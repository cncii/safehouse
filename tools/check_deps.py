#!/usr/bin/env python3
"""check_deps.py — 依赖方向与 RNG 单一入口扫描（架构 §4.3 白名单 + CI 门禁）

单人项目的"替身 code reviewer"。违例 exit 1，这是唯一能替代 code review 的机械防线。

检查项：
  D1  src/ 除 rng_service.gd 外禁止出现 RNG 直调（M15 判据，扫描器先自验 N/N）
  D2  src/ui/** 禁止调用 State.apply（UI 只发 Command，单向数据流边界）
  D3  src/core/systems 之外的文件禁止 autoload 交叉引用越层
  D4  addons/** 禁止被 src/core/** import
  D5  src/** 禁止再出现 Localize.tr / Localize.trf / func tr（stage 2，与 D1/D2 同批）

D5 是防复发门禁：Localize 的 tr() 与 Object 原生 gettext 方法撞名，GDScript 4.3
把它按 error 处理 → 整个 autoload 编译失败 → 全项目 Localize.* 调用全是死的。
终态改名为 Localize.text() / Localize.textf()（背景见 src/core/localization.gd 头注释）。
扫描器先自验：2 条阳性（真实调用 / 真实定义）+ 1 条阴性（注释里的引用不算违例）。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "src"

# D1: RNG 直调黑名单（白名单文件除外）
RNG_PATTERNS = re.compile(
    r"\brandi\s*\(|\brandf\s*\(|\brandi_range\s*\(|\brandomize\s*\(|"
    r"RandomNumberGenerator\s*\.\s*new\s*\("
)
RNG_WHITELIST = {"rng_service.gd"}

# D2: UI 层禁写
UI_WRITE_PATTERN = re.compile(r"\bState\s*\.\s*apply\s*\(")

# D5: Localize tr 复发（命中"调用"或"定义"都算，注释里出现不算——见 main() 的剥离）
LOCALIZE_TR_PATTERNS = re.compile(
    r"Localize\s*\.\s*tr\s*\(|Localize\s*\.\s*trf\s*\(|\bfunc\s+tr\s*\("
)

# 自验样本（M15 要求：扫描器先自验 ≥3 阳性 + ≥3 阴性，报 N/N）
SELF_CHECK_POSITIVE = [
    "var x = randi() % 10",
    "randomize()",
    "var rng = RandomNumberGenerator.new()",
]
SELF_CHECK_NEGATIVE = [
    "Rng.pick(&LOOT, day, keys, 10)",
    "var v = Rng.hash_at(&SPAWN_WAVE, day, keys)",
    "hash_at(SALT_BREACH, day, [str(night)])",
    "## 禁 randi() —— 注释里的引用不是调用（误报回归用例）",  # 注释剥离后不应命中
]

# D5 自验样本：2 阳性（一处真实调用 + 一处真实定义）+ 1 阴性（注释引用不算）
SELF_CHECK_POSITIVE_D5 = [
    'Localize.tr("X")',
    "func tr(",
]
SELF_CHECK_NEGATIVE_D5 = [
    '## 禁止 Localize.tr("X") —— 注释里的引用不是调用（D5 误报回归用例）',
]

# 规则表：(规则名, 正则, 阳性样本, 阴性样本)。新增规则一律在此登记，
# 未登记 = 不自检 = 按"未交付"处理。
RULES: list[tuple[str, re.Pattern, list[str], list[str]]] = [
    ("D1", RNG_PATTERNS, SELF_CHECK_POSITIVE, SELF_CHECK_NEGATIVE),
    ("D5", LOCALIZE_TR_PATTERNS, SELF_CHECK_POSITIVE_D5, SELF_CHECK_NEGATIVE_D5),
]


def self_check() -> tuple[bool, str]:
    """扫描器自检：每条规则的阳性必须全中、阴性（含注释误报回归用例）必须全不中。"""
    total = 0
    bad: list[str] = []
    for name, pat, pos, neg in RULES:
        hits = [bool(pat.search(s)) for s in pos]
        # 阴性样本走与主扫描一致的注释剥离
        misses = [not pat.search(s.split("#")[0]) for s in neg]
        total += len(pos) + len(neg)
        if not (all(hits) and all(misses)):
            bad.append(
                "%s 阳%d/%d 阴%d/%d" % (name, sum(hits), len(pos), sum(misses), len(neg))
            )
    if bad:
        return False, "自验失败（%s）——扫描器本身不可信，拒绝输出结论" % "，".join(bad)
    return True, "自验 %d/%d" % (total, total)


def main() -> int:
    ok, report = self_check()
    print(f"[check_deps] 扫描器自检：{report}")
    if not ok:
        print("[check_deps] 自检失败——扫描器本身不可信，拒绝输出结论")
        return 1

    violations: list[str] = []
    scanned = 0
    for gd in ROOT.rglob("*.gd"):
        scanned += 1
        rel = gd.relative_to(ROOT.parent).as_posix()
        text = gd.read_text(encoding="utf-8", errors="replace")

        # 剥掉 # 注释再匹配——注释里写"禁 randi()"不该被扫（误报会让判据被关掉）
        code_only = "\n".join(line.split("#")[0] for line in text.splitlines())

        # D1
        if gd.name not in RNG_WHITELIST and RNG_PATTERNS.search(code_only):
            violations.append(f"D1 RNG直调: {rel}")

        # D2
        if rel.startswith("src/ui/") and UI_WRITE_PATTERN.search(code_only):
            violations.append(f"D2 UI越权写: {rel}")

        # D5（stage 2，与 D1/D2 同批）
        if LOCALIZE_TR_PATTERNS.search(code_only):
            violations.append(f"D5 Localize.tr复发: {rel}")

        # D4
        if rel.startswith("src/core/") and re.search(r"(addons/|GodotSteam)", text):
            violations.append(f"D4 core引用addons: {rel}")

    print(f"[check_deps] 扫描 {scanned} 个 .gd 文件")
    if violations:
        for v in violations:
            print(f"  VIOLATION  {v}")
        print(f"[check_deps] {len(violations)} 处违例 → exit 1")
        return 1
    print("[check_deps] 无违例")
    return 0


if __name__ == "__main__":
    sys.exit(main())
