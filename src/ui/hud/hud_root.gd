class_name HudRoot
extends Control
## hud_root.gd — HUD 组装根（包 D 表现组 · W1 灰盒）
##
## ── 职责 ──   把时段行与四条状态条摆到左上角；是 W1 唯一的对外入口。
## ── 不做 ──   不写状态、不切场景、不含任何游戏规则（那些归包 B / scene_router）。
## ── 依赖 ──   HudClock · HudVitals · HudStyle
## ── 判据 ──   P20（常驻显示）；S5（27 组合分辨率 UI 越界 0）——W4 自查
##
## ── 用法（灰盒） ──
##   scenes/ui/hud_graybox.tscn 直接挂本脚本；或在任意场景里 add_child(HudRoot.new())
##
## ── TODO ──
##  [x] W2：链状态面板挂到本根（HudLoopPanel，同根共享分辨率适配）
##  [ ] W3：由 scene_router 统一挂接，不再手动 add_child

func _ready() -> void:
	# 鼠标穿透：HUD 不吞点击，否则底下可交互物体点不到（灰盒期就该定，后期改很痛）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_build()

func _build() -> void:
	var panel := VBoxContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	panel.position = Vector2(HudStyle.PANEL_PAD, HudStyle.PANEL_PAD)
	panel.add_theme_constant_override("separation", HudStyle.ROW_GAP)
	add_child(panel)

	var clock := HudClock.new()
	panel.add_child(clock)
	var vitals := HudVitals.new()
	panel.add_child(vitals)

	# W2：三块硬 UI（瞬间报告 + 链状态面板 + 两级预警）挂同一列，流式排布。
	# 曾绝对定位 y=70——clock+vitals 的实际高度（默认字体时代）就已越 70，
	# 与 vitals 底部重叠（S5 只查视口越界不查重叠，故一直没红）；像素字体
	# 行高更高会放大重叠 → 改为进同一 VBox，高度变化自适应。
	var loop_panel := HudLoopPanel.new()
	panel.add_child(loop_panel)

	# W4：音频警报随 HUD 生命周期（纯消费者，只读订阅 State）
	add_child(AudioSystem.new())
