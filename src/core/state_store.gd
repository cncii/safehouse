extends Node
## state_store.gd — 唯一状态写入口（架构 §3.1，L2 状态层）
##
## ── 一句话契约 ──
## GameState 只能被"下降的 ChangeSet"改，改完只能被"上升的通知"观察。
## 任何读→写直达路径（例如 UI 里 player.hp -= 10）都是架构违例，
## 必须被 state_contract.json 的 writers 白名单在运行期挡住。
##
## ── debug / release 双行为 ──
## debug 构建：越权写入 assert 崩溃（问题当场暴露）
## release 构建：越权写入记日志并丢弃（QA M 判据的 rejected 计数）
##
## ── 分包规则 ──
## · 系统层只调 apply()/read()/subscribe()，禁止持有 _state 引用。
## · 新增状态路径：改 data/schema/state_contract.json（路径×类型×范围×writers）。
## · 写入者名单变更 = 架构变更，需三方过审（见 docs/模块分包说明.md §纪律）。

signal state_changed(path_prefix: String, delta: Dictionary)

class ChangeSet:
	extends RefCounted
	var source: StringName          # 谁发的："loop_system" / "event:ev_x" / "ui:hud"
	var reason: String              # 人读说明，进日志
	var ops: Array = []             # Array[Op]

	func _init(src: StringName, why: String) -> void:
		source = src
		reason = why

	func add(path: String, value: float) -> ChangeSet:
		ops.append(Op.make(path, "+", value))
		return self

	func setv(path: String, value: Variant) -> ChangeSet:
		ops.append(Op.make(path, "=", value))
		return self

	func clampv(path: String, value: float) -> ChangeSet:
		ops.append(Op.make(path, "clamp", value))
		return self

class Op:
	extends RefCounted
	var path: String
	var verb: String        # "+" | "=" | "clamp"
	var value: Variant

	static func make(p: String, v: String, val: Variant) -> Op:
		var o := Op.new()
		o.path = p
		o.verb = v
		o.value = val
		return o

class ApplyResult:
	extends RefCounted
	var ok: bool = true
	var applied: int = 0
	var rejected: Array = []        # [{op, why}]

var _state: Dictionary = {}
var _contract: Dictionary = {}   # path -> {type, min, max, writers}
var _subs: Dictionary = {}       # handle -> {prefix, cb}
var _sub_next := 0

func _ready() -> void:
	_load_contract()

func _load_contract() -> void:
	var f := FileAccess.open("res://data/schema/state_contract.json", FileAccess.READ)
	if f == null:
		push_error("state_contract.json missing - refuse boot")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_contract = parsed

## ── 唯一写入口 ──
func apply(cs: ChangeSet) -> ApplyResult:
	var result := ApplyResult.new()
	var touched: Dictionary = {}
	for op_variant: Variant in cs.ops:
		var op := op_variant as Op
		var why := _authorize(op, cs.source)
		if why != "":
			result.rejected.append({"op": op.path, "why": why})
			if OS.is_debug_build():
				assert(false, "StateStore write rejected: source=%s path=%s why=%s" % [cs.source, op.path, why])
			continue
		_mutate(op)
		result.applied += 1
		touched[_prefix_of(op.path)] = true
	result.ok = result.rejected.is_empty()
	# 通知（只通知写成功的前缀）
	for prefix: String in touched:
		state_changed.emit(prefix, {"source": cs.source, "reason": cs.reason})
	for handle: int in _subs.keys():
		var s: Dictionary = _subs[handle]
		var hit := false
		for prefix: String in touched:
			if String(s.prefix) == prefix or String(s.prefix) == "*":
				hit = true
				break
		if hit:
			(s.cb as Callable).call(cs.source, cs.reason)
	return result

func _authorize(op: Op, source: StringName) -> String:
	if not _contract.has(op.path):
		return "path not registered in contract"
	var rule: Dictionary = _contract[op.path]
	var writers: Array = rule.get("writers", [])
	if not writers.has(String(source)):
		return "writers whitelist lacks %s" % source
	# 类型校验
	match String(rule.get("type", "float")):
		"float":
			if not (op.value is float or op.value is int):
				return "expect float"
			if rule.has("min") and float(op.value) < float(rule["min"]):
				return "below min %s" % str(rule["min"])
			if rule.has("max") and float(op.value) > float(rule["max"]):
				return "above max %s" % str(rule["max"])
		"int":
			if not (op.value is int):
				return "expect int"
		"bool":
			if not (op.value is bool):
				return "expect bool"
		"string", "string_array":
			if String(op.path).ends_with("_milli") and not (op.value is int):
				return "milli field must be int (C26)"
	return ""

func _mutate(op: Op) -> void:
	var cur: Variant = _state.get(op.path, 0.0)
	match op.verb:
		"+":
			_state[op.path] = float(cur) + float(op.value)
		"=":
			_state[op.path] = op.value
		"clamp":
			_state[op.path] = maxf(float(cur), float(op.value))
	# 契约上下限夹紧
	var rule: Dictionary = _contract.get(op.path, {})
	if rule.has("min") and rule.has("max") and _state[op.path] is float:
		_state[op.path] = clampf(float(_state[op.path]), float(rule["min"]), float(rule["max"]))

## ── 只读 API ──
func read(path: String) -> Variant:
	return _state.get(path, 0.0)

func snapshot() -> Dictionary:
	return _state.duplicate(true)   # 存档/回滚用

## ── 订阅（UI/Audio 用，只读回调） ──
func subscribe(prefix: StringName, cb: Callable) -> int:
	_sub_next += 1
	_subs[_sub_next] = {"prefix": prefix, "cb": cb}
	return _sub_next

func unsubscribe(handle: int) -> void:
	_subs.erase(handle)

## ── 新局（SaveSystem 专用，唯一允许整体覆写处） ──
func reset_for_new_game(new_seed: int, difficulty: String, cycle: int) -> void:
	_state.clear()
	_state["meta.seed"] = new_seed
	_state["meta.difficulty"] = difficulty
	_state["meta.cycle"] = cycle
	_state["player.hp"] = 100.0
	_state["player.stamina"] = 100.0
	_state["player.hunger"] = 100.0
	_state["player.thirst"] = 100.0
	state_changed.emit("*", {"source": "reset_for_new_game", "reason": "new game init"})

## 供 SaveSystem 恢复整份快照（唯一第二处整体覆写，仅 load 路径）
func restore(snapshot: Dictionary) -> void:
	_state = snapshot.duplicate(true)
	state_changed.emit("*", {"source": "restore", "reason": "load restore"})

func _prefix_of(path: String) -> String:
	var dot := path.rfind(".")
	return path.substr(0, dot) if dot > 0 else path
