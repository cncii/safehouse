class_name MainMenuScreen
extends Control
## main_menu_screen.gd — 极简主菜单（TASK-G M1 · 表现组）
##
## ── 职责 ──   新游戏 / 继续 / 设置 / 退出 → GameWorld 编排 + SceneRouter 切换
## ── 不做 ──   不直接 new 任何游戏系统（那是 GameWorld 的编排职责）；
##              不读档不写档（Save 的 API 调用只在 GameWorld.continue_game 里）
## ── 词条 ──   MAIN_MENU_*（零中文字面量）

const _Store = preload("res://src/core/state_store.gd")


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT, false)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER, false)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	var title := Label.new()
	title.text = Localize.text("MAIN_MENU_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE + 8)
	title.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	box.add_child(_button("MAIN_MENU_NEW", _on_new_game))
	_continue_btn = _button("MAIN_MENU_CONTINUE", _on_continue)
	_continue_btn.disabled = Save.load_run().is_empty()
	box.add_child(_continue_btn)
	box.add_child(_button("MAIN_MENU_SETTINGS", _on_settings))
	box.add_child(_button("MAIN_MENU_QUIT", _on_quit))

	var hint := Label.new()
	hint.text = Localize.text("MAIN_MENU_HINT")
	hint.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	hint.add_theme_color_override("font_color", Color(0.5, 0.52, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


var _continue_btn: Button


func _button(text_key: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = Localize.text(text_key)
	b.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(180, 28)
	b.pressed.connect(action)
	return b


func _router() -> SceneRouter:
	return get_tree().root.get_node_or_null("SceneRouter") as SceneRouter


## 等路由器空闲再切场景。
##
## ★ 为什么必须等：主菜单自己是"淡入中"挂上来的（SceneRouter 的 FADING_IN 阶段），
##   玩家/脚本在菜单刚出现的那一帧就点"新游戏"，`goto()` 会因 `_phase != IDLE`
##   被判 `transition in progress` **直接丢弃**——表现为"点了没反应"。
##   实测（2026-10-22 真链路探针）：boot→主菜单→立刻点新游戏 → goto_rejected，
##   场景永远停在主菜单。人慢慢点通常碰不到，脚本/连点必中。
func _goto_when_idle(target: StringName) -> void:
	var router := _router()
	if router == null:
		return
	for _i in 300:
		if not router.is_transitioning():
			router.goto(target)
			return
		await get_tree().process_frame


## 新游戏：清掉旧对局（回主菜单再开的情形）→ 编排新局 → 切 safehouse
func _on_new_game() -> void:
	var old := GameWorld.instance()
	if old:
		old.queue_free()
	var world := GameWorld.new()
	get_tree().root.add_child.call_deferred(world)
	# start_new_game 必须等 GameWorld 进树（_ready 连 GameLoop 信号）：
	# 延后到下一帧再编排 + 切场景
	call_deferred("_start_world", world)


func _start_world(world: GameWorld) -> void:
	world.start_new_game()
	await _goto_when_idle(&"safehouse")


func _on_continue() -> void:
	var old := GameWorld.instance()
	if old:
		old.queue_free()
	var world := GameWorld.new()
	get_tree().root.add_child.call_deferred(world)
	call_deferred("_continue_world", world)


func _continue_world(world: GameWorld) -> void:
	if not world.continue_game():
		return
	var target := String(State.read("player.scene_id"))
	await _goto_when_idle(StringName(target) if target != "" else &"safehouse")


func _on_settings() -> void:
	await _goto_when_idle(&"settings")


func _on_quit() -> void:
	get_tree().quit()
