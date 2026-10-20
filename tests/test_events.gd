extends RefCounted
## tests/test_events.gd — 域判据：事件 impact 封闭集 【包 F · W2 判据移植】
##
## 判据定义来源：event_system.gd:241（M10：impact 必须在 4 类封闭集内，
## schema additionalProperties:false 硬校验 + 运行时白名单防御）/ 任务书_战斗组_包CE §6。
## 引用版本：event_system.gd@2026-10-20、data/events/**@2026-10-20。
##
## 本文件是**数据侧独立扫描**（不依赖实现的运行时防御）：
## 运行时白名单只拦"被触发的事件"，静态扫描拦全部——没触发的脏数据也逃不掉。
## 封闭集 = effect_sink 的 4 类能力（num/flag/time/spawn），与 effect.schema.json 同源。

const IMPACT_WHITELIST := ["num", "flag", "time", "spawn"]
const EVENT_DIRS := [
	"res://data/events/random",
	"res://data/events/scheduled",
	"res://data/events/conditions",
]


static func run(host) -> void:
	var files := _json_files()
	# 空跑判负：0 个事件表 = 扫描无效（三层空跑判负之判据层）
	host._t("EVENT-0 scanned %d event table(s), must be > 0" % files.size(), files.size() > 0)
	if files.is_empty():
		host._block(["EVENT-M10-impact"], "blocked: no event tables found")
		return

	var total_events := 0
	var bad: PackedStringArray = []
	for p in files:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) != TYPE_DICTIONARY:
			bad.append("%s (parse failed)" % p)
			continue
		var evs: Variant = parsed.get("events", [])
		if typeof(evs) != TYPE_ARRAY:
			continue
		for ev: Dictionary in evs:
			if ev.get("_comment", "") != "" and not ev.has("id"):
				continue   # 顶层说明键不是事件
			total_events += 1
			var kind := String(ev.get("impact", ""))
			if not IMPACT_WHITELIST.has(kind):
				bad.append("%s:%s impact='%s'" % [p, String(ev.get("id", "?")), kind])

	host._t("EVENT-M10-0 total events scanned > 0 (%d)" % total_events, total_events > 0)
	host._t("EVENT-M10-1 all impacts within closed set {num,flag,time,spawn} (%d violations)"
		% bad.size(), bad.is_empty())
	if not bad.is_empty():
		print("      violations: " + " | ".join(bad))


static func _json_files() -> PackedStringArray:
	var out := PackedStringArray()
	for dir_path in EVENT_DIRS:
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not d.current_is_dir() and n.ends_with(".json") and not n.begins_with("_"):
				out.append(dir_path + "/" + n)
			n = d.get_next()
		d.list_dir_end()
	return out
