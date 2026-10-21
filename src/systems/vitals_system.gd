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
const _STATUS_PATH := "res://data/balance/status_effects.json"
const _Store = preload("res://src/core/state_store.gd")

## 存档注册键：状态效果容器（架构 §5.2 落在 player 段下，但 player 段由
## StateStore.snapshot() 自动收录，容器塞不进去 → 单独一段，字段蓝图见
## data/schema/save.schema.json 的 player 段 status_effects）。
const PERSIST_KEY := &"player_status_effects"

signal died(cause: String)                   # cause ∈ ResolveOrder.DAMAGE_SOURCE_ORDER
signal forced_sleep_triggered(path: String)  # "threshold" | "wild"

# ── 运行值（_load_balance 自 survival.json 载入）──
static var _hp_max := 100.0
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

# ── 状态效果容器（容器型：不进 state_contract，走 SaveSystem 注册表）──
## 架构 §5.2 的落盘形态：player.status_effects = [{id, stacks, expires_at_gh}]
## 本系统只持有这一份真相；DAMAGE_SOURCE_ORDER 里的 "bleed" 由此判定。
##
## ⚠ 容器是 **static**（脚本级唯一），不是实例成员：
##   ① 存档注册只能做一次（Save.register_persistence 遇重复 key 会 assert 崩），
##      而无头测试会 new 多个实例——实例成员的话每次 new 都会注册一次，直接崩。
##   ② 更要紧的是**回调要绑到唯一的那份数据**。若注册的是实例 Callable，
##      存档读写就会绑在"第一个被 new 的实例"上，第二个实例的容器是空的——
##      读档丢状态，而且不报错（最难查的那类洞）。
##   static 容器 + static 回调 = 数据与回调始终指向同一份，不存在分叉。
static var _status_effects: Array[Dictionary] = []
static var _persist_registered := false
static var _bleed_hp_loss_per_gh_per_stack := 0.0   # 出血压血速率（自 status_effects.json 载入）
static var _bleed_expires_gh := 12.0    # 出血默认持续 GH
static var _bleed_max_stacks := 0       # 出血层数上限（0 = 不限）
static var _bite_stacks := 1            # 一次咬伤挂几层出血
static var _bite_bleed_expires_gh := 12.0
var _bite_pending := false       # 咬伤致死标记（CombatSystem 置位，跨 GH 有效）


func _ready() -> void:
	_load_balance()
	register_persistence()
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
				_apply_status_effects(gh_mark)
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
	# 按 DAMAGE_SOURCE_ORDER 的固定序找第一个成立的死因（starvation 先于 dehydration）。
	# 判据本体在 static func attribute_death_cause()，实现与判据共用同一张表——
	# 但表是 core 的 ResolveOrder，本系统不持有副本。
	var present := {
		"starvation": float(State.read("player.hunger")) <= 0.0,
		"dehydration": float(State.read("player.thirst")) <= 0.0,
		"wild_sleep": _wild_sleep_death_pending,
		"bleed": _bleed_active(),
		"bite": _bite_pending,
	}
	return attribute_death_cause(present)


# ════════════════════════════════════════════════════════════════
#  状态效果（出血等 buff）
# ════════════════════════════════════════════════════════════════
#
## 容器型状态：数组 [{id, stacks, expires_at_gh}]，**不进 state_contract**——
## ChangeSet 是数值 Op 流，塞不进数组（协作纪律 5 / D-009 两层边界）。
## 落盘走 SaveSystem.register_persistence("player_status_effects", …)。
##
## 结算点：GH 边界（ResolveOrder.STATUS_RESOLVE_ORDER 的 "status_effects" 位）。
## 出血按「每 GH 每层掉多少 HP」结算，**不是按秒**——与饥饿/渴的逐帧扣血不同：
## 出血是持续伤害 buff，设计上以 GH 为粒度（expires_at_gh 也是 GH）。
## 若设计侧要求逐帧，改这里即可，但那时 expires_at_gh 的语义也要一起改。

## 施加状态效果（CombatSystem / 事件效果调用）
## stacks：层数，同 id 叠加层数（不叠 expires——取最晚的那个）
static func apply_status_effect(id: StringName, stacks: int, expires_at_gh: float) -> void:
	if stacks <= 0:
		return
	var eid := String(id)
	for eff: Dictionary in _status_effects:
		if String(eff.get("id", "")) == eid:
			eff["stacks"] = int(eff.get("stacks", 0)) + stacks
			eff["expires_at_gh"] = maxf(float(eff.get("expires_at_gh", 0.0)), expires_at_gh)
			_clamp_stacks(eff)
			return
	_status_effects.append({
		"id": eid, "stacks": stacks, "expires_at_gh": expires_at_gh,
	})
	_clamp_stacks(_status_effects[_status_effects.size() - 1])


## 层数上限（0 = 不限）。上限只对"出血"生效——其它 buff 的上限规则待设计侧给。
static func _clamp_stacks(eff: Dictionary) -> void:
	if String(eff.get("id", "")) != "bleeding":
		return
	if _bleed_max_stacks > 0:
		eff["stacks"] = mini(int(eff.get("stacks", 0)), _bleed_max_stacks)


## GH 边界结算：先到期清理，再按剩余层数扣血
static func _apply_status_effects(gh_now: float) -> void:
	if _status_effects.is_empty():
		return
	# ① 到期清理（expires_at_gh <= 当前 GH 即失效）
	var alive: Array[Dictionary] = []
	for eff: Dictionary in _status_effects:
		if float(eff.get("expires_at_gh", 0.0)) > gh_now:
			alive.append(eff)
	_status_effects = alive
	if _status_effects.is_empty():
		return

	# ② 出血扣血：每 GH 每层一份
	var hp := float(State.read("player.hp"))
	var drain := 0.0
	for eff: Dictionary in _status_effects:
		if String(eff.get("id", "")) != "bleeding":
			continue
		drain += _bleed_hp_loss_per_gh_per_stack * float(int(eff.get("stacks", 0)))
	if drain > 0.0:
		_write_float("player.hp", hp - drain, _hp_max, "bleed status effect")


## 当前是否有生效的出血（死亡归因用）
static func _bleed_active() -> bool:
	for eff: Dictionary in _status_effects:
		if String(eff.get("id", "")) == "bleeding" and int(eff.get("stacks", 0)) > 0:
			return true
	return false


## 状态效果快照（存档用；只读副本，调用方改不动内部）
static func status_effects_snapshot() -> Array:
	var out: Array = []
	for eff: Dictionary in _status_effects:
		out.append({
			"id": String(eff.get("id", "")),
			"stacks": int(eff.get("stacks", 0)),
			"expires_at_gh": float(eff.get("expires_at_gh", 0.0)),
		})
	return out


## 状态效果恢复（存档用；脏 id 拒载，未知 id 不写回内存）
static func status_effects_restore(snap: Array) -> void:
	_status_effects.clear()
	for item: Variant in snap:
		if not (item is Dictionary):
			continue
		var e: Dictionary = item
		var eid := String(e.get("id", ""))
		if eid != "bleeding":
			continue    # 只认已实现的 buff id，其余拒载
		var stacks := int(e.get("stacks", 0))
		if stacks <= 0:
			continue
		_status_effects.append({
			"id": eid, "stacks": stacks,
			"expires_at_gh": float(e.get("expires_at_gh", 0.0)),
		})


## 咬伤致死标记（CombatSystem 调）：置位后，HP 归零时归因走 "bite"
func note_bite_wounding() -> void:
	_bite_pending = true


## 施加咬伤：置位 bite 标记 + 挂出血 buff（层数与持续时间由数据表给）
func apply_bite(stacks: int = -1, expires_at_gh: float = -1.0) -> void:
	_bite_pending = true
	var s := stacks if stacks > 0 else _bite_stacks
	var until := expires_at_gh
	if until < 0.0:
		until = _bite_bleed_expires_gh
	apply_status_effect(&"bleeding", s, until)


## 状态效果存档段（SaveSystem 注册表用）——static：容器与回调必须同源
static func to_save_status_effects() -> Dictionary:
	return {"status_effects": status_effects_snapshot()}


static func from_save_status_effects(snap: Dictionary) -> void:
	status_effects_restore(snap.get("status_effects", []) as Array)


## 存档注册（只做一次）。static 回调 → 不绑任何实例，
## 存档读写永远指向脚本级唯一的那份容器。
static func register_persistence() -> void:
	if _persist_registered:
		return
	Save.register_persistence(PERSIST_KEY, Callable(VitalsSystem, "to_save_status_effects"),
		Callable(VitalsSystem, "from_save_status_effects"))
	_persist_registered = true


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


## M14：同帧多源致死，归因必须走 ResolveOrder.DAMAGE_SOURCE_ORDER 的**固定序**，
## 连跑 10 次归因 10/10 一致（禁 dict 遍历序——遍历序在不同运行/不同插入序下会变）。
##
## 期望值独立于被测逻辑：ORDER 是被测的输入（表本身由 core 提供），
## 但"应当选中哪个 cause"是**本函数按表推出的**，不是被测代码自算的，
## 所以这里比对的是"选中的 cause == 表中第一个成立的 cause"这一结构性质。
static func attribute_death_cause(present: Dictionary) -> String:
	for cause: String in ResolveOrder.DAMAGE_SOURCE_ORDER:
		if bool(present.get(cause, false)):
			return cause
	# 全都不成立：归因到表内第一个（保证字符串有唯一来源，不返回空串）
	return ResolveOrder.DAMAGE_SOURCE_ORDER[0]


## M4：是否触发强制睡（双路径共用一个比较，5.00 与 4.99 一步跨过同样命中）
## threshold_pct 是百分数（5 = 5%），max_units 是满值（100）
static func forced_sleep_should_trigger(stamina: float, threshold_pct: float,
		max_units: float, latched: bool) -> bool:
	if latched:
		return false
	return stamina <= threshold_pct * 0.01 * max_units


# ════════════════════════════════════════════════════════════════
#  自检（M14 死亡归因 / 出血 buff 生命周期）
# ════════════════════════════════════════════════════════════════

## M14 判据本体：同帧多源致死，归因必须 10/10 一致，且必须等于
## DAMAGE_SOURCE_ORDER 固定序中**第一个成立**的 cause。
##
## 为什么期望值要独立写死（防恒真式——本项目已踩三次）：
## 若期望值取自 attribute_death_cause() 自己的输出，那就是"自己算自己比"，
## 恒真。这里写死的是**表序推导出的具体 cause 字符串**。
##
## ⚠ 字典插入序必须**逆着表序**（DAMAGE_SOURCE_ORDER = starvation, dehydration,
## bleed, bite, wild_sleep）：GDScript 的 Dictionary 保序，若字典按表序插入，
## "遍历 present 字典"这个被明令禁止的写法会给出**同一个答案**——
## 判据就成了永远绿的假货（第一次写这判据时正是踩了这个坑）。
## 现在多源用例一律写成 {"bleed":…, "starvation":…} 这种逆表序形态：
## dict 序会给 bleed，表序必须给 starvation，两者不同 ⇒ 判据有牙齿。
static func verify_death_attribution() -> Dictionary:
	var out := {}
	# ① 10 次连跑归因一致（同帧多源：饥饿 + 渴同时归零，**字典按逆表序插入**）
	var causes: Array[String] = []
	for _i in 10:
		causes.append(attribute_death_cause({
			"dehydration": true, "starvation": true,
		}))
	var same := true
	for c: String in causes:
		if c != causes[0]:
			same = false
	out["M14_runs"] = causes.size()
	out["M14_consistent"] = same
	out["M14_cause"] = causes[0] if causes.size() > 0 else ""
	# ② 归因值必须是 starvation（表内 starvation 先于 dehydration）
	out["M14_expected_cause"] = "starvation"
	out["M14_pass"] = same and out["M14_cause"] == "starvation"

	# ③ 反向对照：只成立 dehydration → 归因 dehydration（不是恒返回 starvation）
	var only_thirst := attribute_death_cause({"dehydration": true})
	out["M14_only_dehydration"] = only_thirst
	out["M14_only_dehydration_ok"] = only_thirst == "dehydration"

	# ④ bleed 成立时归因 bleed（证明新加的 buff 位接进了归因表）
	var bleed_only := attribute_death_cause({"bleed": true})
	out["M14_bleed_only"] = bleed_only
	out["M14_bleed_ok"] = bleed_only == "bleed"

	# ⑤ ★ 判据牙齿所在：bleed + starvation 同时成立，字典按逆表序插入。
	#    表序必须给 starvation（表内 starvation < bleed）；
	#    若实现改成遍历 present 字典，这里会给 bleed → 判据变红。
	var starve_and_bleed := attribute_death_cause({"bleed": true, "starvation": true})
	out["M14_starve_over_bleed"] = starve_and_bleed
	out["M14_starve_over_bleed_ok"] = starve_and_bleed == "starvation"

	# ⑥ 全不成立 → 表内第一个（唯一来源，不返回空串）
	var none := attribute_death_cause({})
	out["M14_fallback"] = none
	out["M14_fallback_ok"] = none == ResolveOrder.DAMAGE_SOURCE_ORDER[0]

	out["M14_all_pass"] = bool(out["M14_pass"]) and bool(out["M14_only_dehydration_ok"]) \
		and bool(out["M14_bleed_ok"]) and bool(out["M14_starve_over_bleed_ok"]) \
		and bool(out["M14_fallback_ok"])
	return out


## 出血 buff 生命周期判据：施加 → 生效扣血 → 到期失效 → 存档往返不丢
func verify_bleed_buff() -> Dictionary:
	var out := {}
	_status_effects.clear()

	# ① 施加 2 层出血，持续到 GH 12
	apply_status_effect(&"bleeding", 2, 12.0)
	out["BLEED_stacks"] = 0
	for eff: Dictionary in _status_effects:
		out["BLEED_stacks"] = int(eff.get("stacks", 0))
	out["BLEED_applied"] = int(out["BLEED_stacks"]) == 2
	out["BLEED_active_before_expiry"] = _bleed_active()

	# ② 同 id 叠加：再加 1 层 → 3 层（不是覆盖）
	apply_status_effect(&"bleeding", 1, 12.0)
	var total := 0
	for eff: Dictionary in _status_effects:
		total += int(eff.get("stacks", 0))
	out["BLEED_stacked_total"] = total
	out["BLEED_stack_ok"] = total == 3

	# ③ 叠加不叠到期时间：给一个更晚的到期时间 → 取最晚
	apply_status_effect(&"bleeding", 1, 20.0)
	var latest := 0.0
	for eff: Dictionary in _status_effects:
		latest = maxf(latest, float(eff.get("expires_at_gh", 0.0)))
	out["BLEED_expiry_kept_latest"] = latest
	out["BLEED_expiry_ok"] = is_equal_approx(latest, 20.0)

	# ③b ★ 层数上限：叠到**超过**上限后必须被压住。
	#    ⚠ 上一版这里叠 2+1=3，恰好等于上限 3 → 上限逻辑坏掉也测不出来
	#    （变异体实测 BLEED_all_pass 仍为 true）。必须叠过线才算真测上限。
	var cap := _bleed_max_stacks
	out["BLEED_max_stacks"] = cap
	if cap > 0:
		apply_status_effect(&"bleeding", cap + 5, 20.0)   # 远超上限
		var capped := 0
		for eff: Dictionary in _status_effects:
			capped += int(eff.get("stacks", 0))
		out["BLEED_capped_total"] = capped
		out["BLEED_cap_ok"] = capped == cap
	else:
		# 上限为 0 = 不限：叠多少就是多少
		apply_status_effect(&"bleeding", 5, 20.0)
		var uncapped := 0
		for eff: Dictionary in _status_effects:
			uncapped += int(eff.get("stacks", 0))
		out["BLEED_capped_total"] = uncapped
		out["BLEED_cap_ok"] = uncapped == 8   # 3+5

	# ④ 到期清理：GH 25 边界 → 全部过期 → 不再是活 buff
	_apply_status_effects(25.0)
	out["BLEED_count_after_expiry"] = _status_effects.size()
	out["BLEED_expired"] = _status_effects.is_empty()
	out["BLEED_not_active_after_expiry"] = not _bleed_active()

	# ⑤ 存档往返：容器内容一字不差
	apply_status_effect(&"bleeding", 2, 30.0)
	var snap := to_save_status_effects()
	_status_effects.clear()
	from_save_status_effects(snap)
	out["BLEED_roundtrip_count"] = _status_effects.size()
	out["BLEED_roundtrip_stacks"] = 0
	for eff: Dictionary in _status_effects:
		out["BLEED_roundtrip_stacks"] = int(eff.get("stacks", 0))
	out["BLEED_roundtrip_ok"] = int(out["BLEED_roundtrip_count"]) == 1 \
		and int(out["BLEED_roundtrip_stacks"]) == 2

	# ⑥ 脏 id 拒载：未知 buff id 不写回内存
	var dirty := {"status_effects": [
		{"id": "bleeding", "stacks": 1, "expires_at_gh": 5.0},
		{"id": "buff_removed_from_game", "stacks": 9, "expires_at_gh": 5.0},
	]}
	_status_effects.clear()
	from_save_status_effects(dirty)
	out["BLEED_dirty_rejected"] = _status_effects.size() == 1
	out["BLEED_dirty_ok"] = int(out["BLEED_dirty_rejected"]) == 1

	_status_effects.clear()
	out["BLEED_all_pass"] = bool(out["BLEED_applied"]) and bool(out["BLEED_stack_ok"]) \
		and bool(out["BLEED_expiry_ok"]) and bool(out["BLEED_cap_ok"]) \
		and bool(out["BLEED_expired"]) \
		and bool(out["BLEED_roundtrip_ok"]) and bool(out["BLEED_dirty_ok"])
	return out


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func _threshold_units() -> float:
	return _forced_sleep_threshold_pct * 0.01 * _stamina_max


## 写浮点状态。max_v 是该路径的契约上限（player.* 全是 100），
## 先夹进 [0, max_v] 再 setv——否则 StateStore._authorize 会按 op 值判越界拒写。
static func _write_float(path: String, value: float, max_v: float, reason: String) -> void:
	var cs := _Store.ChangeSet.new(&"vitals_system", reason)
	cs.setv(path, clampf(value, 0.0, max_v))
	State.apply(cs)


static func _write_bool(path: String, value: bool, reason: String) -> void:
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
	_load_status_effects()


## 载入 data/balance/status_effects.json（状态效果数值源）
## 数值缺失时不编造：保持 0（出血不扣血）并把缺数登记在 data/UNDEFINED.md。
func _load_status_effects() -> void:
	var f := FileAccess.open(_STATUS_PATH, FileAccess.READ)
	if f == null:
		push_warning("vitals_system: %s missing - bleed disabled" % _STATUS_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("vitals_system: %s parse failed - bleed disabled" % _STATUS_PATH)
		return
	var d: Dictionary = parsed
	var bleed: Dictionary = d.get("bleeding", {})
	_bleed_hp_loss_per_gh_per_stack = float(bleed.get("bleed_hp_loss_per_gh_per_stack_hp", 0.0))
	_bleed_expires_gh = float(bleed.get("bleed_expires_gh", 12.0))
	_bleed_max_stacks = int(bleed.get("bleed_max_stacks_count", 0))
	var bite: Dictionary = d.get("bite", {})
	_bite_stacks = int(bite.get("bite_bleed_stacks_count", 1))
	_bite_bleed_expires_gh = float(bite.get("bite_bleed_expires_gh", 12.0))

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
