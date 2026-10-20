class_name SettingsScreen
extends Control
## settings_screen.gd — 设置页（包 D 表现组 · W3/S8）
##
## ── 职责 ──   语言切换（S8）+ 键位重绑面板（S6，实现在 keybind_settings.gd）
## ── 不做 ──   不写状态；不改 core；键位落盘走 Save profile 通道（在 keybind_settings.gd）
## ── 依赖 ──   Localize.set_lang / Localize.text · HudStyle · KeybindSettings
## ── 判据 ──   S6（全键位重绑+恢复默认+冲突提示）S8（切语言无需重启、占位符残留 0）
##
## ── 为什么切语言要遍历整棵 UI 树 ──
## core 的 localization.gd 没有"语言已变"的通知信号，而 core 是禁改层，
## 不能为了发个信号去动它。所以约定：任何需要随语言重刷的 UI 节点实现
## refresh_text()，设置页改完语言后遍历整棵树逐个调。
## 代价是 O(节点数)，好处是不碰 core——这个交换在本项目里是划算的。
##
## ── TODO ──
##  [ ] 语言选择持久化（走 Save profile 通道，等 meta_system 接手 profile 生命周期）

const LANGS := ["zh_CN", "zh_TW", "en"]

var _title: Label
var _lang_label: Label
var _lang_options: OptionButton
var _keybind_label: Label
var _close_btn: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_build()

func _build() -> void:
	var panel := PanelContainer.new()
	# center 锚定 + grow both：尺寸变化时保持居中。曾因只用 PRESET_CENTER（offsets
	# 按旧尺寸算定）+ S6 撑高面板 → 矩形从中心向右下延伸出视口（S5 抓到）。
	panel.set_anchors_preset(Control.PRESET_CENTER, false)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	# 640×360 逻辑视口下键位 10 行 + 语言 + 标题 ≈ 540px 高会超屏（S5 实测 30 处越界）
	# → 内容走滚动容器：面板本身钉在视口内，键位列表滚动可达（滚动区不算越界，
	#   ui_screenshot_runner 对 clip 容器子树豁免）。
	panel.custom_minimum_size = Vector2(200.0, 330.0)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.clip_contents = true   # 裁剪滚动内容（S5 runner 对 clip 子树豁免越界检查）
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	scroll.add_child(col)

	_title = Label.new()
	col.add_child(_title)

	var lang_row := HBoxContainer.new()
	col.add_child(lang_row)
	_lang_label = Label.new()
	_lang_label.custom_minimum_size = Vector2(52.0, 12.0)
	lang_row.add_child(_lang_label)
	_lang_options = OptionButton.new()
	_lang_options.custom_minimum_size = Vector2(104.0, 14.0)
	# 语言名永远用该语言自己的写法（选简体中文时看到的"English"仍是 English），
	# 所以这里不随 refresh_text 重建——重建会把用户当前选中项清掉
	for code: String in LANGS:
		_lang_options.add_item(_lang_display_name(code))
		_lang_options.set_item_metadata(_lang_options.item_count - 1, code)
	_lang_options.item_selected.connect(_on_lang_selected)
	lang_row.add_child(_lang_options)

	_keybind_label = Label.new()
	col.add_child(_keybind_label)

	# S6：键位重绑面板（动态遍历 InputMap，冲突拒绝式，profile 落盘）
	var keybinds := KeybindSettings.new()
	col.add_child(keybinds)

	_close_btn = Button.new()
	_close_btn.pressed.connect(_on_close_pressed)
	col.add_child(_close_btn)

	_sync_selection()
	refresh_text()

func _lang_display_name(code: String) -> String:
	match code:
		"zh_CN":
			return Localize.text("LANG_NAME_ZH_CN")
		"zh_TW":
			return Localize.text("LANG_NAME_ZH_TW")
		"en":
			return Localize.text("LANG_NAME_EN")
		_:
			return code

func _sync_selection() -> void:
	var cur := Localize.get_lang()
	for i in _lang_options.item_count:
		if String(_lang_options.get_item_metadata(i)) == cur:
			_lang_options.select(i)
			return

func _on_lang_selected(index: int) -> void:
	var code := String(_lang_options.get_item_metadata(index))
	if code == Localize.get_lang():
		return
	Localize.set_lang(code)
	_refresh_whole_ui()
	Logger.log("ui", "language_changed", "", 0, code)

func _on_close_pressed() -> void:
	queue_free()

## S8：切语言不得要求重启，也不得留下旧语言的占位符
func _refresh_whole_ui() -> void:
	var root := get_tree().root
	if root != null:
		_walk_refresh(root)
	refresh_text()

func _walk_refresh(n: Node) -> void:
	if n.has_method("refresh_text"):
		n.refresh_text()
	for c: Node in n.get_children():
		_walk_refresh(c)

func refresh_text() -> void:
	_title.text = Localize.text("SETTINGS_TITLE")
	_lang_label.text = Localize.text("SETTINGS_LANG")
	_keybind_label.text = Localize.text("SETTINGS_KEYBIND")
	_close_btn.text = Localize.text("SETTINGS_CLOSE")
