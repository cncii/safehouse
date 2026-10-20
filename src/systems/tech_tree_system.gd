class_name TechTreeSystem
extends Node
## tech_tree_system.gd — 科技树 【分包：包 B·模拟系统组】
##
## ── 职责 ──   节点前置校验(prereq_all_of/prereq_any_of 两字段，禁单数 prereq) /
##             研究中进度 / 图纸开启 L3 分支 / 多周目成本折扣 / display_order 仅显示
## ── 不做 ──   不实现节点效果——效果是"事件式 4 类能力"，经 effect_sink 落地
##             （科技与事件共用同一套效果系统，全项目只有一个"改世界"的调试点）
## ── 数据 ──   data/tech/tech_tree.json（语义 key 已定稿，编号=L2-7 这类只是
##             display_order 显示字段，禁止当引用锚点——设计侧已踩过 3 次坑）
## ── 判据 ──   M31(tier↔前置深度) P28(单局[12,16]中位14, 分母24) P22-0(R11 守护断言)
##             S10(路径闭包) M30(锚点全等)
##
## ── 硬约束 ──
## · 24 节点是下限，不许再砍（覆盖率 50–67%，再砍一局全开→多周目卖点消失）
## · unlock_dismantle_bench.prereq_any_of 必须恰好等于全部 5 个 L1 key
##   （R11 缓解的目录级守护，弱化它 = 必败路径回归）
## · prereq_any_of 非空必须 ≥2 元素；all_of/any_of 不得含同一元素
## · workbench 是全部 L3 节点的公共门槛 → 已进 D8 基线四节点，不是分支是必经
##
## ── 实现（逻辑组 · 2026-10-20）──────────────────────────────
##  零件结算用**注入式回调** parts_gate，不持有 InventorySystem 引用——
##  包 B 白名单禁止横向持有兄弟系统引用（见 docs/模块分包说明.md §2 包 B）。
##  回调签名 func(cost_parts: int) -> bool：true = 已成功扣除。
##  **没注入就不放行**（宁可拒绝开研究，也不假装零件白拿）。
##  研究点数 = **毫 GH 整数**（C26）：float 累加会漂，而 P7 要求读档 diff=0。
##  存档段 researching 用对象形态 {node_key, points_left, points_total}
##  （对齐 data/schema/save.schema.json）；contract 路径 tech.researching 仍是
##  string 存 node_key——两层各管各的，不互相冒充。
## ────────────────────────────────────────────────────────────

const PERSIST_KEY := &"tech"
const _Store = preload("res://src/core/state_store.gd")
const _TREE_PATH := "res://data/tech/tech_tree.json"
const POINTS_MILLI := 1000        # 1 GH = 1000 milli（研究点数与进度同一尺度）

signal research_completed(node_key: StringName)   # 节点刚解锁（效果可能同帧落地）
signal research_started(node_key: StringName)

# unlocked / researching 是**数值路径型**（tech.unlocked string_array /
# tech.researching string），已在 state_contract 里由 tech_tree_system 独家写。
# 所以本段**不维护副本**——to_save 从 State 读、from_save 往 State 写，
# State.snapshot() 与本段永远同源，不会分叉（分叉就等于两个来源）。
# blueprints / cost_multiplier / 研究点是容器型，不进 contract，存本地。

var _blueprints: PackedStringArray = PackedStringArray()
var _cost_multiplier := 1.0
var _research_points_milli := 0          # 当前研究已累积的毫 GH
var _tree: Dictionary = {}               # tech_tree.json 载入
var _nodes: Dictionary = {}              # node_key -> node
var _layers: Dictionary = {}             # layer -> [node_key...]
var _sink: EffectSink = null             # 唯一"改世界"入口（节点效果落地）

## 零件结算回调 func(cost_parts: int) -> bool。装配层注入。
var parts_gate: Callable = Callable()


func _ready() -> void:
	_load_tree()
	_sink = EffectSink.new()
	Save.register_persistence(PERSIST_KEY, Callable(self, "to_save"),
		Callable(self, "from_save"))


# ════════════════════════════════════════════════════════════════
#  前置校验
# ════════════════════════════════════════════════════════════════

## 返回 {ok, missing: [语义key...], reason}——missing 为空却仍锁定 = UI 在骗人(P1.5 审核项)
func check_unlock(node_key: StringName) -> Dictionary:
	var key := String(node_key)
	if not _nodes.has(key):
		return {"ok": false, "missing": [], "reason": "unknown_node"}
	var node: Dictionary = _nodes[key]
	var all_of: Array = node.get("prereq_all_of", [])
	var any_of: Array = node.get("prereq_any_of", [])
	var missing: Array = []
	for d: String in all_of:
		if not is_unlocked(StringName(d)):
			missing.append(d)
	# any_of：任一满足即可；全都不满足时把整组报出来（让 UI 能显示"需要其中之一"）
	if missing.is_empty() and not any_of.is_empty():
		var satisfied := false
		for d: String in any_of:
			if is_unlocked(StringName(d)):
				satisfied = true
				break
		if not satisfied:
			missing = any_of.duplicate()
	return {"ok": missing.is_empty(), "missing": missing, "reason": ""}


## 前置是否已满足（不含材料成本——成本在 start_research 里查）
func is_unlocked(node_key: StringName) -> bool:
	return String(node_key) in unlocked_keys()


## P22-0 目录级守护：unlock_dismantle_bench.prereq_any_of 必须**恰好**等于全部 5 个 L1 key。
## 弱化它 = 必败路径回归（玩家不点满 L1 就能拿拆解台 → 零件无限 → 必败洞回归）。
## 这条是**结构断言**，不随运行状态变化，所以是判据不是日志。
func validate_tree_structure() -> Dictionary:
	var problems := PackedStringArray()
	var l1: Array = _layers.get("L1", [])

	# ① 24 节点是下限（P28 的分母）
	var node_count := _nodes.size()
	if node_count < 24:
		problems.append("node count %d < 24 (P28 denominator floor)" % node_count)

	# ② P22-0：拆解台的 any_of 恰好等于全部 L1 key
	var bench: Dictionary = _nodes.get("unlock_dismantle_bench", {})
	if bench.is_empty():
		problems.append("unlock_dismantle_bench missing")
	else:
		var bench_any: Array = bench.get("prereq_any_of", [])
		var bench_set := {}
		for k: String in bench_any:
			bench_set[k] = true
		var l1_set := {}
		for k: String in l1:
			l1_set[k] = true
		if bench_set.size() != l1_set.size():
			problems.append("P22-0: dismantle_bench any_of size %d != L1 size %d"
				% [bench_set.size(), l1_set.size()])
		else:
			for k: String in l1_set:
				if not bench_set.has(k):
					problems.append("P22-0: dismantle_bench any_of missing L1 key %s" % k)
			for k: String in bench_set:
				if not l1_set.has(k):
					problems.append("P22-0: dismantle_bench any_of has non-L1 key %s" % k)

	# ③ any_of 非空必须 ≥2 元素（单元素 any_of = 伪装成"或"的"且"）
	# ④ all_of / any_of 不得含同一元素
	for key: String in _nodes:
		var node: Dictionary = _nodes[key]
		var all_of: Array = node.get("prereq_all_of", [])
		var any_of: Array = node.get("prereq_any_of", [])
		if not any_of.is_empty() and any_of.size() < 2:
			problems.append("%s: prereq_any_of must have >=2 elements" % key)
		for d: String in all_of:
			if d in any_of:
				problems.append("%s: prereq %s appears in both all_of and any_of" % [key, d])
		for d: String in all_of:
			if not _nodes.has(d):
				problems.append("%s: prereq_all_of -> unknown node %s" % [key, d])
		for d: String in any_of:
			if not _nodes.has(d):
				problems.append("%s: prereq_any_of -> unknown node %s" % [key, d])

	# ⑤ 无孤立节点：每个节点都能从根走到（可达性 = 玩家能真的点到它）
	var reach := _reachable_from_roots()
	for key: String in _nodes:
		if not reach.has(key):
			problems.append("%s: unreachable from any root node" % key)

	return {"ok": problems.is_empty(), "problems": problems,
		"node_count": node_count, "l1_count": l1.size()}


func _reachable_from_roots() -> Dictionary:
	var reach := {}
	var roots: Array = []
	for key: String in _nodes:
		var node: Dictionary = _nodes[key]
		if node.get("prereq_all_of", []).is_empty() and node.get("prereq_any_of", []).is_empty():
			roots.append(key)
	for r: String in roots:
		reach[r] = true
	var changed := true
	while changed:
		changed = false
		for key: String in _nodes:
			if reach.has(key):
				continue
			var node: Dictionary = _nodes[key]
			var all_of: Array = node.get("prereq_all_of", [])
			var any_of: Array = node.get("prereq_any_of", [])
			var all_ok := true
			for d: String in all_of:
				if not reach.has(d):
					all_ok = false
					break
			var any_ok := any_of.is_empty()
			if not any_of.is_empty():
				for d: String in any_of:
					if reach.has(d):
						any_ok = true
						break
			if all_ok and any_ok:
				reach[key] = true
				changed = true
	return reach


# ════════════════════════════════════════════════════════════════
#  研究流程
# ════════════════════════════════════════════════════════════════

## 开始研究。前置不满足 / 已在研究别的 / 零件不足 / 未注入零件回调 → 一律拒绝。
func start_research(node_key: StringName) -> bool:
	var key := String(node_key)
	if not _nodes.has(key):
		return false
	if researching_node() != "":
		return false                      # 一次只研究一个（tech.researching 是单值）
	var chk := check_unlock(node_key)
	if not bool(chk.get("ok", false)):
		return false
	var cost := int((_nodes[key] as Dictionary).get("cost_parts", 0))
	if cost > 0:
		if not parts_gate.is_valid():
			push_warning("tech_tree: parts_gate not injected - refusing research")
			return false
		if not bool(parts_gate.call(cost)):
			return false                 # 零件不足 / 扣除失败
	_research_points_milli = 0
	var cs := _Store.ChangeSet.new(&"tech_tree_system", "start research %s" % key)
	cs.setv("tech.researching", key)
	State.apply(cs)
	research_started.emit(StringName(key))
	return true


## 累积研究点数，完成时解锁并触发效果。
func research_tick(delta_gh: float) -> void:
	if delta_gh <= 0.0:
		return
	var key := researching_node()
	if key == "":
		return
	var node: Dictionary = _nodes.get(key, {})
	if node.is_empty():
		return
	var total_gh := float(node.get("research_gh", 0))
	if total_gh <= 0.0:
		return
	_research_points_milli += int(round(delta_gh * float(POINTS_MILLI)))
	var total_milli := int(round(total_gh * float(POINTS_MILLI)))
	if _research_points_milli < total_milli:
		return
	_research_points_milli = total_milli
	_complete_research(StringName(key))


func _complete_research(node_key: StringName) -> void:
	var keys := unlocked_keys()
	if not keys.has(String(node_key)):
		keys.append(String(node_key))
	var cs := _Store.ChangeSet.new(&"tech_tree_system", "unlock %s" % String(node_key))
	cs.setv("tech.unlocked", keys)
	cs.setv("tech.researching", "")
	State.apply(cs)
	_research_points_milli = 0
	# 节点效果：只有节点真的带 effects 才交给 EffectSink 落地。
	# ⚠ 当前 24 个节点**一个 effects 字段都没有**（缺数 D-015）——所以这条路径
	#   现在不会触发。留着是为了效果表补上后不用改代码结构。
	var effects: Array = (_nodes.get(String(node_key), {}) as Dictionary).get("effects", [])
	if not effects.is_empty() and _sink != null:
		_sink.resolve(effects, &"effect_sink")
	research_completed.emit(node_key)


## 已完成研究点数（毫 GH）
func research_points_milli() -> int:
	return _research_points_milli


## 距完成还差多少（毫 GH）
func research_points_left_milli() -> int:
	var key := researching_node()
	if key == "":
		return 0
	var node: Dictionary = _nodes.get(key, {})
	var total_milli := int(round(float(node.get("research_gh", 0)) * float(POINTS_MILLI)))
	return maxi(total_milli - _research_points_milli, 0)


# ════════════════════════════════════════════════════════════════
#  存档挂接（D-009 · 蓝图见 data/schema/save.schema.json）
# ════════════════════════════════════════════════════════════════

func to_save() -> Dictionary:
	return {
		"unlocked": unlocked_keys(),
		"researching": _researching_section(),
		"blueprints": Array(_blueprints),
		"cost_multiplier": _cost_multiplier,
	}


func from_save(snap: Dictionary) -> void:
	_cost_multiplier = float(snap.get("cost_multiplier", 1.0))
	_blueprints = PackedStringArray()
	for b: Variant in snap.get("blueprints", []):
		_blueprints.append(String(b))
	_research_points_milli = 0
	var node_key := ""
	var r: Variant = snap.get("researching", null)
	if typeof(r) == TYPE_DICTIONARY:
		node_key = String((r as Dictionary).get("node_key", ""))
		_research_points_milli = int((r as Dictionary).get("points_done_milli", 0))
	elif typeof(r) == TYPE_STRING:
		node_key = String(r)
	var cs := _Store.ChangeSet.new(&"tech_tree_system", "load tech progress")
	cs.setv("tech.unlocked", unlocked_keys_from(snap))
	cs.setv("tech.researching", node_key)
	State.apply(cs)


## researching 段（对象形态，对齐 save.schema.json 的 {node_key, points_left, points_total}）
func _researching_section() -> Dictionary:
	var key := researching_node()
	if key == "":
		return {}
	var node: Dictionary = _nodes.get(key, {})
	var total_milli := int(round(float(node.get("research_gh", 0)) * float(POINTS_MILLI)))
	return {
		"node_key": key,
		"points_left": maxi(total_milli - _research_points_milli, 0),
		"points_total": total_milli,
		"points_done_milli": _research_points_milli,
	}


func unlocked_keys() -> PackedStringArray:
	var raw: Variant = State.read("tech.unlocked")
	var out := PackedStringArray()
	if typeof(raw) == TYPE_ARRAY or typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for k: Variant in (raw as Array):
			out.append(String(k))
	return out


func researching_node() -> String:
	var raw: Variant = State.read("tech.researching")
	return String(raw) if typeof(raw) == TYPE_STRING else ""


func unlocked_keys_from(snap: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k: Variant in snap.get("unlocked", []):
		out.append(String(k))
	return out


# ════════════════════════════════════════════════════════════════
#  自检（P22-0 / 前置校验 / 研究流程 —— 判据本体在本文件内）
# ════════════════════════════════════════════════════════════════

func verify_tech_tree() -> Dictionary:
	var out := {}

	# ── P22-0：拆解台前置恰好等于全部 5 个 L1 key ──
	var struct_v := validate_tree_structure()
	out["P22_0_structure_ok"] = bool(struct_v.get("ok", false))
	out["P22_0_problems"] = (struct_v.get("problems", []) as PackedStringArray).size()
	out["P22_0_pass"] = bool(struct_v.get("ok", false))

	# ── P28：24 节点是分母下限 ──
	out["P28_node_count"] = int(struct_v.get("node_count", 0))
	out["P28_pass"] = int(struct_v.get("node_count", 0)) >= 24

	# ── 前置校验：未解锁时 missing 非空；解锁后 missing 为空 ──
	var probe := "unlock_dismantle_bench"
	var chk_locked := check_unlock(StringName(probe))
	out["check_missing_when_locked"] = (chk_locked.get("missing", []) as Array).size()
	out["check_locked_rejects"] = not bool(chk_locked.get("ok", true))

	# 注入假 provider：零件永远够（**先注入再调用**——没注入时 start_research 会拒）
	parts_gate = Callable(self, "_fake_parts_gate")

	# ① 锁定节点必须拒绝（拆解台：5 个 L1 key 一个都没解锁）
	var started_locked := start_research(StringName("unlock_dismantle_bench"))
	out["start_research_rejects_locked"] = not started_locked
	out["check_pass"] = out["check_locked_rejects"] and out["check_missing_when_locked"] > 0 \
		and out["start_research_rejects_locked"]

	# ② 无前置节点允许开研究
	var ok_start := start_research(StringName("unlock_water_basic"))
	out["start_ok"] = ok_start

	# ── 研究流程：时长到 → 解锁 → researching 清空 ──
	if ok_start:
		var node: Dictionary = _nodes.get("unlock_water_basic", {})
		var gh := float(node.get("research_gh", 0))
		research_tick(gh - 0.5)
		out["research_not_done_early"] = researching_node() != ""
		research_tick(0.5)
		out["research_done"] = researching_node() == ""
		out["research_unlocked"] = is_unlocked(&"unlock_water_basic")
		out["research_pass"] = out["research_done"] and out["research_unlocked"]
	else:
		out["research_pass"] = false
	return out


func _fake_parts_gate(cost: int) -> bool:
	return true


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func _load_tree() -> void:
	var f := FileAccess.open(_TREE_PATH, FileAccess.READ)
	if f == null:
		push_error("tech_tree: %s missing - refuse boot" % _TREE_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("tech_tree: %s parse failed" % _TREE_PATH)
		return
	_tree = parsed
	_nodes = parsed.get("nodes", {})
	_layers = parsed.get("layers", {})
