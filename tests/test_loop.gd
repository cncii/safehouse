extends RefCounted
## tests/test_loop.gd — 域判据：循环收支 【包 F · W2 判据移植】
##
## 判据定义来源：loop_system.gd 文件头契约（P13/P20/M32/S7-b/P22-0）+ 任务书_逻辑组_包B §6。
## 判据本体：LoopSystem.verify_loop_balance()。
## 引用版本：loop_system.gd@2026-10-20。
##
## ⚠ 2026-10-20 实测：loop_system.gd 存在编译失败（compile_sweep 抓到：
##   :368 Cannot infer the type of "save_level"，无类型容器元素 + := 推断失败，
##   归属包 B 逻辑组，已列入欠件）。在它修好之前，本域全部判据按 _block 判红——
##   「机制存在即在运行」：编译失败 ≠ 通过，也不许静默跳过。

const LOOP_SCRIPT := "res://src/systems/loop_system.gd"
const BLOCKED_IDS := ["LOOP-S7b", "LOOP-M32", "LOOP-P13", "LOOP-P20", "LOOP-P22-0"]


static func run(host) -> void:
	var sc = load(LOOP_SCRIPT)
	# ⚠ 坏脚本（Parse Error）的 GDScript 对象：非 null，但**连 new() 都没有**——
	# 用 new() 探测会抛 "Nonexistent function 'new'" 把本函数截断（A 组缺陷 A 同款坑，
	# 首跑实测：loop 域 5 条 blocked 一条没记上账）。必须先查方法清单（坏脚本为空），
	# 确认能 new 了才 new。
	var usable: bool = sc != null \
		and (sc.get_script_method_list() as Array).size() > 0
	if not usable:
		host._block(BLOCKED_IDS,
			"blocked: loop_system.gd does not compile (deferred to package B, see handover list in docs)")
		return
	var ls = sc.new()
	host.add_child(ls)
	var out: Dictionary = ls.verify_loop_balance()
	host._t("LOOP-0 verify_loop_balance() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(BLOCKED_IDS, "blocked: verify_loop_balance() empty")
		ls.free()
		return

	host._t("LOOP-S7b margin_days_water == frozen anchor (+-0.01)", bool(out.get("S7b_pass", false)))
	host._t("LOOP-M32 Lv2 7-day output < demand (deficit stage, no surplus)", bool(out.get("M32_pass", false)))
	host._t("LOOP-P13 three-tier efficiency conservation", bool(out.get("P13", false)))
	host._t("LOOP-P20 countdown uses net gap not gross stock", bool(out.get("P20_pass", false)))
	host._t("LOOP-P22-0 dismantle_bench immune to breach targeting", bool(out.get("P22_pass", false)))

	# ── 破防目标选择与候选传入顺序无关（M30/M19 类确定性断言，修订 #8）──
	# 判据定义来源：loop_system.gd pick_breach_target 注释（候选先按 facility_id 字典序
	# 排序再取模——「建造顺序是玩家行为不是种子，不排序 = 重开能刷一个不疼的结果」）。
	# 这条是 V5 变异体（破防候选不排序）的目标判据：变异删掉 sort() 后本条必红。
	# 候选全部为非免疫设施（dismantle_bench 在 BREACH_IMMUNE 内，会被剔除，不用于本判据）。
	var cands := PackedStringArray(["generator", "food", "mushroom_bed", "door_panel", "water"])
	var base: String = ls.pick_breach_target(cands, 8, 7)
	var order_independent := base != ""
	var perms := [
		["water", "generator", "food", "mushroom_bed", "door_panel"],
		["mushroom_bed", "water", "door_panel", "generator", "food"],
		["door_panel", "mushroom_bed", "generator", "water", "food"],
		["food", "door_panel", "water", "mushroom_bed", "generator"],
	]
	for perm: Array in perms:
		if String(ls.pick_breach_target(PackedStringArray(perm), 8, 7)) != base:
			order_independent = false
			break
	host._t("LOOP-BREACH breach target choice is candidate-order independent",
		order_independent)
	ls.free()
