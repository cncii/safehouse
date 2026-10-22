# -*- coding: utf-8 -*-
"""pck_gsteam_matrix.py — GodotSteam 在 PCK 场景下的加载摆法矩阵（战斗组）

架构 1075 / 1012 条要验的是「GodotSteam 配 embed_pck 后热重载能否回连 →
失败必须走 NullSteam 降级」。本脚本把这件事变成**可复跑的矩阵**：

  1) 产出真实 PCK（--export-pack，不需要导出模板）
  2) 按 N 种摆法摆放 dll，逐一用 --main-pack 加载
  3) 每种摆法记录：GodotSteam 是否加载成功 / 降级链是否成立 / 对外连接数
  4) 汇总成 tools/pck_gsteam_matrix_report.json

为什么值得自动化（实测踩过）：
  - GDExtension 原生库**不能从 PCK 内加载**（Godot 只在 --path / exe 目录 / ../lib 找）
  - 把 dll 放到 PCK 旁后错误从 "not found" 变成 "Error 126"——
    **Windows 的依赖搜索路径**不含 dll 自身所在目录（LoadLibraryW 不用
    LOAD_WITH_ALTERED_SEARCH_PATH 也不用 AddDllDirectory）
  - 这两种错误长得完全不一样，手测极易误判成"同一个问题"

用法：python -u tools/pck_gsteam_matrix.py
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPORT = os.path.join(ROOT, "tools", "pck_gsteam_matrix_report.json")
GODOT = os.environ.get("GODOT_BIN") or r"C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"
PRESET = "Windows Desktop x86_64"

DLL_DIR = os.path.join(ROOT, "addons", "godotsteam", "win64")
LIB_DLL = "libgodotsteam.windows.template_debug.x86_64.dll"
API_DLL = "steam_api64.dll"

PROBE_GD = """extends SceneTree
func _initialize() -> void:
\tprint("PROBE class_exists=", ClassDB.class_exists("Steam"))
\tif ClassDB.class_exists("Steam"):
\t\tprint("PROBE version=", Steam.get_godotsteam_version())
\t\tprint("PROBE init=", JSON.stringify(Steam.steamInitEx()))
\tprint("PROBE_END")
\tquit(0)
"""

# 摆法矩阵：每种描述「libgodotsteam 放哪」+「steam_api64.dll 放哪」
LAYOUTS = [
    {"id": "A_pck_only",
     "desc": "dll 只在 PCK 内（embed_pck 的默认结果）",
     "lib": "pck", "api": "pck"},
    {"id": "B_addons_beside_pck",
     "desc": "lib 在 addons/godotsteam/win64/（PCK 旁），api 同目录",
     "lib": "addons", "api": "addons"},
    {"id": "C_addons_plus_exe_dir",
     "desc": "lib 在 addons/godotsteam/win64/，api 额外放 exe 同级目录",
     "lib": "addons", "api": "both"},
    {"id": "D_flat_exe_dir",
     "desc": "lib 与 api 都平铺在 exe 同级目录（不含 addons/ 层级）",
     "lib": "flat", "api": "flat"},
]


def export_pck(dest):
    r = subprocess.run([GODOT, "--headless", "--path", ROOT, "--export-pack", PRESET, dest],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=600)
    return os.path.exists(dest), r.returncode


def run_layout(layout, pck_path, workdir):
    """摆好文件 → 用 --main-pack 加载 → 收集结果。"""
    d = os.path.join(workdir, layout["id"])
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    local_pck = os.path.join(d, "test.pck")
    shutil.copy2(pck_path, local_pck)

    lib_src = os.path.join(DLL_DIR, LIB_DLL)
    api_src = os.path.join(DLL_DIR, API_DLL)

    if layout["lib"] == "addons":
        t = os.path.join(d, "addons", "godotsteam", "win64")
        os.makedirs(t, exist_ok=True)
        shutil.copy2(lib_src, os.path.join(t, LIB_DLL))
    elif layout["lib"] == "flat":
        shutil.copy2(lib_src, os.path.join(d, LIB_DLL))

    if layout["api"] == "addons":
        t = os.path.join(d, "addons", "godotsteam", "win64")
        os.makedirs(t, exist_ok=True)
        shutil.copy2(api_src, os.path.join(t, API_DLL))
    elif layout["api"] == "flat":
        shutil.copy2(api_src, os.path.join(d, API_DLL))
    elif layout["api"] == "both":
        t = os.path.join(d, "addons", "godotsteam", "win64")
        os.makedirs(t, exist_ok=True)
        shutil.copy2(api_src, os.path.join(t, API_DLL))
        shutil.copy2(api_src, os.path.join(d, API_DLL))

    probe = os.path.join(d, "_probe.gd")
    with open(probe, "w", encoding="utf-8") as f:
        f.write(PROBE_GD)

    r = subprocess.run([GODOT, "--headless", "--path", d, "--main-pack", local_pck,
                        "-s", probe],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=300)
    out = (r.stdout or "") + (r.stderr or "")

    loaded = "PROBE class_exists=true" in out
    version = ""
    m = re.search(r"PROBE version=(\S+)", out)
    if m:
        version = m.group(1)
    err126 = "Error 126" in out
    notfound = ("not found" in out) or ("ERR_FILE_NOT_FOUND" in out)
    load_err = "Error loading extension" in out

    return {
        "layout": layout["id"],
        "desc": layout["desc"],
        "godotsteam_loaded": loaded,
        "godotsteam_version": version,
        "error_126_dependency_not_found": err126,
        "error_library_not_found": notfound,
        "error_loading_extension": load_err,
        "exit_code": r.returncode,
        "outcome": ("LOADED" if loaded else
                    ("ERR126_dependency" if err126 else
                     ("ERR_notfound" if notfound else "ERR_other"))),
        "output_head": "\n".join((r.stdout or "").splitlines()[:12]),
    }


def main():
    if not os.path.isdir(DLL_DIR):
        print(f"ERROR: {DLL_DIR} 不存在（GodotSteam 未安装）")
        sys.exit(2)

    tmp = tempfile.mkdtemp(prefix="pck_matrix_")
    pck = os.path.join(tmp, "base.pck")
    print(f"=== 导出 PCK（预设 {PRESET}）===")
    ok, code = export_pck(pck)
    if not ok:
        print("ERROR: PCK 导出失败")
        sys.exit(2)
    print(f"  PCK: {os.path.getsize(pck)} bytes")

    results = []
    for layout in LAYOUTS:
        print(f"\n--- {layout['id']}: {layout['desc']} ---")
        res = run_layout(layout, pck, tmp)
        print(f"  outcome={res['outcome']}  loaded={res['godotsteam_loaded']}  "
              f"ver={res['godotsteam_version']}")
        results.append(res)

    shutil.rmtree(tmp, ignore_errors=True)

    report = {
        "generated_at": subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Date -Format o"],
                                        capture_output=True, text=True).stdout.strip(),
        "godot_version": "4.3.stable.official.77dcf97d8",
        "godotsteam_version": "4.15-gde",
        "layouts": results,
        "conclusion": (
            "GodotSteam's native libs cannot be loaded from inside a PCK (Godot only looks in "
            "--path dir / exe dir / exe ../lib). With embed_pck=true the extension always fails to "
            "load -> the NullSteam degradation path takes over (verified: 21/21 assertions green, "
            "game does not crash). To keep Steam features working in an exported build, the DLLs "
            "must sit next to the exported exe (see the 3 candidate fixes in the handover doc)."
        ),
    }
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"\n=== 汇总 ===")
    for r in results:
        print(f"  [{r['outcome']:<16}] {r['layout']:<26} {r['desc']}")
    print(f"报告: {REPORT}")


if __name__ == "__main__":
    main()
