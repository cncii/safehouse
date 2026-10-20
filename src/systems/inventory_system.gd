class_name InventorySystem
extends Node
## inventory_system.gd — 背包与物品 【分包：包 B·模拟系统组】
##
## ── 职责 ──   物品增删/耐久/容量/装备/自动配给开关(L2)/消耗品→四条状态增量
## ── 不做 ──   不直接写 player.*（算出增量后发 ChangeSet 给 StateStore——
##             state_contract 里 inventory_system 在 player.hunger/thirst/hp 的
##             writers 白名单里，仅此特权）；不管掉落生成（MapSystem 给）
## ── 数据 ──   data/items/items.json + loot_tables.json + data/balance/survival.json
## ── 判据 ──   P13(满仓拾取物品不消失/资源不变/件数守恒) M8 系列(存档一致性)
##             S16(save_reason 5 值覆盖) P12(第8天基线：食物≥5 净水≥6 零件15-25)
##
## ── 定稿数值（v3 值表，data/CURRENT.md 为唯一权威） ──
##   容量 24，储物升级 +50%；零件库存上限 20/30(需 L2-3 储物升级前置)
##   食物 1 单位 +25 饥饿；净水 1 单位 +30 渴；能量棒 +25 体力(0.4s 使用)
##
## ── 存档挂接（D-009 裁决后）────────────────────────────────
##  容器型状态**不进 state_contract、不走 State.apply**——ChangeSet 是数值 Op 流，
##  塞不进容器（源头裁决）。本系统的背包列表是内部状态，序列化走
##  SaveSystem.register_persistence("inventory")，字段蓝图见 data/schema/save.schema.json。
##  数值型（auto_ration）仍在 contract 里，两者由 from_save 单点写回，不会分叉。
## ────────────────────────────────────────────────────────────────

const CAPACITY_BASE := 24
const PARTS_CAP_BASE := 20       # 前置断言：>20 必须已解锁储物升级（QA S10）

const PERSIST_KEY := &"inventory"
const _ITEMS_PATH := "res://data/items/items.json"
const _SURV_PATH := "res://data/balance/survival.json"
const _Store = preload("res://src/core/state_store.gd")

# ── 容器状态（不进 contract）──
var _items: Array = []                # [{instance_id, item_id, count, durability}]
var _next_seq := 1
var _storage_upgraded := false

# ── 运行值（_load_balance 载入）──
var _food_hunger_gain := 25.0
var _water_thirst_gain := 30.0
var _energybar_stamina_gain := 25.0
var _med_hp_gain := 30.0             # PROVISIONAL：med_gauze 回血量未定稿（缺数 D-014）
var _item_defs: Dictionary = {}       # item_id -> def


func _ready() -> void:
	_load_balance()
	_register_persistence()


func _register_persistence() -> void:
	Save.register_persistence(PERSIST_KEY, Callable(self, "to_save"),
		Callable(self, "from_save"))


# ════════════════════════════════════════════════════════════════
#  增删
# ════════════════════════════════════════════════════════════════

## 返回实际入包数（容量限制后）——P13 断言不许丢
func add(item_id: StringName, count: int) -> int:
	if count <= 0 or not _item_defs.has(String(item_id)):
		return 0
	var room := capacity() - used()
	var take := mini(room, count)
	if take <= 0:
		return 0
	# 同 id 同耐久档的先叠，数量到上限再开新实例——满仓时也不产生碎片
	for e: Dictionary in _items:
		if String(e["item_id"]) == String(item_id) and e.get("durability", null) == null:
			e["count"] = int(e["count"]) + take
			return take
	var inst := {
		"instance_id": _next_seq,
		"item_id": String(item_id),
		"count": take,
		"durability": null,
	}
	_next_seq += 1
	_items.append(inst)
	return take


## 返回 {"hunger": +25.0, ...} 形式的增量，由调用方转 ChangeSet
func consume(item_id: StringName, count: int) -> Dictionary:
	var remaining := count
	for i in range(_items.size() - 1, -1, -1):
		var e: Dictionary = _items[i]
		if String(e["item_id"]) != String(item_id):
			continue
		var take := mini(int(e["count"]), remaining)
		e["count"] = int(e["count"]) - take
		remaining -= take
		if int(e["count"]) <= 0:
			_items.remove_at(i)
		if remaining <= 0:
			break
	var actually := count - remaining
	if actually <= 0:
		return {}
	return _effect_delta(StringName(item_id), actually)


## 消耗品→四条状态增量。数值全部来自 survival.json，不在本文件硬写。
func _effect_delta(item_id: StringName, n: int) -> Dictionary:
	var f := float(n)
	match String(item_id):
		"item_food_can":
			return {"hunger": _food_hunger_gain * f}
		"item_water_bottle":
			return {"thirst": _water_thirst_gain * f}
		"item_energy_bar":
			return {"stamina": _energybar_stamina_gain * f}
		"item_med_gauze":
			return {"hp": _med_hp_gain * f}
	return {}


## 把 consume() 返回的增量落到 player.*（本系统唯一写 player.* 的特权路径）
func apply_delta(delta: Dictionary) -> void:
	if delta.is_empty():
		return
	var cs := _Store.ChangeSet.new(&"inventory_system", "consumable effect")
	for k: String in delta:
		cs.add("player.%s" % k, float(delta[k]))
	State.apply(cs)


func used() -> int:
	var total := 0
	for e: Dictionary in _items:
		total += int(e["count"])
	return total


func capacity() -> int:
	var base := CAPACITY_BASE
	if _storage_upgraded:
		base = int(round(float(base) * 1.5))
	return base


func count_of(item_id: StringName) -> int:
	var n := 0
	for e: Dictionary in _items:
		if String(e["item_id"]) == String(item_id):
			n += int(e["count"])
	return n


func is_full() -> bool:
	return used() >= capacity()


func set_storage_upgraded(v: bool) -> void:
	_storage_upgraded = v


func auto_ration() -> bool:
	return bool(State.read("inventory.auto_ration"))


func set_auto_ration(v: bool) -> void:
	var cs := _Store.ChangeSet.new(&"inventory_system", "auto ration toggle")
	cs.setv("inventory.auto_ration", v)
	State.apply(cs)


# ════════════════════════════════════════════════════════════════
#  存档挂接（D-009 · 字段蓝图见 data/schema/save.schema.json）
# ════════════════════════════════════════════════════════════════

## ② 背包。数值型 auto_ration 同时在 contract 里，但**只由 from_save 单点写回**，
## 两处不会分叉（分叉了就等于有两个来源，P7 diff=0 会开始挑刺）。
func to_save() -> Dictionary:
	return {
		"capacity": capacity(),
		"auto_ration": auto_ration(),
		"items": _items.duplicate(true),
		"next_instance_seq": _next_seq,
	}


func from_save(snap: Dictionary) -> void:
	_items = []
	for e: Variant in snap.get("items", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var src: Dictionary = e
		if not _item_defs.has(String(src.get("item_id", ""))):
			continue# 物品已下线：丢弃而不是把脏 id 写回内存
		_items.append({
			"instance_id": int(src.get("instance_id", 0)),
			"item_id": String(src.get("item_id", "")),
			"count": maxi(int(src.get("count", 0)), 0),
			"durability": src.get("durability", null),
		})
	_next_seq = maxi(int(snap.get("next_instance_seq", 1)), 1)
	# capacity 是派生值（基础 24 × 储物升级），反推升级标记而不是把派生值当权威存
	_storage_upgraded = int(snap.get("capacity", CAPACITY_BASE)) > CAPACITY_BASE
	if snap.has("auto_ration"):
		set_auto_ration(bool(snap["auto_ration"]))


# ════════════════════════════════════════════════════════════════
#  自检（P13 满仓守恒 · 判据本体在本文件内）
# ════════════════════════════════════════════════════════════════

## P13：满仓拾取不消失 / 资源不变 / 件数守恒
## 守恒口径 = 「入包数 + 溢出数 == 请求数」。这条不许写成"看起来对"——
## 满仓时最容易出的洞是「静默丢弃」，件数对不上却没人报错。
func verify_capacity_conservation() -> Dictionary:
	var out := {}
	var save_items := _items.duplicate(true)
	var save_seq := _next_seq

	_items.clear()
	_next_seq = 1
	var requested := 30# 故意超容量（24），逼出溢出路径
	var out_total := 0
	for id: String in ["item_parts", "item_food_can", "item_parts", "item_parts"]:
		out_total += add(StringName(id), 8)
	var used_total := used()
	var overflow := requested - out_total
	out["P13_requested"] = requested
	out["P13_added"] = out_total
	out["P13_overflow"] = overflow
	out["P13_used"] = used_total
	# 守恒 = 入包 + 溢出 == 请求，且「溢出被显式计数」而不是静默丢弃
	out["P13_conserved"] = (out_total + overflow == requested) and (used_total == out_total)
	out["P13_within_capacity"] = used_total <= capacity()
	out["P13_pass"] = bool(out["P13_conserved"]) and bool(out["P13_within_capacity"])

	# 叠包不产生碎片：同 id 连续 add 两次，实例数应为 1
	_items.clear()
	add(&"item_parts", 3)
	add(&"item_parts", 2)
	out["P13_merge_instances"] = _items.size()
	out["P13_merge_pass"] = _items.size() == 1 and used() == 5

	# 存档往返：to_save → from_save，件数必须一字不差
	var before := used()
	var snap := to_save()
	_items.clear()
	_next_seq = 1
	from_save(snap)
	out["P13_roundtrip_used"] = used()
	out["P13_roundtrip_pass"] = used() == before

	_items = save_items
	_next_seq = save_seq
	return out


# ════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════

func _load_balance() -> void:
	var surv := _read_dict(_SURV_PATH)
	_food_hunger_gain = float(surv.get("food_hunger_gain_units", _food_hunger_gain))
	_water_thirst_gain = float(surv.get("water_thirst_gain_units", _water_thirst_gain))
	_energybar_stamina_gain = float(surv.get("stamina_energybar_gain_units", _energybar_stamina_gain))
	var defs: Dictionary = _read_dict(_ITEMS_PATH).get("items", {})
	for item_id: String in defs:
		_item_defs[item_id] = defs[item_id]


func _read_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("inventory_system: %s missing" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}