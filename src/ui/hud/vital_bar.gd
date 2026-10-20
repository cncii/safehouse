class_name VitalBar
extends HBoxContainer
## vital_bar.gd — 单条状态条（包 D 表现组 · W1 灰盒）
##
## ── 职责 ──   一条状态 = 本地化名 + 数值 + 色块进度条。纯显示，无逻辑。
## ── 不做 ──   不写状态（State.apply 在 src/ui 是架构违例，check_deps D2 会拦）；
##              不持有任何 system 引用；不自己算数值，值由调用方从 State.read() 传入。
## ── 依赖 ──   Localize（文本唯一来源）· HudStyle（色阶与几何唯一来源）
## ── 判据 ──   P20（显示值偏差 0）：条长与数值文本同源同一个入参，不二次换算
##
## ── TODO（后续周次，本组自留） ──
##  [ ] W2：低值时的闪烁/描边，与库存两级预警共用同一套反馈语汇
##  [ ] W3：换成美术素材条（纯色块是灰盒占位，不是最终视觉）

var _name_label: Label
var _value_label: Label
var _bar: ProgressBar
var _low_threshold := -1.0      # < 0 表示这条不启用低值告警（如生命另有表现）
var _name_key: StringName = &""

func _ready() -> void:
	add_theme_constant_override("separation", 4)

	_name_label = Label.new()
	_name_label.custom_minimum_size = Vector2(HudStyle.LABEL_W, HudStyle.BAR_H + 4.0)
	_name_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_name_label.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	add_child(_name_label)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.step = 0.01
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(HudStyle.BAR_W, HudStyle.BAR_H)
	add_child(_bar)

	_value_label = Label.new()
	_value_label.custom_minimum_size = Vector2(HudStyle.VALUE_W, HudStyle.BAR_H + 4.0)
	_value_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_value_label.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	add_child(_value_label)

	_apply_track()

## name_key: 本地化键（进 data/locale/strings.csv）
## low_threshold: 低值告警阈值，< 0 表示不启用
func setup(name_key: StringName, low_threshold: float) -> void:
	_name_key = name_key
	_low_threshold = low_threshold
	refresh_text()

## 切语言时被调用（见 settings_screen.gd：core 的 Localize 没有通知信号，
## 不能改 core，所以由设置页主动遍历 UI 树调本方法）
func refresh_text() -> void:
	_name_label.text = Localize.text(String(_name_key))

## v: 0–100（与 state_contract.json 的 min/max 同标度）
func set_value(v: float) -> void:
	var shown := clampf(v, 0.0, 100.0)
	_bar.value = shown
	_value_label.text = "%d" % int(roundf(shown))
	_bar.remove_theme_stylebox_override("fill")
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_for(shown)
	_bar.add_theme_stylebox_override("fill", sb)

func _color_for(v: float) -> Color:
	if _low_threshold >= 0.0 and v <= _low_threshold:
		return HudStyle.COLOR_CRITICAL
	if v <= HudStyle.WARN_RATIO * 100.0:
		return HudStyle.COLOR_WARN
	return HudStyle.COLOR_NORMAL

func _apply_track() -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = HudStyle.COLOR_TRACK
	_bar.add_theme_stylebox_override("background", track)
