extends RefCounted
## tests/test_time.gd — 域判据：时间与日程 【包 F · W2 判据移植】
##
## 判据本体：src/systems/time_system.gd 自检入口 verify_time_modes()（判据本体在实现文件内，
## 本文件是移植层：调入口 + 拆键断言 + 独立边界测试）。判据定义来源：
##   time_system.gd 文件头契约 / 架构方案 §11 / 任务书_逻辑组_包B §6。
## 引用版本：time_system.gd@2026-10-20（INCAP/WINDUP 等帧常量另由 run_tests.gd M30/F0-b 锚定）。
##
## 覆盖：P12b（夜间 12GH 全额结算 ±0.001，击杀/挂机双驱动）
##       M23（挂机兜底 ≤8min 硬上限）
##       M29（熬夜夜数 k ≤ 2 前置）
##       M5（阶段A→B 切换：day 8 / night_index 1 / B_SIEGE）
##       M11a（入口锁边界：20:00 前 false / 到点即锁）
##       M11b（出口锁：阶段B 常锁）

const EXPECTED_SETTLED_GH := 30.0        # 18:00 起 + 夜间 12 GH（架构定稿）
const EXPECTED_SETTLED_FRAMES := 51840   # 12 GH × 4320 帧（架构定稿）
const M23_CAP_SEC := 480.0               # 挂机兜底 8min（架构定稿）
const M29_MAX_K := 2                     # 熬夜上限（架构定稿）


static func run(host) -> void:
	var ts = TimeSystem.new()
	host.add_child(ts)   # host 已 ready，add_child 安全；_ready 同步触发 _load_balance

	# 空跑判负：自检入口必须返回结构化结果，空字典 = 判据没跑（三层空跑判负之判据层）
	var out: Dictionary = ts.verify_time_modes()
	host._t("TIME-0 verify_time_modes() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["TIME-P12b-kill", "TIME-P12b-kill-frames", "TIME-P12b-idle",
			"TIME-P12b-idle-frames", "TIME-M23", "TIME-M23-anchor", "TIME-M29",
			"TIME-M5", "TIME-M11b", "TIME-M11a-before", "TIME-M11a-boundary",
			"TIME-M11a-B-stage"], "blocked: verify_time_modes() empty")
		ts.free()
		return

	# ── P12b：夜间结算恒 12GH ±0.001（击杀驱动 + 挂机驱动 双路径）──
	host._t("P12b-1 kill-driven settled GH == 30.0 (+-0.001)",
		absf(float(out.get("P12b_kill_gh", -1.0)) - EXPECTED_SETTLED_GH) <= 0.001)
	host._t("P12b-1 kill-driven settled frames exact == 51840",
		bool(out.get("P12b_kill_frames_exact", false)))
	host._t("P12b-2 idle-driven settled GH == 30.0 (+-0.001)",
		absf(float(out.get("P12b_idle_gh", -1.0)) - EXPECTED_SETTLED_GH) <= 0.001)
	host._t("P12b-2 idle-driven settled frames exact == 51840",
		bool(out.get("P12b_idle_frames_exact", false)))

	# ── M23：挂机兜底 ≤8min ──
	# 两条腿：实现侧 M23_pass（用实现冻结常量比）+ 本文件独立锚点（实测秒值 ≤ 480）。
	# 独立锚点的意义：若实现的期望常量被人改松（如 480→600），M23_pass 照样绿，
	# 这条用 tests 侧冻结值 480 抓住——判据眼里的正确答案不随实现常量漂移。
	host._t("TIME-M23 fallback finishes within cap (impl self-check)",
		bool(out.get("M23_pass", false)))
	host._t("TIME-M23 anchor: measured fallback_sec <= 480 (frozen test anchor)",
		float(out.get("M23_fallback_sec", 1e9)) <= M23_CAP_SEC + 1.0)

	# ── M29：熬夜夜数 k 封顶 2 ──
	host._t("TIME-M29 overtime nights capped at 2 (accepted 2/5, k==2)",
		bool(out.get("M29_pass", false))
		and int(out.get("M29_accepted_of_5", -1)) == M29_MAX_K)

	# ── M5：阶段A→B 切换 ──
	host._t("TIME-M5 stage-B entry: stage==B_SIEGE, day==8, night_index==1",
		bool(out.get("M5_pass", false))
		and int(out.get("M5_stage", -1)) == 1 and int(out.get("M5_day", -1)) == 8
		and int(out.get("M5_night_index", -1)) == 1)

	# ── M11b：出口锁（阶段B 常锁，C23）──
	host._t("TIME-M11b exit locked throughout stage B", bool(out.get("M11b_exit_locked_in_B", false)))

	# ── M11a：入口锁边界（独立断言，不依赖 verify_time_modes）──
	# 实例夹具法：gh_now() 在新实例（REALTIME、GameLoop elapsed=0）恒为 0.0，
	# 摆布测试实例自身的 _curfew_gh 到 0 的两侧，测「比较符与阶段门」的行为。
	# 不改 data/*.json、不改源码；实例用完即 free，默认值不受影响。
	# 能抓：>= 被改成 >（边界翻转）/ stage 门被去掉（B 阶段也锁入口）/ 锁被反转。
	ts.stage = TimeSystem.Stage.A_LOOT
	host._t("TIME-M11a before curfew (gh=0 < 20) entry NOT locked",
		not ts.is_entry_locked())
	ts._curfew_gh = 0.0   # 夹具：把锁线摆到当前 gh 之下，测 >= 边界即触发
	host._t("TIME-M11a at curfew boundary (gh >= lock) entry locked",
		ts.is_entry_locked())
	ts.stage = TimeSystem.Stage.B_SIEGE
	host._t("TIME-M11a in stage B entry-lock check does not apply (false), exit stays locked",
		not ts.is_entry_locked() and ts.is_exit_locked())
	ts.free()
