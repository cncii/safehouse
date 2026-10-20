#!/usr/bin/env python3
"""check_assets.py — 资产准入门禁（架构 R6 风格契约 + 性能预算的机械化）

规则全部来自已定稿架构（R6 素材拼贴感缓解 / §7 性能预算）：
  A1 像素格：宽高必须是 16 的倍数（16px 网格契约）
  A2 图集：最长边 <= 2048（导入规则，防 VRAM 超预算 #6）
  A3 命名：小写蛇形 + 域前缀（char_/enemy_/item_/tile_/ui_/portrait_/font_）
  A4 色板：单文件唯一色数 <= 32（需 Pillow；不可用则标未生效）

三层空跑判负：assets/ 内 PNG 数 == 0 → 报 "not_effective"，不计通过也不计失败。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "assets"
NAME_OK = re.compile(r"^(char|enemy|item|tile|ui|portrait|font)_[a-z0-9]+(_[a-z0-9]+)*\.png$")

# 函数级自检（3 正 3 负——判据工具先自验报 N/N）
def _multiple_of_16(w: int, h: int) -> bool:
    return w % 16 == 0 and h % 16 == 0

def self_check() -> tuple[bool, str]:
    pos = [(16, 16), (16, 32), (2048, 2048)]
    neg = [(15, 16), (24, 24), (100, 100)]
    hits = sum(1 for w, h in pos if _multiple_of_16(w, h))
    misses = sum(1 for w, h in neg if not _multiple_of_16(w, h))
    return (hits == 3 and misses == 3), f"自验 {hits + misses}/6"

def main() -> int:
    ok, report = self_check()
    print(f"[check_assets] 扫描器自检：{report}")
    if not ok:
        return 1

    pngs = sorted(ROOT.rglob("*.png"))
    if not pngs:
        print(f"[check_assets] not_effective: assets/ 内 0 个 PNG —— 美术组未交付，不计通过")
        return 0

    violations = []
    try:
        from PIL import Image
        has_pil = True
    except ImportError:
        has_pil = False

    for p in pngs:
        rel = p.relative_to(ROOT.parent).as_posix()
        if not NAME_OK.match(p.name):
            violations.append(f"A3 命名: {rel}（需域前缀+小写蛇形）")
        try:
            w, h = Image.open(p).size if has_pil else (None, None)
        except Exception:
            w, h = None, None
        if w is None:
            # 无 Pillow 时退回解析 PNG IHDR（宽高在字节 16-24）
            with open(p, "rb") as f:
                head = f.read(24)
            if len(head) >= 24 and head[:8] == b"\x89PNG\r\n\x1a\n":
                w = int.from_bytes(head[16:20], "big")
                h = int.from_bytes(head[20:24], "big")
        if w is not None:
            if not _multiple_of_16(w, h):
                violations.append(f"A1 像素格: {rel} = {w}x{h}（非 16 倍数）")
            if max(w, h) > 2048:
                violations.append(f"A2 图集: {rel} = {w}x{h}（超 2048）")
            if has_pil:
                colors = Image.open(p).convert("RGBA").getcolors(maxcolors=64)
                if colors is not None and len(colors) > 32:
                    violations.append(f"A4 色板: {rel} {len(colors)} 色（>32，先过 palette_map 再交）")

    print(f"[check_assets] 扫描 {len(pngs)} 个 PNG（Pillow={'有' if has_pil else '无，色板检查未生效'}）")
    if violations:
        for v in violations:
            print(f"  VIOLATION  {v}")
        return 1
    print("[check_assets] 无违例")
    return 0

if __name__ == "__main__":
    sys.exit(main())
