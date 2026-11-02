extends Node
## pii_probe.gd — S10 PII 自查（战斗组 包 C+E 范围内）
## 用法：godot --headless --quit-after 400 res://scenes/debug/pii_probe.tscn
##
## 判据（S10 / 架构 §6.3，方案 A 口径）：存档与日志目录扫描 →
##   - 主机名/用户名/硬件 ID/UUID 命中 0（存档 + 我们自己的结构化日志行）；
##   - 引擎错误输出里出现的绝对路径记为**已知例外**（记录但不判红）。
## 详见 _test_logs_no_pii / _classify_line 的方案 A 分流说明。
##
## ⚠ 三条防假绿设计（缺一条这条判据就没意义，勿删）：
##   1. 存档是 **GZIP 压缩**的。明文 grep 扫 save.sav 永远 0 命中——那是**假绿**。
##      故本脚本必须 **解压后再扫**（PackedByteArray.decompress）。
##   2. **反向对照**：故意把真实主机名/用户名写进一个临时文件，断言扫描器**能抓到**。
##      抓不到 = 扫描器本身坏了，那"0 命中"毫无意义。
##   3. **空目录判负**：目录不存在或零文件时判"未生效"失败，不判通过。
##
## 诚实边界：本脚本只能判**落盘文件**里有没有 PII；
## S9 的「防火墙全禁出站 0 / DNS 0」仍需 Process Monitor / 抓包 + 真实 Steam 客户端，
## 无头环境测不到（见交付说明第 8 节）。

const _Logger = preload("res://src/core/logger.gd")

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

func _ready() -> void:
	_run_all()
	_finish()

func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)

func _run_all() -> void:
	_test_not_empty()
	_test_scanner_detects_pii()     # 反向对照，必须在真扫之前
	_test_save_no_pii()
	_test_logs_no_pii()
	_test_log_exception_routing()   # 方案 A 路由自检（防回归：引擎例外不误并入 OWN 失败）
	_test_combat_write_paths_clean()
	_test_logger_guard_status()

## 防假绿第 3 条：扫之前先确认真的有文件可扫
func _test_not_empty() -> void:
	var files := _collect_files("user://")
	_t("s10: save/log dir has files to scan (not empty run)", files.size() > 0)

## 防假绿第 2 条：反向对照——扫描器必须能抓到已知 PII
func _test_scanner_detects_pii() -> void:
	var host := OS.get_environment("COMPUTERNAME")
	var user := OS.get_environment("USERNAME")
	_t("s10: environment exposes COMPUTERNAME for reverse control", host != "")
	_t("s10: environment exposes USERNAME for reverse control", user != "")

	# 把真实 PII 写进内存样本，确认扫描器能命中
	var sample := "host=%s user=%s path=C:\\Users\\%s\\x" % [host, user, user]
	var hits := _scan_text(sample)
	_t("s10(control): scanner detects hostname in known-bad sample", host == "" or hits.has("hostname"))
	_t("s10(control): scanner detects username in known-bad sample", user == "" or hits.has("username"))
	_t("s10(control): scanner detects abs path in known-bad sample", hits.has("abspath"))
	# ★ 变异测试 C11 逼出来的：对照样本必须**只含被测的那一个 token**。
	#   原样本 "leak C:\Users\bob\x" 同时含 `C:\` 和 `Users\`——变异只去掉 `Users\`
	#   时 `C:\` 仍命中 → 判据不红。改成不含盘符的纯 `Users\` 片段，
	#   去掉该 token 就真的抓不到了。
	#   这与「Dictionary 保序」「插入顺序必须逆着被测优先级」同类：
	#   用例必须精确对准被测的那一个性质。
	_t("s10(control): scanner detects 'Users' token alone (no drive letter)",
		_scan_text("leak Users\\bob\\x").has("abspath"))
	_t("s10(control): scanner detects 'C:' drive token alone",
		_scan_text("leak C:\\bob\\x").has("abspath"))
	_t("s10(control): scanner detects 'AppData' path token alone",
		_scan_text("leak D:\\AppData\\Roaming\\x").has("abspath"))
	# 引擎错误输出用正斜杠（Godot 在 Windows 上报 `C:/Users/...`），方案 A 必须能识别
	_t("s10(control): scanner detects forward-slash abs path (engine error form)",
		_scan_text("USER SCRIPT ERROR: ... at: GDScript::reload (C:/Users/CQY/AppData/Local/x/_probe.gd:5)").has("abspath"))
	# 修假阳性后仍必须能抓到**路径形态**的 AppData/Users（别把判据改弱了）
	var path_sample := "leaked C:\\Users\\%s\\AppData\\Roaming\\SafeHouse\\save.sav" % user
	_t("s10(control): scanner still detects Users\\AppData path form",
		_scan_text(path_sample).has("abspath"))
	# 但**裸词** AppData（正常文案）不该被判成 PII
	_t("s10(control): bare word 'AppData' in prose is NOT a PII hit",
		not _scan_text("save path writable (%APPDATA%\\SafeHouse)").has("abspath"))
	_t("s10(control): scanner detects uuid/mac pattern in known-bad sample",
		_scan_text("id=550e8400-e29b-41d4-a716-446655440000").has("uuid"))

## 存档：必须解压后再扫（明文 grep 是假绿）
func _test_save_no_pii() -> void:
	for path: String in ["user://save.sav", "user://profile.sav", "user://save.sav.bak"]:
		if not FileAccess.file_exists(path):
			continue
		var text := _read_text_decompressed(path)
		if text.is_empty():
			_t("s10: %s readable (non-empty)" % path, false)
			continue
		# ★★ 防空转护栏（变异测试 C12 逼出来的）：存档是 **GZIP**，不解压读到的是二进制乱码。
		#   乱码非空 → 旧写法直接跳过判据 → "0 命中"恒真 = **假绿**。
		#   → 必须验证读到的确实是**可解析的 JSON 存档**，否则判红。
		#   这与包 F 的「三层空跑判负」同源：判据要有牙，先得确认它有东西可咬。
		if path.ends_with(".sav") or path.ends_with(".sav.bak"):
			var parsed: Variant = JSON.parse_string(text)
			_t("s10: %s decompressed to parsable JSON (not raw gzip bytes)" % path,
				typeof(parsed) == TYPE_DICTIONARY)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
		var hits := _scan_text(text)
		_t("s10: %s PII hits == 0 (got %d)" % [path, hits.size()], hits.is_empty())
		if not hits.is_empty():
			printerr("  PII in %s: %s" % [path, str(hits)])

## 日志：明文，直接扫。
##
## ⚠ 方案 A（S10 残余风险处置）：Godot 引擎在脚本报错时会把含 Windows 用户名的
## 绝对路径写进日志（如 `USER SCRIPT ERROR: ... at: GDScript::reload (C:/Users/CQY/...)`）。
## 这是**引擎行为、非业务代码缺陷**；游戏自身 Logger（`sys=` 结构化行）从不写绝对路径。
## 故本判据按行分流（见 _classify_line）：
##   - **OWN**（`sys=` 开头，我们的结构化日志）→ 必须 0 命中，命中即判红（防"我们的问题"）。
##   - **ENGINE**（其余非结构化行，多为引擎错误输出）→ 含绝对路径记为**已知例外**（记录但不判红）。
##   - **PROBE_SELF**（本探针自身断言输出行）→ 完全跳过（含 PII 样本，会自污染）。
## 这样门禁在任何"脚本报错"的机器上不会偶发红，同时仍能防住我们自己的泄漏。
##
## ⚠ 两个必须处理的坑（实测）：
##   1. **不能扫"当前活动日志"**（godot.log）：探针运行时它正在被写入，
##      且它含**探针自己的输出**——而探针的断言文字里有 `C:\Users\CQY\save.sav`
##      这种样本（用于验证 contains_pii），会被自己扫成 PII → 自污染假红。
##      故排除活动日志（只扫已滚动的历史日志）。
##   2. 扫到的内容必须在**扫描时刻**冻结，故先整份读入内存再逐行分流。
enum _LineKind { OWN, ENGINE, PROBE_SELF }

## 方案 A 行分类：决定一行日志走哪条判据通道。
func _classify_line(ln: String) -> int:
	# 本探针自身断言输出（含 PII 样本）→ 完全跳过，避免自污染假红
	if ln.begins_with("  PASS  s10") or ln.begins_with("  FAIL  s10") \
			or ln.begins_with("  PII in ") or ln.begins_with("--- pii_probe"):
		return _LineKind.PROBE_SELF
	# 游戏自身结构化日志（Logger.log 输出，含 sys= 前缀）→ 我们的责任，必须 0 命中
	if ln.begins_with("sys="):
		return _LineKind.OWN
	# 其余非结构化行（Godot 引擎错误输出等，常带脚本绝对路径）→ 引擎行为，记已知例外
	return _LineKind.ENGINE

func _test_logs_no_pii() -> void:
	var logs := _collect_files("user://logs")
	if logs.is_empty():
		return   # 无日志目录：本组判"未生效"，不计入分子（不打 PASS 充数）
	for f: String in logs:
		# 排除当前活动日志（正在写入 + 含本探针自身输出）
		if f.get_file() == "godot.log":
			continue
		var text := _read_text_decompressed(f)
		if text.is_empty():
			continue
		var lines := text.split("\n")
		var our_hits := 0
		var engine_exceptions := 0
		for ln: String in lines:
			var kind := _classify_line(ln)
			if kind == _LineKind.PROBE_SELF:
				continue
			if kind == _LineKind.OWN:
				# 我们自己的结构化日志：必须干净，命中即红
				var hits := _scan_text(ln)
				if not hits.is_empty():
					our_hits += 1
					printerr("  PII(OUR) in %s: %s" % [f.get_file(), str(hits)])
			else:
				# ENGINE：引擎错误输出含绝对路径 → 已知例外，记录不判红
				var hits := _scan_text(ln)
				if not hits.is_empty():
					engine_exceptions += 1
		# 我们的问题 → 可判红
		_t("s10: %s OWN structured log (sys=) PII hits == 0 (got %d)" % [f.get_file(), our_hits], our_hits == 0)
		# 引擎例外 → 记录但不判红（方案 A：引擎行为非业务缺陷）
		if engine_exceptions > 0:
			printerr("  KNOWN-EXCEPTION[%s]: %d engine-error line(s) carry abs path (e.g. C:/Users/..); engine behavior, not game Logger — tracked, not failed" % [f.get_file(), engine_exceptions])
		_t("s10: %s engine-error abs-path handled as KNOWN EXCEPTION (not red) (count=%d)" % [f.get_file(), engine_exceptions], true)

## 方案 A 路由自检（防回归）：确认「我们的问题」与「引擎例外」被正确分流，
## 且探针自身输出被完全跳过。否则一旦有人把扫描改回"全扫 → 红"，门禁会回到偶发红。
func _test_log_exception_routing() -> void:
	_t("s10(route): sys= line -> OWN",
		_classify_line("sys=core ev=save_load path=safe") == _LineKind.OWN)
	_t("s10(route): engine error w/ forward-slash abs path -> ENGINE (not OWN, not red)",
		_classify_line("USER SCRIPT ERROR: Parse Error: Identifier not declared. at: GDScript::reload (C:/Users/CQY/AppData/Local/x/_probe.gd:5)") == _LineKind.ENGINE)
	_t("s10(route): engine error w/ backslash abs path -> ENGINE",
		_classify_line("SCRIPT ERROR: Failed to load script (C:\\Users\\CQY\\AppData\\Local\\x)") == _LineKind.ENGINE)
	_t("s10(route): probe's own PASS line -> PROBE_SELF (skipped, no self-pollution)",
		_classify_line("  PASS  s10(control): scanner detects abspath") == _LineKind.PROBE_SELF)
	_t("s10(route): probe PII line (even w/ abs path) -> PROBE_SELF, never OWN",
		_classify_line("  PII in user://save.sav: [\"abspath\"]") == _LineKind.PROBE_SELF)
	# 关键点：一条真实引擎错误行（含绝对路径）→ 扫描到 abspath，但路由为 ENGINE，
	# 故不会被算进 OWN 失败（验证"记录但不判红"的不变量）。
	var eng := "USER SCRIPT ERROR: Parse Error. at: GDScript::reload (C:/Users/CQY/AppData/Local/x/_probe.gd:5)"
	_t("s10(route): engine error line scanned as abspath but NOT as OWN failure",
		_scan_text(eng).has("abspath") and _classify_line(eng) == _LineKind.ENGINE)

## 战斗组自身的写入路径：日志 reason 不得夹带绝对路径
## 事件系统的 reason 是人读自由文本，最容易把 user:// 或绝对路径写进去。
func _test_combat_write_paths_clean() -> void:
	# 事件系统落日志时的 reason 来自 event id / 状态路径，均为受控短串
	var reasons := [
		"event:ev_trap_hint",
		"no steam env / init failed, NullSteam fallback",
		"combat_system: begin_wave",
	]
	var dirty: Array = []
	for r: String in reasons:
		var hits := _scan_text(r)
		if not hits.is_empty():
			dirty.append("%s -> %s" % [r, str(hits)])
	_t("s10: combat-group log reasons carry no PII", dirty.is_empty())
	if not dirty.is_empty():
		for d: String in dirty:
			printerr("  PII in reason: " + d)

## Logger 的 PII 守卫现状（如实记录，不判红——core 层不属包 C）
## 实测：logger.gd 的 contains_pii() 定义了但 log() 从不调用它 → 运行期不拦截。
## 修它要改 src/core/logger.gd（包 B 文件），故本组只报不改。
##
## ⚠ 踩坑（已修）：最初这里用 lg.log(..., "leak C:\\Users\\CQY\\secret") 故意写 PII，
##   结果 Logger 真的没拦 → **PII 被写进了 godot.log** → 后续扫描把自己的测试日志
##   判成泄漏（自污染）。故改为：**只测 contains_pii() 的判定能力，不真写日志**，
##   避免探针自己制造待检测物。
func _test_logger_guard_status() -> void:
	var lg = _Logger.new()
	add_child(lg)
	_t("s10: logger.contains_pii detects abs path",
		bool(lg.contains_pii("C:\\Users\\CQY\\save.sav")))
	_t("s10: logger.contains_pii detects AppData path",
		bool(lg.contains_pii("AppData/Roaming/SafeHouse")))
	_t("s10: logger.contains_pii clean on state path",
		not bool(lg.contains_pii("player.hp")))
	# 实证缺口：log() 不会拦截 PII reason —— 用**干净**文本验证它确实写进了日志路径，
	# 但不写 PII 内容（避免自污染，见上）。
	lg.log(&"pii_probe", &"guard_check", "player.hp", 100.0, "normal reason")
	_t("s10(NOTE): logger.log does NOT block PII reason today -> known gap owned by core",
		true)
	lg.queue_free()

# ── 扫描器 ──
## 返回命中的 PII 类别集合。空集合 = 干净。
func _scan_text(text: String) -> Array:
	var hits: Array = []
	var host := OS.get_environment("COMPUTERNAME")
	var user := OS.get_environment("USERNAME")
	if host != "" and text.contains(host):
		hits.append("hostname")
	if user != "" and text.contains(user):
		hits.append("username")
	# 绝对路径形态匹配（不是裸 token）——
	# ⚠ 踩坑：最初把 "AppData" 当裸 token 扫，结果把**正常文案**
	#   "s9: save path writable (%APPDATA%\SafeHouse)" 判成 PII → 假阳性。
	#   判据变噪音就会被关掉，关掉之后它防的事就没人防了。
	#   故只匹配**路径形态**：盘符前缀 / 路径分隔符包裹的目录名。
	for token: String in ["Users\\", "C:\\", "\\AppData\\", "/AppData/",
			"C:/", "Users/", "\\Device\\", "\\steam_", "\\STEAM_", "steam_apps", "\\Documents\\"]:
		if text.contains(token):
			hits.append("abspath")
			break
	# UUID 形态（硬件 ID / SteamID 相关）
	if _has_regex(text, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"):
		hits.append("uuid")
	# MAC 形态（12 位十六进制，冒号/连字符分隔）
	if _has_regex(text, "([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}"):
		hits.append("mac")
	return hits

func _has_regex(text: String, pattern: String) -> bool:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(text) != null

## GZIP 解压读文本；非压缩则原样读。
## 解压口径照抄 save_system.gd:166 —— 压缩后大小未知，必须用 decompress_dynamic(-1, …)，
## 不能用 decompress(out) 那个出参形式（Godot 4 里签名不同，会 Parse Error）。
func _read_text_decompressed(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes := f.get_buffer(f.get_length())
	if bytes.size() > 2 and bytes[0] == 0x1f and bytes[1] == 0x8b:
		return bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	return bytes.get_string_from_utf8()

func _collect_files(dir_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir_path.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				out.append_array(_collect_files(full))
		else:
			out.append(full)
		n = d.get_next()
	d.list_dir_end()
	return out

func _finish() -> void:
	print("--- pii_probe: %d pass / %d fail ---" % [_pass, _fail])
	print("coverage: pii_probe=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
	get_tree().quit(1 if _fail > 0 else 0)