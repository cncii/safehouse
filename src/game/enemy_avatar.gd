class_name EnemyAvatar
extends CharacterBody2D
## enemy_avatar.gd — 丧尸灰盒（TASK-G M2 · 表现组）
##
## ── 职责 ──   单只丧尸的 AI（追玩家 / 近战攻击 / 受击 / 死亡）
## ── 不做 ──   不持有 CombatSystem（攻击伤害由 combat.on_hit_received 消费）；
##              不生成自己（M2 灰盒场景直接 new，正式版走 SpawnService）；
##              不写状态（死亡记日志由场景调用方负责）
## ── 数据 ──   data/balance/graybox_start.json（PROVISIONAL，D-D02）
## ── 美术 ──   色块灰盒（TASK-G §2）

const _GRAY_PATH := "res://data/balance/graybox_start.json"

var hp: float = 60.0
var damage: float = 12.0
var move_speed_px: float = 55.0
var attack_cooldown_frames: int = 45       # ≈0.75s 攻击间隔
var attack_range_px: float = 18.0           # 近战攻击距离

var _player: PlayerAvatar = null
var _combat: CombatSystem = null
var _attack_timer := 0
var _dead := false
var _hit_flash := 0     # 受击闪烁剩余帧

var _body: ColorRect
var _hp_bar: ColorRect


func _ready() -> void:
	_load_graybox()
	_body = ColorRect.new()
	_body.color = Color(0.55, 0.15, 0.12)
	_body.size = Vector2(16, 16)
	_body.position = Vector2(-8, -8)
	add_child(_body)

	_hp_bar = ColorRect.new()
	_hp_bar.color = Color(0.2, 0.55, 0.2)
	_hp_bar.size = Vector2(16, 3)
	_hp_bar.position = Vector2(-8, -12)
	add_child(_hp_bar)

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 8.0
	shape.shape = circle
	add_child(shape)

	collision_layer = 4       # 敌人层
	collision_mask = 2 | 4    # 玩家(2) + 敌人(4)

	# 订阅 CombatSystem 的判定帧（命中结算）
	_combat = _find_combat()
	if _combat:
		_combat.hit_resolved.connect(_on_hit_resolved)


func _find_combat() -> CombatSystem:
	var world := GameWorld.instance()
	return world.combat if world else null


func _load_graybox() -> void:
	var f := FileAccess.open(_GRAY_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d := parsed as Dictionary
	var enemy: Variant = d.get("enemy_zombie", {})
	if enemy is Dictionary:
		hp = float(enemy.get("hp_units", hp))
		damage = float(enemy.get("damage_units", damage))
		move_speed_px = float(enemy.get("move_speed_px_per_sec", move_speed_px))
		attack_cooldown_frames = int(enemy.get("attack_cooldown_frames", attack_cooldown_frames))
		attack_range_px = float(enemy.get("attack_range_px", attack_range_px))


func _physics_process(_delta: float) -> void:
	if _dead:
		return
	# 受击闪烁
	if _hit_flash > 0:
		_hit_flash -= 1
		_body.modulate = Color(1, 0.4, 0.4) if _hit_flash % 4 < 2 else Color(1, 1, 1)
		if _hit_flash == 0:
			_body.modulate = Color(1, 1, 1)

	# 攻击冷却
	if _attack_timer > 0:
		_attack_timer -= 1

	# 追玩家
	_player = _find_player()
	if _player == null:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var dir := (_player.position - position).normalized()
	velocity = dir * move_speed_px
	move_and_slide()

	# 近战攻击：贴身且冷却好了
	if position.distance_to(_player.position) <= attack_range_px and _attack_timer <= 0:
		_do_attack()


## 丧尸攻击 → CombatSystem.on_hit_received（玩家受击）
func _do_attack() -> void:
	if _combat == null:
		return
	_attack_timer = attack_cooldown_frames
	_combat.on_hit_received(damage)


## 玩家挥砍命中判定帧 → 检查方向是否指向本丧尸
func _on_hit_resolved(result: Dictionary) -> void:
	if _dead or _player == null or _combat == null:
		return
	# 玩家朝向的射线是否碰得到本丧尸
	var to_us := (position - _player.position).length()
	if to_us > 60.0:      # 挥砍射程外
		return
	var facing := _player._facing
	if facing.length() < 0.1:
		return
	if facing.normalized().dot((position - _player.position).normalized()) < 0.6:
		return    # 不在前方

	var dmg := float(result.get("damage", 0.0))
	if dmg <= 0:
		return
	apply_damage(dmg)


## 承受伤害（公开入口——判定帧与判据都走这里，避免判据去复制"朝向/射程"那套内务）
func apply_damage(dmg: float) -> void:
	if _dead or dmg <= 0.0:
		return
	hp -= dmg
	_hit_flash = 6
	_refresh_hp_bar()
	Logger.log("enemy_avatar", "zombie_hit", "", int(dmg), "TASK-G M2")
	if hp <= 0.0:
		_die()


func is_dead() -> bool:
	return _dead


func _refresh_hp_bar() -> void:
	if _hp_bar:
		_hp_bar.size = Vector2(maxi(0, 16 * hp / 60.0), 3)


func _die() -> void:
	_dead = true
	velocity = Vector2.ZERO
	_body.modulate = Color(0.3, 0.3, 0.35)
	_hp_bar.visible = false
	Logger.log("enemy_avatar", "zombie_killed", "", 0, "TASK-G M2")
	# 场景侧负责在 2 秒后 queue_free（或由场景监听 dead 信号）


func _find_player() -> PlayerAvatar:
	var world := GameWorld.instance()
	if world == null:
		return null
	# 玩家在当前场景的子树里（场景脚本挂的 PlayerAvatar）
	return get_tree().root.find_child("Player*", true, false) as PlayerAvatar