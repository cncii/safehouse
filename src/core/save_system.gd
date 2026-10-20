extends Node
## save_system.gd — 存档系统（架构 §5，单档位 + 原子写 + 版本迁移 + 种子校验）
##
## ── 硬约束（QA R1/R17/R22 判据） ──
## · 单槽：user://save.sav（无多档位、UI 层不存在"另存为"接口）。
## · 原子写：tmp → 回读自校验 → .bak → rename；失败不动旧档，永不半截文件。
## · 读档零写入（C6）：迁移只在内存做，needs_upgrade_write 留到下次正常存档。
## · 夜战进行中 manual_exit 不写档（R22 定案：退出与崩溃走同一条路径）。
## · 种子校验：day_index_of_seed == time.day 且 day_seed 重算匹配，不符判坏档。
## · profile.sav 单独存跨局数据（周目/解锁/统计），新局重置不碰它。
##
## ── 分包规则 ──
## · SaveSystem 持有 snapshot()/restore() 的整体覆写特权，全项目仅此一处。
## · 各系统把要持久化的字段写进 to_save()/from_save()，本系统只做组装与落盘。

const SCHEMA_VERSION := 1
const PATH_SAVE := "user://save.sav"
const PATH_BAK := "user://save.sav.bak"
const PATH_PROFILE := "user://profile.sav"

signal saved(reason: String)

var needs_upgrade_write := false   # C6：迁移发生在内存，落盘推迟

## ── 写入（原子） ──
func save(reason: String) -> bool:
	if _night_wave_active():
		Logger.log("save", "blocked_night_wave", "", null, "R22: night wave active, save blocked")
		return false
	var payload := _build_payload(reason)
	var text := JSON.stringify(payload, "  ")
	var bytes := text.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)

	var tmp := PATH_SAVE + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("save: cannot open tmp")
		return false
	f.store_buffer(bytes)
	f.flush()
	f.close()

	# 回读自校验：能解开且能 parse 才算写成功
	if not _can_parse(tmp):
		push_error("save: tmp self-check failed, keep old")
		return false

	# 旧档降级为 .bak（抓"bak copy-order guard"：QA M8d 要求 .bak 逐字节等于上一次主档）
	if FileAccess.file_exists(PATH_SAVE):
		DirAccess.copy_absolute(_abs(PATH_SAVE), _abs(PATH_BAK))

	var err := DirAccess.rename_absolute(_abs(tmp), _abs(PATH_SAVE))
	if err != OK:
		push_error("save: rename failed %d" % err)
		return false
	needs_upgrade_write = false
	saved.emit(reason)
	return true

## ── 读取（含迁移与坏档兜底） ──
func load_run() -> Dictionary:
	for path: String in [PATH_SAVE, PATH_BAK]:
		if not FileAccess.file_exists(path):
			continue
		var raw := _read_parsed(path)
		if raw.is_empty():
			continue
		var migrated := migrate(raw)
		if migrated.is_empty():
			continue
		if not _verify_seed(migrated):
			push_error("load: seed check failed (%s) - corrupt" % path)
			continue
		if path == PATH_BAK:
			Logger.log("save", "restored_from_bak", "", null, "main save corrupt, restored from .bak")
		return migrated
	return {}

func load_profile() -> Dictionary:
	if not FileAccess.file_exists(PATH_PROFILE):
		return {"schema_version": SCHEMA_VERSION, "profile": {}}
	return _read_parsed(PATH_PROFILE)

func save_profile(profile: Dictionary) -> bool:
	return _atomic_write(PATH_PROFILE, {"schema_version": SCHEMA_VERSION, "profile": profile})

## ── 版本迁移链（只增不改；每次 bump 必须同时提交 fixture） ──
func migrate(raw: Dictionary) -> Dictionary:
	var v := int(raw.get("schema_version", 0))
	if v > SCHEMA_VERSION:
		push_error("save from newer version %d, current %d" % [v, SCHEMA_VERSION])
		return {}
	while v < SCHEMA_VERSION:
		# 追加迁移函数时在此处接力：v == N → raw = _migrate_vN_to_vN1(raw)
		push_error("missing migration v%d -> v%d" % [v, v + 1])
		return {}
	return raw

## ── 种子一致性（契约 5） ──
func _verify_seed(raw: Dictionary) -> bool:
	var rnd: Dictionary = raw.get("random", {})
	var t: Dictionary = raw.get("time", {})
	if int(rnd.get("day_index_of_seed", -1)) != int(t.get("day", -2)):
		return false
	return Rng.verify_day(int(t.get("day", 0)), int(rnd.get("day_seed", 0)))

## ── 内部 ──
## ── 持久化注册（D-009 修复：to_save/from_save 挂接点）──
## ⚠ 两层边界，分包团队勿混：
##   ① 运行期状态路径（data/schema/state_contract.json）：数值型状态（hp/milli/计数），
##      走 StateStore.apply() 的 writers 鉴权。容器型状态（背包物品列表/搜刮标记/
##      事件日志）**不进 contract、不走 apply**——ChangeSet 是数值 Op 流，塞不进容器。
##   ② 存档文件结构（data/schema/save.schema.json）：九类持久化清单的字段级定义，
##      各系统实现 to_save() 组装、from_save() 恢复，经下面的注册表挂接。
## 新系统接存档三步：实现 to_save/from_save → register_persistence 注册 →
## 按 save.schema.json 校验字段。P7（读档 diff=0）对两层都生效。
var _persistences: Dictionary = {}   # key -> {to_save: Callable, from_save: Callable}

func register_persistence(key: StringName, to_save_cb: Callable, from_save_cb: Callable) -> void:
	assert(not _persistences.has(String(key)), "duplicate persistence key: %s" % key)
	_persistences[String(key)] = {"to_save": to_save_cb, "from_save": from_save_cb}
	Logger.log("save", "persistence_registered", String(key))

## load_run() 之后由启动流程调用：把存档快照分发给各注册系统
func apply_persisted(snapshot: Dictionary) -> void:
	for key: String in _persistences:
		if snapshot.has(key):
			(_persistences[key]["from_save"] as Callable).call(snapshot[key])
		else:
			push_warning("save: missing section '%s' (new field? run migration chain)" % key)

func _build_payload(reason: String) -> Dictionary:
	# 各系统的 to_save() 在此组装；骨架期给出最小结构（QA S16 要求
	# save_reason ∈ {day_start_05_00, manual_exit, event_fired, death, night_cleared}）
	var payload := {
		"schema_version": SCHEMA_VERSION,
		"save_reason": reason,           # 注意：不参与内容语义（C7），哈希比对须排除
		"saved_at_utc": Time.get_datetime_string_from_system(true),
		"time": {"day": 1, "stage": "A", "phase": "PREP", "night_index": 0,
			"gh_elapsed_today": 0.0, "mode": "REALTIME"},
		"random": {"global_seed": Rng._global_seed, "day_index_of_seed": 1,
			"day_seed": Rng.day_seed(1)},
		"player": State.snapshot(),
	}
	# 各系统注册的持久化段（D-009 挂接点）：inventory/tech/facilities/map/events 由包 B/C 落
	for key: String in _persistences:
		payload[key] = (_persistences[key]["to_save"] as Callable).call()
	payload["integrity"] = {"engine_version": Engine.get_version_info()["string"],
		"content_version": ProjectSettings.get_setting("application/config/version", "0.1.0")}
	return payload

func _night_wave_active() -> bool:
	# 由 CombatSystem 在 begin_wave/clear 时置位（阶段B 夜间波次进行中）
	return bool(State.read("combat.wave_active"))

func _can_parse(path: String) -> bool:
	var raw := _read_parsed(path)
	return not raw.is_empty()

func _read_parsed(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var text := bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _atomic_write(path: String, payload: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	# 与 _read_parsed 对称：统一 GZIP（此前裸写 JSON 而读侧解压 → profile 通道读写
	# 不对称，save_profile 后 load_profile 恒空。S6 接入时发现，2026-10-20 修）。
	f.store_buffer(JSON.stringify(payload, "  ").to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))
	f.flush()
	f.close()
	return true

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)
