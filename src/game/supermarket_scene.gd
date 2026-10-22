class_name SupermarketScene
extends Node2D
## supermarket_scene.gd — 超市灰盒场景（TASK-G M2 · 表现组）
##
## ── 职责 ──   超市灰盒房间 + 掉落点交互 + 1 只丧尸 + 出门返回总览图
## ── 不做 ──   不写状态数值（拾取经 MapSystem.loot_take → InventorySystem.add）；
##              不生成掉落（MapSystem.enter_node / loot_point 是唯一入口）；
##              不算路径（回总览图走 SceneRouter）
## ── 场景 id ──   注册名 "supermarket"，与 locations.json 节点 id 严格一致
## ── 美术 ──   色块灰盒（TASK-G §2）

const _INTERIOR := Rect2(24, 24, 720, 480)   # 内部可用区（768×528 设计分辨率）

var _world: GameWorld
var _player: PlayerAvatar
var _zombie: EnemyAvatar
var _loot_zones: Dictionary = {}   # point_id -> InteractionZone
var _exit_zone: InteractionZone
## 本场景代表的地点 id —— **与 SceneRouter 注册键严格一致**。
## 不能读 State.read("map.current_node")：那个值是 enter_node() 自己写的，
## 读它就变成"先有鸡还是先有蛋"——从安全屋出门时读到的还是 safehouse，
## 于是按家来生成布局（0 个可搜点，实测 zones=0）。地点身份属于场景，
## 不属于"上一次去过哪"。
const NODE_ID := &"supermarket"

var _layout: Dictionary = {}
var _node_id: StringName = NODE_ID


func _ready() -> void:
	_world = GameWorld.instance()
	_enter_location()
	_build_room()
	_spawn_player()
	_spawn_zombie()
	_build_loot_points()
	_build_exit()


## ── 进入地点：调 MapSystem.enter_node 拿布局 ─────────────────────────
func _enter_location() -> void:
	var ms := _world.map_sys
	var day := int(State.read("time.day"))
	_layout = ms.enter_node(_node_id, day)
	if not _layout.get("ok", false):
		push_error("supermarket_scene: enter_node failed: %s" % _layout.get("reason", ""))
		return
	Logger.log("supermarket", "enter", str(_node_id), _layout.get("rooms", []).size(), "TASK-G M2")


## ── 房间轮廓（灰盒色块） ──────────────────────────────────────────
func _build_room() -> void:
	var floor_rect := ColorRect.new()
	floor_rect.color = Color(0.15, 0.16, 0.18)
	floor_rect.position = _INTERIOR.position
	floor_rect.size = _INTERIOR.size
	add_child(floor_rect)

	# 四面墙
	_wall(Rect2(16, 16, 736, 16))            # 上
	_wall(Rect2(16, 496, 736, 16))           # 下
	_wall(Rect2(16, 16, 16, 480))            # 左
	_wall(Rect2(736, 16, 16, 480))           # 右


func _wall(rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = rect.position + rect.size / 2.0
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	body.add_child(shape)
	var visual := ColorRect.new()
	visual.color = Color(0.35, 0.36, 0.38)
	visual.position = -rect.size / 2.0
	visual.size = rect.size
	body.add_child(visual)
	add_child(body)


## ── 玩家出生（超市入口） ──────────────────────────────────────────
func _spawn_player() -> void:
	_player = PlayerAvatar.new()
	_player.collision_layer = 2
	_player.collision_mask = 1
	_player.position = Vector2(80, 440)      # 左下角入口
	if _world and _world.combat:
		_player.combat = _world.combat
	add_child(_player)


## ── 丧尸（1 只，放在超市深处） ────────────────────────────────────
func _spawn_zombie() -> void:
	_zombie = EnemyAvatar.new()
	_zombie.position = Vector2(400, 120)
	_zombie.name = "EnemyZombie"
	add_child(_zombie)


## ── 掉落点：从布局生成，每个点挂 InteractionZone ──────────────────
func _build_loot_points() -> void:
	var points: Array = _layout.get("loot_points", [])
	for p_variant: Variant in points:
		var p: Dictionary = p_variant
		var pid := str(p.get("id", ""))
		if pid == "":
			continue
		# 掉落点位置：布局给的 offset 是相对房间的，这里简化为相对内部区
		var ox := float(p.get("offset_x_px", 0))
		var oy := float(p.get("offset_y_px", 0))
		var pos := Vector2(_INTERIOR.position.x + 64 + ox, _INTERIOR.position.y + 48 + oy)

		var root := Node2D.new()
		root.position = pos
		add_child(root)

		# 视觉：色块标记（有掉落=黄，空箱=灰）
		var visual := ColorRect.new()
		var has_drop := _has_drop(p)
		visual.color = Color(0.6, 0.5, 0.2) if has_drop else Color(0.25, 0.25, 0.28)
		visual.size = Vector2(14, 14)
		visual.position = Vector2(-7, -7)
		root.add_child(visual)

		var zone := InteractionZone.new(StringName(pid), "INTERACT_PICK")
		# zone_id 就是 point_id（InteractionZone 构造时传的就是 pid），不必再 bind，
		# bind 会让回调多收一个参数（Method expected 1 arguments, but called with 2）。
		zone.triggered.connect(_on_loot_triggered)
		root.add_child(zone)
		_loot_zones[pid] = zone


## 这个掉落点是否有东西（loot_point 非空）
func _has_drop(point: Dictionary) -> bool:
	var ms := _world.map_sys
	var day := int(State.read("time.day"))
	var drops := ms.loot_point(_node_id, StringName(str(point.get("id", ""))), day)
	return not drops.is_empty()


## ── 拾取：loot_take → InventorySystem.add ─────────────────────────
func _on_loot_triggered(zone_id: StringName) -> void:
	var point_id := str(zone_id)
	if _world == null or _world.inventory == null or _world.map_sys == null:
		return
	var ms := _world.map_sys
	var day := int(State.read("time.day"))
	var result := ms.loot_take(_node_id, StringName(point_id), day)
	if not result.get("ok", false):
		Logger.log("supermarket", "loot_rejected", point_id, 0, str(result.get("reason", "")))
		return
	var added: Array = result.get("added", [])
	for e_variant: Variant in added:
		var e: Dictionary = e_variant
		var iid := str(e.get("item_id", ""))
		var n := int(e.get("count", 0))
		if iid == "" or n <= 0:
			continue
		var took := _world.inventory.add(StringName(iid), n)
		Logger.log("supermarket", "loot_taken", iid, took, "TASK-G M2")
	# 拾取后视觉消掉
	var zone: InteractionZone = _loot_zones.get(point_id) as InteractionZone
	if zone:
		var root := zone.get_parent()
		if root:
			for c in root.get_children():
				if c is ColorRect:
					(c as ColorRect).modulate.a = 0.3
		zone.monitoring = false
		if _player:
			_player.current_zone = null


## ── 出门：返回总览图 ──────────────────────────────────────────────
func _build_exit() -> void:
	var root := Node2D.new()
	root.position = Vector2(700, 460)
	add_child(root)

	var visual := ColorRect.new()
	visual.color = Color(0.4, 0.35, 0.25)
	visual.size = Vector2(20, 14)
	visual.position = Vector2(-10, -7)
	root.add_child(visual)

	_exit_zone = InteractionZone.new(&"exit", "PROMPT_EXIT")
	_exit_zone.triggered.connect(_on_exit_triggered)
	root.add_child(_exit_zone)


func _on_exit_triggered(_zone_id: StringName) -> void:
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(&"overview_map")


## ── 判据/联调用的只读观察口（不给外部改状态的入口） ──────────────
func layout() -> Dictionary:
	return _layout


func zombie() -> EnemyAvatar:
	return _zombie


func loot_zone_ids() -> Array:
	return _loot_zones.keys()