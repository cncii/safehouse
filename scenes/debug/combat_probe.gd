extends Node
## combat_probe.gd — 战斗组无头验证入口（**场景方式**，非 -s 脚本）
##
## 为什么不用 `-s`（实测根因，勿删这段注释）：
##   `-s` 直接实例化脚本，此时 autoload 节点尚未挂到 root，且 autoload **名字在编译期
##   不可解**——写 `State.read(...)` 会报 "Identifier not found"。
##   只有 **const** 能用（`ResolveOrder.DAMAGE_SOURCE_ORDER` / `GameLoop.FRAMES_*`），
##   这正是 run_tests.gd 里那些能跑的原因，它从没真正调用过 autoload 实例方法。
##   全项目凡引用 `State.apply/read` 的脚本（vitals/combat/inventory…）都无法 `-s`。
##   → 故改用场景方式：正常加载工程 → autoload 全部就位 → 跑断言 → quit(退出码)。
##
## 用法：godot --headless --quit-after 300 res://scenes/debug/combat_probe.tscn
##       或直接跑本场景（Project Settings → Run Main Scene 临时指到本场景）。

const _CombatScript := preload("res://src/systems/combat_system.gd")
const _SpawnScript   := preload("res://src/systems/spawn_service.gd")

var _pass := 0
var _fail := 0
var _failures: PackedStringArray = []

var _combat: CombatSystem
var _spawner: SpawnService

func _ready() -> void:
	# autoload 在此已就位（场景方式的核心好处）
	_rng_ready()
	_combat = _CombatScript.new()
	add_child(_combat)
	_spawner = _SpawnScript.new()
	add_child(_spawner)
	_combat.debug_reset_vitals()

	_run_all()
	_finish()

func _rng_ready() -> void:
	var rng := get_node_or_null("/root/Rng")
	if rng != null and rng.has_method("setup"):
		rng.setup(20261020)

func _t(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		_failures.append(name)
		print("  FAIL  %s" % name)

func _run_all() -> void:
	_test_guard()
	_test_w1_state_machine()
	_test_w1_iframe()
	_test_w2_materialize()
	_test_w2_determinism()
	_test_w2_batches()
	_test_w2_spawn_consume()
	_test_breach()

# ── 空跑判负守卫（包 F 教训：空表假绿）──
func _test_guard() -> void:
	var rng := get_node_or_null("/root/Rng")
	_t("guard: autoload Rng present", rng != null)
	_t("guard: autoload State present", get_node_or_null("/root/State") != null)
	_t("guard: rng salts loaded", rng != null and int(rng.hash_at(&"SPAWN_WAVE", 8, ["p"])) != 0)
	_t("guard: vitals initialized", float(State.read("player.hp")) > 0.0)

func _test_w1_state_machine() -> void:
	_combat.debug_reset_combat()
	_combat.debug_reset_vitals()
	_combat.player_dodge(Vector2.RIGHT)
	var busy := _combat.player_attack(Vector2.RIGHT)
	_t("w1: attack rejected while dodging", (not bool(busy.get("ok", true))) and String(busy.get("reason","")) == "busy")
	for i in range(TimeSystem.IFRAMES_TICKS + TimeSystem.RECOVERY_TICKS + 1):
		_combat.tick()
	var before := float(State.read("player.stamina"))
	var atk := _combat.player_attack(Vector2.RIGHT)
	var after := float(State.read("player.stamina"))
	_t("w1: attack accepted when idle", bool(atk.get("ok", false)))
	_t("w1: attack costs exactly stamina_attack", is_equal_approx(before - after, _combat.stamina_attack()))
	_t("w1: windup == TimeSystem.WINDUP_TICKS (C28)", int(atk.get("windup", -1)) == TimeSystem.WINDUP_TICKS)

func _test_w1_iframe() -> void:
	_combat.debug_reset_combat()
	_combat.debug_reset_vitals()
	_t("w1: dodge accepted from idle", bool(_combat.player_dodge(Vector2.RIGHT).get("ok", false)))
	_t("w1: iframe active after dodge", _combat.is_iframe_active())
	var hp0 := float(State.read("player.hp"))
	var blocked := _combat.on_hit_received(12.0)
	_t("w1: hit inside iframe blocked", bool(blocked.get("blocked", false)) and float(blocked.get("damage", -1.0)) == 0.0)
	_t("w1: hp unchanged inside iframe", is_equal_approx(hp0, float(State.read("player.hp"))))
	for i in range(TimeSystem.IFRAMES_TICKS + 2):
		_combat.tick()
	var landed := _combat.on_hit_received(12.0)
	_t("w1: hit after iframe lands with hitstun", (not bool(landed.get("blocked", true))) and int(landed.get("hitstun", -1)) == TimeSystem.HITSTUN_TICKS)
	_t("w1: hp reduced after iframe", float(State.read("player.hp")) < hp0)

func _test_w2_materialize() -> void:
	var p1 := _combat.materialize_wave_plan(1, 8)
	var s1: Array = p1.get("slots", [])
	_t("w2: night1 non-empty", s1.size() > 0)
	_t("w2: night1 slot total == 5", s1.size() == 5)
	_t("w2: night1 batch_count == 2", int(p1.get("batch_count", 0)) == 2)
	_t("w2: materialized_gh == 18.0 (M19 anchor)", is_equal_approx(float(p1.get("materialized_gh", -1.0)), 18.0))
	var fields_ok := true
	var hp_ok := true
	for s_variant: Variant in s1:
		var s: Dictionary = s_variant
		for k in ["batch", "slot", "enemy_id", "entry_point", "hp", "damage"]:
			if not s.has(k):
				fields_ok = false
		if float(s.get("hp", 0.0)) <= 0.0:
			hp_ok = false
	_t("w2: every slot has full field set", fields_ok)
	_t("w2: every slot resolved hp>0 (enemy table hit)", hp_ok)
	var p7 := _combat.materialize_wave_plan(7, 14)
	_t("w2: night7 slot total == 15", (p7.get("slots", []) as Array).size() == 15)
	_t("w2: night1 strength == 1.0", is_equal_approx(float(p1.get("strength_multiplier", 0.0)), 1.0))
	_t("w2: night7 strength == 2.32", is_equal_approx(float(p7.get("strength_multiplier", 0.0)), 2.32))
	_t("w2: unknown night -> empty plan, no crash", (_combat.materialize_wave_plan(99, 99).get("slots", []) as Array).is_empty())

func _test_w2_determinism() -> void:
	var det := _combat.verify_plan_deterministic(1, 8)
	_t("w2(M19): same night/day item-wise equal", bool(det.get("equal", false)))
	_t("w2(M19): slot count stable == 5", int(det.get("slot_count", 0)) == 5)
	var h8 := int(_combat.materialize_wave_plan(1, 8).get("plan_hash", 0))
	var h9 := int(_combat.materialize_wave_plan(1, 9).get("plan_hash", 0))
	_t("w2: plan_hash differs across days", h8 != h9)
	_t("w2: plan_hash stable within same day", h8 == int(_combat.materialize_wave_plan(1, 8).get("plan_hash", 0)))

func _test_w2_batches() -> void:
	var plan := _combat.begin_wave(1, 8)
	_t("w2: begin_wave sets wave_active", _combat.wave_active)
	_t("w2: pool_remaining == slot total", _combat.pool_remaining == (plan.get("slots", []) as Array).size())
	_t("w2: not cleared before kills", not _combat.is_wave_cleared())
	_combat.on_enemy_killed(0); _combat.on_enemy_killed(0); _combat.on_enemy_killed(0)
	_t("w2: batch0 done but batch1 pending -> not cleared", not _combat.is_wave_cleared())
	_combat.on_enemy_killed(1); _combat.on_enemy_killed(1)
	_t("w2: all batches killed -> cleared", _combat.is_wave_cleared())
	var bp := _combat.batches_progress()
	_t("w2: batches_progress == 2/2", int(bp.get("done", 0)) == 2 and int(bp.get("total", 0)) == 2)
	_combat.begin_wave(1, 8)
	_combat.on_enemy_killed(1); _combat.on_enemy_killed(0); _combat.on_enemy_killed(1)
	_combat.on_enemy_killed(0); _combat.on_enemy_killed(0)
	_t("w2: batch progress independent of kill order",
		int(_combat.batches_progress().get("done", 0)) == 2 and _combat.is_wave_cleared())

func _test_w2_spawn_consume() -> void:
	var plan := _combat.materialize_wave_plan(3, 10)
	var slots: Array = plan.get("slots", [])
	_spawner.clear()
	var spawned := _spawner.spawn_from_plan(plan, 10, Vector2.ZERO)
	_t("w2(M19): spawned count == plan slots", spawned.size() == slots.size())
	var same := true
	for i in range(mini(spawned.size(), slots.size())):
		var a: Dictionary = spawned[i]
		var b: Dictionary = slots[i]
		if int(a.get("batch", -1)) != int(b.get("batch", -2)) \
			or int(a.get("slot", -1)) != int(b.get("slot", -2)) \
			or String(a.get("enemy_id", "")) != String(b.get("enemy_id", "")) \
			or String(a.get("entry_point", "")) != String(b.get("entry_point", "")):
			same = false
			break
	_t("w2(M19): every spawned item equals plan item", same)
	_t("w2: spawner within MAX_ALIVE", _spawner.alive_count() <= SpawnService.MAX_ALIVE)

func _test_breach() -> void:
	_combat.begin_wave(1, 8)
	_combat.on_enemy_killed(0)
	_t("w1: unsettled wave settles breach (no early clear)", _combat.settle_night() == &"breach")
	_t("w1: breach target non-empty", _combat.breach_target() != &"")
	_t("w1: wave_active cleared after settle", not _combat.wave_active)

func _finish() -> void:
	print("--- combat_probe: %d pass / %d fail ---" % [_pass, _pass + _fail])
	print("coverage: combat_probe=%d" % (_pass + _fail))
	if _fail > 0:
		for f in _failures:
			printerr("FAILED: " + f)
	get_tree().quit(1 if _fail > 0 else 0)