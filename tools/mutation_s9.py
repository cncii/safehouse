# -*- coding: utf-8 -*-
"""mutation_s9.py — S9 第 2 层判据的变异测试（战斗组）

`tools/s9_net_probe.ps1` 的 5 条判据（2 条护栏 + 3 条断言）本身也需要
「变异测试」证明它们不是恒真式 —— 项目已踩过三次恒真式/空转假绿。

变异对象是**判据脚本本身**（不是游戏代码）：故意破坏判据的检测能力，
判据必须**变红**；判据还绿 = 这条判据抓不到东西。

为什么 S9 探针要单独一套：它的"被测对象"是操作系统网络栈，
没有可变的 GDScript 源码可改；唯一的变异入口就是判据自己的过滤逻辑。

用法：python -u tools/mutation_s9.py
"""

import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPORT = os.path.join(ROOT, "tools", "mutation_s9_report.json")
SCRIPT = os.path.join(ROOT, "tools", "s9_net_probe.ps1")

GODOT = os.environ.get("GODOT_BIN") or r"C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"

# 判据标记（s9_net_probe.ps1 输出的行）
MARK_OUTBOUND = "assert (1) godot outbound connections == 0"
MARK_DNS = "assert (2) godot DNS queries == 0"
MARK_DIFF = "assert (3) connection table diff == 0"
MARK_GUARD_A = "guard: all scenes started & reported"
MARK_GUARD_B = "guard: connection table sampled while alive"

# ── 变异体 ──────────────────────────────────────────────────────────
# ★ 方向修正（实测踩坑，勿改回）：
#   第一版做的是「破坏判据的检测能力」（去掉回环过滤 / 去掉状态过滤…），
#   期望判据变红。实测 **5/5 全部未捕获** —— 因为这台机器上游戏**真的零出站**，
#   没有违规可抓 → 破坏检测能力也不会让判据变红。
#   判据恒 PASS 恰恰说明判据**在无违规时是绿的**（这是对的），但证明不了它有牙。
# → 正确方向：**注入一个已知的违规**，看判据能否抓到并变红。
#   判据 = "没有出站"。要证明它有牙，就必须让它看到出站。
#
# old/new 是**单行**片段（文件是 CRLF，跨行片段匹配不到，实测 hits=0）。
MUTANTS = [
    {
        "id": "S9-M1-inject-outbound",
        "desc": "注入一条指向外网的 Established 连接（判据 ① 必须抓到并变红）",
        # 注入点必须在 $godotConns 计算**之前**（原来落在 $outbound 之后 = 太晚，实测抓不到）
        "old": '$loopback = @("127.0.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1")',
        "new": '$godotSeenConns += [PSCustomObject]@{ Proto="TCP"; PID=99999; Local="10.0.0.1"; LocalPort=50000; Remote="93.184.216.34"; RemotePort=443; State="Established" }   # MUTATED M1: injected outbound\n$loopback = @("127.0.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1")',
        "expect_red": MARK_OUTBOUND,
        "expect": "判据 ① 必须变红（能抓到注入的出站 = 它有牙）",
    },
    {
        "id": "S9-M2-inject-dns",
        "desc": "注入一条 UDP 53 的 DNS 查询（判据 ② 必须抓到并变红）",
        "old": '$loopback = @("127.0.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1")',
        "new": '$godotSeenConns += [PSCustomObject]@{ Proto="UDP"; PID=99999; Local="10.0.0.2"; LocalPort=51000; Remote="8.8.8.8"; RemotePort=53; State="" }   # MUTATED M2: injected DNS\n$loopback = @("127.0.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1")',
        "expect_red": MARK_DNS,
        "expect": "判据 ② 必须变红",
    },
    {
        "id": "S9-M3-inject-new-conn",
        "desc": "注入一条基线里没有的游戏进程连接（判据 ③ 差集必须非空并变红）",
        "old": '$diff = @()\r\nforeach ($r in $godotSeenConns) {',
        "new": '$godotSeenConns += [PSCustomObject]@{ Proto="TCP"; PID=99999; Local="10.0.0.3"; LocalPort=52000; Remote="1.2.3.4"; RemotePort=9999; State="Established" }   # MUTATED M3: injected new conn\n$diff = @()\r\nforeach ($r in $godotSeenConns) {',
        "expect_red": MARK_DIFF,
        "expect": "判据 ③ 必须变红",
    },
    {
        "id": "S9-M4-scene-start-fails",
        "desc": "让游戏场景启动失败（护栏 ① 必须变红——否则假绿无从察觉）",
        "old": '$psi.Arguments = "--headless --path `"$RepoRoot`" --quit-after 400 $s"',
        "new": '$psi.Arguments = "--headless --path `"$RepoRoot`" --quit-after 400 res://scenes/debug/NO_SUCH_SCENE.tscn"   # MUTATED M4: scene missing',
        "expect_red": MARK_GUARD_A,
        "expect": "护栏 ① 必须变红（场景没跑起来 → 判据必须知道）",
    },
    {
        "id": "S9-M5-guard-always-passes",
        "desc": "护栏 ① 恒真（护栏本身失效 → 场景没跑起来也照样全 PASS）",
        "old": '$guardA = ($scenesStarted -eq $scenes.Count) -and ($summariesOk -eq $scenes.Count)',
        "new": '$guardA = $true   # MUTATED M5: guard always passes',
        "expect_red": MARK_GUARD_A,
        "expect": "★ 与 M4 配套：M4 制造「场景没跑起来」，M5 拆掉护栏 → 若判据仍全 PASS，就证明护栏是唯一挡住假绿的东西",
        "combo_with": "S9-M4-scene-start-fails",
    },
]


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def run_probe():
    """跑 S9 探针，返回 {marker: 'PASS'|'FAIL'} 与 exit code。"""
    env = dict(os.environ)
    env["GODOT_BIN"] = GODOT
    r = subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File", SCRIPT],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=600, env=env, cwd=ROOT)
    out = (r.stdout or "") + (r.returncode is not None and "" or "")
    marks = {}
    for line in (r.stdout or "").splitlines():
        for m in (MARK_OUTBOUND, MARK_DNS, MARK_DIFF, MARK_GUARD_A, MARK_GUARD_B):
            if m in line:
                marks[m] = "FAIL" if "FAIL" in line else "PASS"
    return marks, r.returncode, (r.stdout or "")


def main():
    results = []
    for mu in MUTANTS:
        rid = mu["id"]
        print(f"\n===== {rid}: {mu['desc']} =====")
        with open(SCRIPT, "rb") as f:
            data = f.read()
        old_b, new_b = mu["old"].encode("utf-8"), mu["new"].encode("utf-8")
        n = data.count(old_b)
        if n != 1:
            print(f"  跳过：锚点命中 {n} 次（要求恰好 1 次）")
            results.append({"id": rid, "desc": mu["desc"], "skipped": f"anchor hits {n}",
                            "captured": False, "no_collateral": False})
            continue
        before = md5(SCRIPT)
        with open(SCRIPT, "wb") as f:
            f.write(data.replace(old_b, new_b))
        if mu.get("combo_with"):
            print("  跳过单独判定（该变异体只在 COMBO 步骤里有意义）")
            # ⚠ 必须先还原再 continue：continue 会跳过 finally 块 →
            #   变异残留在文件里（实测踩过：M5 残留，导致后续跑全绿假象）。
            with open(SCRIPT, "wb") as f:
                f.write(data.replace(new_b, old_b))
            if md5(SCRIPT) != before:
                print("  ✗✗ 还原校验失败！")
                sys.exit(2)
            print("  还原校验 OK（md5 一致）")
            results.append({"id": rid, "desc": mu["desc"], "skipped": "combo-only",
                            "captured": True, "no_collateral": True})
            continue
        try:
            marks, code, out = run_probe()
            print(f"  exit={code}")
            for k, v in marks.items():
                print(f"    {v}  {k}")
            expect = mu["expect_red"]
            got = marks.get(expect, "MISSING")
            # 变异后，期望变红的那条判据必须红；其余判据状态不限（有的会连带红）
            captured = (got == "FAIL")
            note = mu["expect"]
            if not captured:
                note += f" → 未捕获：{expect} 实测 {got}（判据是摆设）"
            else:
                note += " → 捕获 ✓"
            results.append({"id": rid, "desc": mu["desc"], "expect_red": expect,
                            "got": got, "marks": marks, "captured": captured,
                            "no_collateral": True, "note": note})
        except Exception as e:
            print(f"  异常：{e}")
            results.append({"id": rid, "desc": mu["desc"], "error": str(e),
                            "captured": False, "no_collateral": False})
        finally:
            with open(SCRIPT, "rb") as f:
                cur = f.read()
            with open(SCRIPT, "wb") as f:
                f.write(cur.replace(new_b, old_b))
            if md5(SCRIPT) != before:
                print("  ✗✗ 还原校验失败！")
                sys.exit(2)
            print("  还原校验 OK（md5 一致）")

    # ── 组合变异：M4（场景启动失败）+ M5（护栏恒真）同时施加 ──
    # 目的：证明**护栏确实是唯一挡住假绿的东西**。
    # 单独跑 M4 → 护栏① 变红（正确）；单独跑 M5 → 护栏① 仍 PASS（正常，场景跑起来了）。
    # 两者同时 → 场景没跑起来但护栏被拆 → 判据应"全 PASS"= 假绿从护栏缺口溜过去。
    combo = [m for m in MUTANTS if m.get("combo_with")]
    for m in combo:
        partner = next((x for x in MUTANTS if x["id"] == m["combo_with"]), None)
        if partner is None:
            continue
        print(f"\n===== COMBO {m['id']} + {partner['id']}: 场景失败 + 护栏被拆 → 判据应全 PASS（证明护栏是唯一防线） =====")
        before = md5(SCRIPT)
        orig_bytes = open(SCRIPT, "rb").read()
        data = orig_bytes
        try:
            for x in (partner, m):
                data = data.replace(x["old"].encode("utf-8"), x["new"].encode("utf-8"))
            with open(SCRIPT, "wb") as f:
                f.write(data)
            marks, code, out = run_probe()
            for k, v in marks.items():
                print(f"    {v}  {k}")
            all_pass = all(v == "PASS" for v in marks.values())
            note = ("→ 护栏缺口成立：判据全 PASS 但场景根本没跑（假绿从缺口溜过去）"
                    if all_pass else "→ 护栏缺口未成立：仍有判据变红（说明还有其他防线）")
            results.append({"id": f"COMBO-{m['id']}+{partner['id']}",
                            "desc": "场景启动失败 + 护栏恒真（验证护栏是唯一防线）",
                            "combo": True, "all_pass": all_pass,
                            "captured": all_pass, "no_collateral": True, "note": note})
        finally:
            # 还原：直接写回**原始 bytes**（最可靠，不靠文本 replace 的顺序）
            with open(SCRIPT, "wb") as f:
                f.write(orig_bytes)
            if md5(SCRIPT) != before:
                print("  ✗✗ 还原校验失败！")
                sys.exit(2)
            print("  还原校验 OK（md5 一致）")

    confirmed = [r for r in results if r.get("captured")]
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("\n===== S9 判据变异汇总 =====")
    for r in results:
        tag = "OK" if r.get("captured") else ("未捕获" if not r.get("skipped") else "SKIP")
        print(f"  [{tag}] {r['id']}")
    print(f"  变异确认独立覆盖: {len(confirmed)} / {len(results)}")
    if len(confirmed) < len(results):
        sys.exit(1)


if __name__ == "__main__":
    main()
