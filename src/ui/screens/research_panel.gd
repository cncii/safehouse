class_name ResearchPanel
extends CanvasLayer
## research_panel.gd — 科技研发面板（TASK-G M3 · 表现组）
##
## ── 职责 ──   列科技节点（解锁态 / 前置缺失 / 零件成本 / 研发时长）/
##             开始研发 / 显示进行中节点的剩余 GH（硬约束 4：耗时动作用前给预期时长）
## ── 不做 ──   不判前置（`check_unlock` 是 TechTreeSystem 的活）、不扣零件
##             （注入式 `parts_gate` 由 GameWorld 提供）、不推进研发
##             （`research_tick` 由 GameWorld 每 GH 边界分发）
## ── 词条 ──   TECH_*（零中文字面量）

const _TECH_PATH := "res://data/tech/tech_tree.json"
const COLOR_DIM := Color(0.55, 0.56, 0.6, 1.0)
const COLOR_WARN := Color(0.85, 0.6, 0.25, 1.0)
const COLOR_OK := Color(0.45, 0.75, 0.5, 1.0)

var world: GameWorld          # GameWorld 注入

var _root: Control
var _rows_box: VBoxContainer
var _status: Label
var _nodes: Dictionary = {}   # node_key -> node def


func _ready() -> void:
	layer = 10
	_load_tree()
	_build()
	visible = false


func _load_tree() -> void:
	var f := FileAccess.open(_TECH_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_nodes = (parsed as Dictionary).get("nodes", {})


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER, false)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(320, 240)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.96)
	style.border_color = Color(0.4, 0.42, 0.45)
	style.set_border_width_all(1)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = Localize.text("TECH_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	title.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	box.add_child(title)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_status.add_theme_color_override("font_color", COLOR_DIM)
	box.add_child(_status)

	var scroll := ScrollContainer.new()   # 24 个节点放不进 360p 视口，必须可滚动
	scroll.custom_minimum_size = Vector2(300, 170)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func refresh() -> void:
	if _rows_box == null or world == null or world.tech_sys == null:
		return
	for c in _rows_box.get_children():
		c.free()
	var tech := world.tech_sys
	var cur := tech.researching_node()
	_status.text = ""
	if cur != "":
		# milli → GH：尺度常量取 TechTreeSystem.POINTS_MILLI，不在面板里重写 1000
		var left_gh := float(tech.research_points_left_milli()) \
			/ float(TechTreeSystem.POINTS_MILLI)
		_status.text = "%s: %s  %s" % [
			Localize.text("TECH_RESEARCHING"), cur,
			Localize.textf("TECH_REMAINING", {"gh": "%.1f" % left_gh})]
		_status.add_theme_color_override("font_color", COLOR_WARN)
	else:
		_status.add_theme_color_override("font_color", COLOR_DIM)

	for key: String in _nodes:
		_rows_box.add_child(_make_row(tech, key, cur))


func _make_row(tech: TechTreeSystem, key: String, researching: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var node: Dictionary = _nodes.get(key, {})

	var name_label := Label.new()
	name_label.text = "%s  [%d]" % [key, int(node.get("cost_parts", 0))]
	name_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 2)
	name_label.custom_minimum_size = Vector2(170, 0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE - 2)
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(96, 20)

	if tech.is_unlocked(StringName(key)):
		name_label.add_theme_color_override("font_color", COLOR_OK)
		btn.text = Localize.text("TECH_UNLOCKED")
		btn.disabled = true
	elif key == researching:
		name_label.add_theme_color_override("font_color", COLOR_WARN)
		btn.text = Localize.text("TECH_RESEARCHING")
		btn.disabled = true
	else:
		var chk := tech.check_unlock(StringName(key))
		name_label.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
		if not bool(chk.get("ok", false)):
			btn.text = Localize.text("TECH_LOCKED")
			btn.disabled = true
			# 前置缺失时把缺的 key 直接摆出来（"锁着但不说为什么"是 P1.5 审核项）
			name_label.text += "  (%s)" % ",".join(chk.get("missing", []))
		else:
			# 硬约束 4：耗时动作开始前必须给可预期时长
			btn.text = "%s %.1fGH" % [Localize.text("TECH_START"),
				float(node.get("research_gh", 0.0))]
			btn.disabled = researching != ""
			btn.pressed.connect(_on_start.bind(key))

	row.add_child(name_label)
	row.add_child(btn)
	return row


func _on_start(key: String) -> void:
	if world == null:
		return
	var r := world.start_research(StringName(key))
	if not bool(r.get("ok", false)) and str(r.get("reason", "")) == "no_parts":
		_status.text = Localize.text("TECH_NO_PARTS")
		_status.add_theme_color_override("font_color", COLOR_WARN)
	refresh()
