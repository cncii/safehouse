extends SceneTree
## check_ui_bar.gd — 状态条素材的引擎侧验证
##
## 为什么 Python 侧验过还要再验一次：
##   Python 读的是磁盘上的 PNG；游戏读的是 Godot 导入后的 CompressedTexture2D。
##   这中间隔着一层导入管线（sRGB、压缩、alpha 处理），**它改了什么 Python 看不见**。
##   本脚本断言的是"引擎实际拿到的东西"，而不是"我写进文件的东西"。
##
## 断言分三层：
##   ① 单文件：尺寸 / 可见包围盒 / 色数
##   ② 跨文件：frame 的凹槽必须与 fill 的可见带**逐像素重合**（只比尺寸不够——
##      两张图各自尺寸对、位置差 2px，接上去照样错位）
##   ③ 几何自洽：凹槽区域内的像素必须全是凹槽底色，不能混进边框色

# ── 唯一来源：与 build/art_proof/gen_ui_bar.py 的几何常量逐一对齐 ──
const BAR_W := 112
const BAR_H := 16
const VIS_TOP := 1          # 可见带 y 起点（上下各 1px 透明补到 16）
const VIS_H := 14
const GROOVE := Rect2i(2, 3, 108, 10)   # 凹槽 = fill 可见带，两者必须相等

const TRACK_HEX := "323c39"             # 凹槽底色 #323c39
const FRAME_COLORS := 3                 # #222034 #323c39 #847e87
const FILL_COLORS := 1                  # #ffffff

var _fail := 0

func _t(name: String, ok: bool, detail: String = "") -> void:
	print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + detail if detail != "" else ""))
	if not ok:
		_fail += 1


func _init() -> void:
	print("[ui-bar] 引擎侧验证")
	var frame_img := _img("res://assets/sprites/ui/ui_bar_frame.png", "frame")
	var fill_img := _img("res://assets/sprites/ui/ui_bar_fill.png", "fill")
	if frame_img == null or fill_img == null:
		print("[ui-bar] 贴图加载失败，中止")
		quit(1)
		return

	# ① 单文件
	_t("frame 尺寸 = %dx%d" % [BAR_W, BAR_H], frame_img.get_size() == Vector2i(BAR_W, BAR_H),
			"实际 %s" % str(frame_img.get_size()))
	_t("frame 可见带 = %s" % str(Rect2i(0, VIS_TOP, BAR_W, VIS_H)),
			frame_img.get_used_rect() == Rect2i(0, VIS_TOP, BAR_W, VIS_H),
			"实际 %s" % str(frame_img.get_used_rect()))
	_t("frame 可见色数 = %d" % FRAME_COLORS, _colors(frame_img).size() == FRAME_COLORS,
			"实际 %s" % str(_colors(frame_img)))
	_t("fill 尺寸 = %dx%d" % [BAR_W, BAR_H], fill_img.get_size() == Vector2i(BAR_W, BAR_H),
			"实际 %s" % str(fill_img.get_size()))
	_t("fill 可见色数 = %d" % FILL_COLORS, _colors(fill_img).size() == FILL_COLORS,
			"实际 %s" % str(_colors(fill_img)))

	# ② 跨文件：fill 的可见带必须正好落在 frame 的凹槽上
	_t("fill 可见带 = 凹槽 %s" % str(GROOVE), fill_img.get_used_rect() == GROOVE,
			"实际 %s" % str(fill_img.get_used_rect()))

	# ③ 凹槽区域内必须全是凹槽底色（混进边框色说明边框压到了槽里）
	var bad := 0
	for y in range(GROOVE.position.y, GROOVE.end.y):
		for x in range(GROOVE.position.x, GROOVE.end.x):
			if frame_img.get_pixel(x, y).to_html(false) != TRACK_HEX:
				bad += 1
	_t("凹槽 %d 像素全为 #%s" % [GROOVE.get_area(), TRACK_HEX], bad == 0, "异常 %d 像素" % bad)

	# ④ 几何自洽：凹槽必须落在可见带内且留出 2px 边框
	_t("凹槽在可见带内且四边留边",
			GROOVE.position.x >= 2 and GROOVE.position.y >= VIS_TOP + 2
			and GROOVE.end.x <= BAR_W - 2 and GROOVE.end.y <= VIS_TOP + VIS_H - 2,
			"凹槽 %s / 可见带 %s" % [str(GROOVE), str(Rect2i(0, VIS_TOP, BAR_W, VIS_H))])

	print("[ui-bar] " + ("全部通过" if _fail == 0 else "失败 %d 项" % _fail))
	quit(1 if _fail > 0 else 0)


func _img(path: String, label: String) -> Image:
	var tex := load(path) as Texture2D
	_t(label + " 可加载（导入已生成）", tex != null, path.get_file())
	return tex.get_image() if tex != null else null


func _colors(img: Image) -> Array:
	var seen := {}
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			if c.a > 0.0:
				seen[Color(c.r, c.g, c.b).to_html(false)] = true
	return seen.keys()
