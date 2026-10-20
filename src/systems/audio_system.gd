class_name AudioSystem
extends Node
## audio_system.gd — 音频系统 【分包：包 D·UI/UX 组】
##
## ── 职责 ──   SFX/BGM 播放、总线音量、警报 ducking
## ── 硬边界 ── 纯消费者：只订阅 StateStore，不回写任何东西
##              （ui.hunger/thirst < 25% 时持续可听警报——状态条是硬计时器，
##              这是它唯一的感知通道，QA M 组判据依赖它）
##
## ── 判据 ──  M 组警报项（剩 25% 可听警报）P20(溢出预警一次性音效)
##            R20(体力 ≤10% 屏幕脉动+低频心跳音)

func play_sfx(id: StringName, pitch_jitter := 0.0) -> void:
	pass  # TODO 包 D

func play_bgm(id: StringName, fade_sec := 0.8) -> void:
	pass  # TODO 包 D

func duck(target_bus: StringName, db: float, hold_sec: float) -> void:
	pass  # TODO 包 D：警报优先压 BGM

func bind_alarms() -> void:
	# State.subscribe("player", func(src, reason): _check_alert_levels())
	pass  # TODO 包 D
