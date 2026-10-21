extends Node
## event_probe.gd — 战斗组 W3 无头验证（场景方式；`-s` 不可用，理由见 combat_probe.gd 头注）
## 用法：godot --headless res://scenes/debug/event_probe.tscn
##
## ⚠ 覆盖边界：本脚本不判 P17 的"跨存档重放"（需真实 save/load 往返），
##   判的是 P17 的**核心机制**——日志已有键时不再掷骰。

const _EventScript := preload("res://src/systems/event_system.gd")
## state_store.gd 无 class_name（autoload 名是 State），故 preload 脚本取内嵌 ChangeSet
## ——与 combat_system.gd 同款正解，不要写 StateStore.ChangeSet。
const _Store = preload("res://src/core/state_store.gd")

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

var _ev: EventSystem

func _ready() -> void:
	_ev = _EventScript.new()
	add_child(_ev)
	_run_all()
	_finish()

func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)

func _run_all() -> void:
	_test_guard()
	_test_m10_impact_whitelist()
	_test_p8_linear_stack()
	_test_p9_idempotent()
	_test_p17_replay_no_roll()
	_test_condition_predicate()
	_test_cursor_persistence()
	_test_save_section()

func _test_guard() -> void:
	_t("guard: autoload State present", get_node_or_null("/root/State") != null)
	_t("guard: autoload Rng present", get_node_or_null("/root/Rng") != null)
	_t("guard: autoload Save present", get_node_or_null("/root/Save") != null)
	_t("guard: rng salts loaded", int(Rng.hash_at(&"EVENT_ROLL", 3, ["0"])) != 0)

## M10：impact 必须落在 4 类封闭集内；越界事件被拒且不落日志
func _test_m10_impact_whitelist() -> void:
	var before := _ev.event_log.size()
	# 直接调 _fire 传一个非法 impact 的事件字典
	var bad := {"id": "ev_illegal", "impact": "script", "effects": [{"kind": "num"}]}
	var r: Dictionary = _ev._fire(bad, 3, 99)
	_t("m10: illegal impact kind rejected", r.is_empty())
	_t("m10: illegal impact not written to log", _ev.event_log.size() == before)

## P8：连续触发线性叠加（两次 fire 各自落地一次效果）
## 注：数据表用 verb=set 的绝对值语义（add 负值会被 contract 判 below-min 拒掉），
##     故此处验证「两次触发 → 日志两条 + 效果被应用两次的语义路径」，
##     而非数值线性叠加（那是 loop_system 的 num 能力，不属事件系统判据）。
func _test_p8_linear_stack() -> void:
	State.apply(_Store.ChangeSet.new("effect_sink", "p8").setv("player.thirst", 90.0))
	var def: Dictionary = _ev._event_by_id("ev_neighbor_water")
	_t("p8: event definition found", not def.is_empty())
	var n_before := _ev.event_log.size()
	_ev._fire(def, 3, 0)
	_ev._fire(def, 3, 1)
	_t("p8: two distinct slots produce two log entries",
		_ev.event_log.size() == n_before + 2)
	_t("p8: effect actually applied to state",
		is_equal_approx(float(State.read("player.thirst")), 40.0))

## P9：幂等键不重复发放（同 event_id:day:slot 第二次 fire 无效果）
func _test_p9_idempotent() -> void:
	State.apply(_Store.ChangeSet.new("effect_sink", "p9").setv("player.thirst", 90.0))
	var def: Dictionary = _ev._event_by_id("ev_neighbor_water")
	_ev._fire(def, 5, 0)
	var v1 := float(State.read("player.thirst"))
	# 同键重放前先把值改回 90：若幂等失效会再次 set 成 40
	State.apply(_Store.ChangeSet.new("effect_sink", "p9b").setv("player.thirst", 90.0))
	_ev._fire(def, 5, 0)                 # 同键重放
	var v2 := float(State.read("player.thirst"))
	_t("p9: duplicate key does not re-apply effect", is_equal_approx(v1, 40.0) and is_equal_approx(v2, 90.0))
	var count := 0
	for e_variant: Variant in _ev.event_log:
		if String((e_variant as Dictionary).get("key", "")) == "ev_neighbor_water:5:0":
			count += 1
	_t("p9: duplicate key does not duplicate log entry", count == 1)
	_test_p9_public_fire_path()

## ★ P9 幂等必须走**公开入口** fire() 测（变异测试 C7 逼出来的）
##
## 变异实测：把 fire() 里的幂等查重去掉，上述 P9 判据**一条都没红**——
## 因为它们直接调私有 _fire()，而 _fire() 内部**自己也有一层查重**，
## 于是无论 fire() 的查重坏没坏，_fire() 路径都照样拦住 → 判据形同虚设。
## → 幂等是**对外契约**，必须从公开入口 fire() 打进去才测得到。
func _test_p9_public_fire_path() -> void:
	var sys_p := _EventScript.new()
	add_child(sys_p)
	# 先用公开入口 fire() 触发一次
	sys_p.fire(&"ev_neighbor_water", {"day": 11, "slot_index": 0})
	var n_after_first := sys_p.event_log.size()
	_t("p9: public fire() logs exactly one entry", n_after_first == 1)
	# 再从公开入口重复触发同键 → 幂等：既不重复落日志，也不重复发效果
	State.apply(_Store.ChangeSet.new("effect_sink", "p9pub").setv("player.thirst", 90.0))
	sys_p.fire(&"ev_neighbor_water", {"day": 11, "slot_index": 0})
	_t("p9: public fire() duplicate key does not grow log",
		sys_p.event_log.size() == n_after_first)
	_t("p9: public fire() duplicate key does not re-apply effect",
		is_equal_approx(float(State.read("player.thirst")), 90.0))
	sys_p.queue_free()

## P17：日志已有键 → 不重新掷骰，原样回放（同一天两次 roll_daily 结果集合一致）
func _test_p17_replay_no_roll() -> void:
	var sys_a := _EventScript.new()
	add_child(sys_a)
	var first := sys_a.roll_daily(4)
	var log_snapshot := sys_a.event_log.duplicate(true)
	# 同一天重开：再 roll 一次，日志已有键应全部走"回放"分支，集合不变
	var second := sys_a.roll_daily(4)
	_t("p17: replay produces same fired set", _ids(first) == _ids(second))
	_t("p17: replay does not grow log", sys_a.event_log.size() == log_snapshot.size())
	# 不同天 → 应产生不同结果（证明确实按 day 掷骰，不是恒定）
	var other_day := sys_a.roll_daily(9)
	_t("p17: different day yields different roll", _ids(first) != _ids(other_day))
	sys_a.queue_free()

## 条件谓词：结构化 all/any/not + 比较算子，无 "!" 字符串
func _test_condition_predicate() -> void:
	State.apply(_Store.ChangeSet.new("effect_sink", "cond")
		.setv("player.hunger", 10.0)
		.setv("ui.hints.tech_L2_1_trap", false))
	var node := {"all": [
		{"path": "player.hunger", "op": "lt", "value": 20.0},
		{"path": "ui.hints.tech_L2_1_trap", "op": "eq", "value": false},
	]}
	_t("cond: all() true when both leaves true", _ev._eval_condition(node, 3))
	var node2 := {"all": [
		{"path": "player.hunger", "op": "lt", "value": 5.0},
		{"path": "ui.hints.tech_L2_1_trap", "op": "eq", "value": false},
	]}
	_t("cond: all() false when one leaf false", not _ev._eval_condition(node2, 3))
	# ★ 变异测试 C9 逼出来的：原用例的**首叶子就是假的**（hunger<5），
	#   变异把 all() 改成"只看第 1 个叶子"后仍返回 false → 判据抓不到变异。
	# → 必须再补一条**首叶子为真、次叶子为假**的用例：只看首叶子会返回 true，
	#   而正确实现必须返回 false。顺序即用例设计的关键（与「Dictionary 保序」同源）。
	var node2b := {"all": [
		{"path": "player.hunger", "op": "lt", "value": 50.0},      # 真
		{"path": "ui.hints.tech_L2_1_trap", "op": "eq", "value": true},  # 假
	]}
	_t("cond: all() false when FIRST leaf true but second false",
		not _ev._eval_condition(node2b, 3))
	var node3 := {"not": {"path": "player.hunger", "op": "gt", "value": 50.0}}
	_t("cond: not() negates leaf", _ev._eval_condition(node3, 3))
	var node4 := {"any": [
		{"path": "player.hunger", "op": "gt", "value": 999.0},
		{"path": "player.hunger", "op": "lt", "value": 20.0},
	]}
	_t("cond: any() true when one leaf true", _ev._eval_condition(node4, 3))
	# 全 6 个比较算子
	for op in ["eq", "ne", "lt", "lte", "gt", "gte"]:
		_t("cond: operator %s evaluates" % op,
			typeof(_ev._eval_condition({"path": "player.hunger", "op": op, "value": 10.0}, 3)) == TYPE_BOOL)

## 游标：定时事件按数组序消费，不重复触发
func _test_cursor_persistence() -> void:
	var sys_b := _EventScript.new()
	add_child(sys_b)
	# 游标起点 0；D3 06:00 的 ev_trap_hint 应触发
	# time.day 的 writers 只有 time_system——测试必须用合法 writer，否则 assert 崩
	State.apply(_Store.ChangeSet.new("time_system", "probe").setv("time.day", 3))
	sys_b.check_scheduled(6.5)
	_t("cursor: ev_trap_hint fired at D3 06:00", sys_b._cursor >= 1)
	var log_n := sys_b.event_log.size()
	sys_b.check_scheduled(7.0)              # 同一天再调一次，不应重复
	_t("cursor: same-day recheck does not refire", sys_b.event_log.size() == log_n)
	# D3 21:00 的第二条应触发
	sys_b.check_scheduled(21.5)
	_t("cursor: second scheduled event fired at D3 21:00", sys_b._cursor >= 2)
	sys_b.queue_free()

## 存档段：to_save/from_save 往返（C17 日志必须可复原）
func _test_save_section() -> void:
	var sys_c := _EventScript.new()
	add_child(sys_c)
	var def: Dictionary = sys_c._event_by_id("ev_neighbor_water")
	sys_c._fire(def, 6, 0)
	sys_c._cursor = 2
	var snap := sys_c._to_save()
	_t("save: section has event_log", snap.has("event_log"))
	_t("save: section has scheduled_cursor", int(snap.get("scheduled_cursor", -1)) == 2)
	_t("save: event_log persisted non-empty", (snap.get("event_log", []) as Array).size() > 0)
	# 换新实例恢复
	var sys_d := _EventScript.new()
	add_child(sys_d)
	sys_d._from_save(snap)
	_t("p7: log restored from snapshot", sys_d.event_log.size() == sys_c.event_log.size())
	_t("p7: cursor restored from snapshot", sys_d._cursor == 2)
	# 恢复后同键重放不应再发放（值改回 90，若幂等失效会被 set 成 40）
	State.apply(_Store.ChangeSet.new("effect_sink", "p7").setv("player.thirst", 90.0))
	sys_d._fire(sys_d._event_by_id("ev_neighbor_water"), 6, 0)
	_t("p10: restored log blocks re-fire (rollback diff=0)",
		is_equal_approx(float(State.read("player.thirst")), 90.0))
	sys_c.queue_free()
	sys_d.queue_free()

func _ids(arr: Array) -> Array:
	var out: Array = []
	for e_variant: Variant in arr:
		var e: Dictionary = e_variant
		out.append(String(e.get("key", "")))
	out.sort()
	return out

func _finish() -> void:
	print("--- event_probe: %d pass / %d fail ---" % [_pass, _pass + _fail])
	print("coverage: event_probe=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
	get_tree().quit(1 if _fail > 0 else 0)