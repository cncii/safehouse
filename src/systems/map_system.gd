class_name MapSystem
extends Node
## map_system.gd — 地图与资源系统 【分包：包 B·模拟系统组】
##
## ── 职责 ──   总览节点图(节点+连线+距离=GH成本) / 进入地点时按种子生成布局 /
##             搜刮标记 / D4 起部分回填 / 隐藏状态(遭遇率 -60%)
## ── 不做 ──   不加载场景(SceneRouter)；不管背包(掉落物交 InventorySystem)；
##             不推进时间(距离成本由 TimeSystem 扣)；不直接写 RNG
## ── 依赖 ──   Rng(hash_at 位置无关子流) / data/locations/* / data/items/*
## ── 判据 ──   M9(同种子同日重开快照哈希全等) P16(开箱顺序无关性)
##             P24(隐藏状态-60%遭遇率) P27(致死机制≥2夜预警已由 ev_trap_hint 满足)
##
## ── 核心不变量 ──
## generate_layout 是纯函数：layout = f(day_seed, node_id, theme_params)
## 不依赖访问顺序/真实时间/已消耗随机数个数——防 S/L 的地基。
## 掉落用位置无关 hash：hash_at(LOOT, day, [loc_id, point_id])，不是被顺序消费的流。
##
## ── 实现（逻辑组 · 2026-10-19）────────────────────────────────
## 纯度保证三条，缺一条 M9 就会假绿：
##   ① 本文件不持有任何"已访问/已开箱/已消耗"状态——随机一律 hash_at 直算；
##   ② 布局用 FLAVOR 子流（房间排布属呈现随机，不与玩法数值耦合）；
##   ③ 掉落用 LOOT 子流，键只有 [loc_id, point_id]——键里没有"第几次开箱"。
## 自检入口：verify_determinism() 返回 M9/P16 实测结果，判据本体在本文件内，
##   本包不依赖别人的测试文件；包 F 接线即可红绿。
## ────────────────────────────────────────────────────────────────

const _LOC_PATH := "res://data/locations/locations.json"
const _THEME_PATH := "res://data/locations/themes.json"
const _LOOT_PATH := "res://data/items/loot_tables.json"
const _ITEMS_PATH := "res://data/items/items.json"
const _PLAN_PATH := "res://data/locations/scavenge_plans.json"

static var _loaded := false
static var _persist_registered := false
static var _nodes: Dictionary = {}          # node_id -> node
static var _edges: Array = []               # [{from,to,travel_cost_gh}]
static var _themes: Dictionary = {}         # theme_id -> theme
static var _loot: Dictionary = {}           # theme_id -> [entries]
static var _loot_total: Dictionary = {}     # theme_id -> 权重合计
static var _item_ids: Dictionary = {}       # item_id -> true（悬空引用自检）


func _ready() -> void:
	_ensure_loaded()
	# 存档注册只做一次——Save.register_persistence 遇重复 key 会 assert 崩，
	# 而无头测试会 new 多个实例（test_map / test_map_loot 各一个）。
	# 用 static 回调（不绑实例）：绑实例会把存档绑在"第一个被 new 的实例"上，
	# 第二个实例的容器是空的——读档丢状态且不报错。
	if not _persist_registered:
		Save.register_persistence(PERSIST_KEY, Callable(MapSystem, "to_save"),
			Callable(MapSystem, "from_save"))
		_persist_registered = true


# ════════════════════════════════════════════════════════════════
#  距离（总览节点图）
# ════════════════════════════════════════════════════════════════

## 单程 GH 成本。无连线返回 -1（不可达），**不返回 0**——
## 0 会被调用方当成"免费传送"，是一条会自己长出来的洞。
func travel_cost(from: StringName, to: StringName) -> float:
	_ensure_loaded()
	if from == to:
		return 0.0
	for e: Dictionary in _edges:
		var a := str(e.get("from", ""))
		var b := str(e.get("to", ""))
		if (a == str(from) and b == str(to)) or (a == str(to) and b == str(from)):
			return float(e.get("travel_cost_gh", 0.0))
	return -1.0


## 某节点当前可直达的邻居（供总览图 UI 用）
func neighbors(node_id: StringName) -> Array:
	_ensure_loaded()
	var out: Array = []
	for e: Dictionary in _edges:
		if str(e.get("from", "")) == str(node_id):
			out.append(str(e.get("to", "")))
		elif str(e.get("to", "")) == str(node_id):
			out.append(str(e.get("from", "")))
	return out


func node_ids() -> Array:
	_ensure_loaded()
	return _nodes.keys()


func is_reachable(from: StringName, to: StringName) -> bool:
	return travel_cost(from, to) >= 0.0


# ════════════════════════════════════════════════════════════════
#  布局生成（纯函数 · M9 的主体）
# ════════════════════════════════════════════════════════════════

## 纯函数：layout = f(day_seed, node_id, theme_params)
## 返回 {node_id, day, theme_id, rooms[], loot_points[]}
## loot_points 每项内联该点掉落内容——世界快照因此是布局的确定函数。
func generate_layout(node_id: StringName, day: int) -> Dictionary:
	_ensure_loaded()
	var node: Dictionary = _nodes.get(str(node_id), {})
	if node.is_empty():
		return {}
	var theme_id := str(node.get("theme_id", ""))
	var theme: Dictionary = _themes.get(theme_id, {})
	if theme.is_empty():
		return {}
	return {
		"node_id": str(node_id),
		"day": day,
		"theme_id": theme_id,
		"rooms": _build_rooms(node_id, day, theme),
		"loot_points": _build_loot_points(node_id, day, theme),
	}


## 房间拼装器：房间数/拓扑来自 themes.json，排布由 FLAVOR 子流偏移。
## 「固定分布 + 随机偏移」——设计基线 2.6 原话：固定部分保证同主题手感一致，
## 偏移部分保证不同地点不是一张图复制粘贴。
func _build_rooms(node_id: StringName, day: int, theme: Dictionary) -> Array:
	var room_count := int(theme.get("layout_room_count", 0))
	var corridor_count := int(theme.get("layout_corridor_count", 0))
	var rooms: Array = []
	for i in room_count:
		var h := Rng.mix64(Rng.hash_at(&"FLAVOR", day,
			PackedStringArray([str(node_id), "room", str(i)])))
		rooms.append({
			"id": "r%d" % i,
			"grid_x": i % 4,
			"grid_y": i / 4,
			"offset_x_px": int(absi(h) % 5) - 2,
			"offset_y_px": int(absi(h >> 3) % 5) - 2,
			"is_corridor": i < corridor_count,
			"size_w_px": 96,
			"size_h_px": 64,
		})
	return rooms


## 掉落点：位置由 FLAVOR 定，内容由 LOOT 位置无关 hash 定。
func _build_loot_points(node_id: StringName, day: int, theme: Dictionary) -> Array:
	var point_count := int(theme.get("layout_loot_point_count", 0))
	var points: Array = []
	for i in point_count:
		var point_id := "lp%d" % i
		var h := Rng.mix64(Rng.hash_at(&"FLAVOR", day,
			PackedStringArray([str(node_id), "point", point_id])))
		points.append({
			"id": point_id,
			"room_id": "r%d" % (i % maxi(room_count(theme), 1)),
			"slot": i,
			"offset_x_px": int(absi(h) % 24),
			"offset_y_px": int(absi(h >> 5) % 16),
			"loot": loot_point(node_id, point_id, day),
		})
	return points


# ════════════════════════════════════════════════════════════════
#  掉落（P16 的数学基础）
# ════════════════════════════════════════════════════════════════

## 掉落 = Rng.hash_at("LOOT", day, [loc_id, point_id]) → 查 loot_tables.json
## 顺序无关：先开 A 再开 B 与先 B 后 A，A/B 内容各自相同（P16）
## 本函数**无状态**——签名里没有"第几次开箱"，这是 P16 成立的结构前提。
func loot_point(loc_id: StringName, point_id: StringName, day: int) -> Array:
	_ensure_loaded()
	var table: Array = _loot.get(_theme_of(str(loc_id)), [])
	var total := float(_loot_total.get(_theme_of(str(loc_id)), 0.0))
	if table.is_empty() or total <= 0.0:
		return []
	var h := Rng.hash_at(&"LOOT", day,
		PackedStringArray([str(loc_id), str(point_id)]))
	# 低位定条目（权重抽取）
	var roll := float(absi(h) % 1000000) / 1000000.0 * total
	var acc := 0.0
	for e: Dictionary in table:
		acc += float(e.get("entry_weight_ratio", 0.0))
		if roll <= acc:
			return _roll_count(e, h)
	return []


## 数量区间：用再混一次的值定数量，与条目选择不共用位段，避免同一条永远同一数
func _roll_count(entry: Dictionary, h: int) -> Array:
	var item_id := str(entry.get("item_id", ""))
	if not _item_ids.has(item_id):
		return []          # 悬空引用 → 不产出，别让不存在的物品进背包
	var lo := int(entry.get("entry_min_count", 0))
	var hi := maxi(int(entry.get("entry_max_count", 0)), lo)
	if hi == lo:
		return [] if lo <= 0 else [{"item_id": item_id, "count": lo}]
	var pick := lo + int(absi(Rng.mix64(h)) % (hi - lo + 1))
	if pick <= 0:
		return []
	return [{"item_id": item_id, "count": pick}]


# ════════════════════════════════════════════════════════════════
#  回填（D4 起高频地点部分回填一次 · REFILL 子流）
# ════════════════════════════════════════════════════════════════

## 该地点在 day 当天是否处于「已回填」状态。
## 判据：high_freq == true 且 day >= refill_from_day_count 且 REFILL 命中。
## 每日至多回填一次（hash_at 是 day 的纯函数，天然不会一天命中两次）。
static func is_refilled(node_id: StringName, day: int) -> bool:
	_ensure_loaded()
	var node: Dictionary = _nodes.get(str(node_id), {})
	if node.is_empty() or not bool(node.get("high_freq", false)):
		return false
	if day < int(node.get("refill_from_day_count", 9999)):
		return false
	var h := Rng.hash_at(&"REFILL", day, PackedStringArray([str(node_id), "refill"]))
	return int(absi(h) % 3) == 0   # 约 1/3 命中（PROVISIONAL，见 UNDEFINED.md D-003）


## 跨日刷新「待回填」清单。**由每日 05:00 的跨日结算调用**（TimeSystem 的 day rollover）。
## 命中回填的高频地点进 _pending_refills，回填代数 +1；没命中的从清单里移除。
## 玩家进该地点时消费掉这次回填（mark_visited 里移除）。
##
## 为什么「回填后货架内容会变」不需要额外机制：LOOT 的哈希键是
## [loc_id, point_id]，而**跨天时 day 本身就变了** → 哈希变 → 内容变。
## （同一天内的二次回填不换内容——那要不要换，属未定义，缺数 D-B08。）
static func refresh_refills(day: int) -> void:
	_ensure_loaded()
	var next := PackedStringArray()
	for node_id: String in _nodes:
		if not is_refilled(StringName(node_id), day):
			continue
		next.append(node_id)
		var sec := _location_sec(node_id)
		sec["refill_generation"] = int(sec.get("refill_generation", 0)) + 1
	_pending_refills = next


## 当前待回填（玩家还没去）的地点
static func pending_refills() -> PackedStringArray:
	return _pending_refills.duplicate()


# ════════════════════════════════════════════════════════════════
#  存档挂接（D-009 · 蓝图见 data/schema/save.schema.json）
# ════════════════════════════════════════════════════════════════

const PERSIST_KEY := &"map"
const _Store = preload("res://src/core/state_store.gd")

## ⑤ 地图。current_node / unlocked_nodes 是数值路径型（已在 state_contract，
## writer = map_system），读写都过 State 单点源；locations（visited_days/looted/
## refill_generation）与 pending_refills 是容器型，存本地，不进 contract。
static func to_save() -> Dictionary:
	return {
		"current_node": str(State.read("map.current_node")),
		"unlocked_nodes": _unlocked_nodes(),
		"locations": _locations.duplicate(true),
		"pending_refills": Array(_pending_refills),
	}


static func from_save(snap: Dictionary) -> void:
	_locations = {}
	var raw: Variant = snap.get("locations", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for node_id: String in (raw as Dictionary):
			var sec: Dictionary = (raw as Dictionary)[node_id]
			_locations[node_id] = {
				"visited_days": _to_int_array(sec.get("visited_days", [])),
				"looted": _to_string_array(sec.get("looted", [])),
				"refill_generation": int(sec.get("refill_generation", 0)),
			}
	_pending_refills = _to_string_array(snap.get("pending_refills", []))
	var cs := _Store.ChangeSet.new(&"map_system", "load map progress")
	cs.setv("map.current_node", str(snap.get("current_node", "")))
	cs.setv("map.unlocked_nodes", _to_string_array(snap.get("unlocked_nodes", [])))
	State.apply(cs)


# ── 容器型运行状态 ──
static var _locations: Dictionary = {}       # node_id -> {visited_days[], looted[], refill_generation}
static var _pending_refills: PackedStringArray = PackedStringArray()

static func mark_visited(node_id: StringName, day: int) -> void:
	var sec := _location_sec(str(node_id))
	var days: Array = sec["visited_days"]
	if not days.has(day):
		days.append(day)
	# 玩家到了 = 这次回填被消费掉，从待回填清单里移除。
	# 不移除的话，待回填清单会一直挂着同一个地点，UI 会一直提示"有货可捡"。
	# （PackedStringArray 没有 erase()，用 find + remove_at）
	var idx := _pending_refills.find(str(node_id))
	if idx >= 0:
		_pending_refills.remove_at(idx)


static func mark_looted(node_id: StringName, point_id: StringName) -> void:
	var sec := _location_sec(str(node_id))
	var looted: Array = sec["looted"]
	if not looted.has(str(point_id)):
		looted.append(str(point_id))


static func is_looted(node_id: StringName, point_id: StringName) -> bool:
	var sec: Dictionary = _locations.get(str(node_id), {})
	var looted: Array = sec.get("looted", [])
	return looted.has(str(point_id))


static func _location_sec(node_id: String) -> Dictionary:
	if not _locations.has(node_id):
		_locations[node_id] = {"visited_days": [], "looted": [], "refill_generation": 0}
	return _locations[node_id]


static func _unlocked_nodes() -> PackedStringArray:
	var raw: Variant = State.read("map.unlocked_nodes")
	var out := PackedStringArray()
	if typeof(raw) == TYPE_ARRAY or typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for k: Variant in (raw as Array):
			out.append(str(k))
	return out


static func _to_int_array(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for x: Variant in (v as Array):
			out.append(int(x))
	return out


static func _to_string_array(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(v) == TYPE_ARRAY:
		for x: Variant in (v as Array):
			out.append(str(x))
	return out


# ════════════════════════════════════════════════════════════════
#  自检（M9 / P16 —— 判据本体在本文件内，不依赖别人的测试文件）
# ════════════════════════════════════════════════════════════════

## M9：同日重开 reopen_count 次，布局签名必须 reopen_count/reopen_count 全等。
## M9b（反向对照）：换一天签名必须变——否则 hash 没吃 day，是"恒等函数假绿"。
## P16：正序与逆序各开一遍同一组点，逐点内容必须逐一相等。
##   若谁把 loot_point 改回顺序消费流：正序 lp0=stream[0]、逆序 lp0=stream[n-1]，立刻红。
func verify_determinism(reopen_count: int = 20) -> Dictionary:
	_ensure_loaded()
	var probe_nodes := PackedStringArray(["supermarket", "residential", "metro"])
	var probe_day := 3

	var first := world_signature(probe_day, probe_nodes)
	var m9_equal := 0
	for _i in reopen_count:
		if world_signature(probe_day, probe_nodes) == first:
			m9_equal += 1
	var m9_day_separates := world_signature(probe_day + 1, probe_nodes) != first

	var pts := PackedStringArray(["lp0", "lp1", "lp2", "lp3", "lp4", "lp5"])
	var forward := _loot_sequence("supermarket", pts, probe_day, false)
	var reverse := _loot_sequence("supermarket", pts, probe_day, true)
	var p16_equal := 0
	var p16_nonempty := 0
	for p: String in pts:
		if forward[p] == reverse[p]:
			p16_equal += 1
		if not (forward[p] as String).is_empty() and (forward[p] as String) != "[]":
			p16_nonempty += 1

	return {
		"M9_reopen_total": reopen_count,
		"M9_reopen_equal": m9_equal,
		"M9_pass": m9_equal == reopen_count,
		"M9b_day_separates": m9_day_separates,
		"P16_points_total": pts.size(),
		"P16_points_equal": p16_equal,
		# 防空转护栏：P16 比的是「各点内容相等」。若所有点的内容都是空数组，
		# 「相等」是平凡成立——判据等于没测。**必须有非空内容，这条判据才算数。**
		"P16_nonempty_points": p16_nonempty,
		"P16_pass": p16_equal == pts.size() and p16_nonempty > 0,
		"REFILL_pending_count": _pending_refills.size(),
		"REFILL_pass": _refill_roundtrip_ok(),
	}


# ════════════════════════════════════════════════════════════════
#  P12 背包基线（跨域合成判据）
# ════════════════════════════════════════════════════════════════
#
## 任务书_逻辑组_包B §6：P12 = 「D8 基线：食物≥5 净水≥6 零件 15–25」。
##
## 这条是**合成判据**，不是单系统判据——它同时踩三个域：
##   地图（掉落内容 × 地点）× 背包（24 格容量上限）× 时间（D8 那天能跑几趟）
## 所以判据本体放 map_system（它掌握掉落与地点），**背包容量以参数注入**——
## 包 B 白名单禁止横向持有 InventorySystem 引用。
##
## 期望值（≥5 / ≥6 / 15–25）是**设计定稿**，写在判据里不取自被测代码。

## P12 判据本体
## plan_name: data/locations/scavenge_plans.json 里的计划名
## baseline_min_food / baseline_min_water / baseline_min_parts / baseline_max_parts
##   —— 期望值由调用方传入（判据不自己写死期望，免得"改实现=改判据"）
func verify_loot_baseline(plan_name: String, baseline_min_food: int,
		baseline_min_water: int, baseline_min_parts: int, baseline_max_parts: int) -> Dictionary:
	_ensure_loaded()
	var out := {}
	var plans := _read_dict(_PLAN_PATH)
	var plan: Dictionary = plans.get(plan_name, {})
	if plan.is_empty():
		out["P12_plan_found"] = false
		out["P12_pass"] = false
		return out
	out["P12_plan_found"] = true

	var target_day := int(plan.get("target_day", 8))
	var cap := int(plan.get("inventory_capacity_units", 24))
	var visits: Array = plan.get("visits", [])

	# ── 逐地点搜刮：每个掉落点的内容由 loot_point() 决定（位置无关 hash）──
	var tally := {}       # item_id -> 件数
	var used_slots := 0   # 背包占用（每件占 1 格）
	var dropped := 0      # 因背包满而丢弃的件数
	for v: Variant in visits:
		if not (v is Dictionary):
			continue
		var visit: Dictionary = v
		var node_id := str(visit.get("node_id", ""))
		var days := int(visit.get("days", 1))
		var want_points := int(visit.get("points_per_visit", 0))
		var layout := generate_layout(StringName(node_id), target_day)
		var points: Array = layout.get("loot_points", [])
		# 只能搜到实际存在的点（不能凭空多搜）
		var take := mini(want_points, points.size())
		for i in take:
			# ⚠ 字段名是 `id` 不是 `point_id`——写错会让所有点查不到东西，
			#   结果是 0 食物 0 净水 0 零件（判据会红，但"红得没道理"，
			#   排查时容易误判成"数值不对"而不是"代码取错字段"）。
			var pid := str((points[i] as Dictionary).get("id", ""))
			for entry: Variant in loot_point(StringName(node_id), StringName(pid), target_day):
				if not (entry is Dictionary):
					continue
				var e: Dictionary = entry
				var iid := str(e.get("item_id", ""))
				var n := int(e.get("count", 0))
				if n <= 0:
					continue
				# 背包容量约束：装不下的部分被丢弃（计入 dropped，不计入 tally）
				var room := cap - used_slots
				if room <= 0:
					dropped += n
					continue
				var fit := mini(room, n)
				dropped += n - fit
				tally[iid] = int(tally.get(iid, 0)) + fit
				used_slots += fit

	var food := int(tally.get("item_food_can", 0))
	var water := int(tally.get("item_water_bottle", 0))
	var parts := int(tally.get("item_parts", 0))

	out["P12_day"] = target_day
	out["P12_capacity"] = cap
	out["P12_used_slots"] = used_slots
	out["P12_dropped"] = dropped
	out["P12_food"] = food
	out["P12_water"] = water
	out["P12_parts"] = parts
	out["P12_food_ok"] = food >= baseline_min_food
	out["P12_water_ok"] = water >= baseline_min_water
	out["P12_parts_ok"] = parts >= baseline_min_parts and parts <= baseline_max_parts
	# 防空转护栏：背包一格都没满、什么都没捡到 → 判据是空的
	out["P12_nonempty"] = used_slots > 0
	# ★ 第二道护栏：点名目标物一件都没有 = 掉落链路断了（不是"数值偏低"）。
	#   只看 used_slots > 0 不够——捡到一堆杂物、背包满了、目标物 0 件，
	#   那也是空的判据（且"红得没道理"，容易误判成数值问题）。
	out["P12_has_target_loot"] = (food + water + parts) > 0
	out["P12_pass"] = bool(out["P12_food_ok"]) and bool(out["P12_water_ok"]) \
		and bool(out["P12_parts_ok"]) and bool(out["P12_nonempty"]) \
		and bool(out["P12_has_target_loot"])
	return out


## 回填闭环自检：05:00 刷新 → 待回填清单**恰好**等于当天的命中集合 → 玩家到了消费掉
## → 存档往返不丢。
## 这条判据抓的是「pending_refills 存了但没人写/没人清」——那种洞在 UI 上看不出来，
## 只会表现为"提示说有货，去了没货"或"永远提示有货"。
##
## ⚠ 断言**不能建立在"随机恰好命中"上**：第 4 天起 4 个高频地点各 1/3 概率，
##   一天全不中的概率约 20%——那种判据自己会随机红。
##   所以这里比的是「清单 == is_refilled() 的集合」，不是「清单非空」。
func _refill_roundtrip_ok() -> bool:
	var save_pending := _pending_refills.duplicate()
	var save_locations := _locations.duplicate(true)

	# ① 连续 10 天：清单必须逐天等于当天的命中集合
	var list_ok := true
	for day in range(4, 14):
		refresh_refills(day)
		var expected := PackedStringArray()
		for node_id: String in _nodes:
			if is_refilled(StringName(node_id), day):
				expected.append(node_id)
		expected.sort()
		var actual := _pending_refills.duplicate()
		actual.sort()
		if actual != expected:
			list_ok = false
		# ② 回填代数必须随命中次数递增
		for node_id: String in _nodes:
			var gen := int((_locations.get(node_id, {}) as Dictionary).get("refill_generation", 0))
			var want := 0
			for d in range(4, day + 1):
				if is_refilled(StringName(node_id), d):
					want += 1
			if gen != want:
				list_ok = false

	# ③ 玩家到了第一个待回填地点 → 消费掉
	var consumed := true
	if _pending_refills.size() > 0:
		var first := _pending_refills[0]
		mark_visited(StringName(first), 13)
		consumed = not _pending_refills.has(first)

	# ④ 存档往返：待回填清单与回填代数都不能丢
	var snap := to_save()
	var gen_before := int((_locations.get("supermarket", {}) as Dictionary).get("refill_generation", 0))
	_pending_refills = PackedStringArray()
	_locations = {}
	from_save(snap)
	var gen_after := int((_locations.get("supermarket", {}) as Dictionary).get("refill_generation", 0))
	var kept: bool = _pending_refills.size() == (snap.get("pending_refills", []) as Array).size()

	_pending_refills = save_pending
	_locations = save_locations
	return list_ok and consumed and kept and gen_before == gen_after


## 世界快照签名：day + 节点集合 → 全部布局与掉落内容的序列化。
## M9 的"快照哈希"就是它——生成是纯函数，签名必然逐字节相等。
func world_signature(day: int, nodes: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for n: String in nodes:
		parts.append("%s@d%d=%s" % [n, day, JSON.stringify(generate_layout(StringName(n), day))])
	return "|".join(parts)


func _loot_sequence(loc_id: String, pts: PackedStringArray, day: int, backwards: bool) -> Dictionary:
	var out := {}
	if backwards:
		for i in range(pts.size() - 1, -1, -1):
			out[pts[i]] = _loot_sig(loc_id, pts[i], day)
	else:
		for p: String in pts:
			out[p] = _loot_sig(loc_id, p, day)
	return out


func _loot_sig(loc_id: String, point_id: String, day: int) -> String:
	return JSON.stringify(loot_point(StringName(loc_id), StringName(point_id), day))


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func room_count(theme: Dictionary) -> int:
	return maxi(int(theme.get("layout_room_count", 0)), 1)


static func _theme_of(loc_id: String) -> String:
	return str((_nodes.get(loc_id, {}) as Dictionary).get("theme_id", ""))


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var loc := _read_dict(_LOC_PATH)
	_nodes = loc.get("nodes", {})
	_edges = loc.get("edges", [])
	_themes = _read_dict(_THEME_PATH)
	_loot = _read_dict(_LOOT_PATH)
	# ⚠ 只遍历**真正的主题表**（值是 Array 的键）。loot_tables.json 顶层还有
	#   $schema_note / $provisional / _comment_p16 这些字符串键——一并遍历会在
	#   `as Array` 处崩，**函数当场中断**，后面的 _loot_total 永远填不上，
	#   loot_point() 于是恒返回空数组 → P16「各点内容相等」变成**全空数组的平凡相等**，
	#   判据假绿。这是我自己的 bug，2026-10-21 由 P16 假绿倒查发现。
	for theme_id: String in _loot:
		var table: Variant = _loot[theme_id]
		if typeof(table) != TYPE_ARRAY:
			continue
		var total := 0.0
		for e: Dictionary in (table as Array):
			total += float(e.get("entry_weight_ratio", 0.0))
		_loot_total[theme_id] = total
	var defs: Dictionary = _read_dict(_ITEMS_PATH).get("items", {})
	for item_id: String in defs:
		_item_ids[item_id] = true


static func _read_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("map_system: %s missing" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("map_system: %s parse failed" % path)
		return {}
	return parsed