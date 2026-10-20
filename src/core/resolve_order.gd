extends Node
## resolve_order.gd — 同帧结算顺序硬约束（架构 §3.13，QA 契约 4）
##
## ── 为什么存在 ──
## QA 判据 M14：四条状态同帧归零，连跑 10 次死亡归因字符串必须 10/10 一致。
## 用 Dictionary 遍历序/哈希序结算会让同一份存档的归因漂移。
## 所以任何"同帧多源结算"必须按下表数组序执行——这是常量表，不是配置。
##
## ── 分包规则 ──
## 引用方只许 `for step in ResolveOrder.STATUS_RESOLVE_ORDER`，
## 禁止自己再写一份顺序、禁止 dict.keys() 代替。

## 状态条结算序（VitalsSystem 每 GH 边界调用）
const STATUS_RESOLVE_ORDER: PackedStringArray = [
	"hunger",            # 饥饿结算（先于渴——渴比饿快 40%，先扣快钟）
	"thirst",
	"hp_floor",          # 归零判定 → 死亡
	"status_effects",    # 出血等 buff
	"forced_sleep",      # 体力 5% 检测（最后，避免同帧既死又睡）
]

## 循环产线结算序（LoopSystem 每 GH 边界调用）
const LOOP_RESOLVE_ORDER: PackedStringArray = [
	"WATER", "FOOD", "POWER", "MEDS",
]

## 同帧多伤害源归因序（死亡归因字符串的唯一来源）
const DAMAGE_SOURCE_ORDER: PackedStringArray = [
	"starvation", "dehydration", "bleed", "bite", "wild_sleep",
]

## 05:00 / 06:00 跨日结算序（C16，QA M12b 的常量表）
const DAY_ROLLOVER_ORDER: PackedStringArray = [
	"day_increment",     # day += 1
	"save_autosave",     # 自动存档（先存后结算，保证可回滚到天起点）
	"production_tick",   # 循环产线结算隔夜产出
	"event_scheduled",   # 定时事件游标推进
	"spawn_refill",      # D4 起部分回填
]

## 破防随机目标选择（架构 v1.10：L1 强制要求——hash 派生 + 字典序）
## 用法：candidates 必须先按 facility_id 字典序排序再取模。
const BREACH_IMMUNE: PackedStringArray = [
	"dismantle_bench",   # 材料链唯一来源，破防不可拆（R11 缓解）
	"generator",         # 断电连锁下一夜全部 L3 与陷阱
	"door_main",
]
