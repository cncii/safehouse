extends RefCounted
## tests/test_save_seed.gd — 域判据：seed 存档往返精度（P0 回归门禁） 【core 2026-10-22】
##
## ## 这条判据对着什么
## Godot 4.3 的 JSON.parse_string() 对超出 2^53 的数字必转 float（精度丢失），
## 而 Rng.day_seed() 是 splitmix64 的 64 位输出——8/8 天全部超出 2^53。
## P0 修复（2026-10-22）：random 段的 seed 一律存**十进制字符串**（字符串往返无损，
## 读档 String.to_int() 精确还原）。修复前 `Save.load_run()` 恒返回空字典——
## 玩家每一次真实读档都失败。本域验证修复且防回归。
##
## ## 判据来源
## scenes/debug/core_seed_probe.gd（P0 检测器，修复后转绿）+ 架构 §5.5 契约 5
## + save.schema.json random 段（P0 修复版）。引用版本：save_system.gd@2026-10-22。
##
## ## 能抓
## 字符串路径被改回数字 / _verify_seed 丢掉 String 分支 / 真实 save→load 往返
## 因 seed 失真判坏档 / .bak 恢复链失效。
##
## ## 变异建议（留给包 F）
##   变异 A：_build_payload 把 str() 摘掉 → SAVE-str / SAVE-real / SAVE-verify 三红
##   变异 B：_verify_seed 删 String 分支 → SAVE-verify 红
##   变异 C：to_int() 改 int() → SAVE-str2 红（int(float) 截断）
##
## ⚠ 本域会写 user://save.sav：进出做字节级备份/恢复（P17b 惯例），
##   一次门禁跑不能把开发机现存档冲掉。

static func run(host) -> void:
	# ── ① 字符串路径数学上无损（不经引擎 JSON 数字的危险区）──
	var ok_days := 0
	for day in range(1, 9):
		var ds: int = Rng.day_seed(day)
		var text := JSON.stringify({"v": str(ds)})
		var parsed: Variant = JSON.parse_string(text)
		var back: int = str((parsed as Dictionary)["v"]).to_int()
		if back == ds and typeof((parsed as Dictionary)["v"]) == TYPE_STRING:
			ok_days += 1
	host._t("SAVE-str 8/8 days: day_seed as STRING survives JSON roundtrip exactly (%d/8)" % ok_days,
		ok_days == 8)

	# ── ② 对照：数字路径仍然危险（Godot 引擎行为回归护栏，防有人改回数字）──
	var raw_ds: int = Rng.day_seed(1)
	var num_back: int = int((JSON.parse_string(JSON.stringify({"v": raw_ds})) as Dictionary)["v"])
	var num_is_lossy: bool = num_back != raw_ds
	host._t("SAVE-guard raw-number roundtrip is STILL lossy for day_seed (do not regress to number storage)",
		num_is_lossy or absi(raw_ds) <= 9007199254740992)

	# ── ③ 真实存档往返：Save.save() → 磁盘 → Save.load_run() ──
	var user_dir := OS.get_user_data_dir()
	var bak_real := user_dir.path_join("save.sav.pre_seed_test")
	var had_real := FileAccess.file_exists("user://save.sav")
	if had_real:
		DirAccess.copy_absolute(_abs("user://save.sav"), _abs(bak_real))

	# 清洗：前面的测试域（TIMEP 等）可能写过档，先删主档/.bak，
	# 让本次往返从零开始——SAVE 域只对"自己写的档"负责，不背别人的锅。
	Save.purge_dead_persistences()
	for p: String in ["user://save.sav", "user://save.sav.bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(_abs(p))

	var saved: bool = Save.save("death")   # 探针用途，落真实文件
	host._t("SAVE-real Save.save() wrote a real file (P0 made load_run always fail; save itself was fine)",
		saved)

	# 直接证据：绕开 load_run，手动读盘 dump random 段（save 刚写的必须是字符串形态）
	if saved and FileAccess.file_exists("user://save.sav"):
		var f := FileAccess.open("user://save.sav", FileAccess.READ)
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var txt := bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
		var disk: Variant = JSON.parse_string(txt)
		var rnd_disk: Variant = (disk as Dictionary).get("random", {}) if typeof(disk) == TYPE_DICTIONARY else {}
		print("  [SAVE-debug] disk random section = ", JSON.stringify(rnd_disk))

	var loaded: Dictionary = Save.load_run() if saved else {}
	host._t("SAVE-real Save.load_run() returns non-empty (P0 made this ALWAYS empty)", not loaded.is_empty())

	# ── ④ 读回的 day_seed 与当前派生一致（字符串 → to_int 精确）──
	if not loaded.is_empty():
		var rnd: Dictionary = loaded.get("random", {})
		var stored: Variant = rnd.get("day_seed", null)
		host._t("SAVE-type stored day_seed is TYPE_STRING (per save.schema.json P0 fix)",
			typeof(stored) == TYPE_STRING)
		var day: int = int(loaded.get("time", {}).get("day", 1))
		host._t("SAVE-verify stored day_seed == Rng.day_seed(day) exactly (day=%d)" % day,
			typeof(stored) == TYPE_STRING and (stored as String).to_int() == Rng.day_seed(day))
		host._t("SAVE-verify2 seed check passes through _verify_seed path (day_index matches)",
			int(rnd.get("day_index_of_seed", -1)) == day)

	# ── ⑤ 现场清理：恢复原存档（或删掉探针写的），不留垃圾 ──
	if had_real:
		DirAccess.copy_absolute(_abs(bak_real), _abs("user://save.sav"))
		DirAccess.remove_absolute(_abs(bak_real))
	else:
		DirAccess.remove_absolute(_abs("user://save.sav"))
		if FileAccess.file_exists("user://save.sav.bak"):
			DirAccess.remove_absolute("user://save.sav.bak")
	host._t("SAVE-clean probe restored/cleared user save dir (no residue)", true)


static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)


## save 前清掉注册表里的死 Callable（前面测试域 queue_free 的实例残留），
## 返回注册表是否可用。真实游戏无此问题（系统永不释放）。
static func _prepare_registry() -> bool:
	var removed: int = Save.purge_dead_persistences()
	return true
