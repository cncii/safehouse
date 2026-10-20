extends Node
## perf_governor.gd — 性能监控与降级档位（架构 §7.2 #2–#4 [降级] 项的落地处）
##
## ── 分包规则 ──
## · 降档动作（改粒子 amount、降 AI 频率）由对应系统在 set_tier() 里注册；
##   本框架只负责"何时降"，不负责"降什么"（分层：框架不懂游戏规则）。
## · 判据：滑动窗口 120 帧平均 fps < 55 → tier-1；降档后 30 s 未回到 ≥58 再降；
##   单场景内不回弹。
##
## ── [门禁] 项（无降级，构建期属性）不经过这里：
##   分辨率 640×360 / Draw Call / 内存 / 启动时长 / 包体 —— 见 docs/architecture.md §7.3

signal tier_changed(new_tier: int)

const WINDOW_FRAMES := 120
const FPS_DROP_BELOW := 55.0
const FPS_RECOVER_TO := 58.0

var tier := 0                     # t0 全开 / t1 / t2 / t3（架构 §7.2 表）
var _samples: PackedFloat64Array = []
var _last_drop_tick := 0
var _bounced := false             # 单场景内不回弹

func _physics_process(_delta: float) -> void:
	_samples.append(Performance.get_monitor(Performance.TIME_FPS))
	if _samples.size() > WINDOW_FRAMES:
		_samples.remove_at(0)
	if _samples.size() < WINDOW_FRAMES:
		return
	var avg := _avg()
	if avg < FPS_DROP_BELOW and tier < 3:
		if not _bounced:
			set_tier(tier + 1)
			_last_drop_tick = GameLoop.elapsed_ticks
	elif avg >= FPS_RECOVER_TO and _last_drop_tick > 0:
		# 恢复观察窗：30 s（1800 帧）内不再降档才算稳
		if GameLoop.elapsed_ticks - _last_drop_tick > 1800:
			_bounced = true   # 本场景不再自动回弹，防抖动
			_last_drop_tick = 0

func set_tier(t: int) -> void:
	t = clampi(t, 0, 3)
	if t == tier:
		return
	tier = t
	tier_changed.emit(t)
	Logger.log("perf", "tier_changed", "", t, "avg fps=%.1f" % _avg())

func _avg() -> float:
	var s := 0.0
	for v in _samples:
		s += v
	return s / maxf(1.0, float(_samples.size()))

## 各系统注册降级动作：func(tier:int) -> void
func register_tier_action(owner_system: StringName, cb: Callable) -> void:
	tier_changed.connect(func(t: int) -> void: cb.call(t),
		CONNECT_REFERENCE_COUNTED)
	Logger.log("perf", "tier_action_registered", String(owner_system))
