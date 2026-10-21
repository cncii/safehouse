extends SceneTree
# check_font.gd — 中文字体在 Godot 里能否真正出字形（不只是 cmap 里有码位）
#
# 为什么需要它：tools/check_font_coverage.py 解析的是字体文件的 cmap 表，
# 证明「这个码位有映射」。但真实渲染还要过 TextServer + FreeType。
# 二者不一致的典型情形：cmap 有映射但字形是空的、或字体被 Godot 判为无效。
#
# 跑法：
#   Godot_v4.3-stable_win64_console.exe --headless --path <工程根> -s res://build/art_proof/check_font.gd

const FONT_HANS := "res://assets/fonts/font_fusion_pixel_12px_zh_hans.ttf"
const FONT_HANT := "res://assets/fonts/font_fusion_pixel_12px_zh_tw.ttf"

# strings.csv 里 Ark Pixel 缺的那 5 个字（简/繁），是本次换字体的直接起因。
const PROBE := "药避击据脏擊據髒"

func _init() -> void:
	var failed := false
	for path in [FONT_HANS, FONT_HANT]:
		var f := load(path) as FontFile
		if f == null:
			printerr("[font-check] 加载失败: ", path)
			failed = true
			continue
		print("[font-check] ", path.get_file())
		# ⚠ 不要用 get_glyph_count()：它会遍历全部字形，在 headless 下对 3.7 万码位的
		#   中文字体实测卡死（45s 未返回）。get_supported_chars() 走 cmap，瞬时返回。
		print("   类型=%s  覆盖码位=%d" % [f.get_class(), f.get_supported_chars().length()])

		# ① 逐字 has_char —— 直接问 TextServer 这个码位有没有字形
		var missing := ""
		for i in PROBE.length():
			var cp := PROBE.unicode_at(i)
			if not f.has_char(cp):
				missing += PROBE[i]
		if missing == "":
			print("   关键缺字探针 8/8 全部有字形  PASS")
		else:
			printerr("   缺字形: ", missing, "  FAIL")
			failed = true

		# ② 真实排版 —— 12px 下量一行中文的宽高，宽为 0 说明根本没排出来
		var line := "避难所药店攻击据点"
		var sz := f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		var char_w := f.get_char_size("避".unicode_at(0), 12)
		print("   12px 度量: %s -> %.1f x %.1f ; 单字 %.1f x %.1f"
			% [line, sz.x, sz.y, char_w.x, char_w.y])
		if sz.x <= 0.0 or char_w.x <= 0.0:
			printerr("   排版尺寸为 0，字体未被 TextServer 接受  FAIL")
			failed = true
		# 12px 等宽字体：每字宽应正好 12
		elif absf(char_w.x - 12.0) > 0.01:
			print("   ⚠ 单字宽 %.1f 与 12px 等宽预期不符（非致命，仅提示）" % char_w.x)
		else:
			print("   等宽 12px 栅格对齐  PASS")

	print("[font-check] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
