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
	await _test_loop_panel()
	_test_audio_alarms()
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

	_t("clock: 0 GH -> 00:00", clock._gh_to_clock(0.0) == "00:00")
	_t("clock: 14.5 GH -> 14:30", clock._gh_to_clock(14.5) == "14:30")
	_t("clock: 23.9 GH -> 23:54", clock._gh_to_clock(23.9) == "23:54")
	_t("clock: over 24 clamps", clock._gh_to_clock(30.0) == "00:00")

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
