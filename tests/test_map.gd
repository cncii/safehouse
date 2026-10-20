extends RefCounted
## tests/test_map.gd — 域判据：地图确定性 【包 F · W2 判据移植】
##
## 判据本体：src/systems/map_system.gd 自检入口 verify_determinism()。
## 判据定义来源：map_system.gd 文件头契约（M9/M9b/P16）/ 任务书_逻辑组_包B §6（M9 重开 20/20）。
## 引用版本：map_system.gd@2026-10-20。
##
## 覆盖：M9（同日重开 20 次快照签名全等——世界快照哈希逐字节相等）
##       M9b（反向对照：换一天签名必须变——防恒等函数假绿）
##       P16（正序/逆序开同组点位，逐点内容相等——防顺序消费流回流）

const REOPEN_COUNT := 20   # 任务书_逻辑组 DoD：M9 重开 20/20 全等


static func run(host) -> void:
	var ms = MapSystem.new()
	host.add_child(ms)

	var out: Dictionary = ms.verify_determinism(REOPEN_COUNT)
	# 空跑判负：结果为空 = 判据没跑
	host._t("MAP-0 verify_determinism() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["MAP-M9", "MAP-M9b", "MAP-P16"],
			"blocked: verify_determinism() empty")
		ms.free()
		return

	# ── M9：同日重开 20/20 全等 ──
	# 双腿：M9_pass（实现自检）+ 实测计数 == 20（防实现的"全等"口径被改松成 >0）
	host._t("MAP-M9 reopen determinism %d/%d (signature byte-equal)"
		% [int(out.get("M9_reopen_equal", 0)), int(out.get("M9_reopen_total", 0))],
		bool(out.get("M9_pass", false))
		and int(out.get("M9_reopen_equal", 0)) == REOPEN_COUNT)
	# ── M9b：换天必须变（反向对照，抓"hash 没吃 day"的恒等假绿）──
	host._t("MAP-M9b day+1 signature differs (reverse control)", bool(out.get("M9b_day_separates", false)))
	# ── P16：开箱顺序无关 6/6 ──
	host._t("MAP-P16 loot order-independent %d/%d points equal"
		% [int(out.get("P16_points_equal", 0)), int(out.get("P16_points_total", 0))],
		bool(out.get("P16_pass", false)))

	ms.free()
