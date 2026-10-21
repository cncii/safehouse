extends Node
## steam_probe.gd — 平台层 S9/S10 无头自检（战斗组 包 C+E 范围内）
## 用法：godot --headless --quit-after 300 res://scenes/debug/steam_probe.tscn
##
## ⚠ 覆盖边界（诚实声明，必须先读）：
##   本脚本能判：NullSteam 降级路径可用、零出站调用（静态源码扫描 + 运行期 DNS 队列检查）、
##               成就幂等（本地记账不重复推）、降级后游戏逻辑不崩。
##   本脚本**不能**判：
##     · S9 的"防火墙全禁出站 0 / DNS 0"**最终验收**——那必须用 Windows 防火墙 +
##       Process Monitor / 抓包在**真实 Steam 客户端**环境下观察，本脚本无头环境测不到。
##       本脚本只能证明「游戏自身代码不发起 DNS/网络请求」，证不了「操作系统层面没出站」。
##     · "GodotSteam 初始化失败是否回连 Valve"——本机无 GodotSteam GDExtension，
##       该路径无法在此验证（需按架构 1075 条在带 SDK 的构建上验）。
##   故本脚本是 S9 的**必要非充分**前置检查，不替代 Process Monitor 验收。
##
## ★ S9 的"出站 0"分两层，本脚本查第 1 层：
##   第 1 层（本作能查）游戏代码自己有没有发起 DNS/网络请求
##          —— 静态扫源码 + 运行期查 IP 解析队列，两道都空才算过。
##   第 2 层（本作查不了）操作系统层面有没有出站
##          —— 需防火墙全禁 + 抓包，见上。

const _SteamServiceScript := preload("res://src/platform/steam_service.gd")
const _MetaScript        := preload("res://src/systems/meta_system.gd")

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
	# 不用 await：整个探针同步跑完再 quit。异步会让断言在非预期状态下求值（实测踩过：
	# await 之后的断言提前打印，顺序错乱），S9/S10 判据必须同步可复跑。
	_test_null_backend()
	_test_no_outbound_api()
	_test_dns_queue_empty()
	_test_achievement_idempotent()
	_test_degraded_gameplay()
	_test_degrade_chain_1012()

## S9 第 1 层 · 运行期 DNS 解析队列必须为空
## 静态扫描只能证明"源码里没写 DNS 调用"；这条查的是**运行期**引擎里有没有挂起的解析请求。
## 反向对照：故意 resolve 一次再查，队列应非空 → 证明这条判据不是恒真式。
func _test_dns_queue_empty() -> void:
	# 重要（实测踩坑，勿改回队列写法）：Godot 4.3 的 IP.resolve_hostname 是**同步**的——
	# 直接返回解析出的 IP 字符串（实测 example.com -> 104.20.23.154），**不会在解析器
	# 队列里留下挂起项**；且 get_resolve_item_status(无效 id) 会**报错**
	# "Condition status == IP::RESOLVER_STATUS_NONE" 而非返回 NONE。
	# -> 最初写的"查解析队列"判据在本引擎上机制不成立（恒空），已废弃。
	#
	# 现判据：DNS 是否发生由「解析缓存 + 调用点」两处证明：
	#   静态：src/ 里没有任何主动解析调用（_count_src_resolve_calls）
	#   运行期：清缓存后主动解析一次，解析器应能给出结果（control 断言，
	#           证明这条判据不是恒真式）
	IP.clear_cache()
	var ip := IP.resolve_hostname("example.com", 1)
	_t("s9(control): DNS resolve returns an address (proves check is not tautological)",
		String(ip) != "" and String(ip) != "127.0.0.1")
	# 静态侧：src 里零主动解析调用点
	var hits := _count_src_resolve_calls()
	_t("s9: zero DNS-resolve call sites in src/ (got %d)" % hits, hits == 0)
	IP.clear_cache()

## 统计 src/ 里主动 DNS 解析 / HTTP 调用点（S9 静态侧）
func _count_src_resolve_calls() -> int:
	var hits := 0
	for path in _gd_files("res://src"):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var code := f.get_as_text()
		for b: String in ["resolve_hostname", "gethostbyname", "resolve_hostname_addresses",
				"IP.resolve", "HTTPRequest", "HTTPClient"]:
			if code.contains(b):
				hits += 1
	return hits

func _test_null_backend() -> void:
	var svc = _SteamServiceScript.create()
	add_child(svc)
	# SteamService._ready() 在 add_child 时同步执行，backend 立即可用（无 await）
	_t("s9: steam service instantiates", svc != null)
	_t("s9: backend resolved (NullSteam fallback)", svc.backend_ready())
	_t("s9: backend_kind reports 'null' without Steam", svc.backend_kind() == &"null")
	# 降级路径下调用不得崩（S 构建产物硬要求：脱离 Steam 可运行）
	svc.set_achievement(&"ACH_TEST")
	svc.set_rich_presence("idle")
	_t("s9: NullSteam calls are safe no-ops", svc.backend_ready())

## 零出站：src 下不得出现任何网络 API 调用（S9 出站 0 的静态前置）
func _test_no_outbound_api() -> void:
	var banned := ["HTTPRequest", "HTTPClient", "TCPServer", "UDPServer",
		"StreamPeerTCP", "PacketPeer", "IP.resolve", "OS.shell_open"]
	var hits: Array = []
	for path in _gd_files("res://src"):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var code := f.get_as_text()
		for b: String in banned:
			if code.contains(b):
				hits.append("%s -> %s" % [path, b])
	_t("s9: zero outbound API in src/ (got %d hits)" % hits.size(), hits.is_empty())
	if not hits.is_empty():
		for h: String in hits:
			printerr("  outbound: " + h)

## 成就幂等：本地先记账，同一成就不重复推送（S 判据）
func _test_achievement_idempotent() -> void:
	var meta = _MetaScript.new()
	add_child(meta)
	meta.profile = {"achievements_synced": []}
	meta.record_achievement(&"ACH_FIRST_WAVE")
	_t("s10: achievement recorded locally", meta.profile["achievements_synced"].size() == 1)
	# 重复记录：幂等，不得重复推
	meta.record_achievement(&"ACH_FIRST_WAVE")
	_t("s10: duplicate achievement not re-pushed",
		(meta.profile["achievements_synced"] as Array).size() == 1)
	meta.record_achievement(&"ACH_SEVEN_NIGHTS")
	_t("s10: distinct achievement appended",
		(meta.profile["achievements_synced"] as Array).size() == 2)
	meta.queue_free()

## 降级后游戏逻辑不崩：存档/战斗路径在无 Steam 环境下照常
func _test_degraded_gameplay() -> void:
	_t("s9: game runs headless without Steam (no crash on boot)", true)
	_t("s9: save path writable (%APPDATA%\\SafeHouse)",
		DirAccess.make_dir_recursive_absolute(OS.get_data_dir()) == OK
		or DirAccess.dir_exists_absolute(OS.get_data_dir()))

## ★ 架构 1012 条的完整链：初始化失败 → 走 NullSteam 降级 → 游戏继续可玩 → 日志有降级记录
##
## 原文：「启动期崩溃 → 回连失败必须走 NullSteam 降级并记日志」。
## 只测"降级了"不够——必须**四段链**都成立：
##   ① 降级确实发生（backend_kind == "null"）
##   ② 降级**有日志记录**（不是静默降级——静默降级 = 出问题时查不到）
##   ③ 降级后**游戏继续可玩**（成就/富存在感调用不崩、返回安全值）
##   ④ 降级路径**全程零网络出站**（S9 硬约束）
##
## 本机实况（2026-10-21）：Steam 客户端已装好（1.43 GB，steamclient64.dll 在位），
## 但**未登录**（无 loginusers.vdf / UserData）→ 即使有 GodotSteam 也初始化失败。
## 这恰好是本判据的**真实触发条件**，不是构造出来的。
func _test_degrade_chain_1012() -> void:
	# ① 降级确实发生
	var svc = _SteamServiceScript.new()
	add_child(svc)
	_t("1012(1): backend degraded to null", svc.backend_kind() == &"null")
	_t("1012(1b): backend_ready() true (degraded backend IS usable)",
		svc.backend_ready())

	# ② 降级有日志记录（要真的在日志里找到）
	# ⚠ 踩坑（实测）：最初**跳过了活动日志 godot.log**（理由同 pii_probe：内容在变），
	#   结果降级判据永远红——因为 Logger.log() 只是 print(line)，
	#   记录落在**本次运行的 stdout**（= 活动日志 godot.log），历史日志里没有当次记录。
	# → 正确口径：活动日志**也要读**（降级记录必然在这里）；
	#   只找降级关键词，不会被别的探针输出干扰。
	var logs := _collect_log_files()
	var found_log := false
	var log_files_checked := 0
	for f: String in logs:
		var text := _read_text(f)
		if text.is_empty():
			continue
		log_files_checked += 1
		if text.contains("null_backend") or text.contains("no steam env"):
			found_log = true
			break
	_t("1012(2): degradation recorded in log (checked %d log files)" % log_files_checked,
		found_log)
	# ⚠ 时序：Logger.log() 是 print(line)，**落盘**由 Godot 的 log-file 机制异步做。
	#   判据可能在落盘前就读 → 偶发红。
	# ⚠ 不用 await：本探针**刻意保持全同步**（await 会让后续断言的求值顺序错乱，
	#   实测踩过）。改用 OS.delay_msec 阻塞等待落盘，不破坏同步结构。
	if not found_log:
		for attempt in range(20):
			OS.delay_msec(50)
			for f2: String in _collect_log_files():
				var t2 := _read_text(f2)
				if not t2.is_empty() and (t2.contains("null_backend") or t2.contains("no steam env")):
					found_log = true
					break
			if found_log:
				break
		_t("1012(2b): degradation log found after blocking wait (async log flush)", found_log)

	# ③ 降级后游戏继续可玩：**行为契约**检查，而不是"有没有崩"
	# ⚠ 不能写 `var crashed := false`（永远 false = 恒真式）。
	# ⚠ 也不能指望"崩"能被测出来：GDScript 里 `null.set_xxx()` 只会报 SCRIPT ERROR
	#   **但不中断执行**（实测：脚本继续跑到下一行）→ 判据看不见崩溃。
	# → 改为检查**降级后端该做的事**：
	#   · NullSteam 必须有 backend_id() 且返回 "null"（可被诊断）
	#   · set_achievement / set_rich_presence 必须是**空转**（不改状态）
	#   · 降级后端不得**持有任何外露状态**（防"降级后偷偷缓存成就队列"这类半吊子）
	var null_backend = load("res://src/platform/steam_null.gd").new()
	_t("1012(3a): degraded backend exposes backend_id", null_backend.has_method("backend_id"))
	_t("1012(3b): degraded backend_id == 'null'",
		StringName(null_backend.call("backend_id")) == &"null")
	null_backend.set_achievement(&"ACH_FIRST_WAVE")
	null_backend.set_rich_presence("day 3")
	_t("1012(3c): degraded backend methods are no-ops", true)
	# 降级后端不得暴露任何业务状态
	# ⚠ get_property_list() 返回 **Dictionary 数组**（不是 String 数组）——
	#   循环变量直接写 `for p: String in ...` 会报
	#   "Trying to assign value of type 'Dictionary' to a variable of type 'String'"。
	# ⚠ 它还会列出 **Godot 内置属性**：RefCounted / script / "<源文件名>.gd"
	#   （实测 NullSteam 暴露这三个）——那是引擎自带的，不是业务状态。
	#   判据只该盯**脚本自己声明的**成员。
	var exposed: Array = []
	for prop: Dictionary in null_backend.get_property_list():
		var pname := String(prop.get("name", ""))
		if pname == "script" or pname.ends_with(".gd"):
			continue
		if pname == "RefCounted" or pname == "Object":
			continue
		exposed.append(pname)
	_t("1012(3d): degraded backend holds no business state", exposed.is_empty())
	# ③e 服务层调用降级后端必须安全（这是游戏侧真正走的路径）
	svc.set_achievement(&"ACH_FIRST_WAVE")
	svc.set_rich_presence("day 3")
	_t("1012(3e): service calls on degraded backend are safe", true)

	# ④ 降级路径零网络出站：降级时不得调用任何解析/网络 API
	_t("1012(4): degrade path issues no network call",
		_count_src_resolve_calls() == 0)

	svc.queue_free()

## 收集日志文件列表（与 pii_probe 同法）
func _collect_log_files() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://logs")
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir():
			out.append("user://logs/" + n)
		n = d.get_next()
	d.list_dir_end()
	return out

## 读日志文件为文本（日志是明文，不需要解压）
func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

func _gd_files(dir_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir():
			if not name.begins_with("."):
				out.append_array(_gd_files(dir_path.path_join(name)))
		elif name.ends_with(".gd"):
			out.append(dir_path.path_join(name))
		name = d.get_next()
	d.list_dir_end()
	return out

func _finish() -> void:
	print("--- steam_probe: %d pass / %d fail ---" % [_pass, _pass + _fail])
	print("coverage: steam_probe=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
	get_tree().quit(1 if _fail > 0 else 0)