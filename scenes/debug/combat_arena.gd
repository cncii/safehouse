extends Node2D
## combat_arena.gd — 战斗组调参场景（手感判据 R5 载体 + 波次判据 M19 载体）
## W1：3 秒重开 / 热重载 combat.json / 无敌帧可视化
## W2：波次物化自检面板（逐项相等 + 18:00±1 帧锚点 + plan_hash）
## 操作：J 攻击 / K 翻滚 / E 热重载 combat.json / W 跑 M19 物化自检

@onready var combat: CombatSystem = $CombatSystem
@onready var spawner: SpawnService = $SpawnService

var _session_t := 0.0
const SESSION_LEN := 3.0

var _m19_report: Dictionary = {}   # 最近一次 M19 自检结果
var _night := 1
var _spawned_count := 0

func _ready() -> void:
	_reset_session()
	_run_m19()

func _reset_session() -> void:
	_session_t = 0.0
	combat.debug_reset_vitals()
	combat.reload_tunables()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("attack"):
		var r := combat.player_attack(Vector2.RIGHT)
		print("attack -> ", r)
	elif event.is_action_pressed("dodge"):
		var r := combat.player_dodge(Vector2.RIGHT)
		print("dodge -> ", r)
	elif event.is_action_pressed("interact"):
		combat.reload_tunables()
		print("reloaded combat.json")
	elif event.is_action_pressed("pause"):
		# 借 pause 键位跑 M19（避免改动 InputMap —— F0 门禁项）
		_run_m19()

## M19 自检：物化两次比对逐项相等 + 物化时刻 18:00 锚点 + 消费端生成数
func _run_m19() -> void:
	var det := combat.verify_plan_deterministic(_night, 7 + _night)
	var plan := combat.materialize_wave_plan(_night, 7 + _night)
	spawner.clear()
	var spawned := spawner.spawn_from_plan(plan, 7 + _night, Vector2.ZERO)
	_spawned_count = spawned.size()
	var bp := combat.batches_progress()
	_m19_report = {
		"equal": det.get("equal", false),
		"slots": det.get("slot_count", 0),
		"spawned": _spawned_count,
		"gh": float(det.get("materialized_gh", -1.0)),
		"hash": det.get("plan_hash", 0),
		"strength": float(plan.get("strength_multiplier", 1.0)),
		"batches": "%d/%d" % [int(bp.get("done", 0)), int(bp.get("total", 0))],
	}
	print("[M19] ", _m19_report)

func _process(delta: float) -> void:
	combat.tick()
	_session_t += delta
	if _session_t >= SESSION_LEN:
		_reset_session()
	queue_redraw()

## Godot 4.3 draw_string 签名：
##   draw_string(font, pos, text, alignment, width, font_size, modulate)
## alignment/width 为必填位（-1 = 不限），漏掉会直接 Parse Error。
const FONT_SZ := 10
const W_UNLIM := -1.0
const ALIGN_LEFT := HORIZONTAL_ALIGNMENT_LEFT

func _text(pos: Vector2, s: String, col: Color = Color.WHITE) -> void:
	draw_string(ThemeDB.fallback_font, pos, s, ALIGN_LEFT, W_UNLIM, FONT_SZ, col)

func _draw() -> void:
	var stam := float(State.read("player.stamina"))
	var hp := float(State.read("player.hp"))
	draw_rect(Rect2(20, 20, 200, 16), Color(0.2, 0.2, 0.2))
	draw_rect(Rect2(20, 20, 200 * stam / 100.0, 16), Color(0.2, 0.8, 0.3))
	# 无敌帧可视化：翻滚期间蓝条
	if combat.is_iframe_active():
		draw_rect(Rect2(20, 44, 200, 16), Color(0.2, 0.6, 1.0))
	var act := "IDLE"
	match combat.current_action():
		1: act = "WINDUP"
		2: act = "RECOVER"
		3: act = "ROLLING"
	_text(Vector2(20, 90), "action=%s  iframe=%s  stam=%.0f  hp=%.0f" % [act, combat.is_iframe_active(), stam, hp])
	_text(Vector2(20, 110), "J=attack K=dodge E=reload ESC=M19 self-test  auto-reset every 3s", Color(0.8, 0.8, 0.8))

	# ── W2 · M19 物化面板 ──
	var y := 140.0
	_text(Vector2(20, y), "-- M19 wave_plan materialization --", Color(0.9, 0.9, 0.4)); y += 16
	if _m19_report.is_empty():
		_text(Vector2(20, y), "press ESC to run self-test", Color(0.7, 0.7, 0.7))
		return
	var ok := bool(_m19_report.get("equal", false))
	var ok_col := Color(0.3, 0.9, 0.4) if ok else Color(0.9, 0.3, 0.3)
	_text(Vector2(20, y), "night %d  item-wise equal: %s" % [_night, "PASS" if ok else "FAIL"], ok_col); y += 15
	_text(Vector2(20, y), "slots=%d  spawned=%d  batch=%s" % [
			int(_m19_report.get("slots", 0)), int(_m19_report.get("spawned", 0)),
			String(_m19_report.get("batches", "-"))], Color(0.8, 0.8, 0.8)); y += 15
	_text(Vector2(20, y), "materialized gh=%.2f (must be 18.00 +/-1 frame)" % float(_m19_report.get("gh", -1.0)), Color(0.8, 0.8, 0.8)); y += 15
	_text(Vector2(20, y), "strength x%.2f  plan_hash=%d" % [float(_m19_report.get("strength", 1.0)), int(_m19_report.get("hash", 0))],
		Color(0.8, 0.8, 0.8))
