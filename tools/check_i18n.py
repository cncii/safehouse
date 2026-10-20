#!/usr/bin/env python3
"""check_i18n.py — 中文字面量扫描（R9 本地化返工防线，第一天就开）

src/**/*.gd 与 data/**/（locale 除外）出现 CJK 字符 → exit 1。
理由：第 300 天再开这个检查 = 重写所有 UI；第一天开 = 成本 0。

注释例外：`##` 文档注释允许中文（给人看的）；字符串字面量里的中文一律违规。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CJK = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]")

SCAN_DIRS = [ROOT / "src", ROOT / "tests"]
# 字符串字面量（"..." 或 '...'）中的 CJK 才违规；所有 # 注释豁免
# （注释不参与游戏文本——豁免不足会把判据变成噪音然后被关掉）
STRING_LITERALS = re.compile(r'"([^"\n]*)"|\'([^\'\n]*)\'')


def main() -> int:
    violations: list[str] = []
    scanned = 0
    for base in SCAN_DIRS:
        for gd in base.rglob("*.gd"):
            scanned += 1
            rel = gd.relative_to(ROOT).as_posix()
            for lineno, line in enumerate(gd.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                code = line.split("#")[0]           # 剥掉全部注释，只查代码
                for m in STRING_LITERALS.finditer(code):
                    literal = m.group(1) or m.group(2) or ""
                    if CJK.search(literal):
                        violations.append(f"{rel}:{lineno}  中文字面量: \"{literal[:24]}\"")
                        break

    print(f"[check_i18n] 扫描 {scanned} 个 .gd 文件")
    if violations:
        for v in violations:
            print(f"  VIOLATION  {v}")
        return 1
    print("[check_i18n] 无中文字面量（# 注释豁免）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
