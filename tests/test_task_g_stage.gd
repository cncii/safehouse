extends RefCounted
## tests/test_task_g_stage.gd — 域判据：TASK-G 拨钟 / 过渡夜 / 阶段A→B 【包 B 接线 · 2026-10-22】
##
## 判据本体：src/systems/time_system.gd 自检入口 verify_stage_transition()。
## 判据定义来源：架构 §11.1「切换点唯一：D7 20:00 门锁死的那一刻」+
##   「D7 20:00 → D8 06:00 是过渡夜：不计夜次、无波次、只播氛围音」+
##   §13.1 第16条「过渡夜照常衰减 10 GH」+ TASK-G §4 硬约束2。
##   引用版本：time_system.gd@2026-10-22。
##
## 对着 DoD：G5（阶段 A→B → 夜 1 波次可打）、G7（20:00 门锁、阶段B 常锁实机可触发）。
##
## ## 拨钟为什么是注入的
## C27 规定 `GameLoop.elapsed_ticks` 是时间唯一真相，而 GameLoop 属 **core**——
## 包 B 不直接写 core 状态（协作纪律），所以走 `clock_advance_gate` 注入回调。
## **未注入时新局/跳夜/过渡夜一律明确失败**（reason="no_clock_gate"），不静默算错。
## 测试里注入一个把 ticks 拨到目标 GH 的实现，模拟 core 提供 API 后的一行接线。
##
## 变异测试（3 个变异体各自被抓，无误伤）：
##   A：settle_gh 漏算到天亮的 6 GH（10→4）→ G_transition_settle_ok 红
##   B：阶段守卫失效（阶段A 也能开波次）→ G_stage_a_wave_rejected 红
##   C：过渡夜计了夜次（架构明写"不计夜次"）→ G_transition_no_night_count 红

const BLOCKED_IDS := ["G-TR-no-gate", "G-TR-settle", "G-TR-phase", "G-TR-night-count",
	"G-TR-wave", "G-TR-early", "G-TR-repeat", "G-TR-b-skip", "G-TR-wave-driven"]

## 过渡夜结算 GH 独立基准（24 - 20 出走 + 6 到天亮 = 10）。
## 写死而不用 (24-curfew)+dawn 自算——后者是恒真式（改设计值判据跟着变）。
const TRANSITION_SETTLE_GH := 10.0


static func run(host) -> void:
	var ts = TimeSystem.new()
	host.add_child(ts)

	# 注入拨钟（模拟 core 提供 GameLoop.advance_to 之后的一行接线）
	ts.clock_advance_gate = Callable(host, "_advance_clock_for_test")

	var out: Dictionary = ts.verify_stage_transition()
	host._t("G-TR-0 verify_stage_transition() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(BLOCKED_IDS, "blocked: verify_stage_transition() empty")
		ts.queue_free()
		return

	# ── ① 未注入拨钟时必须明确失败（不静默算错）──
	host._t("G-TR-no-gate without clock gate begin_new_run fails with reason=%s"
		% str(out.get("G_no_gate_reason", "?")),
		bool(out.get("G_no_gate_rejects", false)))

	# ── ② 过渡夜结算 10 GH（架构 §13.1 第16条：照常衰减）──
	host._t("G-TR-settle transition night settles %.0f GH (expected %.0f)"
		% [float(out.get("G_transition_settle_gh", -1.0)), TRANSITION_SETTLE_GH],
		bool(out.get("G_transition_settle_ok", false)))

	# ── ③ 进过渡夜后 phase == TRANSITION_NIGHT 且**不计夜次** ──
	host._t("G-TR-phase phase==%s, night_index stays %d (not counted)"
		% [str(out.get("G_transition_phase", "?")),
			int(out.get("G_transition_night_index", -1))],
		bool(out.get("G_transition_phase_ok", false))
		and bool(out.get("G_transition_no_night_count", false)))

	# ── ④ 过渡夜「无波次」──
	host._t("G-TR-wave wave rejected during transition night (reason=%s)"
		% str(out.get("G_transition_wave_reason", "?")),
		bool(out.get("G_transition_wave_rejected", false)))

	# ── ⑤ 切换点唯一：D5 不许进过渡夜 ──
	host._t("G-TR-early transition night rejected before D7 (reason=%s)"
		% str(out.get("G_early_reason", "?")),
		bool(out.get("G_early_rejected", false)))

	# ── ⑥ 重复进过渡夜幂等（settle_gh 不累加）──
	host._t("G-TR-repeat repeat begin rejected=%s, settle unchanged"
		% str(out.get("G_repeat_rejected", false)),
		bool(out.get("G_repeat_rejected", false))
		and bool(out.get("G_repeat_settle_unchanged", false)))

	# ── ⑦ 阶段B 不可跳夜（核心动词）──
	host._t("G-TR-b-skip stage B reject skip-night",
		bool(out.get("G_stage_b_skip_rejected", false)))

	# ── ⑧ 阶段A 不许开波次；阶段B 开波次 → mode 必须 WAVE_DRIVEN（硬约束2）──
	host._t("G-TR-wave-driven stage A rejects wave; stage B wave -> mode=%s phase=%s"
		% [str(out.get("G_wave_mode", "?")), str(out.get("G_wave_phase", "?"))],
		bool(out.get("G_stage_a_wave_rejected", false))
		and bool(out.get("G_stage_b_wave_ok", false))
		and bool(out.get("G_wave_driven", false))
		and bool(out.get("G_wave_phase_ok", false)))

	ts.queue_free()


## 死亡重开（TASK-G DoD G4 的时间侧）
## 架构 §5.4：「死亡从当日清晨重开，种子按『局种子+天数』派生 →
##   同一天重开随机内容完全一致」。
## 本组负责时间复位；「同种子同日布局一致」由 map 侧 M9 判据覆盖。
##
## 变异测试（2 个变异体各自被抓）：
##   A：day_start 用 floor(g/24)*24+mark（会跳到次日）→ 凌晨用例抓（G-RS-midnight 红）
##   B：重开时 day+1（变成次日重开）→ G-RS-same-day / G-RS-3x 红

const RESTART_DAY_A_START_GH := 53.0        # D3 05:00 = 2*24 + 5
const RESTART_DAY_B_START_GH := 174.0       # D8 06:00 = 7*24 + 6
const RESTART_MIDNIGHT_EXPECTED_GH := 5.0   # 第1天 03:00 死 → 回第0天 05:00


static func run_restart(host) -> void:
	var ts = TimeSystem.new()
	host.add_child(ts)
	ts.clock_advance_gate = Callable(host, "_advance_clock_for_test")

	var out: Dictionary = ts.verify_restart_same_day()
	host._t("G-RS-0 verify_restart_same_day() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["G-RS-same-day", "G-RS-3x", "G-RS-stage-b", "G-RS-midnight"],
			"blocked: verify_restart_same_day() empty")
		ts.queue_free()
		return

	# ── ① 同日重开：day 不变，钟回当日 05:00 ──
	host._t("G-RS-same-day restart from %.0f GH -> day stays %d, gh=%.0f (expected %.0f)"
		% [float(out.get("G_restart_before_gh", -1)), int(out.get("G_restart_day", -1)),
			float(out.get("G_restart_gh", -1)), RESTART_DAY_A_START_GH],
		bool(out.get("G_restart_day_unchanged", false))
		and bool(out.get("G_restart_gh_ok", false))
		and bool(out.get("G_restart_phase_ok", false)))

	# ── ② 连开 3 次，落点完全相同（DoD G4 的"×3"）──
	host._t("G-RS-3x restart 3x lands on identical day+gh (%d runs)"
		% int(out.get("G_restart_runs", -1)),
		bool(out.get("G_restart_3x_pass", false))
		and int(out.get("G_restart_runs", 0)) == 3)

	# ── ③ 阶段B 重开落在 06:00（不是 05:00）──
	host._t("G-RS-stage-b stage B restart lands on %.0f (dawn 06:00)"
		% RESTART_DAY_B_START_GH,
		bool(out.get("G_restart_b_gh_ok", false))
		and bool(out.get("G_restart_b_day_unchanged", false)))

	# ── ④ ★ 判据牙齿：凌晨死亡必须回"当天"的 mark，不是次日 ──
	host._t("G-RS-midnight death at 03:00 returns %.0f (same day, not next)"
		% RESTART_MIDNIGHT_EXPECTED_GH,
		bool(out.get("G_restart_midnight_ok", false)))

	ts.queue_free()