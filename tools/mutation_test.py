# -*- coding: utf-8 -*-
"""mutation_test.py — 包 F·W3 变异测试（QA 标准，照任务书 §4 执行）

每个变异体两条硬标准：
  ① captured       目标判据变红            （抓到了）
  ② no_collateral  只有目标(含声明连锁族)变红（无误伤）
未满足 → 标 "未正确捕获"，即使它红了。

产出 tools/mutation_report.json，供 test.ps1 的 coverage_statement 读取
（变异确认独立覆盖 N 条 —— 由本报告统计，禁手写）。

流程安全：每变异体 备份(md5) → 替换(必须恰好命中 1 次) → 跑 → 还原 → md5 校验；
任何一步失败立即中止并还原，绝不留带变异的文件。
"""

import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPORT = os.path.join(ROOT, "tools", "mutation_report.json")

GODOT = os.environ.get("GODOT_BIN") or r"C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"

MIN_ASSERTS = 121   # run_tests.gd 修订 #6 后的门槛；变异不得改变断言总数

# 恒红 blocked 判据（与变异无关的固定红，从红集剔除——否则每个变异体都被判"误伤"）：
#   LOOP-* 五条：loop_system.gd 编译失败（欠件退回包 B），修复前恒红。
KNOWN_CONSTANT_REDS = ("LOOP-",)


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def apply_mutation(rel, old, new):
    """把 old 替换为 new，必须恰好命中 1 次；返回原 md5。"""
    p = os.path.join(ROOT, rel)
    before = md5(p)
    with open(p, "r", encoding="utf-8") as f:
        src = f.read()
    n = src.count(old)
    if n != 1:
        raise RuntimeError(f"{rel}: 变异锚点命中 {n} 次（要求恰好 1 次），拒绝执行")
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(src.replace(old, new))
    return before


def restore(rel, before_md5):
    raise SystemExit  # 占位：用下方 replace-back 实现


def revert_mutation(rel, old, new):
    p = os.path.join(ROOT, rel)
    with open(p, "r", encoding="utf-8") as f:
        src = f.read()
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(src.replace(new, old))
    return md5(p)


def run_gate_gd():
    """跑 stage 4（场景方式），返回 (红判据名列表, 断言总数)。"""
    r = subprocess.run([GODOT, "--headless", "--path", ROOT, "res://tests/test_main.tscn"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=240)
    reds, total = [], 0
    for line in (r.stdout or "").splitlines():
        m = re.match(r"\s*FAIL\s+(.+?)\s*--\s*", line) or re.match(r"\s*FAIL\s+(.+)", line)
        if m:
            reds.append(m.group(1).strip())
        m2 = re.search(r"gate run: (\d+) pass / (\d+) fail", line)
        if m2:
            total = int(m2.group(2))
    return reds, total


def run_stage1():
    """跑 stage 1（validate_data.py），返回 (红判据行列表, exit code)。"""
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "validate_data.py")],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=120)
    reds = [l.strip() for l in (r.stdout or "").splitlines() if "[FAIL]" in l]
    return reds, r.returncode


# ── 变异体登记（任务书 §4 首批；目标判据 + 声明的连锁族白名单）──────────
MUTANTS = [
    {
        "id": "V1-windup-frame",
        "desc": "windup 8→7 帧（改 src 权威常量，秒值镜像不动）",
        "file": "src/systems/time_system.gd",
        "old": "const WINDUP_TICKS := 8",
        "new": "const WINDUP_TICKS := 7",
        "runner": "gd",
        "target": ["F0-b", "M30 combat-chain: windup"],
        "chain_ok": [],           # windup 只进这两个判据
        "expect_qa": "应红 F0-b（QA 任务书 §4）",
    },
    {
        "id": "V2-doc-seconds",
        "desc": "文档基线秒值 0.1333333→0.12（time.json derived_check 与帧数脱钩）",
        "file": "data/balance/time.json",
        "old": '"windup_sec": 0.1333333',
        "new": '"windup_sec": 0.12',
        "runner": "stage1",
        "target": ["F0-b"],
        "chain_ok": [],
        "expect_qa": "应红 C28-b（= validate_data 的 F0-b 帧数↔秒值链）",
    },
    {
        "id": "V3-hunger-rate",
        "desc": "饥饿速率 5→6/GH（survival.json）",
        "file": "data/balance/survival.json",
        "old": '"hunger_rate_per_gh": 5',
        "new": '"hunger_rate_per_gh": 6',
        "runner": "gd",
        "target": ["M2-c hunger_rate"],
        "chain_ok": [],
        "expect_qa": "QA 原预判应红 M2 —— M2 死钟用归零后 loss 速率，预计实际红的是 M2-c 锚点"
                     "（M2 是否被牵红由实测回答，这正是变异报告的价值）",
    },
    {
        "id": "V4-gh-frames",
        "desc": "GH 帧数 4320→4300（src/core/game_loop.gd）",
        "file": "src/core/game_loop.gd",
        "old": "const FRAMES_PER_GH := 4320",
        "new": "const FRAMES_PER_GH := 4300",
        "runner": "gd",
        "target": ["M1", "P1-1"],
        "chain_ok": ["M30 time-chain", "P12b", "C1/M30", "P28"],  # 全部锚定 FRAMES_PER_GH 的判据族
        "expect_qa": "应红 M1/P1①（QA 任务书 §4）；连锁红= 同一事实族的锚点，非误伤",
    },
    {
        "id": "V5-breach-unsorted",
        "desc": "破防候选不排序（loop_system.pick_breach_target 字典序+hash）",
        "file": "src/systems/loop_system.gd",
        "old": None, "new": None,
        "runner": "blocked",
        "target": ["M30/M19 类确定性断言"],
        "chain_ok": [],
        "expect_qa": "应红 M30/M19 类确定性断言 —— 本轮 blocked：loop_system.gd 编译失败"
                     "（欠件退回包 B），变异体无法在坏脚本上区分红因，不得出假记录",
    },
]


def main():
    results = []
    for mu in MUTANTS:
        rid = mu["id"]
        print(f"\n===== 变异体 {rid}: {mu['desc']} =====")
        if mu["runner"] == "blocked":
            print("  BLOCKED  上游实现编译失败（loop_system.gd:368），不出红绿记录")
            results.append({"id": rid, "desc": mu["desc"], "blocked": True,
                            "captured": False, "no_collateral": False,
                            "note": mu["expect_qa"]})
            continue

        rel, old, new = mu["file"], mu["old"], mu["new"]
        p = os.path.join(ROOT, rel)
        before = apply_mutation(rel, old, new)
        try:
            reds, total = [], 0
            if mu["runner"] == "gd":
                reds, total = run_gate_gd()
                if total != MIN_ASSERTS:
                    raise RuntimeError(f"断言总数 {total} != {MIN_ASSERTS}：变异意外改变了判据规模，结果无效")
            else:
                reds, code = run_stage1()
                if code == 0:
                    reds = []   # exit 0 = stage1 全绿 = 未捕获
            # 剔除与变异无关的恒红 blocked 判据（如 LOOP-* 欠件红）
            constant_reds = [r for r in reds if any(r.startswith(k) for k in KNOWN_CONSTANT_REDS)]
            reds = [r for r in reds if r not in constant_reds]
            print(f"  红判据 {len(reds)} 条（另有 {len(constant_reds)} 条恒红 blocked 已剔除）:")
            for r in reds:
                print(f"    - {r}")

            def in_target(name):
                return any(name.startswith(t) or t in name for t in mu["target"])

            def in_chain(name):
                return any(c in name for c in mu["chain_ok"])

            captured = any(in_target(r) for r in reds)
            collateral = [r for r in reds if not (in_target(r) or in_chain(r))]
            no_collateral = captured and not collateral
            note = mu["expect_qa"]
            if not captured:
                note += " → 未捕获（SURVIVED）：目标判据没红，判据对该变异是摆设"
            elif collateral:
                note += " → 误伤：" + " | ".join(collateral)
            else:
                note += " → 捕获 ✓ 且无误伤 ✓"
            results.append({"id": rid, "desc": mu["desc"], "file": rel,
                            "red": reds, "captured": captured,
                            "no_collateral": no_collateral, "note": note})
        finally:
            after = revert_mutation(rel, old, new)
            if after != before:
                print(f"  ✗✗ 还原校验失败 {rel}: {before} → {after}，需人工核查！")
                sys.exit(2)
            print(f"  还原校验 OK（md5 一致）")

    confirmed = [r for r in results if r.get("captured") and r.get("no_collateral")]
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n===== 变异汇总 =====")
    for r in results:
        tag = "BLOCKED" if r.get("blocked") else (
            "OK" if r["captured"] and r["no_collateral"] else
            ("未捕获" if not r["captured"] else "误伤"))
        print(f"  [{tag}] {r['id']}")
    print(f"  变异确认独立覆盖: {len(confirmed)} 条（详见 tools/mutation_report.json）")


if __name__ == "__main__":
    main()
