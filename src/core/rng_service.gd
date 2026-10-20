extends Node
## rng_service.gd — 随机数唯一入口（架构 §5.5，防 S/L 的地基）
##
## 七条不可协商契约（CI 会扫违例，见 tools/check_deps.py）：
##  1. 全项目只有本文件能创建 RandomNumberGenerator；src/ 其它地方出现
##     randi()/randf()/randomize()/RandomNumberGenerator.new() → exit 1。
##  2. 派生只依赖 (global_seed, day, purpose_salt, 键)，绝不依赖：
##     已消耗的抽取次数、真实时间、帧率、实体数量、玩家操作。
##  3. 全项目 7 条子流全部是"纯 hash / 按槽位 hash"，零顺序消费（C14）。
##  4. UI / Audio / Actor / _process / _physics_process 内禁止取任何 RNG。
##  5. 读档强校验：day_index_of_seed == time.day 且 day_seed 重算匹配。
##  6. rng_salts.json 发布后不可改值；加新子流只能在末尾追加。
##  7. 每日 05:00 存档点后 day_seed 锁定 → 重开同一天世界完全一致。
##
## ⚠ 常数书写纪律（2026-10-20 实跑结论，勿回滚）：
## splitmix64 的三个常数与掩码原为无符号 64 位十六进制（0x9E3779B97F4A7C15 等），
## 其值 > INT64_MAX，**GDScript 无法表示**：引擎会报
##   ERROR: Cannot represent 0x... as a 64-bit signed integer, since the value is too large.
## 并把它**截断成 INT64_MAX**。GOLDEN / M1 / M2 全部塌成同一个数 →
## 十日 day_seed 只剩两个值、按奇偶交替，掉落逐日不变。
## 因此下面**一律以有符号十进制补码书写**（与无符号原值是同一个 64 位位模式，
## 位运算语义完全等价）。**禁止改回十六进制无符号字面量**——那会让缺陷原地复发。

const GOLDEN := -7046029254386353131      # 原 0x9E3779B97F4A7C15
const M1     := -4658895280553007687      # 原 0xBF58476D1CE4E5B9
const M2     := -7723592293110705685      # 原 0x94D049BB133111EB
const U63    := 0x7FFFFFFFFFFFFFFF        # 合法正值 = 9223372036854775807

var _global_seed := 0
var _salts: Dictionary = {}   # purpose -> int，来自 data/rng_salts.json

func setup(global_seed: int) -> void:
	_global_seed = global_seed
	if _salts.is_empty():
		_load_salts()

func _load_salts() -> void:
	var f := FileAccess.open("res://data/rng_salts.json", FileAccess.READ)
	if f == null:
		push_error("rng_salts.json missing - RNG disabled")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("rng_salts.json invalid")
		return
	for k: String in parsed:
		_salts[k] = int(parsed[k])

## 逻辑右移（无符号右移）。
##
## ⚠ GDScript 的 >> 是**算术右移**：负数会在高位灌 1 而不是 0。
## splitmix64 要的是逻辑右移，用 >> 会静默算出完全错的混合结果。
## 本文件只用 30 / 27 / 31，均满足 n >= 1，故不做 n == 0 保护。
static func _ushr(x: int, n: int) -> int:
	return (x >> n) & (U63 >> (n - 1))

## splitmix64 终混（用 int 模拟无符号 64 位语义）
static func mix64(x: int) -> int:
	x = (x ^ _ushr(x, 30)) * M1
	x = (x ^ _ushr(x, 27)) * M2
	return x ^ _ushr(x, 31)

static func str_hash(s: String) -> int:
	return s.hash()

## 当日种子：day_seed(day) = mix64(global_seed ^ day * GOLDEN)
func day_seed(day: int) -> int:
	return mix64(_global_seed ^ (day * GOLDEN))

## 官方转换器：任意哈希值 → 非负整数 [0, 2^63)。
## 全项目"哈希值取非负整数"只此一处定义（包 B/C 迁移 absi 时用这个）。
## 不用 absi()：实测 absi(INT64_MIN) == INT64_MIN 仍为负，取模会得到负数下标。
static func u63(x: int) -> int:
	return x & U63

## 位置无关派生（核心 API）：
##   同一天、同一用途、同一组键 → 永远同一个值。
##   与调用顺序、次数、时间、帧率完全无关（P16 开箱顺序无关性的数学基础）。
func hash_at(purpose: StringName, day: int, keys: PackedStringArray) -> int:
	var h := day_seed(day) ^ int(_salts.get(String(purpose), 0))
	for k in keys:
		h = mix64(h ^ str_hash(k))
	return h

## 从派生值取无符号整数 [0, mod)
func pick(purpose: StringName, day: int, keys: PackedStringArray, mod: int) -> int:
	if mod <= 0:
		return 0
	return (hash_at(purpose, day, keys) & U63) % mod

## 从派生值取 [0.0, 1.0) 浮点（仅用于不参与 L1 判定的表现层）
func unitf(purpose: StringName, day: int, keys: PackedStringArray) -> float:
	return float((hash_at(purpose, day, keys) & U63) % 1000000) / 1000000.0

## 读档校验（契约 5）：由 SaveSystem 在 load 时调用
func verify_day(day: int, stored_day_seed: int) -> bool:
	return day_seed(day) == stored_day_seed

## 新局种子（由 meta/主菜单生成后传入，禁止 randomize()）
static func fresh_seed() -> int:
	# 允许的唯一非确定性来源：新局创建那一刻。
	return int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFFFF
