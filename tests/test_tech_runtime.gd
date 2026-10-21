extends RefCounted
## tests/test_tech_runtime.gd — 域判据：科技树·运行期 【包 B 接线 · 2026-10-21】
##
## 判据本体：src/systems/tech_tree_system.gd 自检入口 verify_tech_tree()。
## 判据定义来源：任务书_逻辑组_包B §6（P28 单局 [12,16] 分母 24 · P22-0 拆解台守护）
##   + tech_tree_system.gd 文件头契约。引用版本：tech_tree_system.gd@2026-10-21。
##
## ⚠ 与 test_tech.gd 的 `M31` **不是同一条判据**（互补，不重叠）：
##   test_tech.gd 测的是**数据层** M31（tier ↔ 前置深度，tier_max == max_level）；
##   本文件测的是**运行期**行为：研究流程（开工→累计→解锁→清 researching）
##   与 P22-0 目录级守护（拆解台必须恰好覆盖全部 5 个 L1 key）。
##
## ⚠ 与 test_loop.gd 里出现的 `P22-0` **也不是同一条**：
##   那是 loop 侧的设施前置守护，本条是科技树的目录级守护。
##
## 能抓：研究提前解锁（变异体 3：提前 10% → research_90pct_not_done 红）
##       锁定节点可被开工 / researching 不清 / 拆解台守护被弱化 / 节点数掉到 24 以下

const BLOCKED_IDS := ["TECHRUN-P22-0", "TECHRUN-P28", "TECHRUN-check",
	"TECHRUN-research", "TECHRUN-boundary"]

## P22-0 结构判据的独立基准（冻结值）：拆解台必须恰好覆盖全部 5 个 L1 key。
## 写死不取被测函数自算值——防恒真式（本项目已踩三次）。
const EXPECTED_L1_COUNT := 5
const EXPECTED_MIN_NODES := 24


static func run(host) -> void:
	var ts = TechTreeSystem.new()
	host.add_child(ts)

	var out: Dictionary = ts.verify_tech_tree()
	host._t("TECHRUN-0 verify_tech_tree() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(BLOCKED_IDS, "blocked: verify_tech_tree() empty")
		ts.queue_free()
		return

	# ── P22-0 目录级守护：拆解台前置必须恰好等于全部 L1 key（弱化它 = 必败路径回归）──
	host._t("TECHRUN-P22-0 dismantle bench guard structure intact (%d problems)"
		% int(out.get("P22_0_problems", -1)),
		bool(out.get("P22_0_pass", false)))

	# ── P28：节点数 ≥ 24（分母 24）──
	host._t("TECHRUN-P28 tech tree node count %d >= %d"
		% [int(out.get("P28_node_count", -1)), EXPECTED_MIN_NODES],
		bool(out.get("P28_pass", false))
		and int(out.get("P28_node_count", 0)) >= EXPECTED_MIN_NODES)

	# ── check_unlock：锁定节点必须拒绝，且报出缺失的前置数 ──
	host._t("TECHRUN-check locked node rejects unlock + reports %d missing prereq"
		% int(out.get("check_missing_when_locked", -1)),
		bool(out.get("check_pass", false))
		and int(out.get("check_missing_when_locked", 0)) == EXPECTED_L1_COUNT)

	# ── 研究流程：差 1 milli 不许解锁；补满最后 1 milli 立刻解锁且 researching 清空 ──
	host._t("TECHRUN-research 1-milli-short stays locked; full duration unlocks",
		bool(out.get("research_pass", false))
		and bool(out.get("research_not_done_1milli_short", false))
		and bool(out.get("research_done", false))
		and bool(out.get("research_unlocked", false)))

	# ── 边界（抓"提前解锁"类变异）：90% 必须仍未完成，100% 必须完成 ──
	host._t("TECHRUN-boundary 90pct not done / 100pct done (anti-early-unlock)",
		bool(out.get("research_boundary_pass", false))
		and bool(out.get("research_90pct_not_done", false))
		and bool(out.get("research_100pct_done", false))
		and bool(out.get("research_torch_unlocked", false)))

	ts.queue_free()