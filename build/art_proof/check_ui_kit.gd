extends SceneTree
## check_ui_kit.gd — 按钮/面板/物品格的引擎侧验证（10 件）
##
## 为什么 Python 侧验过还要再验一次（与 check_ui_bar.gd 同理）：
##   Python 读磁盘上的 PNG；游戏读的是 Godot 导入后的 CompressedTexture2D。
##   中间隔着一层导入管线（sRGB、压缩、alpha 处理、fix_alpha_border），
##   **它改了什么 Python 看不见**。本脚本断言"引擎实际拿到的东西"。
##
## ★ 期望值一律在本文件里独立写死，不从 gen_ui_kit.py 或任何 JSON 读。
##   从被测系统那边读期望值 = 恒真式：那边错了，这边跟着一起绿，两边都"通过"。
##
## 断言分层：
##   ① 单件：尺寸 / 无透明留白 / 色集合 / 圆角 2 级台阶 / 九宫可平铺
##   ② 跨件：五态两两差异、左上光源方向、按下反转、禁用无方向光、选中强调色
##   ③ 采样点一律取各边中点——角上那 3 格被圆角切掉了，拿角当探针等于在测圆角

# ── 契约 §4.1 尺寸 + §4.2 九宫 + §3.1 色值（全部独立写死）──
const SPEC := {
	"ui_btn_base_normal":   {"sz": [96, 32],   "m": 8, "cols": ["222034", "323c39", "847e87"]},
	"ui_btn_base_hover":    {"sz": [96, 32],   "m": 8, "cols": ["222034", "595652", "847e87"]},
	"ui_btn_base_pressed":  {"sz": [96, 32],   "m": 8, "cols": ["222034", "595652", "847e87"]},
	"ui_btn_base_disabled": {"sz": [96, 32],   "m": 8, "cols": ["222034", "323c39", "595652"]},
	"ui_btn_base_selected": {"sz": [96, 32],   "m": 8, "cols": ["222034", "323c39", "fbf236"]},
	"ui_panel_dialog":      {"sz": [192, 112], "m": 8, "cols": ["222034", "323c39", "847e87"]},
	"ui_panel_small":       {"sz": [96, 64],   "m": 8, "cols": ["222034", "323c39", "847e87"]},
	"ui_slot_item_normal":  {"sz": [32, 32],   "m": 4, "cols": ["222034", "323c39", "847e87"]},
	"ui_slot_item_hover":   {"sz": [32, 32],   "m": 4, "cols": ["222034", "595652", "847e87"]},
	"ui_slot_item_selected": {"sz": [32, 32],  "m": 4, "cols": ["222034", "323c39", "fbf236"]},
}

const BTN_STATES := ["normal", "hover", "pressed", "disabled", "selected"]
const SLOT_STATES := ["normal", "hover", "selected"]

const C_OUTLINE := "222034"
const C_BASE := "323c39"
const C_SUNKEN := "595652"
const C_HILITE := "847e87"
const C_ACCENT := "fbf236"

var _fail := 0
var _img := {}


func _t(name: String, ok: bool, detail: String = "") -> void:
	print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + detail if detail != "" else ""))
	if not ok:
		_fail += 1


func _init() -> void:
	print("[ui-kit] 引擎侧验证（10 件）")

	for key in SPEC:
		var tex := load("res://assets/sprites/ui/%s.png" % key) as Texture2D
		_t("%s 可加载" % key, tex != null, key + ".png")
		if tex == null:
			continue
		_img[key] = tex.get_image()

	if _img.size() != SPEC.size():
		print("[ui-kit] 贴图缺失 %d 件，中止" % (SPEC.size() - _img.size()))
		quit(1)
		return

	# ── ① 单件 ──
	for key in SPEC:
		var im: Image = _img[key]
		var spec: Dictionary = SPEC[key]
		var w: int = spec["sz"][0]
		var h: int = spec["sz"][1]
		var m: int = spec["m"]

		_t("%s 尺寸 %dx%d" % [key, w, h], im.get_size() == Vector2i(w, h),
				"实际 %s" % str(im.get_size()))
		_t("%s 无透明留白" % key, im.get_used_rect() == Rect2i(0, 0, w, h),
				"可见 %s" % str(im.get_used_rect()))

		var cols := _colors(im)
		var want: Array = spec["cols"]
		_t("%s 色集合 = %s" % [key, str(want)], cols == want, "实际 %s" % str(cols))

		_t("%s 圆角 2 级台阶" % key, _corners_ok(im), "四角应各切 3 格")
		_t("%s 九宫 %dpx 可平铺" % [key, m], _tileable(im, m) == "", _tileable(im, m))

	# ── ② 跨件 ──
	var btn := {}
	for s in BTN_STATES:
		btn[s] = _img["ui_btn_base_" + s]

	# 五态两两差异（防"五个文件内容相同"）
	for i in range(BTN_STATES.size()):
		for j in range(i + 1, BTN_STATES.size()):
			var a: String = BTN_STATES[i]
			var b: String = BTN_STATES[j]
			var d := _diff(btn[a], btn[b])
			_t("按钮 %s|%s 差异 >= 200" % [a, b], d >= 200, "实际 %d px" % d)

	# 左上光源（S3）：常态上左亮于下右
	var n_hi := _luma(_px(btn["normal"], "bhi"))
	var n_lo := _luma(_px(btn["normal"], "blo"))
	_t("normal 左上受光", n_hi > n_lo, "上左 %.1f vs 下右 %.1f" % [n_hi, n_lo])

	# 悬停必须提亮
	var hv := _luma(_px(btn["hover"], "plane"))
	var nv := _luma(_px(btn["normal"], "plane"))
	_t("hover 比 normal 亮", hv > nv, "%.1f vs %.1f" % [hv, nv])

	# 按下必须斜面反转（凹进去）
	var p_hi := _luma(_px(btn["pressed"], "bhi"))
	var p_lo := _luma(_px(btn["pressed"], "blo"))
	_t("pressed 斜面反转", p_hi < p_lo, "上左 %.1f vs 下右 %.1f" % [p_hi, p_lo])

	# 禁用必须无方向光
	var d_a := _px(btn["disabled"], "bhi")
	var d_b := _px(btn["disabled"], "blo")
	_t("disabled 两侧同色（无方向光）", d_a == d_b, "#%s vs #%s" % [d_a, d_b])

	# 非禁用三态必须保留方向光
	for s in ["normal", "hover", "pressed"]:
		var x := _px(btn[s], "bhi")
		var y := _px(btn[s], "blo")
		_t("%s 保留方向光" % s, x != y, "#%s vs #%s" % [x, y])

	# 选中态：强调色只走边框，平面保持底板色（否则文字对比度不够）
	_t("selected 左斜面 = #%s" % C_ACCENT, _px(btn["selected"], "bhi") == C_ACCENT,
			"实际 #%s" % _px(btn["selected"], "bhi"))
	_t("selected 右斜面 = #%s" % C_ACCENT, _px(btn["selected"], "blo") == C_ACCENT,
			"实际 #%s" % _px(btn["selected"], "blo"))
	_t("selected 平面 = #%s" % C_BASE, _px(btn["selected"], "plane") == C_BASE,
			"实际 #%s" % _px(btn["selected"], "plane"))

	# 物品格三态同源：0 < diff < 全图
	for i in range(SLOT_STATES.size()):
		for j in range(i + 1, SLOT_STATES.size()):
			var a: String = SLOT_STATES[i]
			var b: String = SLOT_STATES[j]
			var d := _diff(_img["ui_slot_item_" + a], _img["ui_slot_item_" + b])
			_t("物品格 %s|%s 差异 0<d<1024" % [a, b], d > 0 and d < 1024, "实际 %d px" % d)

	print("[ui-kit] " + ("全部通过" if _fail == 0 else "失败 %d 项" % _fail))
	quit(1 if _fail > 0 else 0)


# ── 工具 ──

## 采样点：一律取各边中点，避开被圆角切掉的四角
func _px(im: Image, key: String) -> String:
	var w := im.get_width()
	var h := im.get_height()
	var pts := {
		"bhi": [1, h / 2],
		"blo": [w - 2, h / 2],
		"plane": [w / 2, h / 2],
	}
	var p: Array = pts[key]
	return im.get_pixel(p[0], p[1]).to_html(false)


## 可见色集合（排序后返回，便于与写死的期望值逐项比对）
func _colors(im: Image) -> Array:
	var seen := {}
	for y in range(im.get_height()):
		for x in range(im.get_width()):
			var c := im.get_pixel(x, y)
			if c.a > 0.0:
				seen[c.to_html(false)] = true
	var out := seen.keys()
	out.sort()
	return out


## 四角 2 级台阶：(0,0)(1,0)(0,1) 透明，(2,0)(0,2) 实心。四角都查。
func _corners_ok(im: Image) -> bool:
	var w := im.get_width()
	var h := im.get_height()
	var corners := [
		[[0, 0], [1, 0], [0, 1], [2, 0], [0, 2]],
		[[w - 1, 0], [w - 2, 0], [w - 1, 1], [w - 3, 0], [w - 1, 2]],
		[[0, h - 1], [1, h - 1], [0, h - 2], [2, h - 1], [0, h - 3]],
		[[w - 1, h - 1], [w - 2, h - 1], [w - 1, h - 2], [w - 3, h - 1], [w - 1, h - 3]],
	]
	for c in corners:
		for k in range(3):
			if im.get_pixel(c[k][0], c[k][1]).a != 0.0:
				return false
		for k in range(3, 5):
			if im.get_pixel(c[k][0], c[k][1]).a == 0.0:
				return false
	return true


## 九宫可平铺：上/下条每列切片必须相同，左/右条每行切片必须相同。
## 返回 ""=通过，否则返回故障描述。
func _tileable(im: Image, m: int) -> String:
	var w := im.get_width()
	var h := im.get_height()

	var top_cols := {}
	for x in range(m, w - m):
		var s := ""
		for y in range(m):
			s += im.get_pixel(x, y).to_html(true)
		top_cols[s] = true
	if top_cols.size() != 1:
		return "上条 %d 种切片" % top_cols.size()

	var bot_cols := {}
	for x in range(m, w - m):
		var s := ""
		for y in range(h - m, h):
			s += im.get_pixel(x, y).to_html(true)
		bot_cols[s] = true
	if bot_cols.size() != 1:
		return "下条 %d 种切片" % bot_cols.size()

	var l_rows := {}
	for y in range(m, h - m):
		var s := ""
		for x in range(m):
			s += im.get_pixel(x, y).to_html(true)
		l_rows[s] = true
	if l_rows.size() != 1:
		return "左条 %d 种切片" % l_rows.size()

	var r_rows := {}
	for y in range(m, h - m):
		var s := ""
		for x in range(w - m, w):
			s += im.get_pixel(x, y).to_html(true)
		r_rows[s] = true
	if r_rows.size() != 1:
		return "右条 %d 种切片" % r_rows.size()

	return ""


func _diff(a: Image, b: Image) -> int:
	var n := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n


## BT.601 明度（0..255）。物理亮度比较，不用 Color.get_luminance()
## ——后者用 BT.709 系数，与契约里"明度差 >= 60"的算法不同口径。
func _luma(hex: String) -> float:
	var r := hex.substr(0, 2).hex_to_int()
	var g := hex.substr(2, 2).hex_to_int()
	var b := hex.substr(4, 2).hex_to_int()
	return 0.299 * r + 0.587 * g + 0.114 * b
