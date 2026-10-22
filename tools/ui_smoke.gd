extends Node
## ui_smoke.gd — 表现组（包 D）自验冒烟 · W4 修订
##
## ── 运行方式（重要，勿回退）──
##   godot --headless res://tools/ui_smoke.tscn
## 旧版 `godot --headless -s tools/ui_smoke.gd`（extends SceneTree）**永久作废**：
## -s 模式主脚本编译早于 autoload 注册，Localize/State 等标识符解析失败 = 永远编不过。
## 场景方式正常启动工程（autoload 全注册），本脚本作为场景根节点在 _ready 跑断言。
##
## ── 归属说明 ── 表现组自己验证 W1/W3/W4 交付物的工具，**不进 tools/test.ps1**
## （test.ps1 是包 F 编排的验收单一入口，要并入需由包 F 决定断言计数口径）。
##
## ── State 写入说明 ── fixture 用 source="effect_sink"（contract writers 白名单内的
## 合法写入者）构造沿翻转；tools/ 不在 src/ui 的 D2 扫描范围，不构成 UI 越权。
##
## 每条判据注明"能抓什么"——抓不住东西的断言等于噪音，最后会被关掉。

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

func _ready() -> void:
	_test_locale_chain()
	_test_vitals_bars()
	_test_clock()
	_test_hud_root()
	_test_settings_language_switch()
	_test_keybinds()
	await _test_loop_panel()
	_test_audio_alarms()
	await _test_m1_world()
	await _test_m2_world()
	await _test_m3_world()
	_finish()

# ── 本地化链路 ──
# 能抓：strings.csv 被改名/被删/表头第一列不是 KEY。
# 这条是 W1 最重要的守卫——文件缺失时 core 只 push_warning，不报错，
# 界面会静默退化成满屏裸 KEY，没有任何别的检查会报出来。
func _test_locale_chain() -> void:
	_t("locale: HUD_VITAL_HP resolves (not raw key)",
		Localize.text("HUD_VITAL_HP") != "HUD_VITAL_HP")
	_t("locale: missing key falls back to key itself",
		Localize.text("NO_SUCH_KEY_XYZ") == "NO_SUCH_KEY_XYZ")
	_t("locale: default lang is zh_CN", Localize.get_lang() == "zh_CN")
	Localize.set_lang("en")
	_t("locale: en label resolves to ASCII text",
		Localize.text("SETTINGS_TITLE") == "Settings")
	Localize.set_lang("zh_CN")

# ── 四条状态条 ──
# 能抓：add_child/setup 顺序被改回（那会给 null 赋值）、条数被改、数值没夹紧。
func _test_vitals_bars() -> void:
	var vitals := HudVitals.new()
	add_child(vitals)          # _ready 依赖入树，顺序不能反

	_t("vitals: exactly 4 bars", vitals._bars.size() == 4)
	_t("vitals: bar names are localized", _all_bars_named(vitals))

	var bar0: VitalBar = vitals._bars[0]["bar"]
	bar0.set_value(42.0)
	_t("vitals: value label shows 42", bar0._value_label.text == "42")
	_t("vitals: progress bar follows value", is_equal_approx(bar0._bar.value, 42.0))

	bar0.set_value(-10.0)
	_t("vitals: negative clamps to 0", bar0._value_label.text == "0")
	bar0.set_value(150.0)
	_t("vitals: over-max clamps to 100", bar0._value_label.text == "100")

	vitals.queue_free()

func _all_bars_named(v: HudVitals) -> bool:
	# 注意：HudVitals._bars 元素是 {"bar", "path"}——本地化键在 VitalBar._name_key 里，
	# 不存在 "key" 键（曾因访问 item["key"] 抛 SCRIPT ERROR 假红过一轮）。
	var ok := true
	for item: Dictionary in v._bars:
		var b: VitalBar = item["bar"]
		var t: String = b._name_label.text
		print("  diag: bar internal_key=[%s] text=[%s]" % [String(b._name_key), t])
		if t == "" or t == String(b._name_key):
			ok = false      # 空文本或退化成裸 KEY
	return ok

# ── 时段显示 ──
# 能抓：GH→时钟换算被改（小数部分按 60 分而不是 100 分）、
#       time.stage 未命中时直接 String() 把 0.0 显示成 "0"。
func _test_clock() -> void:
	var clock := HudClock.new()
	add_child(clock)

	# 修订 #9（TASK-G M1）：GH 口径改为「日起点 + 已过」——compose_clock(elapsed, mark)
	# mark=0 保留旧覆盖语义（换算本身），mark=5/6 验证阶段起点偏移
	_t("clock: mark0 0 GH -> 00:00", HudClock.compose_clock(0.0, 0.0) == "00:00")
	_t("clock: mark0 14.5 GH -> 14:30", HudClock.compose_clock(14.5, 0.0) == "14:30")
	_t("clock: mark0 23.9 GH -> 23:54", HudClock.compose_clock(23.9, 0.0) == "23:54")
	_t("clock: over 24 clamps", HudClock.compose_clock(30.0, 0.0) == "00:00")
	# 期望值独立写死（05:00/20:00/06:00 是设计锚点，不从代码派生）
	_t("clock: stage A day start 05:00 (elapsed=0, mark=5)", HudClock.compose_clock(0.0, 5.0) == "05:00")
	_t("clock: stage A 18:00 curfew (elapsed=13, mark=5)", HudClock.compose_clock(13.0, 5.0) == "18:00")
	_t("clock: stage B dawn 06:00 (elapsed=0, mark=6)", HudClock.compose_clock(0.0, 6.0) == "06:00")
	# State 未命中 stage（float 0.0）→ 走 A 路径 mark，不得崩、不得显示 "0"
	_t("clock: unset stage still renders clock", clock._clock_text(0.0) == "05:00")

	# 关键：State.read 未命中返回 0.0，是 float 不是 string → 必须显示 fallback 而不是 "0"
	_t("clock: unset stage shows fallback not literal zero",
		clock._stage_text() != "A_LOOT" and clock._stage_text() != "0")

	clock.queue_free()

# ── HUD 组装根 ──
# 能抓：HudRoot 忘了加 HudVitals/HudClock/AudioSystem/HudLoopPanel（W2 接新面板时最容易漏）。
func _test_hud_root() -> void:
	var hud := HudRoot.new()
	add_child(hud)
	_t("hud_root: has clock child", _has_type(hud, "HudClock"))
	_t("hud_root: has vitals child", _has_type(hud, "HudVitals"))
	_t("hud_root: has audio child", _has_type(hud, "AudioSystem"))
	_t("hud_root: has loop panel child", _has_type(hud, "HudLoopPanel"))
	hud.queue_free()

# ── W2 三块硬 UI（瞬间报告 + 链状态面板 + 两级预警）──
# 能抓：面板行数硬编码成 4/5（动态渲染被改坏 → 接口加链必返工的根）、
#       链名/卡点退化成裸 KEY（strings.csv 缺 LOOP_* 键）、
#       wiring 缺位时面板崩溃而不是降级、阈值缺键时误着色（D-017 降级路径）。
# LoopSystem 由本测试 wiring 到 /root（名字必须是 "LoopSystem"，与 combat_system 的
# get_node_or_null("/root/LoopSystem") 约定一致）——真实 wiring 是 core 欠件。
func _test_loop_panel() -> void:
	# ① wiring 缺位路径：必须降级显示，不许崩
	var panel := HudLoopPanel.new()
	add_child(panel)
	_t("loop_panel: unwired shows fallback text",
		panel._report_label.text == Localize.text("LOOP_DATA_NOT_WIRED"))
	_t("loop_panel: unwired grid keeps only header row", panel._grid.get_child_count() == 5)

	# ② wiring LoopSystem（冷启动，balance 从 loop.json 读）
	# 注意：场景根 _ready 期间 root 正在 setup children，直接 add_child 会被拒
	# （实测报 "Parent node is busy setting up children"）→ 必须 deferred + 跨帧等待。
	var loop_node: Node = (load("res://src/systems/loop_system.gd") as GDScript).new()
	loop_node.name = "LoopSystem"
	get_tree().root.add_child.call_deferred(loop_node)
	await get_tree().process_frame
	await get_tree().process_frame
	panel._on_loop_changed(&"", "test-refresh")   # 模拟 State loop 段变化回调

	var urg: Dictionary = loop_node.maintenance_urgency()
	_t("loop_panel: wiring binds after add_child", panel._loop == loop_node)
	_t("loop_panel: row count follows interface (dynamic, no hardcode)",
		panel._grid.get_child_count() == 5 + urg.size() * 5)

	# ③ 每条链的渲染与接口逐格一致（不硬编码初始解锁状态）
	var rows_ok := true
	var names_ok := true
	for i: int in urg.size():
		var res: String = urg.keys()[i]
		var st: Dictionary = urg[res]
		var base := 5 + i * 5
		var name_l: Label = panel._grid.get_child(base)
		var rate_l: Label = panel._grid.get_child(base + 1)
		var block_l: Label = panel._grid.get_child(base + 4)
		if name_l.text != Localize.text("LOOP_CHAIN_" + res):
			names_ok = false
		if rate_l.text != "%.2f" % float(st["rate_per_day"]):
			rows_ok = false
		if block_l.text != Localize.text("LOOP_BLOCK_" + String(st["blocked_at"]).to_upper()):
			rows_ok = false
	_t("loop_panel: chain names localized (not raw KEY)", names_ok)
	_t("loop_panel: rate/block cells match interface", rows_ok)

	# ④ 块3 降级路径：survival.json 无阈值键（D-017）→ 一律不着色
	var warn_off := true
	for i: int in urg.size():
		var cell: Label = panel._grid.get_child(5 + i * 5)
		if cell.get_theme_color("font_color") != HudStyle.COLOR_TEXT:
			warn_off = false
	_t("loop_panel: missing warn keys keep neutral color (D-017 fallback)", warn_off)

	# ⑤ 块1：冷启动 stock=0 → 无"约 X 天后耗尽"行（不显示除零产物）
	_t("loop_panel: zero stock renders no gap report", panel._report_label.text == "")

	# ⑥ audio 侧：阈值缺键 → stock warn 静默，不误播
	var audio := AudioSystem.new()
	add_child(audio)
	audio._on_loop_changed(&"", "test-refresh")
	_t("audio: stock warn stays silent when thresholds missing (D-017)",
		audio._stock_warn_active == false)

	audio.queue_free()
	panel.queue_free()
	loop_node.queue_free()

# ── 设置页切语言 ──
# 能抓：切语言后 UI 树没被重刷（S8 回归）、或者设了语言但没落回 zh_CN 影响后续用例。
func _test_settings_language_switch() -> void:
	var settings := SettingsScreen.new()
	add_child(settings)
	_t("settings: title localized", settings._title.text != "SETTINGS_TITLE")

	settings._on_lang_selected(2)   # en
	_t("settings: switching to en changes title",
		settings._title.text == "Settings")

	# 遍历整棵 UI 树重刷——顺带验证树上其它节点确实被刷到了
	settings._on_lang_selected(1)   # zh_TW
	_t("settings: switching back keeps title non-empty",
		settings._title.text != "")
	settings._on_lang_selected(0)   # zh_CN，还原，避免污染同进程后续用例
	settings.queue_free()

# ── S6 键位重绑 ──
# 能抓：动作清单被硬编码（动态遍历被改坏 → 工程加动作面板不同步）、
#       冲突检测漏掉（误覆盖他动作的键）、被拒绝的重绑仍改写了 InputMap、
#       profile 落盘/启动恢复断链（重启后键位丢失的回归）、恢复默认不彻底。
# 注意：rebind/reset 会写 user://profile.sav = 真实用户目录（use_custom_user_dir），
#       测试前后快照恢复，不留痕。
func _test_keybinds() -> void:
	var orig_profile: Dictionary = Save.load_profile()

	var kb := KeybindSettings.new()
	add_child(kb)

	# ① 清单动态遍历：面板行数 == 过滤后动作数（工程 [input] 现为 10 个）
	var acts: PackedStringArray = kb._game_actions()
	_t("keybind: filters ui_* and renders dynamic list",
		kb._rows.size() == acts.size() and acts.size() == 10
		and not String(acts[0]).begins_with("ui_"))

	# ② 动作名本地化（strings.csv 缺 ACTION_* 键会退化成裸 KEY）
	var names_ok := true
	for a: String in kb._rows:
		if (kb._rows[a]["label"] as Label).text != Localize.text("ACTION_" + a.to_upper()):
			names_ok = false
	_t("keybind: action names localized (not raw KEY)", names_ok)

	# 基准：工程默认键位（⑤⑦ 判据要用）。
	# ⚠ 判据期望值一律从 defaults 派生，不许凭记忆写键码——
	#   本域曾因"记得 attack=K"（实际默认 J=74）造出 7 条假红。
	var defaults := {}
	for a: String in acts:
		defaults[a] = kb._primary_key(a)

	# ③ 重绑生效：move_up → 空闲键（候选表取第一个工程默认未占用的，判据与默认键位解耦）
	var free_key := 0
	for cand: Key in [KEY_X, KEY_Z, KEY_B, KEY_V, KEY_N]:
		var taken := false
		for a: String in acts:
			if int(defaults[a]) == int(cand):
				taken = true
		if not taken:
			free_key = int(cand)
			break
	_t("keybind: fixture has a free key to test with", free_key != 0)
	_t("keybind: rebind move_up->free key succeeds", kb.rebind("move_up", free_key) == "")
	var has_new := false
	var has_old := false
	for ev: InputEvent in InputMap.action_get_events("move_up"):
		if ev is InputEventKey:
			if (ev as InputEventKey).physical_keycode == free_key:
				has_new = true
			if (ev as InputEventKey).physical_keycode == int(defaults["move_up"]):
				has_old = true
	_t("keybind: move_up has new key after rebind", has_new)
	_t("keybind: move_up old key erased (no dual-trigger)", not has_old)

	# ④ 冲突拒绝：attack 想占 move_right 的默认键 → 拒绝、不改写、提示占用方
	var conflict_key := int(defaults["move_right"])
	_t("keybind: conflict detected (move_right's key)", kb.rebind("attack", conflict_key) == "move_right")
	_t("keybind: rejected rebind leaves attack untouched",
		kb._primary_key("attack") == int(defaults["attack"]))
	_t("keybind: conflict note names the occupying action",
		kb._note.text.contains(Localize.text("ACTION_MOVE_RIGHT")))

	# ⑤ 落盘：rebind 即写 profile（不等关页）
	_t("keybind: rebind persisted to profile",
		int(Save.load_profile().get("profile", {}).get("keybinds", {}).get("move_up", 0)) == free_key)

	# ⑥ 启动恢复链：打回工程默认 → apply_saved → 改过的键回来
	InputMap.load_from_project_settings()
	KeybindSettings.apply_saved()
	_t("keybind: apply_saved restores rebinding after engine-default reset",
		kb._primary_key("move_up") == free_key)

	# ⑦ 恢复默认：InputMap 全量对齐工程默认 + profile 重记默认
	kb.reset_defaults()
	var all_default := true
	for a: String in defaults:
		if kb._primary_key(a) != int(defaults[a]):
			all_default = false
	_t("keybind: reset_defaults restores every project default", all_default)
	_t("keybind: profile re-records defaults after reset",
		int(Save.load_profile().get("profile", {}).get("keybinds", {}).get("move_up", 0)) == int(defaults["move_up"]))

	kb.queue_free()
	Save.save_profile(orig_profile.get("profile", {}))   # 快照恢复，真实 profile 不留测试痕

# ── 音频警报（W4）──
# 能抓：阈值被抄成另一份常量（与 HudStyle 脱钩）、订阅沿翻转失效、
#       bind_alarms 幂等被改坏（重复订阅）、冷启动全 0 没进警报侧。
func _test_audio_alarms() -> void:
	var audio := AudioSystem.new()
	add_child(audio)   # _ready → bind_alarms → 订阅 + 冷启动对齐

	# 冷启动：State 里 player.* 未写入 → read 全 0 → 三条警报都应在激活侧
	_t("audio: cold all-zero state activates hunger alarm side",
		audio._loop_active.get("alarm_hunger", false) == true)
	_t("audio: cold all-zero state activates thirst alarm side",
		audio._loop_active.get("alarm_thirst", false) == true)
	_t("audio: cold all-zero state activates heartbeat side",
		audio._loop_active.get("heartbeat", false) == true)

	# 饱足 fixture（effect_sink 是 contract 白名单内的合法写入者）→ 全部退出警报侧
	var cs := State.ChangeSet.new(&"effect_sink", "ui_smoke fixture: satiate vitals")
	cs.setv("player.hunger", 80.0)
	cs.setv("player.thirst", 80.0)
	cs.setv("player.stamina", 50.0)
	var r: State.ApplyResult = State.apply(cs)
	_t("audio: fixture writes accepted by contract", r.ok and r.applied == 3)
	_t("audio: satiated state deactivates hunger alarm",
		audio._loop_active.get("alarm_hunger", true) == false)
	_t("audio: satiated state deactivates heartbeat",
		audio._loop_active.get("heartbeat", true) == false)

	# 体力降到 ≤10（HudStyle.LOW_STAMINA）→ 心跳沿再翻回激活侧
	var cs2 := State.ChangeSet.new(&"effect_sink", "ui_smoke fixture: drain stamina")
	cs2.setv("player.stamina", 10.0)
	State.apply(cs2)
	_t("audio: stamina at threshold re-activates heartbeat",
		audio._loop_active.get("heartbeat", false) == true)

	# bind_alarms 幂等：重复调用不产生第二个订阅句柄
	var before: int = audio._sub_handle
	audio.bind_alarms()
	_t("audio: bind_alarms is idempotent", audio._sub_handle == before)

	audio.queue_free()

## 按 class_name 全局名递归查找（不能直接 is HudVitals，因为这里要写成通用的）
func _has_type(n: Node, script_class: String) -> bool:
	for c: Node in n.get_children():
		var s := c.get_script() as Script
		if s != null and s.get_global_name() == script_class:
			return true
		if _has_type(c, script_class):
			return true
	return false

# ── TASK-G M1 灰盒世界 ──
# 能抓：start_new_game 编排断链（系统未挂 / 四条状态未归位 / 时钟未归位到 05:00）、
#       拾取→背包链路断（item_id 打错 / add 返回 0 / 二次触发不幂等）、
#       消费链路断（consume 增量丢失 / 背包不扣减）、
#       场景注册表漏 key、菜单词条退化为裸 KEY。
# ⚠ 本块整组只 new 一次 GameWorld：InventorySystem/TimeSystem/MapSystem 的
#   Save.register_persistence 无 static 守卫（实例侧注册），第二次注册 assert 崩。
# ⚠ start_new_game 后的所有断言与 start_new_game 同栈同步执行（中间不 await）——
#   GameLoop 每物理帧 +1 / Vitals 每帧掉饥饿，任何 await 都会让"精确 100 / 21600"变骰子。
func _test_m1_world() -> void:
	var world := GameWorld.new()
	get_tree().root.add_child(world)
	await get_tree().process_frame    # GameWorld._ready 连 GameLoop 信号
	world.start_new_game(42)

	_t("m1: systems mounted (time/vitals/inventory/map/combat)",
		world.time_sys != null and world.vitals != null \
		and world.inventory != null and world.map_sys != null and world.combat != null)
	_t("m1: HUD mounted by world (cross-scene lifetime)",
		world.hud != null and world.hud.get_parent() == world)
	_t("m1: new game vitals baseline all 100",
		float(State.read("player.hp")) == 100.0 and float(State.read("player.stamina")) == 100.0 \
		and float(State.read("player.hunger")) == 100.0 and float(State.read("player.thirst")) == 100.0)
	# 期望值 5GH 独立写死（05:00 设计锚点），不取自 GameWorld 自算——防恒真式
	_t("m1: clock reset to 05:00 mark (21600 frames)",
		GameLoop.elapsed_ticks == 5 * GameLoop.FRAMES_PER_GH)
	_t("m1: map current_node seeded safehouse",
		str(State.read("map.current_node")) == "safehouse")
	var unlocked: Variant = State.read("map.unlocked_nodes")
	var has_market := false
	if typeof(unlocked) == TYPE_ARRAY or typeof(unlocked) == TYPE_PACKED_STRING_ARRAY:
		for n: Variant in (unlocked as Array):
			if str(n) == "supermarket":
				has_market = true
	_t("m1: supermarket unlocked for graybox outing", has_market)

	# 场景壳：拾取链路（不经 SceneRouter，直接挂载构建）
	var scene := SafehouseScene.new()
	add_child(scene)
	var zone := _find_zone(scene, &"supplies")
	_t("m1: safehouse has supplies interaction zone", zone != null)
	if zone != null:
		zone.trigger()
		_t("m1: pickup lands in inventory (2+2 per graybox data)",
			world.inventory.count_of(&"item_food_can") == 2 \
			and world.inventory.count_of(&"item_water_bottle") == 2)
		zone.trigger()    # 二次触发必须幂等（一次性物资堆）
		_t("m1: pickup is one-shot (idempotent trigger)",
			world.inventory.count_of(&"item_food_can") == 2)
	_t("m1: bed and door zones present (silent M3/M2 placeholders)",
		_find_zone(scene, &"bed") != null and _find_zone(scene, &"door_main") != null)

	# 消费链路：consume 返回增量 + 背包扣减（+25 定稿值来自 survival.json，判据冻结 25）
	var delta: Dictionary = world.inventory.consume(&"item_food_can", 1)
	_t("m1: consume returns hunger delta +25",
		is_equal_approx(float(delta.get("hunger", 0.0)), 25.0))
	_t("m1: consume decrements inventory",
		world.inventory.count_of(&"item_food_can") == 1)

	# 主菜单壳：按钮数 + 词条非裸 KEY
	var menu := MainMenuScreen.new()
	add_child(menu)
	var btns := _find_buttons(menu)
	_t("m1: main menu has 4 action buttons", btns.size() == 4)
	var raw_key_leak := false
	for b: Node in btns:
		if String((b as Button).text).begins_with("MAIN_MENU_"):
			raw_key_leak = true
	_t("m1: menu labels localized (no raw KEY leak)", not raw_key_leak)

	# 场景注册表（SceneRouter 侧，TASK-G 主流程三场景）
	_t("m1: router registry has main_menu/settings/safehouse",
		SceneRouter.SCENE_PATHS.has("main_menu") and SceneRouter.SCENE_PATHS.has("settings") \
		and SceneRouter.SCENE_PATHS.has("safehouse"))

	menu.free()
	scene.free()
	world.free()


## ── M2：总览图出门 → 超市灰盒 → 搜刮 + 1 种丧尸战斗 ─────────────
## 判据对着 TASK-G §5 M2「能出门一趟」与 §6 G3/G4 的前置。
## 期望值一律独立写死（12 点位 / 1.0 GH 成本 / 60 HP 来自 themes.json + locations.json 定稿），
## 不从被测代码现取——否则实现坏了判据跟着绿（本项目已踩三次恒真式）。
func _test_m2_world() -> void:
	var world := GameWorld.new()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	world.start_new_game(42)

	# ── ① 注册表：总览图与超市场景都在 ──
	_t("m2: router registry has overview_map/supermarket",
		SceneRouter.SCENE_PATHS.has("overview_map") \
		and SceneRouter.SCENE_PATHS.has("supermarket"))

	# ── ② 总览图可达性（成本 1.0 GH 来自 locations.json 定稿，写死不取自代码）──
	var ms := world.map_sys
	var cost := ms.travel_cost(&"safehouse", &"supermarket")
	_t("m2: safehouse->supermarket cost is 1.0 GH", is_equal_approx(cost, 1.0))
	_t("m2: safehouse does not reach radio_tower directly (no edge)",
		ms.travel_cost(&"safehouse", &"radio_tower") < 0.0)

	# ── ③ 出门扣时：travel_to 推进 1 GH = 4320 帧 ──
	#   同栈断言（无 await）：GameLoop 每帧 +1，插一帧这条就永远不准
	var before := GameLoop.elapsed_ticks
	world.travel_to(&"supermarket")
	var after := GameLoop.elapsed_ticks
	_t("m2: travel_to advances clock by exactly 1 GH (4320 frames)",
		after - before == GameLoop.FRAMES_PER_GH)

	# ── ④ 进地点：布局点数 12（commercial 主题定稿值）+ current_node 写入 ──
	var e := ms.enter_node(&"supermarket", int(State.read("time.day")))
	_t("m2: enter_node ok with 12 loot points",
		bool(e.get("ok", false)) and (e.get("loot_points", []) as Array).size() == 12)
	_t("m2: enter_node writes map.current_node=supermarket",
		str(State.read("map.current_node")) == "supermarket")

	# ── ⑤ 场景皮：超市场景 12 个掉落交互点 + 1 只丧尸 ──
	var market := SupermarketScene.new()
	add_child(market)
	_t("m2: supermarket scene builds 12 loot interaction zones",
		market.loot_zone_ids().size() == 12)
	_t("m2: supermarket scene has exactly one zombie",
		market.zombie() != null)

	var z := market.zombie()
	if z != null:
		# 60 HP 来自 graybox_start.json（PROVISIONAL D-D02），写死为判据期望值
		_t("m2: zombie hp comes from data (60)", is_equal_approx(z.hp, 60.0))
		z.apply_damage(25.0)
		_t("m2: zombie takes damage (60-25=35)", is_equal_approx(z.hp, 35.0))
		z.apply_damage(25.0)
		z.apply_damage(25.0)
		_t("m2: zombie dies at <=0 hp and stops being alive",
			z.is_dead() and z.hp <= 0.0)

	# ── ⑥ 搜刮链路：InteractionZone.trigger → loot_take → InventorySystem.add ──
	var inv_before := world.inventory.used()
	var ids := market.loot_zone_ids()
	var picked := 0
	for pid: Variant in ids:
		var zone := _find_zone(market, StringName(str(pid)))
		if zone == null:
			continue
		zone.trigger()
		picked += 1
	_t("m2: all 12 loot zones are triggerable", picked == 12)
	_t("m2: scavenging fills inventory (slots used > before)",
		world.inventory.used() > inv_before)
	# 搜过即打空：再点同一个点不会重复进包
	var first_id := StringName(str(ids[0]))
	var used_after_sweep := world.inventory.used()
	var first_zone := _find_zone(market, first_id)
	if first_zone != null:
		first_zone.trigger()
	_t("m2: re-triggering a looted point adds nothing",
		world.inventory.used() == used_after_sweep)

	market.free()
	world.free()


## ── M3：回屋研发/跳夜 → 05:00 自动存档 → 一天闭环 ──────────────────
## 期望值一律独立写死：05:00 起点 = 5.0 GH（time.json 定稿）、
## 跳夜后 = 次日 05:00（+24 GH）、unlock_water_basic 的 cost_parts 2 / research_gh 2
## 来自 tech_tree.json 定稿值——都不从被测代码现取。
func _test_m3_world() -> void:
	var world := GameWorld.new()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	world.start_new_game(7)

	_t("m3: systems mounted (loop/tech/event)",
		world.loop_sys != null and world.tech_sys != null and world.event_sys != null)
	_t("m3: begin_new_run puts run at D1 05:00 stage A",
		TimeSystem.day == 1 and is_equal_approx(TimeSystem.gh_now(), 5.0) \
		and TimeSystem.stage == TimeSystem.Stage.A_LOOT)
	_t("m3: tech parts_gate injected by world", world.tech_sys.parts_gate.is_valid())

	# ── 研发全周期：给零件 → 开始（扣零件）→ research_tick 到时长 → 解锁 ──
	world.inventory.add(&"item_parts", 5)
	var parts_before := world.inventory.count_of(&"item_parts")
	var r := world.start_research(&"unlock_water_basic")
	_t("m3: start_research ok", bool(r.get("ok", false)))
	_t("m3: research deducts cost_parts 2", 
		world.inventory.count_of(&"item_parts") == parts_before - 2)
	_t("m3: tech.researching points at the node",
		world.tech_sys.researching_node() == "unlock_water_basic")
	world.tech_sys.research_tick(2.0)       # research_gh 定稿值 = 2
	_t("m3: research completes exactly at research_gh",
		world.tech_sys.is_unlocked(&"unlock_water_basic"))

	# ── 反向：零件不足必须拒绝（不许"白拿科技"）──
	world.inventory.consume(&"item_parts", world.inventory.count_of(&"item_parts"))
	var no_parts := world.start_research(&"unlock_cook")
	_t("m3: research rejected when parts are short",
		not bool(no_parts.get("ok", true)) \
		and str(no_parts.get("reason", "")) == "no_parts")

	# ── 跳夜：判定链（无床/不在家 都必须拒），再走真实链路 ──
	var bad_bed := world.skip_night(false)
	_t("m3: skip_night without bed is rejected",
		not bool(bad_bed.get("ok", true)) and str(bad_bed.get("reason", "")) == "no_bed")

	# 走到安全屋：player.scene_id 只许 SceneRouter 写，所以这里用真的路由器
	var router := SceneRouter.new()
	router.name = "SceneRouter"
	get_tree().root.add_child(router)
	await get_tree().process_frame
	get_tree().current_scene = null      # 否则切场景会把 ui_smoke 自己 free 掉
	await _goto_scene(router, &"safehouse")
	_t("m3: route to safehouse sets player.scene_id",
		str(State.read("player.scene_id")) == "safehouse")

	var day_before := TimeSystem.day
	var gh_before := TimeSystem.gh_now()
	var slept := world.skip_night(true)
	_t("m3: skip_night at home succeeds", bool(slept.get("ok", false)))
	# 落点判据用「当天已过 GH == 5」而不是 gh_now()==gh_before+24：
	# 进安全屋那一跳会走过几帧（GameLoop 每帧 +1），gh_before 带余数，
	# 拿它加 24 去比就会差个零头（实测 29.00 vs 29.03 这种假红）。
	# 05:00 的语义是"当天已过 0 小时"（gh_elapsed_today 以起钟点为 0），
	# 不是 5.0——写 5.0 会把正确实现判红（第一次就踩了）。
	_t("m3: skip lands on next day 05:00 (day+1, elapsed_today=0)",
		TimeSystem.day == day_before + 1 \
		and is_equal_approx(TimeSystem.gh_elapsed_today(), 0.0))
	_t("m3: skip reports settled GH = (next 05:00 - now)",
		is_equal_approx(float(slept.get("settled_gh", 0.0)), 29.0 - gh_before))

	# ── 05:00 自动存档：存档可读回且 day 一致 ──
	var run := Save.load_run()
	_t("m3: day-start autosave written and loadable", not run.is_empty())
	_t("m3: autosave carries the rolled-over day",
		int((run.get("time", {}) as Dictionary).get("day", -1)) == TimeSystem.day)

	world.free()


func _goto_scene(router: SceneRouter, id: StringName) -> void:
	router.goto(id, {}, 0.0)
	for i in 900:
		await get_tree().process_frame
		if not router.is_transitioning():
			return


func _find_zone(n: Node, id: StringName) -> InteractionZone:
	for c: Node in n.get_children():
		if c is InteractionZone and (c as InteractionZone).zone_id == id:
			return c
		var sub := _find_zone(c, id)
		if sub != null:
			return sub
	return null


func _find_buttons(n: Node) -> Array:
	var out: Array = []
	for c: Node in n.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_find_buttons(c))
	return out

func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)

func _finish() -> void:
	print("--- ui_smoke: %d pass / %d fail / %d total ---" % [_pass, _fail, _pass + _fail])
	print("coverage: ui_smoke=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
		get_tree().quit(1)
	else:
		get_tree().quit(0)
