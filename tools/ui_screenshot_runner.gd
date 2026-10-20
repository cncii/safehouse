extends Control
## ui_screenshot_runner.gd — S5 27 组合分辨率截图自查（包 D 表现组 · W4）
##
## ── 场景根必须是 Control（勿回退成 Node）──
## 被测 UI（HUD/设置页）的 anchors 需要一个真实 Control 父级：挂在普通 Node 下时，
## content_scale_mode 切换（DPI 组合）后父锚定基准会失效（SettingsScreen 曾量得 size 0×0，
## 12 处假越界）。根 Control FULL_RECT = 稳定的锚定链。
##
## ── 运行方式（必须真实渲染，禁 headless）──
##   Godot_console.exe --path <工程> res://tools/ui_screenshot_runner.tscn
## headless 下直接退出（exit 2）：无渲染就没有截图，跑了等于没跑。
##
## ── 组合口径（默认值是【假设】，具体清单未定稿，见 data/UNDEFINED.md D-015）──
##   3 分辨率 {1280x720, 1920x1080, 2560x1440} × 3 窗口模式 {windowed, borderless, exclusive}
##   × 3 DPI {100, 125, 150}。DPI 用 content_scale_factor 模拟：
##   100% 保持工程默认（viewport + integer stretch）；125/150% 切 CANVAS_ITEMS + 对应倍率，
##   用于抓"系统 DPI 放大后文本变宽 → 溢出面板/越界"这一真实风险。
##
## ── 越界判定 ── 被测 UI 的每个 Control 的 global rect 必须完整落在视口内（容差 0.5px）。
##   能抓：写死屏幕坐标的节点、DPI 放大后溢出的面板/文本。
##
## ── 产物 ── build/s5/<组合>.png × 27 + build/s5_report.md（红绿以越界数为准）。

const OUT_DIR := "res://build/s5"
const REPORT := "res://build/s5_report.md"

# 假设值，待老板确认（D-015）；可用命令行覆盖：-- res=1280x720,1920x1080 -- modes=windowed,fullscreen
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440)]
const MODES := [
	{"id": "windowed", "mode": Window.MODE_WINDOWED},
	{"id": "borderless", "mode": Window.MODE_FULLSCREEN},
	{"id": "exclusive", "mode": Window.MODE_EXCLUSIVE_FULLSCREEN},
]
const DPIS := [100, 125, 150]
const RECT_TOLERANCE := 0.5

var _violations_total := 0
var _report_lines: PackedStringArray = []
var _hud: Node
var _settings: Node

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("S5 runner needs a real renderer; do NOT run with --headless")
		get_tree().quit(2)
		return
	_hud = (load("res://scenes/ui/hud_graybox.tscn") as PackedScene).instantiate()
	add_child(_hud)
	_settings = SettingsScreen.new()
	add_child(_settings)
	_run()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_report_lines.append("# S5 27 组合截图自查报告（%s）" % Time.get_datetime_string_from_system())
	_report_lines.append("")
	_report_lines.append("| # | 分辨率(设定) | 窗口实际 | 模式 | DPI | 越界数 |")
	_report_lines.append("|---|---|---|---|---|---|")

	var win := get_window()
	var idx := 0
	for res: Vector2i in RESOLUTIONS:
		for m: Dictionary in MODES:
			for dpi: int in DPIS:
				idx += 1
				win.mode = m["mode"]
				win.size = res
				if dpi == 100:
					# 工程默认口径：内部分辨率 640×360 + viewport + integer stretch
					win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
					win.content_scale_factor = 1.0
				else:
					# DPI 放大口径：UI 元素随系统缩放（文本变宽是真实越界来源）
					win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
					win.content_scale_factor = float(dpi) / 100.0
				await get_tree().process_frame
				# 防锚定失效：content_scale 切换后 Control 的 anchors 重算不可靠
				# （实测 scene-root Control 曾被置 0×0）——显式钉到逻辑视口尺寸。
				# S5 测量语义 = UI 在 640×360 逻辑视口内布局是否正确，与工程纪律一致。
				var vis: Vector2 = get_viewport().get_visible_rect().size
				for c: Control in [self, _hud, _settings]:
					c.size = vis
				await _settle_frames(6)
				var actual := win.size
				var view := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
				var bad := _scan_overflows(view)
				var shot := "%s/s5_%02d_%dx%d_%s_dpi%d.png" % [OUT_DIR, idx, res.x, res.y, m["id"], dpi]
				var img := get_viewport().get_texture().get_image()
				img.save_png(ProjectSettings.globalize_path(shot))
				_violations_total += bad.size()
				_report_lines.append("| %d | %dx%d | %dx%d | %s | %d | %d |" % [
					idx, res.x, res.y, actual.x, actual.y, m["id"], dpi, bad.size()])
				print("S5 [%02d/27] %dx%d %s dpi%d -> %d violation(s)" % [
					idx, res.x, res.y, m["id"], dpi, bad.size()])
				for v: String in bad:
					_report_lines.append("  - 越界: " + v)
					print("    overflow: " + v)

	# 恢复工程默认窗口状态，不留测试残留
	win.mode = Window.MODE_WINDOWED
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_factor = 1.0
	win.size = Vector2i(1280, 720)

	var header := "S5 RESULT: %s (%d violation(s) across 27 combos)\n" % [
		"PASS" if _violations_total == 0 else "FAIL", _violations_total]
	var path := ProjectSettings.globalize_path(REPORT)
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	f.store_string(header + "\n" + "\n".join(_report_lines) + "\n")
	f.close()
	print(header.strip_edges())
	print("report: %s" % path)
	get_tree().quit(0 if _violations_total == 0 else 1)

func _settle_frames(n: int) -> void:
	for i: int in n:
		await RenderingServer.frame_post_draw

## 遍历被测 UI 的所有 Control：global rect 必须完整落在视口 content 尺寸内
func _scan_overflows(view: Rect2) -> PackedStringArray:
	var out := PackedStringArray()
	_walk(_hud, view, out)
	_walk(_settings, view, out)
	return out

func _walk(n: Node, view: Rect2, out: PackedStringArray) -> void:
	_walk_clipped(n, view, out, false)

## clipped=true：当前节点处于滚动/裁剪容器（clip_contents）子树内——内容滚动可达，
## 不算视口越界（豁免子树；容器自身的 rect 仍检查）。S6 设置页改滚动布局后必需。
func _walk_clipped(n: Node, view: Rect2, out: PackedStringArray, clipped: bool) -> void:
	for c: Node in n.get_children():
		if c is Control:
			var ctrl := c as Control
			if not clipped:
				var r: Rect2 = ctrl.get_global_rect()
				var inside := r.position.x >= -RECT_TOLERANCE \
					and r.position.y >= -RECT_TOLERANCE \
					and r.end.x <= view.size.x + RECT_TOLERANCE \
					and r.end.y <= view.size.y + RECT_TOLERANCE
				if not inside:
					out.append("%s rect=%s viewport=%s chain=%s" % [
						_path_of(c), r, view.size, _chain_rects(c)])
			_walk_clipped(c, view, out, clipped or ctrl.clip_contents)

func _chain_rects(n: Node) -> String:
	var parts: PackedStringArray = []
	var cur: Node = n
	while cur is Control and cur != _hud and cur != _settings:
		parts.insert(0, "%s=%s" % [cur.name, (cur as Control).get_global_rect()])
		cur = cur.get_parent()
	if cur is Control:
		parts.insert(0, "root=%s" % [(cur as Control).get_global_rect()])
	return " > ".join(parts)

func _path_of(n: Node) -> String:
	var owner_root: Node = _settings if _settings.is_ancestor_of(n) else _hud
	var rel := String(n.get_path()).replace(String(owner_root.get_path()) + "/", "")
	return ("settings/" if owner_root == _settings else "hud/") + rel
