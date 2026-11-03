class_name PlayerAvatar
extends CharacterBody2D
## player_avatar.gd — 玩家角色（TASK-G 灰盒 · 表现组）
##
## ── 职责 ──   WASD 移动 / 攻击·翻滚键桥接 CombatSystem / 交互键转发
## ── 不做 ──   不写四条状态（挥砍/翻滚的体力扣减在 CombatSystem 内）；
##              不判战斗结果（hit_resolved 的消费在 M2 敌方场景）
## ── 数据 ──   移速/交互半径 = data/balance/graybox_start.json（PROVISIONAL，D-D01）
## ── 判据 ──   G1（冷启动→可操作 ≤5s 的"可操作"半边）；R5 手感由 CombatSystem 承担

const _Store = preload("res://src/core/state_store.gd")
const _GRAY_PATH := "res://data/balance/graybox_start.json"

## 占位精灵 + 统一色板 shader（视觉替换，不影响逻辑）
const _PALETTE_SHADER := preload("res://assets/shaders/palette_map.gdshader")
const _PALETTE_LUT := preload("res://assets/sprites/ui/ui_palette_db32.png")
const _HERO_WALK := {
	"down": preload("res://assets/sprites/chars/char_hero_walk_down.png"),
	"up": preload("res://assets/sprites/chars/char_hero_walk_up.png"),
	"left": preload("res://assets/sprites/chars/char_hero_walk_left.png"),
	"right": preload("res://assets/sprites/chars/char_hero_walk_right.png"),
}
const _HERO_ATTACK := {
	"down": preload("res://assets/sprites/chars/char_hero_attack_down.png"),
	"up": preload("res://assets/sprites/chars/char_hero_attack_up.png"),
	"left": preload("res://assets/sprites/chars/char_hero_attack_left.png"),
	"right": preload("res://assets/sprites/chars/char_hero_attack_right.png"),
}
const _HERO_ROLL := {
	"down": preload("res://assets/sprites/chars/char_hero_roll_down.png"),
	"up": preload("res://assets/sprites/chars/char_hero_roll_up.png"),
	"left": preload("res://assets/sprites/chars/char_hero_roll_left.png"),
	"right": preload("res://assets/sprites/chars/char_hero_roll_right.png"),
}

var combat: CombatSystem          # GameWorld 注入（不横向 new）
var current_zone: InteractionZone = null

var _speed_px := 120.0
var _facing := Vector2.RIGHT
## 挥砍/翻滚的表现占位：动作期间染色的短暂方块（M2 换正式动画）
var _action_flash: ColorRect
## 占位精灵主体（替换原 ColorRect 色块；modulate 不在此文件使用）
var _body: Sprite2D


func _ready() -> void:
	_load_graybox()
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 8.0
	shape.shape = circle
	add_child(shape)
	# 占位精灵：替换原色块 body（脚底落在碰撞圆原点附近）
	_body = Sprite2D.new()
	_body.texture = _HERO_WALK["down"]
	_body.position = Vector2(0, -16)
	var mat := ShaderMaterial.new()
	mat.shader = _PALETTE_SHADER
	mat.set_shader_parameter("enabled", true)
	mat.set_shader_parameter("palette_tex", _PALETTE_LUT)
	mat.set_shader_parameter("mix_strength", 1.0)
	mat.set_shader_parameter("alpha_cut", 1.0)
	_body.material = mat
	add_child(_body)
	_action_flash = ColorRect.new()
	_action_flash.color = Color(0.95, 0.6, 0.3)
	_action_flash.size = Vector2(10, 4)
	_action_flash.position = Vector2(6, -2)
	_action_flash.visible = false
	add_child(_action_flash)


func _load_graybox() -> void:
	var f := FileAccess.open(_GRAY_PATH, FileAccess.READ)
	if f == null:
		push_warning("player_avatar: graybox_start.json missing - defaults")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_speed_px = float((parsed as Dictionary).get("player_move_speed_px_per_sec", _speed_px))


func _physics_process(_delta: float) -> void:
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * _speed_px
	if dir != Vector2.ZERO:
		_facing = dir.normalized()
	move_and_slide()
	_update_flash()
	# 视觉：移动或动作中时切换占位精灵朝向/动作帧（空闲保留上一帧）
	if dir != Vector2.ZERO or (combat != null and combat.current_action() != 0):
		_apply_facing_sprite()
	if combat == null:
		return
	if Input.is_action_just_pressed("attack"):
		var r := combat.player_attack(_facing)
		if r.get("ok", false):
			_show_flash()
	elif Input.is_action_just_pressed("dodge"):
		combat.player_dodge(_facing)
	elif Input.is_action_just_pressed("interact"):
		if current_zone != null:
			current_zone.trigger()
	elif Input.is_action_just_pressed("inventory"):
		var world := GameWorld.instance()
		if world:
			world.toggle_inventory()
	elif Input.is_action_just_pressed("tech_tree"):
		var world2 := GameWorld.instance()
		if world2:
			world2.toggle_research()


func _update_flash() -> void:
	if combat == null or _action_flash == null:
		return
	_action_flash.visible = combat.current_action() != 0   # 0 = Action.IDLE
	_action_flash.position = Vector2(6, -2) if _facing.x >= 0.0 else Vector2(-16, -2)


func _show_flash() -> void:
	if _action_flash:
		_action_flash.visible = true


## 占位精灵：依据 _facing 选 walk 帧；combat 动作态选 attack/roll 帧。
## 仅做视觉切换，纯查表，缺图时通过 .get 兜底不崩。
func _apply_facing_sprite() -> void:
	if _body == null:
		return
	var d := "down"
	if abs(_facing.x) > abs(_facing.y):
		d = "right" if _facing.x > 0.0 else "left"
	elif _facing.y < 0.0:
		d = "up"
	var tex: Texture2D = null
	if combat != null:
		var act := combat.current_action()
		if act == 3:          # CombatSystem.Action.ROLLING
			tex = _HERO_ROLL.get(d, null)
		elif act == 1 or act == 2:   # WINDUP / RECOVER → 攻击帧
			tex = _HERO_ATTACK.get(d, null)
	if tex == null:
		tex = _HERO_WALK.get(d, null)
	if tex != null and _body.texture != tex:
		_body.texture = tex
