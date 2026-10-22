class_name DeathScreen
extends CanvasLayer
## death_screen.gd — 死亡画面（TASK-G M4 · 表现组）
##
## ── 职责 ──   显示死因 + "从当日清晨重开"按钮
## ── 不做 ──   不自己重开（重开要还原存档快照，属 GameWorld 的编排职责）；
##              不做结局/统计（M5 通关画面是另一个场景）
## ── 词条 ──   DEATH_*（零中文字面量）
##
## 死因字符串来自 ResolveOrder.DAMAGE_SOURCE_ORDER（"starvation" 等英文枚举），
## 这里只做「枚举 → 词条」的映射，不认识任何"为什么死"的规则。

var world: GameWorld

var _cause_label: Label
var _cause := ""


func _ready() -> void:
	layer = 20
	_build()
	visible = false


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.03, 0.03, 0.92)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER, false)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	var title := Label.new()
	title.text = Localize.text("DEATH_TITLE")
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE + 10)
	title.add_theme_color_override("font_color", Color(0.85, 0.3, 0.28))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_cause_label = Label.new()
	_cause_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_cause_label.add_theme_color_override("font_color", Color(0.75, 0.72, 0.7))
	_cause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_cause_label)

	var btn := Button.new()
	btn.text = Localize.text("DEATH_RESTART")
	btn.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(200, 28)
	btn.pressed.connect(restart)
	box.add_child(btn)


func show_death(cause: String) -> void:
	_cause = cause
	_cause_label.text = Localize.text(cause_key(cause))
	visible = true
	# 死亡扣血已经发生，时间必须停住——否则躺在地上还在掉饥饿
	GameLoop.set_suspended(true)


## 死因枚举 → 词条 key。未知枚举回退 UNKNOWN，**不把英文枚举漏到玩家脸上**。
static func cause_key(cause: String) -> String:
	match cause:
		"starvation":
			return "DEATH_CAUSE_STARVATION"
		"dehydration":
			return "DEATH_CAUSE_DEHYDRATION"
		"bleed":
			return "DEATH_CAUSE_BLEED"
		"bite":
			return "DEATH_CAUSE_BITE"
		"wild_sleep":
			return "DEATH_CAUSE_WILD_SLEEP"
	return "DEATH_CAUSE_UNKNOWN"


## 重开（公开：按钮与判据共用同一条路径，判据不必去点私有方法）
func restart() -> void:
	visible = false
	GameLoop.set_suspended(false)
	if world:
		world.restart_from_day_start()
