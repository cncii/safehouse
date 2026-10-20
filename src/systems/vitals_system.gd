class_name VitalsSystem
extends Node
## vitals_system.gd — 四条状态系统 【分包：包 B·模拟系统组】
##
## ── 职责 ──   HP/体力/饥饿/渴的速率结算、归零后果、强制睡/野睡/失能三态机
## ── 不做 ──   不自己推进时间（挂在 GameLoop.gh_crossed / GameLoop.ticked）；不做 UI；不碰背包
## ── 依赖 ──   读 data/balance/survival.json；经 StateStore.apply 写 player.*
## ── 判据 ──   M2(饥饿0→死100±2s) M3(渴0→死66.7s) M2b/M3b(跨零单帧份额)
##              M4/M5(体力5%双路径) M13(每夜硬失能≤1次) M14(同帧结算序)
##              R19-b(不可操作窗口上限) R20(阶段B夜间触底→能量棒+UI预警)
##
## ── 设计定稿（不许改数值，改=设计变更需三方过审）──
##   饥饿 5/GH；渴 7/GH；渴归零每秒 -1%HP；渴归零每秒 -1.5%HP
##   户外野睡 2GH -15HP 体力回 20%；波次失能 3.6s 体力回 10%
##   每夜硬失能(野睡+失能合计)≤1次，第2次起 DeBUFF(锁5%/移速×0.6/能走能吃喝)
##   DeBUFF 唯一解除：吃正餐。能量棒 +25 体力、使用耗时 0.4s(24帧)
##   UI 预警阈值：≤40% 黄 / ≤20% 红+音 / ≤10% 屏幕脉动+心跳 / ≤5% 失能
##
## ── 实现说明（包 B · 2026-10-19）────────────────────────────────
##  取数：data/balance/survival.json 是唯一数值源（协作纪律 1，代码零魔法数）。
##        下方 const 是设计定稿锚点，_load_balance 做漂移自检，不参与运行取数。
##  写入：唯一经 State.apply，source = &"vitals_system"（writers 白名单已注册）。
##        只用 setv 写「已算好的绝对值」——StateStore._authorize 对 op 值本身做
##        min/max 校验，负增量走 add() 会被当成「低于 min」拒掉；绝对值写法既过
##        鉴权又不动 core（core 禁改）。
##  死亡归因：字符串取 ResolveOrder.DAMAGE_SOURCE_ORDER，经 died() 上抛，不落 State ——
##        新增状态路径须先改 state_contract.json 并三方过审（协作纪律 5），本轮不动 schema。
##  可测性：结算数学抽成 static func，tests/run_tests.gd 无头直调（M2/M2b/M3/M3b/M4）。
## ────────────────────────────────────────────────────────────────

## ── 设计定稿锚点（C28：冻结禁改；运行值自 survival.json 载入）──
const HUNGER_RATE_PER_GH := 5.0
const THIRST_RATE_PER_GH := 7.0
const HP_LOSS_HUNGER_PER_SEC := 1.0
const HP_LOSS_THIRST_PER_SEC := 1.5
const FORCED_SLEEP_THRESHOLD_PCT := 5.0
const TICKS_PER_SEC := 60        # C27 帧基（FRAMES_PER_GH = 72s × 60）
const HP_MILLI := 1000           # C26 milli 定点：1 HP = 1000 milli

const _BAL_PATH := "res://data/balance/survival.json"
const _Store = preload("res://src/core/state_store.gd")

signal died(cause: String)                   # cause ∈ ResolveOrder.DAMAGE_SOURCE_ORDER
signal forced_sleep_triggered(path: String)  # "threshold" | "wild"

# ── 运行值（_load_balance 自 survival.json 载入）──
var _hp_max := 100.0
var _stamina_max := 100.0
var _hunger_max := 100.0
var _thirst_max := 100.0
var _hunger_rate_per_gh := HUNGER_RATE_PER_GH
var _thirst_rate_per_gh := THIRST_RATE_PER_GH
var _hp_loss_hunger_per_sec := HP_LOSS_HUNGER_PER_SEC
var _hp_loss_thirst_per_sec := HP_LOSS_THIRST_PER_SEC
var _forced_sleep_threshold_pct := FORCED_SLEEP_THRESHOLD_PCT
var _wild_sleep_duration_gh := 2.0
var _wild_sleep_hp_penalty_hp := 15.0
var _wild_sleep_stamina_refill_pct := 20.0
var _incap_duration_frames := 216
var _incap_stamina_refill_pct := 10.0

var _frac_hunger := 0.0          # 整 GH 边界结算的余数（定点化前置）
var _frac_thirst := 0.0
var _frac_hp_hunger_milli := 0.0 # 饥饿归零 HP 扣血的 milli 余数（M2b）
var _frac_hp_thirst_milli := 0.0 # 渴归零 HP 扣血的 milli 余数（M3b）

var night_incap_count := 0       # 每夜硬失能计数（跨 05:00 重置；阶段B 06:00）
var _forced_sleep_latched := false   # M13 一次性锁存：触发即置，离开 ≤5% 才复位
var _wild_sleep_death_pending := false
var _death_fired := false
var last_death_cause := ""


func _ready() -> void:
	_load_balance()
	# GameLoop 走运行期查找而非 autoload 标识符：`-s` 无头启动时被拉进来的脚本
	# 引用 autoload 标识符会编译失败，连带本文件的 static 判据全部不可用。
	var loop := get_node_or_null("/root/GameLoop")
	if loop:
		if not loop.ticked.is_connected(on_frames):
			loop.ticked.connect(on_frames)
		if not loop.gh_crossed.is_connected(on_gh_crossed):
			loop.gh_crossed.connect(on_gh_crossed)


# ════════════════════════════════════════════════════════════════
#  结算点
# ════════════════════════════════════════════════════════════════

## 每整 GH 边界结算（GameLoop.gh_crossed 驱动）
func on_gh_crossed(gh_mark: int) -> void:
	if _death_fired:
		return
	# 结算序硬约束：必须走 ResolveOrder.STATUS_RESOLVE_ORDER，禁止字典遍历
	for step: String in ResolveOrder.STATUS_RESOLVE_ORDER:
		match step:
			"hunger":
				_apply_hunger()
			"thirst":
				_apply_thirst()
			"hp_floor":
				_check_death()
			"status_effects":
				pass  # TODO 包 B：出血 buff（expires_at_gh）
			"forced_sleep":
				_check_forced_sleep()


## 每帧结算（GameLoop.ticked 驱动）——归零扣血必须按帧，不能按秒整块
func on_frames(_frames: int) -> void:
	if _death_fired:
		return
	_tick_hp_drain()
	_check_death()


# ════════════════════════════════════════════════════════════════
#  饥饿 / 渴（GH 边界）
# ════════════════════════════════════════════════════════════════

func _apply_hunger() -> void:
	# 速率结算余数进 _frac_hunger（定点化前置）：整数部分一次扣，余数留到下次
	var debt := _hunger_rate_per_gh + _frac_hunger
	var whole := floorf(debt)
	_frac_hunger = debt - whole
	var cur := float(State.read("player.hunger"))
	_write_float("player.hunger", cur - whole, _hunger_max,
		"hunger drain %.1f/GH" % _hunger_rate_per_gh)


func _apply_thirst() -> void:
	var debt := _thirst_rate_per_gh + _frac_thirst
	var whole := floorf(debt)
	_frac_thirst = debt - whole
	var cur := float(State.read("player.thirst"))
	_write_float("player.thirst", cur - whole, _thirst_max,
		"thirst drain %.1f/GH" % _thirst_rate_per_gh)


# ════════════════════════════════════════════════════════════════
#  归零扣血（逐帧）
# ════════════════════════════════════════════════════════════════

## M2b/M3b：归零后 HP 按「每秒份额 ÷ 60」逐帧扣，跨零那一帧只吃一个帧份额，
## 禁止在跨零帧整块扣 1%（"no whole-percent chunk on zero-cross frame"）。
## C26：按 milli 记账，余数留到下一帧，绝不回头补扣整块。
func _tick_hp_drain() -> void:
	var hp := float(State.read("player.hp"))
	if hp <= 0.0:
		return
	var drain_milli := 0.0

	if float(State.read("player.hunger")) <= 0.0:
		_frac_hp_hunger_milli += hp_loss_per_tick(_hp_loss_hunger_per_sec) * HP_MILLI
		var whole_h := floorf(_frac_hp_hunger_milli)
		_frac_hp_hunger_milli -= whole_h
		drain_milli += whole_h

	if float(State.read("player.thirst")) <= 0.0:
		_frac_hp_thirst_milli += hp_loss_per_tick(_hp_loss_thirst_per_sec) * HP_MILLI
		var whole_t := floorf(_frac_hp_thirst_milli)
		_frac_hp_thirst_milli -= whole_t
		drain_milli += whole_t

	if drain_milli > 0.0:
		_write_float("player.hp", hp - drain_milli / float(HP_MILLI), _hp_max,
			"zero vitals HP drain")


# ════════════════════════════════════════════════════════════════
#  死亡
# ════════════════════════════════════════════════════════════════

## 死亡归因字符串必须从 ResolveOrder.DAMAGE_SOURCE_ORDER 取——唯一来源。
## M14：同帧多源致死，连跑 10 次归因必须 10/10 一致（不许靠 dict 遍历序）。
func _check_death() -> void:
	if _death_fired:
		return
	if float(State.read("player.hp")) > 0.0:
		return
	last_death_cause = _attribute_death()
	_death_fired = true
	died.emit(last_death_cause)


func _attribute_death() -> String:
	# 按 DAMAGE_SOURCE_ORDER 的固定序找第一个成立的死因（starvation 先于 dehydration）
	for cause: String in ResolveOrder.DAMAGE_SOURCE_ORDER:
		match cause:
			"starvation":
				if float(State.read("player.hunger")) <= 0.0:
					return cause
			"dehydration":
				if float(State.read("player.thirst")) <= 0.0:
					return cause
			"wild_sleep":
				if _wild_sleep_death_pending:
					return cause
			_:
				pass  # bleed / bite 归 CombatSystem，不在本系统判定
	# 兜底：HP 归零但可归因源都没命中 → 取表内第一个，保证字符串有唯一来源
	return ResolveOrder.DAMAGE_SOURCE_ORDER[0]


# ════════════════════════════════════════════════════════════════
#  强制睡 / 野睡 / 失能
# ════════════════════════════════════════════════════════════════

## M13 双路径：5.01→5.00 与 4.99 一步跨过，都必须触发且只触发 1 次
## （一次性锁存语义：触发即置 forced_sleep_pending，离开 ≤5% 才复位）
func _check_forced_sleep() -> void:
	var stamina := float(State.read("player.stamina"))
	var threshold := _threshold_units()
	if stamina <= threshold:
		if not _forced_sleep_latched:
			_forced_sleep_latched = true
			_write_bool("player.forced_sleep_pending", true, "stamina <= 5% forced sleep")
			forced_sleep_triggered.emit("threshold")
	else:
		if _forced_sleep_latched:
			_forced_sleep_latched = false
			_write_bool("player.forced_sleep_pending", false, "stamina recovered")


## 户外野睡结算（TimeSystem 调）：2GH -15HP，体力回满值的 20%
## 可选择性: 不可选（设计定稿 2.2，野睡是门禁的唯一惩罚通道）
func wild_sleep_penalty() -> void:
	var hp := float(State.read("player.hp"))
	var stamina := float(State.read("player.stamina"))
	var hp_after := hp - _wild_sleep_hp_penalty_hp
	_write_float("player.hp", hp_after, _hp_max, "wild sleep penalty")
	_write_float("player.stamina",
		stamina + _wild_sleep_stamina_refill_pct * 0.01 * _stamina_max, _stamina_max,
		"wild sleep stamina refill")
	night_incap_count += 1  # M13：野睡占用每夜硬失能额度
	if hp_after <= 0.0:
		_wild_sleep_death_pending = true
	forced_sleep_triggered.emit("wild")


## 波次失能结算（CombatSystem 调）：3.6s（216 帧）体力回满值的 10%
func wave_incap_refill() -> void:
	var stamina := float(State.read("player.stamina"))
	_write_float("player.stamina",
		stamina + _incap_stamina_refill_pct * 0.01 * _stamina_max, _stamina_max,
		"wave incap stamina refill")
	night_incap_count += 1  # M13：失能占用每夜硬失能额度


## 每夜硬失能额度重置（TimeSystem 的 day rollover 调；阶段A 05:00 / 阶段B 06:00）
## M13：每夜硬失能（野睡+失能合计）≤1 次，第 2 次起转 DeBUFF，不重复强制睡
func reset_night_incap() -> void:
	night_incap_count = 0


## M13：本夜硬失能额度是否已用掉
func night_incap_exhausted() -> bool:
	return night_incap_count >= 1


# ════════════════════════════════════════════════════════════════
#  纯函数（无头可断言；tests/run_tests.gd 直调）
# ════════════════════════════════════════════════════════════════

## M2/M3：归零后到死亡的秒数 = hp_max ÷ 每秒扣血
static func death_seconds_after_zero(hp_max: float, loss_per_sec: float) -> float:
	if loss_per_sec <= 0.0:
		return INF
	return hp_max / loss_per_sec


## M2b/M3b：单帧扣血份额 = 每秒扣血 ÷ TICKS_PER_SEC
static func hp_loss_per_tick(loss_per_sec: float) -> float:
	return loss_per_sec / float(TICKS_PER_SEC)


## M2b/M3b 判定：跨零那一帧单帧份额 ≤ 1% ÷ 60 帧
static func zero_cross_frame_share_ok(loss_per_sec: float) -> bool:
	return hp_loss_per_tick(loss_per_sec) <= (1.0 / float(TICKS_PER_SEC)) + 1e-9


## M4：是否触发强制睡（双路径共用一个比较，5.00 与 4.99 一步跨过同样命中）
## threshold_pct 是百分数（5 = 5%），max_units 是满值（100）
static func forced_sleep_should_trigger(stamina: float, threshold_pct: float,
		max_units: float, latched: bool) -> bool:
	if latched:
		return false
	return stamina <= threshold_pct * 0.01 * max_units


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func _threshold_units() -> float:
	return _forced_sleep_threshold_pct * 0.01 * _stamina_max


## 写浮点状态。max_v 是该路径的契约上限（player.* 全是 100），
## 先夹进 [0, max_v] 再 setv——否则 StateStore._authorize 会按 op 值判越界拒写。
func _write_float(path: String, value: float, max_v: float, reason: String) -> void:
	var cs := _Store.ChangeSet.new(&"vitals_system", reason)
	cs.setv(path, clampf(value, 0.0, max_v))
	State.apply(cs)


func _write_bool(path: String, value: bool, reason: String) -> void:
	var cs := _Store.ChangeSet.new(&"vitals_system", reason)
	cs.setv(path, value)
	State.apply(cs)


## 载入 data/balance/survival.json（协作纪律 1：唯一数值源）
## 载入后对 5 个定稿锚点做漂移自检——锚点被改 / 数据被改都会当场报出来
func _load_balance() -> void:
	var f := FileAccess.open(_BAL_PATH, FileAccess.READ)
	if f == null:
		push_error("vitals_system: %s missing - refuse boot" % _BAL_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("vitals_system: %s parse failed" % _BAL_PATH)
		return
	var d: Dictionary = parsed
	_hp_max = float(d.get("hp_max_hp", 100.0))
	_stamina_max = float(d.get("stamina_max_units", 100.0))
	_hunger_max = float(d.get("hunger_max_units", 100.0))
	_thirst_max = float(d.get("thirst_max_units", 100.0))
	_hunger_rate_per_gh = float(d.get("hunger_rate_per_gh", HUNGER_RATE_PER_GH))
	_thirst_rate_per_gh = float(d.get("thirst_rate_per_gh", THIRST_RATE_PER_GH))
	_hp_loss_hunger_per_sec = float(d.get("hp_loss_hunger_zero_per_sec", HP_LOSS_HUNGER_PER_SEC))
	_hp_loss_thirst_per_sec = float(d.get("hp_loss_thirst_zero_per_sec", HP_LOSS_THIRST_PER_SEC))
	_forced_sleep_threshold_pct = float(d.get("forced_sleep_threshold_pct", FORCED_SLEEP_THRESHOLD_PCT))
	_wild_sleep_duration_gh = float(d.get("wild_sleep_duration_gh", 2.0))
	_wild_sleep_hp_penalty_hp = float(d.get("wild_sleep_hp_penalty_hp", 15.0))
	_wild_sleep_stamina_refill_pct = float(d.get("wild_sleep_stamina_refill_pct", 20.0))
	_incap_duration_frames = int(d.get("incap_duration_frames", 216))
	_incap_stamina_refill_pct = float(d.get("incap_stamina_refill_pct", 10.0))

	var drifts: PackedStringArray = []
	if not is_equal_approx(_hunger_rate_per_gh, HUNGER_RATE_PER_GH):
		drifts.append("hunger_rate_per_gh")
	if not is_equal_approx(_thirst_rate_per_gh, THIRST_RATE_PER_GH):
		drifts.append("thirst_rate_per_gh")
	if not is_equal_approx(_hp_loss_hunger_per_sec, HP_LOSS_HUNGER_PER_SEC):
		drifts.append("hp_loss_hunger_zero_per_sec")
	if not is_equal_approx(_hp_loss_thirst_per_sec, HP_LOSS_THIRST_PER_SEC):
		drifts.append("hp_loss_thirst_zero_per_sec")
	if not is_equal_approx(_forced_sleep_threshold_pct, FORCED_SLEEP_THRESHOLD_PCT):
		drifts.append("forced_sleep_threshold_pct")
	if not drifts.is_empty():
		push_warning("vitals_system: design-anchor drift in %s" % ", ".join(drifts))
