class_name TechTreeSystem
extends Node
## tech_tree_system.gd — 科技树 【分包：包 B·模拟系统组】
##
## ── 职责 ──   节点前置校验(prereq_all_of/prereq_any_of 两字段，禁单数 prereq) /
##              研究中进度 / 图纸开启 L3 分支 / 多周目成本折扣 / display_order 仅显示
## ── 不做 ──   不实现节点效果——效果是"事件式 4 类能力"，经 effect_sink 落地
##              （科技与事件共用同一套效果系统，全项目只有一个"改世界"的调试点）
## ── 数据 ──   data/tech/tech_tree.json（语义 key 已定稿，编号=L2-7 这类只是
##              display_order 显示字段，禁止当引用锚点——设计侧已踩过 3 次坑）
## ── 判据 ──   M31(tier==ending→2个L3前置; support→1L3+1L2) P28(单局[12,16]中位14,
##              分母24) P22-0(R11 守护断言) S10(路径闭包) M30(锚点全等)
##
## ── 硬约束 ──
## · 24 节点是下限，不许再砍（覆盖率 50–67%，再砍一局全开→多周目卖点消失）
## · unlock_dismantle_bench.prereq_any_of 必须恰好等于全部 5 个 L1 key
##   （R11 缓解的目录级守护，弱化它 = 必败路径回归）
## · prereq_any_of 非空必须 ≥2 元素；all_of/any_of 不得含同一元素
## · workbench 是全部 L3 节点的公共门槛 → 已进 D8 基线四节点，不是分支是必经

func check_unlock(node_key: StringName) -> Dictionary:
	# 返回 {ok, missing: [语义key...]}——missing 为空却仍锁定 = UI 在骗人(P1.5 审核项)
	return {}  # TODO 包 B

func start_research(node_key: StringName) -> bool:
	return false  # TODO 包 B

func research_tick(delta_gh: float) -> void:
	pass  # TODO 包 B：累积研究点数，完成时经 EffectSink 触发效果

func is_unlocked(node_key: StringName) -> bool:
	return false  # TODO 包 B


# ════════════════════════════════════════════════════════════════
#  存档挂接（D-009 · 蓝图见 data/schema/save.schema.json）
# ════════════════════════════════════════════════════════════════

const PERSIST_KEY := &"tech"
const _Store = preload("res://src/core/state_store.gd")

# unlocked / researching 是**数值路径型**（tech.unlocked string_array /
# tech.researching string），已在 state_contract 里由 tech_tree_system 独家写。
# 所以本段**不维护副本**——to_save 从 State 读、from_save 往 State 写，
# State.snapshot() 与本段永远同源，不会分叉（分叉就等于两个来源）。
# blueprints / cost_multiplier 是容器型，不进 contract，存本地。

var _blueprints: PackedStringArray = PackedStringArray()
var _cost_multiplier := 1.0

func _ready() -> void:
	Save.register_persistence(PERSIST_KEY, Callable(self, "to_save"),
		Callable(self, "from_save"))


func to_save() -> Dictionary:
	return {
		"unlocked": unlocked_keys(),
		"researching": researching_node(),
		"blueprints": Array(_blueprints),
		"cost_multiplier": _cost_multiplier,
	}


func from_save(snap: Dictionary) -> void:
	_cost_multiplier = float(snap.get("cost_multiplier", 1.0))
	_blueprints = PackedStringArray()
	for b: Variant in snap.get("blueprints", []):
		_blueprints.append(String(b))
	var cs := _Store.ChangeSet.new(&"tech_tree_system", "load tech progress")
	cs.setv("tech.unlocked", unlocked_keys_from(snap))
	cs.setv("tech.researching", researching_node_from(snap))
	State.apply(cs)


func unlocked_keys() -> PackedStringArray:
	var raw: Variant = State.read("tech.unlocked")
	var out := PackedStringArray()
	if typeof(raw) == TYPE_ARRAY or typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for k: Variant in (raw as Array):
			out.append(String(k))
	return out


func researching_node() -> Variant:
	var raw: Variant = State.read("tech.researching")
	return raw if typeof(raw) == TYPE_STRING else ""


func unlocked_keys_from(snap: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k: Variant in snap.get("unlocked", []):
		out.append(String(k))
	return out


func researching_node_from(snap: Dictionary) -> String:
	var r: Variant = snap.get("researching", null)
	if typeof(r) == TYPE_STRING:
		return String(r)
	if typeof(r) == TYPE_DICTIONARY:
		return String((r as Dictionary).get("node_key", ""))
	return ""
