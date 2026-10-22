class_name OverviewMapScene
extends Control
## overview_map_scene.gd — 总览图（TASK-G M2 · 表现组）
##
## ── 职责 ──   节点图（圆圈 + 连线 + GH 成本）/ 点击可达节点跳转 / 返回安全屋
## ── 不做 ──   不算路径（最短路是逻辑组的事，这里只读 travel_cost / neighbors）；
##              不扣时间（travel_to 在 GameWorld 里统一扣）；
##              不生成布局（那是 MapSystem.enter_node 的活）
## ── 词条 ──   OVERVIEW_* / NODE_*（零中文字面量）
## ── 美术 ──   色块灰盒（TASK-G §2：闸门过了才进资产批量）

const _Store = preload("res://src/core/state_store.gd")

# 节点在总览图上的固定布局位置（灰盒阶段手工指定，正式版迁 data/locations/overview_layout.json）
const _NODE_POS := {
	"safehouse":      Vector2(120, 200),
	"supermarket":    Vector2(360, 120),
	"department_store": Vector2(500, 200),
	"hardware_store":  Vector2(200, 320),
	"residential":    Vector2(120, 320),
	"gas_station":    Vector2(500, 120),
	"pharmacy":       Vector2(500, 280),
	"police_station": Vector2(360, 360),
	"farm":           Vector2(120, 440),
	"metro":          Vector2(560, 360),
	"radio_tower":    Vector2(680, 200),
}

const NODE_RADIUS := 22.0
const LINE_WIDTH := 3.0
## 次要文字色（HudStyle 无 COLOR_DIM，本地定义——S5 同款处置）
const COLOR_DIM := Color(0.62, 0.64, 0.68, 1.0)

var _world: GameWorld
var _current_node: StringName = &"safehouse"
var _node_buttons: Dictionary = {}   # node_id -> Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_world = GameWorld.instance()
	if _world:
		_current_node = StringName(str(State.read("map.current_node")))
	_build_ui()


func _build_ui() -> void:
	# 背景
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	add_child(bg)

	# 标题
	var title := Label.new()
	title.text = Localize.text("OVERVIEW_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE + 6)
	title.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	title.position = Vector2(16, 12)
	add_child(title)

	# 当前位置提示
	var loc := Label.new()
	loc.text = "%s: %s" % [Localize.text("OVERVIEW_TITLE"), _node_name(_current_node)]
	loc.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	loc.add_theme_color_override("font_color", COLOR_DIM)
	loc.position = Vector2(16, 34)
	add_child(loc)

	# 画布（绘边线 + 节点）
	var canvas := Control.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	canvas.position = Vector2(0, 56)
	canvas.size = Vector2(1200, 600)
	add_child(canvas)

	# 先画边线（在节点底下）
	_draw_edges(canvas)
	# 再画节点按钮（盖在边线上方）
	_draw_nodes(canvas)

	# 底部：返回按钮
	var back := _node_button("OVERVIEW_BACK", _on_back, Vector2(16, 540))
	back.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)


## 节点 id → 显示名（走 Localize，零中文字面量）
func _node_name(node_id: StringName) -> String:
	var key := "NODE_" + str(node_id).to_upper()
	var txt := Localize.text(key)
	if txt == key:
		return str(node_id)   # 词条缺失时回退 id（不崩）
	return txt


## 画所有边线 + GH 成本标注
func _draw_edges(canvas: Control) -> void:
	var ms := _world.map_sys
	for e in ms._edges:   # _edges 是 static，直接读
		var from := str(e.get("from", ""))
		var to := str(e.get("to", ""))
		if not _NODE_POS.has(from) or not _NODE_POS.has(to):
			continue
		var cost := float(e.get("travel_cost_gh", 0.0))
		var reachable := ms.travel_cost(StringName(from), StringName(to)) >= 0.0 \
			and (from == str(_current_node) or to == str(_current_node))
		_draw_line(canvas, _NODE_POS[from], _NODE_POS[to], cost, reachable)


## 画一条边线 + 成本标注
func _draw_line(canvas: Control, p1: Vector2, p2: Vector2, cost: float, reachable: bool) -> void:
	var line := Line2D.new()
	line.width = LINE_WIDTH
	line.default_color = Color(0.35, 0.36, 0.38) if reachable else Color(0.18, 0.19, 0.21)
	line.points = PackedVector2Array([p1, p2])
	canvas.add_child(line)

	# 成本标注（中点偏移，避免压住线）
	var mid := (p1 + p2) / 2.0
	var dir := (p2 - p1).normalized()
	var perp := Vector2(-dir.y, dir.x) * 14.0
	var label := Label.new()
	label.text = "%.1f" % cost
	label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 2)
	label.add_theme_color_override("font_color", Color(0.6, 0.62, 0.65))
	label.position = mid + perp - Vector2(12, 6)
	canvas.add_child(label)


## 画所有节点按钮
func _draw_nodes(canvas: Control) -> void:
	for node_id: String in _NODE_POS:
		var pos: Vector2 = _NODE_POS[node_id]
		var is_current := node_id == str(_current_node)
		var reachable := _is_reachable_from_current(StringName(node_id))

		var btn := Button.new()
		btn.name = "Node_%s" % node_id
		btn.position = pos - Vector2(NODE_RADIUS, NODE_RADIUS)
		btn.size = Vector2(NODE_RADIUS * 2, NODE_RADIUS * 2)
		btn.flat = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 1) if reachable else Color(0.5, 0.5, 0.5, 1)

		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.25, 0.45, 0.30, 1) if is_current else \
			(Color(0.20, 0.28, 0.40, 1) if reachable else Color(0.12, 0.14, 0.16, 1))
		style.border_color = Color(0.8, 0.75, 0.5, 1) if is_current else Color(0.3, 0.32, 0.35, 1)
		# Godot 4.3 的 StyleBoxFlat 没有聚合属性 `border_width`（只有 _left/_top/…），
		# 直接赋值会报 "Invalid assignment of property 'border_width'"，用 setter 一次设四边。
		style.set_border_width_all(2 if is_current else 1)
		style.set_corner_radius_all(int(NODE_RADIUS))   # 同上：聚合属性不存在，用 setter
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)

		# 节点名（按钮内）
		var lbl := Label.new()
		lbl.text = _node_name(StringName(node_id))
		lbl.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 3)
		lbl.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
		lbl.set_anchors_preset(Control.PRESET_CENTER)
		btn.add_child(lbl)

		if reachable and not is_current:
			btn.pressed.connect(_on_node_pressed.bind(node_id))
		elif is_current:
			# 当前节点：显示 GH 成本提示
			var gh := TimeSystem.gh_now()
			var gh_lbl := Label.new()
			gh_lbl.text = "%.1f GH" % gh
			gh_lbl.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 4)
			gh_lbl.add_theme_color_override("font_color", COLOR_DIM)
			gh_lbl.position = Vector2(NODE_RADIUS * 2 + 4, 4)
			btn.add_child(gh_lbl)
		else:
			# 不可达：灰显 + 无路线提示
			var nr := Label.new()
			nr.text = Localize.text("OVERVIEW_NO_ROUTE")
			nr.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 4)
			nr.add_theme_color_override("font_color", Color(0.45, 0.46, 0.48))
			nr.position = Vector2(NODE_RADIUS * 2 + 4, 4)
			btn.add_child(nr)

		canvas.add_child(btn)
		_node_buttons[node_id] = btn


## 当前节点能否直达目标
func _is_reachable_from_current(target: StringName) -> bool:
	var ms := _world.map_sys
	return ms.travel_cost(_current_node, target) >= 0.0


## 普通节点按钮（底部返回用）
func _node_button(text_key: String, action: Callable, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = Localize.text(text_key)
	b.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	b.focus_mode = Control.FOCUS_NONE
	b.position = pos
	b.custom_minimum_size = Vector2(100, 24)
	b.pressed.connect(action)
	return b


## 点击节点 → 旅行
func _on_node_pressed(node_id: String) -> void:
	var ms := _world.map_sys
	var cost := ms.travel_cost(_current_node, StringName(node_id))
	if cost < 0.0:
		return
	_world.travel_to(StringName(node_id))


## 返回「我当前所在的地点」（不是固定回安全屋）。
## 总览图是"看地图"，不是"瞬移"——按返回键回到当前节点不消耗 GH，
## 硬写 goto(&"safehouse") 会变成一条免费回城的暗门。
func _on_back() -> void:
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(_current_node)