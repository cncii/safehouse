extends RefCounted
## tests/test_tech.gd — 域判据：科技树结构 【包 F · W2 判据移植】
##
## 判据定义来源：tech_tree_system.gd 文件头契约（M31 tier↔前置深度）+ 任务书_逻辑组_包B §6。
## 引用版本：tech_tree.json@2026-10-20（24 节点；P28 分母由 run_tests.gd 锚定）。
##
## ⚠ 诚实边界：M31 原文缩写「ending→2个L3前置; support→1L3+1L2」中的**具体配额**
## 因 QA 判据表未落盘而无法逐字移植——本文件先落可独立判的机械部分（引用存在性 /
## 层单调 / 注册表一致 / 无环），配额部分标 pending，等 QA 原文落盘补移植。不猜、不编。

const TECH_PATH := "res://data/tech/tech_tree.json"
const LAYER_ORDER := {"L1": 1, "L2": 2, "L3": 3, "L4": 4}


static func run(host) -> void:
	var f := FileAccess.open(TECH_PATH, FileAccess.READ)
	if f == null:
		host._block(["TECH-M31-dangling", "TECH-M31-monotonic", "TECH-M31-registry", "TECH-M31-acyclic"],
			"blocked: tech_tree.json unreadable")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		host._block(["TECH-M31-dangling", "TECH-M31-monotonic", "TECH-M31-registry", "TECH-M31-acyclic"],
			"blocked: tech_tree.json parse failed")
		return
	var tree: Dictionary = parsed
	var nodes: Dictionary = tree.get("nodes", {})
	var layers: Dictionary = tree.get("layers", {})

	# 空跑判负：0 节点的树测什么都是空的
	host._t("TECH-0 tech_tree.json nodes > 0 (else all structure checks are void)",
		nodes.size() > 0)
	if nodes.size() == 0:
		host._block(["TECH-M31-dangling", "TECH-M31-monotonic", "TECH-M31-registry", "TECH-M31-acyclic"],
			"blocked: tech_tree.json empty nodes")
		return

	# ── M31-1：前置引用无悬空（引用的节点必须存在）──
	var dangling: PackedStringArray = []
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		for pre: String in (n.get("prereq_all_of", []) as Array):
			if not nodes.has(pre):
				dangling.append("%s -> %s" % [id, pre])
		for pre: String in (n.get("prereq_any_of", []) as Array):
			if not nodes.has(pre):
				dangling.append("%s -> %s" % [id, pre])
	host._t("TECH-M31-1 zero dangling prereq references (%d found)" % dangling.size(),
		dangling.is_empty())
	if not dangling.is_empty():
		print("      dangling: " + " | ".join(dangling))

	# ── M31-2：前置层不得高于本层（tier↔前置深度的机械义）──
	# 修订 #5：首版写的是「严格低于本层」，首跑红 4 处——复核（Python 独立复算一致）发现
	# 同层链式前置是数据真实形态且玩法合理（滤芯←滤水器、天台←加固门、
	# water_filter←rain_collector、sample_culture←mushroom_bed 全是同层链）。
	# 判据自己写错（把"配额判据"的机械义补成"严格分层"），修正为「不得高于」：
	# 允许同层链，禁倒挂引用更高层。能抓：L1 节点引用 L3 前置这类倒挂。
	var bad_layer: PackedStringArray = []
	for id: String in nodes:
		var n: Dictionary = nodes[id]
		var my_layer := String(n.get("layer", ""))
		if not LAYER_ORDER.has(my_layer):
			bad_layer.append("%s unknown layer '%s'" % [id, my_layer])
			continue
		for pre: String in ((n.get("prereq_all_of", []) as Array) + (n.get("prereq_any_of", []) as Array)):
			if nodes.has(pre):
				var pre_layer := String(nodes[pre].get("layer", ""))
				if int(LAYER_ORDER.get(pre_layer, 99)) > int(LAYER_ORDER[my_layer]):
					bad_layer.append("%s(L%s) needs %s(L%s)" % [id, my_layer, pre, pre_layer])
	host._t("TECH-M31-2 prereq layer not above own layer (%d violations)" % bad_layer.size(),
		bad_layer.is_empty())
	if not bad_layer.is_empty():
		print("      layer violations: " + " | ".join(bad_layer))

	# ── M31-3：layers 注册表与 nodes.layer 双向一致（无幽灵节点 / 无漏登记）──
	var registry_ok := true
	var registered := 0
	for lname: String in layers:
		for id: String in (layers[lname] as Array):
			registered += 1
			if not nodes.has(id):
				registry_ok = false
				print("      ghost in layers: " + id)
			elif String(nodes[id].get("layer", "")) != lname:
				registry_ok = false
				print("      layer mismatch: " + id)
	if registered != nodes.size():
		registry_ok = false
		print("      registered=%d nodes=%d" % [registered, nodes.size()])
	host._t("TECH-M31-3 layers registry matches nodes 1:1 (%d registered)" % registered,
		registry_ok)

	# ── M31-4：前置闭包无环（Kahn 拓扑排序必须消化全部节点）──
	var indeg := {}
	for id: String in nodes:
		indeg[id] = (nodes[id].get("prereq_all_of", []) as Array).size()
	var queue: Array = []
	for id: String in indeg:
		if int(indeg[id]) == 0:
			queue.append(id)
	var consumed := 0
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		consumed += 1
		for id: String in nodes:
			if (nodes[id].get("prereq_all_of", []) as Array).has(cur):
				indeg[id] = int(indeg[id]) - 1
				if int(indeg[id]) == 0:
					queue.append(id)
	host._t("TECH-M31-4 prereq closure acyclic (topology consumed %d/%d)" % [consumed, nodes.size()],
		consumed == nodes.size())
