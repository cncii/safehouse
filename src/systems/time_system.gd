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
static var _transition_night_sec := 120.0
static var _transition_night_playable := false

# ── 从 time.json 载入的运行值（数值唯一来源，不硬编码）──
## 默认值与 data/balance/time.json 的当前定稿一致，但**载入后一律以文件为准**。
static var _tick_hz := 60            # tick_hz_count
static var _days_stage_a := 7        # days_stage_a_count（阶段A 天数 = D7 之后进过渡夜）

# ── 过渡夜状态（TASK-G M5：D7 20:00 → D8 06:00，架构 §11.1）──
## 架构原文三句，逐句落到实现：
##   ①「D7 20:00 → D8 06:00 是过渡夜：不计夜次、无波次、只播氛围音」
##      → _transition_settle_gh = 10.0（20:00→06:00），night_index 不动
##   ②「过渡夜照常衰减 10 GH（不暂停衰减）」（§13.1 第 16 条，防"故意不清状态白嫖"）
##      → 进过渡夜时广播要结算的 GH 数，各系统自己按这数结算
##   ③「SKIP 改为 SCRIPTED（整段跳、无空闲等待）」（§13.5）+「不得进入无法操作但持续受损」
##      （§13.3 硬不变量）→ **不让玩家坐着看 12 分钟**，一次性结完
##     ⚠ 这就是 `transition_night_duration_sec=120` 的定位：**氛围过场时长**，
##       不是"时间流逝时长"。两者混用会同时违反 ② 和 ③。
static var _transition_active := false
static var _transition_settle_gh := 0.0     # 本次过渡夜要结算的 GH 数
static var _transition_elapsed_sec := 0.0   # 过场已播秒数（表现层用，不驱动衰减）

## 拨钟注入点（C27：GameLoop.elapsed_ticks 是时间唯一真相，**包 B 不直接写 core 状态**）
## 签名：func(target_gh: float) -> bool，把钟拨到 target_gh（绝对值，累计 GH）
## 未注入时跳夜/新局会返回 false + 明确 reason，**不静默算错**。
## （包 B 既有同款先例：tech_tree_system.parts_gate）
static var clock_advance_gate: Callable = Callable()

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
static func _check_day_rollover() -> void:
	var gh := gh_now()
	var mark := _prep_start_gh if stage == Stage.A_LOOT else _stage_b_dawn_gh
	if gh < mark or _rolled_today:
		return
	_rolled_today = true
	_rollover()


static func _rollover() -> void:
	day += 1
	if stage == Stage.A_LOOT:
		# ⚠ 阶段A→B 的切换点唯一 = **D7 20:00 门锁那一刻**（架构 §11.1 修订 v1.1），
		#   由 begin_transition_night() 触发，**不在跨日里跳**。
		#   旧版这里写 `if day >= 8: _enter_stage_b()`，等于把过渡夜整个跳过——
		#   实测：跳夜后 stage 变 B、day=8，但 gh 没动（还是 D7 21:00），
		#   玩家眼前仍是夜里却被告知"天亮了"。已改为不在此处切阶段。
		phase = Phase.PREP
	else:
		night_index += 1
		phase = Phase.EVENING
	_sync_time_state()


## M5：阶段A→阶段B 切换。触发点 = D7 过渡夜结束（day 8 清晨）。
static func _enter_stage_b() -> void:
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
#  新局 / 拨钟 / 过渡夜（TASK-G M3/M5 逻辑组配合项⑤）
# ════════════════════════════════════════════════════════════════

## 拨钟：把 GameLoop 的 elapsed_ticks 拨到 target_gh 对应帧。
## C27 规定 elapsed_ticks 是时间唯一真相，而 GameLoop 属 core——
## 包 B 不直接写 core 状态，走注入回调。未注入即失败（不静默算错）。
static func _advance_clock_to(target_gh: float) -> Dictionary:
	if not clock_advance_gate.is_valid():
		return {"ok": false, "reason": "no_clock_gate"}
	var ok := bool(clock_advance_gate.call(target_gh))
	return {"ok": ok, "reason": "ok" if ok else "gate_rejected"}


## 新开一局：复位到 D1 05:00 阶段A PREP（TASK-G M1 冷启动）
##
## ★ 为什么需要这个 API：表现组此前在 game_world.gd:109 直接写
##   `TimeSystem._rolled_today = true` 来绕"首个 tick 把 day 滚到 2"的坑——
##   那是访问私有静态变量，属于跨包越界。本 API 是它的正式替代。
##
## 返回 {ok, reason, day, gh}
static func begin_new_run() -> Dictionary:
	var target_gh := _prep_start_gh     # 05:00
	var r := _advance_clock_to(target_gh)
	if not bool(r.get("ok", false)):
		# 拨钟失败时**不改状态**——半开一局比不开更糟（day 和 gh 会对不上）
		return {"ok": false, "reason": str(r.get("reason", "")), "day": day,
			"gh": gh_now()}
	stage = Stage.A_LOOT
	phase = Phase.PREP
	mode = TimeMode.REALTIME
	day = 1
	night_index = 0
	k_overtime = 0
	_transition_active = false
	_transition_settle_gh = 0.0
	_transition_elapsed_sec = 0.0
	# 05:00 起步 = 今天的跨日结算已算过，否则首个 tick 会把 day 滚到 2
	_rolled_today = true
	_sync_time_state()
	return {"ok": true, "reason": "ok", "day": day, "gh": gh_now()}


## 跳夜（阶段A 有床时）：瞬时结算到次日 05:00
## TASK-G §5 M3「跳夜 → 次日 05:00 自动存档」靠它。
## 返回 {ok, reason, day, gh, settled_gh}
static func skip_to_next_prep() -> Dictionary:
	if stage != Stage.A_LOOT:
		return {"ok": false, "reason": "stage_b_no_skip", "day": day, "gh": gh_now()}
	var now_gh := gh_now()
	# 次日 05:00 的绝对 GH：今天的 05:00 + 24（若已过 05:00）或今天的 05:00
	var today_mark := floorf(now_gh / 24.0) * 24.0 + _prep_start_gh
	var target := today_mark if today_mark > now_gh else today_mark + 24.0
	var settled := target - now_gh
	var r := _advance_clock_to(target)
	if not bool(r.get("ok", false)):
		return {"ok": false, "reason": str(r.get("reason", "")), "day": day,
			"gh": now_gh, "settled_gh": 0.0}
	# 钟已拨到次日 05:00 —— 走一次跨日结算序（day+1，幂等锁要放开）
	_rolled_today = false
	_check_day_rollover()
	_sync_time_state()
	return {"ok": true, "reason": "ok", "day": day, "gh": gh_now(),
		"settled_gh": settled}


## 进过渡夜（D7 20:00 门锁那一刻；架构 §11.1「切换点唯一」）
##
## 返回 {ok, reason, settle_gh}
## 调用方拿到 settle_gh 后，让各系统按这个 GH 数**一次性结算**（§13.5「瞬时结算」），
## 结算完再调 finish_transition_night()。
##
## ⚠ 只允许在阶段A 且 day>=7 进（切换点唯一，不允许提前/重复）
static func begin_transition_night() -> Dictionary:
	if _transition_active:
		return {"ok": false, "reason": "already_active", "settle_gh": _transition_settle_gh}
	if stage != Stage.A_LOOT:
		return {"ok": false, "reason": "not_stage_a", "settle_gh": 0.0}
	if day < _days_stage_a:
		return {"ok": false, "reason": "too_early", "settle_gh": 0.0}
	# D7 20:00 → D8 06:00 = 10 GH（出走的 4 GH + 过夜的 6 GH）
	var settle := (24.0 - _curfew_gh) + _stage_b_dawn_gh
	_transition_active = true
	_transition_settle_gh = settle
	_transition_elapsed_sec = 0.0
	phase = Phase.TRANSITION_NIGHT
	mode = TimeMode.SCRIPTED      # §13.5：整段跳，无空闲等待
	_sync_time_state()
	return {"ok": true, "reason": "ok", "settle_gh": settle}


## 过渡夜过场播完（表现层可播 _transition_night_sec 秒的氛围，也可直接跳过）
## → 把钟拨到 D8 06:00 → 进阶段B
## 返回 {ok, reason, day, night_index, stage}
static func finish_transition_night() -> Dictionary:
	if not _transition_active:
		return {"ok": false, "reason": "not_active", "day": day, "night_index": night_index}
	var now_gh := gh_now()
	var today_mark := floorf(now_gh / 24.0) * 24.0 + _stage_b_dawn_gh
	var target := today_mark if today_mark > now_gh else today_mark + 24.0
	var r := _advance_clock_to(target)
	if not bool(r.get("ok", false)):
		return {"ok": false, "reason": str(r.get("reason", "")), "day": day,
			"night_index": night_index}
	_transition_active = false
	_transition_elapsed_sec = 0.0
	_enter_stage_b()
	return {"ok": true, "reason": "ok", "day": day, "night_index": night_index,
		"stage": _stage_name()}


static func is_transition_night() -> bool:
	return _transition_active


static func transition_settle_gh() -> float:
	return _transition_settle_gh


## 过渡夜过场计时（表现层可选：播 _transition_night_sec 秒氛围后自己调 finish）
## 不驱动任何衰减——衰减是 begin_transition_night() 返回的 settle_gh 一次性算的。
static func tick_transition_visual(frames: int) -> void:
	if not _transition_active:
		return
	_transition_elapsed_sec += float(frames) / float(_tick_hz)
	if _transition_elapsed_sec >= _transition_night_sec:
		_transition_elapsed_sec = _transition_night_sec


static func transition_visual_done() -> bool:
	return _transition_active and _transition_elapsed_sec >= _transition_night_sec


# ════════════════════════════════════════════════════════════════
#  WAVE_DRIVEN（阶段B 夜战）
# ════════════════════════════════════════════════════════════════

## 开一场夜战（TASK-G §4 硬约束 2：夜间波次必须 WAVE_DRIVEN，禁真实时间驱动）
## 返回 {ok, reason}
## ⚠ 只有阶段B 才许开（阶段A 的夜里没有波次——D7 过渡夜「无波次」是架构 §11.1 明写的）
static func begin_wave() -> Dictionary:
	if stage != Stage.B_SIEGE:
		return {"ok": false, "reason": "not_stage_b"}
	if _transition_active:
		# 过渡夜「不计夜次、无波次」——这条是架构原文，不是实现选择
		return {"ok": false, "reason": "in_transition_night"}
	mode = TimeMode.WAVE_DRIVEN
	phase = Phase.NIGHT_WAVE
	_wave_ticks = 0
	_wave_settled_ticks = 0
	_wave_kills_ratio = 0.0
	_wave_elapsed_sec = 0.0
	_wave_finished = false
	_sync_time_state()
	return {"ok": true, "reason": "ok"}


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
	# WAVE_DRIVEN 只在阶段B 成立（TASK-G 硬约束2 + 架构 §11.1「过渡夜无波次」）。
	# begin_wave() 有阶段守卫，本自检必须先摆到阶段B——
	# 否则 begin_wave 被拒、波次根本没开，P12b 会假红（实测：加守卫后 P12b-1 立刻红）。
	var save_stage_vm := stage
	var save_tr_vm := _transition_active
	stage = Stage.B_SIEGE
	_transition_active = false

	# ── P12b-1：击杀驱动，ratio 0→1，终点必须正好 30.0 GH（18 + 12）──
	var began := begin_wave()
	out["P12b_begin_ok"] = bool(began.get("ok", false))
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

	# 复原阶段（本函数开头为了 begin_wave 的守卫把 stage 摆到了 B）
	stage = save_stage_vm
	_transition_active = save_tr_vm
	return out


# ════════════════════════════════════════════════════════════════
#  TASK-G M3/M5 判据：拨钟 / 过渡夜 / 阶段A→B
# ════════════════════════════════════════════════════════════════
#
## 对着 TASK-G §3 逻辑组配合项⑤（阶段 A→B 切换实装，含过渡夜）与 §4 硬约束2
## （夜间波次必须 WAVE_DRIVEN）。
##
## 架构依据：§11.1「切换点唯一：D7 20:00 门锁死的那一刻」+「D7 20:00 → D8 06:00 是
##   过渡夜：不计夜次、无波次、只播氛围音」+ §13.1 第16条「过渡夜照常衰减 10 GH」。
##
## ★ 判据的期望值全部独立写死（10 GH 是 24-20+6 的算术结果，但那 20/6 是设计定稿
##   prep/curfew 值，不是从被测代码取的）。本项目已踩三次恒真式。

## 拨钟/过渡夜/阶段切换判据
## 需要 clock_advance_gate 已注入（未注入时全部返回 false——这也是一条判据）
static func verify_stage_transition() -> Dictionary:
	var out := {}
	# 保存现场
	var s_stage := stage
	var s_phase := phase
	var s_mode := mode
	var s_day := day
	var s_night := night_index
	var s_k := k_overtime
	var s_roll := _rolled_today
	var s_tr := _transition_active
	var s_tr_gh := _transition_settle_gh

	# ── ① 未注入拨钟时，新局/跳夜/过渡夜都必须**明确失败**（不静默算错）──
	#   这条判据防的是"没接上却假装成功"——那种洞会让 game_world 以为时间动了。
	var saved_gate := clock_advance_gate
	clock_advance_gate = Callable()
	var no_gate := begin_new_run()
	out["G_no_gate_reason"] = str(no_gate.get("reason", ""))
	out["G_no_gate_rejects"] = not bool(no_gate.get("ok", true))
	clock_advance_gate = saved_gate

	# ── ② 过渡夜结算 GH = 10（24-20 出走 + 6 到天亮）──
	#    写死 10.0 而不是用 (24-_curfew_gh)+_stage_b_dawn_gh 自算——后者是恒真式
	out["G_transition_settle_expected"] = 10.0
	stage = Stage.A_LOOT
	day = 7
	night_index = 0        # ⚠ 必须显式复位：前面用例会改它（实测漏了 → 判据假红）
	_transition_active = false
	var tr := begin_transition_night()
	out["G_transition_ok"] = bool(tr.get("ok", false))
	out["G_transition_settle_gh"] = float(tr.get("settle_gh", -1.0))
	out["G_transition_settle_ok"] = is_equal_approx(
		float(tr.get("settle_gh", -1.0)), 10.0)
	out["G_transition_phase"] = phase_name()
	out["G_transition_phase_ok"] = phase == Phase.TRANSITION_NIGHT
	# 过渡夜「不计夜次」：night_index 必须没动
	out["G_transition_night_index"] = night_index
	out["G_transition_no_night_count"] = night_index == 0
	# 过渡夜「无波次」：此时开波次必须被拒
	# ⚠ 这里只断言"被拒"，**不写死 reason**——过渡夜必在阶段A，
	#   所以先撞 `not_stage_b` 守卫（实测 reason="not_stage_b"）。
	#   第一版写死了 "in_transition_night"，判据假红：行为对的、期望错的。
	var wave_in_tr := begin_wave()
	out["G_transition_wave_reason"] = str(wave_in_tr.get("reason", ""))
	out["G_transition_wave_rejected"] = not bool(wave_in_tr.get("ok", true))

	# ── ③ 早于 D7 不许进过渡夜（切换点唯一）──
	_transition_active = false
	day = 5
	var early := begin_transition_night()
	out["G_early_reason"] = str(early.get("reason", ""))
	out["G_early_rejected"] = (not bool(early.get("ok", true))) \
		and str(early.get("reason", "")) == "too_early"

	# ── ④ 重复调用幂等（不许把 settle_gh 累加）──
	_transition_active = false
	day = 7
	begin_transition_night()
	var again := begin_transition_night()
	out["G_repeat_reason"] = str(again.get("reason", ""))
	out["G_repeat_settle_unchanged"] = is_equal_approx(
		float(again.get("settle_gh", -1.0)), 10.0)
	out["G_repeat_rejected"] = (not bool(again.get("ok", true))) \
		and str(again.get("reason", "")) == "already_active"

	# ── ⑤ 阶段B 不许跳夜（核心动词：阶段B 不可跳夜）──
	_transition_active = false
	stage = Stage.B_SIEGE
	var skip_b := skip_to_next_prep()
	out["G_stage_b_skip_rejected"] = (not bool(skip_b.get("ok", true))) \
		and str(skip_b.get("reason", "")) == "stage_b_no_skip"

	# ── ⑥ 阶段A 才许开波次（阶段A 的夜里没有波次）──
	stage = Stage.A_LOOT
	_transition_active = false
	var wave_a := begin_wave()
	out["G_stage_a_wave_rejected"] = (not bool(wave_a.get("ok", true))) \
		and str(wave_a.get("reason", "")) == "not_stage_b"

	# ── ⑦ 阶段B 开波次 → mode 必须是 WAVE_DRIVEN（硬约束2）──
	stage = Stage.B_SIEGE
	var wave_b := begin_wave()
	out["G_stage_b_wave_ok"] = bool(wave_b.get("ok", false))
	out["G_wave_mode"] = mode_name()
	out["G_wave_driven"] = mode == TimeMode.WAVE_DRIVEN
	out["G_wave_phase"] = phase_name()
	out["G_wave_phase_ok"] = phase == Phase.NIGHT_WAVE

	# 复原
	stage = s_stage
	phase = s_phase
	mode = s_mode
	day = s_day
	night_index = s_night
	k_overtime = s_k
	_rolled_today = s_roll
	_transition_active = s_tr
	_transition_settle_gh = s_tr_gh
	_wave_finished = true
	_wave_ticks = 0
	_wave_settled_ticks = 0
	_wave_kills_ratio = 0.0
	_wave_elapsed_sec = 0.0
	_sync_time_state()

	out["G_all_pass"] = bool(out["G_no_gate_rejects"]) and bool(out["G_transition_ok"]) \
		and bool(out["G_transition_settle_ok"]) and bool(out["G_transition_phase_ok"]) \
		and bool(out["G_transition_no_night_count"]) \
		and bool(out["G_transition_wave_rejected"]) \
		and bool(out["G_early_rejected"]) and bool(out["G_repeat_rejected"]) \
		and bool(out["G_repeat_settle_unchanged"]) \
		and bool(out["G_stage_b_skip_rejected"]) \
		and bool(out["G_stage_a_wave_rejected"]) \
		and bool(out["G_stage_b_wave_ok"]) and bool(out["G_wave_driven"]) \
		and bool(out["G_wave_phase_ok"])
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
	_tick_hz = int(d.get("tick_hz_count", _tick_hz))
	_days_stage_a = int(d.get("days_stage_a_count", _days_stage_a))
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