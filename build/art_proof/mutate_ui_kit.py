#!/usr/bin/env python3
"""mutate_ui_kit.py — 对 gen_ui_kit.py 的 19 条判据做变异测试

为什么必须做：判据全绿有两种可能——素材对，或者判据抓不到东西。
本项目已踩过太多次第二种（恒真式、空转假绿、历史残留假绿）。这里逐个
往素材里"打洞"，看每条判据是否真的会红，以及**有没有哪条判据从没红过**
（死判据 = 白写）。

每个变异体都做两件事：
  1) 先确认变异体**确实制造了缺陷**（图真的变了）——否则"没被抓到"
     分不清是判据弱还是变异无效；
  2) 再用同一套判据（`gen_ui_kit.run_checks` / `kit_checks`）审，
     收集所有报红的 label。

★ 关键设计：对"改设计表（STATES）"的变异体，审查期望值必须用**变异后的**
  STATES。否则 c_probe 会先全红，把 k_* 那几条语义判据的功劳盖住——
  我们就永远不知道"悬停更亮"这种判据到底会不会红。

用法：
  python build/art_proof/mutate_ui_kit.py            # 跑全部
  python build/art_proof/mutate_ui_kit.py --verbose  # 打印每个变异体的红字详情
退出码：0 = 每个变异体都被抓到且无死判据；1 = 有漏网或有死判据。
"""
import copy
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_ui_kit as G  # noqa: E402

# 全部判据 label（从生成器读单一来源，**不要在这里手抄一份**）
# 手抄过一次的教训：改名时只改实现没改这份清单，mutate 把改名后的判据
# 误报成"死判据"，看着像判据失效，其实是对不上名字。
ALL_LABELS = G.UNIT_LABELS + G.KIT_LABELS


def base():
    return (G.build_all(), [list(x) for x in G.SPEC], copy.deepcopy(G.STATES))


def judge(made, spec, states):
    """跑全套判据，返回报红的 label（去重保序）。"""
    bad = []
    for name, w, h, m, state in spec:
        for label, detail in G.run_checks(made[name], states[state], name, w, h, m):
            bad.append((label, detail))
    for label, detail in G.kit_checks(made):
        bad.append((label, detail))
    seen, out = set(), []
    for label, detail in bad:
        if label not in seen:
            seen.add(label)
            out.append((label, detail))
    return out


def redraw(made, spec, states, r=None, only=None):
    """用（可能被改过的）states 重画全部件。r 可覆盖圆角台阶数。"""
    kw = {} if r is None else {"r": r}
    for name, w, h, m, state in spec:
        if only and name != only:
            continue
        st = states[state]
        made[name] = G.slab(w, h, st["edge"], st["bhi"], st["blo"], st["plane"], **kw)


def slab_and_bug(w, h, edge, bhi, blo, plane, r=G.R_STEPS):
    """M17 的载体：把 `y == 1 or x == 1` 手滑成 `and`。
    只有单点 (1,1) 算上左斜面，四条边全变暗——最典型的一处真 bug。"""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cut = G.corner_cells(w, h, r, x0=0, y0=0)
    for y in range(h):
        for x in range(w):
            if (x, y) in cut:
                continue
            d = min(x, y, w - 1 - x, h - 1 - y)
            if d == 0:
                c = edge
            elif d == 1:
                c = bhi if (y == 1 and x == 1) else blo
            else:
                c = plane
            img.putpixel((x, y), c + (255,))
    return img


# ══ 变异体 ══════════════════════════════════════════════════════════════
# 每个函数返回 (made, spec, states)。变异点写在一行里，便于人核对。

def v01_no_round():
    """圆角整个没做（直角）—— 探针全避开角，只有圆角判据能抓。"""
    made, spec, st = base()
    redraw(made, spec, st, r=0)
    return made, spec, st


def v02_round3():
    """圆角做成 3 级台阶（(2,0) 被切掉）—— 切多了。"""
    made, spec, st = base()
    redraw(made, spec, st, r=3)
    return made, spec, st


def v03_plane_highlight():
    """normal 平面填成高光色 #847e87（图和表一起错，逐点断言抓不到）。"""
    made, spec, st = base()
    st["normal"]["plane"] = G.HILITE
    redraw(made, spec, st, only=None)
    return made, spec, st


def v04_hover_no_lift():
    """hover 忘了提亮（平面还是 BASE）→ hover 与 normal 成同一张图。"""
    made, spec, st = base()
    st["hover"]["plane"] = G.BASE
    redraw(made, spec, st)
    return made, spec, st


def v05_pressed_not_inverted():
    """pressed 斜面没反转（还是上左亮下右暗）→ 按下去看着是凸的。"""
    made, spec, st = base()
    st["pressed"]["bhi"], st["pressed"]["blo"] = G.HILITE, G.OUTLINE
    redraw(made, spec, st)
    return made, spec, st


def v06_disabled_lit():
    """disabled 下右斜面恢复成高光色 → 还带着方向光。"""
    made, spec, st = base()
    st["disabled"]["blo"] = G.HILITE
    redraw(made, spec, st)
    return made, spec, st


def v07_panel_pattern():
    """面板上条里画虚线 —— 本地看是装饰，九宫拉宽后变成一排重复竖纹。"""
    made, spec, st = base()
    img = made["ui_panel_dialog"]
    for x in range(8, img.width - 8):
        if (x // 3) % 2 == 0:
            img.putpixel((x, 3), G.HILITE + (255,))
    return made, spec, st


def v08_semi_alpha():
    """一个像素 alpha=128（羽化边缘残留）。"""
    made, spec, st = base()
    made["ui_btn_base_normal"].putpixel((48, 16), G.BASE + (128,))
    return made, spec, st


def v09_off_by_one():
    """一个像素写成 #d97726（#df7126 差 1）—— A4 只数色数，这条必须由 ∈DB32 兜。"""
    made, spec, st = base()
    made["ui_btn_base_normal"].putpixel((48, 16), (0xD9, 0x77, 0x26, 255))
    return made, spec, st


def v10_size_drift():
    """图做成 112×32，契约仍是 96×32（112 仍是 16 倍数，只有尺寸判据能抓）。"""
    made, spec, st = base()
    st_ = st["normal"]
    made["ui_btn_base_normal"] = G.slab(112, 32, st_["edge"], st_["bhi"], st_["blo"], st_["plane"])
    return made, spec, st


def v11_grid_drift():
    """图和契约一起改成 104×32 —— 尺寸自洽，只有 16 倍数判据能抓。"""
    made, spec, st = base()
    st_ = st["normal"]
    made["ui_btn_base_normal"] = G.slab(104, 32, st_["edge"], st_["bhi"], st_["blo"], st_["plane"])
    for row in spec:
        if row[0] == "ui_btn_base_normal":
            row[1] = 104
    return made, spec, st


def v12_margin_too_small():
    """九宫边距压到 2px（< 圆角占位 3px）→ 拉伸时圆角被啃。"""
    made, spec, st = base()
    for row in spec:
        row[3] = 2
    return made, spec, st


def v13_slot_copy_paste():
    """slot_hover 直接拷了 normal（复制文件忘改）—— 三态里有一态是假的。"""
    made, spec, st = base()
    made["ui_slot_item_hover"] = made["ui_slot_item_normal"].copy()
    return made, spec, st


def v14_too_many_colors():
    """撒 4 种额外的 DB32 色 → 7 色。色值全部合规，只有色数判据能抓。"""
    made, spec, st = base()
    img = made["ui_btn_base_normal"]
    for i, c in enumerate([(0xAC, 0x32, 0x32), (0x6A, 0xBE, 0x30),
                           (0x30, 0x60, 0x82), (0xEE, 0xC3, 0x9A)]):
        img.putpixel((40 + i * 4, 16), c + (255,))
    return made, spec, st


def v15_blank():
    """一件整张全透明（空文件冒充"合规"）。"""
    made, spec, st = base()
    made["ui_panel_small"] = Image.new("RGBA", (96, 64), (0, 0, 0, 0))
    return made, spec, st


def v16_selected_no_accent():
    """selected 丢了强调色（斜面回到普通高光）→ 选中态和常态长得一样。"""
    made, spec, st = base()
    st["selected"]["bhi"] = st["selected"]["blo"] = G.HILITE
    redraw(made, spec, st)
    return made, spec, st


def v17_bevel_or_and():
    """`or` 手滑成 `and`：只有 (1,1) 算上左斜面，四条边全暗。"""
    made, spec, st = base()
    for name, w, h, m, state in spec:
        s = st[state]
        made[name] = slab_and_bug(w, h, s["edge"], s["bhi"], s["blo"], s["plane"])
    return made, spec, st


def v18_transparent_row():
    """顶行整行透明（用透明留白换"可见尺寸"，A1 判的是文件尺寸所以不会拦）。"""
    made, spec, st = base()
    img = made["ui_panel_dialog"]
    for x in range(img.width):
        img.putpixel((x, 0), (0, 0, 0, 0))
    return made, spec, st


def v19_normal_inverted():
    """normal 斜面左右弄反（右上受光）—— S3 左上光源被违反。"""
    made, spec, st = base()
    st["normal"]["bhi"], st["normal"]["blo"] = G.OUTLINE, G.HILITE
    redraw(made, spec, st)
    return made, spec, st


def v20_hover_flat():
    """hover 两侧斜面同色（跟着 disabled 一起变平）→ 悬停失去立体感。"""
    made, spec, st = base()
    st["hover"]["bhi"] = st["hover"]["blo"] = G.HILITE
    redraw(made, spec, st)
    return made, spec, st


VARIANTS = [
    ("V1  圆角 r=0（直角）", v01_no_round),
    ("V2  圆角 r=3（切多了）", v02_round3),
    ("V3  normal 平面=高光色", v03_plane_highlight),
    ("V4  hover 忘了提亮", v04_hover_no_lift),
    ("V5  pressed 斜面没反转", v05_pressed_not_inverted),
    ("V6  disabled 带方向光", v06_disabled_lit),
    ("V7  面板上条画虚线", v07_panel_pattern),
    ("V8  单像素 alpha=128", v08_semi_alpha),
    ("V9  单像素差 1 的近似色", v09_off_by_one),
    ("V10 尺寸漂到 112 宽", v10_size_drift),
    ("V11 尺寸+契约一起改 104", v11_grid_drift),
    ("V12 九宫边距压到 2px", v12_margin_too_small),
    ("V13 slot_hover 拷贝 normal", v13_slot_copy_paste),
    ("V14 撒 4 色（共 7 色）", v14_too_many_colors),
    ("V15 一件全透明", v15_blank),
    ("V16 selected 丢强调色", v16_selected_no_accent),
    ("V17 斜面 or→and", v17_bevel_or_and),
    ("V18 顶行透明", v18_transparent_row),
    ("V19 normal 斜面弄反", v19_normal_inverted),
    ("V20 hover 两侧同色", v20_hover_flat),
]


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    verbose = "--verbose" in sys.argv

    # 先确认基线全绿（否则变异测试没有意义）
    made0, spec0, st0 = base()
    base_bad = judge(made0, spec0, st0)
    if base_bad:
        print("[mutate] 基线不绿，变异测试无意义：")
        for label, detail in base_bad:
            print(f"   [{label}] {detail}")
        return 1
    print(f"[mutate] 基线 {len(ALL_LABELS)} 条判据全绿 ✓ 开始注入 {len(VARIANTS)} 个变异体\n")

    covered = {}
    escaped = []
    for title, fn in VARIANTS:
        made, spec, st = fn()

        # ① 先验"变异确实制造了缺陷"（防变异体本身写错 = 空变异）
        changed = sum(1 for k in made0
                      if made[k].tobytes() != made0[k].tobytes())
        spec_changed = spec != spec0
        if changed == 0 and not spec_changed:
            print(f"{title:<26} ✗ 变异无效（图与基线逐字节相同）")
            escaped.append(title)
            continue

        # ② 再让判据审
        bad = judge(made, spec, st)
        if not bad:
            print(f"{title:<26} ✗ 漏网（{changed} 件被改，无判据报红）")
            escaped.append(title)
            continue

        labels = [b[0] for b in bad]
        for lb in labels:
            covered.setdefault(lb, []).append(title.split()[0])
        print(f"{title:<26} 捕获 ← {'、'.join(labels)}")
        if verbose:
            for label, detail in bad:
                print(f"      [{label}] {detail}")

    # ③ 死判据检查：哪条从没红过
    dead = [lb for lb in ALL_LABELS if lb not in covered]
    print(f"\n[mutate] 判据覆盖 {len(ALL_LABELS) - len(dead)}/{len(ALL_LABELS)}"
          f"  变异体 {len(VARIANTS) - len(escaped)}/{len(VARIANTS)} 被捕获")
    if dead:
        print(f"[mutate] ★ 死判据（从未被打红，等于白写）：{'、'.join(dead)}")
    if escaped:
        print(f"[mutate] ★ 漏网变异体：{'、'.join(escaped)}")

    # 多判据同时红是正常的（一条性质有多个面），但要把"一红一大片"报出来，
    # 否则某条判据可能只是被别人的变异顺带打红，独立性存疑。
    wide = {lb: v for lb, v in covered.items() if len(v) > 3}
    if wide:
        print("[mutate] 备注：以下判据被 >3 个变异体打红（正常，因为共用斜面/平面锚点）：")
        for lb, v in wide.items():
            print(f"   {lb}: {len(v)} 个")

    return 0 if not dead and not escaped else 1


if __name__ == "__main__":
    sys.exit(main())
