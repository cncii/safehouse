extends RefCounted
## tests/test_action.gd — 域判据：连续动作产出守恒 【包 F · W2 判据移植 2026-10-20】
##
## 判据定义来源：continuous_action.gd 头契约（M20：25 断言点 5 动作×5 场景，产出守恒）。
## 判据本体：ContinuousAction.verify_continuous_actions()（逻辑组 924b0f6 补齐自检入口，
## 此前 M20 完全空缺）。引用版本：continuous_action.gd@924b0f6。
##
## 守恒口径 = 「续做 N 次的累计产出 == 一次做完的产出」。能抓：
## 中断把已结算段清零（越续越亏）/ refund_on_cancel 被打开（无限刷材料）/ 半段锚点误载。

static func run(host) -> void:
	# ⚠ ContinuousAction 是 RefCounted 不是 Node——不能 add_child（类型错会把 run()
	# 整段截断，首跑实测 ACTION 域 0 条上账）。RefCounted 无 _ready，直接实例即用。
	var ca = ContinuousAction.new()

	var out: Dictionary = ca.verify_continuous_actions()
	# 空跑判负：返回空 = 判据没跑（三层空跑判负）
	host._t("ACTION-0 verify_continuous_actions() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["ACTION-M20-full", "ACTION-M20-resume", "ACTION-M20-anon",
			"ACTION-M20-refund", "ACTION-M20-anchor", "ACTION-M20-schema",
			"ACTION-G-remaining", "ACTION-G-research"],
			"blocked: verify_continuous_actions() empty")
		ca.free()
		return

	# ── M20-1：一次做完 = 3000 milli（拆解 2GH / 4 段 / 每段 750）──
	# 双腿：实现自检 pass 键 + tests 侧冻结值 3000 直比（防实现的期望值被改松）
	host._t("ACTION-M20-1 full run output == 3000 milli (frozen anchor)",
		bool(out.get("M20_full_pass", false))
		and int(out.get("M20_full_output_milli", -1)) == 3000)
	# ── M20-2：同一动作反复中断续做（≥10 次尝试），总产出恒 3000 milli ──
	host._t("ACTION-M20-2 interrupted resume keeps total == 3000 milli",
		bool(out.get("M20_resume_pass", false))
		and int(out.get("M20_resumed_total_milli", -1)) == 3000
		and int(out.get("M20_resumed_interrupts", 0)) >= 1)
	# ── M20-3：ALL_OR_NOTHING 中断 → 进度与产出归零（重来无套利）──
	host._t("ACTION-M20-3 ALL_OR_NOTHING interrupt resets progress and output to 0",
		bool(out.get("M20_anon_pass", false)))
	# ── M20-4：refund_on_cancel 恒 false（写 true 被拒——"无限刷零件"洞封口）──
	host._t("ACTION-M20-4 refund_on_cancel stays false (write-true rejected)",
		bool(out.get("M20_refund_pass", false))
		and bool(out.get("M20_refund_flag", true)) == false)
	# ── M20-5：半段锚点拒载（750 是竞态不是状态，2000 才合法）──
	host._t("ACTION-M20-5 anchor 750 rejected, 2000 accepted",
		bool(out.get("M20_anchor_pass", false)))
	# ── 硬规则：分段动作缺 progress_persisted → 加载期即报错 ──
	host._t("ACTION-M20-6 schema blocks missing progress_persisted",
		bool(out.get("M20_schema_pass", false)))

	# ════════════════════════════════════════════════════════════
	#  ↓ TASK-G 追加段（逻辑组 · 2026-10-22，包 F 归档时可整体移走）
	# ════════════════════════════════════════════════════════════
	# ── TASK-G §4 硬约束4：耗时动作必须能给"剩余 GH" ──
	host._t("ACTION-G-remaining remaining=%s elapsed=%s sum==duration (zero-safe)"
		% [str(out.get("G_remaining_gh", "?")), str(out.get("G_elapsed_gh", "?"))],
		bool(out.get("G_remaining_pass", false)))
	# ── TASK-G M3：研发动作工厂（时长从 tech_tree.json 读；未知节点必拒）──
	host._t("ACTION-G-research research factory gh=%s (frozen anchor 3), unknown rejected"
		% str(out.get("G_research_duration_gh", "?")),
		bool(out.get("G_research_factory_pass", false)))

	ca.free()
