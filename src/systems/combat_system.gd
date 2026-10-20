class_name CombatSystem
extends Node
## combat_system.gd — 战斗系统 【分包：包 C·事件与战斗组】
##
## ── 职责 ──   近战/翻滚/伤害结算/波次状态机/破防结算/体力消耗
## ── 不做 ──   不持有 RNG（敌人属性由 SpawnService 按 plan 生成）；
##              不写存档（入档只有 wave plan + cursor，运行时实体永不入档）
## ── 数据 ──   data/balance/combat.json（资源/伤害权威源）+ data/events/waves.json
## ── 判据 ──   R5(战斗手感：闪避>挥砍×0.6 且无站桩局) P11系列(五条拆分判据)
##              M19(wave_plan 物化 18:00±1帧,实际生成与plan逐项相等)
##              M23(挂机兜底≤8min) P11-D(极差≤36且steps_dropped==0)
##
## ── 定稿参数（帧是唯一权威，C28） ──
##   无敌 9 帧 / 前摇 8 帧 / 后摇 6 帧 / 受击硬直 12 帧 / 失能 216 帧
##   挥砍 -3 体力 / 翻滚 -6 / 冲刺 1.5/s / 受击 -5
##   挥砍伤害 25/35/50（基础/强化/顶级）；有效 DPS 27（理论41.7×走位0.65）
##   夜间体力量级：熟练 bot 夜7 实耗 81%（余 13 次挥砍 + 2 支能量棒）
##
## ── 波次完成判据（三条件，防"召唤池抽干提前过关"）──
##   all_batches_killed = 所有batch已处理 AND alive==0 AND pool_remaining==0
##   破防结算：night_clear 拿奖励池 / breach 无奖励+门板-50+随机损毁1设施
##
## ── 禁改边界（任务书 §4，违反即 CI exit 1 / 契约破坏）──
##   帧常量只读 TimeSystem.*（C28）；EffectSink 四类能力不许加第5类；
##   condition 结构化谓词，禁用 "!"；RNG 单一入口(src 出现 randi() 即 CI exit 1)

const SOURCE := "combat_system"

# 状态写入口：preload 脚本以访问其内嵌 ChangeSet 类（与 vitals_system.gd 同款稳妥写法；
# 仅 State 是 autoload 实例，state_store.gd 无 class_name，故不能 _Store.ChangeSet）。
const _Store = preload("res://src/core/state_store.gd")

# ── 资源/伤害常量（权威源 = data/balance/combat.json，本文件只持有加载缓存）──
var _stamina_attack := 3.0
var _stamina_dodge := 6.0
var _dmg_base := 25.0
var _dmg_boost := 35.0
var _dmg_apex := 50.0
var _dps_effective := 27.0

# ── 动作状态机 ──
enum Action { IDLE, WINDUP, RECOVER, ROLLING }
var _action := Action.IDLE
var _timer := 0          # 当前动作剩余帧
var _iframes := 0        # 翻滚无敌剩余帧
var _attack_queued := false   # windup 结束帧的判定标记

signal hit_resolved(result: Dictionary)     # 判定帧结算结果（敌场景消费）
signal wave_progress(kills_ratio: float)    # 击杀推进波次时钟（TimeSystem 订阅）
signal breach_resolved(target: StringName)  # 破防目标（LoopSystem 解析后回传）

# ── 波次状态 ──
var wave_active := false
var pool_remaining := 0
var _kills := 0
var _plan_total := 0
var _breach_target: StringName = &""
var _wave_plan: Dictionary = {}      # W2 物化清单（M19 比对用）
var _batches_total := 0
var _batches_done := 0
var _batch_slots: Dictionary = {}    # batch_idx -> 该 batch 的 slot 总数（物化时建）
var _batch_killed: Dictionary = {}   # batch_idx -> 该 batch 已清 slot 数（击杀时记账）
var _strength := 1.0
var _config: Dictionary = {}         # waves.json 缓存
var _enemy_table: Dictionary = {}    # enemies.json 缓存

func _ready() -> void:
	_load_tunables()

func _load_tunables() -> void:
	var f := FileAccess.open("res://data/balance/combat.json", FileAccess.READ)
	if f == null:
		push_warning("combat_system: combat.json missing - using built-in defaults")
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY:
		return
	# 注：键名带单位后缀（M28-a）：_units=点/次数，_dps=每秒伤害
	_stamina_attack = float(d.get("combat_stamina_attack_units", _stamina_attack))
	_stamina_dodge  = float(d.get("combat_stamina_dodge_units", _stamina_dodge))
	_dmg_base  = float(d.get("combat_damage_base_units", _dmg_base))
	_dmg_boost = float(d.get("combat_damage_boost_units", _dmg_boost))
	_dmg_apex  = float(d.get("combat_damage_apex_units", _dmg_apex))
	_dps_effective = float(d.get("combat_dps_effective_ratio", _dps_effective))

## 热重载（combat_arena 调参用，不重开场景）
func reload_tunables() -> void:
	_load_tunables()

# ── 帧推进（由 GameLoop 每帧 / combat_arena._process 调用）──
func tick() -> void:
	if _iframes > 0:
		_iframes -= 1
	if _timer > 0:
		_timer -= 1
		if _action == Action.WINDUP and _timer == 0:
			_attack_queued = true          # 判定帧：此刻结算命中
		if _timer == 0:
			if _action == Action.WINDUP and _attack_queued:
				_resolve_hit()
			_action = Action.IDLE

func is_iframe_active() -> bool:
	return _iframes > 0

func current_action() -> int:
	return _action

func stamina_attack() -> float: return _stamina_attack
func stamina_dodge() -> float:  return _stamina_dodge

## 经 StateStore 写「带下限夹紧的绝对值」。
## 注意：contract._authorize 对 add 的负值增量直接判 below-min 拒掉（vitals_system 注释同款坑），
## 故负增量必须本地算绝对值再 setv，绝不能 add(负值)。
func _delta_vital(path: String, delta: float, reason: String = "vital_delta") -> void:
	var cur := float(State.read(path))
	var new_val := maxf(0.0, cur + delta)
	State.apply(_Store.ChangeSet.new(SOURCE, reason).setv(path, new_val))

## 近战攻击：扣 3 体力 → 前摇 8 帧 → 判定帧结算 → 后摇 6 帧
func player_attack(dir: Vector2) -> Dictionary:
	if _action != Action.IDLE or _iframes > 0:
		return {"ok": false, "reason": "busy"}
	if State.read("player.stamina") < _stamina_attack:
		return {"ok": false, "reason": "no_stamina"}
	_delta_vital("player.stamina", -_stamina_attack, "attack")
	_action = Action.WINDUP
	_timer = TimeSystem.WINDUP_TICKS
	return {"ok": true, "stamina_cost": _stamina_attack, "windup": TimeSystem.WINDUP_TICKS, "damage": _dmg_base}

## 翻滚：扣 6 体力，无敌帧 9 帧（对齐 TimeSystem.IFRAMES_TICKS）
func player_dodge(dir: Vector2) -> Dictionary:
	if _action != Action.IDLE or _iframes > 0:
		return {"ok": false, "reason": "busy"}
	if State.read("player.stamina") < _stamina_dodge:
		return {"ok": false, "reason": "no_stamina"}
	_delta_vital("player.stamina", -_stamina_dodge, "dodge")
	_action = Action.ROLLING
	_iframes = TimeSystem.IFRAMES_TICKS
	_timer = TimeSystem.IFRAMES_TICKS + TimeSystem.RECOVERY_TICKS   # 翻滚+后摇不可动作
	return {"ok": true, "stamina_cost": _stamina_dodge, "iframes": TimeSystem.IFRAMES_TICKS}

## 受击：无敌帧内完全格挡（R5 手感核心——翻滚可躲）；否则扣血 + 硬直 12 帧
func on_hit_received(dmg: float) -> Dictionary:
	if _iframes > 0:
		return {"blocked": true, "damage": 0.0}
	_delta_vital("player.hp", -dmg, "take_hit")
	_action = Action.RECOVER
	_timer = TimeSystem.HITSTUN_TICKS
	return {"blocked": false, "damage": dmg, "hitstun": TimeSystem.HITSTUN_TICKS}

## 判定帧结算：产出基础伤害（命中目标由 enemy 场景消费本返回值）
func _resolve_hit() -> Dictionary:
	var result := {"damage": _dmg_base, "hitstun": TimeSystem.HITSTUN_TICKS}
	_attack_queued = false
	hit_resolved.emit(result)
	return result

## 开波：物化 wave_plan（M19）→ 置 combat.wave_active，pool_remaining = 物化 slot 总数
##
## M19 契约：实际生成清单与 plan 逐项相等，且物化时刻 18:00±1 帧（由调用方在 18:00 调本方法保证）。
## 物化零顺序消费——每个 slot 的敌人变体只由 (day, night_index, batch, slot) 槽位 hash 决定，
## 与击杀顺序/开箱顺序/帧率无关，故同种子重开逐项相等。
func begin_wave(night_index: int, calendar_day: int = -1) -> Dictionary:
	var plan := materialize_wave_plan(night_index, calendar_day)
	_wave_plan = plan
	_plan_total = plan.get("slots", []).size()
	pool_remaining = _plan_total
	_kills = 0
	_batches_total = int(plan.get("batch_count", 0))
	_batches_done = 0
	_batch_slots = {}
	_batch_killed = {}
	for s_variant: Variant in _wave_plan.get("slots", []):
		var s: Dictionary = s_variant
		var b := int(s.get("batch", 0))
		_batch_slots[b] = int(_batch_slots.get(b, 0)) + 1
	_strength = float(plan.get("strength_mult", 1.0))
	wave_active = true
	# plan_hash 入状态契约（writer 含 combat_system）：M19/P7 读档后重算比对的锚点。
	# int 存 hash 的一部分，仅作「同一夜同一物化结果」的等值标记，不用于反推内容。
	# 注：core 的 state_contract.gd 无此路径常量（战斗组不改 core），故用字面量，与
	# 其它系统写 "player.stamina" 同款；路径本身已在 state_contract.json 注册。
	State.apply(_Store.ChangeSet.new(SOURCE, "begin_wave")
		.setv(StateContract.C_WAVE_ACTIVE, true)
		.setv("combat.wave_plan_hash", int(plan.get("plan_hash", 0))))
	return plan

## ── W2 · wave_plan 物化 ────────────────────────────────────────────────
## 读 waves.json 的该夜配置 → 逐 batch 按槽位展开 spawn slot。
## 每 slot 固定产出 {batch, slot, enemy_id, entry_point, hp, damage, ...}，
## 参数由 enemies.json 查表 × strength_mult（同事实单一来源，不内联不掷骰）。
func materialize_wave_plan(night_index: int, calendar_day: int = -1) -> Dictionary:
	var cfg := _load_wave_config(night_index)
	if cfg.is_empty():
		push_warning("combat_system: waves.json has no night %d config - empty plan" % night_index)
		return {"night_index": night_index, "slots": [], "batch_count": 0,
			"strength_mult": 1.0, "plan_hash": 0, "materialized_gh": -1.0}
	var day := calendar_day if calendar_day > 0 else int(State.read("time.day"))
	var strength := float(cfg.get("strength_mult", 1.0))
	var table := _load_enemy_table()
	var slots: Array = []
	for b_variant: Variant in cfg.get("batches", []):
		var b: Dictionary = b_variant
		var batch_idx := int(b.get("batch", 0))
		var enemy_id := String(b.get("enemy_id", ""))
		var entry_point := String(b.get("entry_point", "door_main"))
		var cap := int(b.get("count", 0))          # count 是上限，不是硬生成数
		var enemy: Dictionary = table.get(enemy_id, {})
		for slot in range(cap):
			# 槽位 hash：唯一允许的「随机」来源；同 (day,night,batch,slot) 恒等
			var hv := Rng.hash_at(&"SPAWN_WAVE", day, [str(night_index), str(batch_idx), str(slot)])
			slots.append({
				"batch": batch_idx,
				"slot": slot,
				"enemy_id": enemy_id,
				"entry_point": entry_point,
				"strength_mult": strength,
				# 敌人属性键名带单位后缀（M28-a）：max_hp / damage_ratio / speed_px /
				# attack_interval_sec / breach_damage_ratio
				"hp": float(enemy.get("max_hp", 0.0)) * strength,
				"damage": float(enemy.get("damage_ratio", 0.0)) * strength,
				"speed": float(enemy.get("speed_px", 0.0)),
				"attack_interval_s": float(enemy.get("attack_interval_sec", 1.0)),
				"breach_damage": float(enemy.get("breach_damage_ratio", 0.0)) * strength,
				# slot_variant 仅作表现层抖动（如朝向/步态），不参与任何 L1 判定
				"slot_variant": int(absi(hv) % 1000),
			})
	var gh := float(_config.get("wave_start_gh", 18.0))
	var plan := {
		"night_index": night_index,
		"calendar_day": day,
		"strength_mult": strength,
		"batch_count": cfg.get("batches", []).size(),
		"slots": slots,
		"materialized_gh": gh,     # 物化时刻锚点：M19 要求 18:00±1 帧
		"plan_hash": _plan_hash(night_index, day, slots),
	}
	return plan

## plan_hash：物化清单的确定性指纹（FNV-1a 风格 rolling hash，不依赖顺序消费）。
## 同 (night, day, slots) → 恒等；任一 slot 的 enemy_id/entry_point/参数变化 → 改变。
func _plan_hash(night_index: int, day: int, slots: Array) -> int:
	var h := 1469598103934665603   # FNV offset basis
	for s_variant: Variant in slots:
		var s: Dictionary = s_variant
		var key := "%d|%d|%d|%s|%s|%.4f|%.4f" % [
			int(s.get("batch", 0)), int(s.get("slot", 0)), day,
			String(s.get("enemy_id", "")), String(s.get("entry_point", "")),
			float(s.get("hp", 0.0)), float(s.get("damage", 0.0))]
		for ch in key.to_utf8_buffer():
			h = (h ^ int(ch)) * 1099511628211
	return absi(h) & 0x7FFFFFFF

## 读 waves.json 该夜配置（取顶层 wave_start_gh 等全局键 + nights[n] 的该夜配置）
func _load_wave_config(night_index: int) -> Dictionary:
	if _config.is_empty():
		var f := FileAccess.open("res://data/events/waves.json", FileAccess.READ)
		if f == null:
			return {}
		var d: Variant = JSON.parse_string(f.get_as_text())
		if typeof(d) == TYPE_DICTIONARY:
			_config = d
	var nights: Dictionary = _config.get("nights", {})
	var cfg: Variant = nights.get(str(night_index), {})
	return cfg if typeof(cfg) == TYPE_DICTIONARY else {}

## 读敌人表（纯查表，不掷骰）
func _load_enemy_table() -> Dictionary:
	if not _enemy_table.is_empty():
		return _enemy_table
	var f := FileAccess.open("res://data/enemies/enemies.json", FileAccess.READ)
	if f == null:
		push_warning("combat_system: enemies.json missing - enemy stats resolve to 0")
		return _enemy_table
	var d: Variant = JSON.parse_string(f.get_as_text())
	if typeof(d) == TYPE_DICTIONARY:
		_enemy_table = d.get("enemies", {})
	return _enemy_table

## 每次击杀推进波次进度（WAVE_DRIVEN 时钟由 TimeSystem 订阅本信号推进）
## batch_idx：被杀敌所在 batch（由生成侧给出）。batch 进度按「每 batch 已清数」记账，
## 与击杀先后顺序无关——M19 零顺序消费。
func on_enemy_killed(batch_idx: int = -1) -> void:
	_kills += 1
	if pool_remaining > 0:
		pool_remaining -= 1
	if batch_idx >= 0:
		_batch_killed[batch_idx] = int(_batch_killed.get(batch_idx, 0)) + 1
	_refresh_batches_done()
	wave_progress.emit(float(_kills) / float(maxi(_plan_total, 1)))

## 按「已清空的 batch 数」重算（三条件判据之一：所有 batch 已处理）。
## 从每 batch 的「已清 slot 数 / 总 slot 数」统计，而非按调用顺序累加——
## 计数与击杀顺序无关，同种子重放逐项相等（M19 零顺序消费）。
func _refresh_batches_done() -> void:
	if _batch_slots.is_empty():
		_batches_done = 0
		return
	_batches_done = 0
	for b_variant: Variant in _batch_slots:
		var b := int(b_variant)
		if int(_batch_killed.get(b, 0)) >= int(_batch_slots[b]):
			_batches_done += 1

## 波次是否真正打完（三条件，防「召唤池抽干 → 生成 0 → 提前通关」，架构风险登记 #1）
func is_wave_cleared() -> bool:
	return _plan_total > 0 and pool_remaining == 0 and _batches_done >= _batches_total and _kills >= _plan_total

## 安全取 LoopSystem 实例（core 层 wiring 完成后由 /root 可达；战斗组不碰 autoload 注册）
func _loop_system() -> Node:
	return get_node_or_null("/root/LoopSystem")

## 夜战结算：返回 "night_clear" 或 "breach"；breach 走 LoopSystem.pick_breach_target（任务书 §4 #5）
func settle_night() -> StringName:
	_refresh_batches_done()
	var all_batches_killed := is_wave_cleared()
	wave_active = false
	State.apply(_Store.ChangeSet.new(SOURCE, "settle").setv(StateContract.C_WAVE_ACTIVE, false))
	if all_batches_killed:
		_breach_target = &""
		return &"night_clear"
	# 破防：LoopSystem.pick_breach_target 用 hash 派生（禁 randi，候选字典序排序后取模）。
	# LoopSystem 已注册则直接调用；未接入(/root 缺失)时降级本地确定性选取并告警（不崩溃）。
	var ls := _loop_system()
	var target: StringName = &"door_panel"
	if ls != null and ls.has_method("pick_breach_target"):
		var day := int(State.read("time.day"))
		var night := int(State.read("time.night_index"))
		target = ls.pick_breach_target(PackedStringArray(["door_panel", "workbench", "filter"]), day, night)
	else:
		push_warning("combat_system: LoopSystem not wired at /root - breach target uses local fallback; awaiting core wiring")
	_breach_target = target
	breach_resolved.emit(target)
	return &"breach"

func breach_target() -> StringName:
	return _breach_target

## ── M19 断言入口（combat_arena / tests 调用）─────────────────────────
## 物化两次（同 night/day）应逐项完全相等——这是 M19「实际生成与 plan 逐项相等」的
## 机械判据：不等即说明引入了顺序消费或非常量来源。
func verify_plan_deterministic(night_index: int, calendar_day: int = -1) -> Dictionary:
	var a := materialize_wave_plan(night_index, calendar_day)
	var b := materialize_wave_plan(night_index, calendar_day)
	var slots_a: Array = a.get("slots", [])
	var slots_b: Array = b.get("slots", [])
	var equal := (slots_a.size() == slots_b.size()) and int(a.get("plan_hash", 0)) == int(b.get("plan_hash", 0))
	if equal:
		for i in range(slots_a.size()):
			# 比较实质字段：排除 slot_variant 之外全部（它也是 hash 派生，应同样相等）
			if slots_a[i] != slots_b[i]:
				equal = false
				break
	return {
		"equal": equal,
		"slot_count": slots_a.size(),
		"plan_hash": int(a.get("plan_hash", 0)),
		"materialized_gh": float(a.get("materialized_gh", -1.0)),
	}

## 波次只读访问器（供 SpawnService 消费 plan / 表现层查询，不暴露可写引用）
func wave_plan() -> Dictionary:
	return _wave_plan.duplicate(true)

func plan_total() -> int:
	return _plan_total

func strength_mult() -> float:
	return _strength

func batches_progress() -> Dictionary:
	return {"done": _batches_done, "total": _batches_total}

## 调试用：调参场景/无头自检重置（源=combat_system，过 writers 白名单）
## ⚠ 只重置体力和血量，**不动动作状态机**（_action/_timer/_iframes）——
##   战斗状态重置是另一件事，见 debug_reset_combat()。
func debug_reset_vitals() -> void:
	State.apply(_Store.ChangeSet.new(SOURCE, "debug_reset").setv("player.stamina", 100.0).setv("player.hp", 100.0))

## 调试用：把动作状态机与波次状态一并复位到 IDLE/未开波。
## 无头自检的每个用例开头必须调它——否则上个用例残留的 WINDUP/ROLLING 会让
## 下一个 player_dodge/player_attack 被 busy 守卫拒绝，断言在假状态下跑（假红）。
func debug_reset_combat() -> void:
	_action = Action.IDLE
	_timer = 0
	_iframes = 0
	_attack_queued = false
	wave_active = false
	_kills = 0
	_plan_total = 0
	pool_remaining = 0
	_batches_total = 0
	_batches_done = 0
	_batch_slots = {}
	_batch_killed = {}
	_wave_plan = {}
	_breach_target = &""
