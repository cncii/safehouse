class_name SceneRouter
extends Node
## scene_router.gd — 场景管理 【分包：包 D·UI/UX 组】
##
## ── 职责 ──   场景加载/切换/模拟挂起/预加载
## ── 不做 ──   不驱动时间（GameLoop 唯一驱动）——"UI 打开时暂停时间"就是
##              suspend_simulation() 一个开关，不需要 12 个系统各写一遍 if paused
## ── 依赖 ──   GameLoop.set_suspended（暂停开关）· State（写 player.scene_id）
## ── 判据 ──  性能预算 #8（切场景单帧 ≤33ms，分帧实例化每帧 ≤40 节点）
##
## ── 为什么必须分帧 ──
## PackedScene.instantiate() 只是建对象，真正的开销在 add_child 那一刻：
## 所有 _ready / _enter_tree 会在同一帧里挤着跑完，这是切场景掉帧的唯一来源。
## 所以这里的做法是：先在树外把整棵子树摘下来，只挂根，再按帧分批把节点挂回去。
## 摘下来的顺序是 BFS（层序），保证挂回时父节点一定已经在树上。
##
## ── TODO ──
##  [ ] 场景注册表迁到 data/scenes.json（键名域要先与包 F 约定，暂留代码内）
##  [ ] payload 传给目标场景（等 scene_router 与目标场景的接口约定定稿）
##  [ ] 请 core 维护者补 StateContract.P_SCENE_ID，替换本文件里的字面量

const MAX_NODES_PER_FRAME := 40      # 性能预算 #8，禁放宽
const FRAME_BUDGET_MS := 33.0        # 同一条预算：单帧硬上限，超了就留给下一帧
const DEFAULT_FADE_SEC := 0.4

const _Store = preload("res://src/core/state_store.gd")

signal transition_started(scene_id: StringName)
signal transition_finished(scene_id: StringName)

enum _Phase { IDLE, FADING_OUT, LOADING, MOUNTING, FADING_IN }

# 场景注册表（TODO：迁 data/scenes.json）
const SCENE_PATHS := {
	"boot": "res://scenes/boot/boot.tscn",
	"combat_arena": "res://scenes/debug/combat_arena.tscn",
	"hud_graybox": "res://scenes/ui/hud_graybox.tscn",
	# TASK-G 灰盒主流程（表现组 M1）：
	"main_menu": "res://scenes/ui/main_menu.tscn",
	"settings": "res://scenes/ui/settings.tscn",
	# 键名与 locations.json 节点 id 严格一致（TimeSystem/存档按 player.scene_id 判定）
	"safehouse": "res://scenes/game/safehouse.tscn",
	# TASK-G M2（表现组）：总览图 + 超市灰盒
	"overview_map": "res://scenes/ui/overview_map.tscn",
	"supermarket": "res://scenes/game/supermarket.tscn",
}

var _current_id: StringName = &"boot"
var _phase := _Phase.IDLE
var _target_id: StringName = &""
var _target_path := ""
var _payload: Dictionary = {}
var _fade_sec := DEFAULT_FADE_SEC

var _fade_layer: CanvasLayer
var _fade_rect: ColorRect
var _mount_root: Node = null
var _mount_queue: Array = []
# 单深度排队（后到覆盖先到）：切场景途中的请求不再丢弃
var _pending_id: StringName = &""
var _pending_payload: Dictionary = {}
var _pending_fade := DEFAULT_FADE_SEC

func _ready() -> void:
	# 切场景期间模拟是挂起的；如果本节点跟着树一起暂停，淡入淡出就永远停在中途
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_fade()

func _build_fade() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.layer = 128
	add_child(_fade_layer)
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade_rect.modulate.a = 0.0
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_layer.add_child(_fade_rect)

## ── 对外唯一入口 ──
## ★ 切场景途中来的请求**排队一次**（后到覆盖先到），不再静默丢弃。
##
## 为什么改：直接丢弃会让"点了没反应"变成一类无声 bug——实测（2026-10-22 真链路探针）
## boot → 主菜单 → 立刻点"新游戏"：主菜单还在淡入（FADING_IN），goto(safehouse)
## 被判 transition in progress 丢掉，游戏永远停在菜单，且日志只有一行 goto_rejected。
##
## 为什么只排一个（不是队列）：连点 N 次要的只是"最后去哪"。真正危险的是
## **两个场景同时挂载**，而排队保证任一时刻只有一次挂载在跑，所以单槽足够。
func goto(scene_id: StringName, payload := {}, fade := DEFAULT_FADE_SEC) -> void:
	if _phase != _Phase.IDLE:
		_pending_id = scene_id
		_pending_payload = payload
		_pending_fade = fade
		Logger.log("scene_router", "goto_queued", "", int(_phase), String(scene_id))
		return
	var path := String(SCENE_PATHS.get(String(scene_id), ""))
	if path == "":
		push_error("SceneRouter: unknown scene_id=%s" % String(scene_id))
		return
	_target_id = scene_id
	_target_path = path
	_payload = payload
	_fade_sec = maxf(0.0, fade)
	_phase = _Phase.FADING_OUT
	GameLoop.set_suspended(true)
	transition_started.emit(_target_id)
	Logger.log("scene_router", "goto_start", "", String(_target_id))
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 1.0, _fade_sec)
	tw.tween_callback(_on_fade_out_done)

func suspend_simulation() -> void:
	GameLoop.set_suspended(true)

func resume_simulation() -> void:
	GameLoop.set_suspended(false)

func current_scene_id() -> StringName:
	return _current_id

func is_transitioning() -> bool:
	return _phase != _Phase.IDLE

func _process(_delta: float) -> void:
	match _phase:
		_Phase.LOADING:
			_poll_load()
		_Phase.MOUNTING:
			_mount_step()
		_:
			pass

func _on_fade_out_done() -> void:
	_phase = _Phase.LOADING
	ResourceLoader.load_threaded_request(_target_path)

func _poll_load() -> void:
	var st := ResourceLoader.load_threaded_get_status(_target_path)
	if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	if st != ResourceLoader.THREAD_LOAD_LOADED:
		push_error("SceneRouter: load failed: %s" % _target_path)
		_abort_transition()
		return
	var packed := ResourceLoader.load_threaded_get(_target_path) as PackedScene
	if packed == null:
		push_error("SceneRouter: not a PackedScene: %s" % _target_path)
		_abort_transition()
		return
	_phase = _Phase.MOUNTING
	_begin_mount(packed)

func _begin_mount(packed: PackedScene) -> void:
	var tree := get_tree()
	if tree == null:
		_abort_transition()
		return
	if tree.current_scene != null:
		tree.current_scene.free()
	_mount_root = packed.instantiate()
	_mount_queue = _detach_descendants(_mount_root)
	tree.root.add_child(_mount_root)
	tree.current_scene = _mount_root

## 把整棵子树从根上摘下来，返回 [{node, parent, index}]，按 BFS 层序排列。
## 层序是关键：父节点一定排在子节点之前，挂回时父节点才一定已经在树上。
func _detach_descendants(root: Node) -> Array:
	var out: Array = []
	var stack: Array = []
	for c: Node in root.get_children():
		stack.append({"node": c, "parent": root})
	while not stack.is_empty():
		var item: Dictionary = stack.pop_front()
		var node: Node = item["node"]
		var parent: Node = item["parent"]
		var idx := node.get_index()
		parent.remove_child(node)
		out.append({"node": node, "parent": parent, "index": idx})
		for gc: Node in node.get_children():
			stack.append({"node": gc, "parent": node})
	return out

func _mount_step() -> void:
	var t0 := Time.get_ticks_usec()
	var mounted := 0
	while not _mount_queue.is_empty() and mounted < MAX_NODES_PER_FRAME:
		# 预算双限：节点数 ≤40 且本帧耗时 ≤33ms，先撞哪个就停哪个
		if float(Time.get_ticks_usec() - t0) / 1000.0 > FRAME_BUDGET_MS:
			break
		var item: Dictionary = _mount_queue.pop_front()
		var node: Node = item["node"]
		var parent: Node = item["parent"]
		if not is_instance_valid(node) or not is_instance_valid(parent):
			continue
		parent.add_child(node)
		parent.move_child(node, mini(int(item["index"]), parent.get_child_count() - 1))
		mounted += 1
	if _mount_queue.is_empty():
		_finish_mount()

func _finish_mount() -> void:
	_current_id = _target_id
	_mount_root = null
	_write_scene_id()
	_phase = _Phase.FADING_IN
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 0.0, _fade_sec)
	tw.tween_callback(_on_fade_in_done)

func _on_fade_in_done() -> void:
	_phase = _Phase.IDLE
	GameLoop.set_suspended(false)
	transition_finished.emit(_current_id)
	Logger.log("scene_router", "goto_done", "", String(_current_id))
	_flush_pending()


## 淡入结束后补做排队中的那一次切换（同帧发起，不再等一帧）
func _flush_pending() -> void:
	if _pending_id == &"":
		return
	var nid := _pending_id
	var np := _pending_payload
	var nf := _pending_fade
	_pending_id = &""
	_pending_payload = {}
	_pending_fade = DEFAULT_FADE_SEC
	Logger.log("scene_router", "goto_flushed", "", String(nid), "from pending slot")
	goto(nid, np, nf)

func _abort_transition() -> void:
	_mount_queue.clear()
	_mount_root = null
	_phase = _Phase.IDLE
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 0.0, DEFAULT_FADE_SEC)
	tw.tween_callback(func() -> void: GameLoop.set_suspended(false))

## player.scene_id 在 state_contract.json 的 writers 白名单里只登记了 scene_router
## 一个写入者——所以这个写入只能在本文件发生，别的系统写了会被鉴权挡下
func _write_scene_id() -> void:
	var cs := _Store.ChangeSet.new(&"scene_router", "goto")
	cs.setv("player.scene_id", String(_current_id))   # TODO 换成 StateContract.P_SCENE_ID
	var res := State.apply(cs)
	if not res.ok:
		Logger.log("scene_router", "scene_id_rejected", "player.scene_id", res.rejected.size(), "writers whitelist")
