class_name HudClock
extends HBoxContainer
## hud_clock.gd — 日程/时段显示（包 D 表现组 · W1 灰盒）
##
## ── 职责 ──   D{第几天} + 当日 GH 时刻 + 阶段名。三块拼一行。
## ── 不做 ──   不写状态；不推进时间（时间唯一真相是 GameLoop 的 elapsed_ticks）。
## ── 依赖 ──   State.read / State.subscribe（只读）· Localize · HudStyle
## ── 判据 ──   P20（HUD 倒计时/时刻偏差 ≤1GH）：时刻由 gh 直算，
##              不做任何插值或缓存——缓存一帧就是偏差来源
##
## ── GH 口径 ──
## 1 GH = 72 s 现实时间（M1），一天 24 GH（state_contract 的 max=24）。
## gh 的小数部分按 60 分制展开成 HH:MM，因此 gh=14.5 → 14:30。
##
## ── TODO ──
##  [ ] W3：门禁倒计时（阶段A 20:00 锁门）与时段并排，同一行右对齐

var _day_label: Label
var _time_label: Label
var _stage_label: Label
var _sub_handle := -1

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_day_label = _make_label(26.0)
	_time_label = _make_label(38.0)
	_stage_label = _make_label(72.0)
	_sub_handle = State.subscribe(&"time", _on_time_changed)
	_refresh()

func _exit_tree() -> void:
	if _sub_handle >= 0:
		State.unsubscribe(_sub_handle)
		_sub_handle = -1

func _make_label(w: float) -> Label:
	var l := Label.new()
	l.custom_minimum_size = Vector2(w, HudStyle.BAR_H + 4.0)
	l.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	l.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	add_child(l)
	return l

func _on_time_changed(_source: StringName, _reason: String) -> void:
	_refresh()

## 切语言时被调用（见 settings_screen.gd）
func refresh_text() -> void:
	_refresh()

func _refresh() -> void:
	var day := int(State.read("time.day"))
	_day_label.text = Localize.textf("HUD_CLOCK_DAY", {"day": day})
	_time_label.text = _clock_text(float(State.read("time.gh_elapsed_today")))
	_stage_label.text = _stage_text()

## time.gh_elapsed_today 语义 = 「今天从日起点已过的活跃 GH」（0..24，time_system 同步），
## **不是钟点**。钟点 = 日起点 + 已过：阶段A 起点 prep_start_gh（05:00）、
## 阶段B 起点 stage_b_dawn_gh（06:00），数值唯一来源 = data/balance/time.json。
## ⚠ 旧实现把"已过"直接当地钟换算——C-01 修复（逻辑组 633c386）让这条路径
##   第一次有真值后，TASK-G M1 灰盒实机测出显示恒偏 5 小时，本函数修正口径。
static var _time_marks: Dictionary = {}

func _clock_text(elapsed: float) -> String:
	var raw_stage: Variant = State.read("time.stage")
	var is_stage_b := raw_stage is String and String(raw_stage).begins_with("B")
	var mark := _day_mark("stage_b_dawn_gh") if is_stage_b else _day_mark("prep_start_gh")
	return compose_clock(elapsed, mark)


## 纯函数（可测）：已过活跃 GH + 日起点 → 钟点。clamp 防越界，24 点自然折回。
static func compose_clock(elapsed: float, mark: float) -> String:
	var total_min := int(roundf((clampf(elapsed, 0.0, 24.0) + mark) * 60.0))
	var hh := (total_min / 60) % 24
	var mm := total_min % 60
	return "%02d:%02d" % [hh, mm]


func _day_mark(key: String) -> float:
	if _time_marks.is_empty():
		var f := FileAccess.open("res://data/balance/time.json", FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY:
				_time_marks = parsed
	return float(_time_marks.get(key, 0.0))

## time.stage 是 string 类型，但 State.read 未命中时返回 0.0——
## 直接 String() 会显示 "0"，必须按类型过滤，不能无脑转字符串
## ⚠ time_system._stage_name() 写入的是 "A"/"B"（枚举名不落盘——数值会漂），
##   旧实现匹配 "A_LOOT"/"B_SIEGE" 恒 UNKNOWN；两套名都接住，灰盒期兼容。
func _stage_text() -> String:
	var raw: Variant = State.read("time.stage")
	if not (raw is String):
		return Localize.text("HUD_STAGE_UNKNOWN")
	match String(raw):
		"A", "A_LOOT":
			return Localize.text("HUD_STAGE_A_LOOT")
		"B", "B_SIEGE":
			return Localize.text("HUD_STAGE_B_SIEGE")
		_:
			return Localize.text("HUD_STAGE_UNKNOWN")
