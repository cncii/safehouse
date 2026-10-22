#!/usr/bin/env python3
"""check_palette_conformance.py — 契约 S2 的机器判据（色板一致性）

为什么需要这个工具（与 check_assets.py 的分工）：

  check_assets.py 的 A4 只判「单文件唯一色数 <= 32」。
  它判不了「这 32 色到底是不是 target palette 里的 32 色」——
  一张 32 色但整张都在 DB32 之外的图，A4 直接放行。

  而契约 S2 的原文是「单素材 <=32 色；全项目统一 target palette」。
  第二条（统一）在机器上此前完全没有判据，只能靠人眼看并排对比图。
  本工具补的就是这一条。

判据（逐条对应契约条款）：
  P1 色板归属：所有可见像素的颜色必须**严格等于** DB32 的某一色（不是"接近"）
  P2 alpha 二值：alpha 只允许 0 或 255（契约 §3「Alpha 只允许 0 或 255」）
  P3 非空素材：单文件可见像素数 > 0（防空文件冒充"合规"）
  P4 LUT 自洽：色板 LUT 图的颜色集合必须与冻结的 32 色**完全一致**
                （防 LUT 被悄悄改动后，全项目跟着一起错）

退出码：
  0  全部合规
  1  有违例
  2  not_effective：扫描目录内 0 个 PNG，不计通过也不计失败

用法：
  python tools/check_palette_conformance.py                    # 扫 assets/
  python tools/check_palette_conformance.py --dir <path>       # 扫指定目录（用于跑负样本）
  python tools/check_palette_conformance.py --selftest         # 只跑判据自验
"""
import argparse
import sys
from pathlib import Path

# ── 冻结色板（唯一来源：docs/style_contract.md §3.2 Target Palette 表）──────────
# 顺序与 LUT 图横向排列顺序一致（第 i 列 = DB32[i]）。
DB32_HEX = [
    "000000", "222034", "45283c", "663931", "8f563b", "df7126", "d9a066", "eec39a",
    "fbf236", "99e550", "6abe30", "37946e", "4b692f", "524b24", "323c39", "3f3f74",
    "306082", "5b6ee1", "639bff", "5fcde4", "cbdbfc", "ffffff", "9badb7", "847e87",
    "696a6a", "595652", "76428a", "ac3232", "d95763", "d77bba", "8f974a", "8a6f30",
]
DB32 = {tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in DB32_HEX}
LUT_NAME = "ui_palette_db32.png"


def hexs(rgb) -> str:
    return "#%02x%02x%02x" % rgb


def nearest(rgb) -> str:
    """最接近的 DB32 色——只用于报告，不参与判定（判定必须严格相等）。"""
    best, bd = None, None
    for c in DB32:
        d = sum((a - b) ** 2 for a, b in zip(c, rgb))
        if bd is None or d < bd:
            best, bd = c, d
    return hexs(best)


def analyze(img) -> dict:
    """把一张图拆成可判定的三组数据。

    用 getcolors 取全量直方图（比逐像素遍历快，且天然给出每色计数）。
    """
    rgba = img.convert("RGBA")
    w, h = rgba.size
    # maxcolors 必须 >= 总像素数，否则超过上限时返回 None
    hist = rgba.getcolors(maxcolors=w * h)
    if hist is None:  # 理论上不会发生（上限已放到 w*h），保底走逐像素
        hist = {}
        for px in rgba.getdata():
            hist[px] = hist.get(px, 0) + 1
        hist = [(n, px) for px, n in hist.items()]

    visible = [(n, px) for n, px in hist if px[3] > 0]
    semi = [(n, px) for n, px in hist if 0 < px[3] < 255]
    illegal = [(n, px[:3]) for n, px in visible if px[:3] not in DB32 and px[3] == 255]
    # alpha 半透明的像素即便颜色合规也要单独报（P2 是独立条款）
    return {
        "size": (w, h),
        "visible_px": sum(n for n, _ in visible),
        "visible_colors": {px[:3] for _, px in visible},
        "semi": semi,
        "illegal": illegal,
    }


def check_image(path: Path, img) -> list:
    """对单张图跑 P1/P2/P3，返回违例字符串列表。"""
    v = []
    a = analyze(img)
    if a["visible_px"] == 0:
        v.append("P3 非空素材: 可见像素 0 个（整张全透明/空文件不能算合规）")
        return v
    if a["semi"]:
        n = sum(c for c, _ in a["semi"])
        sample = "、".join(f"{hexs(px[:3])}@{px[3]}" for _, px in a["semi"][:3])
        v.append(f"P2 alpha 二值: {n} 个像素 alpha 非 0/255（{sample}…）")
    if a["illegal"]:
        n = sum(c for c, _ in a["illegal"])
        uniq = sorted({c for _, c in a["illegal"]})
        detail = "、".join(f"{hexs(c)}→最近 {nearest(c)}" for c in uniq[:4])
        more = f" 等 {len(uniq)} 种" if len(uniq) > 4 else ""
        v.append(f"P1 色板归属: {n} 个像素不在 DB32 内{more}（{detail}）")
    return v


def check_lut(lut_path: Path, img) -> list:
    """P4：LUT 的颜色集合必须与冻结的 32 色完全一致。"""
    got = {px[:3] for _, px in (img.convert("RGBA").getcolors(
        maxcolors=img.width * img.height) or []) if px[3] > 0}
    if got == DB32:
        return []
    extra = sorted(got - DB32)
    missing = sorted(DB32 - got)
    parts = []
    if extra:
        parts.append("多出 " + "、".join(hexs(c) for c in extra[:5]))
    if missing:
        parts.append("缺少 " + "、".join(hexs(c) for c in missing[:5]))
    return [f"P4 LUT 自洽: {lut_path.name} 与冻结色板不一致（{'；'.join(parts)}）"]


# ── 判据自验 ────────────────────────────────────────────────────────────────
# 目的是回答一个问题：这套判据真的抓得到东西吗？
# 期望值是独立写死的（不是被测函数算出来的），否则就是恒真式。
def selftest() -> bool:
    from PIL import Image

    def img_from(px_list):
        im = Image.new("RGBA", (len(px_list), 1))
        for i, px in enumerate(px_list):
            im.putpixel((i, 0), px)
        return im

    cases = []

    # 正样本 1：全用 DB32 内颜色 + 全透明背景
    cases.append(("正1 DB32 三色+透明", img_from(
        [(0x22, 0x20, 0x34, 255), (0xdf, 0x71, 0x26, 255), (0x00, 0x00, 0x00, 0)]), 0))
    # 正样本 2：边界——正好用满 32 色，必须放行（不能因为"刚好 32"就误杀）
    cases.append(("正2 正好 32 色", img_from(
        [tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,) for h in DB32_HEX]), 0))
    # 正样本 3：单像素、单色
    cases.append(("正3 单像素", img_from([(0xff, 0xff, 0xff, 255)]), 0))
    # 负样本 1：明显越界色
    cases.append(("负1 越界色", img_from([(0x01, 0x02, 0x03, 255)]), 1))
    # 负样本 2：差 1 的"近似色"必须被抓（不然"统一色板"就成了摆设）
    cases.append(("负2 差1近似色", img_from([(0xdf, 0x71, 0x27, 255)]), 1))
    # 负样本 3：半透明羽化边
    cases.append(("负3 alpha=128", img_from([(0xdf, 0x71, 0x26, 128)]), 1))
    # 负样本 4：全透明空文件（空转假绿）
    cases.append(("负4 全透明", img_from([(0, 0, 0, 0)]), 1))

    print("[palette] 判据自验：")
    all_ok = True
    for name, im, want_red in cases:
        v = check_image(Path("<selftest>"), im)
        got_red = 1 if v else 0
        ok = got_red == want_red
        all_ok = all_ok and ok
        print(f"   {'PASS' if ok else 'FAIL'}  {name:<18} 期望={'报红' if want_red else '放行'}"
              f"  实际={'报红' if got_red else '放行'}")
        if not ok and v:
            for line in v:
                print(f"         {line}")
    # 计数必须由用例数算出来，不能写死——写死过的项目会把 7 条显示成 6/6
    n_pass = sum(1 for _, im, want in cases if (1 if check_image(Path("<selftest>"), im) else 0) == want)
    print(f"[palette] 自验 {n_pass}/{len(cases)}" + ("" if all_ok else "（未全过）"))
    return all_ok


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="契约 S2 色板一致性门禁")
    ap.add_argument("--dir", default=None, help="扫描目录（默认 safehouse/assets）")
    ap.add_argument("--selftest", action="store_true", help="只跑判据自验")
    args = ap.parse_args()

    if not selftest():
        print("[palette] 自验未过 —— 判据本身不可信，后续结论作废")
        return 1
    if args.selftest:
        return 0

    from PIL import Image
    root = Path(args.dir) if args.dir else Path(__file__).resolve().parent.parent / "assets"
    pngs = sorted(root.rglob("*.png"))
    if not pngs:
        print(f"[palette] not_effective: {root} 内 0 个 PNG —— 不计通过也不计失败")
        return 2

    violations = []
    for p in pngs:
        rel = p.relative_to(root.parent).as_posix() if root.name != "." else p.name
        try:
            im = Image.open(p)
        except Exception as e:
            violations.append(f"{rel}: 无法打开（{e}）")
            continue
        if p.name == LUT_NAME:
            violations += [f"{rel}: {m}" for m in check_lut(p, im)]
        violations += [f"{rel}: {m}" for m in check_image(p, im)]

    print(f"[palette] 扫描 {len(pngs)} 个 PNG，DB32 冻结色 {len(DB32)} 色")
    if violations:
        for v in violations:
            print(f"  VIOLATION  {v}")
        print(f"[palette] {len(violations)} 项违例")
        return 1
    print("[palette] 无违例：所有可见像素均落在 DB32 内，alpha 均为 0/255")
    return 0


if __name__ == "__main__":
    sys.exit(main())
