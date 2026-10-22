class_name InteractionZone
extends Area2D
## interaction_zone.gd — 可交互区域（TASK-G 灰盒 · 表现组）
##
## ── 职责 ──   以圆形区域感知玩家，重叠时浮出提示、玩家按交互键时发 triggered
## ── 不做 ──   不知道交互后果（拾取/睡觉/出门都是 zone_id 的消费者——场景脚本——的事）
## ── 用法 ──   zone_id = &"supplies" | &"bed" | &"door_main"；提示词条 = prompt_key
##              （零中文字面量纪律：显示文案全部走 Localize）

signal triggered(zone_id: StringName)

const _Store = preload("res://src/core/state_store.gd")
const _GRAY_PATH := "res://data/balance/graybox_start.json"

var zone_id: StringName = &""
var prompt_key: String = ""

var _hint: Label
var _radius := 28.0


func _init(id: StringName = &"", key: String = "", radius: float = -1.0) -> void:
	zone_id = id
	prompt_key = key
	if radius > 0.0:
		_radius = radius


func _ready() -> void:
	if _radius <= 0.0:
		_load_radius_default()
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = _radius
	shape.shape = circle
	add_child(shape)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_hint.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	_hint.visible = false
	_hint.position = Vector2(-30, -_radius - 16.0)
	add_child(_hint)
	monitoring = true


func _load_radius_default() -> void:
	var f := FileAccess.open(_GRAY_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_radius = float((parsed as Dictionary).get("player_interact_radius_px", _radius))


func _enter_tree() -> void:
	collision_layer = 0
	collision_mask = 2        # 玩家所在层（safehouse 场景里玩家 layer=2）


func body_entered(body: Node2D) -> void:
	if body is PlayerAvatar:
		(body as PlayerAvatar).current_zone = self
		_refresh_hint()


func body_exited(body: Node2D) -> void:
	if body is PlayerAvatar and (body as PlayerAvatar).current_zone == self:
		(body as PlayerAvatar).current_zone = null
		_refresh_hint()


func trigger() -> void:
	triggered.emit(zone_id)


func set_prompt_key(key: String) -> void:
	prompt_key = key
	_refresh_hint()


func _refresh_hint() -> void:
	if _hint == null:
		return
	var player_active := false
	for b in get_overlapping_bodies():
		if b is PlayerAvatar:
			player_active = true
			break
	_hint.visible = player_active and not prompt_key.is_empty()
	if _hint.visible:
		# 键位提示动态取当前绑定（S6 键位可重绑，文案里不硬写键名）
		_hint.text = "%s [%s]" % [Localize.text(prompt_key), _interact_key_name()]


func _interact_key_name() -> String:
	var events := InputMap.action_get_events("interact")
	if events.is_empty():
		return "E"
	var key := events[0] as InputEventKey
	if key == null:
		return "E"
	return OS.get_keycode_string(key.physical_keycode)
