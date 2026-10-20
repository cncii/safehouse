extends Node
## game_loop.gd — 唯一时间驱动者与命令分发者（架构 §2.1 + C27）
##
## ── C27：elapsed_ticks 是时间系统唯一真相 ──
## gh 不存储、不 float 累加，只由整数帧派生：
##   gh() = elapsed_ticks / 4320.0
## 这消掉"帧率不同导致时间漂移"整类 bug；P1 判据因此可以整数全等：
##   P1①：elapsed_ticks == 816_480 + 38_880 × k（k = 阶段A熬夜夜数，±0）
##
## ── 分包规则 ──
## · 只有本文件在 _physics_process 里推进模拟；其它系统一律被动接收 tick。
## · SceneRouter.suspend_simulation() 期间本循环停摆（UI 全屏页时停时间）。
## · 禁止任何系统读取 Engine.time_scale 或修改它（F0 断言恒 1.0）。

signal ticked(frames: int)
signal gh_crossed(gh_mark: int)      # 每跨过 1 个整 GH 发一次（Vitals/Loop 结算点）
signal day_changed(new_day: int)

const FRAMES_PER_GH := 4320          # 72 s × 60（M1 判据锚点，禁改）
const FRAMES_PHASE_A_ACTIVE := 64800 # 阶段A 单日活跃 15 GH
const FRAMES_PHASE_B_DAYTIME := 51840# 阶段B 单日白天 12 GH
const FRAMES_NIGHT_OVERTIME := 38880 # 阶段A 每熬夜一夜 +9 GH
const FRAMES_FULL_RUN := 816480      # 全季 clock（k=0 的 P1① 期望值）

var elapsed_ticks: int = 0
var _suspended := false

func _physics_process(_delta: float) -> void:
	if _suspended:
		return
	var prev_gh := elapsed_ticks / FRAMES_PER_GH
	elapsed_ticks += 1
	ticked.emit(1)
	var now_gh := elapsed_ticks / FRAMES_PER_GH
	if now_gh > prev_gh:
		gh_crossed.emit(now_gh)

## ── 派生量（只读，纯函数） ──
func gh() -> float:
	return float(elapsed_ticks) / float(FRAMES_PER_GH)

func gh_int() -> int:
	return elapsed_ticks / FRAMES_PER_GH

func seconds() -> float:
	return float(elapsed_ticks) / 60.0

## P1① 结构判据（QA v1.4 定稿）：clock 帧数 == 816480 + 38880k
func p1_clock_assert(k: int) -> bool:
	return elapsed_ticks == FRAMES_FULL_RUN + FRAMES_NIGHT_OVERTIME * k

## ── 暂停控制（SceneRouter 调，其它地方禁止） ──
func set_suspended(v: bool) -> void:
	_suspended = v

## ── 新局 / 读档 ──
func reset(new_ticks: int = 0) -> void:
	elapsed_ticks = new_ticks
