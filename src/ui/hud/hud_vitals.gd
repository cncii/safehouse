class_name HudVitals
extends VBoxContainer
## hud_vitals.gd — 四条状态条容器（包 D 表现组 · W1 灰盒）
##
## ── 职责 ──   HP / 体力 / 饱食 / 水分 四条常驻状态条。
## ── 不做 ──   不写状态；不持有 vitals_system 引用（横向依赖白名单禁止）。
## ── 依赖 ──   State.read / State.subscribe（只读消费）· Localize · HudStyle
## ── 判据 ──   P20（常驻库存 + 显示值偏差 0）：值直接取 State.read()，
##              中途不做任何取整/平滑，显示多少就是状态多少
##
## ── 订阅口径 ──
## State.subscribe 的 prefix 是"路径去掉最后一段"：player.hp → "player"。
## 因此四条状态共用一个 "player" 订阅，一次回调里整体刷新，不逐条订阅。
##
## ── TODO ──
##  [ ] W2：与链状态面板共用同一行距/色阶（先别各做各的，否则联调要全部重排）

var _bars: Array = []            # [{bar, path}]
var _sub_handle := -1

func _ready() -> void:
	add_theme_constant_override("separation", HudStyle.ROW_GAP)
	for def: Dictionary in _vital_defs():
		var bar := VitalBar.new()
		# 顺序不能反：VitalBar 的 Label/ProgressBar 在它自己的 _ready() 里才创建，
		# 而 _ready() 由 add_child 触发。先 setup 再 add_child = 给 null 赋值。
		add_child(bar)
		bar.setup(StringName(String(def["key"])), float(def["low"]))
		_bars.append({"bar": bar, "path": StringName(String(def["path"]))})
	_sub_handle = State.subscribe(&"player", _on_player_changed)
	_refresh()

func _exit_tree() -> void:
	if _sub_handle >= 0:
		State.unsubscribe(_sub_handle)
		_sub_handle = -1

func _vital_defs() -> Array:
	return [
		{"path": "player.hp", "key": "HUD_VITAL_HP", "low": HudStyle.LOW_HP},
		{"path": "player.stamina", "key": "HUD_VITAL_STAMINA", "low": HudStyle.LOW_STAMINA},
		{"path": "player.hunger", "key": "HUD_VITAL_HUNGER", "low": HudStyle.LOW_HUNGER},
		{"path": "player.thirst", "key": "HUD_VITAL_THIRST", "low": HudStyle.LOW_THIRST},
	]

func _on_player_changed(_source: StringName, _reason: String) -> void:
	_refresh()

func _refresh() -> void:
	for item: Dictionary in _bars:
		var v: Variant = State.read(String(item["path"]))
		(item["bar"] as VitalBar).set_value(float(v))
