#!/usr/bin/env python3
"""gen_ui_kit_preview.py — UI 件全表预览（3× 放大 + 1× 真实尺 + 九宫拉伸好坏对比）

四段：
  ① 按钮五态：每行左边 3× 放大看细节，右边 1× 真实尺寸看实机观感。
     五态并排才看得出"靠斜面方向区分"这件事到底成立不成立。
  ② 九宫拉伸：同一个按钮拉到 240 宽。第三张是**反例**——在上条里画一道虚线
     再拉，能直接看到九宫拉伸最典型的故障（重复竖纹）。
     这一对比就是 `c_tileable` 那条判据在防的东西。
  ③ 面板两件 2× 放大（看圆角与边框比例）。
  ④ 物品格三态 3× + 一排 1× 拼成背包行（10 格），看小件在 1× 下会不会糊。

为什么标签全是 ASCII：PIL 默认位图字体没有 CJK 字形，写中文渲染成豆腐块
（状态条预览踩过这个坑）。

为什么反例是"内存里造"而不是落盘成负样本：负样本 PNG 一旦落在 assets/
就会过门禁、进图集、进包体。这里用完即弃。

★ 版面用"先建超高画布、画完 crop"而不是"先算总高"：
  上一版正是手算 sec_b 少算了 100px，结果面板压到拉伸图上、底部物品格被裁。
  手算高度这种事没有一次算对过，就别算了。
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "assets" / "sprites" / "ui"
PROOF = ROOT / "build" / "art_proof"

sys.path.insert(0, str(PROOF))
import gen_ui_kit as G  # noqa: E402

BG = (26, 26, 30)
FG = (232, 232, 236)
DIM = (150, 150, 158)
WARN = (240, 190, 90)

PAD = 24
CW = 448
S3 = 3


def nine_slice(img: Image.Image, tw: int, th: int, m: int) -> Image.Image:
    """标准九宫拉伸。中间段用 NEAREST 重复 1px 切片——正是引擎的行为。"""
    img = img.convert("RGBA")
    w, h = img.size
    src_x = [(0, m), (m, w - m), (w - m, w)]
    src_y = [(0, m), (m, h - m), (h - m, h)]
    dst_x = [(0, m), (m, tw - m), (tw - m, tw)]
    dst_y = [(0, m), (m, th - m), (th - m, th)]
    out = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    for i in range(3):
        for j in range(3):
            x0, x1 = src_x[i]
            y0, y1 = src_y[j]
            px0, px1 = dst_x[i]
            py0, py1 = dst_y[j]
            if px1 <= px0 or py1 <= py0:
                continue
            tile = img.crop((x0, y0, x1, y1))
            if tile.size != (px1 - px0, py1 - py0):
                tile = tile.resize((px1 - px0, py1 - py0), Image.NEAREST)
            out.alpha_composite(tile, (px0, py0))
    return out


def textured_bad_copy(img: Image.Image, m: int) -> Image.Image:
    """反例：在九宫上条里画**竖条带**（每 4px 一列，跨越 y=1..m-1）。
    本地 1× 看只是"一道装饰纹"，拉宽后每一列都被重复成一排竖纹。
    用竖条而不是横虚线，是因为竖条正好沿拉伸方向排列，故障一眼可见。"""
    bad = img.convert("RGBA").copy()
    for x in range(m, bad.width - m):
        if (x // 4) % 2 == 0:
            for y in range(1, m):
                bad.putpixel((x, y), G.HILITE + (255,))
    return bad


def main() -> None:
    btn = {s: Image.open(UI / f"ui_btn_base_{s}.png") for s in G.BTN_STATES}
    panel_d = Image.open(UI / "ui_panel_dialog.png")
    panel_s = Image.open(UI / "ui_panel_small.png")
    slot = {s: Image.open(UI / f"ui_slot_item_{s}.png") for s in G.SLOT_STATES}

    f = ImageFont.load_default(size=15)
    fs = ImageFont.load_default(size=11)

    canvas = Image.new("RGB", (CW, 2600), BG)   # 给足高度，最后按实际裁
    d = ImageDraw.Draw(canvas)
    y = 14

    d.text((PAD, y), "UI kit   btn 96x32   panel 192x112 / 96x64   slot 32x32",
           font=f, fill=FG)
    y += 30

    # ── ① 按钮五态 ──
    d.text((PAD, y), "1  BUTTON   5 states   (3x detail / 1x actual)", font=fs, fill=DIM)
    y += 16
    notes = {
        "normal":   "top-left lit, bottom-right dark  (S3)",
        "hover":    "plane lifted to #595652",
        "pressed":  "bevel inverted => looks sunk",
        "disabled": "both sides same => no directional light",
        "selected": "accent #fbf236 frame, plane stays #323c39",
    }
    for s in G.BTN_STATES:
        img = btn[s]
        big = img.resize((img.width * S3, img.height * S3), Image.NEAREST)
        canvas.paste(big, (PAD, y))
        canvas.paste(img, (PAD + big.width + 20, y + (big.height - img.height) // 2))
        d.text((PAD, y + big.height + 3), "%s   %s" % (s, notes[s]), font=fs, fill=FG)
        y += big.height + 22

    # ── ② 九宫拉伸 ──
    y += 10
    d.text((PAD, y), "2  9-SLICE   96 -> 240 wide", font=fs, fill=DIM)
    y += 16
    base = btn["normal"]
    canvas.paste(base, (PAD, y))
    d.text((PAD + 110, y + 10), "1x 96  (original)", font=fs, fill=DIM)
    y += 32 + 16

    canvas.paste(nine_slice(base, 240, 32, 8), (PAD, y))
    d.text((PAD, y + 34), "240  OK   every column identical => clean", font=fs, fill=FG)
    y += 32 + 28

    canvas.paste(nine_slice(textured_bad_copy(base, 8), 240, 32, 8), (PAD, y))
    d.text((PAD, y + 34), "240  BAD  pattern in top band => repeated stripes", font=fs, fill=WARN)
    d.text((PAD, y + 46), "     this is what c_tileable catches", font=fs, fill=WARN)
    y += 32 + 46

    # ── ③ 面板 ──
    d.text((PAD, y), "3  PANEL   2x   (9-slice 8/8/8/8)", font=fs, fill=DIM)
    y += 16
    for img, name in ((panel_d, "ui_panel_dialog"), (panel_s, "ui_panel_small")):
        b = img.resize((img.width * 2, img.height * 2), Image.NEAREST)
        canvas.paste(b, (PAD, y))
        d.text((PAD, y + b.height + 3), "%s  %dx%d" % (name, img.width, img.height),
               font=fs, fill=DIM)
        y += b.height + 22

    # ── ④ 物品格 ──
    y += 10
    d.text((PAD, y), "4  SLOT   3 states 3x   +   1x backpack row", font=fs, fill=DIM)
    y += 16
    x = PAD
    for s in G.SLOT_STATES:
        img = slot[s]
        b = img.resize((img.width * S3, img.height * S3), Image.NEAREST)
        canvas.paste(b, (x, y))
        d.text((x, y + b.height + 3), s, font=fs, fill=DIM)
        x += b.width + 22
    y += 32 * S3 + 24

    x = PAD
    for i in range(10):
        pick_ = "hover" if i == 4 else ("selected" if i == 7 else "normal")
        canvas.paste(slot[pick_], (x, y))
        x += 32 + 2
    d.text((PAD, y + 36), "1x row   (cell 4 = hover, cell 7 = selected)", font=fs, fill=DIM)
    y += 36 + 14

    canvas = canvas.crop((0, 0, CW, y + PAD))
    out = PROOF / "ui_kit_preview.png"
    canvas.save(out)
    print(f"[preview] {out}  ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
