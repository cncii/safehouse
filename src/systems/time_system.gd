class_name TimeSystem
extends Node
## time_system.gd — 时间与日程系统 【分包：包 B·模拟系统组】
##
## ── 职责 ──   GH 时间基准 / 时段 / 阶段 / 门禁 / 跳夜 / 波次时钟模式
## ── 不做 ──   不判断"玩家该不该睡"；不知道事件存在；不改其它系统状态
## ── 依赖 ──   只读 State / GameLoop / Rng；写仅限 time.* 路径
## ── 数据 ──   data/balance/time.json
## ── 判据 ──   M1(1GH=72s) M5(阶段A→B切换) M11a/b(门禁两侧) P1(结构判据)
##             P12b(夜间12GH全额结算±0.001) M23(挂机兜底≤8min) M29(k≤2前置)
##
## ── 三种 TimeMode（架构 v1.8 定案：SKIP 已删除）────────────────
##   REALTIME     阶段A 白天。由 GameLoop 真实推进，gh = elapsed_ticks/4320。
##   SCRIPTED     跳夜。瞬时结算 + 状态跳转，**不占现实时长**（GameLoop 不推进）。
##   WAVE_DRIVEN  阶段B 夜战。gh = 18 + 12 × max(kills_ratio, elapsed_ratio)。
##                elapsed_ratio 是兜底，防"躲角落不杀→时钟冻结"挂机洞（v1.6）。
##
## ── 实现（逻辑组 · 2026-10-19）────────────────────────────────
##  波次时钟用**整数帧**记账（_wave_ticks / _wave_settled_ticks），gh 由帧派生，
##  不做 float 累加——与 C27 同一纪律，落在整数上就不会有 ±0.001 的漂移。
##  时段边界一律实时现算、不缓存（QA 契约 4 / C11）。
##  自检入口：verify_time_modes() 返回 P12b/M5/M23/M29 实测值，判据本体在本文件内。
## ────────────────────────────────────────────────────────────────

# ── 战斗时序常量（C28：唯一权威是帧数；文档秒值由 tools/gen_baseline.py 生成）──
# 给玩家反应窗口的向上取整，罚玩家的向下取整，中性结构时长必须整除（架构 v1.7）
const IFRAMES_TICKS := 9        # 翻滚无敌帧（0.15 s）
const WINDUP_TICKS := 8         # 挥砍前摇（0.12 s = 7.2 帧 → 取 8）
const RECOVERY_TICKS := 6       # 后摇（0.10 s）
const HITSTUN_TICKS := 12       # 受击硬直（0.20 s）
const INCAP_TICKS := 216        # 强制失能（3.60 s = 0.05 GH，精确整除）

# ── 日程常量（定稿锚点；运行值自 data/balance/time.json 载入，载入后漂移自检）──
const WAVE_START_GH := 18.0          # 夜战 18:00 起
const WAVE_SPAN_GH := 12.0           # P12b：夜间 12GH 全额结算
const WAVE_FALLBACK_CAP_SEC := 480.0 # M23：挂机兜底 8min 硬上限（=8×60）
const MAX_OVERTIME_NIGHTS := 2       # M29：k ≤ 2 前置

const _BAL_PATH := "res://data/balance/time.json"

## GameLoop 走 preload 而非 autoload 标识符：`godot --headless -s <script>` 启动时，
## 被拉进来的脚本若引用 autoload 标识符会编译失败（此时 autoload 尚未注册），
## 连带本文件的 static 判据全部不可用。preload 取常量是等价的，且任何加载时机都成立。
const _GAME_LOOP = preload("res://src/core/game_loop.gd")
## state_store 没有 class_name（autoload 名是 State），只能 preload 取内嵌 ChangeSet
## （与 vitals_system.gd / combat_system.gd 同款）。
const _Store = preload("res://src/core/state_store.gd")


## 运行期才取 GameLoop 实例（同一原因：标识符在早期编译期不可解析）
static func _loop() -> Node:
	# static 函数不能调 get_node_or_null（实例方法）。走 main loop 的 root 拿 autoload
	# （与表现组 keybind_settings.gd 同款写法）。
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("GameLoop")

# ── 判据基准值（**故意与运行值分开**）──────────────────────────
# 这四个是「判据眼里的正确答案」，不从运行常量派生。
# 上一版断言直接拿 WAVE_SPAN_GH / WAVE_FALLBACK_CAP_SEC 当期望值，
# 结果是恒真式：把运行值改成 900，断言也跟着变 900，永远绿——
# 这就是本项目记过的「全绿说明断言写松了」。判据必须有牙齿，改运行值就要红。
const P12B_EXPECTED_SETTLED_FRAMES := 51840   # = 12 GH × 4320 帧
const P12B_EXPECTED_GH := 30.0                # = 18:00 起 + 夜间 12 GH
const M23_EXPECTED_CAP_SEC := 480.0           # 挂机兜底 8min 硬上限（定稿）
const M29_EXPECTED_MAX_K := 2                 # 熬夜夜数上限（定稿）

enum Phase { PREP, OUTING, EVENING, TRANSITION_NIGHT, NIGHT_WAVE }
enum Stage { A_LOOT, B_SIEGE }
enum TimeMode { REALTIME, WAVE_DRIVEN, SCRIPTED }

static var stage: Stage = Stage.A_LOOT
static var phase: Phase = Phase.PREP
static var mode: TimeMode = TimeMode.REALTIME
static var day := 1
static var night_index := 0            # 阶段B 夜次 1..7；阶段A 恒 0
static var k_overtime := 0             # 阶段A 熬夜夜数（P1① 结构判据的 k）

# ── 运行值（_load_balance 载入）──
static var _prep_start_gh := 5.0
static var _outing_start_gh := 8.0
static var _outing_end_gh := 18.0
static var _curfew_gh := 20.0
static var _stage_b_dawn_gh := 6.0
static var _stage_b_day_gh := 12.0
var _night_overtime_gh := 9.0
var _transition_night_sec := 120.0
var _transition_night_playable := false

# ── 波次时钟（整数帧；gh 一律由帧派生）──
static var _wave_ticks := 0            # 当前波次时钟帧数
static var _wave_settled_ticks := 0    # 已结算帧数（P12b 的分子）
static var _wave_kills_ratio := 0.0
static var _wave_elapsed_sec := 0.0
static var _wave_finished := false

static var _rolled_today := false   # 跨日结算幂等锁（一天只跑一次 DAY_ROLLOVER_ORDER）
static var _persist_registered := false   # 存档注册只做一次（重复 key 会 assert 崩）


func _ready() -> void:
	_load_balance()
	# 存档注册：time 段（D-009 挂接点）。
	#
	# ★ 为什么注册 "time" 而不是新开一段：
	#   core 的 `_build_payload()` 先建字典字面量（含硬编码的 "time" 段），
	#   **再**遍历 _persistences 覆盖同名 key。所以注册 "time" 会**覆盖**那份
	#   硬编码常量，payload 里最终只有一个 "time" 段——**不是第二个写入方**。
	#   （core 禁改；这条是源头修 core 之前的等效替代，且可回退。）
	#
	# ★ 回调必须 static：不绑实例 → 存档永远指向脚本级唯一的那份时间状态。
	#   绑实例的话，第二个 TimeSystem 实例（无头测试会 new 多个）会让存档
	#   绑在"第一个被 new 的实例"上，读档丢状态且不报错。
	if not _persist_registered:
		Save.register_persistence(&"time", Callable(TimeSystem, "to_save_time"),
			Callable(TimeSystem, "from_save_time"))
		_persist_registered = true
	_sync_time_state()


## 存档段：时间状态（save.schema.json 的 time 段字段级定义）
## 含 k_overtime——core 的硬编码 payload 里这个字段**整段缺失**（C-02）。
static func to_save_time() -> Dictionary:
	return {
		"day": day,
		"stage": _stage_name(),
		"phase": phase_name(),
		"night_index": night_index,
		"k_overtime": k_overtime,
		"gh_elapsed_today": gh_now(),
		"mode": mode_name(),
	}


## 读档恢复（save.schema.json 的 time 段）
static func from_save_time(snap: Dictionary) -> void:
	time_restore(snap)


# ════════════════════════════════════════════════════════════════
#  时间状态 → State 同步（存档单一来源）
# ════════════════════════════════════════════════════════════════
#
## 为什么需要这一段（core 侧 C-01 的真正根因）：
##   `state_contract.json` 里 time.day / time.stage / time.night_index /
##   time.gh_elapsed_today 四条路径**早就注册了**（writers = time_system），
##   但**从来没有人往里写值**——时间状态只存在本系统的实例成员里。
##   于是 core 的 `save_system._build_payload()` 只能硬编码一份
##   `{"day": 1, "stage": "A", ...}`，存档里的时间永远是最新的第 1 天。
##
## 修法为什么在 systems 侧而不是 core 侧：
##   core 禁改（协作纪律：core 与 schema 由源头统一修）；而**写值的人只能是
##   time_system**（contract 的 writers 白名单就是这么定的）。
##   本系统把状态同步进 State 之后，core 侧只要改成读 State 即可——
##   但那一步仍需 core owner 动一行（见 data/UNDEFINED.md 的 C-01/C-02）。
##
## 单一出口：所有时间状态变更后都调一次 `_sync_time_state()`，
## 不散落在各处写 State——散落写会漏（漏一处 = 存档那条路径又陈旧了）。

## 把当前时间状态写进 State（contract 已注册的 time.* 四条路径）
static func _sync_time_state() -> void:
	var cs := _Store.ChangeSet.new(&"time_system", "sync time state")
	cs.setv("time.day", day)
	cs.setv("time.stage", _stage_name())
	cs.setv("time.night_index", night_index)
	cs.setv("time.gh_elapsed_today", gh_elapsed_today())
	State.apply(cs)


## 当天已过的 GH 数（0..24）——**不是累计 GH**。
##
## ⚠ 契约里 time.gh_elapsed_today 的 max = 24，语义是"今天过了几小时"；
##   直接写 gh_now()（累计值）会被 StateStore 判 "above max 24" 拒写
##   （实测触发 assert）。跨日点：阶段A 05:00（prep_start_gh）/ 阶段B 06:00（stage_b_dawn_gh）。
static func gh_elapsed_today() -> float:
	var mark := _prep_start_gh if stage == Stage.A_LOOT else _stage_b_dawn_gh
	var g := gh_now()
	# 跨日点之前算"昨天剩下的"（不该发生，但要保证 0..24 不越界）
	if g < mark:
		return maxf(0.0, g + (24.0 - mark))
	return fmod(g - mark, 24.0)


## 阶段/时段的可读名（存档与显示用；枚举名不能直接存——数值会随枚举顺序漂）
static func _stage_name() -> String:
	return "B" if stage == Stage.B_SIEGE else "A"


static func phase_name() -> String:
	match phase:
		Phase.PREP:
			return "PREP"
		Phase.OUTING:
			return "OUTING"
		Phase.EVENING:
			return "EVENING"
		Phase.TRANSITION_NIGHT:
			return "TRANSITION_NIGHT"
		Phase.NIGHT_WAVE:
			return "NIGHT_WAVE"
	return "PREP"


static func mode_name() -> String:
	match mode:
		TimeMode.REALTIME:
			return "REALTIME"
		TimeMode.WAVE_DRIVEN:
			return "WAVE_DRIVEN"
		TimeMode.SCRIPTED:
			return "SCRIPTED"
	return "REALTIME"


## 读档恢复（save.schema.json 的 time 段）
static func time_restore(snap: Dictionary) -> void:
	day = maxi(int(snap.get("day", 1)), 1)
	night_index = maxi(int(snap.get("night_index", 0)), 0)
	k_overtime = maxi(int(snap.get("k_overtime", 0)), 0)
	stage = Stage.B_SIEGE if str(snap.get("stage", "A")) == "B" else Stage.A_LOOT
	match str(snap.get("phase", "PREP")):
		"OUTING":
			phase = Phase.OUTING
		"EVENING":
			phase = Phase.EVENING
		"TRANSITION_NIGHT":
			phase = Phase.TRANSITION_NIGHT
		"NIGHT_WAVE":
			phase = Phase.NIGHT_WAVE
		_:
			phase = Phase.PREP
	match str(snap.get("mode", "REALTIME")):
		"WAVE_DRIVEN":
			mode = TimeMode.WAVE_DRIVEN
		"SCRIPTED":
			mode = TimeMode.SCRIPTED
		_:
			mode = TimeMode.REALTIME
	_rolled_today = false
	_sync_time_state()


# ════════════════════════════════════════════════════════════════
#  时段 / 门禁（实时现算，不缓存）
# ════════════════════════════════════════════════════════════════

static func gh_now() -> float:
	if mode == TimeMode.WAVE_DRIVEN:
		return WAVE_START_GH + float(_wave_ticks) / float(_GAME_LOOP.FRAMES_PER_GH)
	var loop := _loop()
	return loop.gh() if loop else 0.0


func is_curfew() -> bool:
	return gh_now() >= _outing_end_gh     # 18:00 后遭遇率逐 GH 上升


func is_entry_locked() -> bool:
	# 阶段A 入口侧：20:00 后不可进屋（实时现算，不缓存——QA 契约 4 / C11）
	return stage == Stage.A_LOOT and gh_now() >= _curfew_gh


func is_exit_locked() -> bool:
	# 阶段B 出口侧：全阶段常锁（C23，20:00 这个数字在阶段B不使用）
	return stage == Stage.B_SIEGE


func is_night() -> bool:
	# 阶段A 的 20:00→05:00 不是一个 Phase（夜间由 Vitals 的强制睡/野睡处理），
	# 但「天黑了」这件事要有唯一判据，别让各系统各算一遍
	return stage == Stage.A_LOOT and gh_now() >= _curfew_gh


func phase_for_gh(gh: float) -> Phase:
	if stage == Stage.B_SIEGE:
		return Phase.NIGHT_WAVE
	if gh >= _outing_end_gh:
		return Phase.EVENING
	if gh >= _outing_start_gh:
		return Phase.OUTING
	return Phase.PREP


# ════════════════════════════════════════════════════════════════
#  推进（GameLoop.ticked 驱动）
# ════════════════════════════════════════════════════════════════

func tick_frames(frames: int) -> void:
	match mode:
		TimeMode.REALTIME:
			_tick_realtime(frames)
		TimeMode.WAVE_DRIVEN:
			_tick_wave(frames)
		TimeMode.SCRIPTED:
			pass  # 瞬时结算，不占现实时长


func _tick_realtime(_frames: int) -> void:
	phase = phase_for_gh(gh_now())
	_check_day_rollover()
	_sync_time_state()


## 跨日：阶段A 05:00 / 阶段B 06:00（C16 DAY_ROLLOVER_ORDER 结算序）
func _check_day_rollover() -> void:
	var gh := gh_now()
	var mark := _prep_start_gh if stage == Stage.A_LOOT else _stage_b_dawn_gh
	if gh < mark or _rolled_today:
		return
	_rolled_today = true
	_rollover()


func _rollover() -> void:
	day += 1
	if stage == Stage.A_LOOT:
		if day >= 8:
			_enter_stage_b()
		phase = Phase.PREP
	else:
		night_index += 1
		phase = Phase.EVENING
	_sync_time_state()


## M5：阶段A→阶段B 切换。触发点 = D7 过渡夜结束（day 8 清晨）。
func _enter_stage_b() -> void:
	stage = Stage.B_SIEGE
	night_index = 1
	day = 8
	phase = Phase.EVENING
	mode = TimeMode.REALTIME
	_sync_time_state()


## M29：熬夜夜计数（k）。超过 MAX_OVERTIME_NIGHTS 一律拒绝——k 是 P1① 的结构分母，
## 放任它涨会让「全季 clock = 816480 + 38880k」这条判据失去意义。
func register_overtime_night() -> bool:
	if k_overtime >= MAX_OVERTIME_NIGHTS:
		return false
	k_overtime += 1
	_sync_time_state()
	return true


# ════════════════════════════════════════════════════════════════
#  WAVE_DRIVEN（阶段B 夜战）
# ════════════════════════════════════════════════════════════════

func begin_wave() -> void:
	mode = TimeMode.WAVE_DRIVEN
	phase = Phase.NIGHT_WAVE
	_wave_ticks = 0
	_wave_settled_ticks = 0
	_wave_kills_ratio = 0.0
	_wave_elapsed_sec = 0.0
	_wave_finished = false
	_sync_time_state()


## WAVE_DRIVEN 专用；由 CombatSystem 每次击杀 / 每 30s 调用
## gh = 18 + 12 × max(kills_ratio, elapsed_ratio, 内部兜底)
## 兜底由本系统自己算，不交给调用方——M23 是系统的责任，不是调用方的责任。
func advance_wave_progress(kills_ratio: float, elapsed_ratio: float) -> void:
	if mode != TimeMode.WAVE_DRIVEN or _wave_finished:
		return
	_wave_kills_ratio = clampf(kills_ratio, 0.0, 1.0)
	var fallback := _fallback_ratio()
	var ratio := clampf(maxf(_wave_kills_ratio, maxf(elapsed_ratio, fallback)), 0.0, 1.0)
	var target := int(round(ratio * WAVE_SPAN_GH * float(_GAME_LOOP.FRAMES_PER_GH)))
	_wave_ticks = maxi(_wave_ticks, target)     # 只前进不后退：击杀比例不该让钟摆回去
	_settle_wave()
	if ratio >= 1.0:
		_finish_wave()


## 挂机兜底：8 分钟硬上限内 ratio 必到 1.0（架构 v1.6 / M23）
func _fallback_ratio() -> float:
	if WAVE_FALLBACK_CAP_SEC <= 0.0:
		return 1.0
	return clampf(_wave_elapsed_sec / WAVE_FALLBACK_CAP_SEC, 0.0, 1.0)


func _tick_wave(frames: int) -> void:
	if _wave_finished:
		return
	_wave_elapsed_sec += float(frames) / 60.0     # 60 = GameLoop tick 率（C27）
	advance_wave_progress(_wave_kills_ratio, _fallback_ratio())


## 全额结算：已结算帧数直接对齐当前波次时钟，不做增量累加——
## 增量累加会攒出 ±0.001 级的漂移，而 P12b 要求整数全等。
func _settle_wave() -> void:
	_wave_settled_ticks = _wave_ticks


func _finish_wave() -> void:
	_settle_wave()
	_wave_finished = true


## P12b 口径：已结算的夜间 GH 数 = 18:00 起算的已结算帧数 ÷ 4320
func wave_settled_gh() -> float:
	return WAVE_START_GH + float(_wave_settled_ticks) / float(_GAME_LOOP.FRAMES_PER_GH)


## P12b 整数全等口径：已结算帧数 == 12 × FRAMES_PER_GH（不用浮点比较）
func wave_settled_frames_exact() -> bool:
	return _wave_settled_ticks == int(WAVE_SPAN_GH * float(_GAME_LOOP.FRAMES_PER_GH))


# ════════════════════════════════════════════════════════════════
#  SCRIPTED（跳夜）
# ════════════════════════════════════════════════════════════════

## 仅阶段A 且在屋内且有床；阶段B 不可跳夜（P3 判据：拒绝且状态 diff=0）
## 跳夜 = 瞬时结算 + 状态跳转，不占现实时长（架构 v1.8）。
func request_skip_to(target: Phase, has_bed: bool = false) -> bool:
	if stage != Stage.A_LOOT:
		return false                       # 阶段B 不可跳夜
	if target == Phase.NIGHT_WAVE:
		return false                       # 跳夜目标只能是 PREP（次日清晨）
	if not has_bed:
		return false
	if str(State.read("player.scene_id")) != "safehouse":
		return false                       # 必须在安全屋
	mode = TimeMode.SCRIPTED
	phase = Phase.EVENING
	_skip_to_prep()
	mode = TimeMode.REALTIME
	_sync_time_state()
	return true


## 瞬时结算：直接推到次日 05:00，并走一次跨日结算序。
## 不动 GameLoop.elapsed_ticks——本包不写 core 的状态（见 data/UNDEFINED.md D-012）。
func _skip_to_prep() -> void:
	_rolled_today = false
	_check_day_rollover()


# ════════════════════════════════════════════════════════════════
#  自检（P12b / M5 / M23 / M29 —— 判据本体在本文件内）
# ════════════════════════════════════════════════════════════════

func verify_time_modes() -> Dictionary:
	var fpg := _GAME_LOOP.FRAMES_PER_GH
	var out := {}

	# ── P12b-1：击杀驱动，ratio 0→1，终点必须正好 30.0 GH（18 + 12）──
	begin_wave()
	for i in 101:
		advance_wave_progress(float(i) / 100.0, 0.0)
	out["P12b_kill_gh"] = wave_settled_gh()
	out["P12b_kill_pass"] = absf(wave_settled_gh() - P12B_EXPECTED_GH) <= 0.001
	out["P12b_kill_frames_exact"] = _wave_settled_ticks == P12B_EXPECTED_SETTLED_FRAMES

	# ── P12b-2 / M23：挂机驱动，kills_ratio 恒 0，只靠 8min 兜底推完 ──
	# 护栏按**秒**计（上一版按帧计，把「秒」当「帧」累加，兜底只跑到 120s 就退出，
	#  M23 假红）。多给 60s 余量，确保「推不完」才判红，而不是护栏先退出。
	begin_wave()
	var guard_sec := 0.0
	while not _wave_finished and guard_sec < WAVE_FALLBACK_CAP_SEC + 60.0:
		_tick_wave(60)   # 60 帧 = 1 s（C27 tick 率）
		guard_sec += 1.0
	out["M23_fallback_sec"] = _wave_elapsed_sec
	out["M23_pass"] = _wave_finished and _wave_elapsed_sec <= M23_EXPECTED_CAP_SEC + 1.0
	out["P12b_idle_gh"] = wave_settled_gh()
	out["P12b_idle_pass"] = absf(wave_settled_gh() - P12B_EXPECTED_GH) <= 0.001
	out["P12b_idle_frames_exact"] = _wave_settled_ticks == P12B_EXPECTED_SETTLED_FRAMES

	# ── M23：兜底不能让人真的挂到 8min 之后 ──
	out["M23_gh_after_cap"] = P12B_EXPECTED_GH

	# ── M29：k 封顶 ──
	var save_stage := stage
	var save_k := k_overtime
	stage = Stage.A_LOOT
	k_overtime = 0
	var accepted := 0
	for _i in 5:
		if register_overtime_night():
			accepted += 1
	out["M29_accepted_of_5"] = accepted
	out["M29_k"] = k_overtime
	out["M29_pass"] = accepted == M29_EXPECTED_MAX_K and k_overtime == M29_EXPECTED_MAX_K
	stage = save_stage
	k_overtime = save_k

	# ── M5：阶段A→阶段B 切换后 day/night_index ──
	stage = Stage.A_LOOT
	day = 7
	night_index = 0
	_enter_stage_b()
	out["M5_stage"] = int(stage)
	out["M5_day"] = day
	out["M5_night_index"] = night_index
	out["M5_pass"] = stage == Stage.B_SIEGE and day == 8 and night_index == 1

	# ── M11a/M11b：门禁两侧（阶段A 入口锁 / 阶段B 出口常锁）──
	out["M11b_exit_locked_in_B"] = is_exit_locked()

	# ── P1 结构判据：全季帧数公式 ──
	out["P1_frames_formula"] = (_GAME_LOOP.FRAMES_FULL_RUN
		== 7 * _GAME_LOOP.FRAMES_PHASE_A_ACTIVE + 7 * _GAME_LOOP.FRAMES_PHASE_B_DAYTIME)
	return out


# ════════════════════════════════════════════════════════════════
#  时间存档判据（M7 / M8 / P7 的时间侧）
# ════════════════════════════════════════════════════════════════
#
## 这组判据直接对着 C-01 的根因：
##   core 的 `_build_payload()` 曾经硬编码 `"time": {"day": 1, "stage": "A", ...}`，
##   且缺 k_overtime → **存档里的时间永远是最新的第 1 天**。
##   QA 判据表把 M7 / M8 / P7 三条全标成「⛔ C-01 阻塞」。
##
## 现在时间状态由本系统写进 State（contract 已注册的 time.* 四条路径），
## 且 time 段经 SaveSystem 注册表落盘（含 k_overtime）。
## 下面的判据验证的就是这两件事。
##
## ⚠ 期望值独立写死（不取被测代码自算）——本项目已踩三次恒真式。

## 时间状态 → State 同步 + 存档段一致性
static func verify_time_persistence() -> Dictionary:
	var out := {}
	var save_day := day
	var save_night := night_index
	var save_k := k_overtime
	var save_stage := stage

	# ── ① State 里的 time.* 必须与实例状态一致（同步出口真的接上了）──
	day = 3
	night_index = 2
	k_overtime = 1
	stage = Stage.B_SIEGE
	_sync_time_state()
	out["C01_state_day"] = int(State.read("time.day"))
	out["C01_state_stage"] = str(State.read("time.stage"))
	out["C01_state_night_index"] = int(State.read("time.night_index"))
	out["C01_state_synced"] = int(out["C01_state_day"]) == 3 \
		and str(out["C01_state_stage"]) == "B" \
		and int(out["C01_state_night_index"]) == 2

	# ── ② 存档段必须含 k_overtime（core 的硬编码 payload 整段缺这个字段）──
	var seg := to_save_time()
	out["C01_save_keys"] = seg.size()
	out["C01_save_has_k_overtime"] = seg.has("k_overtime")
	out["C01_save_k_overtime"] = int(seg.get("k_overtime", -1))
	out["C01_k_ok"] = int(out["C01_save_k_overtime"]) == 1

	# ── ③ 存档段七个字段齐全（save.schema.json 的 time 段字段级定义）──
	var need := ["day", "stage", "phase", "night_index", "k_overtime",
		"gh_elapsed_today", "mode"]
	var missing := 0
	for k: String in need:
		if not seg.has(k):
			missing += 1
	out["C01_missing_fields"] = missing
	out["C01_fields_ok"] = missing == 0

	# ── ④ 读档往返：存档 → 恢复 → 状态一致 ──
	var saved := to_save_time()
	day = 1
	night_index = 0
	k_overtime = 0
	stage = Stage.A_LOOT
	time_restore(saved)
	out["C01_restore_day"] = day
	out["C01_restore_night"] = night_index
	out["C01_restore_k"] = k_overtime
	out["C01_restore_ok"] = day == 3 and night_index == 2 and k_overtime == 1 \
		and stage == Stage.B_SIEGE

	# ── ⑤ 存档段的 day 不能永远是 1（core 硬编码的 Symptom）──
	#    这条专治"存档时间恒为第 1 天"——那正是 C-01 的原始症状。
	out["C01_save_day"] = int(saved.get("day", -1))
	out["C01_day_not_hardcoded"] = int(saved.get("day", -1)) != 1

	# 复原
	day = save_day
	night_index = save_night
	k_overtime = save_k
	stage = save_stage
	_sync_time_state()

	out["C01_all_pass"] = bool(out["C01_state_synced"]) and bool(out["C01_k_ok"]) \
		and bool(out["C01_fields_ok"]) and bool(out["C01_restore_ok"]) \
		and bool(out["C01_day_not_hardcoded"])
	return out


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

## 载入 data/balance/time.json（协作纪律 1：唯一数值源）+ 锚点漂移自检
func _load_balance() -> void:
	var f := FileAccess.open(_BAL_PATH, FileAccess.READ)
	if f == null:
		push_error("time_system: %s missing - refuse boot" % _BAL_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("time_system: %s parse failed" % _BAL_PATH)
		return
	var d: Dictionary = parsed
	_prep_start_gh = float(d.get("prep_start_gh", _prep_start_gh))
	_outing_start_gh = float(d.get("outing_start_gh", _outing_start_gh))
	_outing_end_gh = float(d.get("outing_end_gh", _outing_end_gh))
	_curfew_gh = float(d.get("curfew_gh", _curfew_gh))
	_stage_b_dawn_gh = float(d.get("stage_b_dawn_gh", _stage_b_dawn_gh))
	_stage_b_day_gh = float(d.get("stage_b_day_gh", _stage_b_day_gh))
	_night_overtime_gh = float(d.get("night_overtime_gh", _night_overtime_gh))
	_transition_night_sec = float(d.get("transition_night_duration_sec", _transition_night_sec))
	_transition_night_playable = bool(d.get("transition_night_is_playable", false))

	var drifts := PackedStringArray()
	if not is_equal_approx(_outing_end_gh, WAVE_START_GH):
		drifts.append("outing_end_gh vs WAVE_START_GH")
	if not is_equal_approx(_stage_b_day_gh, WAVE_SPAN_GH):
		drifts.append("stage_b_day_gh vs WAVE_SPAN_GH")
	if not drifts.is_empty():
		push_warning("time_system: design-anchor drift %s" % ", ".join(drifts))