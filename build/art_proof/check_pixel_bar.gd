extends SceneTree
## check_pixel_bar.gd — 状态条接入参考实现的判据
##
## 验的是「接入方式对不对」，不是「图对不对」（图由 check_ui_bar.gd 管）。
## 核心性质三条：
##   P1 裁切宽度 = 左边框 + 可见像素数，且上界锁死在 112（右边框永不被覆盖）
##   P2 visible_px 单调不减：血量涨了条不能变短
##   P3 贴图 1:1 落在 (0,0)：引擎里 fill 的实际 size 必须等于原生尺寸（没有被拉伸）
##
## P3 是这一轮最容易错的地方：ProgressBar 的 fill StyleBox 会把图**拉伸**到
## 当前值宽度，112px 拉到 41.44px 落在半像素上，像素素材就糊了。必须裁切。

const REF := "res://build/art_proof/pixel_bar_ref.gd"

var _fail := 0

func _t(name: String, ok: bool, detail: String = "") -> void:
	print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + detail if detail != "" else ""))
	if not ok:
		_fail += 1


func _init() -> void:
	print("[pixel-bar] 接入参考实现判据")
	var S := load(REF)
	if S == null:
		print("[pixel-bar] 参考实现加载失败")
		quit(1)
		return

	var BW: int = S.BAR_W
	var BH: int = S.BAR_H
	var VL: int = S.VIS_LEFT
	var VT: int = S.VIS_TOP
	var VW: int = S.VIS_W
	var VH: int = S.VIS_H

	# ① 常量自洽：凹槽必须放得进文件
	_t("几何常量落在文件内", VL + VW <= BW and VT + VH <= BH,
			"右界 %d/%d  下界 %d/%d" % [VL + VW, BW, VT + VH, BH])
	_t("四边留有 2px 边框", VL == 2 and VT == 3 and BW - (VL + VW) == 2,
			"左 %d 上 %d 右 %d" % [VL, VT, BW - (VL + VW)])

	# ② P1/P2：裁切宽度与边界值
	var cases := [
		[0.0, 0, VL, "空槽"],
		[1.0, VW, VL + VW, "满值"],
		[0.5, 54, 56, "半值"],
		[0.001, 1, VL + 1, "极小值至少 1px"],
		[-5.0, 0, VL, "负值被夹到 0"],
		[200.0, VW, VL + VW, "超 100 被夹到满"],
	]
	for c in cases:
		var r: float = c[0]
		var want_vis: int = c[1]
		var want_clip: int = c[2]
		_t("ratio=%.3f → 可见 %dpx / 裁切 %dpx（%s）" % [r, want_vis, want_clip, c[3]],
				S.visible_px(r) == want_vis and S.clip_width(r) == want_clip,
				"实际 可见 %d / 裁切 %d" % [S.visible_px(r), S.clip_width(r)])

	_t("裁切宽度上界 = BAR_W（右边框永不被覆盖）",
			S.clip_width(1.0) <= BW and S.clip_width(9.9) <= BW,
			"满值裁切 %d / 文件宽 %d" % [S.clip_width(1.0), BW])

	# ③ P2 单调性：100 个采样点全区间不得回退
	var prev := -1
	var broke := ""
	for i in range(101):
		var v: int = S.visible_px(float(i) / 100.0)
		if v < prev:
			broke = "ratio=%.2f 处从 %d 掉到 %d" % [float(i) / 100.0, prev, v]
			break
		prev = v
	_t("0→1 全区间单调不减（101 采样）", broke == "", broke)

	# ④ P3：实例化后贴图必须 1:1 落在 (0,0)，且裁切容器宽度随值变化
	var bar = S.new()
	root.add_child(bar)
	bar.set_value(37.0)                       # 37% → round(0.37*108)=40px 可见 → 裁切 42
	var clip: Control = bar._fill_clip
	var tex: TextureRect = bar._fill_tex
	var native: Vector2i = tex.texture.get_size()

	_t("fill 贴图原生尺寸 = %dx%d（导入未改尺寸）" % [BW, BH],
			native == Vector2i(BW, BH), "实际 %s" % str(native))
	_t("fill 节点尺寸 = 原生尺寸（未被缩放）",
			tex.size == Vector2(BW, BH), "实际 %s" % str(tex.size))
	_t("fill 拉伸模式 = STRETCH_KEEP（原尺寸绘制）",
			tex.stretch_mode == TextureRect.STRETCH_KEEP,
			"实际 %d" % tex.stretch_mode)
	_t("fill 落点 = (0,0)（不需要记偏移量）",
			tex.position == Vector2.ZERO, "实际 %s" % str(tex.position))
	_t("clip_contents 已开启（裁切而非缩放）", clip.clip_contents, "")
	_t("37% 时裁切宽 = 42px", int(clip.size.x) == 42, "实际 %d" % int(clip.size.x))

	# ⑤ 一组取值逐一核对裁切宽度（像素条只能整像素，不能有半像素）
	var mismatch: Array = []
	for pair in [[0.0, 0], [1.0, 100], [50.0, 54], [99.0, 100], [0.5, 1]]:
		bar.set_value(float(pair[1]))
		var want: int = S.clip_width(float(pair[1]) / 100.0)
		if int(clip.size.x) != want:
			mismatch.append("v=%d 期望 %d 实际 %d" % [pair[1], want, int(clip.size.x)])
	_t("各取值下裁切宽度逐一对齐", mismatch.is_empty(), str(mismatch))

	bar.queue_free()
	print("[pixel-bar] " + ("全部通过" if _fail == 0 else "失败 %d 项" % _fail))
	quit(1 if _fail > 0 else 0)
