extends RefCounted
## tests/test_task_g_flow.gd — 域判据：TASK-G 进入地点 + 搜刮 【包 B 接线 · 2026-10-22】
##
## 判据本体：src/systems/map_system.gd 自检入口 verify_enter_and_loot()。
## 判据定义来源：docs/tasks/任务书_灰盒主流程_TASK-G.md §3（逻辑组配合项①②进地点对接 +
##   拾取→背包）+ 设计基线 2.6（搜过即打空）。引用版本：map_system.gd@2026-10-22。
##
## 对着 DoD 的哪几条：G3（一天循环：出门→搜刮→回屋，无卡死）、
##   G4（同种子同日内容一致，M9 实机复跑）的前置部分。
##
## ★ 关键设计：超市点位数 **12 写死在判据里**（不取自被测代码）。
##   实测变异体 B：布局被截到 6 时，若期望值取自 layout 就会跟着变 6 → 永远绿。
##   写死才抓得住（实测 points_ok / layout_stable 双红）。
##
## 变异测试（2 个变异体各自被抓，无误伤）：
##   A：跳过 mark_looted（不写已搜标记）→ G_repeat_rejected / G_swept_to_zero 双红
##   B：loot_points 被截到 6 → G_points_ok / G_layout_stable 双红

const BLOCKED_IDS := ["G-enter", "G-points", "G-current", "G-loot", "G-repeat",
	"G-sweep", "G-boundary", "G-same-seed"]


static func run(host) -> void:
	var ms = MapSystem.new()
	host.add_child(ms)

	var out: Dictionary = ms.verify_enter_and_loot(8)
	host._t("G-0 verify_enter_and_loot() returned non-empty result", not out.is_empty())
	if out.is_empty():
		host._block(BLOCKED_IDS, "blocked: verify_enter_and_loot() empty")
		ms.queue_free()
		return

	# ── ① 进地点成功 + 布局齐全（超市 = 灰盒唯一地点）──
	host._t("G-enter enter_node(supermarket) ok, theme=%s, %d rooms"
		% [str(out.get("G_enter_theme", "?")), int(out.get("G_enter_rooms", -1))],
		bool(out.get("G_enter_ok", false)))

	# ── ② 点位数 == 定稿 12（独立基准，不取自 layout——防恒真式）──
	host._t("G-points supermarket loot points %d == %d (frozen anchor)"
		% [int(out.get("G_enter_points", -1)), int(out.get("G_points_expected", -1))],
		bool(out.get("G_points_ok", false))
		and bool(out.get("G_available_nonempty", false)))

	# ── ③ enter_node 写了 map.current_node ──
	host._t("G-current map.current_node == %s after entering"
		% str(out.get("G_current_node", "?")),
		bool(out.get("G_current_node_ok", false)))

	# ── ④ 拾取有非空内容（防空转：全空箱 = 掉落链路断了）──
	host._t("G-loot %d points yielded loot, %d empty"
		% [int(out.get("G_loot_nonempty_points", -1)),
			int(out.get("G_loot_empty_points", -1))],
		bool(out.get("G_loot_nonempty_ok", false)))

	# ── ⑤ 搜过即打空（防反复探箱刷随机）──
	host._t("G-repeat re-looting a taken point rejected", bool(out.get("G_repeat_rejected", false)))

	# ── ⑥ 全搜完后可用点归零，但布局本身不变（12 个点位仍在）──
	host._t("G-sweep swept all points -> %d available, layout still %d"
		% [int(out.get("G_available_after_sweep", -1)), int(out.get("G_points_expected", -1))],
		bool(out.get("G_swept_to_zero", false))
		and bool(out.get("G_layout_stable", false)))

	# ── ⑦ 边界：安全屋可进但无搜刮物；未知节点被拒 ──
	host._t("G-boundary safehouse enterable-without-loot; unknown node rejected",
		bool(out.get("G_home_ok", false))
		and bool(out.get("G_unknown_rejected", false)))

	# ── ⑧ 同种子同日内容一致（G4 前置）──
	host._t("G-same-seed same day re-enter yields byte-equal loot signature (%d chars)"
		% int(out.get("G_signature_len", -1)),
		bool(out.get("G_same_seed_same_content", false))
		and int(out.get("G_signature_len", 0)) > 0)

	ms.queue_free()