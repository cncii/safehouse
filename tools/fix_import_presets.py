#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_import_presets.py — 把 .import 的 [params] 段对齐到导入规格（check_import_presets 的修法）

为什么需要它：
  Godot 首次导入时用的是**内建默认值**，其中两条对像素美术是有害的：
    process/fix_alpha_border=true   → 侵蚀透明留白（我们靠图内透明边距对齐状态条）
    detect_3d/compress_to=1         → 被 3D 引用时悄悄切成 VRAM 压缩
  两条都不报错、不警告。每加一批素材就要改一遍，手改 10 个文件必错一次，
  所以把"改"也机械化。

职责边界：
  **只改** [params] 段里属于规格的键，其余段落（uid / path / metadata / deps）一个字节不动。
  不新建文件、不删键、不碰 assets 之外的东西。

用法：
  python tools/fix_import_presets.py --dry-run   # 只看要改什么
  python tools/fix_import_presets.py             # 实际写入
之后必须重跑一次 Godot 导入，参数才会生效到 .ctex：
  Godot_v4.3-stable_win64_console.exe --headless --import --path .
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"

# 规格从校验器导入——修复和校验必须用同一份规格，否则会出现
# "修完还是不达标"的死循环。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_import_presets import SPECS  # noqa: E402


def patch_text(text: str, spec: dict) -> tuple:
    """返回 (新文本, 改动列表)。只动 [params] 段里 key 命中 spec 的行。"""
    lines = text.splitlines()
    out = []
    in_params = False
    params_end = -1          # [params] 段中最后一个内容行的下标
    seen = set()
    changes = []

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_params = stripped == "[params]"
            out.append(line)
            if in_params:
                params_end = len(out) - 1
            continue
        if in_params and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in spec:
                want = spec[key]
                if stripped != f"{key}={want}":
                    changes.append(f"{key}: {stripped.split('=', 1)[1]} -> {want}")
                    out.append(f"{key}={want}")
                else:
                    out.append(line)
                seen.add(key)
                params_end = len(out) - 1
                continue
            params_end = len(out) - 1
        out.append(line)

    missing = [k for k in spec if k not in seen]
    if missing and params_end >= 0:
        add = [f"{k}={spec[k]}" for k in missing]
        out[params_end + 1:params_end + 1] = add
        changes += [f"补缺失键 {a}" for a in add]

    return "\n".join(out) + ("\n" if text.endswith("\n") else ""), changes


def main() -> int:
    ap = argparse.ArgumentParser(description="对齐 .import 参数到导入规格")
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写盘")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    files = sorted(ASSETS.rglob("*.import"))
    if not files:
        print("assets/ 下没有 .import")
        return 0

    touched = 0
    for imp in files:
        src = Path(str(imp)[:-len(".import")])
        entry = SPECS.get(src.suffix.lower())
        if entry is None:
            continue
        _kind, spec = entry
        text = imp.read_text(encoding="utf-8")
        new, changes = patch_text(text, spec)
        rel = imp.relative_to(ROOT).as_posix()
        if not changes:
            continue
        touched += 1
        print(f"{rel}")
        for c in changes:
            print(f"    {c}")
        if not args.dry_run:
            imp.write_text(new, encoding="utf-8")

    if touched == 0:
        print(f"扫描 {len(files)} 个 .import：全部已符合规格")
        return 0
    print(f"\n{'（dry-run，未写盘）' if args.dry_run else ''}共 {touched} 个文件"
          f"{'待' if args.dry_run else '已'}修正")
    if not args.dry_run:
        print("下一步：跑一次 Godot --headless --import，参数才会落到 .ctex")
    return 0


if __name__ == "__main__":
    sys.exit(main())
