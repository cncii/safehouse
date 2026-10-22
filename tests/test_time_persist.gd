extends RefCounted
## tests/test_time_persist.gd — 域判据：时间存档一致性（C-01 的直接判据） 【包 B 接线 · 2026-10-22】
##
## 判据本体：src/systems/time_system.gd 自检入口 verify_time_persistence()。
## 判据定义来源：QA 判据表 M7 / M8 / P7 的「⛔ C-01 阻塞」项
##   + data/schema/save.schema.json 的 time 段字段级定义。引用版本：time_system.gd@2026-10-22。
##
## ## 这条判据对着什么
## core 的 `_build_payload()` 曾硬编码 `"time": {"day": 1, "stage": "A", ...}`，
## 且缺 k_overtime → **存档里的时间永远是最新的第 1 天**（C-01 原始症状）。
## 现在时间状态由 TimeSystem 写进 State（contract 已注册的 time.* 四条路径），
## time 段经 SaveSystem 注册表落盘（含 k_overtime）。本文件验证的就是这两件事。
##
## ## 变异测试（两个变异体各自被抓，无误伤）
##   变异 1：摘掉 State 同步出口 → C01_state_synced 红
##   变异 2：存档段退回 core 硬编码 → C01_k_ok / C01_missing_fields /
##            C01_restore_ok / C01_day_not_hardcoded 四条同时红
##
## 能抓：时间状态从不进 State / 存档段缺 k_overtime / 存档段字段不全 /
##       读档恢复丢字段 / 存档 day 恒为 1（core 硬编码的症状）

static func run(host) -> void:
	var ts = TimeSystem.new()
	host.add_child(ts)

	var out: Dictionary = ts.verify_time_persistence()
	host._t("TIMEP-0 verify_time_persistence() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["TIMEP-sync", "TIMEP-k", "TIMEP-fields", "TIMEP-restore", "TIMEP-day"],
			"blocked: verify_time_persistence() empty")
		ts.queue_free()
		return

	# ── ① State 里的 time.* 与实例状态一致（同步出口接上了）──
	host._t("TIMEP-sync time.* synced into State (day=%s stage=%s night=%s)"
		% [str(out.get("C01_state_day", "?")), str(out.get("C01_state_stage", "?")),
			str(out.get("C01_state_night_index", "?"))],
		bool(out.get("C01_state_synced", false)))

	# ── ② 存档段含 k_overtime（core 的硬编码 payload 整段缺这个字段）──
	host._t("TIMEP-k save section carries k_overtime (= %s)"
		% str(out.get("C01_save_k_overtime", "?")),
		bool(out.get("C01_save_has_k_overtime", false))
		and bool(out.get("C01_k_ok", false)))

	# ── ③ 存档段七个字段齐全 ──
	host._t("TIMEP-fields save section has all 7 schema fields (missing %d)"
		% int(out.get("C01_missing_fields", -1)),
		bool(out.get("C01_fields_ok", false)))

	# ── ④ 读档往返：存档 → 恢复 → 状态一致 ──
	host._t("TIMEP-restore load restores day/night_index/k_overtime/stage",
		bool(out.get("C01_restore_ok", false)))

	# ── ⑤ 存档的 day 不能恒为 1（专治 core 硬编码的症状）──
	host._t("TIMEP-day saved day=%s is not hardcoded 1"
		% str(out.get("C01_save_day", "?")),
		bool(out.get("C01_day_not_hardcoded", false)))

	ts.queue_free()