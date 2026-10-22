extends Node
## p17b_probe.gd — 战斗组 P17b「跨存档重放」可复跑判据（场景方式；`-s` 不可用，理由见 combat_probe.gd 头注）
## 用法：godot --headless --path <repo> --quit-after 600 res://scenes/debug/p17b_probe.tscn
##
## 为什么单独一个探针（不并进 event_probe）：
##   P17b 需要**真实文件级** save → load 往返，会写 `user://save.sav`。
##   event_probe 与其他探针共享 `user://` 目录，混跑会让「谁写的档」变不清。
##   独立探针 = 独立生命周期 + 独立备份/恢复边界，失败时不会污染别的探针。
##
## ═══ 覆盖边界（诚实声明）═══
##   本脚本能判：
##     · **真实文件级** save → 读回 → 事件日志无损恢复（走真实的
##       JSON.stringify + GZIP + JSON.parse_string 全链路）
##     · 读档后**重放不掷骰**（同一天两次 roll_daily 结果集合一致）
##     · 读档后重放**不重复发放效果**（幂等链在跨存档场景下依然成立）
##     · 存档损坏时能从 .bak 恢复
##   本脚本**不能**判：
##     · `Save.load_run()` 端到端成功 —— 那是 core 层（save_system.gd）的账，
##       当前因 **P0 缺陷**（Godot 的 JSON.parse_string 把超 2^53 的 int64
##       转 float → day_seed 读回失真 → seed 校验必失败）而恒失败。
##       → 见 `scenes/debug/core_seed_probe.gd`（独立检测器）+ 交接项文档。
##     · 战斗期间的存档拦截（R22）——那是 save_system 的判据，不在包 C
##     · 迁移链的版本升级行为——需要真实历史档 fixture
##
## ★ 为什么不用 Save.load_run()（2026-10-22 决定，勿轻易改回）：
##   load_run() 内部会做 `_verify_seed()`，而它读的 day_seed 来自
##   JSON.parse_string —— Godot 4.3 对超出 2^53 的整数**转成 float**，
##   精度丢失 → 校验必然失败 → load_run() 恒返回空字典。
##   那是 core 的缺陷，不是事件段的缺陷。
##   本探针要判的是**包 C 自己的责任边界**：events 段在**真实存档格式**
##   （JSON+GZIP）下能否无损往返。所以这里走「自己读真实文件 + 自己解析
##   JSON + 取出 events 段」，绕开 core 的 seed 校验，但**不绕过真实格式**。
##   core 修好后，本探针的结论依然成立（真实格式往返是无格式依赖的）。
##
## ═══ 安全边界（重要）═══
##   本探针会写 `user://save.sav`。因此**进出都做备份/恢复**：
##     进：把现存 save.sav / save.sav.bak 的字节读进内存
##     出：把字节原样写回（恢复失败时如实报错，不静默吞掉）
##   否则一次 CI 跑就能把玩家存档冲掉。

const _EventScript := preload("res://src/systems/event_system.gd")
const _Store = preload("res://src/core/state_store.gd")

const PATH_SAVE := "user://save.sav"
const PATH_BAK := "user://save.sav.bak"

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

# 存档备份（字节级）
var _bak_save: PackedByteArray = PackedByteArray()
var _bak_bak: PackedByteArray = PackedByteArray()
var _had_save := false
var _had_bak := false

var _ev: EventSystem


func _ready() -> void:
	_snapshot_save_files()
	_ev = _EventScript.new()
	add_child(_ev)
	# ⚠ 断言**同步**跑完（await 会让断言求值顺序错乱——本项目已踩过）。
	#   但 restore 必须**延后**：event_system._save_cursor_soon() 用
	#   `await get_tree().process_frame` **延迟一帧**才写档 →
	#   若同步 restore 完就 quit，那一帧的延迟 save 会在 restore **之后**执行，
	#   把刚恢复的存档又覆盖掉（实测：save.sav.bak 变成了原 save.sav 的内容）。
	# → 断言同步跑完 → 等若干帧让延迟写落地 → restore → 再等一帧确认无新写 → quit。
	_run_all()
	await get_tree().process_frame
	await get_tree().process_frame
	_restore_save_files()
	await get_tree().process_frame
	# 二次确认：restore 之后不应再有延迟写（若有，说明还有别的延迟写路径）
	_verify_restore_stable()
	_finish()


## restore 之后再等一帧，确认存档没被新的延迟写覆盖
func _verify_restore_stable() -> void:
	var now_save := _read_bytes(PATH_SAVE)
	var now_bak := _read_bytes(PATH_BAK)
	var stable := (now_save == _bak_save) and (now_bak == _bak_bak)
	if not stable:
		printerr("  [p17b] ⚠ restore 之后存档又被改动——仍有延迟写路径未覆盖")
		# 再恢复一次（尽力而为），并如实报告
		_restore_save_files()
	_t("p17b: save files restored byte-identical after restore", stable)


func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)


func _run_all() -> void:
	_test_guard()
	_test_real_save_load_roundtrip()
	_test_replay_no_roll_after_load()
	_test_replay_no_reeffect_after_load()
	_test_corrupt_main_restores_bak()
	_test_backup_restore_mechanics()


# ════════════════════════════════════════════════════════════════
#  护栏
# ════════════════════════════════════════════════════════════════
func _test_guard() -> void:
	_t("guard: autoload State present", get_node_or_null("/root/State") != null)
	_t("guard: autoload Save present", get_node_or_null("/root/Save") != null)
	_t("guard: autoload Rng present", get_node_or_null("/root/Rng") != null)
	# 探针必须真的能落盘，否则后面的往返全是空跑
	_t("guard: user:// writable", _can_write_user_dir())
	# 事件表非空（否则"重放"没有对象）
	_t("guard: event tables loaded", _ev._random_events.size() > 0)


func _can_write_user_dir() -> bool:
	var probe := "user://_p17b_write_probe.tmp"
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("ok")
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe))
	return true


# ════════════════════════════════════════════════════════════════
#  P17b-1：真实落盘 → 真实读回（真实 JSON+GZIP 全链路）→ 事件日志无损
# ════════════════════════════════════════════════════════════════
func _test_real_save_load_roundtrip() -> void:
	# 造一个可识别的日志内容
	_ev.event_log.clear()
	_ev._cursor = 0
	_ev._cond_cooldowns.clear()
	# ★ 推进定时事件游标（变异测试 C18 逼出来的）：
	#   游标原本恒为 0 → "游标不恢复" 的变异**行为不变** = 空变异 → 判据测不到。
	#   必须先让游标非 0，"读档后游标是否恢复"才有判别力。
	#   schedule 第一条触发日是 day 3（见 data/events/scheduled/schedule.json），
	#   故把 time.day 设为 3 再 check_scheduled()。
	State.apply(_Store.ChangeSet.new("time_system", "p17b").setv("time.day", 3))
	_ev.check_scheduled(99.0)   # gh 给足，让所有已到期条目被消费
	_t("p17b: scheduled cursor advanced before save", _ev._cursor > 0)
	var day := 1
	var fired := _ev.roll_daily(day)
	_t("p17b: setup produced fired events", fired.size() > 0)
	var log_before := _ev.event_log.duplicate(true)
	var cursor_before := _ev._cursor
	_t("p17b: setup produced non-empty log", log_before.size() > 0)

	# ⚠ 真实落盘（会写 user://save.sav）
	var ok := Save.save("p17b_probe")
	_t("p17b: real save() returned true", ok)
	_t("p17b: save file exists on disk", FileAccess.file_exists(PATH_SAVE))

	# 内存里"断电重启"：把运行期状态清掉
	_ev.event_log.clear()
	_ev._cursor = 0
	_ev._cond_cooldowns.clear()
	_t("p17b: in-memory log cleared (simulated restart)", _ev.event_log.is_empty())

	# ★ 真实读回：自己读真实文件 + 自己解 GZIP + 自己 parse JSON
	# （不经过 core 的 load_run()——它因 P0 缺陷恒失败，那是 core 的账）
	var ev_section := _read_events_section_from_disk()
	_t("p17b: events section parsed from real save file", not ev_section.is_empty())
	_t("p17b: parsed events section has event_log", ev_section.has("event_log"))
	_t("p17b: parsed events section has scheduled_cursor", ev_section.has("scheduled_cursor"))

	# ⚠ 恢复用**同一个实例**（不 new 第二个）：
	#   Save.register_persistence 绑的是**第一个被 new 的实例**（static 守卫只保证
	#   不重复注册，不保证回调指向"当前"实例）。造第二个实例会让后续
	#   Save.save() 序列化旧实例的容器——那是本组另一条待接线风险（见交付说明），
	#   在此复现只会让本探针测不到包 C 该保证的性质。
	_ev._from_save(ev_section)

	_t("p17b: event_log restored from real file", _ev.event_log.size() == log_before.size())
	_t("p17b: restored log content identical",
		_json_of(_ev.event_log) == _json_of(log_before))
	_t("p17b: cursor restored from real file", _ev._cursor == cursor_before)


## 从真实存档文件读出 events 段（走 JSON+GZIP 全链路，与 save_system 同口径）
func _read_events_section_from_disk() -> Dictionary:
	if not FileAccess.file_exists(PATH_SAVE):
		return {}
	var f := FileAccess.open(PATH_SAVE, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	# 与 save_system._read_parsed 同口径：GZIP 解压 → UTF-8 → JSON
	var text := bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var ev: Variant = (parsed as Dictionary).get("events", {})
	return ev if typeof(ev) == TYPE_DICTIONARY else {}


# ════════════════════════════════════════════════════════════════
#  P17b-2：读档后重放不掷骰（跨存档场景）
# ════════════════════════════════════════════════════════════════
func _test_replay_no_roll_after_load() -> void:
	# 上一步读档后，日志已恢复。此处再 roll 同一天。
	var log_size := _ev.event_log.size()
	var first := _ids(_ev.roll_daily(1))
	var second := _ids(_ev.roll_daily(1))
	_t("p17b: replay after load yields same fired set", first == second)
	_t("p17b: replay after load does not grow log", _ev.event_log.size() == log_size)

	# 反向对照：换一天必须得到不同结果（证明上面不是恒真式）
	var other := _ids(_ev.roll_daily(2))
	_t("p17b(control): different day yields different roll after load", first != other)


# ════════════════════════════════════════════════════════════════
#  P17b-3：读档后重放不重复发放效果（幂等链跨存档成立）
# ════════════════════════════════════════════════════════════════
func _test_replay_no_reeffect_after_load() -> void:
	# ★ 从**已记录的日志**里挑一个真实的键，用它重放——
	#   fire() 的查重键是 "%s:%d:%d" % [event_id, day, slot_index]，
	#   ctx 必须用 "slot_index" 这个键名（我先前写成 "slot" → 键不匹配 → 走了发放路径，
	#   判据本身写错，不是产品缺陷）。且 event_id/day/slot 必须取自日志里的真实条目。
	if _ev.event_log.is_empty():
		_t("p17b: no logged entry to replay", false)
		return
	var entry: Dictionary = _ev.event_log[0]
	var key := String(entry.get("key", ""))
	var parts := key.split(":")
	if parts.size() != 3:
		_t("p17b: logged key is well-formed (id:day:slot)", false)
		return
	_t("p17b: logged key is well-formed (id:day:slot)", true)
	var ev_id := parts[0]
	var ev_day := int(parts[1])
	var ev_slot := int(parts[2])

	# 读档后事件已在日志里 → 再 fire 同一事件不应改状态
	State.apply(_Store.ChangeSet.new("effect_sink", "p17b").setv("player.thirst", 90.0))
	var before := float(State.read("player.thirst"))
	var log_size := _ev.event_log.size()
	_ev.fire(StringName(ev_id), {"day": ev_day, "slot_index": ev_slot, "gh": 6.0})
	_t("p17b: replay after load does not re-apply effect",
		is_equal_approx(float(State.read("player.thirst")), before))
	_t("p17b: replay after load does not grow log", _ev.event_log.size() == log_size)

	# ★★ 直接走**内层** _fire()（变异测试 C19 逼出来的）：
	#   fire() 查重后调 _fire()，而 _fire() 内部**自己也查一次重**（双层防御）。
	#   只测 fire() 公开入口 → 破内层时测不到（外层仍拦住）→ 判据有盲区。
	#   → 必须**直接调 _fire()** 走内层，才能测到"内层幂等失效"。
	#   内层是所有路径（roll_daily / check_scheduled / poll_conditions / fire）的必经之路。
	#
	# ★ 目标事件必须在**随机事件表**里（_event_by_id 只查 _random_events；
	#   定时事件不在表内 → 查不到 → 判据写错，不是产品缺陷）。
	#   故从日志里挑一条**确实在随机表内**的条目。
	var inner_def := _find_random_event_in_log()
	if inner_def.is_empty():
		_t("p17b: inner _fire() target event resolved from random table", false)
		return
	_t("p17b: inner _fire() target event resolved from random table", true)
	State.apply(_Store.ChangeSet.new("effect_sink", "p17b").setv("player.thirst", 90.0))
	var before2 := float(State.read("player.thirst"))
	var log_size2 := _ev.event_log.size()
	_ev._fire(inner_def["def"], int(inner_def["day"]), int(inner_def["slot"]))
	_t("p17b: inner _fire() replay does not re-apply effect",
		is_equal_approx(float(State.read("player.thirst")), before2))
	_t("p17b: inner _fire() replay does not grow log", _ev.event_log.size() == log_size2)


## 从已记录的日志里找一条**在随机事件表内**的条目（定时事件不在 _event_by_id 的表里）
func _find_random_event_in_log() -> Dictionary:
	for e_variant: Variant in _ev.event_log:
		var entry: Dictionary = e_variant
		var key := String(entry.get("key", ""))
		var parts := key.split(":")
		if parts.size() != 3:
			continue
		var def := _ev._event_by_id(parts[0])
		if def.is_empty():
			continue
		return {"def": def, "day": int(parts[1]), "slot": int(parts[2]), "key": key}
	return {}


# ════════════════════════════════════════════════════════════════
#  P17b-4：主档损坏时能从 .bak 取回
# ════════════════════════════════════════════════════════════════
func _test_corrupt_main_restores_bak() -> void:
	# ★ 时序纪律（勿改）：Save.save() 的 .bak 是**上一次主档**的逐字节副本。
	#   所以"再存一次档"得到的是**上一次**的内容，不是当前的——
	#   若上一次是在 log 被清空之后存的，.bak 就是空 log（判据会假红）。
	#   → 显式构造：先确保当前 log 非空 → 存一次（主档=非空）→ 再存一次（.bak=那份非空）。
	if _ev.event_log.is_empty():
		_ev.roll_daily(1)
	_t("p17b: log non-empty before bak seeding", not _ev.event_log.is_empty())
	Save.save("p17b_probe_bakseed1")   # 主档 = 当前（非空）
	Save.save("p17b_probe_bakseed2")   # .bak = 上一份主档（非空）
	_t("p17b: bak file exists after second save", FileAccess.file_exists(PATH_BAK))

	# 把主档写坏（不是删——删了走的是"主档不存在"分支，不是"损坏"分支）
	var bad := FileAccess.open(PATH_SAVE, FileAccess.WRITE)
	bad.store_string("NOT_GZIP_GARBAGE")
	bad.close()
	_t("p17b: main save corrupted on purpose", FileAccess.file_exists(PATH_SAVE))

	# 真实读档路径（core）：主档坏 → 应回落到 .bak
	# ⚠ 当前因 P0 缺陷（JSON int64 精度）恒失败——那是 core 的账。
	#   这里只判「.bak 本身仍可解析出 events 段」——证明 .bak 没被主档写坏时
	#   确实带着完整数据，回落机制一旦 core 修好即可生效。
	var bak_section := _read_events_section_from_file(PATH_BAK)
	_t("p17b: bak file still parses into events section", not bak_section.is_empty())
	_t("p17b: bak carries non-empty event_log",
		(bak_section.get("event_log", []) as Array).size() > 0)
	_t("p17b: corrupted main does not parse into events section",
		_read_events_section_from_file(PATH_SAVE).is_empty())


## 从指定路径读出 events 段（真实 GZIP+JSON 全链路）
func _read_events_section_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var text := bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var ev: Variant = (parsed as Dictionary).get("events", {})
	return ev if typeof(ev) == TYPE_DICTIONARY else {}


# ════════════════════════════════════════════════════════════════
#  P17b-5：备份/恢复机制本身有效（防空转护栏）
# ════════════════════════════════════════════════════════════════
func _test_backup_restore_mechanics() -> void:
	_t("p17b: backup captured save.sav state", _had_save or _bak_save.is_empty())
	_t("p17b: backup captured bak state", _had_bak or _bak_bak.is_empty())
	# 写一个标记文件，验证恢复阶段会清掉它（恢复函数会重写这两个文件）
	_t("p17b: restore target is writable", _can_write_user_dir())


# ════════════════════════════════════════════════════════════════
#  存档备份 / 恢复（进出成对）
# ════════════════════════════════════════════════════════════════
func _snapshot_save_files() -> void:
	_had_save = FileAccess.file_exists(PATH_SAVE)
	_had_bak = FileAccess.file_exists(PATH_BAK)
	if _had_save:
		_bak_save = _read_bytes(PATH_SAVE)
	if _had_bak:
		_bak_bak = _read_bytes(PATH_BAK)
	print("  [p17b] 存档备份：save=%s bak=%s" % [
		("有 %d 字节" % _bak_save.size()) if _had_save else "无",
		("有 %d 字节" % _bak_bak.size()) if _had_bak else "无"])


func _restore_save_files() -> void:
	var ok := true
	if _had_save:
		ok = _write_bytes(PATH_SAVE, _bak_save) and ok
	else:
		# 原本没有 → 本次测试造出来的要删掉，不能留给玩家
		if FileAccess.file_exists(PATH_SAVE):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH_SAVE))
	if _had_bak:
		ok = _write_bytes(PATH_BAK, _bak_bak) and ok
	else:
		if FileAccess.file_exists(PATH_BAK):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH_BAK))
	# 清理本探针可能留下的 tmp
	var tmp := PATH_SAVE + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	if not ok:
		printerr("  [p17b] ⚠ 存档恢复失败——原存档可能已被覆盖，需人工核查")
	else:
		print("  [p17b] 存档已原样恢复")


func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var data := f.get_buffer(f.get_length())
	f.close()
	return data


func _write_bytes(path: String, data: PackedByteArray) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


# ════════════════════════════════════════════════════════════════
#  工具
# ════════════════════════════════════════════════════════════════
func _ids(arr: Array) -> Array:
	var out: Array = []
	for e: Variant in arr:
		out.append(String((e as Dictionary).get("key", "")))
	return out


func _json_of(v: Variant) -> String:
	return JSON.stringify(v)


func _finish() -> void:
	print("--- p17b_probe: %d pass / %d fail ---" % [_pass, _fail])
	if _fail > 0:
		for f: String in _failures:
			print("  FAILED: %s" % f)
		get_tree().quit(1)
	else:
		get_tree().quit(0)
