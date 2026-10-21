extends RefCounted
## tests/test_inventory.gd — 域判据：背包容量守恒 【包 B 接线 · 2026-10-21】
##
## 判据本体：src/systems/inventory_system.gd 自检入口 verify_capacity_conservation()。
## 判据定义来源：任务书_逻辑组_包B §6（背包 P12/P13）+ inventory_system.gd 文件头。
## 引用版本：inventory_system.gd@2026-10-21。
##
## ⚠ 与 test_loop.gd 的 `LOOP-P13` **不是同一条判据**：
##   LOOP-P13 测的是 loop 的三段效率（未满/溢出/超软上限）；
##   本文件的 P13 测的是**背包容量守恒**（满仓不超吃、溢出被计数、叠包不碎片）。
##   同名不同物——别把看到 LOOP-P13 就以为背包守恒已覆盖。
##
## 能抓：add() 夹紧失效（变异体 1：满仓多吃 8 件 → within_capacity 红）
##       叠包条件破坏（变异体 2：同 id 开新实例 → merge_instances 红）
##       存档往返丢件（to_save/from_save 不一致 → roundtrip 红）

const BLOCKED_IDS := ["INV-P13-conserved", "INV-P13-capacity",
	"INV-P13-merge", "INV-P13-roundtrip"]


static func run(host) -> void:
	var iv = InventorySystem.new()
	host.add_child(iv)

	var out: Dictionary = iv.verify_capacity_conservation()
	# 空跑判负：结果为空 = 判据没跑（比"跑了个寂寞"更早暴露）
	host._t("INV-0 verify_capacity_conservation() returned non-empty result",
		not out.is_empty())
	if out.is_empty():
		host._block(BLOCKED_IDS, "blocked: verify_capacity_conservation() empty")
		iv.queue_free()
		return

	# ── P13-1 满仓守恒：入包 + 溢出 == 请求，且 used == 入包（溢出不是静默丢弃）──
	host._t("INV-P13-conserved requested=%d = added %d + overflow %d"
		% [int(out.get("P13_requested", -1)), int(out.get("P13_added", -1)),
			int(out.get("P13_overflow", -1))],
		bool(out.get("P13_conserved", false)))
	# ⚠ 守恒式里的 overflow 是算出来的（requested - added），夹紧坏掉时它会自洽——
	#   变异体 1 实测 P13_conserved 仍为 true。**真正抓住夹紧失效的是下面这条**。
	host._t("INV-P13-capacity used %d <= capacity (clamp holds)"
		% int(out.get("P13_used", -1)),
		bool(out.get("P13_within_capacity", false))
		and bool(out.get("P13_pass", false)))
	# ── P13-2 叠包不产生碎片：同 id 叠两次 → 1 个实例、5 件 ──
	host._t("INV-P13-merge same-id stacks merge into 1 instance (got %d)"
		% int(out.get("P13_merge_instances", -1)),
		bool(out.get("P13_merge_pass", false)))
	# ── P13-3 存档往返：件数字节级不差 ──
	host._t("INV-P13-roundtrip save/load preserves item count (%d)"
		% int(out.get("P13_roundtrip_used", -1)),
		bool(out.get("P13_roundtrip_pass", false)))

	iv.queue_free()