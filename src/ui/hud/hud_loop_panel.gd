class_name HudLoopPanel
extends VBoxContainer

## hud_loop_panel.gd — W2 三块硬 UI（包 D 表现组）
## ── 数据 ──   LoopSystem.maintenance_urgency()（只读方法，实例挂 /root/LoopSystem）
##              data/balance/survival.json（预警阈值键，缺失则降级，见 UNDEFINED D-017）
## ── 边界 ──   UI 只读：不 State.apply()、不写 loop.*/facilities.*；数值零魔法数。
##
## 三块（任务书 §4，设计定稿）：
##   块1 建造/停机瞬间三行报告 —— State "loop" 段变化时刷新（R13' 知识型必败唯一解法）
##   块2 链状态面板 —— 动态遍历 maintenance_urgency() 返回值渲染：接口给几条显示几条。
##       （🔴 链数量冲突裁定 2026-10-20：逻辑组 loop_system.gd 注释已明确"链状态面板四项"，
##        data/** 无链清单 JSON → 接口即权威。动态渲染结构性免疫"面板 5 条/接口 4 条"返工。）
##   块3 库存两级预警 —— days_left 低于阈值着色（黄→红），阈值读 survival.json；
##       键缺失 = 不着色（数值纪律：不编造、不填默认值），数值落位零改动生效。
##
## ⚠ core wiring 欠件：全工程尚无 LoopSystem 实例挂 /root（combat_system 同样在等）。
##   本面板防御式获取，缺位时显示降级文案并 push_warning 一次，wiring 落位自动恢复。

const _LOOP_NODE := "/root/LoopSystem"
const _SURV_PATH := "res://data/balance/survival.json"
const _WARN_KEY_Y := "stock_warn_yellow_days"   # UNDEFINED D-017 约定键名
const _WARN_KEY_R := "stock_warn_red_days"

var _loop: Node = null
var _warned_no_wiring := false
var _warn_rows: Dictionary = {}            # res -> Label（块3 着色目标）
var _warn_thresholds := {}                 # yellow_days / red_days；缺键时为空
var _report_label: Label
var _grid: GridContainer
var _last_loop_signature := {}

static var _s_thresholds := {}
static var _s_thresholds_loaded := false


## 预警阈值唯一读取口：HudLoopPanel（着色）与 AudioSystem（一次性音效）都必须走这里，
## 与"显示/反馈阈值不许留副本"纪律同源（先例：audio 引用 HudStyle.LOW_*）。
## 键缺失返回空 Dictionary —— 消费方据此整体降级，不编造数值（UNDEFINED D-017）。
static func warn_thresholds() -> Dictionary:
	if not _s_thresholds_loaded:
		_s_thresholds_loaded = true
		var f := FileAccess.open(_SURV_PATH, FileAccess.READ)
		if f == null:
			push_warning("hud_loop_panel: %s missing - stock warn disabled" % _SURV_PATH)
			return {}
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) != TYPE_DICTIONARY:
			push_warning("hud_loop_panel: %s not a json object - stock warn disabled" % _SURV_PATH)
			return {}
		var d: Dictionary = parsed
		if d.has(_WARN_KEY_Y) and d.has(_WARN_KEY_R):
			_s_thresholds = {"y": float(d[_WARN_KEY_Y]), "r": float(d[_WARN_KEY_R])}
		else:
			push_warning("hud_loop_panel: %s lacks %s/%s - stock warn disabled (UNDEFINED D-017)" % [
				_SURV_PATH, _WARN_KEY_Y, _WARN_KEY_R])
	return _s_thresholds


var _loop_sub := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_thresholds = warn_thresholds()
	_build()
	_refresh()
	# loop 段由 LoopSystem._write_store 写入（建成/升级/停机最终都会反映到这里）
	_loop_sub = State.subscribe(&"loop", _on_loop_changed)


## 退树时必须退订：State 的订阅表是全局的，HUD 被 free 后回调仍会指向死对象，
## 之后每次 loop 段写入都会刷一排 `null::_on_loop_changed`（实测 50 条噪音），
## 且真正的错误会被淹掉。
func _exit_tree() -> void:
	if _loop_sub >= 0:
		State.unsubscribe(_loop_sub)
		_loop_sub = -1


func _on_loop_changed(_source: StringName, _reason: String) -> void:
	# 块1"瞬间"语义：变化即刷新报告与面板。wiring 缺位时借此机会重试获取。
	_refresh()


func _try_bind_loop() -> Node:
	if is_instance_valid(_loop):
		return _loop
	_loop = get_node_or_null(_LOOP_NODE)
	if _loop == null and not _warned_no_wiring:
		_warned_no_wiring = true
		push_warning("hud_loop_panel: LoopSystem not wired at %s - showing fallback; awaiting core wiring" % _LOOP_NODE)
	return _loop


func _build() -> void:
	add_theme_constant_override("separation", HudStyle.ROW_GAP)

	var title := Label.new()
	title.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	title.add_theme_color_override("font_color", HudStyle.COLOR_TEXT)
	title.text = Localize.text("LOOP_PANEL_TITLE")
	add_child(title)

	# 块1：建造/停机瞬间三行报告（变化时由 _refresh 更新）
	_report_label = Label.new()
	_report_label.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	_report_label.add_theme_color_override("font_color", HudStyle.COLOR_WARN)
	add_child(_report_label)

	# 块2：链状态面板。列头 + 动态数据行（列数固定 5，行数跟随接口）。
	_grid = GridContainer.new()
	_grid.columns = 5
	_grid.add_theme_constant_override("h_separation", HudStyle.ROW_GAP)
	add_child(_grid)
	for key: String in ["LOOP_COL_CHAIN", "LOOP_COL_RATE", "LOOP_COL_STOCK",
			"LOOP_COL_DAYS", "LOOP_COL_BLOCK"]:
		_grid.add_child(_make_cell(Localize.text(key), HudStyle.COLOR_TEXT))


func _make_cell(txt: String, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", HudStyle.FONT_SIZE)
	l.add_theme_color_override("font_color", color)
	l.text = txt
	return l


func _refresh() -> void:
	var loop := _try_bind_loop()
	if loop == null or not loop.has_method("maintenance_urgency"):
		_report_label.text = Localize.text("LOOP_DATA_NOT_WIRED")
		return
	var urg: Dictionary = loop.maintenance_urgency()
	_render_report(urg)
	_render_rows(urg)


## 块1：建造/停机瞬间三行。接口不回 demand/缺口，但 days_left = stock / (demand - rate)
## 数学可逆：缺口/天 = stock_units / days_left（同源导出，非副本）。
func _render_report(urg: Dictionary) -> void:
	var lines: PackedStringArray = []
	for res: String in urg.keys():
		var st: Dictionary = urg[res]
		var dl := float(st["days_left"])
		if dl > 0.0 and not is_inf(dl):
			var gap := float(st["stock_units"]) / dl
			lines.append(Localize.textf("LOOP_REPORT_GAP", {
				"chain": Localize.text("LOOP_CHAIN_" + res),
				"gap": "%.2f" % gap,
				"stock": "%.1f" % float(st["stock_units"]),
				"days": "%.1f" % dl,
			}))
	if lines.is_empty():
		_report_label.text = ""
	else:
		_report_label.text = "\n".join(lines)


## 块2 + 块3：动态行渲染 + 阈值着色。行数 == 接口返回条数（不硬编码 4/5）。
func _render_rows(urg: Dictionary) -> void:
	# 保留列头（前 5 个子节点），清掉旧数据行
	while _grid.get_child_count() > 5:
		var c := _grid.get_child(5)
		_grid.remove_child(c)
		c.queue_free()
	_warn_rows.clear()

	for res: String in urg.keys():
		var st: Dictionary = urg[res]
		var row_color := _warn_color(float(st["days_left"]))
		var cells := [
			Localize.text("LOOP_CHAIN_" + res),
			"%.2f" % float(st["rate_per_day"]),
			"%.1f" % float(st["stock_units"]),
			_format_days(float(st["days_left"])),
			Localize.text("LOOP_BLOCK_" + String(st["blocked_at"]).to_upper()),
		]
		for i: int in cells.size():
			var cell := _make_cell(String(cells[i]), row_color)
			_grid.add_child(cell)
			if i == 0:
				_warn_rows[res] = cell


func _warn_color(days_left: float) -> Color:
	if _warn_thresholds.is_empty() or days_left < 0.0 or is_inf(days_left):
		return HudStyle.COLOR_TEXT
	if days_left < float(_warn_thresholds["r"]):
		return HudStyle.COLOR_CRITICAL
	if days_left < float(_warn_thresholds["y"]):
		return HudStyle.COLOR_WARN
	return HudStyle.COLOR_TEXT


func _format_days(dl: float) -> String:
	if dl < 0.0:
		return "-"          # 接口语义：-1 = 净产出为正，不会见底
	if is_inf(dl):
		return "-"          # 无需求链：不存在"耗尽"
	return "%.1f" % dl
