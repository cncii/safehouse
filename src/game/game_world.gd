class_name GameWorld
extends Node
## game_world.gd — 对局根（TASK-G 灰盒 · 表现组牵头）
##
## ── 职责 ──   把已建好的系统实例化成"一局"：新局编排 / GameLoop→系统分发 /
##              HUD 与全局面板挂载 / 死亡与重开钩子
## ── 不做 ──   不写任何游戏规则（四条状态归 Vitals、产出归 Loop、掉落归 Map）；
##              不持有场景（场景归 SceneRouter）；不改 core 与它系统文件
## ── 为什么挂 root 直属 ──   SceneRouter 切场景会 free 掉 current_scene——
##              系统、HUD、背包面板必须活在 current_scene 之外才能跨场景存活
## ── 分发契约 ──   各系统里只有 VitalsSystem 自连 GameLoop（历史既成）；
##              其余系统（Time/Combat/Loop/Tech/Event）的结算点由本类统一分发，
##              这是"唯一时间驱动者"架构下唯一合法的接法：GameLoop 发 tick，
##              GameWorld 转译，系统被动接收——没有任何系统自己 push 时间

const _Store = preload("res://src/core/state_store.gd")
const _GRAY_PATH := "res://data/balance/graybox_start.json"
const _TIME_PATH := "res://data/balance/time.json"

## 协作标记：初局种子固定为 1（灰盒可复现，联调/截图/判据都受益）。
## 正式游戏的随机种子在 M5 前接入（届时从 wall-clock 熵取，禁 randi()）。
const GRAYBOX_SEED := 1

var time_sys: TimeSystem
var vitals: VitalsSystem
var inventory: InventorySystem
var map_sys: MapSystem
var combat: CombatSystem
var hud: HudRoot
var inv_panel: InventoryPanel

var _last_gh_int := -1


static func instance() -> GameWorld:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("GameWorld") as GameWorld


func _ready() -> void:
	name = "GameWorld"
	var loop := get_node_or_null("/root/GameLoop")
	if loop:
		if not loop.ticked.is_connected(_on_ticked):
			loop.ticked.connect(_on_ticked)
		if not loop.gh_crossed.is_connected(_on_gh_crossed):
			loop.gh_crossed.connect(_on_gh_crossed)


## ── 新局编排（主菜单"新游戏"调用）────────────────────────────
## 顺序即依赖：Rng 种子先立（day_seed 的根）→ State 归位 → 时钟归位 →
## 实例化系统（_ready 里各自连 GameLoop/注册存档段）→ 地图初始 → 挂 HUD。
## 调用方（main_menu）随后自行 SceneRouter.goto(&"safehouse")。
func start_new_game(seed_value: int = GRAYBOX_SEED) -> void:
	if time_sys != null:
		push_warning("GameWorld: start_new_game on a live run - ignored")
		return
	Rng.setup(seed_value)
	State.reset_for_new_game(seed_value, "normal", 1)
	# 新局从 05:00（prep_start_gh）起步——时钟语义见 time_system（gh=当日钟点）
	GameLoop.reset(_prep_mark_frames())
	_instantiate_systems()
	_init_map_progress()
	_mount_ui()


## ── 读档编排（M3 接存档往返时补全 restore 各段；M1 先立骨架）──
func continue_game() -> bool:
	var run := Save.load_run()
	if run.is_empty():
		return false
	if time_sys != null:
		return true   # 已在对局中（例如读档后回到主菜单再继续）
	var rnd: Dictionary = run.get("random", {})
	Rng.setup(int(rnd.get("global_seed", GRAYBOX_SEED)))
	_instantiate_systems()
	var t: Dictionary = run.get("time", {})
	TimeSystem.time_restore(t)
	GameLoop.reset(_prep_mark_frames() + int(float(t.get("gh_elapsed_today", 0.0))
		* float(GameLoop.FRAMES_PER_GH)))
	State.restore(run.get("state", {}))
	# 各系统容器段经 Save.apply_persisted 分发（save_system 统一入口）
	Save.apply_persisted(run)
	_init_map_progress()
	_mount_ui()
	return true


func _instantiate_systems() -> void:
	time_sys = TimeSystem.new()
	add_child(time_sys)
	vitals = VitalsSystem.new()
	vitals.died.connect(_on_player_died)
	add_child(vitals)
	inventory = InventorySystem.new()
	add_child(inventory)
	map_sys = MapSystem.new()
	add_child(map_sys)
	combat = CombatSystem.new()
	add_child(combat)

	# ★ 灰盒桥（逻辑组 D-012 协作项落地前的脚手架）：
	# time_system 的跨日幂等锁没有公开的"新局已开日"入口——新局 05:00 起步时
	# _rolled_today=false 会让首个 tick 把 day 滚到 2。跨日拨钟（跳夜后
	# GameLoop 推进到次日 mark）本就是逻辑组 TASK-G 配合项，这里先在
	# 世界侧置位，逻辑组给出正式 init API 后替换本行。
	TimeSystem._rolled_today = true


## 新局地图初始态：safehouse 为家、超市可达（灰盒 1 地点，TASK-G §2）。
## 借道 from_save（writer=map_system 的合法写入路径），逻辑组 enter_node()
## 落地后这里换正式 API（协作项，已在日报登记）。
func _init_map_progress() -> void:
	MapSystem.from_save({
		"current_node": "safehouse",
		"unlocked_nodes": ["safehouse", "supermarket"],
		"locations": {},
		"pending_refills": [],
	})


func _mount_ui() -> void:
	hud = HudRoot.new()
	add_child(hud)
	inv_panel = InventoryPanel.new()
	inv_panel.inventory = inventory
	add_child(inv_panel)


## ── GameLoop → 系统分发 ─────────────────────────────────────
func _on_ticked(frames: int) -> void:
	if time_sys:
		time_sys.tick_frames(frames)
	if combat:
		combat.tick()


func _on_gh_crossed(gh_mark: int) -> void:
	var delta := 0
	if _last_gh_int >= 0:
		delta = gh_mark - _last_gh_int
	_last_gh_int = gh_mark
	if delta <= 0:
		return
	# M3 接线：LoopSystem.tick(delta_gh) / TechTreeSystem.research_tick(delta_gh)
	# / EventSystem.check_scheduled(gh_now) 在回屋经营里程碑接入。


func _on_player_died(cause: String) -> void:
	# M4 接线：死亡 → 当日清晨重开（同种子同日内容一致，M9 实机复跑）。
	# M1 先记日志：灰盒第一天饿死也是有效观测（硬约束 3：自动配给不许抢先存在）。
	Logger.log("game_world", "player_died", "", 0, cause)


func toggle_inventory() -> void:
	if inv_panel:
		inv_panel.toggle()


## prep_start_gh（当日起点钟点）→ 帧数。数值唯一来源 = time.json（零魔法数）。
func _prep_mark_frames() -> int:
	var mark := 5.0
	var f := FileAccess.open(_TIME_PATH, FileAccess.READ)
	if f:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			mark = float((parsed as Dictionary).get("prep_start_gh", mark))
	return int(round(mark * float(GameLoop.FRAMES_PER_GH)))
