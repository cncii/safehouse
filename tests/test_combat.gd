extends RefCounted
## tests/test_combat.gd — 域判据：波次物化确定性 【包 F · W2 判据移植】
##
## 判据定义来源：combat_system.gd 文件头契约（M19：wave_plan 物化 18:00±1帧，
## 实际生成与 plan 逐项相等、零顺序消费）/ 任务书_战斗组_包CE §6。
## 判据本体：CombatSystem.verify_plan_deterministic()（物化两次逐项比对）。
## 引用版本：combat_system.gd@2026-10-20（waves.json/enemies.json 为数据源）。
##
## R5（手感）与 M23 端到端不在此列：R5 需真人连打 10 场（周报 review 项）。

const PROBE_NIGHT := 1
const PROBE_DAY := 8   # 阶段B 第 1 夜（day 8 起）


static func run(host) -> void:
	var cs = CombatSystem.new()
	host.add_child(cs)

	var out: Dictionary = cs.verify_plan_deterministic(PROBE_NIGHT, PROBE_DAY)
	# 空跑判负：返回空 = 判据没跑
	host._t("COMBAT-0 verify_plan_deterministic() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(["COMBAT-M19-equal", "COMBAT-M19-slots", "COMBAT-M19-hash"],
			"blocked: verify_plan_deterministic() empty")
		cs.free()
		return

	# ── M19：物化两次逐项相等（slots + plan_hash）──
	host._t("COMBAT-M19 double materialization item-by-item equal", bool(out.get("equal", false)))

	# ── M19 空跑判负：物化 0 slot 说明数据空，"相等"无意义（三层空跑判负）──
	host._t("COMBAT-M19 materialized slot_count > 0 (else the comparison is void)",
		int(out.get("slot_count", 0)) > 0)

	# ── M19 plan_hash 稳定且非零（P7 读档重算比对的锚点；0 = hash 链断了）──
	host._t("COMBAT-M19 plan_hash stable and non-zero",
		int(out.get("plan_hash", 0)) != 0)

	cs.free()
