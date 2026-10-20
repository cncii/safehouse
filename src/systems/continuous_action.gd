class_name ContinuousAction
extends RefCounted
## continuous_action.gd — 持续动作统一抽象（架构 v1.4，7 处共用一个模式）
##
## 覆盖：清滤芯(10s可打断) / 手动滤水(36s) / 拆解(2GH分4段) / 修门(1.5GH) /
##       造陷阱(1GH) / 补装(0.5GH) / 路障(0.5GH)
##
## ── 三条硬规则（"无限刷零件"洞的修法，第 4 个交界洞） ──
## 1. 材料一律在动作开始时扣除，refund_on_cancel 全项目恒 false（探针判据）
## 2. settle_mode=ALL_OR_NOTHING（默认）：中断 → 产出不给、进度不保留
##    settle_mode=PER_SEGMENT：中断 → 已结算段保留，断点续做
##    schema 强制：segment_gh < duration → progress_persisted 必须为 true
##    （违反即加载期报错——"分段但没保留进度"在结构上写不出来）
## 3. progress_milli 只允许锚点 {0,500,1000,1500,2000}，750 类中间值拒载
##    （750 = "半段已结算但未落账"，是竞态不是状态）
##
## ── 判据 ── M20(25 个断言点：5 动作×5 场景) 产出守恒：中断续做 10 次总产出恒 3000 milli
##
## ── 实现（逻辑组 · 2026-10-20）──────────────────────────────
##  单位口径：progress_milli 是**毫 GH**（1 GH = 1000 milli，C26 同一尺度）。
##  段长 0.5 GH = 2160 帧 = 500 milli——所以锚点 {0,500,1000,1500,2000}
##  正好是「拆解 2GH 分 4 段」的四个刻度，与 save.schema.json 的
##  dismantle_bench.progress_milli 锚点集逐个对得上。
##  产出另用一套单位（毫单位，零件 = 1000 milli/件），**不与进度共用刻度**：
##  进度是「做完了多少」，产出是「拿到多少零件」，两件事不该共用一个数字。
## ────────────────────────────────────────────────────────────

const FRAMES_PER_GH := 4320
const FRAMES_PER_SEGMENT := 2160        # 0.5 GH —— 每段的帧数
const PROGRESS_MILLI_PER_SEGMENT := 500 # 0.5 GH × 1000 milli/GH
const PROGRESS_ANCHORS: PackedInt32Array = [0, 500, 1000, 1500, 2000]

enum SettleMode { ALL_OR_NOTHING, PER_SEGMENT }

var action_id: StringName
var duration_gh: float
var segment_gh := 0.5                    # 0 = 不分段（单段一次结算）
var settle_mode := SettleMode.ALL_OR_NOTHING
var interrupt_on: PackedStringArray = ["moved", "hit", "scene_changed"]
# 注意：打开 UI 面板（背包/科技/库存）不算中断（架构 v1.7 定案——
# 玩家拆到一半想看还差多少零件，不该白拆 2 分半）
var progress_milli := 0

## 每段结算的产出（毫单位）。拆解 = 750（3 件零件 / 4 段 = 3000 milli，M20 守恒口径）。
var output_per_segment_milli := 750

## PER_SEGMENT 时是否保留已结算进度。schema 强制：只要动作是分段的，就必须为 true。
var progress_persisted := false

## 已结算产出（毫单位）。ALL_OR_NOTHING 中断时作废归零。
var settled_output_milli := 0

var _frames_done := 0
var _finished := false
var _refund_on_cancel := false


## 硬规则 1：refund_on_cancel 恒 false。做成只读属性——写 true 会被当场拒绝，
## 不是"写进去也没人用"。材料在动作开始时扣，中途取消不还。
var refund_on_cancel: bool:
	get:
		return _refund_on_cancel
	set(value):
		if value:
			# 用 warning 不用 error：规则靠**行为**强制（值仍被拒），不是靠日志级别。
			# 门禁输出里常驻一条 ERROR，久了就没人看了——那才是真问题。
			push_warning("ContinuousAction: refund_on_cancel is always false (R11 / hard rule 1)")
		_refund_on_cancel = false


func _init(id: StringName = &"", dur_gh: float = 0.0, seg_gh: float = 0.5) -> void:
	action_id = id
	duration_gh = dur_gh
	segment_gh = seg_gh
	progress_persisted = (settle_mode == SettleMode.PER_SEGMENT)


## schema 强制（硬规则 2 末段）：动作是分段的（segment_gh < duration）时，
## progress_persisted 必须为 true——"分段但没保留进度"在结构上写不出来。
## 违反在**加载期**就报错，不等到运行中才发现白拆。
func validate() -> Dictionary:
	var problems := PackedStringArray()
	if segment_gh < duration_gh and not progress_persisted:
		problems.append("segmented action requires progress_persisted=true")
	if refund_on_cancel:
		problems.append("refund_on_cancel must be false")
	if not is_valid_anchor(progress_milli):
		problems.append("progress_milli=%d is not an anchor" % progress_milli)
	return {"ok": problems.is_empty(), "problems": problems}


## 硬规则 3：progress_milli 只允许锚点。750 这类中间值拒载——
## 那是"半段已结算但未落账"，是竞态不是状态。
static func is_valid_anchor(v: int) -> bool:
	return PROGRESS_ANCHORS.has(v)


## 中断处理。ALL_OR_NOTHING → 进度清零、已结算产出作废（重来无套利）；
## PER_SEGMENT → 进度与已结算产出保留，断点续做（M20 产出守恒的基础）。
func cancel_interrupted() -> void:
	if settle_mode == SettleMode.PER_SEGMENT:
		if not progress_persisted:
			push_error("ContinuousAction: PER_SEGMENT without progress_persisted")
			return
		# 保留 progress_milli 与 settled_output_milli（断点续做的依据）。
		# _frames_done 回退到「已落账进度」对应的帧数——被打断的那段时间不算数，
		# 否则续做会把中断前的帧数再算一遍（产出翻倍）。
		_frames_done = int(round(float(progress_milli) / 1000.0 * float(FRAMES_PER_GH)))
		return
	progress_milli = 0
	settled_output_milli = 0
	_frames_done = 0
	_finished = false


## 每 0.5 GH = 2160 帧结算一段。
func advance(frames: int) -> void:
	if _finished or frames <= 0:
		return
	_frames_done += frames
	var total_frames := int(round(duration_gh * float(FRAMES_PER_GH)))
	if _frames_done > total_frames:
		_frames_done = total_frames
	var seg_frames := int(round(segment_gh * float(FRAMES_PER_GH)))
	if seg_frames <= 0:
		seg_frames = FRAMES_PER_SEGMENT
	var new_progress := progress_milli
	while new_progress < _anchor_for(_frames_done, seg_frames):
		new_progress += PROGRESS_MILLI_PER_SEGMENT
		settled_output_milli += output_per_segment_milli
	progress_milli = new_progress
	if _frames_done >= total_frames:
		_finished = true


## 已完成帧数 → 段锚点进度。向下取到段边界（半段未落账不进账）。
func _anchor_for(frames_done: int, seg_frames: int) -> int:
	var segs := int(floor(float(frames_done) / float(seg_frames)))
	return segs * PROGRESS_MILLI_PER_SEGMENT


func is_finished() -> bool:
	return _finished


func progress_ratio() -> float:
	if duration_gh <= 0.0:
		return 0.0
	return clampf(float(progress_milli) / 1000.0 / duration_gh, 0.0, 1.0)


## 取走已结算产出（交给调用方落账）。ALL_OR_NOTHING 中断后这里返回 0。
func take_output_milli() -> int:
	var v := settled_output_milli
	settled_output_milli = 0
	return v


# ════════════════════════════════════════════════════════════════
#  自检（M20 产出守恒 —— 判据本体在本文件内）
# ════════════════════════════════════════════════════════════════

## M20 核心：中断续做 10 次，总产出恒 3000 milli。
## 守恒口径 = 「续做 N 次的累计产出 == 一次做完的产出」。
## 这条判据抓的是「中断把已结算段清零」——那会让每次中断都吃掉一段，
## 玩家越续做亏得越多。
func verify_continuous_actions() -> Dictionary:
	var out := {}

	# ── M20-1：一次做完 = 3000 milli（拆解 2GH / 4 段 / 每段 750）──
	var full := _make_dismantle(SettleMode.PER_SEGMENT)
	while not full.is_finished():
		full.advance(FRAMES_PER_SEGMENT)
	out["M20_full_output_milli"] = full.settled_output_milli
	out["M20_full_progress_milli"] = full.progress_milli
	out["M20_full_pass"] = full.settled_output_milli == 3000 and full.progress_milli == 2000

	# ── M20-2：**一个**动作被反复中断续做，总产出恒 3000 milli。
	#   口径是「中断多少次都不多不少」——不是「做 10 遍」。
	#   每次在 1.5 段处打断（故意落在段边界外，逼出半段竞态）。
	var resumed := _make_dismantle(SettleMode.PER_SEGMENT)
	var interrupts := 0
	while not resumed.is_finished() and interrupts < 10:
		resumed.advance(int(float(FRAMES_PER_SEGMENT) * 1.5))
		resumed.cancel_interrupted()
		interrupts += 1
	while not resumed.is_finished():
		resumed.advance(FRAMES_PER_SEGMENT)
	out["M20_resumed_total_milli"] = resumed.settled_output_milli
	out["M20_resumed_interrupts"] = interrupts
	out["M20_resumed_progress_milli"] = resumed.progress_milli
	out["M20_resume_pass"] = resumed.settled_output_milli == 3000 \
		and resumed.progress_milli == 2000

	# ── M20-3：ALL_OR_NOTHING 中断 → 进度与产出都归零（重来无套利）──
	var anon := _make_dismantle(SettleMode.ALL_OR_NOTHING)
	anon.advance(FRAMES_PER_SEGMENT)
	anon.advance(FRAMES_PER_SEGMENT)
	anon.cancel_interrupted()
	out["M20_anon_progress_milli"] = anon.progress_milli
	out["M20_anon_output_milli"] = anon.settled_output_milli
	out["M20_anon_pass"] = anon.progress_milli == 0 and anon.settled_output_milli == 0

	# ── M20-4：材料不退还——refund_on_cancel 恒 false，写 true 被拒 ──
	var probe := _make_dismantle(SettleMode.ALL_OR_NOTHING)
	probe.refund_on_cancel = true
	out["M20_refund_flag"] = probe.refund_on_cancel
	out["M20_refund_pass"] = probe.refund_on_cancel == false

	# ── M20-5：锚点拒载 750（半段已结算但未落账，是竞态不是状态）──
	out["M20_anchor_750_rejected"] = not is_valid_anchor(750)
	out["M20_anchor_2000_ok"] = is_valid_anchor(2000)
	out["M20_anchor_pass"] = out["M20_anchor_750_rejected"] and out["M20_anchor_2000_ok"]

	# ── 硬规则 2 末段：分段动作缺 progress_persisted → 加载期就报错 ──
	var bad := _make_dismantle(SettleMode.PER_SEGMENT)
	bad.progress_persisted = false
	out["M20_schema_blocks_missing_persist"] = not bool(bad.validate()["ok"])
	out["M20_schema_pass"] = out["M20_schema_blocks_missing_persist"]
	return out


func _make_dismantle(mode: SettleMode) -> ContinuousAction:
	var a := ContinuousAction.new(&"dismantle", 2.0, 0.5)
	a.settle_mode = mode
	a.progress_persisted = (mode == SettleMode.PER_SEGMENT)
	a.output_per_segment_milli = 750
	return a
