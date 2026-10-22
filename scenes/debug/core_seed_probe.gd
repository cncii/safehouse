extends Node
## core_seed_probe.gd — ★ P0 缺陷检测器：Godot JSON.parse_string 的 int64 精度丢失
## 用法：godot --headless --path <repo> --quit-after 120 res://scenes/debug/core_seed_probe.tscn
##
## ═══ 这条判据在「core 修好之前应该是红的」═══
##   本探针**故意**判红。红的含义 = **P0 缺陷仍在**。
##   它不并入任何门禁（跑一次就红会污染信号），单独跑、单独看。
##   core 修好后（seed 改用字符串或改存到 53 位内），本探针会转绿。
##
## ═══ 缺陷是什么 ═══
##   Godot 4.3 的 `JSON.parse_string()` 对**超出 2^53 的整数**会转成 **float**，
##   精度丢失。实测：
##     JSON.stringify({"v": -2152535657050944081})  →  '{"v":-2152535657050944081}'  ✅ 文本正确
##     JSON.parse_string('{"v":-2152535657050944081}') →  -2152535657050944000         ❌ 差 81
##     typeof 结果 = 3 (TYPE_FLOAT)，不是 2 (TYPE_INT)
##
##   而 `rng_service.day_seed()` 是 splitmix64 的 64 位输出 —— **8/8 天全部超出 2^53**。
##   存档里存的是这个值，读档时：
##     save_system._verify_seed() → Rng.verify_day(day, stored_day_seed)
##     → day_seed(day) == stored_day_seed  →  **必然不等** → 判为坏档
##   → `Save.load_run()` 恒返回空字典 → **玩家每一次真实读档都失败**。
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
		print("  ↑ 本探针当前**预期为红**：红的含义 = P0 缺陷仍在。")
		print("    修好后（core owner 改 save_system/rng_service + save.schema.json）会转绿。")
		for f: String in _failures:
			print("  FAILED: %s" % f)
		get_tree().quit(1)
	else:
		print("  ✓ P0 缺陷已修复——真实读档路径应该通了（可复跑 p17b_probe 确认）。")
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

	# 真实场景的值（day_seed(1) 的实际取值）
	var real_seed := Rng.day_seed(1)
	_t("json: Rng.day_seed(1) survives JSON roundtrip",
		_json_roundtrip_int(real_seed) == real_seed)

	# typeof 断言：超 2^53 的整数解析后应为 INT，实际得到 FLOAT
	var parsed: Variant = JSON.parse_string(JSON.stringify({"v": real_seed}))
	var v: Variant = (parsed as Dictionary)["v"]
	_t("json: parsed oversized int keeps TYPE_INT (not TYPE_FLOAT)",
		typeof(v) == TYPE_INT)


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
#  缺陷 3：真实存档的读档路径必然失败（seed 校验恒不过）
# ════════════════════════════════════════════════════════════════
func _test_save_load_seed_verify() -> void:
	# 模拟 save_system._verify_seed 的判定（同一份逻辑，同一个来源）
	var stored := _json_roundtrip_int(Rng.day_seed(1))   # 存档里读回来的值
	var verified := Rng.verify_day(1, stored)
	_t("save: seed check passes on a JSON-roundtripped day_seed", verified)
	_t("save: seed check passes on the raw day_seed (control)",
		Rng.verify_day(1, Rng.day_seed(1)))


## 一个 int64 过一趟 JSON 往返后的值
func _json_roundtrip_int(v: int) -> int:
	var text := JSON.stringify({"v": v})
	var parsed: Variant = JSON.parse_string(text)
	return int((parsed as Dictionary)["v"])
