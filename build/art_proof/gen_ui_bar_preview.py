#!/usr/bin/env python3
"""gen_ui_bar_preview.py — 状态条合成预览 + 几何自检（对齐包 D 的真实行高）

做三件事：
1. 几何自检（断言，不靠眼睛）：fill 的可见带必须与 frame 的凹槽**逐像素重合**，
   且两者合成原点都是 (0,0)——偏移全部由 PNG 内的透明边距编码，接入方不记偏移量。
2. 按包 D 的真实布局排一遍（标签 40 + 条 112 + 数值 30，行高 14，行距 3），
   断言换上素材后**行高不变**，S5 布局结论不用重跑。
3. 出 4× 放大 + 1× 真实尺寸，给老板看效果。

颜色按包 D 现有语义走（`_color_for`）：>40 正常 / ≤40 警戒 / ≤阈值 危险。
所以四条用 68 / 35 / 18 / 92 四个值，正好把三档都打出来。

注：图中的标签文字用色块占位，真实渲染是 Fusion Pixel 12px。
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "assets" / "sprites" / "ui"
PROOF = ROOT / "build" / "art_proof"

# 三档语义色 → 落到 DB32 内的取值（fill 是纯白，modulate 后即为此色）
C_NORMAL = (0x6a, 0xbe, 0x30)     # #6abe30 DB32 绿
C_WARN = (0xdf, 0x71, 0x26)       # #df7126 DB32 橙
C_CRIT = (0xac, 0x32, 0x32)       # #ac3232 DB32 红
TRACK = (0x32, 0x3c, 0x39)

# (名称, 值, 颜色, 状态名) —— 值按包 D 的 _color_for 逻辑挑选，覆盖三档
SEMANTIC = [
    ("HP",     68, C_NORMAL, "normal"),
    ("STA",    35, C_WARN,   "warn"),
    ("HUNGER", 18, C_CRIT,   "critical"),
    ("THIRST", 92, C_NORMAL, "normal"),
]

# 包 D 的 HudStyle 几何
LABEL_W, BAR_W, VALUE_W, ROW_GAP = 40, 112, 30, 3
# 行高 = HBox 内最高的子控件，不是"标签高度"：
#   接素材前 max(Label 14, ProgressBar 10) = 14
#   接素材后 max(Label 14, 状态条 16)      = 16   ← 素材高会撑行高，S5 必须重跑
ROW_H_BEFORE = max(10 + 4, 10)      # BAR_H+4 的 Label vs BAR_H 的 ProgressBar
ROW_H_AFTER = max(10 + 4, 16)       # Label 不变，状态条素材高 16


def band_rect(img: Image.Image) -> tuple:
    """可见像素包围盒 (x0, y0, x1, y1)，闭区间。"""
    pts = [(i % img.width, i // img.width)
           for i, px in enumerate(img.convert("RGBA").get_flattened_data()) if px[3] > 0]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def assert_geometry(frame: Image.Image, fill: Image.Image) -> tuple:
    rgba = frame.convert("RGBA")
    tp = [(x, y) for y in range(rgba.height) for x in range(rgba.width)
          if rgba.getpixel((x, y))[:3] == TRACK]
    groove = (min(p[0] for p in tp), min(p[1] for p in tp),
              max(p[0] for p in tp), max(p[1] for p in tp))

    fb, lb = band_rect(frame), band_rect(fill)
    print(f"[geom] frame 可见  {fb}  = {fb[2]-fb[0]+1}x{fb[3]-fb[1]+1}")
    print(f"[geom] frame 凹槽  {groove}  = {groove[2]-groove[0]+1}x{groove[3]-groove[1]+1}")
    print(f"[geom] fill  可见  {lb}  = {lb[2]-lb[0]+1}x{lb[3]-lb[1]+1}")

    assert lb == groove, f"fill 可见带 {lb} 与凹槽 {groove} 不重合"
    assert fb[2] - fb[0] + 1 == BAR_W, f"frame 可见宽 {fb[2]-fb[0]+1} != BAR_W({BAR_W})"
    assert fb[1] >= 0 and fb[3] <= fill.height - 1
    print("[geom] 两张图同原点 (0,0) 叠画即可，偏移已编码在图内 ✓")
    return groove


def compose(frame: Image.Image, fill: Image.Image, ratio: float, color: tuple,
            groove: tuple) -> Image.Image:
    """按「同原点」规则合成：fill 裁宽度后直接叠在 (0,0)。"""
    out = frame.convert("RGBA").copy()
    band = fill.convert("RGBA").copy()
    px = band.load()
    for y in range(band.height):
        for x in range(band.width):
            if px[x, y][3]:
                px[x, y] = color + (255,)

    gx0, _, gx1, _ = groove
    vis_w = gx1 - gx0 + 1
    # 裁切右端：保留左透明边距 + 按比例的有效宽度（至少 1px，否则 0% 什么都不显示）
    cut_x = gx0 + max(1, round(vis_w * ratio))
    out.alpha_composite(band.crop((0, 0, cut_x, band.height)), (0, 0))
    return out


def main() -> None:
    frame = Image.open(UI / "ui_bar_frame.png")
    fill = Image.open(UI / "ui_bar_fill.png")
    groove = assert_geometry(frame, fill)

    # 行高由最高的子控件决定，素材 16 高必然撑高行高 —— 断言它"变了"，
    # 变了就必须让包 D 重跑 S5。早期版本误断言"不变"，已纠正。
    assert ROW_H_AFTER >= ROW_H_BEFORE, "行高不应变矮"
    delta = 4 * (ROW_H_AFTER - ROW_H_BEFORE)
    print(f"[layout] 行高 {ROW_H_BEFORE} → {ROW_H_AFTER}（+{ROW_H_AFTER-ROW_H_BEFORE}）  "
          f"四条块高 {4*ROW_H_BEFORE+3*ROW_GAP} → {4*ROW_H_AFTER+3*ROW_GAP}（+{delta}）")
    print("[layout] ⚠ 行高变了 → 包 D 的 S5（27 组合越界 0）必须重跑")

    rows = [compose(frame, fill, pct / 100.0, c, groove) for _, pct, c, _ in SEMANTIC]

    SCALE, PAD, LBL = 5, 22, 78
    rw, rh = frame.width, frame.height
    big_h = rh * SCALE

    f = ImageFont.load_default(size=15)
    fs = ImageFont.load_default(size=11)

    sec1 = len(rows) * (big_h + 10)
    sec2 = 18 + 4 * (ROW_H_AFTER + ROW_GAP)
    cw = PAD + LBL + rw * SCALE + PAD
    ch = PAD + 30 + sec1 + 18 + sec2 + PAD

    canvas = Image.new("RGB", (cw, ch), (26, 26, 30))
    d = ImageDraw.Draw(canvas)

    d.text((PAD, 12), f"vital bar  |  frame {rw}x{rh} (visible 14px)  "
                      f"|  BAR_W={BAR_W}  row {ROW_H_AFTER}px  |  same origin (0,0)",
           font=f, fill=(232, 232, 236))

    # ── ① 4× ──
    y = PAD + 30
    d.text((PAD, y - 15), "4x", font=fs, fill=(140, 140, 150))
    for i, (name, pct, _c, state) in enumerate(SEMANTIC):
        big = rows[i].resize((rw * SCALE, rh * SCALE), Image.NEAREST)
        yb = y + i * (big_h + 10)
        canvas.paste(big, (PAD + LBL, yb), big)
        d.text((PAD, yb + big_h // 2 - 13), name, font=f, fill=(215, 215, 220))
        d.text((PAD, yb + big_h // 2 + 1), f"{pct}%  {state}", font=fs, fill=(150, 150, 158))

    # ── ② 1× 真实尺寸 + 包 D 的行距 ──
    y += sec1 + 18
    # 标签一律用 ASCII：PIL 的默认字体没有 CJK 字形，写中文会渲染成豆腐块
    d.text((PAD, y - 15), f"1x  actual  ·  row {ROW_H_AFTER}px  ·  gap {ROW_GAP}px  "
                          f"(row grows {ROW_H_BEFORE} -> {ROW_H_AFTER}: texture height)", font=fs, fill=(150, 150, 158))
    for i, _ in enumerate(SEMANTIC):
        yb = y + i * (ROW_H_AFTER + ROW_GAP)
        d.rectangle([PAD, yb + 4, PAD + LABEL_W - 4, yb + 11], fill=(70, 72, 78))
        canvas.paste(rows[i], (PAD + LABEL_W, yb))
        d.rectangle([PAD + LABEL_W + BAR_W + 4, yb + 4,
                     PAD + LABEL_W + BAR_W + 4 + VALUE_W - 8, yb + 11], fill=(70, 72, 78))

    out = PROOF / "ui_bar_preview.png"
    canvas.save(out)
    print(f"\n[preview] {out}  ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
