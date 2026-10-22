class_name SafehouseScene
extends Node2D
## safehouse_scene.gd — 安全屋灰盒场景（TASK-G M1 · 表现组）
##
## ── 职责 ──   房间轮廓 + 玩家出生 + 交互点（物资堆/床/大门）+ 拾取→背包
## ── 不做 ──   不写状态数值（拾取经 InventorySystem.add，M1 链路终点在背包）；
##              床与大门的交互后果在 M3/M2 接线（现在是无提示的占位区域）
## ── 美术 ──   色块灰盒（TASK-G §2：闸门过了才进资产批量）
## ── 场景 id ── 注册名 "safehouse"，与 locations.json 节点 id 严格一致
##              （TimeSystem.request_skip_to 按 player.scene_id=="safehouse" 判定）

const _GRAY_PATH := "res://data/balance/graybox_start.json"
const _INTERIOR := Rect2(32, 32, 576, 296)   # 内部可用区（640×360 设计分辨率）

var _world: GameWorld
var _player: PlayerAvatar
var _supplies_taken := false
var _supplies_root: Node2D


func _ready() -> void:
	_build_room()
	_world = GameWorld.instance()
	_spawn_player()
	_build_interactables()


func _build_room() -> void:
	var floor_rect := ColorRect.new()
	floor_rect.color = Color(0.13, 0.14, 0.15)
	floor_rect.position = _INTERIOR.position
	floor_rect.size = _INTERIOR.size
	add_child(floor_rect)
	# 四面墙（StaticBody2D，collision_layer=1，玩家 mask=1）
	_wall(Rect2(24, 16, 592, 16))            # 上
	_wall(Rect2(24, 328, 592, 16))           # 下
	_wall(Rect2(24, 16, 16, 328))            # 左
	_wall(Rect2(600, 16, 16, 328))           # 右


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
	visual.color = Color(0.32, 0.33, 0.35)
	visual.position = -rect.size / 2.0
	visual.size = rect.size
	body.add_child(visual)
	add_child(body)


func _spawn_player() -> void:
	_player = PlayerAvatar.new()
	_player.collision_layer = 2
	_player.collision_mask = 1
	_player.position = Vector2(320, 180)
	if _world and _world.combat:
		_player.combat = _world.combat
	add_child(_player)


func _build_interactables() -> void:
	# ── 物资堆（M1 唯一启用交互：拾取 → 背包）──
	_supplies_root = _marker(Rect2(500, 70, 26, 18), Color(0.62, 0.45, 0.25))
	var supplies_zone := InteractionZone.new(&"supplies", "INTERACT_PICK")
	supplies_zone.triggered.connect(_on_supplies_triggered)
	_supplies_root.add_child(supplies_zone)

	# ── 床（M3：睡觉 → 次日 05:00，has_bed 语义点）──
	var bed_root := _marker(Rect2(56, 56, 52, 30), Color(0.3, 0.4, 0.55))
	var bed_zone := InteractionZone.new(&"bed", "INTERACT_SLEEP")
	bed_zone.triggered.connect(_on_bed_triggered)
	bed_root.add_child(bed_zone)

	# ── 工作台（M3：科技研发面板）──
	var bench_root := _marker(Rect2(500, 250, 40, 22), Color(0.42, 0.38, 0.30))
	var bench_zone := InteractionZone.new(&"workbench", "INTERACT_RESEARCH")
	bench_zone.triggered.connect(_on_workbench_triggered)
	bench_root.add_child(bench_zone)

	# ── 大门（M2 接总览图出门）──
	var door_root := _marker(Rect2(300, 318, 44, 14), Color(0.5, 0.25, 0.2))
	var door_zone := InteractionZone.new(&"door_main", "PROMPT_EXIT")
	door_zone.triggered.connect(_on_door_triggered)
	door_root.add_child(door_zone)


func _marker(rect: Rect2, color: Color) -> Node2D:
	var root := Node2D.new()
	root.position = rect.position + rect.size / 2.0
	var visual := ColorRect.new()
	visual.color = color
	visual.position = -rect.size / 2.0
	visual.size = rect.size
	root.add_child(visual)
	add_child(root)
	return root


## 拾取：graybox_start.json 的 starter_supplies → InventorySystem.add
## （容器状态在背包侧；P13 守恒由 add 的容量截断保证）。
## 已拾取标记目前是**场景局部**的：M1 没有场景切换，M2 接出门时挪到跨日重开
## 语义的正确归属处（死亡重开同日物资应复原，与 M9 同种子一致口径相同）。
func _on_supplies_triggered(_zone_id: StringName) -> void:
	if _supplies_taken or _world == null or _world.inventory == null:
		return
	_supplies_taken = true
	for entry: Variant in _starter_supplies():
		var e: Dictionary = entry
		var n := _world.inventory.add(StringName(str(e.get("item_id", ""))), int(e.get("count", 0)))
		Logger.log("safehouse", "supplies_picked", str(e.get("item_id", "")), n, "TASK-G M1")
	_supplies_root.visible = false
	for c in _supplies_root.get_children():
		if c is InteractionZone:
			(c as InteractionZone).monitoring = false
	if _player:
		_player.current_zone = null


func _starter_supplies() -> Array:
	var f := FileAccess.open(_GRAY_PATH, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var arr: Variant = (parsed as Dictionary).get("starter_supplies", [])
	return arr if typeof(arr) == TYPE_ARRAY else []


## 大门：进总览图（不扣 GH——总览图是"看地图"不是"旅行")
func _on_door_triggered(_zone_id: StringName) -> void:
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(&"overview_map")


## 床：跳到次日 05:00（判定全在 TimeSystem：阶段A / 有床 / 在屋内）
## 成功时世界顺带做跨日自动存档；失败只记日志（灰盒不做 toast）
func _on_bed_triggered(_zone_id: StringName) -> void:
	if _world == null:
		return
	var r := _world.skip_night(true)
	if not bool(r.get("ok", false)):
		Logger.log("safehouse", "skip_night_rejected", "", 0, str(r.get("reason", "")))
		return
	Logger.log("safehouse", "skip_night_done", "", int(r.get("day", 0)), "TASK-G M3")


## 工作台：开研发面板（进度由 GameWorld 每 GH 分发 research_tick）
func _on_workbench_triggered(_zone_id: StringName) -> void:
	if _world:
		_world.toggle_research()
