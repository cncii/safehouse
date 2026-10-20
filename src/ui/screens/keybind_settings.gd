class_name KeybindSettings
extends VBoxContainer
## keybind_settings.gd — S6 键位重绑面板（包 D 表现组）
##
## ── 职责 ──   全键位重绑 + 冲突提示（拒绝式）+ 恢复默认 + profile 落盘/启动恢复
## ── 不做 ──   手柄（S7 超上游范围，待拍板）；不做 Steam Input（架构 §6.1：内置 InputMap）
## ── 依赖 ──   Save.load_profile / save_profile（L1 存档，profile 通道现成——
##              S6 落盘**不必等包 E meta_system**，任务书 TODO 在此更正）
## ── 判据 ──   S6（全键位重绑 + 恢复默认 + 冲突提示）
##
## ── 动作清单来源（数值纪律）──
## 动态遍历 InputMap.get_actions() 并过滤 "ui_" 前缀（Godot 内置动作），
## 清单与 project.godot [input] 段天然同步——增删动作无需改本文件
## （与 W2 链面板"接口给几条显示几条"同一设计哲学）。
##
## ── 冲突策略 ── 拒绝式：新键已被其他动作占用 → 红字提示"已被「X」占用"，
## 不完成改写。任务书只要求"冲突提示"，拒绝比覆盖+警告更保守，
## 误绑后想找回旧键只能恢复默认，覆盖式会造成连锁改键。
##
## ── ESC 边界 ── listening 状态下 ESC 一律是"取消重绑"，不是绑定输入。
## 想把某动作绑回 ESC：恢复默认（pause 默认即 ESC）后不要再改 pause。
##
## ── 存储结构（profile.sav，save.schema.json 不管 profile 段）──
## profile.keybinds = { "<action>": <physical_keycode int>, ... }
## 读-改-写全量回存：保留 profile 里其他段（语言选择等将来共存）。

const UI_ACTION_PREFIX := "ui_"

var _rows := {}                # action -> {label: Label, btn: Button}
var _listening_action := ""    # 非空 = 正在等待该动作的新按键
var _note: Label
var _note_key := ""            # 当前提示 i18n 键（"" = 无提示）
var _note_args: Dictionary = {}
var _reset_btn: Button

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build()
	refresh_text()
	set_process_input(false)

## ── 对外 API（ui_smoke 直接调用验证；boot 用 static 版）──

## 重绑一个动作。成功返回 ""；冲突返回占用动作名（InputMap 不变，已提示）。
func rebind(action: String, phys_keycode: int) -> String:
	var conflict := _find_conflict(action, phys_keycode)
	if conflict != "":
		_set_note("KEYBIND_CONFLICT", {"action": Localize.text("ACTION_" + conflict.to_upper())})
		return conflict
	_apply_one(action, phys_keycode)
	_persist_all()
	_set_note("", {})
	Logger.log("ui", "keybind_rebind", action, phys_keycode)
	return ""

## 恢复全部动作为工程默认（project.godot [input]），并清除 profile 里的 keybinds 段。
func reset_defaults() -> void:
	InputMap.load_from_project_settings()
	_listening_action = ""
	for action: String in _rows:
		_rows[action]["btn"].text = _key_label(_primary_key(action))
	_persist_all()
	_set_note("KEYBIND_RESET_DONE", {})
	Logger.log("ui", "keybind_reset", "", 0)

## 启动时应用已保存键位（boot 自检通过后调用）。
## static：不依赖实例；autoload 在 static 上下文解析不到，经 main loop root 取 Save。
static func apply_saved() -> void:
	var save_node: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Save")
	if save_node == null:
		push_warning("keybind: Save not ready - saved keybinds not applied this boot")
		return
	var profile: Dictionary = save_node.load_profile().get("profile", {})
	var binds: Dictionary = profile.get("keybinds", {})
	for action: String in binds:
		if InputMap.has_action(action):
			_apply_one(action, int(binds[action]))

## ── 构建 ──

func _build() -> void:
	for action: String in _game_actions():
		var row := HBoxContainer.new()
		add_child(row)

		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(52.0, 12.0)
		row.add_child(name_label)

		var key_btn := Button.new()
		key_btn.custom_minimum_size = Vector2(104.0, 14.0)
		key_btn.pressed.connect(_on_rebind_pressed.bind(action))
		row.add_child(key_btn)

		_rows[action] = {"label": name_label, "btn": key_btn}
		key_btn.text = _key_label(_primary_key(action))

	_reset_btn = Button.new()
	_reset_btn.pressed.connect(reset_defaults)
	add_child(_reset_btn)

	_note = Label.new()
	add_child(_note)

## 动作清单 = InputMap 全量 - Godot 内置（ui_ 前缀）。顺序即注册顺序（工程定义序）。
func _game_actions() -> PackedStringArray:
	var out: PackedStringArray = []
	for action: StringName in InputMap.get_actions():
		if not String(action).begins_with(UI_ACTION_PREFIX):
			out.append(String(action))
	return out

## ── 交互 ──

func _on_rebind_pressed(action: String) -> void:
	_listening_action = action
	for a: String in _rows:
		var btn := _rows[a]["btn"] as Button
		btn.disabled = (a == action)
		if a == action:
			btn.text = Localize.text("KEYBIND_LISTENING")
	set_process_input(true)

func _input(event: InputEvent) -> void:
	if _listening_action == "":
		set_process_input(false)
		return
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		get_viewport().set_input_as_handled()
		var phys := (event as InputEventKey).physical_keycode
		var action := _listening_action
		_exit_listening()
		if phys == KEY_ESCAPE:
			# ESC 永远是取消，不是绑定（见头注释 ESC 边界）
			_set_note("", {})
			return
		rebind(action, phys)
		(_rows[action]["btn"] as Button).text = _key_label(_primary_key(action))

func _exit_listening() -> void:
	var action := _listening_action
	_listening_action = ""
	set_process_input(false)
	for a: String in _rows:
		(_rows[a]["btn"] as Button).disabled = false
		if a == action:
			(_rows[a]["btn"] as Button).text = _key_label(_primary_key(action))

## ── InputMap 操作 ──

## 目标键被**其他**动作占用时返回该动作名；空闲返回 ""（本动作旧键不参与——会被 erase）。
func _find_conflict(action: String, phys_keycode: int) -> String:
	for other: String in _game_actions():
		if other == action:
			continue
		for ev: InputEvent in InputMap.action_get_events(other):
			if ev is InputEventKey and (ev as InputEventKey).physical_keycode == phys_keycode:
				return other
	return ""

## 单动作改写：清旧事件 → 加新键事件（物理键码，布局无关）。
static func _apply_one(action: String, phys_keycode: int) -> void:
	InputMap.action_erase_events(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = phys_keycode as Key
	InputMap.action_add_event(action, ev)

func _primary_key(action: String) -> int:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return int((ev as InputEventKey).physical_keycode)
	return 0

## 物理键码 → 显示键名（转当前布局键码；headless/dummy 下原样回退，不炸）。
func _key_label(phys: int) -> String:
	if phys == 0:
		return "?"
	var kc := DisplayServer.keyboard_get_keycode_from_physical(phys as Key)
	return OS.get_keycode_string(kc if kc != Key.KEY_NONE else (phys as Key))

## ── 持久化（profile 读-改-写全量回存，不覆盖其他段）──

func _persist_all() -> void:
	var save_node := get_node_or_null("/root/Save")
	if save_node == null:
		push_warning("keybind: Save not ready - keybinds not persisted")
		return
	var profile: Dictionary = save_node.load_profile().get("profile", {})
	var binds := {}
	for action: String in _game_actions():
		var phys := _primary_key(action)
		if phys != 0:
			binds[action] = phys
	profile["keybinds"] = binds
	save_node.save_profile(profile)

## ── S8 协作：设置页切语言时被遍历调用 ──

func refresh_text() -> void:
	for action: String in _rows:
		(_rows[action]["label"] as Label).text = Localize.text("ACTION_" + action.to_upper())
		var btn := _rows[action]["btn"] as Button
		if not btn.disabled:
			btn.text = _key_label(_primary_key(action))
	if _reset_btn != null:
		_reset_btn.text = Localize.text("KEYBIND_RESET")
	if _note != null:
		# 提示随语言重刷（冲突提示的 %s 插值参数存在 _note_args，重刷不丢）
		_note.text = "" if _note_key == "" else Localize.textf(_note_key, _note_args)

## 提示行统一入口：记键名 + 参数，切语言重刷不丢插值。
func _set_note(key: String, args: Dictionary) -> void:
	_note_key = key
	_note_args = args
	_note.text = "" if key == "" else Localize.textf(key, args)
