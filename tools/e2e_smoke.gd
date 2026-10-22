extends Node
## e2e_smoke.gd — 真链路冒烟（TASK-G 灰盒闸门前自检）
##
## 与另两个测试入口的分工：
##   · tests/run_tests.gd —— 系统级判据（无场景）
##   · tools/ui_smoke.gd  —— 场景壳与面板（自造 SceneRouter，不走 boot）
##   · 本文件             —— **走真实入口**：真 boot → 真主菜单 → 点"新游戏" → 安全屋
##                           → 睡觉跳夜 → 总览图 → 超市
## 它抓的是"接线断了"这类问题：2026-10-22 就是它抓到「主菜单刚出现就点新游戏
## 会没反应」——ui_smoke 因为自己造路由器，永远碰不到那个时序。
##
## 用法：godot --headless --path . res://tools/e2e_smoke.tscn
## 退出码：0 全通 / 1 有失败。
##
## ⚠ 探针必须先把 `current_scene` 置 null：否则 boot 切主菜单时会把它 free 掉，
##   协程直接消失，表现为"什么都没打印就挂住"（踩过）。

var _fail := 0


func _ready() -> void:
	get_tree().current_scene = null
	var boot: Node = (load("res://scenes/boot/boot.tscn") as PackedScene).instantiate()
	get_tree().root.add_child.call_deferred(boot)
	await get_tree().process_frame

	var router := await _wait_router()
	var menu := await _wait_scene("MainMenu", 900)
	_check("boot reaches main menu", menu != null)
	if menu == null:
		_finish()
		return
	var t_menu := Time.get_ticks_msec()
	print("  [e2e] main menu at %d ms (G1 预算 5000)" % t_menu)
	# G1 在闸门上由老板亲验（含引擎冷启动与磁盘缓存）；这里只记录不判定，
	# 否则 CI 机器一冷就红，红得没道理。
	if t_menu > 5000:
		print("  [e2e] WARN: 冷启动超出 5s 预算（本机实测，需在目标机复核）")

	# 立刻点：此刻菜单很可能还在淡入，正是"点了没反应"的高发时刻
	menu._on_new_game()

	var house := await _wait_scene("Safehouse", 1200)
	_check("new game reaches the safehouse", house != null)
	if house == null:
		_finish()
		return
	await _wait_idle(router)
	print("  [e2e] safehouse at %d ms" % Time.get_ticks_msec())

	_check("player.scene_id is safehouse", str(State.read("player.scene_id")) == "safehouse")
	print("  [e2e] day=%d gh=%.2f hp=%.1f hunger=%.1f" % [
		int(State.read("time.day")), TimeSystem.gh_now(),
		float(State.read("player.hp")), float(State.read("player.hunger"))])
	# ⚠ 不能用 is_equal_approx 比 gh：跑到这里已经过了几帧（每帧 1/4320 GH），
	#   5.0002 对 5.0 会被判不等。用显式容差 0.05 GH（≈3.6 s）。
	_check("new game starts at D1 05:00 with full hp",
		int(State.read("time.day")) == 1
		and absf(TimeSystem.gh_now() - 5.0) <= 0.05
		and absf(float(State.read("player.hp")) - 100.0) <= 0.01)

	var bed := _find_zone(house, &"bed")
	_check("safehouse has a bed", bed != null)
	if bed != null:
		bed.trigger()
		await get_tree().process_frame
		await get_tree().process_frame
		_check("sleeping rolls over to D2 at 05:00",
			int(State.read("time.day")) == 2
			and TimeSystem.gh_elapsed_today() <= 0.05)

	var world := GameWorld.instance()
	_check("world is alive after sleeping", world != null)
	if world != null:
		await _goto(router, &"overview_map")
		_check("door reaches the overview map",
			String(router.current_scene_id()) == "overview_map")
		world.travel_to(&"supermarket")
		await _wait_idle(router)
		_check("traveling lands in the supermarket",
			String(router.current_scene_id()) == "supermarket")
		var market := get_tree().current_scene
		_check("supermarket has 12 loot zones and a zombie",
			market != null and market.has_method("loot_zone_ids")
			and (market.loot_zone_ids() as Array).size() == 12
			and _count_enemies(market) >= 1)
	_finish()


func _check(name: String, ok: bool) -> void:
	if ok:
		print("  PASS  %s" % name)
	else:
		_fail += 1
		print("  FAIL  %s" % name)


func _finish() -> void:
	print("--- e2e_smoke: %d fail ---" % _fail)
	get_tree().quit(0 if _fail == 0 else 1)


func _wait_router() -> SceneRouter:
	for _i in 600:
		await get_tree().process_frame
		var r := get_tree().root.get_node_or_null("SceneRouter") as SceneRouter
		if r != null:
			return r
	return null


func _wait_scene(name_prefix: String, frames: int) -> Node:
	for _i in frames:
		await get_tree().process_frame
		var cs := get_tree().current_scene
		if cs != null and String(cs.name).begins_with(name_prefix):
			return cs
	return null


func _wait_idle(router: SceneRouter) -> void:
	if router == null:
		return
	for _i in 900:
		await get_tree().process_frame
		if not router.is_transitioning():
			return


func _goto(router: SceneRouter, id: StringName) -> void:
	router.goto(id, {}, 0.0)
	await _wait_idle(router)


func _count_enemies(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is EnemyAvatar:
			c += 1
	return c


func _find_zone(n: Node, id: StringName) -> InteractionZone:
	for c in n.get_children():
		if c is InteractionZone and (c as InteractionZone).zone_id == id:
			return c
		var sub := _find_zone(c, id)
		if sub != null:
			return sub
	return null
