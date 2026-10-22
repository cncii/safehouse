class_name AudioSystem
extends Node
## audio_system.gd — 音频系统 【分包：包 D·UI/UX 组 · W4】
##
## ── 职责 ──   SFX/BGM 播放、总线音量、警报 ducking、
##              生命值警报（饥饿/渴 < LOW_* 持续可听、体力 ≤ LOW_STAMINA 心跳音）
## ── 硬边界 ── 纯消费者：只订阅 StateStore，不回写任何东西
##              （状态条是硬计时器，这是它唯一的感知通道，QA M 组判据依赖它）
## ── 阈值 ──   与 HUD 同源：直接引用 HudStyle.LOW_*（见 hud_style.gd 头注释——
##              显示/反馈阈值不进 data/balance/**，HUD 与 audio 必须读同一份，不许留副本）
## ── 素材 ──   res://assets/audio/{sfx,bgm} 当前为空。按 <id>.ogg|wav|mp3 约定路径加载，
##              缺失时 push_warning 一次并静默降级——素材落位后无需改代码。
## ── 判据 ──   M 组警报项（饥饿/渴 <25% 可听警报）P20(库存预警一次性音效，W2 接线)
##              R20(体力 ≤10% 低频心跳音)
##
## ── 挂载 ──   由 HudRoot._build() 实例化为子节点（音频随 HUD 生命周期）；
##              不注册 autoload（project.godot 不在表现组名下，注册需架构审批）。
##
## ── 随机数 ── pitch_jitter 属呈现随机：走 Rng.unitf 的 FLAVOR 盐 + 自增序号 key，
##              不消耗任何玩法流，也不碰全局 randf（工程随机数单点源纪律）。

const SFX_DIR := "res://assets/audio/sfx/"
const BGM_DIR := "res://assets/audio/bgm/"

# ── 音量/时长：技术参数（非玩法数值，归类同 HudStyle 的几何/配色常量）──
const ALARM_DB := -6.0
const HEARTBEAT_DB := -10.0
const SFX_DB := -8.0
const BGM_DB := -12.0
const DUCK_RECOVER_SEC := 0.3

var _alarm_hunger: AudioStreamPlayer
var _alarm_thirst: AudioStreamPlayer
var _alarm_heartbeat: AudioStreamPlayer
var _sfx: AudioStreamPlayer
var _bgm: AudioStreamPlayer
var _bgm_tween: Tween
var _sub_handle := -1
var _stock_sub_handle := -1
var _stock_warn_active := false   # 沿触发：任一链 days_left 进入警区 = true
var _sfx_seq := 0
var _warned := {}        # id -> true：素材缺失只警一次
var _duck_warned := false
var _loop_active := {}   # id -> bool：警报激活侧标志（与素材是否存在无关，先于播放翻转）

func _ready() -> void:
	_alarm_hunger = _make_player(ALARM_DB)
	_alarm_thirst = _make_player(ALARM_DB)
	_alarm_heartbeat = _make_player(HEARTBEAT_DB)
	_sfx = _make_player(SFX_DB)
	_bgm = _make_player(BGM_DB)
	# 持续可听 = 播完自动重来（不依赖 stream.loop 属性，对 ogg/wav/mp3 都成立）
	for p: AudioStreamPlayer in [_alarm_hunger, _alarm_thirst, _alarm_heartbeat]:
		p.finished.connect(p.play)
	bind_alarms()
	# W2 块3：库存两级预警一次性音效（阈值同源 HudLoopPanel.warn_thresholds → survival.json）
	_stock_sub_handle = State.subscribe(&"loop", _on_loop_changed)

func _exit_tree() -> void:
	if _sub_handle >= 0:
		State.unsubscribe(_sub_handle)
		_sub_handle = -1
	# W2 块3 的库存预警是第二个订阅句柄，退订时容易只退第一个（实测漏了这一个）
	if _stock_sub_handle >= 0:
		State.unsubscribe(_stock_sub_handle)
		_stock_sub_handle = -1
	if _stock_sub_handle >= 0:
		State.unsubscribe(_stock_sub_handle)
		_stock_sub_handle = -1

func _make_player(db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = db
	p.bus = &"Master"
	add_child(p)
	return p

## 订阅生命值警报。可重复调用（幂等）；并立即对齐一次当前状态
## （冷启动 vitals 全 0 = 全部低于阈值，警报应处于激活侧，不依赖第一次写入才起响）。
func bind_alarms() -> void:
	if _sub_handle < 0:
		_sub_handle = State.subscribe(&"player", _on_player_changed)
	_on_player_changed(&"", "bind")

func _on_player_changed(_source: StringName, _reason: String) -> void:
	_set_looping(_alarm_hunger, "alarm_hunger",
		float(State.read("player.hunger")) < HudStyle.LOW_HUNGER)
	_set_looping(_alarm_thirst, "alarm_thirst",
		float(State.read("player.thirst")) < HudStyle.LOW_THIRST)
	_set_looping(_alarm_heartbeat, "heartbeat",
		float(State.read("player.stamina")) <= HudStyle.LOW_STAMINA)


## W2 块3 库存两级预警：任一链 days_left 进入警区（<黄 或 <红）→ 一次性音效，
## 走沿触发（false→true 那一刻播一次，不循环不重播）。阈值缺键 = 整体静默（D-017）。
## LoopSystem 实例同 combat_system 模式防御式获取；缺位时 no-op，wiring 落位自动生效。
func _on_loop_changed(_source: StringName, _reason: String) -> void:
	var th := HudLoopPanel.warn_thresholds()
	if th.is_empty():
		return
	var loop := get_node_or_null("/root/LoopSystem")
	if loop == null or not loop.has_method("maintenance_urgency"):
		return
	var urg: Dictionary = loop.maintenance_urgency()
	var any_warn := false
	for res: String in urg.keys():
		var dl: float = float(urg[res]["days_left"])
		if dl >= 0.0 and not is_inf(dl) \
				and (dl < float(th["r"]) or dl < float(th["y"])):
			any_warn = true
			break
	if any_warn and not _stock_warn_active:
		play_sfx(&"stock_warn")
	_stock_warn_active = any_warn

## 沿触发：进入阈值侧开始循环、退出侧停止；已在播则不动（避免每帧重播）。
## _loop_active 与素材解耦：先翻标志再尝试播放——素材缺失时判据仍可红绿。
func _set_looping(p: AudioStreamPlayer, id: String, active: bool) -> void:
	_loop_active[id] = active
	if active and not p.playing:
		p.stream = _load_stream(SFX_DIR, id)
		if p.stream != null:
			p.play()
	elif not active and p.playing:
		p.stop()

func _load_stream(dir: String, id: String) -> AudioStream:
	for ext: String in ["ogg", "wav", "mp3"]:
		var path := dir + id + "." + ext
		if ResourceLoader.exists(path):
			return load(path) as AudioStream
	if not _warned.has(id):
		_warned[id] = true
		push_warning("AudioSystem: missing audio asset '%s' (searched %s{ogg,wav,mp3})" % [id, dir])
	return null

func play_sfx(id: StringName, pitch_jitter := 0.0) -> void:
	var s := _load_stream(SFX_DIR, String(id))
	if s == null:
		return
	_sfx.stream = s
	_sfx_seq += 1
	if pitch_jitter > 0.0:
		var u := Rng.unitf(&"FLAVOR", 0, PackedStringArray(["sfx", String(id), str(_sfx_seq)]))
		_sfx.pitch_scale = 1.0 + (u * 2.0 - 1.0) * pitch_jitter
	else:
		_sfx.pitch_scale = 1.0
	_sfx.play()

func play_bgm(id: StringName, fade_sec := 0.8) -> void:
	var s := _load_stream(BGM_DIR, String(id))
	if s == null:
		return
	_bgm.stream = s
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_bgm.volume_db = -40.0
	_bgm.play()
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(_bgm, "volume_db", BGM_DB, maxf(fade_sec, 0.01))

## 警报优先压 BGM：把 target_bus 压到 db，hold_sec 后自动恢复 0 dB。
## bus 未建（default_bus_layout 未配置）时警告一次并 no-op——音频素材与总线到位前不阻塞。
func duck(target_bus: StringName, db: float, hold_sec: float) -> void:
	var idx := AudioServer.get_bus_index(String(target_bus))
	if idx < 0:
		if not _duck_warned:
			_duck_warned = true
			push_warning("AudioSystem: duck target bus '%s' not found, skipped" % String(target_bus))
		return
	AudioServer.set_bus_volume_db(idx, db)
	get_tree().create_timer(maxf(hold_sec, 0.0)).timeout.connect(func() -> void:
		AudioServer.set_bus_volume_db(idx, 0.0))
