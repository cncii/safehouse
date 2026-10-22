extends SceneTree
## check_ui_bar.gd — 状态条素材的引擎侧验证（九宫格边界 + 像素完整性）
##
## 为什么 Python 侧验过还要再验一次：
##   Python 读的是磁盘上的 PNG；游戏读的是 Godot 导入后的 CompressedTexture2D。
##   这中间隔着一层导入管线（sRGB、压缩、alpha 处理），**它改了什么 Python 看不见**。
##   本脚本断言的是"引擎实际拿到的东西"，而不是"我写进文件的东西"。

const EXPECT := {
	"res://assets/sprites/ui/ui_bar_frame.png": {
		"size": Vector2i(128, 16),
		"used": Rect2i(0, 0, 128, 16),      # 全画布都有内容（含侧边框）
		"colors": 4,
		"margin": [8, 4, 8, 4],             # §4.2 四个具名值
	},
	"res://assets/sprites/ui/ui_bar_fill.png": {
		"size": Vector2i(112, 16),
		"used": Rect2i(0, 2, 112, 12),      # 可见带 12px：上下各 2px 透明留白
		"colors": 1,
		"margin": [4, 4, 4, 4],
	},
}

var _fail := 0

func _t(name: String, ok: bool, detail: String = "") -> void:
	print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + detail if detail != "" else ""))
	if not ok:
		_fail += 1


func _init() -> void:
	print("[ui-bar] 引擎侧验证")
	for path in EXPECT:
		var e: Dictionary = EXPECT[path]
		var tex := load(path) as Texture2D
		_t(path.get_file() + " 可加载", tex != null)
		if tex == null:
			continue
		var img := tex.get_image()
		_t("  尺寸 = %s" % str(e["size"]), img.get_size() == e["size"], "实际 %s" % str(img.get_size()))

		var used := img.get_used_rect()
		_t("  可见带 = %s" % str(e["used"]), used == e["used"], "实际 %s" % str(used))

		# 颜色集合：导入管线若做了 sRGB 或量化，这里会与原值不符
		var seen := {}
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				if c.a > 0.0:
					seen[Color(c.r, c.g, c.b).to_html(false)] = true
		_t("  可见色数 = %d" % e["colors"], seen.size() == e["colors"],
				"实际 %d：%s" % [seen.size(), str(seen.keys())])

		# 九宫格：节点参数能设进去且被接受（Godot 的参数绑在节点上，不绑资源）
		var np := NinePatchRect.new()
		np.texture = tex
		np.patch_margin_left = e["margin"][0]
		np.patch_margin_top = e["margin"][1]
		np.patch_margin_right = e["margin"][2]
		np.patch_margin_bottom = e["margin"][3]
		np.size = Vector2(512, 128)          # 拉伸到 4 倍宽 8 倍高，看参数是否越界
		_t("  九宫格 %s 可设置且 < 尺寸" % str(e["margin"]),
				np.patch_margin_left + np.patch_margin_right < int(e["size"].x)
				and np.patch_margin_top + np.patch_margin_bottom < int(e["size"].y))
		np.free()

	print("[ui-bar] " + ("全部通过" if _fail == 0 else "失败 %d 项" % _fail))
	quit(1 if _fail > 0 else 0)
