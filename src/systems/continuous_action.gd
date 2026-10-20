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

enum SettleMode { ALL_OR_NOTHING, PER_SEGMENT }

var action_id: StringName
var duration_gh: float
var segment_gh := 0.0                     # 0 = 不分段
var settle_mode := SettleMode.ALL_OR_NOTHING
var interrupt_on: PackedStringArray = ["moved", "hit", "scene_changed"]
# 注意：打开 UI 面板（背包/科技/库存）不算中断（架构 v1.7 定案——
# 玩家拆到一半想看还差多少零件，不该白拆 2 分半）
var progress_milli := 0
var refund_on_cancel := false             # 恒 false；任何"true"都会被 QA 探针抓

func cancel_interrupted() -> void:
	if settle_mode == SettleMode.ALL_OR_NOTHING:
		progress_milli = 0   # 不保留——没给过产出，重来无套利
	# PER_SEGMENT：progress_milli 保留，断点续做（产出守恒判据的基础）

func advance(frames: int) -> void:
	# 每 0.5 GH = 2160 帧结算一段（PER_SEGMENT 时每段 750 milli 零件）
	pass  # TODO 包 B
