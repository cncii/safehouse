class_name LoopSystem
extends Node
## loop_system.gd — 循环系统（安全屋自我造血）【分包：包 B·模拟系统组】
##
## ── 职责 ──   4 类产出按 GH 连续累积(整数定点 1/1000 milli，C26 零容差) /
##             库存上限与三段效率(100%→50%溢出暂存→0) / 3 个维护动作 /
##             设施三级与升级 / 断电倍率 / BROKEN 停机态 / 破防目标选择
## ── 不做 ──   不自动投喂玩家(净水/食物是背包消耗品，玩家手动吃喝——
##             四条状态条存在的前提)；不直接改 player.*（只写 loop.* 与 facilities.*）
## ── 数据 ──   data/balance/loop.json + data/facilities/facilities.json
## ── 判据 ──   P12b(夜间结算恒12GH±0.001与夜战时长无关) P13(三段效率/溢出守恒)
##             P20(HUD常驻库存+倒计时偏差≤1GH) P22-0(R11守护) M30(锚点)
##             S7-b(收支闭合：window_days必填+margin_days输出+ZERO_TOLERANCE标记)
##             M32(Lv2 七天累计产出 < 七天总需求，缓降段不许盈余)
##
## ── 定稿数值（v3 值表，勿动——M32 会自动否掉"Lv2 盈余"类改动）──
##   菌菇架 Lv1 0.12 / Lv2 0.19 / Lv3 0.22 每 GH（对应 2.88/4.56/5.28 每天）
##   净水器 Lv1 0.15 / Lv2 0.20 / Lv3 0.24 每 GH（3.60/4.80/5.76 每天）
##   Lv2 需 workbench（5零件 0GH）；Lv3 需 power_distribution（5零件 0GH）
##   库存上限：净水 15 / 食物 12 / 样本 10（储物升级 +50%）
##   维护：加燃料(发电机8GH/箱)、清滤芯(脏了-50%,10s可打断)、补料(样本0.5/天)
##   破防：夜7破防倒计时 0.50–1.29 天，min=0.50 恰好一个夜战窗口（精确设计）
##   ⚠ 末端余量(净水0.43天)是"不可触发界"——D15 06:00已通关，禁止拿它调平衡
##
## ── 实现（逻辑组 · 2026-10-20）────────────────────────────────
##  一切存量走 milli 整数（C26）。tick 的 delta_gh 先换算成 milli 帧当量再乘速率，
##  累加全程 int——浮点只出现在「读出来给人看」的那一步。
##  三段效率在 _deposit 里：未满 100% → 溢出段 50% → 软上限以上 0%（P13 守恒）。
##  自检入口：verify_loop_balance() 返回 P13/P20/M32/S7-b/P22-0 实测值。
## ────────────────────────────────────────────────────────────────

const PROD_SCALE := 1000         # 整数定点：1 单位 = 1000 milli
const OVERFLOW_SOFT_CAP_RATIO := 0.5   # 暂存区容量 = 上限 × 0.5（ceil）

# ── 判据基准值（**故意与运行值分开**，防恒真式断言）────────────
# 期望值若从运行常量派生，改一个等于改两个，断言永远成立。
const S7B_EXPECTED_MARGIN_DAYS_WATER := 0.43   # 末端净水余量（天）
const M32_LV2_MUST_BE_DEFICIT := true           # Lv2 产出 < 需求（不许盈余）

const _LOOP_PATH := "res://data/balance/loop.json"
const _SURV_PATH := "res://data/balance/survival.json"
const _Store = preload("res://src/core/state_store.gd")

var _store_milli: Dictionary = { "WATER": 0, "FOOD": 0, "POWER": 0, "MEDS": 0 }
var _progress_milli := 0         # 拆解分段进度：只允许 {0,500,1000,1500,2000}

# ── 设施状态（由 UI/建造层驱动；本系统只读）──
var _level: Dictionary = { "FOOD": 1, "WATER": 1, "POWER": 1, "MEDS": 1 }
var _unlocked: Dictionary = { "FOOD": true, "WATER": true, "POWER": true, "MEDS": false }
var _fueled := true              # 发电机有油
var _filter_dirty := false       # 滤芯脏
var _storage_upgraded := false   # 储物升级（上限 +50%）

# ── 运行值（_load_balance 载入）──
var _food_rate := [0.12, 0.19, 0.22]        # 每 GH，L1/L2/L3
var _water_rate := [0.15, 0.20, 0.24]
var _store_cap := { "WATER": 15, "FOOD": 12, "MEDS": 10 }
var _overflow_cap_pct := 50.0
var _overflow_eff_pct := 50.0
var _filter_dirty_mult_pct := 50.0
var _power_off_mult_pct := 50.0
var _carry_food_min := 6.0
var _carry_water_min := 8.0
var _demand_food_per_day := 4.8
var _demand_water_per_day := 5.6
var _power_rate_per_gh := 1.0    # PROVISIONAL：loop.json 未给发电速率（缺数 D-011）
var _meds_rate_per_day := 0.4    # loop.json medical_kit_rate_per_day（口径见 D-012）


func _ready() -> void:
	_load_balance()
	Save.register_persistence(PERSIST_KEY, Callable(self, "to_save"),
		Callable(self, "from_save"))


# ════════════════════════════════════════════════════════════════
#  产出推进
# ════════════════════════════════════════════════════════════════

## 结算序：ResolveOrder.LOOP_RESOLVE_ORDER；速率公式：
## rate = base × unlock_mult × power_mult × cleanliness_mult（四乘数可单独关）
func tick(delta_gh: float) -> void:
	if delta_gh <= 0.0:
		return
	# C26：delta_gh 先换算 milli 当量，全程整数累加，浮点只在这一步出现一次
	var delta_milli := int(round(delta_gh * float(PROD_SCALE)))
	if delta_milli <= 0:
		return
	for res: String in ResolveOrder.LOOP_RESOLVE_ORDER:
		var rate_milli := production_rate_milli(StringName(res))
		if rate_milli <= 0:
			continue
		_deposit(StringName(res), rate_milli * delta_milli / PROD_SCALE)


## 每 GH 产出（单位/小时）。四乘数可单独关，便于做单因子变异。
func production_rate(res: StringName) -> float:
	return float(production_rate_milli(res)) / float(PROD_SCALE)


func production_rate_milli(res: StringName) -> int:
	var r := String(res)
	var base := 0.0
	match r:
		"WATER":
			base = _water_rate[clampi(_level_of(r) - 1, 0, 2)]
		"FOOD":
			base = _food_rate[clampi(_level_of(r) - 1, 0, 2)]
		"POWER":
			base = _power_rate_per_gh if _fueled else 0.0
		"MEDS":
			base = _meds_rate_per_gh() if bool(_unlocked.get(r, false)) else 0.0
		_:
			return 0
	var unlock_mult := 1.0 if bool(_unlocked.get(r, false)) else 0.0
	var power_mult := 1.0 if _fueled else (_power_off_mult_pct * 0.01)
	var clean_mult := (_filter_dirty_mult_pct * 0.01) if (_filter_dirty and r == "WATER") else 1.0
	return int(round(base * unlock_mult * power_mult * clean_mult * float(PROD_SCALE)))


## P13 三段效率：未满 → 100%；满后进暂存区 → 50%；超出软上限 → 0%（溢出浪费）。
## 守恒口径：本函数是**唯一**写 _store_milli 的地方，存量变化 = 本次实际入账，
## 差额就是浪费——不做「先加后裁」，那样溢出量会凭空消失又凭空出现。
func _deposit(res: StringName, amount_milli: int) -> void:
	var r := String(res)
	var cap_milli := _cap_milli(r)
	if cap_milli <= 0:
		return                                # 无上限类（POWER/MEDS 不设库存上限）
	var cur := int(_store_milli.get(r, 0))
	if cur < cap_milli:
		var room := cap_milli - cur
		var into_main := mini(room, amount_milli)
		cur += into_main
		amount_milli -= into_main
	if amount_milli > 0:
		var soft := _soft_cap_milli(res)
		var into_overflow := mini(maxi(soft - cur, 0), amount_milli)
		if into_overflow > 0:
			var eff := int(round(float(into_overflow) * _overflow_eff_pct * 0.01))
			cur += eff
			amount_milli -= into_overflow      # 余下的是真浪费，不进账
	_store_milli[r] = cur
	_write_store(r, cur)


# ════════════════════════════════════════════════════════════════
#  HUD 数据（S10-b：已缓解必须有 UI 支撑）
# ════════════════════════════════════════════════════════════════

## 给 HUD 的"maintenance due"倒计时 + 链状态面板四项：
## {产出/天, 库存, 还能撑几天, 卡在哪一环}
func maintenance_urgency() -> Dictionary:
	var out := {}
	out["FOOD"] = _chain_status("FOOD", _demand_food_per_day)
	out["WATER"] = _chain_status("WATER", _demand_water_per_day)
	out["MEDS"] = _chain_status("MEDS", 0.0)
	out["POWER"] = _chain_status("POWER", 0.0)
	return out


## P20：倒计时偏差 ≤1 GH。days_left 用「净缺口」算而不是「毛存量」——
## 只看存量会高估：产出 0 的链存量再高也在跌。
func _chain_status(res: StringName, demand_per_day: float) -> Dictionary:
	var rate_per_day := production_rate(res) * 24.0
	var stock := float(_store_milli.get(String(res), 0)) / float(PROD_SCALE)
	var net := demand_per_day - rate_per_day
	var days_left := INF
	if net > 0.0:
		days_left = stock / net
	var status := {
		"rate_per_day": rate_per_day,
		"stock_units": stock,
		"days_left": days_left,
		"blocked_at": _blocked_at(res),
	}
	if demand_per_day > 0.0 and is_inf(days_left):
		status["days_left"] = -1.0        # 净产出为正 = 不会见底，-1 表示「不适用」
	return status


## 卡在哪一环：解锁 / 供电 / 滤芯 / 未解锁，四选一，UI 直接显示
func _blocked_at(res: StringName) -> String:
	var r := String(res)
	if not bool(_unlocked.get(r, false)):
		return "unlock"
	if r == "POWER" and not _fueled:
		return "power"
	if r == "WATER" and _filter_dirty:
		return "filter_core"
	return "none"


# ════════════════════════════════════════════════════════════════
#  S7-b 收支闭合 + M32 设计意图锁
# ════════════════════════════════════════════════════════════════

## 收支闭合。window_days 必填（不填不给默认值——默认值会让"忘了填"和"故意填 7"长得一样）。
## 输出 margin_days（末端还能撑几天）与 ZERO_TOLERANCE 标记（余量 < 1 天 = 缺水一天即崩）。
## 走的是**纯计算**，不读实例存量：判据要能在任何时刻复算，不受当前局状态影响。
func balance_closure(window_days: int, level_index: int) -> Dictionary:
	if window_days <= 0:
		push_error("loop_system: window_days is required and must be > 0")
		return {}
	var li := clampi(level_index, 0, 2)
	# 显式标注 float：_food_rate/_water_rate 是无类型 Array，`:=` 推不出类型会直接 Parse Error
	var food_rate: float = _food_rate[li]
	var water_rate: float = _water_rate[li]

	# 逐日推进，记录全程最紧处（末端不是最紧处——这正是这个判据存在的理由）
	var stock_f := _carry_food_min
	var stock_w := _carry_water_min
	var min_f := stock_f
	var min_w := stock_w
	var min_day_f := 0
	var min_day_w := 0
	for d in range(1, window_days + 1):
		stock_f += 24.0 * food_rate - _demand_food_per_day
		stock_w += 24.0 * water_rate - _demand_water_per_day
		if stock_f < min_f:
			min_f = stock_f
			min_day_f = d
		if stock_w < min_w:
			min_w = stock_w
			min_day_w = d

	var produced_f := 24.0 * food_rate * float(window_days)
	var produced_w := 24.0 * water_rate * float(window_days)
	var demand_f := _demand_food_per_day * float(window_days)
	var demand_w := _demand_water_per_day * float(window_days)
	var margin_days_f := stock_f / _demand_food_per_day
	var margin_days_w := stock_w / _demand_water_per_day
	var zero_tolerance := margin_days_f < 1.0 or margin_days_w < 1.0

	# M32：Lv2 必须是「缓降段」——产出小于需求，不许盈余
	var lv2_deficit := produced_f < demand_f and produced_w < demand_w

	return {
		"window_days": window_days,
		"level_index": li,
		"produced_food_units": produced_f,
		"produced_water_units": produced_w,
		"demand_food_units": demand_f,
		"demand_water_units": demand_w,
		"end_food_units": stock_f,
		"end_water_units": stock_w,
		"margin_days_food": margin_days_f,
		"margin_days_water": margin_days_w,
		"tightest_food_units": min_f,
		"tightest_water_units": min_w,
		"tightest_food_day": min_day_f,
		"tightest_water_day": min_day_w,
		"ZERO_TOLERANCE": zero_tolerance,
		"never_negative": min_f >= 0.0 and min_w >= 0.0,
		"M32_lv2_deficit": lv2_deficit,
	}


# ════════════════════════════════════════════════════════════════
#  破防目标（L1 强制：hash 派生，禁 randi）
# ════════════════════════════════════════════════════════════════

func pick_breach_target(candidates: PackedStringArray, day: int, night: int) -> StringName:
	# L1 强制要求：hash 派生，禁 randi；candidates 先按 facility_id 字典序排序
	# 再取模（建造顺序是玩家行为不是种子——不排序=重开能刷一个不疼的结果）
	var sorted := candidates.duplicate()
	sorted.sort()
	var pool := PackedStringArray()
	for c in sorted:
		if not ResolveOrder.BREACH_IMMUNE.has(c):
			pool.append(c)
	if pool.is_empty():
		return &""   # 全 immune → 降级为门板额外 -50（累计上限 -100，必须有可见反馈）
	return pool[Rng.pick(&"BREACH", day, [str(night)], pool.size())]


# ════════════════════════════════════════════════════════════════
#  存档挂接（D-009 · 蓝图见 data/schema/save.schema.json）
# ════════════════════════════════════════════════════════════════

const PERSIST_KEY := &"facilities"

## ④ 屋内设施。设施是**容器型**（每件一段的同构结构），不进 state_contract，
## 序列化走注册表。唯一例外是 dismantle_bench.progress_milli——它在 contract 里
## （锚点判据），所以这一条额外走 State 写，两处由 from_save 单点同步。
func to_save() -> Dictionary:
	var out := {}
	for fid: String in _FACILITY_IDS:
		out[fid] = {
			"level": _level.get(_res_of(fid), 1),
			"state": "OK",
			"durability": 100,
			"running": bool(_unlocked.get(_res_of(fid), false)),
			"store_milli": int(_store_milli.get(_res_of(fid), 0)),
			"store_cap_milli": _cap_milli(_res_of(fid)),
			"fuel": _fueled,
			"filter_dirt": _filter_dirty,
			"last_serviced_gh": _last_serviced_gh,
			"breach_immune": ResolveOrder.BREACH_IMMUNE.has(fid),
			"dismantleable": not ResolveOrder.BREACH_IMMUNE.has(fid),
		}
	out["dismantle_bench.progress_milli"] = _progress_milli
	return out


func from_save(snap: Dictionary) -> void:
	for fid: String in _FACILITY_IDS:
		var sec: Dictionary = snap.get(fid, {})
		if sec.is_empty():
			continue
		var res := _res_of(fid)
		_level[res] = clampi(int(sec.get("level", 1)), 1, 3)
		_unlocked[res] = bool(sec.get("running", true))
		_store_milli[res] = maxi(int(sec.get("store_milli", 0)), 0)
	_fueled = bool(snap.get("generator", {}).get("fuel", true))
	_filter_dirty = bool(snap.get("water_filter", {}).get("filter_dirt", false))
	# progress_milli 是锚点：只允许 {0,500,1000,1500,2000}，750 这类中间值拒载
	var raw := int(snap.get("dismantle_bench.progress_milli", 0))
	if _PROGRESS_ANCHORS.has(raw):
		_progress_milli = raw
	else:
		push_warning("loop_system: reject progress_milli=%d (not an anchor)" % raw)
		_progress_milli = 0


const _FACILITY_IDS: PackedStringArray = [
	"water_filter", "mushroom_bed", "generator", "dismantle_bench", "medical_bench",
]
const _PROGRESS_ANCHORS: PackedInt32Array = [0, 500, 1000, 1500, 2000]

var _last_serviced_gh := 0.0


func _res_of(facility_id: String) -> String:
	match facility_id:
		"water_filter", "medical_bench":
			return "WATER" if facility_id == "water_filter" else "MEDS"
		"mushroom_bed":
			return "FOOD"
	return "POWER"


# ════════════════════════════════════════════════════════════════
#  自检（P13 / P20 / M32 / S7-b / P22-0 —— 判据本体在本文件内）
# ════════════════════════════════════════════════════════════════

func verify_loop_balance() -> Dictionary:
	var out := {}

	# ── S7-b：Lv2 生存线 7 天（口径与 tools/validate_data.py 的 s7b 同一条）──
	var c := balance_closure(7, 1)
	out["S7b_margin_days_water"] = c.get("margin_days_water", -1.0)
	out["S7b_margin_days_food"] = c.get("margin_days_food", -1.0)
	out["S7b_zero_tolerance"] = c.get("ZERO_TOLERANCE", false)
	out["S7b_never_negative"] = c.get("never_negative", false)
	out["S7b_window_days"] = c.get("window_days", -1)
	# 余量对齐定稿值（±0.01 天）；用基准常量比，不用运行值比
	out["S7b_pass"] = absf(float(c.get("margin_days_water", -99.0))
		- S7B_EXPECTED_MARGIN_DAYS_WATER) <= 0.01

	# ── M32：Lv2 七天累计产出必须 < 七天总需求（缓降段不许盈余）──
	out["M32_lv2_deficit"] = c.get("M32_lv2_deficit", false)
	out["M32_pass"] = (not M32_LV2_MUST_BE_DEFICIT) or bool(c.get("M32_lv2_deficit", false))

	# ── P13：三段效率守恒（未满 100% / 溢出段 50% / 软上限以上 0%）──
	out["P13"] = _verify_overflow_conservation()

	# ── P20：倒计时用净缺口而不是毛存量 ──
	# `_level` 是无类型 Dictionary，`:=` 推不出类型 → 显式标 int
	var save_level: int = _level["FOOD"]
	_unlocked["FOOD"] = false                     # 断链 → rate 0
	var st := _chain_status(&"FOOD", _demand_food_per_day)
	var expect_days := (float(_store_milli.get("FOOD", 0)) / float(PROD_SCALE)) / _demand_food_per_day
	out["P20_days_left"] = st.get("days_left", -99.0)
	out["P20_pass"] = absf(float(st.get("days_left", -99.0)) - expect_days) <= 1.0 / 24.0 \
		and String(st.get("blocked_at", "")) == "unlock"
	_unlocked["FOOD"] = true
	_level["FOOD"] = save_level

	# ── P22-0：R11 守护——拆解台必须免疫破防（"无限刷零件"洞的封口）──
	var immunes := ResolveOrder.BREACH_IMMUNE
	out["P22_dismantle_immune"] = immunes.has("dismantle_bench")
	out["P22_pass"] = out["P22_dismantle_immune"] \
		and String(pick_breach_target(PackedStringArray(["dismantle_bench"]), 8, 7)) == ""
	return out


## P13 守恒自检：把存量推到不同区间，核对「入账量 == 存量增量」，且溢出段确实只吃 50%。
func _verify_overflow_conservation() -> bool:
	var save := int(_store_milli.get("WATER", 0))
	var cap := _cap_milli("WATER")
	var soft := _soft_cap_milli("WATER")
	var ok := true

	# 1) 未满：入账 = 增量
	_store_milli["WATER"] = 0
	_deposit(&"WATER", cap / 2)
	ok = ok and int(_store_milli["WATER"]) == cap / 2

	# 2) 满后进溢出段：cap→soft 的区间只有 50% 效率
	_store_milli["WATER"] = cap
	var into := soft - cap
	_deposit(&"WATER", into)
	var expect := cap + int(round(float(into) * _overflow_eff_pct * 0.01))
	ok = ok and int(_store_milli["WATER"]) == expect

	# 3) 灌到软上限后再存：0% 效率，存量不再涨（溢出真浪费）
	_store_milli["WATER"] = soft
	_deposit(&"WATER", PROD_SCALE * 10)
	ok = ok and int(_store_milli["WATER"]) == soft

	# 4) 守恒：主段 100% 吃满 + 溢出段只吃一半 —— 期望值必须分段算，不能对总量取半
	_store_milli["WATER"] = 0
	_deposit(&"WATER", cap + into)
	var expect_full := cap + int(round(float(into) * _overflow_eff_pct * 0.01))
	ok = ok and int(_store_milli["WATER"]) == expect_full

	_store_milli["WATER"] = save
	return ok


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func _level_of(res: String) -> int:
	return clampi(int(_level.get(res, 1)), 1, 3)


func _cap_milli(res: StringName) -> int:
	var base := float(_store_cap.get(String(res), 0.0))
	if _storage_upgraded:
		base *= 1.5
	return int(round(base * float(PROD_SCALE)))


## 暂存区上限 = 主上限 × overflow_cap_ratio_pct（数据源，比例 = pct/100）。
## OVERFLOW_SOFT_CAP_RATIO 只是 load 前的兜底默认值，装载后一律以 JSON 为准。
func _soft_cap_milli(res: StringName) -> int:
	var cap := _cap_milli(res)
	return cap + int(ceil(float(cap) * (_overflow_cap_pct * 0.01)))


func _meds_rate_per_gh() -> float:
	# medical_kit_rate_per_day 是「每天」口径，统一除以 24 折成 GH 口径。
	# ⚠ 缺数 D-012：该值到底是「医疗台持续产出」还是「可制作速率」未定义，
	#   解锁条件也缺（medical_bench 是 L3）。本轮按持续产出实现，等设计侧定口径。
	return _meds_rate_per_day / 24.0


func _write_store(res: String, value_milli: int) -> void:
	var path := "loop.store_%s_milli" % res.to_lower()
	var cs := _Store.ChangeSet.new(&"loop_system", "loop production %s" % res)
	cs.setv(path, value_milli)
	State.apply(cs)


## 载入 data/balance/loop.json（协作纪律 1：唯一数值源）
func _load_balance() -> void:
	var d := _read_dict(_LOOP_PATH)
	if d.is_empty():
		push_error("loop_system: %s missing - refuse boot" % _LOOP_PATH)
		return
	_food_rate = [float(d["mushroom_food_rate_l1_per_gh"]),
		float(d["mushroom_food_rate_l2_per_gh"]),
		float(d["mushroom_food_rate_l3_per_gh"])]
	_water_rate = [float(d["filter_water_rate_l1_per_gh"]),
		float(d["filter_water_rate_l2_per_gh"]),
		float(d["filter_water_rate_l3_per_gh"])]
	_store_cap = {
		"WATER": float(d["water_store_cap_units"]),
		"FOOD": float(d["food_store_cap_units"]),
		"MEDS": float(d["sample_store_cap_units"]),
	}
	_overflow_cap_pct = float(d.get("overflow_cap_ratio_pct", _overflow_cap_pct))
	_overflow_eff_pct = float(d.get("overflow_efficiency_pct", _overflow_eff_pct))
	_filter_dirty_mult_pct = float(d.get("filter_dirty_output_mult_pct", _filter_dirty_mult_pct))
	_power_off_mult_pct = float(d.get("power_off_output_mult_pct", _power_off_mult_pct))
	_carry_food_min = float(d.get("carry_in_food_min_units", _carry_food_min))
	_carry_water_min = float(d.get("carry_in_water_min_units", _carry_water_min))
	_meds_rate_per_day = float(d.get("medical_kit_rate_per_day", _meds_rate_per_day))

	# 需求口径在 survival.json 的 derived（协作纪律 1：不在本文件重复定义）
	var surv := _read_dict(_SURV_PATH)
	var derived: Dictionary = surv.get("derived", {})
	_demand_food_per_day = float(derived.get("food_units_per_day", _demand_food_per_day))
	_demand_water_per_day = float(derived.get("water_units_per_day", _demand_water_per_day))


func _read_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}