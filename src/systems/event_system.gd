class_name EventSystem
extends Node
## event_system.gd — 事件系统 【分包：包 C·事件与战斗组】
##
## ── 职责 ──   三类触发（随机日内掷骰 / 定时游标 / 条件轮询）+ 夜间袭击波次编排
## ── 不做 ──   不写任何状态（产出 Effect 交给 EffectSink）；
##              不做通用脚本引擎（无表达式求值、无 on_fire 代码字段）
## ── 数据 ──   data/events/{random,scheduled,conditions}/*.json + waves.json
##              + spawn_tables.json + effect.schema.json
## ── 判据 ──   M10(impact ∈ 4类白名单) P8(连续触发线性叠加) P9(幂等键不重复发放)
##              P10(事件改开关→读档回滚 diff=0) P17/P17b(日志重放零掷骰)
##              P18(ev_trap_hint 可感知) P23(ui.hints 持久化) M28(双定义扫描)
##
## ── C17：append-only 事件日志（"重放不重新掷骰"）──
##   event_log[] 落盘，幂等键 {event_id}:{day}:{slot_index}；
##   同一天重开时按日志顺序回放——根本不掷骰，比"种子相同所以结果相同"不赌。
##
## ── 定稿事件（设计侧已交付） ──
##   ev_trap_hint：D3 06:00（曾 D5→D4→D3 改期三次 → 立基线条款：
##   事件 id 不得编码会变的数据，日期只放 trigger.day）

var event_log: Array = []            # [{key, day, slot_index, effects_applied}]
var event_cursor := 0                # 定时事件表消费游标（存档字段名）
var _cursor := 0                     # 与 event_cursor 同值镜像（内部统一用这个）

var _random_events: Array = []
var _schedule: Array = []
var _conditions: Array = []
var _random_slots: Array = [0, 1, 2, 3]
var _cond_cooldowns: Dictionary = {} # event_id -> gh 剩余冷却
var _loaded := false
var _sink: EffectSink                  # EffectSink 实例（唯一写世界入口）

## 存档注册只做一次——Save.register_persistence 遇重复 key 会 assert 崩。
## 用本脚本静态位守卫，不去读 Save 的私有字典（core 内部结构，包 C 不依赖）。
static var _persist_registered := false

func _ready() -> void:
	_sink = EffectSink.new()
	add_child(_sink)
	_load_tables()
	# D-009 挂接点：存档事件段（events）
	if not _persist_registered:
		Save.register_persistence(&"events", _to_save, _from_save)
		_persist_registered = true

## ── 载入三表 ──
func _load_tables() -> void:
	_random_events = _read_json_array("res://data/events/random/events.json", "events")
	var sched: Dictionary = _read_json_dict("res://data/events/scheduled/schedule.json")
	_schedule = sched.get("schedule", [])
	var cond: Dictionary = _read_json_dict("res://data/events/conditions/conditions.json")
	_conditions = cond.get("conditions", [])
	if not _random_events.is_empty():
		var rnd: Dictionary = _read_json_dict("res://data/events/random/events.json")
		_random_slots = rnd.get("slots", _random_slots)
	_loaded = true

func _read_json_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("event_system: missing %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if typeof(d) == TYPE_DICTIONARY else {}

func _read_json_array(path: String, key: String) -> Array:
	return _read_json_dict(path).get(key, [])

# ── 三类触发之一：随机日内掷骰 ────────────────────────────────────────
## 纯函数：每个时段槽独立用 EVENT_ROLL 槽位 hash，不累积、不顺序消费。
## 同一天重开 → 结果必然相同；且已触发过的键进日志后直接跳过（P9 幂等）。
func roll_daily(day: int) -> Array:
	var fired: Array = []
	if not _loaded:
		_load_tables()
	for slot_variant: Variant in _random_slots:
		var slot := int(slot_variant)
		var key := "%s:%d:%d" % [_pick_event_id(day, slot), day, slot]
		# P17 重放：日志里已有的键原样回放，绝不重新掷骰
		if _has_logged(key):
			fired.append(_log_entry(key))
			continue
		var ev := _event_by_id(_pick_event_id(day, slot))
		if ev.is_empty():
			continue
		var entry := _fire(ev, day, slot)
		if not entry.is_empty():
			fired.append(entry)
	return fired

## 按槽位 hash 选事件：Rng.pick(EVENT_ROLL, day, [slot])，零顺序消费
func _pick_event_id(day: int, slot: int) -> String:
	if _random_events.is_empty():
		return ""
	var eligible: Array = []
	for e_variant: Variant in _random_events:
		var e: Dictionary = e_variant
		if day >= int(e.get("trigger", {}).get("day_min", 0)):
			eligible.append(String(e.get("id", "")))
	if eligible.is_empty():
		return ""
	var idx := Rng.pick(&"EVENT_ROLL", day, [str(slot)], eligible.size())
	return String(eligible[idx])

func _event_by_id(id: String) -> Dictionary:
	for e_variant: Variant in _random_events:
		var e: Dictionary = e_variant
		if String(e.get("id", "")) == id:
			return e
	return {}

# ── 三类触发之二：定时游标 ────────────────────────────────────────────
## 触发时刻由 trigger.day + trigger.gh 唯一确定，不掷骰。
func check_scheduled(gh_now: float) -> void:
	if not _loaded:
		_load_tables()
	var day := int(State.read("time.day"))
	# 游标单调前进：从 event_cursor 起找第一条已到期的，触发后游标+1。
	# 同一天多条按数组序逐条判定；跨天靠 trigger.day 比较自然跳过。
	var guard := 0
	while _cursor < _schedule.size() and guard < 64:
		guard += 1
		var ev: Dictionary = _schedule[_cursor]
		var trig: Dictionary = ev.get("trigger", {})
		var ev_day := int(trig.get("day", 0))
		if ev_day > day:
			break                                  # 未到日：不消费
		if gh_now < float(trig.get("gh", 0.0)):
			break                                  # 未到时：不消费
		var key := "%s:%d:-1" % [String(ev.get("id", "")), day]
		if not _has_logged(key):
			_fire(ev, day, -1)
		_cursor += 1
		event_cursor = _cursor                     # 兼容旧字段（同值镜像）
	_save_cursor_soon()

## 游标推进不每次都写盘：定时事件本就低频，用 deferred 合并一次
var _cursor_dirty := false
func _save_cursor_soon() -> void:
	if _cursor_dirty:
		return
	_cursor_dirty = true
	await get_tree().process_frame
	_cursor_dirty = false
	if not bool(State.read("combat.wave_active")):  # 夜战不写档（任务书 §4 #5）
		Save.save("day_start_05_00")

# ── 三类触发之三：条件轮询（结构化谓词，禁 "!"）─────────────────────
## 每 gh_every 轮询一次；谓词全为 {all/any/not + eq/ne/lt/lte/gt/gte} 结构。
func poll_conditions(gh_now: float) -> void:
	if not _loaded:
		_load_tables()
	var day := int(State.read("time.day"))
	for c_variant: Variant in _conditions:
		var c: Dictionary = c_variant
		var ev_id := String(c.get("id", ""))
		var every := float(c.get("poll", {}).get("gh_every", 1.0))
		# 冷却未到不轮询
		if float(_cond_cooldowns.get(ev_id, 0.0)) > 0.0:
			continue
		# 只在 gh_every 的整数倍轮询（零顺序消费，纯位置判定）
		if fmod(gh_now, every) > 1e-6:
			continue
		if not _eval_condition(c.get("condition", {}), day):
			continue
		var key := "%s:%d:%d" % [ev_id, day, int(gh_now)]
		if _has_logged(key):
			continue
		if not _fire(c, day, int(gh_now)).is_empty():
			_cond_cooldowns[ev_id] = 24.0   # 冷却 1 天，防同条件反复弹提示

## 结构化谓词求值：all / any / not + 比较算子。禁 "!" 字符串，故不写 not 缩写。
func _eval_condition(node: Dictionary, day: int) -> bool:
	if node.has("all"):
		for sub_variant: Variant in node["all"]:
			if not _eval_condition(sub_variant, day):
				return false
		return true
	if node.has("any"):
		for sub_variant: Variant in node["any"]:
			if _eval_condition(sub_variant, day):
				return true
		return false
	if node.has("not"):
		return not _eval_condition(node["not"], day)
	# 叶子：{path, op, value}
	# 注：Dictionary.get 返回 Variant，工程把「从 Variant 推断类型」警告当错误，
	# 故这三处必须写显式类型。
	var cur: Variant = _read_state_path(String(node.get("path", "")), day)
	var target: Variant = node.get("value")
	var op := String(node.get("op", "eq"))
	# eq/ne 必须同类型比较：GDScript 里 float 与 bool 混比会在运行期报
	# "Invalid operands"直接崩。故先判类型是否同类，再比值。
	if op == "eq":  return _same_kind(cur, target) and cur == target
	if op == "ne":  return not (_same_kind(cur, target) and cur == target)
	if op == "lt":  return float(cur) < float(target)
	if op == "lte": return float(cur) <= float(target)
	if op == "gt":  return float(cur) > float(target)
	if op == "gte": return float(cur) >= float(target)
	push_warning("event_system: unknown condition op '%s'" % op)
	return false

## condition 里的 path 可含 {day} 模板（如 time.day → 当前天），便于跨天条件
func _read_state_path(path: String, day: int) -> Variant:
	return State.read(path.replace("{day}", str(day)))

## eq/ne 的类型守卫：数值族（int/float）互认，其余必须严格同类型。
## 缺了它，`{"op":"eq","value":false}` 对 float 值会在运行期抛 Invalid operands。
func _same_kind(a: Variant, b: Variant) -> bool:
	var a_num := (a is int or a is float)
	var b_num := (b is int or b is float)
	if a_num or b_num:
		return a_num and b_num
	if a is bool or b is bool:
		return (a is bool) and (b is bool)
	return typeof(a) == typeof(b)

# ── fire：落日志 + 交 EffectSink 落地 ────────────────────────────────
## 1) 幂等键查重（P9）→ 2) event_log 落盘（append-only，C17）
## 3) EffectSink.resolve（唯一写世界入口）→ 4) 标记已触发、当天不可回滚
func fire(event_id: StringName, ctx: Dictionary) -> void:
	var day := int(ctx.get("day", State.read("time.day")))
	var slot := int(ctx.get("slot_index", -1))
	var key := "%s:%d:%d" % [String(event_id), day, slot]
	if _has_logged(key):
		return   # P9 幂等：同键不重复发放
	var ev := _event_by_id(String(event_id))
	if ev.is_empty():
		push_warning("event_system: unknown event id '%s'" % String(event_id))
		return
	_fire(ev, day, slot)

## 落地单个事件（roll_daily / check_scheduled / poll_conditions 共用）
func _fire(ev: Dictionary, day: int, slot: int) -> Dictionary:
	var ev_id := String(ev.get("id", ""))
	var key := "%s:%d:%d" % [ev_id, day, slot]
	if _has_logged(key):
		return _log_entry(key)
	var effects: Array = ev.get("effects", [])
	# M10：impact 必须在 4 类封闭集内（schema 已 additionalProperties:false 硬校验，
	# 这里再做一次白名单防御——schema 校验在 editor 期，运行时也得挡住）
	var kind := String(ev.get("impact", ""))
	if not ["num", "flag", "time", "spawn"].has(kind):
		push_error("event_system: illegal impact kind '%s' for %s" % [kind, ev_id])
		return {}
	var entry := {"key": key, "day": day, "slot_index": slot, "effects_applied": effects.size()}
	if _sink != null:
		_sink.resolve(effects, StringName("event:" + ev_id))
	else:
		# 未入树（无头直调场景）时兜底：新建一个 EffectSink 落地，不静默丢弃效果
		_sink = EffectSink.new()
		_sink.resolve(effects, StringName("event:" + ev_id))
	event_log.append(entry)     # C17 append-only：先落地再推存档
	# 当天内不可回滚 → 强制立即存档（save_reason ∈ 白名单，S16）
	Save.save("event_fired")
	return entry

func _has_logged(key: String) -> bool:
	for e_variant: Variant in event_log:
		if String((e_variant as Dictionary).get("key", "")) == key:
			return true
	return false

func _log_entry(key: String) -> Dictionary:
	for e_variant: Variant in event_log:
		var e: Dictionary = e_variant
		if String(e.get("key", "")) == key:
			return e
	return {}

# ── 存档段（D-009：events）─────────────────────────────────────────
## 架构 5.3 events 段：triggered_today / triggered_total / scheduled_cursor /
## condition_cooldowns / wave。wave 段由 CombatSystem 写（战斗组），此处不碰。
func _to_save() -> Dictionary:
	return {
		"triggered_today": _triggered_today(),
		"triggered_total": _triggered_total(),
		"scheduled_cursor": _cursor,
		"condition_cooldowns": _cond_cooldowns.duplicate(true),
		"event_log": event_log.duplicate(true),
	}

func _from_save(snap: Dictionary) -> void:
	event_log = snap.get("event_log", [])
	_cursor = int(snap.get("scheduled_cursor", 0))
	event_cursor = _cursor   # 兼容字段（旧名保留）
	_cond_cooldowns = snap.get("condition_cooldowns", {})

func _triggered_today() -> Array:
	var day := int(State.read("time.day"))
	var out: Array = []
	for e_variant: Variant in event_log:
		if int((e_variant as Dictionary).get("day", -1)) == day:
			out.append(String((e_variant as Dictionary).get("key", "")).split(":")[0])
	return out

func _triggered_total() -> Array:
	var seen: Dictionary = {}
	for e_variant: Variant in event_log:
		seen[String((e_variant as Dictionary).get("key", "")).split(":")[0]] = true
	return seen.keys()