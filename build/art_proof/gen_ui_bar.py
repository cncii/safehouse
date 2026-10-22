#!/usr/bin/env python3
"""gen_ui_bar.py — 生成四条状态条的 UI 件基准图（119 行规格的机械化）

产物（assets/sprites/ui/）：
  ui_bar_frame.png  128×16   底板/槽（描边 + 左上高光 + 右下暗边 + 凹槽）
  ui_bar_fill.png   112×16   填充块（可见带 12px 居中，上下各 2px 透明留白）

为什么 fill 是 112×16 而不是契约原稿的 112×8：
  验收器 A1 要求宽高都是 16 的倍数，8 不是 → 112×8 会被判违例。
  已用 check_assets._multiple_of_16 实测确认，不是推测。
  所以要出 112×16，靠"上下透明留白"把可见带压到 12px；
  九宫格 top/bottom 对应的正是这两条透明留白，纵向不会被拉伸（16 就是目标高）。

设计（逐条对应 style_contract）：
  S1 16 网格      : 128×16 / 112×16
  S3 左上光源     : 上/左 1px 高光 #847e87，下/右 1px 暗边 #222034
  S4 1px 深色描边 : 外圈 1px #222034，圆角处阶梯收边
  §3.1 UI 6 色子集: 只用到 4 色（#222034 #323c39 #595652 #847e87）
  §4.2 九宫格     : frame 8/4/8/4，fill 4/4/4/4（四个具名值）
  §4.3 像素硬边   : 圆角 r=2 的两级阶梯，无平滑弧、无渐变、alpha 只有 0/255
  §4.3 索引色导出 : PNG-8 + 透明索引（自建调色板，不用 ADAPTIVE 以免色值漂移）
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "sprites" / "ui"

# ── §3.1 UI 专用子集（只取本件用到的 4 色）──────────────────────────────
OUTLINE = (0x22, 0x20, 0x34)   # #222034 描边（S4）
TRACK = (0x32, 0x3c, 0x39)     # #323c39 底板主色（凹槽，S3.2 四条条底色）
PLATE = (0x59, 0x56, 0x52)     # #595652 底板内凹色（本件用作外框台面）
HILITE = (0x84, 0x7e, 0x87)    # #847e87 面板高光边（左上光源落点）
FILL = (0xff, 0xff, 0xff)      # #ffffff 纯白，由表现组 modulate 成四条语义色

W, H = 128, 16
# 竖向只留 2px（1px 描边 + 1px 斜面），让色彩带占到 12/16 = 75%。
# 初版是上下各 4px（带高 8px），1× 下色彩带只有条高的一半，读起来像一条细线 —— 太薄。
INSET_L, INSET_T, INSET_R, INSET_B = 8, 2, 8, 2     # §4.2 frame 九宫格给 8/4/8/4，此处只定义凹槽
GW, GH = W - INSET_L - INSET_R, H - INSET_T - INSET_B   # 112 × 12 凹槽


def corner_cells(w: int, h: int, r: int = 2, x0: int = 0, y0: int = 0) -> set:
    """r=2 的像素阶梯圆角：首行去 2 格，次行去 1 格。

    x0/y0 让圆角可以贴着"可见带"而不是整张画布算——fill 上下带透明留白时必须如此，
    否则圆角会落在透明区里，等于没做。
    """
    cut = set()
    for i in range(r):
        for j in range(r - i):
            cut.add((x0 + i, y0 + j))
            cut.add((x0 + w - 1 - i, y0 + j))
            cut.add((x0 + i, y0 + h - 1 - j))
            cut.add((x0 + w - 1 - i, y0 + h - 1 - j))
    return cut


def build_frame() -> Image.Image:
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cut = corner_cells(W, H)
    for y in range(H):
        for x in range(W):
            if (x, y) in cut:
                continue
            d = min(x, y, W - 1 - x, H - 1 - y)     # 到最近边的距离
            if d == 0:
                c = OUTLINE                          # S4 外描边
            elif d == 1:
                # S3 左上光源：上/左亮，下/右暗；角落过渡处优先取暗边
                if y == 1 and x < W - 2:
                    c = HILITE
                elif x == 1 and y < H - 2:
                    c = HILITE
                elif y == H - 2 and x > 1:
                    c = OUTLINE
                elif x == W - 2 and y > 1:
                    c = OUTLINE
                else:
                    c = HILITE
            else:
                c = PLATE                            # 外框台面（比槽亮，读作凸起）
            img.putpixel((x, y), c + (255,))
    # 凹槽 = fill 的嵌位，尺寸与 fill 的可见带完全一致（112×8 @ 8,4）
    for y in range(INSET_T, INSET_T + GH):
        for x in range(INSET_L, INSET_L + GW):
            img.putpixel((x, y), TRACK + (255,))
    return img


def build_fill() -> Image.Image:
    """112×16，可见带 12px（上下各 2px 全透明）。

    透明留白不是装饰，是 A1 的产物：可见带只有 12px 高的图（112×12）会被判违例。
    """
    img = Image.new("RGBA", (GW, H), (0, 0, 0, 0))
    cut = corner_cells(GW, GH, 2, x0=0, y0=INSET_T)   # 圆角贴可见带，不贴画布
    for y in range(INSET_T, H - INSET_B):
        for x in range(GW):
            if (x, y) in cut:
                continue
            img.putpixel((x, y), FILL + (255,))
    return img


def save_indexed(img: Image.Image, path: Path) -> None:
    """PNG-8 + 透明索引（§4.3）。自建调色板保证色值与 RGBA 源逐位一致。

    不用 convert("P", palette=ADAPTIVE)——它会按出现频次重排/量化颜色，
    在 6 色小图上通常没错，但"通常"不足以支撑色值契约。
    """
    colors = sorted({px[:3] for px in img.get_flattened_data() if px[3] > 0})
    pal = [(0, 0, 0)] + colors                    # index 0 留给透明
    idx_of = {c: i + 1 for i, c in enumerate(colors)}

    out = Image.new("P", img.size, 0)
    flat_pal = []
    for c in pal:
        flat_pal += list(c)
    flat_pal += [0] * (768 - len(flat_pal))
    out.putpalette(flat_pal)
    out.putdata([0 if px[3] == 0 else idx_of[px[:3]] for px in img.get_flattened_data()])
    out.save(path, "PNG", optimize=True, transparency=0)

    # 逐位回读校验：索引色导出不得改动任何色值
    back = Image.open(path).convert("RGBA")
    if list(back.get_flattened_data()) != list(img.get_flattened_data()):
        raise SystemExit(f"[gen] 索引色导出改动了像素，已中止：{path.name}")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    frame, fill = build_frame(), build_fill()

    save_indexed(frame, OUT / "ui_bar_frame.png")
    save_indexed(fill, OUT / "ui_bar_fill.png")

    for p, im in ((OUT / "ui_bar_frame.png", frame), (OUT / "ui_bar_fill.png", fill)):
        vis = {px[:3] for px in im.get_flattened_data() if px[3] > 0}
        kb = p.stat().st_size / 1024
        print(f"{p.name:<20} {im.width}x{im.height}  可见色 {len(vis)}  {kb:.1f} KB")
        print(f"   色值: {' '.join('#%02x%02x%02x' % c for c in sorted(vis))}")


if __name__ == "__main__":
    main()
