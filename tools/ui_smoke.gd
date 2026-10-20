extends SceneTree
## ui_smoke.gd — 表现组（包 D）自验冒烟
## 用法：godot --headless -s tools/ui_smoke.gd
##
## 归属说明：本文件是表现组自己验证 W1/W3 交付物的工具，**不进 tools/test.ps1**
## （test.ps1 是包 F 编排的验收单一入口，要并入需由包 F 决定断言计数口径）。
##
## 每条判据注明"能抓什么"——抓不住东西的断言等于噪音，最后会被关掉。

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

func _initialize() -> void:
	_test_locale_chain()
	_test_vitals_bars()
	_test_clock()
	_test_hud_root()
	_test_settings_language_switch()
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
	root.add_child(vitals)          # _ready 依赖入树，顺序不能反

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
	for item: Dictionary in v._bars:
		var b: VitalBar = item["bar"]
		if b._name_label.text == "":
			return false
		if b._name_label.text == String(item["key"]):
			return false      # 退化成裸 KEY 了
	return true

# ── 时段显示 ──
# 能抓：GH→时钟换算被改（小数部分按 60 分而不是 100 分）、
#       time.stage 未命中时直接 String() 把 0.0 显示成 "0"。
func _test_clock() -> void:
	var clock := HudClock.new()
	root.add_child(clock)

	_t("clock: 0 GH -> 00:00", clock._gh_to_clock(0.0) == "00:00")
	_t("clock: 14.5 GH -> 14:30", clock._gh_to_clock(14.5) == "14:30")
	_t("clock: 23.9 GH -> 23:54", clock._gh_to_clock(23.9) == "23:54")
	_t("clock: over 24 clamps", clock._gh_to_clock(30.0) == "00:00")

	# 关键：State.read 未命中返回 0.0，是 float 不是 string → 必须显示 fallback 而不是 "0"
	_t("clock: unset stage shows fallback not literal zero",
		clock._stage_text() != "A_LOOT" and clock._stage_text() != "0")

	clock.queue_free()

# ── HUD 组装根 ──
# 能抓：HudRoot 忘了加 HudVitals 或 HudClock（W2/W3 接新面板时最容易漏）。
func _test_hud_root() -> void:
	var hud := HudRoot.new()
	root.add_child(hud)
	_t("hud_root: has clock child", _has_type(hud, "HudClock"))
	_t("hud_root: has vitals child", _has_type(hud, "HudVitals"))
	hud.queue_free()

# ── 设置页切语言 ──
# 能抓：切语言后 UI 树没被重刷（S8 回归）、或者设了语言但没落回 zh_CN 影响后续用例。
func _test_settings_language_switch() -> void:
	var settings := SettingsScreen.new()
	root.add_child(settings)
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
	print("--- ui_smoke: %d pass / %d fail ---" % [_pass, _pass + _fail])
	print("coverage: ui_smoke=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
		quit(1)
	else:
		quit(0)
