class_name InventoryPanel
extends CanvasLayer
## inventory_panel.gd — 最小背包面板（TASK-G M1 · 表现组）
##
## ── 职责 ──   列出背包（数量>0 的物品）+ 使用消耗品 → InventorySystem.consume
##              + apply_delta（饥饿/渴/体力/HP 回升的 M1 链路终点）
## ── 不做 ──   不写 player.*（apply_delta 是 inventory_system 的白名单特权，
##              本面板只调它的公开 API）；不做拖拽/装备（M5 后深化）
## ── 键位 ──   inventory 动作（默认 I）开关；打开时模拟继续走（架构 v1.7：
##              打开面板不算持续动作中断——时间不停）
## ── 词条 ──   INV_* / ITEM_*（零中文字面量）

const _ITEMS_PATH := "res://data/items/items.json"
const COLOR_DIM := Color(0.55, 0.56, 0.6, 1.0)   # 空背包占位文案（非 HUD 域，面板本地色）

var inventory: InventorySystem      # GameWorld 注入

var _root: Control
var _rows_box: VBoxContainer
var _cap_label: Label
var _item_defs: Dictionary = {}     # item_id -> def（name_key 查 Localize）


func _ready() -> void:
	layer = 10
	_load_item_defs()
	_build()
	visible = false


func _load_item_defs() -> void:
	var f := FileAccess.open(_ITEMS_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_item_defs = (parsed as Dictionary).get("items", {})


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER, false)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(240, 180)
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
	title.text = Localize.text("INV_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	title.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	box.add_child(title)

	_cap_label = Label.new()
	_cap_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_cap_label.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	box.add_child(_cap_label)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	box.add_child(_rows_box)


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func refresh() -> void:
	if _rows_box == null or inventory == null:
		return
	for c in _rows_box.get_children():
		c.free()
	_cap_label.text = "%s %d/%d" % [Localize.text("INV_CAPACITY"),
		inventory.used(), inventory.capacity()]
	var any := false
	for item_id: String in _item_defs:
		var n := inventory.count_of(StringName(item_id))
		if n <= 0:
			continue
		any = true
		_rows_box.add_child(_make_row(item_id, n))
	if not any:
		var empty := Label.new()
		empty.text = Localize.text("INV_EMPTY")
		empty.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
		empty.add_theme_color_override("font_color", COLOR_DIM)
		_rows_box.add_child(empty)


func _make_row(item_id: String, count: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var def: Dictionary = _item_defs.get(item_id, {})
	var name_label := Label.new()
	name_label.text = "%s x%d" % [Localize.text(str(def.get("name_key", item_id))), count]
	name_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	name_label.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	name_label.custom_minimum_size = Vector2(150, 0)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	var use := Button.new()
	use.text = Localize.text("INV_USE")
	use.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	use.focus_mode = Control.FOCUS_NONE
	use.pressed.connect(_on_use.bind(item_id))
	row.add_child(use)
	return row


## 使用 1 件：consume 返回增量字典 → apply_delta 落到 player.*
## （背包扣减与状态回升都走 InventorySystem 公开 API，本面板零直接写状态）
func _on_use(item_id: String) -> void:
	if inventory == null:
		return
	var delta := inventory.consume(StringName(item_id), 1)
	inventory.apply_delta(delta)
	refresh()
