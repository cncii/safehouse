#!/usr/bin/env python3
"""gen_ui_kit.py — UI 件全表生成器（状态条之外的 10 件）

产物（assets/sprites/ui/），全部按 style_contract §4 的尺寸表：

    ui_btn_base_normal.png     96×32   九宫 8/8/8/8
    ui_btn_base_hover.png      96×32   九宫 8/8/8/8
    ui_btn_base_pressed.png    96×32   九宫 8/8/8/8
    ui_btn_base_disabled.png   96×32   九宫 8/8/8/8
    ui_btn_base_selected.png   96×32   九宫 8/8/8/8
    ui_panel_dialog.png       192×112  九宫 8/8/8/8
    ui_panel_small.png         96×64   九宫 8/8/8/8
    ui_slot_item_normal.png    32×32   九宫 4/4/4/4
    ui_slot_item_hover.png     32×32   九宫 4/4/4/4
    ui_slot_item_selected.png  32×32   九宫 4/4/4/4

── 为什么尺寸不能自选 ────────────────────────────────────────────
§4.1 的尺寸全部是 16 的倍数（A1 硬约束），且 dialog 的 192 = 640×30%、
112 = 7×16 能放 5 行 16px 文本；btn 的 32 高 = 16px 字 + 上下各 8px 留白。
改尺寸等于改布局，属设计变更，不是美术自由。

── 为什么圆角只做 2 级台阶，而 §4.2 写 r=4 ──────────────────────
§4.2 通用后处理明确"圆角必须是像素阶梯（硬边 2 级台阶），禁止平滑圆角"。
r=4 是**含描边在内的名义外接半径**，落在像素上是：
    第 0 行切掉 2 格、第 1 行切掉 1 格（+ 1px 描边 = 外轮廓内切 3px）
九宫 8 给了 5px 余量、九宫 4 给了 1px 余量，拉伸时角块不会被压。
（更细的 3~4 级台阶在 1× 下反而像被啃掉一块，且九宫 4 的槽位放不下。）

── 五态怎么区分（这是本批最容易做成"五个一模一样的文件"的地方）──
靠**斜面方向**而不是靠调色，这样只用 §3.1 的 6 色就够：

    态        d=0 描边    d=1 上/左斜面   d=1 下/右斜面   平面
    normal    #222034     #847e87(亮)     #222034(暗)     #323c39
    hover     #222034     #847e87(亮)     #222034(暗)     #595652(亮一档)
    pressed   #222034     #222034(暗)     #847e87(亮)     #595652   ← 斜面反转=凹陷
    disabled  #222034     #595652         #595652         #323c39   ← 两侧同色=无方向光
    selected  #222034     #fbf236(强调)   #fbf236(强调)   #323c39

★ disabled 的落地解释：契约原文"用 #595652 压暗 + 去掉描边高光"。
  我们把 #595652 用作**斜面**而不是描边——因为 SUNKEN 比 BASE 亮
  （luma 86.4 vs 56.7），拿来当描边会让禁用态边框比常态更扎眼，
  与"压暗"相反；而拿它替换 #847e87 高光，正好就是"去掉高光"的字面意思：
  左右两侧同色 → 方向性光照消失 → 视觉上变平、变哑。这是解释，不是改条款。

★ pressed 与 hover 的色集合完全相同（都是 #222034/#595652/#847e87），
  只靠**斜面向量反了**区分。这不是笔误：凹陷态在像素画里的标准做法就是
  反转 bevel，底色不变。`k_distinct` 用逐像素差异而非色集合来判，正是为了
  不被"色集合相同"骗过去。

★ 为什么不用 modulate 做五态：`modulate` 染色是色板门禁（P1）的盲区
  （PNG 本身合规，代码里手调的值没人查）。五态出五张图，色彩全部落盘可验。
  代价是 5 个文件 × 0.9 KB，对 200 MB 预算可忽略。

── 判据为什么是"收集式"而不是直接 assert ────────────────────────
`run_checks` / `kit_checks` 返回失败清单而不抛异常，是为了让
`mutate_ui_kit.py` 能对每个变异体报出"哪几条判据抓到了"。
如果直接 assert，第一个失败就中断，就永远不知道剩下几条是死的。

── 复用 gen_ui_bar 的两个函数 ────────────────────────────────────
`corner_cells`（2 级台阶圆角）与 `save_indexed`（自建调色板 + 逐位回读校验）。
不复制粘贴，避免"索引色导出校验"这类关键逻辑出现两份实现、只修一份。
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_ui_bar import corner_cells, save_indexed  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "sprites" / "ui"

# ── 冻结色板（逐字抄自 docs/style_contract.md §3 DB32 表，勿改）──────────
# 期望值必须独立写死，不从 tools/check_palette_conformance.py 导入——
# 否则那边改错一个色值，生成器和门禁会一起错，两边都绿。
DB32_HEX = [
    "000000", "222034", "45283c", "663931", "8f563b", "df7126", "d9a066", "eec39a",
    "fbf236", "99e550", "6abe30", "37946e", "4b692f", "524b24", "323c39", "3f3f74",
    "306082", "5b6ee1", "639bff", "5fcde4", "cbdbfc", "ffffff", "9badb7", "847e87",
    "696a6a", "595652", "76428a", "ac3232", "d95763", "d77bba", "8f974a", "8a6f30",
]
DB32 = {tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in DB32_HEX}

# ── §3.1 UI 专用子集（本批 10 件共用这 5 色）────────────────────────────
OUTLINE = (0x22, 0x20, 0x34)   # #222034 描边（S4）
BASE = (0x32, 0x3C, 0x39)      # #323c39 底板主色
SUNKEN = (0x59, 0x56, 0x52)    # #595652 底板内凹（悬停提亮 / 禁用斜面）
HILITE = (0x84, 0x7E, 0x87)    # #847e87 面板高光边（S3 左上光源落点）
ACCENT = (0xFB, 0xF2, 0x36)    # #fbf236 强调（选中态）

UI_SUBSET = [OUTLINE, BASE, SUNKEN, HILITE, ACCENT]
for _c in UI_SUBSET:
    assert _c in DB32, f"UI 子集色 {_c} 不在 DB32 内 —— 契约表被改过？"

# ── 状态表（设计输入。slab() 按它画，断言按它验）────────────────────────
# edge / bhi(上左斜面) / blo(下右斜面) / plane(平面)
STATES = {
    "normal":   dict(edge=OUTLINE, bhi=HILITE, blo=OUTLINE, plane=BASE),
    "hover":    dict(edge=OUTLINE, bhi=HILITE, blo=OUTLINE, plane=SUNKEN),
    "pressed":  dict(edge=OUTLINE, bhi=OUTLINE, blo=HILITE, plane=SUNKEN),
    "disabled": dict(edge=OUTLINE, bhi=SUNKEN, blo=SUNKEN, plane=BASE),
    "selected": dict(edge=OUTLINE, bhi=ACCENT, blo=ACCENT, plane=BASE),
    "panel":    dict(edge=OUTLINE, bhi=HILITE, blo=OUTLINE, plane=BASE),
}

# ── §4.1 尺寸表 + §4.2 九宫具名值（左右上下四边同值）────────────────────
# (name, w, h, margin, state)
SPEC = [
    ("ui_btn_base_normal",    96,  32,  8, "normal"),
    ("ui_btn_base_hover",     96,  32,  8, "hover"),
    ("ui_btn_base_pressed",   96,  32,  8, "pressed"),
    ("ui_btn_base_disabled",  96,  32,  8, "disabled"),
    ("ui_btn_base_selected",  96,  32,  8, "selected"),
    ("ui_panel_dialog",      192, 112,  8, "panel"),
    ("ui_panel_small",        96,  64,  8, "panel"),
    ("ui_slot_item_normal",   32,  32,  4, "normal"),
    ("ui_slot_item_hover",    32,  32,  4, "hover"),
    ("ui_slot_item_selected", 32,  32,  4, "selected"),
]

R_STEPS = 2                 # 圆角台阶数（§4.2「硬边 2 级台阶」）
CORNER_SPAN = R_STEPS + 1    # 圆角实际吃掉的行列数（2 级台阶 + 1px 描边 = 3）

BTN_STATES = ("normal", "hover", "pressed", "disabled", "selected")
SLOT_STATES = ("normal", "hover", "selected")


def slab(w: int, h: int, edge, bhi, blo, plane, r: int = R_STEPS) -> Image.Image:
    """画一块带 1px 描边 + 1px 斜面的硬边像素面板。

    d = 到最近边的距离（0 = 外描边圈，1 = 斜面圈，>=2 = 平面）。
    d==1 时按"上/左"与"下/右"分色 —— 这就是 S3 左上光源在 UI 上的全部实现。
    """
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cut = corner_cells(w, h, r, x0=0, y0=0)
    for y in range(h):
        for x in range(w):
            if (x, y) in cut:
                continue
            d = min(x, y, w - 1 - x, h - 1 - y)
            if d == 0:
                c = edge
            elif d == 1:
                c = bhi if (y == 1 or x == 1) else blo
            else:
                c = plane
            img.putpixel((x, y), c + (255,))
    return img


# ══ 判据（每条一个函数，抛 AssertionError 即判红）════════════════════════

def luma(c) -> float:
    """BT.601 明度。只用于性质断言（"悬停更亮"等），不参与出图。"""
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def diff_px(a: Image.Image, b: Image.Image) -> int:
    pa, pb = list(a.get_flattened_data()), list(b.get_flattened_data())
    return sum(1 for x, y in zip(pa, pb) if x != y)


def probes(w: int, h: int) -> dict:
    """6 个采样点，全部取各边中点。

    **一个都不能取在角上**——2 级台阶圆角会把 (0,0) 那 3 格填透明，
    用角当探针等于在测"圆角有没有做"，而不是在测配色（第一版就踩了这个，
    报 'edge_tl(0,0) 期望 #222034 实得透明'）。
    """
    return {
        "edge_left": (0, h // 2),
        "bhi_left": (1, h // 2),
        "bhi_top": (w // 2, 1),
        "blo_right": (w - 2, h // 2),
        "blo_bottom": (w // 2, h - 2),
        "plane": (w // 2, h // 2),
    }


PROBE_FIELD = {"edge_left": "edge", "bhi_left": "bhi", "bhi_top": "bhi",
               "blo_right": "blo", "blo_bottom": "blo", "plane": "plane"}


def c_size(img, w, h, name):
    assert img.size == (w, h), f"{name} 尺寸 {img.size} != 契约 {w}×{h}"


def c_grid(img, w, h, name):
    assert w % 16 == 0 and h % 16 == 0, f"{name} {w}×{h} 非 16 倍数（A1）"


def c_opaque(img, w, h, name):
    """可见区必须等于整张图（没有靠透明留白偷尺寸）。
    用 img.size 而不是传入的 w/h —— 否则这条会连带把"尺寸不对"也报进来，
    变异常测试里就看不出到底是哪条判据抓到的。"""
    assert img.getbbox() == (0, 0) + img.size, f"{name} 有透明留白"


def c_probe(img, st, name):
    """逐点色值：期望值来自 STATES 表（设计输入），不是从 img 反算。"""
    for key, (x, y) in probes(*img.size).items():
        want = st[PROBE_FIELD[key]] + (255,)
        got = img.getpixel((x, y))
        assert got == want, f"{name} @{key}{x, y}: 期望 {want} 实得 {got}"


def c_corners(img, name):
    """四角必须是 2 级台阶斜切（每角切 3 格：(0,0)(1,0)(0,1) 透明，(2,0)(0,2) 实心）。

    这条是补漏：探针全部避开角，所以"忘了做圆角"在上面完全绿（直角也是合法配色）。
    切多了（3 级台阶 → (2,0) 透明）或切少了（1 级 → (1,0) 不透明）都报红。
    """
    w, h = img.size
    corners = {
        "左上": ([(0, 0), (1, 0), (0, 1)], [(2, 0), (0, 2)]),
        "右上": ([(w - 1, 0), (w - 2, 0), (w - 1, 1)], [(w - 3, 0), (w - 1, 2)]),
        "左下": ([(0, h - 1), (1, h - 1), (0, h - 2)], [(2, h - 1), (0, h - 3)]),
        "右下": ([(w - 1, h - 1), (w - 2, h - 1), (w - 1, h - 2)],
                 [(w - 3, h - 1), (w - 1, h - 3)]),
    }
    for cname, (clear, solid) in corners.items():
        for p in clear:
            assert img.getpixel(p)[3] == 0, f"{name} {cname}角 {p} 应透明（2 级台阶）"
        for p in solid:
            assert img.getpixel(p)[3] == 255, f"{name} {cname}角 {p} 应实心"


def c_tileable(img, m, name):
    """九宫边条沿**拉伸方向**必须平移不变。

    九宫拉伸时上中块沿 x 重复 1px 切片、左中块沿 y 重复 1px 切片。
    所以判据不是"整条单色"（上中块本身含描边+斜面+平面三层，本来就不是单色，
    第一版就是这么写错的），而是：**每列（上/下条）或每行（左/右条）的色序列
    必须完全相同**。有一列不同，拉伸后那一列就成一条竖纹——九宫最常见的
    "本地看没问题、拉宽就花"故障，A1~A4 一条都抓不到。
    """
    w, h = img.size

    def col(x, y0, y1):
        return tuple(img.getpixel((x, y)) for y in range(y0, y1))

    def row(y, x0, x1):
        return tuple(img.getpixel((x, y)) for x in range(x0, x1))

    bands = {
        "上条(沿x)": [col(x, 0, m) for x in range(m, w - m)],
        "下条(沿x)": [col(x, h - m, h) for x in range(m, w - m)],
        "左条(沿y)": [row(y, 0, m) for y in range(m, h - m)],
        "右条(沿y)": [row(y, w - m, w) for y in range(m, h - m)],
    }
    bad = [f"{b} 有 {len(set(v))} 种切片" for b, v in bands.items() if len(set(v)) != 1]
    assert not bad, f"{name} 九宫边条不平整，拉伸会出重复纹：{'；'.join(bad)}"


def c_margin(m, name):
    """圆角占位必须小于九宫边距，否则拉伸时圆角被压、出现断角。"""
    assert CORNER_SPAN < m, (
        f"{name} 九宫边距 {m} <= 圆角占位 {CORNER_SPAN}px —— 拉伸会啃掉圆角")


def c_alpha(img, name):
    alphas = {px[3] for px in img.get_flattened_data()}
    assert alphas <= {0, 255}, f"{name} 存在半透明像素：{sorted(alphas)}"


def c_color_count(img, name):
    vis = {px[:3] for px in img.get_flattened_data() if px[3] > 0}
    assert len(vis) <= 6, f"{name} 可见 {len(vis)} 色 > 6（§4.3 上限）"


def c_db32(img, name):
    """色数达标 ≠ 色值合规。两条分开判，否则"7 色但都在 DB32 内"和
    "3 色但有一个差 1"会挤在同一条 label 里，变异测试分不清谁抓到的。"""
    out = sorted({px[:3] for px in img.get_flattened_data() if px[3] > 0} - DB32)
    assert not out, f"{name} 有 DB32 之外的色：{' '.join('#%02x%02x%02x' % c for c in out)}"


def c_plane_family(st, name):
    """平面色只能是底板色族（BASE / SUNKEN）。

    逐点断言只保证"图和 STATES 表一致"，抓不到"STATES 表本身写错"——
    比如把 normal 的平面填成高光色 #847e87，图和表一起错，逐点断言照样全绿。
    这条语义约束补的就是这个洞：平面用描边色或高光色都会红。
    """
    assert st["plane"] in (BASE, SUNKEN), (
        f"{name} 平面色 #%02x%02x%02x 不属于底板色族（#323c39/#595652）" % st["plane"])


# ── 判据清单（label 是判据的身份，只在这一处定义）──────────────────────
# 变异测试用这两个清单判断"哪条判据从没红过 = 死判据"。
# 踩过的坑：改名时只改了实现没改 mutate 脚本里的清单，结果 mutate 报
# "强调色最亮且只在边框 从未响应" —— 看着像死判据，其实是标签对不上。
# 所以在下面 _assert_labels 里让清单与实现逐项对齐，改名漏改会当场炸。
UNIT_LABELS = [
    "尺寸=契约", "16倍数", "无透明留白", "逐点色值", "平面属底板色族",
    "圆角2级台阶", "九宫可平铺", "圆角<边距", "alpha二值", "色数≤6", "∈DB32",
]
KIT_LABELS = [
    "五态两两差异≥200px", "悬停更亮", "常态左上受光", "按下斜面反转",
    "禁用无方向光", "非禁用保留方向光", "选中用强调色且不染平面", "物品格三态同源",
]


def _run(cases):
    """cases = [(label, fn, args)]。返回失败 [(label, detail)]。"""
    out = []
    for label, fn, args in cases:
        try:
            fn(*args)
        except AssertionError as e:
            out.append((label, str(e)))
    return out


def _assert_labels(got, want, what):
    if got != want:
        raise SystemExit(
            f"[gen] {what} 判据清单与实现不一致（改名漏改？）\n"
            f"  实现: {got}\n  清单: {want}")


# ── 单件判据集合 ────────────────────────────────────────────────────────
def unit_cases(img, st, name, w, h, m):
    return [
        ("尺寸=契约", c_size, (img, w, h, name)),
        ("16倍数", c_grid, (img, w, h, name)),
        ("无透明留白", c_opaque, (img, w, h, name)),
        ("逐点色值", c_probe, (img, st, name)),
        ("平面属底板色族", c_plane_family, (st, name)),
        ("圆角2级台阶", c_corners, (img, name)),
        ("九宫可平铺", c_tileable, (img, m, name)),
        ("圆角<边距", c_margin, (m, name)),
        ("alpha二值", c_alpha, (img, name)),
        ("色数≤6", c_color_count, (img, name)),
        ("∈DB32", c_db32, (img, name)),
    ]


def run_checks(img, st, name, w, h, m):
    """返回失败判据 [(label, detail)]；空列表 = 全过。"""
    cases = unit_cases(img, st, name, w, h, m)
    _assert_labels([c[0] for c in cases], UNIT_LABELS, "单件")
    return _run(cases)


# ── 整套判据（跨文件性质，单件判据抓不到）───────────────────────────────
def pick(img, key):
    """从**素材本身**取一个采样点的颜色。

    ★ 这一句是 5 条语义判据的生死线。第一版这些判据直接读模块级 `STATES`
    （设计表），于是验的是"设计表自不自洽"，跟素材长什么样无关——
    变异测试一跑就露馅：20 个变异体里有 5 条判据从未红过，全是死的。
    判据的输入必须来自被测系统实际产出的数据，不是它声称的规格。
    """
    return img.getpixel(probes(*img.size)[key])[:3]


def kit_checks(made):
    btn = {s: made[f"ui_btn_base_{s}"] for s in BTN_STATES}
    slot = {s: made[f"ui_slot_item_{s}"] for s in SLOT_STATES}

    def k_distinct():
        """任意两态必须明显不同 —— 防"五个文件内容相同"这种交付缺陷。
        用逐像素差异而不是色集合：pressed 与 hover 的色集合**刻意相同**，
        色集合判据会把一个正确的实现判成重复。"""
        for i, a in enumerate(BTN_STATES):
            for b in BTN_STATES[i + 1:]:
                d = diff_px(btn[a], btn[b])
                # 阈值贴着性质取：最近的一对只差 d==1 整圈，
                # 96×32 的 d==1 圈 = 2×(96+32) − 4 = 252 px。取 200 留 20% 余量。
                assert d >= 200, f"按钮 {a} 与 {b} 仅差 {d} px —— 两态视觉上分不出来"

    def k_hover_brighter():
        n, hv = luma(pick(btn["normal"], "plane")), luma(pick(btn["hover"], "plane"))
        assert hv > n, f"hover 平面 luma {hv:.1f} 未高于 normal {n:.1f} —— 悬停无正向反馈"

    def k_normal_lit():
        hi = luma(pick(btn["normal"], "bhi_left"))
        lo = luma(pick(btn["normal"], "blo_right"))
        assert hi > lo, f"normal 上左 luma {hi:.1f} 未亮于下右 {lo:.1f} —— 违反 S3 左上光源"

    def k_pressed_inverted():
        hi = luma(pick(btn["pressed"], "bhi_left"))
        lo = luma(pick(btn["pressed"], "blo_right"))
        assert hi < lo, f"pressed 上左 {hi:.1f} 未暗于下右 {lo:.1f} —— 斜面没反转，按下去是凸的"

    def k_disabled_flat():
        """禁用必须失去方向性光照 —— 这就是"去掉描边高光"的可判形式。"""
        a, b = pick(btn["disabled"], "bhi_left"), pick(btn["disabled"], "blo_right")
        assert a == b, (f"disabled 两侧斜面 #%02x%02x%02x / #%02x%02x%02x 不同"
                        f" —— 还带着方向光" % (a + b))

    def k_lit_kept():
        """非禁用态必须保留左上光源。selected **豁免**：它用一整圈强调色做选中框，
        是刻意的"框住"语义；强行要求两侧异色等于否掉选中态的设计目的。"""
        for s in ("normal", "hover", "pressed"):
            a, b = pick(btn[s], "bhi_left"), pick(btn[s], "blo_right")
            assert a != b, f"{s} 两侧斜面同色（#%02x%02x%02x）—— 失去立体感" % a

    def k_accent():
        """期望值是写死的 #fbf236，不从 UI_SUBSET 反算 —— 反算等于用设计表验设计表。"""
        want = (0xFB, 0xF2, 0x36)
        got = pick(btn["selected"], "bhi_left")
        assert got == want, "selected 左斜面实得 #%02x%02x%02x（应 #fbf236 强调色）" % got
        got2 = pick(btn["selected"], "blo_right")
        assert got2 == want, "selected 右斜面实得 #%02x%02x%02x（应 #fbf236 强调色）" % got2
        plane = pick(btn["selected"], "plane")
        assert plane == (0x32, 0x3C, 0x39), \
            "selected 平面实得 #%02x%02x%02x（应保持 #323c39，强调只走边框）" % plane

    def k_slot_same_geo():
        """物品格三态必须同源：几何一致，只有配色差。
        diff==0 说明复制文件忘改；diff==整张说明形状都不一样了。"""
        total = 32 * 32
        for a, b in (("normal", "hover"), ("normal", "selected")):
            d = diff_px(slot[a], slot[b])
            assert 0 < d < total, f"slot {a} vs {b} 差异 {d}/{total}（0=忘改，满=几何变了）"

    cases = [
        ("五态两两差异≥200px", k_distinct, ()),
        ("悬停更亮", k_hover_brighter, ()),
        ("常态左上受光", k_normal_lit, ()),
        ("按下斜面反转", k_pressed_inverted, ()),
        ("禁用无方向光", k_disabled_flat, ()),
        ("非禁用保留方向光", k_lit_kept, ()),
        ("选中用强调色且不染平面", k_accent, ()),
        ("物品格三态同源", k_slot_same_geo, ()),
    ]
    _assert_labels([c[0] for c in cases], KIT_LABELS, "整套")
    return _run(cases)


def build_all() -> dict:
    """按 SPEC 造全部件（不落盘）。变异测试复用同一入口。"""
    made = {}
    for name, w, h, m, state in SPEC:
        st = STATES[state]
        made[name] = slab(w, h, st["edge"], st["bhi"], st["blo"], st["plane"])
    return made


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    made = build_all()

    allbad = []
    for name, w, h, m, state in SPEC:
        for label, detail in run_checks(made[name], STATES[state], name, w, h, m):
            allbad.append(f"[{label}] {detail}")
    for label, detail in kit_checks(made):
        allbad.append(f"[{label}] {detail}")

    if allbad:
        print("[gen] 判据未过，已中止（不落盘脏素材）：")
        for b in allbad:
            print("   " + b)
        return 1

    print(f"{'文件':<26}{'尺寸':<10}{'九宫':<6}{'色数':<5}色值")
    print("-" * 96)
    for name, w, h, m, _s in SPEC:
        save_indexed(made[name], OUT / f"{name}.png")
        img = made[name]
        vis = sorted({px[:3] for px in img.get_flattened_data() if px[3] > 0})
        kb = (OUT / f"{name}.png").stat().st_size / 1024
        print(f"{name + '.png':<26}{f'{w}×{h}':<10}{m:<6}{len(vis):<5}"
              f"{' '.join('#%02x%02x%02x' % c for c in vis)}  {kb:.1f}KB")

    n_unit = len(SPEC) * 11
    n_kit = 8
    print(f"\n[assert] 单件判据 {n_unit} 条（10 件 × 11）全过 ✓")
    print(f"[assert] 整套判据 {n_kit} 条全过 ✓")
    print(f"[assert] 产出 {len(SPEC)} 个 PNG，合计 "
          f"{sum((OUT / f'{n}.png').stat().st_size for n, *_ in SPEC) / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
