extends Node
## core_seed_probe.gd — P0 缺陷检测器：Godot JSON.parse_string 的 int64 精度丢失
## 用法：godot --headless --path <repo> --quit-after 120 res://scenes/debug/core_seed_probe.tscn
##
## ═══ 状态：已修复（2026-10-22，core owner 采纳修法 1：seed 存字符串）═══
##   修复内容：save_system._build_payload 的 random 段 global_seed/day_seed 改存
##   十进制字符串；_verify_seed 加 String 分支（String.to_int() 对 64 位精确）；
##   save.schema.json random 段同步。回归门禁：tests/test_save_seed.gd（SAVE 域）。
##   本探针保留为深度检测（含 Godot 引擎行为的边界回归护栏），任何一条红 = 回归。
##
## ═══ 缺陷是什么（历史记录）═══
##   Godot 4.3 的 `JSON.parse_string()` 对**超出 2^53 的整数**会转成 **float**，
##   精度丢失。实测：
##     JSON.stringify({"v": -2152535657050944081})  →  '{"v":-2152535657050944081}'  ✅ 文本正确
##     JSON.parse_string('{"v":-2152535657050944081}') →  -2152535657050944000         ❌ 差 81
##     typeof 结果 = 3 (TYPE_FLOAT)，不是 2 (TYPE_INT)
##
##   而 `rng_service.day_seed()` 是 splitmix64 的 64 位输出 —— **8/8 天全部超出 2^53**。
##   修复前存档里存的是数字，读档时 seed 校验必然不等 → `Save.load_run()` 恒返回
##   空字典 → **玩家每一次真实读档都失败**。
##
## ═══ 为什么这不是战斗组能直接改的 ═══
##   缺陷在 `src/core/rng_service.gd` + `src/core/save_system.gd`（L1 基础层 / core）。
##   按任务书 §2「不做」列，战斗组**只报不改**——core 与 schema 只由源头统一修，
##   各自改会分叉出第二个版本（通道事故重演）。
##   → 本探针是**判据**（战斗组名下），实现修复由 core owner 负责。
##
## ═══ 修法提示（供 core owner 参考，本组不实施）═══
##   三条路，推荐第 1 条：
##   1. **seed 存字符串**：`"day_seed": str(Rng.day_seed(1))`，读档 `int(str)` 还原。
##      —— 改动最小、不动 RNG 算法、JSON 字符串无精度问题。
##   2. **存 53 位内**：把 day_seed 拆成高低两半存（如 `seed_hi`/`seed_lo`）。
##   3. **改用二进制存档**（`var_to_bytes`）：最彻底，但要动整个存档格式与迁移链。
##
##   ⚠ 注意：修哪条都要同步改 `save.schema.json` 的 random 段字段类型
##     （`data/schema/save.schema.json`，属 schema → 也要 core owner 一起改）。

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []


func _ready() -> void:
	_run_all()
	print("--- core_seed_probe: %d pass / %d fail ---" % [_pass, _fail])
	if _fail > 0:
		print("  ↑ RED = P0 回归（seed 路径又被改坏，或引擎行为假设失效）。")
		for f: String in _failures:
			print("  FAILED: %s" % f)
		get_tree().quit(1)
	else:
		print("  ✓ P0 修复有效——真实读档路径畅通（字符串 seed 往返无损）。")
		get_tree().quit(0)


func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)


func _run_all() -> void:
	_test_json_int64_precision()
	_test_day_seed_all_days()
	_test_save_load_seed_verify()


# ════════════════════════════════════════════════════════════════
#  缺陷 1：JSON.parse_string 把超 2^53 的 int64 转 float
# ════════════════════════════════════════════════════════════════
func _test_json_int64_precision() -> void:
	# 边界探测：2^53 之内（含 2^53 本身）可精确表示，超过就丢精度
	# ⚠ 边界选点纪律：2^53 = 9007199254740992 **本身**在 double 里是可精确表示的
	#   （实测往返无损）——用它当"会丢精度"的样本会得到假绿。
	#   真正开始丢的是 2^53 + 1。
	var safe_edge := 9007199254740991          # 2^53 - 1
	var exact_edge := 9007199254740992         # 2^53（仍精确）
	var first_bad := 9007199254740993          # 2^53 + 1（开始丢）
	_t("json: int64 at 2^53-1 survives roundtrip",
		_json_roundtrip_int(safe_edge) == safe_edge)
	_t("json: int64 at exactly 2^53 survives roundtrip (double is exact there)",
		_json_roundtrip_int(exact_edge) == exact_edge)
	_t("json: int64 at 2^53+1 loses precision (known Godot behavior)",
		_json_roundtrip_int(first_bad) != first_bad)

	# 真实场景的值（day_seed(1) 的实际取值）——修复后走**字符串路径**，无损
	var real_seed := Rng.day_seed(1)
	_t("fix: Rng.day_seed(1) survives roundtrip via STRING storage (P0 fix path)",
		_string_roundtrip_int(real_seed) == real_seed)

	# typeof 断言：字符串路径解析回 TYPE_STRING 且 to_int 无损（数字路径永远危险）
	var parsed: Variant = JSON.parse_string(JSON.stringify({"v": str(real_seed)}))
	var v: Variant = (parsed as Dictionary)["v"]
	_t("fix: string-stored day_seed parses as TYPE_STRING and converts losslessly",
		typeof(v) == TYPE_STRING and str(v).to_int() == real_seed)


# ════════════════════════════════════════════════════════════════
#  缺陷 2：day_seed 8/8 天全部超出 2^53（不是偶发）
# ════════════════════════════════════════════════════════════════
func _test_day_seed_all_days() -> void:
	var limit := 9007199254740992   # 2^53
	var over := 0
	for day in range(1, 9):
		var ds := Rng.day_seed(day)
		if ds > limit or ds < -limit:
			over += 1
	_t("rng: all 8 in-game days produce day_seed beyond 2^53 (got %d/8)" % over, over == 8)


# ════════════════════════════════════════════════════════════════
#  缺陷 3：真实存档的读档路径（修复后：save → 磁盘 → load_run 必须通）
# ════════════════════════════════════════════════════════════════
func _test_save_load_seed_verify() -> void:
	# 真实往返：Save.save() 写盘 → Save.load_run() 读回 → seed 校验通过。
	# 修复前 load_run 恒返回空字典（seed 校验必败）；修复后必须非空。
	# ⚠ 会写 user://save.sav——进出字节级备份/恢复（P17b 惯例，不冲玩家存档）。
	var user_dir := OS.get_user_data_dir()
	var bak_real := user_dir.path_join("save.sav.pre_probe")
	var had_real := FileAccess.file_exists("user://save.sav")
	if had_real:
		DirAccess.copy_absolute(ProjectSettings.globalize_path("user://save.sav"),
			ProjectSettings.globalize_path(bak_real))

	var saved := Save.save("death")
	_t("save: Save.save() wrote a real file", saved)
	var loaded := Save.load_run() if saved else {}
	_t("save: Save.load_run() returns non-empty (was ALWAYS empty before P0 fix)",
		not loaded.is_empty())

	# 控制组：未过 JSON 的原始 day_seed 校验（RNG 本身自洽）
	_t("save: seed check passes on the raw day_seed (control)",
		Rng.verify_day(1, Rng.day_seed(1)))

	# 清理：恢复原存档（或删掉探针写的）
	if had_real:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(bak_real),
			ProjectSettings.globalize_path("user://save.sav"))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak_real))
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://save.sav"))
		if FileAccess.file_exists("user://save.sav.bak"):
			DirAccess.remove_absolute("user://save.sav.bak")


## 字符串路径往返：str(int) → JSON → parse → to_int()（P0 修复的通道）
func _string_roundtrip_int(v: int) -> int:
	var text := JSON.stringify({"v": str(v)})
	var parsed: Variant = JSON.parse_string(text)
	return str((parsed as Dictionary)["v"]).to_int()


## 一个 int64 过一趟 JSON 数字往返后的值（对照用：超 2^53 必失真）
func _json_roundtrip_int(v: int) -> int:
	var text := JSON.stringify({"v": v})
	var parsed: Variant = JSON.parse_string(text)
	return int((parsed as Dictionary)["v"])
