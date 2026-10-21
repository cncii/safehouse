extends RefCounted
## tests/test_map_loot.gd — 域判据：P12 背包基线（跨域合成） 【包 B 接线 · 2026-10-21】
##
## 判据本体：src/systems/map_system.gd 自检入口 verify_loot_baseline()。
## 判据定义来源：任务书_逻辑组_包B §6（P12：D8 基线 食物≥5 净水≥6 零件 15–25）。
## 引用版本：map_system.gd@2026-10-21。
##
## 这条是**跨域合成判据**：地图掉落 × 背包 24 格容量 × D8 出行计划。
## 计划表在 data/locations/scavenge_plans.json（PROVISIONAL——设计基线没给 D8 出行策略）。
##
## ⚠ 期望值（5 / 6 / 15–25）是**设计定稿**，从判据定义直接写死在这里，
##   不取自被测代码自算值——防恒真式（本项目已踩三次）。
##
## 能抓：背包容量约束失效（变异体：room 恒为 cap → 掉落量虚高）
##       夹紧方向反了（变异体：room 取负 → 全 0）
##       掉落点位 id 取错字段（→ 目标物一件没有）

const PLAN_NAME := "plan_d8_baseline"
const BASELINE_MIN_FOOD := 5
const BASELINE_MIN_WATER := 6
const BASELINE_MIN_PARTS := 15
const BASELINE_MAX_PARTS := 25


static func run(host) -> void:
	var ms = MapSystem.new()
	host.add_child(ms)

	var out: Dictionary = ms.verify_loot_baseline(PLAN_NAME,
		BASELINE_MIN_FOOD, BASELINE_MIN_WATER, BASELINE_MIN_PARTS, BASELINE_MAX_PARTS)

	host._t("MAP-P12-0 verify_loot_baseline() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["MAP-P12-food", "MAP-P12-water", "MAP-P12-parts"],
			"blocked: verify_loot_baseline() empty")
		ms.queue_free()
		return

	# ── 掉落链路通不通（防空转护栏）──
	# 只看 used_slots > 0 不够：捡一堆杂物把背包塞满、目标物 0 件，
	# 那也是空的判据（且"红得没道理"）。两条护栏都要。
	host._t("MAP-P12-loot non-empty (used %d slots, dropped %d)"
		% [int(out.get("P12_used_slots", -1)), int(out.get("P12_dropped", -1))],
		bool(out.get("P12_nonempty", false))
		and bool(out.get("P12_has_target_loot", false)))

	# ── P12 三项基线（任务书 §6 定稿）──
	host._t("MAP-P12-food D8 food %d >= %d"
		% [int(out.get("P12_food", -1)), BASELINE_MIN_FOOD],
		bool(out.get("P12_food_ok", false)))
	host._t("MAP-P12-water D8 water %d >= %d"
		% [int(out.get("P12_water", -1)), BASELINE_MIN_WATER],
		bool(out.get("P12_water_ok", false)))
	host._t("MAP-P12-parts D8 parts %d in [%d, %d]"
		% [int(out.get("P12_parts", -1)), BASELINE_MIN_PARTS, BASELINE_MAX_PARTS],
		bool(out.get("P12_parts_ok", false)))

	ms.queue_free()