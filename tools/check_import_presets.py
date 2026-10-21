#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_import_presets.py — 素材导入参数一致性校验（架构 §7.3「统一 import preset」门禁）。

为什么不是「在 project.godot 里写 [importer_defaults]」：
  `project.godot` 归主理人所有，任务书 §3 明令禁改。而 Godot 4 的项目级导入默认值
  只能写在 `project.godot` 的 `[importer_defaults]` 段。所以这里换一条等价路线：
  **把规格写成可校验的判据**，扫描所有 `.import` 的 `[params]` 段与之比对。
  新增素材照 `assets/import_presets/README.md` 的参数表设置，本脚本负责兜底。

为什么需要它（真实风险，不是形式主义）：
  Godot 对字体的默认导入是 `antialiasing=1`（灰度抗锯齿）+ `subpixel_positioning=1`
  （亚像素定位）。对**像素字体**这两个默认值的后果是：12px 的字被灰化、字落在半像素上，
  在 640×360 整数缩放下糊成一团。默认 `allow_system_fallback=true` 还会让缺字静默回退到
  系统字体——开发机上看着正常，玩家机器上变豆腐块。这三条都不会报错，只能靠规格拦住。

用法：
  python tools/check_import_presets.py             # 校验 assets/**/*.import
  python tools/check_import_presets.py --verbose   # 同时打印每个文件的实际参数

退出码：0 = 全部符合；1 = 存在不符（可直接进 CI）。
"""

import argparse
import configparser
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"

# ── 规格（与 assets/import_presets/README.md 的参数表逐条对应）────────────────
# PNG 像素美术
SPEC_TEXTURE = {
    "compress/mode": "0",            # Lossless。有损压缩会破坏调色板色值 → 直接违反 S2
    "compress/high_quality": "false",
    "compress/normal_map": "0",
    "compress/channel_pack": "0",
    "mipmaps/generate": "false",     # 2D 像素图开 mipmap = 远处糊
    "process/fix_alpha_border": "false",  # 像素数据零改动；等比放大走 NEAREST，无黑边问题
    "process/premult_alpha": "false",
    "process/size_limit": "0",
    "detect_3d/compress_to": "0",    # 关键：默认 1 会在被 3D 引用时自动改 VRAM 压缩
}

# 字体（像素中文字体，动态字体导入器）
SPEC_FONT = {
    "antialiasing": "0",             # None。像素字形必须硬边
    "hinting": "0",                  # None。字形已按位图设计，自动 hinting 会二次改造
    "subpixel_positioning": "0",     # Disabled。字必须落在整像素
    "allow_system_fallback": "false",  # 缺字必须暴露，禁止静默回退（配 check_font_coverage）
    "generate_mipmaps": "false",
    "multichannel_signed_distance_field": "false",
    "oversampling": "0.0",
}

# 按扩展名路由到对应规格
SPECS = {
    ".png": ("纹理", SPEC_TEXTURE),
    ".ttf": ("字体", SPEC_FONT),
    ".otf": ("字体", SPEC_FONT),
}


def read_params(import_path):
    """读取 .import 的 [params] 段；该段含 `Rendering=null` 这类非标准值，
    且键名是大小写混排，因此不用 configparser，按行解析更稳。"""
    params = {}
    section = None
    for raw in import_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section != "params" or "=" not in line:
            continue
        k, _, v = line.partition("=")
        params[k.strip()] = v.strip()
    return params


def main():
    ap = argparse.ArgumentParser(description="素材导入参数一致性校验")
    ap.add_argument("--verbose", action="store_true", help="打印每个文件的全部参数")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    imports = sorted(ASSETS.rglob("*.import"))
    if not imports:
        print("assets/ 下没有 .import 文件（素材尚未被 Godot 导入？）")
        return 0

    violations = []
    checked = 0
    skipped = 0

    for imp in imports:
        rel = imp.relative_to(ROOT).as_posix()
        # 源文件名 = 去掉尾部 .import
        src = Path(str(imp)[:-len(".import")])
        spec_entry = SPECS.get(src.suffix.lower())
        if spec_entry is None:
            skipped += 1
            if args.verbose:
                print("── 跳过（无规格）: %s" % rel)
            continue
        kind, spec = spec_entry
        params = read_params(imp)
        checked += 1

        bad = []
        for key, want in spec.items():
            got = params.get(key)
            if got is None:
                bad.append("%s 缺失（应为 %s）" % (key, want))
            elif got != want:
                bad.append("%s=%s（应为 %s）" % (key, got, want))

        if args.verbose:
            print("── %s  [%s]" % (rel, kind))
            for key in spec:
                got = params.get(key, "<无>")
                mark = "OK " if got == spec[key] else "!! "
                print("   %s%-32s %s" % (mark, key, got))

        if bad:
            violations.append((rel, kind, bad))

    print("\n扫描 %d 个 .import：符合规格 %d 个，跳过 %d 个（无规格的素材类型）"
          % (len(imports), checked - len(violations), skipped))

    if violations:
        print("\n以下文件不符合导入规格：")
        for rel, kind, bad in violations:
            print("  ✗ %s  [%s]" % (rel, kind))
            for b in bad:
                print("      - %s" % b)
        print("\n结论: 存在 %d 个文件不合规 —— 按 assets/import_presets/README.md 修正后重跑"
              % len(violations))
        return 1

    print("结论: 全部符合导入规格")
    return 0


if __name__ == "__main__":
    sys.exit(main())
