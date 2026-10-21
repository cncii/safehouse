class_name HudStyle
extends RefCounted
## hud_style.gd — HUD 显示常量的唯一来源（包 D 表现组 · W1）
##
## ── 为什么单列这个文件 ──
## HUD 与 audio_system 的告警必须读同一份阈值，否则会出现"条已经红了但没声音"
## 或"响了但条还是绿的"——那种不一致一旦上线就没人敢改，因为不知道哪个是对的。
## 后续 W4 音频接入请直接引用本文件，不要另抄一份常量。
##
## ── 阈值来源 ──
## 低值阈值与《任务书_表现组_包D.md》§5-4 的音频警报同源（饥饿/渴 <25、体力 ≤10）。
## 注意：这些是"显示/反馈阈值"，不是速率类数值，因此不进 data/balance/**
## （data/balance/** 归包 B 与包 CE，见任务书 §9 的归属待裁定项）。
## 若将来要把它们挪进 data/**，必须同时改 HUD 与 audio 两处引用，不许留副本。

# ── 低值告警阈值（0–100 标度，与状态路径同标度）──
const LOW_HP := 25.0
const LOW_STAMINA := 10.0
const LOW_HUNGER := 25.0
const LOW_THIRST := 25.0

# 低于满值的该比例即进入黄色警戒（低于上面的 LOW_* 才转红）
const WARN_RATIO := 0.40

# ── 灰盒配色（纯色块，W2/W3 换素材后本组仍保留同色阶语义）──
const COLOR_TRACK := Color(0.12, 0.13, 0.16, 1.0)
const COLOR_NORMAL := Color(0.35, 0.72, 0.40, 1.0)
const COLOR_WARN := Color(0.92, 0.74, 0.20, 1.0)
const COLOR_CRITICAL := Color(0.88, 0.28, 0.24, 1.0)
const COLOR_TEXT := Color(0.92, 0.93, 0.95, 1.0)

# ── 几何（内部分辨率 640×360，全部为整数，禁止小数缩放）──
# FONT_SIZE 必须是像素字体原生尺寸的整数倍（Fusion Pixel 12px，见 ui_theme.gd）——
# 非整数倍会把位图字形落在半像素上（模糊/粗细不一）。曾是 8（默认字体时代灰盒值），
# 接像素字体后改 12（原生），S5 重跑验证布局。
const FONT_SIZE := 12
const LABEL_W := 40.0
const VALUE_W := 30.0
const BAR_W := 112.0
const BAR_H := 10.0
const ROW_GAP := 3.0
const PANEL_PAD := 6.0
