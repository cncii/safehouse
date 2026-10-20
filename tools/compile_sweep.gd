extends SceneTree
## compile_sweep.gd — 确定性编译普查（验收判据，**替代不可靠的 --import**）
##
## 用法：
##   godot --headless --path . -s tools/compile_sweep.gd
## 退出码：0 = 全部编译通过；1 = 有脚本编译失败；2 = 自检失败（扫描器本身不可信）
##
## ── 为什么不能用 --import 当验收判据（2026-10-20 实测，勿回滚）──
## · 热导入（.godot 存在）：按 mtime 增量扫描。mtime 没变的脚本，它的红会被静默
##   吞掉 → 修完一个文件后其余坏脚本"全部消失" → 假绿。
## · 冷导入（rm -rf .godot）：有竞态。同一份代码连跑 4 轮，ERROR 行数得
##   26 / 28 / 26 / **0**，第 4 轮在一个明确有 3 个编译失败脚本的仓库上报 0 条、
##   exit 0 → 假绿。推测扫描并发、进程在扫描跑完前就退出。
## · load() 是**同步**调用，编译失败当场出结果，不受 mtime 与竞态影响。
##   本工具只用它，这是它相对 --import 的唯一优势——**不要改回 --import**。
##
## ── 判定信号：编译失败的脚本 `get_instance_base_type()` 为空串 ──
## 实测（2026-10-20）：失败脚本 base=''，成功脚本 base='Node'/'HBoxContainer'/'SceneTree'。
##
## ⚠ 不要用 `GDScript.reload()` 做判定（已踩坑，勿回滚）：
## reload() 是**破坏性**的——它把已实例化为 autoload 的脚本重新编译，返回
## ERR_ALREADY_IN_USE(22)，于是 src/core/** 八个 autoload 全被误报成坏文件；
## 被它弄坏的 Localize 还会让依赖它的 UI 脚本跟着报 ERR_COMPILATION_FAILED(36)。
## 后果：真失败 3 个被淹没在 12–16 条假红里，且连跑 3 遍结果不一致。
## 本工具只读 `get_instance_base_type()`，绝不 reload() 已加载的脚本。
##
## ── 自检样例为什么用内存造 ──
## GDScript.new() + source_code + reload() 编译的是一次性对象，不落盘、不进
## ResourceCache、不碰 autoload。因此**在 src/ 下留一个真坏脚本当夹具是被禁止的**
## ——那会让仓库永远带着一个红文件，还会污染 check_i18n / check_deps。
##
## ── 已知边界（本工具覆盖不到，别指望它，已在输出里明说）──
## `-s <script>` 模式下，被 -s 直接指定的**主脚本**编译早于 autoload 注册，
## 引用 Localize/Rng/GameLoop 会报 Identifier not found；本工具用 load() 加载
## 它们，处在 autoload 已注册的上下文，扫不出这一类。典型：tools/ui_smoke.gd。

const SCAN_DIRS := ["res://src", "res://scenes", "res://tools", "res://tests"]

# 自检样例：阳性必须编译失败，阴性必须编译成功（在内存里编译，不落盘）
const SELF_CHECK_POSITIVE := [
	"extends Node\nfunc _ready():\n\tvar a := 1 +\n",           # 表达式残缺
	"extends Node\nvar x: int = \"str\"\n",                      # 类型不匹配
]
const SELF_CHECK_NEGATIVE := [
	"extends Node\nfunc _ready():\n\tvar a: int = 1\n",
	"extends Node\nvar x: int = 1\n",
]

var _files: Array = []
var _broken: Array = []

func _initialize() -> void:
	var ok := false
	var report := ""
	ok = _self_check()
	if not ok:
		print("[compile_sweep] 自检失败——扫描器本身不可信，拒绝输出结论")
		quit(2)
		return
	print("[compile_sweep] 扫描器自检：%s" % report_of_selfcheck)

	_collect()
	_files.sort()          # 排序：保证输出逐字可复现
	print("[compile_sweep] 待编译 %d 个 .gd（目录：%s）" % [_files.size(), ", ".join(SCAN_DIRS)])

	# 第一遍：把 class_name 全局类注册进 ScriptServer，不判错。
	# 不排序依赖做不到，只能靠这一遍把"被引用方"先编译出来。
	for p in _files:
		load(p)

	# 第二遍：只读判定，绝不 reload()
	for p in _files:
		var s = load(p)
		if not (s is GDScript):
			_broken.append("%s  (不是 GDScript)" % p)
			continue
		if (s as GDScript).get_instance_base_type() == "":
			_broken.append(p)

	if _broken.is_empty():
		print("[compile_sweep] 全部编译通过")
		print("[compile_sweep] 注意：-s 主脚本的 autoload 标识符问题不在本工具覆盖范围内")
		quit(0)
		return

	print("[compile_sweep] 编译失败 %d 个（引擎原样报错见上方，含文件:行号）：" % _broken.size())
	for b in _broken:
		print("  BROKEN  %s" % b)
	print("[compile_sweep] 注意：-s 主脚本的 autoload 标识符问题不在本工具覆盖范围内")
	quit(1)

## 自检：阳性必须全部编译失败、阴性必须全部编译成功。
## 用一次性 GDScript 对象，不落盘、不进缓存、不碰 autoload。
var report_of_selfcheck := ""

func _self_check() -> bool:
	var hits := 0
	for src in SELF_CHECK_POSITIVE:
		if _compile_mem(src) != OK:
			hits += 1
	var misses := 0
	for src in SELF_CHECK_NEGATIVE:
		if _compile_mem(src) == OK:
			misses += 1
	var n := SELF_CHECK_POSITIVE.size() + SELF_CHECK_NEGATIVE.size()
	report_of_selfcheck = "自验 %d/%d（阳 %d/%d，阴 %d/%d）" % [
		hits + misses, n, hits, SELF_CHECK_POSITIVE.size(), misses, SELF_CHECK_NEGATIVE.size()
	]
	return hits == SELF_CHECK_POSITIVE.size() and misses == SELF_CHECK_NEGATIVE.size()

func _compile_mem(source: String) -> int:
	var g := GDScript.new()
	g.source_code = source
	return g.reload()

func _collect() -> void:
	for d in SCAN_DIRS:
		_walk(d)

func _walk(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.begins_with("."):
			f = d.get_next()
			continue
		var full := dir + "/" + f
		if d.current_is_dir():
			_walk(full)
		elif f.ends_with(".gd"):
			_files.append(full)
		f = d.get_next()
	d.list_dir_end()
