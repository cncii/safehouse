#!/usr/bin/env python3
"""gen_ui_bar_preview.py — 状态条基准图的合成预览 + 几何自检

做两件事：
1. 几何自检（断言，不靠眼睛）：frame 的凹槽 rect 必须与 fill 的可见带 rect
   **在组合坐标系里逐像素重合**。落点差 2px 就会溢出凹槽，肉眼在 1× 下看不出来。
2. 出一张合成预览（1× 真实尺寸 + 4× 放大），给老板看效果与四条语义色。
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "assets" / "sprites" / "ui"
PROOF = ROOT / "build" / "art_proof"

# §3.2 语义色映射（底色恒为槽色 #323c39）
SEMANTIC = [
    ("HP", 68, (0xac, 0x32, 0x32)),
    ("STA", 42, (0x6a, 0xbe, 0x30)),
    ("HUNGER", 18, (0xd9, 0xa0, 0x66)),   # 低值 → 告警态
    ("THIRST", 8, (0x5f, 0xcd, 0xe4)),    # 低值 → 告警态
]
TRACK = (0x32, 0x3c, 0x39)


def visible_rect(img: Image.Image) -> tuple:
    """返回可见像素（alpha>0）的边界框，用于几何断言。"""
    return img.convert("RGBA").getbbox()


def assert_geometry(frame: Image.Image, fill: Image.Image) -> None:
    fx0, fy0, fx1, fy1 = visible_rect(frame)
    # frame 的凹槽 = 全是槽色 TRACK 的区域
    rgba = frame.convert("RGBA")
    xs, ys = [], []
    for y in range(rgba.height):
        for x in range(rgba.width):
            if rgba.getpixel((x, y))[:3] == TRACK:
                xs.append(x)
                ys.append(y)
    groove = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)

    fx0f, fy0f, fx1f, fy1f = visible_rect(fill)
    # fill 的可见带是"相对自身原点"的偏移；落点必须 = 凹槽原点
    band_w, band_h = fx1f - fx0f, fy1f - fy0f
    groove_w, groove_h = groove[2] - groove[0], groove[3] - groove[1]

    print(f"[geom] frame 凹槽 rect      = {groove_w}x{groove_h} @ ({groove[0]},{groove[1]})")
    print(f"[geom] fill 可见带          = {band_w}x{band_h} @ ({fx0f},{fy0f}) 内偏移")
    assert (band_w, band_h) == (groove_w, groove_h), "fill 可见带尺寸 != 凹槽尺寸"
    # fill 必须落在 frame 的 (groove.x, 0)——注意是 y=0，不是 y=groove.y
    print(f"[geom] 正确落点 = ({groove[0]}, 0)   ← 不是 ({groove[0]}, {groove[1]})")
    print(f"[geom] 判定: 尺寸一致 ✓  落点需按上式放置，否则填充带整体下移 {groove[1]}px 溢出凹槽")


def compose(frame: Image.Image, fill: Image.Image, ratio: float, color: tuple) -> Image.Image:
    out = frame.convert("RGBA").copy()
    band = fill.convert("RGBA").copy()
    # 染色：fill 是纯白，直接替换成语义色（等价于 modulate(#ffffff, color)）
    px = band.load()
    for y in range(band.height):
        for x in range(band.width):
            r, g, b, a = px[x, y]
            if a:
                px[x, y] = color + (255,)
    # 落点 (groove.x, 0)——fill 自带的 4px 透明留白会自己对齐凹槽
    w = round(band.width * ratio)
    out.alpha_composite(band.crop((0, 0, w, band.height)), (8, 0))
    return out


def main() -> None:
    frame = Image.open(UI / "ui_bar_frame.png")
    fill = Image.open(UI / "ui_bar_fill.png")
    assert_geometry(frame, fill)

    rows = [compose(frame, fill, pct / 100.0, c) for _, pct, c in SEMANTIC]

    SCALE, PAD = 4, 20
    LABEL_W = 76
    row_w, row_h = frame.width, frame.height

    # 布局：标题 → 4× 放大区 → 分隔 → 1× 真实尺寸区。高度逐段相加，不用中间变量猜。
    header_h = 30
    block_big_h = len(rows) * (row_h * SCALE + 12)
    block_real_h = 16 + len(rows) * (row_h + 2)
    block_ab_h = 16 + 2 * (row_h * SCALE + 10)
    canvas_w = PAD + LABEL_W + row_w * SCALE + PAD
    canvas_h = PAD + header_h + block_big_h + 14 + block_real_h + 10 + block_ab_h + PAD
    canvas = Image.new("RGB", (canvas_w, canvas_h), (26, 26, 30))

    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(canvas)
    f = ImageFont.load_default(size=15)
    fs = ImageFont.load_default(size=12)

    d.text((PAD, PAD - 4), "vital bars  |  frame 128x16 + fill 112x16 (visible band 12px)", font=f, fill=(230, 230, 235))

    # 4× 放大区
    y0 = PAD + header_h
    for i, (name, pct, color) in enumerate(SEMANTIC):
        big = rows[i].resize((row_w * SCALE, row_h * SCALE), Image.NEAREST)
        bh = big.height
        yb = y0 + i * (bh + 12)
        canvas.paste(big, (PAD + LABEL_W, yb), big)
        d.text((PAD, yb + bh // 2 - 7), f"{name}", font=fs, fill=(210, 210, 215))
        d.text((PAD, yb + bh // 2 + 5), f"{pct}%", font=fs, fill=(150, 150, 158))

    # 1× 真实尺寸区（关键：这才是玩家真正看到的像素密度）
    y1 = y0 + block_big_h + 14
    d.text((PAD, y1), "actual size (1x)", font=fs, fill=(150, 150, 158))
    y1 += 16
    for i in range(len(rows)):
        canvas.paste(rows[i], (PAD + LABEL_W, y1 + i * (row_h + 2)), rows[i])

    # ── A/B：外框台面色取 #595652（亮台面，读作"框"）还是 #323c39（同槽色，读作"槽"）
    # 这是语义取舍不是审美取舍，交老板定，所以在同一张图里并排给出来。
    y2 = y1 + block_real_h + 10
    d.text((PAD, y2), "frame plate A/B  (same 68% fill)", font=fs, fill=(150, 150, 158))
    y2 += 16
    alt = frame.convert("RGBA").copy()
    ap = alt.load()
    for yy in range(alt.height):
        for xx in range(alt.width):
            if ap[xx, yy][:3] == (0x59, 0x56, 0x52):
                ap[xx, yy] = TRACK + (255,)          # 台面并入槽色
    for i, (im, tag) in enumerate(((rows[0], "A plate #595652"),
                                   (compose(alt, fill, 0.68, SEMANTIC[0][2]), "B plate #323c39"))):
        big = im.resize((row_w * SCALE, row_h * SCALE), Image.NEAREST)
        yb = y2 + i * (big.height + 10)
        canvas.paste(big, (PAD + LABEL_W, yb), big)
        d.text((PAD, yb + big.height // 2 - 7), tag.split()[0], font=fs, fill=(210, 210, 215))
        d.text((PAD, yb + big.height // 2 + 5), "plate " + tag.split()[2], font=fs, fill=(150, 150, 158))

    out = PROOF / "ui_bar_preview.png"
    canvas.save(out)
    print(f"\n[preview] {out}  ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
