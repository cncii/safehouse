extends Node2D
## boot.gd — 启动自检场景（分包后每个团队跑的第一件事）
## 按 F0 门禁做时基冒烟：任何一项失败，print 到控制台并以非零退出。

func _ready() -> void:
	var problems: PackedStringArray = []

	if Engine.physics_ticks_per_second != 60:
		problems.append("F0: physics_ticks_per_second=%d (expect 60)" % Engine.physics_ticks_per_second)
	if Engine.max_physics_steps_per_frame < 8:
		problems.append("F0: max_physics_steps_per_frame=%d (expect >=8)" % Engine.max_physics_steps_per_frame)
	if Engine.time_scale != 1.0:
		problems.append("F0: time_scale=%f (must be 1.0)" % Engine.time_scale)

	# C27 常量双向校验：帧数 / 60 必须等于设计基线秒值
	var baselines := {
		TimeSystem.IFRAMES_TICKS: 0.15,
		TimeSystem.WINDUP_TICKS: 0.1333333,
		TimeSystem.RECOVERY_TICKS: 0.10,
		TimeSystem.HITSTUN_TICKS: 0.20,
		TimeSystem.INCAP_TICKS: 3.60,
	}
	for frames: int in baselines:
		var sec := float(frames) / 60.0
		if absf(sec - baselines[frames]) > 1e-6:
			problems.append("F0-b: %d frames = %.6f s, baseline %.6f s mismatch" % [frames, sec, baselines[frames]])

	if problems.is_empty():
		print("[boot] OK - timing self-check passed")
	else:
		for p in problems:
			push_error(p)
		print("[boot] FAILED - %d items" % problems.size())
		get_tree().quit(1)
		return
	# 自检通过后进入主菜单（分包初期先停在空场景）
	# SceneRouter.goto("main_menu")  ← 待 UI 包接入
