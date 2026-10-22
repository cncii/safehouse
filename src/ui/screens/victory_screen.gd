class_name VictoryScreen
extends CanvasLayer
## victory_screen.gd — 通关画面（TASK-G M5 · 表现组）
##
## ── 职责 ──   夜 7 天亮后的一行字 + 返回主菜单
## ── 不做 ──   不做结局分支（结局 A/B 不在 TASK-G 范围，任务书 §2 明确"不做"）；
##              不结算统计（灰盒阶段没有需要展示的分数）
## ── 词条 ──   VICTORY_*（零中文字面量）


func _ready() -> void:
	layer = 25
	_build()
	visible = false


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.09, 0.94)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER, false)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	var title := Label.new()
	title.text = Localize.text("VICTORY_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE + 10)
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 0.6))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var sub := Label.new()
	sub.text = Localize.text("VICTORY_SUB")
	sub.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	sub.add_theme_color_override("font_color", Color(0.75, 0.78, 0.8))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	var btn := Button.new()
	btn.text = Localize.text("VICTORY_BACK")
	btn.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(200, 28)
	btn.pressed.connect(back_to_menu)
	box.add_child(btn)


func show_victory() -> void:
	visible = true
	GameLoop.set_suspended(true)


## 公开：按钮与判据共用同一条路径
func back_to_menu() -> void:
	visible = false
	GameLoop.set_suspended(false)
	var router := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
	if router:
		router.goto(&"main_menu")
