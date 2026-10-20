class_name SpawnService
extends Node
## spawn_service.gd — 生成服务 【分包：包 C·事件与战斗组】
##
## ── 职责 ──   消费 CombatSystem 物化好的 wave_plan slot 清单生成实体；同屏敌人上限管理
## ── 不做 ──   不掷骰（参数全部来自 plan/table，是纯消费者——M19 判据的前提）；
##              不自己读 waves.json 改 plan（物化唯一入口在 CombatSystem）；
##              不管理 AI 行为（在 enemy 场景内）
## ── 数据 ──   消费 CombatSystem.wave_plan()；敌人属性权威源 data/enemies/enemies.json
## ── 判据 ──   M19(实际生成清单与 plan 逐项相等) γ采样点(波次构成 20/20 全等)
##
## ── 硬约束 ──
## · max_alive = 40 硬上限（性能预算 #3）：超出进队列不生成——
##   不是删实体，"敌人凭空消失"比掉帧更糟
## · 环境敌人分布：进入地点瞬间按槽位 hash 整段预生成，之后不再消费（C14/C15）
## · batch 语义：count 是上限不是硬生成数，实际取 min(count, pool_remaining)
## · 零顺序消费：生成顺序只影响"先出哪个"，不影响"出哪些"——清单本身由 plan 定死

const MAX_ALIVE := 40

var _alive: Array = []
var _queued: Array = []          # 超上限待生成（不丢实体，只延后）

## 消费 CombatSystem 物化的 wave_plan，按清单逐项生成。
## 返回实际生成的 slot 下标数组——与 plan 逐项相等即 M19 通过（调用方比对）。
func spawn_from_plan(plan: Dictionary, day: int, anchor: Vector2 = Vector2.ZERO) -> Array:
	var spawned: Array = []
	var slots: Array = plan.get("slots", [])
	for s_variant: Variant in slots:
		var s: Dictionary = s_variant
		if _alive.size() >= MAX_ALIVE:
			_queued.append(s)      # 进队列不生成——QA P 判据（不是删实体）
			continue
		_alive.append(s.get("enemy_id", ""))
		spawned.append({
			"batch": int(s.get("batch", 0)),
			"slot": int(s.get("slot", 0)),
			"enemy_id": String(s.get("enemy_id", "")),
			"entry_point": String(s.get("entry_point", "")),
			"hp": float(s.get("hp", 0.0)),
			"damage": float(s.get("damage", 0.0)),
			"anchor": anchor,
			# slot_variant 来自 plan 的槽位 hash，仅表现层抖动，不参与 L1 判定
			"slot_variant": int(s.get("slot_variant", 0)),
		})
	return spawned

## 敌人死亡后释放同屏位，并从队列补一个（补的是哪一项由队列顺序固定，非随机）
func release(alive_count: int) -> Array:
	_alive.resize(maxi(0, alive_count))
	var refilled: Array = []
	while _alive.size() < MAX_ALIVE and not _queued.is_empty():
		var s: Dictionary = _queued.pop_front()
		_alive.append(s.get("enemy_id", ""))
		refilled.append(s)
	return refilled

func alive_count() -> int:
	return _alive.size()

func queued_count() -> int:
	return _queued.size()

func clear() -> void:
	_alive.clear()
	_queued.clear()

## 兼容旧调用点（事件 spawn 能力 EffectSink kind="spawn"）：按 table_id 走同一零顺序消费路径
func spawn(table_id: StringName, count: int, anchor: Vector2, day: int, slot: int) -> Array:
	var spawned: Array = []
	for i in range(count):
		if _alive.size() >= MAX_ALIVE:
			break   # 进队列不生成——QA P 判据
		# 敌人参数 = Rng.hash_at(SPAWN_WAVE, day, [str(slot), str(i)]) → 查表
		# 注意：是按槽位 hash，不是顺序流——零顺序消费（架构 v1.2 C14）
		spawned.append({"table_id": String(table_id), "slot": i, "anchor": anchor})
	return spawned
