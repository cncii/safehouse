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
var loop_sys: LoopSystem
var tech_sys: TechTreeSystem
var event_sys: EventSystem
var hud: HudRoot
var inv_panel: InventoryPanel
var research_panel: ResearchPanel
var death_screen: DeathScreen
var victory_screen: VictoryScreen
var spawner: SpawnService

var _last_gh_int := -1
var _last_saved_day := -1      # 跨日自动存档的去重锚（State 的 time.day）


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
	# 开局先把钟归零：GameLoop.reset() 是 core 给"新局/读档"的公开入口，
	# 而网关只允许向前拨（回拨会把 day/阶段算乱），所以"从 0 起表"必须走 reset。
	GameLoop.reset(0)
	# 之后时钟只经网关拨——这是唯一合法写入点；未注入时 begin_new_run 明确失败
	_install_clock_gate()
	_instantiate_systems()
	# 新局从 D1 05:00 阶段A PREP 起步。以前这里写 GameLoop.reset() +
	# TimeSystem._rolled_today = true，后者是**跨包写私有静态变量**；
	# 逻辑组已给正式入口 begin_new_run()，这里换掉（含拨钟 + 幂等锁置位）。
	var begun := TimeSystem.begin_new_run()
	if not bool(begun.get("ok", false)):
		push_error("GameWorld: begin_new_run failed (%s)" % str(begun.get("reason", "")))
	_sync_gh_mark()        # 对表不结算：05:00 是新一天的起点，不是"已经过了 5 小时"
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
	_install_clock_gate()
	_instantiate_systems()
	var t: Dictionary = run.get("time", {})
	GameLoop.reset(0)            # 同上：先归零，再由网关拨到存档时刻
	TimeSystem.time_restore(t)
	# 读档同样只能经网关拨钟（不碰 TimeSystem 的私有 _advance_clock_to）。
	# 恢复的是"当天已过 GH"，所以从当日 05:00 起点加上已过小时。
	_advance_clock_to_gh(_saved_absolute_gh(t))
	State.restore(run.get("player", {}))
	# 各系统容器段经 Save.apply_persisted 分发（save_system 统一入口）
	Save.apply_persisted(run)
	# 同 restart_from_day_start：必须在 apply_persisted 之后（它会再跑一次 time_restore）
	_time_restore_guard(t)
	_sync_gh_mark()
	_init_map_progress()
	_mount_ui()
	return true


func _instantiate_systems() -> void:
	# 先清死引用再注册：上一局（回主菜单再开一局）的系统实例 Callable 还挂在
	# Save 注册表里，`register_persistence` 遇重复 key 会 assert，新系统就注册不上
	# → 读档少段、自动存档写不出来（实测 duplicate persistence key: inventory/tech）。
	Save.purge_dead_persistences()
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
	loop_sys = LoopSystem.new()
	add_child(loop_sys)
	tech_sys = TechTreeSystem.new()
	add_child(tech_sys)
	event_sys = EventSystem.new()
	add_child(event_sys)
	spawner = SpawnService.new()
	add_child(spawner)
	# 零件扣减走注入式回调（包 B 禁横向持有 InventorySystem 引用，同款先例
	# tech_tree_system.parts_gate / combat 的 EffectSink）。世界侧是唯一装配点。
	tech_sys.parts_gate = Callable(self, "_consume_parts")

	# 跨日幂等锁由 TimeSystem.begin_new_run() 自己置位（旧代码在这里直接写
	# TimeSystem._rolled_today = true，属跨包写私有静态变量，已移除）。


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
	research_panel = ResearchPanel.new()
	research_panel.world = self
	add_child(research_panel)
	death_screen = DeathScreen.new()
	death_screen.world = self
	add_child(death_screen)
	victory_screen = VictoryScreen.new()
	add_child(victory_screen)


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
	# ── M3 接线：每跨 1 个整 GH 的三件结算（顺序按 ResolveOrder 的语义分组）──
	# 产线 → 研发 → 事件。三者都以 delta_gh 为单位，不读真实时间（C27）。
	if loop_sys:
		loop_sys.tick(float(delta))
	if tech_sys:
		tech_sys.research_tick(float(delta))
	if event_sys:
		# 事件系统会自己落盘（day_start_05_00 / event_fired）。上一局遗留的死
		# 持久化回调会让它的 save 直接崩，所以每 GH 分发前先清一次（7 个键，成本可忽略）。
		Save.purge_dead_persistences()
		event_sys.check_scheduled(TimeSystem.gh_now())
	_check_day_autosave()
	_check_stage_transition()
	_check_night_wave()


## 跨日自动存档（DoD G2/G3「走到第一次 05:00 存档」）。
## 判据来源 = State 的 time.day（time_system 唯一写者），不开第二个"今天过了没"的口径。
func _check_day_autosave() -> void:
	var day := int(State.read("time.day"))
	if day == _last_saved_day:
		return
	_last_saved_day = day
	if event_sys:
		event_sys.roll_daily(day)      # 每日随机事件槽（P17：日志有键即回放，不重掷）
	# 夜战中不写档（R22 由 Save.save 自己拦，这里只避免白跑）
	if bool(State.read("combat.wave_active")):
		return
	# 写档前清一次死引用：上一局的系统（实例 Callable）被 free 后仍挂在注册表里，
	# `_build_payload` 会 `null::to_save` 崩 → 存档静默写不出来（实测 why=fail）。
	Save.purge_dead_persistences()
	var ok := Save.save("day_start_05_00")
	Logger.log("game_world", "autosave_day_start", "", day, "ok" if ok else "fail")


## ── 死亡（M4）──────────────────────────────────────────────────
## 死因字符串由 VitalsSystem 按 ResolveOrder.DAMAGE_SOURCE_ORDER 归因，
## 世界侧只负责「停表 + 出画面」，不敢自己编死因。
func _on_player_died(cause: String) -> void:
	Logger.log("game_world", "player_died", "", 0, cause)
	if death_screen:
		death_screen.show_death(cause)


## ── 死亡重开：回到**当日清晨的存档**（架构 §5.4）─────────────────
## 为什么不是"把钟拨回去"：单纯拨钟不还原状态（口粮还是 0、背包还是空的），
## 重开即再死。走当日清晨的自动存档快照才是设计口径，也顺带满足
## M9「同种子同日内容一致」——同一天的地图/掉落由 (种子, day) 纯函数决定。
func restart_from_day_start() -> bool:
	var run := Save.load_run()
	if run.is_empty():
		# 当天还没落过盘（开局当刻就死）：退化到系统级同日重开 + 把状态补满，
		# 不静默什么都不做——否则玩家会卡在尸体上。
		var r0 := TimeSystem.restart_same_day()
		# 复位四条状态只能走有写入权限的系统（player.hp/stamina 的 writers 白名单里
		# 没有 game_world）。CombatSystem 提供了公开的调试复位口，正好够用。
		if combat:
			combat.debug_reset_vitals()
		_sync_gh_mark()
		Logger.log("game_world", "restart_no_save", "", 0,
			"ok" if bool(r0.get("ok", false)) else str(r0.get("reason", "")))
		_goto_home()
		return bool(r0.get("ok", false))

	var t: Dictionary = run.get("time", {})
	TimeSystem.time_restore(t)
	GameLoop.reset(0)
	_advance_clock_to_gh(_saved_absolute_gh(t))
	State.restore(run.get("player", {}))
	Save.apply_persisted(run)
	# ⚠ 必须放在 apply_persisted **之后**：那个调用会把 "time" 段分发给
	#   TimeSystem.from_save_time() → time_restore()，又把 _rolled_today 清成 false。
	#   放在前面等于白设（实测：m4 三条判据时红时绿，就是这几次发的差异）。
	_time_restore_guard(t)
	if combat:
		combat.debug_reset_combat()
	_sync_gh_mark()
	Logger.log("game_world", "restart_from_day_start", "", int(t.get("day", 0)),
		"day-start autosave restored")
	_goto_home()
	return true


## ── M5：阶段 A → B 的切换点（D7 20:00 门锁，架构 §11.1）──────────
## 切换点唯一：只在"阶段A 且到了 D7 且已过宵禁"这一刻触发，
## 不做"每天 20:00 都试一次"的轮询式判断——那会掩盖 day 判定的 bug。
func _check_stage_transition() -> void:
	if TimeSystem.stage != TimeSystem.Stage.A_LOOT:
		return
	# 天数/宵禁都从 time.json 读（数值唯一来源），不用 TimeSystem 的私有静态
	if TimeSystem.day < int(_time_cfg("days_stage_a_count", 7)):
		return
	if fmod(TimeSystem.gh_now(), 24.0) < float(_time_cfg("curfew_gh", 20.0)):
		return
	if TimeSystem.is_transition_night():
		return
	var began := TimeSystem.begin_transition_night()
	if not bool(began.get("ok", false)):
		Logger.log("game_world", "transition_rejected", "", 0, str(began.get("reason", "")))
		return
	# 过渡夜是"整段跳"：按 settle_gh 一次性结算，再落阶段B
	var gh_from := _loop_gh_int()
	var fin := TimeSystem.finish_transition_night()
	if bool(fin.get("ok", false)):
		_settle_gh_range(gh_from)
		Logger.log("game_world", "stage_b_entered", "", int(fin.get("day", 0)),
			"night %d" % int(fin.get("night_index", 0)))


func _goto_home() -> void:
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(&"safehouse")


## ── 拨钟（唯一时钟写入点）────────────────────────────────────────
## 逻辑组把「跳夜/过渡夜/开局拨钟」做成了注入式回调 `TimeSystem.clock_advance_gate`
## （包 B 不直接写 core 状态，C27 + 协作纪律），但 core 的 `GameLoop.advance_to()`
## 还没落地（缺数 C-03 有登记）。在世界侧补一个同签名的实现顶住，等 core 给了
## 正式 API，把这里换成 `Callable(loop, "advance_to")` 即可，**调用方一行不用改**。
##
## 为什么必须补发 gh_crossed：Vitals 的饥饿/口渴结算点挂在 `GameLoop.gh_crossed` 上。
## 直接跳 `elapsed_ticks` 而不发信号 → "路上那 1 GH 不消耗饥饿"，
## 与「1 GH = 72 s」的设计口径冲突（旅行不是时间走私通道）。
func _install_clock_gate() -> void:
	# 静态变量跨对局存活：上一局的 GameWorld 被 free 后，gate 里还攥着死对象。
	# 只判 is_valid() 不够（Callable 本身仍然 valid），要判绑定对象还在不在。
	var cur := TimeSystem.clock_advance_gate
	if cur.is_valid():
		var obj: Object = cur.get_object()
		if obj != null and is_instance_valid(obj):
			return
	TimeSystem.clock_advance_gate = Callable(self, "advance_clock_to")


## 对局被销毁时收回自己注册的网关，别把死对象留给下一局
func _exit_tree() -> void:
	var cur := TimeSystem.clock_advance_gate
	if cur.is_valid() and cur.get_object() == self:
		TimeSystem.clock_advance_gate = Callable()
	# 本局各系统注册的存档段（inventory/map/loop/tech/events…）是**实例** Callable，
	# 本局销毁后它们在 Save 里变成死引用 → 下一次 save 会 `null::to_save` 崩，
	# 表现为"存档写不出来"（实测：跨日自动存档 why=fail）。
	Save.purge_dead_persistences()


## 把钟拨到 target_gh（单位 GH）。只允许向前拨——回拨会把 day/阶段算乱。
##
## ★ 网关**只拨钟、不发 gh_crossed**。为什么：开局把钟对到 05:00 不是"过了 5 小时"，
##   发信号会让 Vitals 立刻扣掉 5 GH 的饥饿（实测把"新局四条状态 100"打成 95 以下）。
##   结算由调用方显式走 `_settle_gh()`：旅行 1 GH、睡一整夜 24 GH 才该结算。
func advance_clock_to(target_gh: float) -> bool:
	var loop := get_node_or_null("/root/GameLoop") as GameLoop
	if loop == null:
		return false
	var new_ticks := int(round(target_gh * float(GameLoop.FRAMES_PER_GH)))
	if new_ticks < loop.elapsed_ticks:
		return false
	loop.elapsed_ticks = new_ticks
	# ⚠ 这里**不**改 _last_gh_int：改了就等于"把这段路当没走过"，
	# 紧接着补发的 gh_crossed 会因为 delta<=0 被丢弃 → 旅行/整夜结算静默为零。
	# 基准点由调用方决定：结算型（旅行/睡觉）走 _settle_gh_range，对表型走 _sync_gh_mark。
	return true


## 显式结算「真的过去了 delta_gh 小时」：补发跨过的整 GH，驱动 Vitals/Loop/Tech/Event。
## 与网关分离是刻意的——拨钟（对齐时刻）和流逝（结算）是两件事，混在一起
## 就会让"开局对表"吃掉 5 小时口粮。
## 补发 (from_gh, now] 之间的整 GH。from_gh 必须由调用方在拨钟**前**取，
## 拨钟后再取就已经是新值了（踩过：range 空 → 结算静默为零）。
## 只对表不结算（开局/读档）：把基准点对齐到当前整数 GH，防止下一拍算出巨大的 delta。
func _sync_gh_mark() -> void:
	_last_gh_int = _loop_gh_int()
	_last_saved_day = int(State.read("time.day"))


func _settle_gh_range(from_gh: int) -> void:
	var loop := get_node_or_null("/root/GameLoop") as GameLoop
	if loop == null:
		return
	var to_gh := loop.gh_int()
	if from_gh < 0:
		from_gh = to_gh
	for g in range(from_gh + 1, to_gh + 1):
		loop.gh_crossed.emit(g)
	_last_gh_int = to_gh


## ── 出门：从总览图前往一个地点 ────────────────────────────────────
## 扣 GH（走 clock gate）→ SceneRouter 切场景。
## 目标节点必须有对应场景（SceneRouter 注册表里查）。
func travel_to(node_id: StringName) -> void:
	var ms := map_sys
	if ms == null:
		push_error("GameWorld: travel_to but map_sys null")
		return
	var cost := ms.travel_cost(
		StringName(str(State.read("map.current_node"))), node_id)
	if cost < 0.0:
		Logger.log("game_world", "travel_no_route", str(node_id), 0, "no edge")
		return
	# 扣 GH：走统一时钟网关（未注入时明确失败，不静默算错）
	var gh_from := _loop_gh_int()
	if not TimeSystem.clock_advance_gate.is_valid() \
			or not bool(TimeSystem.clock_advance_gate.call(TimeSystem.gh_now() + cost)):
		Logger.log("game_world", "travel_no_clock_gate", str(node_id), cost, "C-03")
		return
	_settle_gh_range(gh_from)   # 路上这 1 GH 要真扣饥饿/真出产（不是时间走私）
	Logger.log("game_world", "travel_cost", str(node_id), cost, "GH")
	# 切场景（SceneRouter 里注册的 scene_id 与 node_id 同名）
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(node_id)


func toggle_inventory() -> void:
	if inv_panel:
		inv_panel.toggle()


func toggle_research() -> void:
	if research_panel:
		research_panel.toggle()


## ── 零件扣减网关（TechTreeSystem.parts_gate 的实现）──────────────
## 用「扣前扣后计数」验证，不看 consume() 的返回值——
## consume 返回的是**状态增量**（食物/水才有），零件没有状态效果，
## 靠返回值判成败会把"扣成功"误判成"没扣"（灰盒第一次接线就踩了）。
func _consume_parts(cost: int) -> bool:
	if cost <= 0:
		return true
	if inventory == null:
		return false
	var before := inventory.count_of(&"item_parts")
	if before < cost:
		return false
	inventory.consume(&"item_parts", cost)
	return inventory.count_of(&"item_parts") == before - cost


## 开始研发：零件经 parts_gate 扣、进度由 research_tick 推。
## 返回 {ok, reason}
func start_research(node_key: StringName) -> Dictionary:
	if tech_sys == null:
		return {"ok": false, "reason": "no_system"}
	if inventory != null and inventory.count_of(&"item_parts") 			< _node_parts_cost(node_key):
		return {"ok": false, "reason": "no_parts"}
	var ok := tech_sys.start_research(node_key)
	if not ok:
		return {"ok": false, "reason": "rejected"}
	Logger.log("game_world", "research_started", str(node_key), 0, "TASK-G M3")
	if research_panel:
		research_panel.refresh()
	return {"ok": true, "reason": "ok"}


func _node_parts_cost(node_key: StringName) -> int:
	var f := FileAccess.open("res://data/tech/tech_tree.json", FileAccess.READ)
	if f == null:
		return 0
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return 0
	var nodes: Variant = (parsed as Dictionary).get("nodes", {})
	if typeof(nodes) != TYPE_DICTIONARY:
		return 0
	var node: Variant = (nodes as Dictionary).get(str(node_key), {})
	if typeof(node) != TYPE_DICTIONARY:
		return 0
	return int((node as Dictionary).get("cost_parts", 0))


## ── 跳夜（M3 核心：睡觉 → 次日 05:00 → 自动存档 → 一天闭环）──────
## 判定全部交给 TimeSystem（阶段A / 有床 / 在安全屋内），世界侧不复制规则。
## 返回 TimeSystem.skip_to_next_prep() 的原样结果，另加 ui 字段给 HUD 提示。
func skip_night(has_bed: bool) -> Dictionary:
	if time_sys == null:
		return {"ok": false, "reason": "no_system"}
	if not has_bed:
		return {"ok": false, "reason": "no_bed"}
	if str(State.read("player.scene_id")) != "safehouse":
		return {"ok": false, "reason": "not_home"}
	if TimeSystem.stage != TimeSystem.Stage.A_LOOT:
		return {"ok": false, "reason": "stage_b_no_skip"}
	var gh_from := _loop_gh_int()
	var r := TimeSystem.skip_to_next_prep()
	if bool(r.get("ok", false)):
		# 睡过的整夜要真结算（口粮/产线/研发进度），否则"睡觉免饿"就是白送的
		_settle_gh_range(gh_from)
		Logger.log("game_world", "skip_night", "", float(r.get("settled_gh", 0.0)),
			"day %d" % int(r.get("day", 0)))
		# 拨钟过程中发出的 gh_crossed 已驱动产线/研发；跨日存档在这里补一次兜底
		_check_day_autosave()
	return r


## prep_start_gh（当日起点钟点）→ 帧数。数值唯一来源 = time.json（零魔法数）。
func _prep_mark_frames() -> int:
	return int(round(_prep_mark_gh() * float(GameLoop.FRAMES_PER_GH)))


## time.json 单项读取（数值唯一来源；缺键回退到传入的默认值，不硬写常量在调用点）。
func _time_cfg(key: String, fallback: Variant) -> Variant:
	var f := FileAccess.open(_TIME_PATH, FileAccess.READ)
	if f == null:
		return fallback
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return fallback
	return (parsed as Dictionary).get(key, fallback)


## prep_start_gh（当日起点钟点）→ GH 值。数值唯一来源 = time.json（零魔法数）。
func _prep_mark_gh() -> float:
	var mark := 5.0
	var f := FileAccess.open(_TIME_PATH, FileAccess.READ)
	if f:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			mark = float((parsed as Dictionary).get("prep_start_gh", mark))
	return mark


func _loop_gh_int() -> int:
	var loop := get_node_or_null("/root/GameLoop") as GameLoop
	return loop.gh_int() if loop else 0


## 读档后的跨日幂等锁。
##
## ★ 为什么需要：`TimeSystem.time_restore()` 无条件把 `_rolled_today` 置 false。
##   而当日清晨存档的 gh **正好等于**当日起钟点（05:00 / 06:00），于是恢复后的
##   第一拍 `_check_day_rollover()` 会立刻满足 `gh >= mark` → **day 又 +1**。
##   实测：D1 05:00 的存档读回来变成 D2（重开、读档都会跳一天）。
##
## ⚠ 这是**跨包写私有静态**，属临时处置：正确做法是 time_system 给一个
##   public 的 `mark_day_started()`（已在 data/UNDEFINED.md 登记 D-D04）。
##   逻辑组提供后删掉本函数即可，调用点不用改。
func _time_restore_guard(_t: Dictionary) -> void:
	TimeSystem._rolled_today = true


## 存档里的时间字段是**累计 GH**（time_system.to_save_time 写的是 gh_now()，
## 字段名叫 gh_elapsed_today 但值不是"当天已过"）——直接当偏移再加起钟点会
## 多加 5 GH（实测 D1 05:00 读回变成 10:00）。这里按绝对 GH 处理，缺字段才退回起钟点。
func _saved_absolute_gh(t: Dictionary) -> float:
	if not t.has("gh_elapsed_today"):
		return _prep_mark_gh()
	return float(t.get("gh_elapsed_today", _prep_mark_gh()))


## 经公开的时钟网关拨钟（不碰 TimeSystem 的私有 _advance_clock_to，
## 也不碰 core 的 GameLoop.elapsed_ticks——那是 C27 的时间唯一真相，但只有网关可写）。
func _advance_clock_to_gh(target_gh: float) -> bool:
	if not TimeSystem.clock_advance_gate.is_valid():
		return false
	return bool(TimeSystem.clock_advance_gate.call(target_gh))


## ── M5：阶段 B 夜间波次 ────────────────────────────────────────
## 触发点 = 阶段B 的 18:00。波次必须 WAVE_DRIVEN（击杀推进 + 8 分钟兜底都在
## TimeSystem 里），世界侧只负责"开波 + 把敌人摆进场景"。
func _check_night_wave() -> void:
	if TimeSystem.stage != TimeSystem.Stage.B_SIEGE:
		return
	if combat == null or combat.wave_active:
		return
	var night := TimeSystem.night_index
	if night < 1:
		return
	# 最后一夜打完就通关，不再开下一夜（夜数从 time.json 读）
	if night > int(_time_cfg("nights_stage_b_count", 7)):
		_check_victory()
		return
	if fmod(TimeSystem.gh_now(), 24.0) < float(_time_cfg("outing_end_gh", 18.0)):
		return
	var plan := combat.begin_wave(night)
	var spawned: Array = []
	if spawner:
		spawned = spawner.spawn_from_plan(plan, int(State.read("time.day")))
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("spawn_wave"):
		scene.spawn_wave(spawned)
	Logger.log("game_world", "wave_started", "", night, "spawned %d" % spawned.size())


## 敌人死亡：先记账（CombatSystem 的批次/池），再看这一夜是否清场。
func on_enemy_killed(z: EnemyAvatar) -> void:
	if combat == null:
		return
	combat.on_enemy_killed()
	var scene := get_tree().current_scene
	var alive := 0
	if scene != null and scene.has_method("alive_enemies"):
		alive = (scene.alive_enemies() as Array).size()
	if spawner:
		var refilled: Array = spawner.release(alive)
		if not refilled.is_empty() and scene != null and scene.has_method("spawn_wave"):
			scene.spawn_wave(refilled)
	if z != null and is_instance_valid(z):
		z.queue_free()
	if combat.is_wave_cleared():
		var result := combat.settle_night()
		Logger.log("game_world", "night_settled", String(result), TimeSystem.night_index, "")
		if String(result) == "night_clear" \
				and TimeSystem.night_index >= int(_time_cfg("nights_stage_b_count", 7)):
			_check_victory()


## 通关：最后一夜清场。任务书 §2 明确"夜 7 天亮即算通关，结局画面一行字"。
func _check_victory() -> void:
	if victory_screen and not victory_screen.visible:
		victory_screen.show_victory()
		Logger.log("game_world", "victory", "", TimeSystem.night_index, "TASK-G M5")
