#!/usr/bin/env python3
"""gen_ui_bar.py — 生成状态条基准图（几何与包 D 的 HudStyle 对齐）

产物（assets/sprites/ui/）：
  ui_bar_frame.png  112×16   底板/槽（可见 112×14，上下各 1px 透明）
  ui_bar_fill.png   112×16   填充块（可见 104×10，其余透明）

── 为什么是 112 宽 ────────────────────────────────────────────────
包 D 的 `HudStyle.BAR_W = 112.0` 是状态条控件宽度。底板必须与控件同宽，
否则会左右各溢出 (底板宽-112)/2 px（上一版出 128 宽，就多出 16px）。
112 = 7×16，正好也是 A1 要求的 16 倍数——巧合但省事。

── 为什么可见高 14，而文件高 16 ───────────────────────────────────
A1 判的是**文件**宽高必须是 16 倍数（`_multiple_of_16` 对 w 与 h 都判）。
可见高度可以是任意值，用透明行把它补到 16 即可。

可见高取 14 是为了与文字行高一致（`HudStyle.BAR_H(10) + 4` = 14，
被 hud_clock 与 vital_bar 的三处 Label 引用）：条与文字同高，视觉上才对得齐。

★ 但**不要**因此认为行高不变。`VitalBar` 里是
`_bar.custom_minimum_size = Vector2(BAR_W, BAR_H)`，素材高 16 就会让 HBox
的行高从 14 涨到 16（4 行 → 总高 65→71）。**S5 必须重跑**。
上一版注释曾写"行高不变、S5 不用重跑"，那是错的，已删。

── 为什么凹槽是 108 宽，而不是"112 减去 16 的倍数"──────────────
A1 只约束**文件**宽高；文件里可见带多宽是自由的。
所以边框可以四边都取 2px（1px 描边 + 1px 斜面），凹槽自然就是 108×10。
上一版误以为"可见带宽度也得是 16 倍数"，把槽压到 104，结果左右各剩 4px
亮边、上下只剩 2px——四条边不成比例，1× 下看着像两根孤立亮柱。

── ★ 对齐规则：两张图都画在 (0,0) ────────────────────────────────
所有内部偏移（左右 2px、上下 3px）都编码为 PNG 内的透明边距，
所以接入方**不需要记任何偏移量**，两张图同原点叠画即可：

    frame 可见带  x 0..111,  y 1..14      ← 112×14
    凹槽         x 2..109,  y 3..12      ← 108×10
    fill  可见带  x 2..109,  y 3..12      ← 与凹槽逐像素重合

上一版的坑是"fill 要放在 (2,0) 而不是 (2,2)"，靠人记偏移量迟早写错；
这一版把它变成"同原点"，偏移写在图里。

设计（逐条对应 style_contract）：
  S1 16 网格      : 112×16
  S3 左上光源     : 上/左 1px 高光 #847e87，下/右 1px 暗边 #222034
  S4 1px 深色描边 : 外圈 1px #222034，圆角处 r=2 阶梯收边
  §3.1 UI 色子集  : frame 只用到 3 色（#222034 #323c39 #847e87），fill 1 色
  §4.3 像素硬边   : 无色渐变、无羽化，alpha 只有 0/255
  §4.3 索引色导出 : PNG-8 + 透明索引（自建调色板，不用 ADAPTIVE 以免色值漂移）
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "sprites" / "ui"

# ── §3.1 UI 专用子集（本件用到 3 色）────────────────────────────────────
OUTLINE = (0x22, 0x20, 0x34)   # #222034 描边（S4）
TRACK = (0x32, 0x3c, 0x39)     # #323c39 凹槽底色
HILITE = (0x84, 0x7e, 0x87)    # #847e87 面板高光边（左上光源落点）
FILL = (0xff, 0xff, 0xff)      # #ffffff 纯白，由表现组 modulate 成三条语义色

# ── 几何（单位：像素）─────────────────────────────────────────────────
W, H = 112, 16                 # 文件尺寸（须为 16 倍数，A1）

VIS_TOP, VIS_H = 1, 14         # 可见带：y=1..14（上下各 1px 透明补到 16）
BORDER = 2                     # 四边统一 2px（1px 描边 + 1px 斜面）→ 视觉上才协调
GROOVE_X, GROOVE_W = BORDER, W - BORDER * 2    # 2..109，宽 108
GROOVE_Y, GROOVE_H = VIS_TOP + BORDER, VIS_H - BORDER * 2   # 3..12，高 10


def corner_cells(w: int, h: int, r: int, x0: int, y0: int) -> set:
    """r=2 的像素阶梯圆角：首行去 2 格，次行去 1 格。

    x0/y0 让圆角贴着"可见带"而不是整张画布算——上下有透明留白时必须如此，
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
    cut = corner_cells(W, VIS_H, 2, x0=0, y0=VIS_TOP)

    # 边框：d=0 外描边，d=1 斜面（上/左亮、下/右暗）。BORDER=2 → 只需画这两圈，
    # 内侧全部由凹槽覆盖，没有"台面"这一层（上一版 4px 侧边就是因为多画了一层台面）。
    for yv in range(VIS_H):                     # yv = 可见带内坐标 0..13
        y = VIS_TOP + yv
        for x in range(W):
            d = min(x, yv, W - 1 - x, VIS_H - 1 - yv)
            if d >= BORDER:
                continue                        # 内部留给凹槽
            if (x, y) in cut:
                continue                        # r=2 阶梯圆角
            if d == 0:
                c = OUTLINE                     # S4 外描边
            else:
                c = HILITE if (yv == 1 or x == 1) else OUTLINE   # S3 左上光源
            img.putpixel((x, y), c + (255,))

    # 凹槽 = fill 可见带的位置，尺寸完全一致（108×10 @ 2,3）
    for y in range(GROOVE_Y, GROOVE_Y + GROOVE_H):
        for x in range(GROOVE_X, GROOVE_X + GROOVE_W):
            img.putpixel((x, y), TRACK + (255,))
    return img


def build_fill() -> Image.Image:
    """112×16，可见带 108×10 @ (2,3) —— 与凹槽坐标逐像素重合。

    不做圆角：条是从左往右裁切的，右端会被切掉，做圆角只会在左端留一个
    孤立缺口；直角在凹槽里读起来更像仪表。
    """
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for y in range(GROOVE_Y, GROOVE_Y + GROOVE_H):
        for x in range(GROOVE_X, GROOVE_X + GROOVE_W):
            img.putpixel((x, y), FILL + (255,))
    return img


def save_indexed(img: Image.Image, path: Path) -> None:
    """PNG-8 + 透明索引（§4.3）。自建调色板保证色值与 RGBA 源逐位一致。

    不用 convert("P", palette=ADAPTIVE)——它会按频次重排/量化颜色，
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


def visible_bbox(img: Image.Image) -> tuple:
    """可见像素的包围盒 (x0, y0, x1, y1)，闭区间。用于断言对齐。"""
    pts = [(i % img.width, i // img.width)
           for i, px in enumerate(img.get_flattened_data()) if px[3] > 0]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


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

    # ── 对齐断言：fill 可见带必须逐像素落在 frame 的凹槽里 ──
    fb, lb = visible_bbox(frame), visible_bbox(fill)
    need = (GROOVE_X, GROOVE_Y, GROOVE_X + GROOVE_W - 1, GROOVE_Y + GROOVE_H - 1)
    assert fb == (0, VIS_TOP, W - 1, VIS_TOP + VIS_H - 1), f"frame 可见范围异常: {fb}"
    assert lb == need, f"fill 可见带 {lb} 与凹槽 {need} 不重合"
    print(f"[align] frame 可见 {fb}  凹槽/填充 {need}  重合 ✓")


if __name__ == "__main__":
    main()
