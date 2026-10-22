extends Control
## pixel_bar_ref.gd — 像素状态条参考实现（美术组提供，包 D 可直接移植到 src/ui/hud/）
##
## ── 为什么不能用 ProgressBar 的 fill StyleBox ──
## ProgressBar 把 "fill" 当成 StyleBox 画在剩余宽度上，用 StyleBoxTexture 时
## **整张图会被拉伸到当前值对应的宽度**。112px 的填充块拉到 37% = 41.44px，
## 落在半像素上 → 像素被重采样、边缘糊、左右 2px 透明留白宽度也跟着漂。
## 像素素材的正确做法是**裁切**：图原样 1:1 画，只把右半边盖住。
##
## ── 对齐原理（为什么两张图都画在 (0,0) 就行）──
## 所有内部偏移都编码为 PNG 里的透明边距，所以接入方不需要记任何偏移量：
##     frame 可见带  x 0..111, y 1..14
##     凹槽          x 2..109, y 3..12   ← 108×10
##     fill  可见带  x 2..109, y 3..12   ← 与凹槽逐像素重合
## 两张图同原点叠画，凹槽自然对上。上一版曾要求"fill 放在 (2,2)"，
## 靠人记偏移量迟早写错，现改为同一原点。
##
## ── 移植时──
## 1. 本文件放进 src/ui/hud/，加 `class_name PixelBar`（build/ 下的脚本故意不带
##    class_name，避免给工程加一个只在验证期存在的全局类）
## 2. `set_value(v: float)` 接 0–100，与 VitalBar 现有入参同标度（P20 判据要求
##    "条长与数值文本同源同一入参，不二次换算"——本类只做一次 /100）
## 3. 染色：fill 是纯白，用 `modulate` 直接乘语义色（白×色=色，色值精确）

# ── 几何：唯一来源是本文件，必须与 build/art_proof/gen_ui_bar.py 一致 ──
const BAR_W := 112          # 文件宽 = 控件宽（1:1，不缩放）
const BAR_H := 16           # 文件高 = 控件高
const VIS_LEFT := 2         # 凹槽左边界（2px 边框）
const VIS_TOP := 3          # 凹槽上边界（1px 透明 + 2px 边框）
const VIS_W := 108          # 凹槽宽 = 可填充像素数
const VIS_H := 10           # 凹槽高

const TEX_FRAME := "res://assets/sprites/ui/ui_bar_frame.png"
const TEX_FILL := "res://assets/sprites/ui/ui_bar_fill.png"

var _fill_clip: Control
var _fill_tex: TextureRect
var _ratio := 0.0

# ── 纯函数：可被判据直接调用，不依赖节点树 ──
## 当前比例对应的「可见像素数」。0 就是 0（空槽），非 0 至少给 1px，
## 否则玩家看到"血条还有 0.4% 但一个像素都没有"，会以为已经空了。
static func visible_px(ratio: float) -> int:
	var r := clampf(ratio, 0.0, 1.0)
	if r <= 0.0:
		return 0
	return maxi(1, int(round(r * float(VIS_W))))

## 裁切容器宽度 = 左边框 + 可见像素数。上限 BAR_W。
static func clip_width(ratio: float) -> int:
	return mini(BAR_W, VIS_LEFT + visible_px(ratio))


func _init() -> void:
	custom_minimum_size = Vector2(BAR_W, BAR_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 底层：底板（含边框与凹槽）
	var frame := _make_tex(TEX_FRAME)
	add_child(frame)

	# 上层：填充块，用 clip_contents 裁切而不是缩放
	_fill_clip = Control.new()
	_fill_clip.clip_contents = true
	_fill_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill_clip.position = Vector2.ZERO
	add_child(_fill_clip)

	_fill_tex = _make_tex(TEX_FILL)
	_fill_clip.add_child(_fill_tex)

	_apply()


## v: 0–100（与 state_contract.json 的 min/max 同标度）
func set_value(v: float) -> void:
	_ratio = clampf(v, 0.0, 100.0) / 100.0
	_apply()


## 语义色（与 HudStyle 色阶同源，白底相乘得到精确色值）
func set_tint(c: Color) -> void:
	_fill_tex.modulate = c


func get_ratio() -> float:
	return _ratio


func _apply() -> void:
	if _fill_clip == null:
		return
	_fill_clip.size = Vector2(float(clip_width(_ratio)), float(BAR_H))


func _make_tex(path: String) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.stretch_mode = TextureRect.STRETCH_KEEP      # 原尺寸，绝不缩放
	tr.position = Vector2.ZERO
	tr.size = Vector2(BAR_W, BAR_H)                 # = 贴图原生尺寸 → 1:1
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr
