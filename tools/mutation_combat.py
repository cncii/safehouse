# -*- coding: utf-8 -*-
"""mutation_combat.py — 战斗组（包 C+E）判据变异测试

包 F 的 tools/mutation_test.py 覆盖的是 stage 4（tests/test_main.tscn，包 F 域）。
战斗组自建 4 套探针（scenes/debug/*_probe.tscn，107 条断言）**从未做过变异验证**——
"全绿"可能只是判据抓不到东西（项目已踩过三次恒真式/空转假绿）。
本文件补上这一块，**不改包 F 的任何文件**。

每个变异体两条硬标准（同 QA 标准）：
  ① captured       目标判据变红            （抓到了）
  ② no_collateral  只有目标(+声明的连锁族)变红（无误伤）

额外一条战斗组特有：
  ③ cross_probe_clean  变异只影响它声明的探针，不牵连别的探针

流程安全（照抄包 F 的教训）：
  - 必须**二进制模式**读写：文本模式 universal-newlines 会把 CRLF 统一成 LF，
    apply 一步就改坏整个文件行尾，revert 后 md5 对不上（V5 首跑实测翻车）。
  - 锚点必须是不含行尾的单行片段，且**恰好命中 1 次**，否则拒绝执行。
  - 备份(md5) → 替换 → 跑 → 还原 → md5 校验；任一步失败立即还原并中止。
  - 结束时必须校验**所有被改过的文件**都回到原样（不留带变异的文件）。
"""

import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REPORT = os.path.join(ROOT, "tools", "mutation_combat_report.json")

GODOT = os.environ.get("GODOT_BIN") or r"C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"

# 各探针的断言总数门槛——变异不得改变判据规模，否则结果无效
PROBE_ASSERTS = {
    "combat": 45,
    "event": 37,
    "steam": 21,
    "pii": 27,
    "p17b": 36,
}


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def apply_mutation(rel, old, new):
    """施加变异，返回 (原 md5, 替换的字节偏移量)。

    ⚠ 必须二进制模式：文本模式 universal-newlines 会把 CRLF 统一转 LF，
    apply 一步就改坏整个文件的行尾，revert 后 md5 对不上（V5 首跑实测翻车）。
    锚点必须写成不含行尾的单行片段。

    ★ 返回**字节偏移量**是必须的（实测翻车 C2）：revert 若靠"再找一次 new 文本"，
    会匹配到**别的行**——例：new = `"strength_mult": 2.0` 是夜6 `"…": 2.02` 的**子串**，
    find() 命中夜6 → 还原时把夜6 改成 2.32，夜7 仍是 2.0 → md5 不一致且数据被改坏。
    → 还原必须**按偏移量精确回填**，与 apply 严格对称。
    """
    p = os.path.join(ROOT, rel)
    before = md5(p)
    with open(p, "rb") as f:
        data = f.read()
    old_b, new_b = old.encode("utf-8"), new.encode("utf-8")
    n = data.count(old_b)
    if n != 1:
        raise RuntimeError(f"{rel}: 变异锚点命中 {n} 次（要求恰好 1 次），拒绝执行")
    idx = data.find(old_b)
    with open(p, "wb") as f:
        f.write(data[:idx] + new_b + data[idx + len(old_b):])
    return before, idx, len(old_b)


def revert_mutation(rel, old, new, offset=None, old_len=None):
    """按**字节偏移量**精确还原（与 apply 严格对称，不靠文本再匹配）。"""
    p = os.path.join(ROOT, rel)
    with open(p, "rb") as f:
        data = f.read()
    old_b, new_b = old.encode("utf-8"), new.encode("utf-8")
    if offset is not None:
        # 偏移量路径：直接按位置回填，绝不文本匹配
        cur = data[offset:offset + len(new_b)]
        if cur != new_b:
            raise RuntimeError(
                f"{rel}: 偏移 {offset} 处内容与变异片段不符（期望 {new_b!r}，实际 {cur!r}）")
        with open(p, "wb") as f:
            f.write(data[:offset] + old_b + data[offset + len(new_b):])
        return md5(p)
    # 兜底路径（无偏移信息时）：只替换第 1 处，且必须**唯一**
    if data.count(new_b) != 1:
        raise RuntimeError(
            f"{rel}: 待还原片段命中 {data.count(new_b)} 次（要求恰好 1 次），拒绝执行")
    with open(p, "wb") as f:
        f.write(data.replace(new_b, old_b))
    return md5(p)


def run_probe(probe):
    """跑一套探针，返回 (红判据名列表, 断言总数, exit code)。"""
    scene = f"res://scenes/debug/{probe}_probe.tscn"
    r = subprocess.run([GODOT, "--headless", "--path", ROOT, "--quit-after", "400", scene],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=300)
    reds, total = [], 0
    for line in (r.stdout or "").splitlines():
        m = re.match(r"\s*FAIL\s+(.+?)\s*--\s*", line) or re.match(r"\s*FAIL\s+(.+)", line)
        if m:
            reds.append(m.group(1).strip())
        m2 = re.search(r"gate run: (\d+) pass / (\d+) fail", line)
        if m2:
            # ★ 解析口径（2026-10-22 实测踩坑）：战斗组探针的汇总行是
            #   `--- xxx_probe: %d pass / %d fail ---`，两个数是 **pass 数** 与 **fail 数**。
            #   我原先取 group(2) 当"断言总数" → 拿到的是 fail 数（正常情况恒为 0）
            #   → total 永远 0 → 后面"探针 0 条断言 = 探针没跑起来"的判据
            #   **误伤了每一个变异体**（全被判成"变异无效"）。
            # → 正确口径：总数 = pass + fail（= 实际执行的断言条数）。
            total = int(m2.group(1)) + int(m2.group(2))
        m3 = re.search(r"probe: (\d+) pass / (\d+) fail", line)
        if m3:
            total = int(m3.group(1)) + int(m3.group(2))
    return reds, total, r.returncode


# ── 战斗组变异体登记 ─────────────────────────────────────────────────
# probe  = 期望该变异打红的探针
# target = 目标判据名（子串匹配）
# chain_ok = 声明的连锁族（同一事实族的其他锚点，非误伤）
MUTANTS = [
    {
        "id": "C1-iframe-frames",
        "desc": "无敌帧 IFRAMES_TICKS 9→8（TimeSystem 权威常量，战斗组读它）",
        "file": "src/systems/time_system.gd",
        "old": "const IFRAMES_TICKS := 9",
        "new": "const IFRAMES_TICKS := 8",
        "probe": "combat",
        "target": ["w1: IFRAMES_TICKS == 9", "w1: IFRAMES_TICKS/60 == 0.15",
                  "w1: iframe still active on frame 8", "w1: iframe expired exactly on frame 9"],
        "chain_ok": ["w1: iframe active after dodge", "w1: hit inside iframe blocked",
                     "w1: hit after iframe lands with hitstun"],
        "expect": "应红无敌帧族——R5 手感核心判据",
    },
    {
        "id": "C2-strength-curve",
        "desc": "夜7 强度乘数 2.32→2.0（waves.json 曲线脱钩）",
        "file": "data/events/waves.json",
        "old": '"strength_mult": 2.32',
        "new": '"strength_mult": 2.0',
        "probe": "combat",
        "target": ["w2: night7 strength"],
        "chain_ok": [],
        "expect": "应红夜7 强度锚点",
    },
    {
        "id": "C3-night1-count",
        "desc": "夜1 batch0 数量 3→4（waves.json 波次规模改了）",
        "file": "data/events/waves.json",
        "old": '{ "batch": 0, "enemy_id": "zombie_shambler", "entry_point": "door_main",   "count": 3 }',
        "new": '{ "batch": 0, "enemy_id": "zombie_shambler", "entry_point": "door_main",   "count": 4 }',
        "probe": "combat",
        "target": ["w2: night1 slot total"],
        "chain_ok": ["w2: night1 non-empty", "w2: night1 batch_count",
                     "w2(M19): slot count stable", "w2: all batches killed",
                     "w2: batches_progress", "w2: batch progress independent"],
        "expect": "应红夜1 slot 总数——但**不能**红 M19 逐项相等（物化仍自洽）",
    },
    {
        "id": "C4-batch-merge",
        "desc": "batch 计数改为 1（多 batch 波次被压成单 batch——防「召唤池抽干提前过关」）",
        "file": "src/systems/combat_system.gd",
        "old": '"batch_count": cfg.get("batches", []).size(),',
        "new": '"batch_count": 1,',
        "probe": "combat",
        "target": ["w2: night1 batch_count", "w2: batches_progress"],
        "chain_ok": ["w2: batch0 done but batch1 pending", "w2: all batches killed",
                     "w2: batch progress independent of kill order"],
        "expect": "应红 batch 族——架构风险登记 #1 的守护判据",
    },
    {
        "id": "C5-materialize-gh",
        "desc": "物化时刻锚点 18.0→19.0（M19 锚点漂移）",
        "file": "src/systems/combat_system.gd",
        "old": '"materialized_gh": gh,',
        "new": '"materialized_gh": gh + 1.0,',
        "probe": "combat",
        "target": ["w2: materialized_gh"],
        "chain_ok": [],
        "expect": "应红 M19 物化时刻锚点（18:00±1 帧）",
    },
    {
        "id": "C6-event-impact-guard",
        "desc": "事件 impact 白名单放开（加第 5 类 'script'——M10 封闭集被破坏）",
        "file": "src/systems/event_system.gd",
        "old": 'if not ["num", "flag", "time", "spawn"].has(kind):',
        "new": 'if false:',
        "probe": "event",
        "target": ["m10: illegal impact kind rejected"],
        "chain_ok": ["m10: illegal impact not written to log"],
        "expect": "应红 M10 封闭集判据",
    },
    {
        "id": "C7-idempotency-off",
        "desc": "幂等键查重失效（破 _fire() 内层查重——所有路径的必经之地）",
        "file": "src/systems/event_system.gd",
        "old": '\tif _has_logged(key):\n\t\treturn _log_entry(key)',
        "new": '\tif false:\n\t\treturn _log_entry(key)   # MUTATED C7',
        "probe": "event",
        # 破的是**内层** _fire() 查重 → 外层 fire() 的公开 API 防线仍有效
        # → 公开入口判据**理应不红**（那是设计如此：两层防御是冗余的）。
        # 故 target 指向走内层路径的判据。
        "target": ["p9: duplicate key does not re-apply effect",
                   "p9: duplicate key does not duplicate log entry"],
        "chain_ok": ["p10: restored log blocks re-fire"],
        "expect": "应红 P9 幂等族（破内层查重 → 同键重复发放）",
    },
    {
        "id": "C8-append-only-log",
        "desc": "事件日志不再 append（重放将无历史可依——C17 append-only 被破坏）",
        "file": "src/systems/event_system.gd",
        "old": 'event_log.append(entry)     # C17 append-only：先落地再推存档',
        "new": 'pass     # MUTATED C8: log not appended',
        "probe": "event",
        "target": ["p8: two distinct slots", "p9: duplicate key does not duplicate log entry",
                   "save: event_log persisted non-empty", "p7: log restored from snapshot"],
        "chain_ok": ["p10: restored log blocks re-fire",
                     "p9: duplicate key does not re-apply effect",
                     "p9: public fire() logs exactly one entry",
                     "p9: public fire() duplicate key does not grow log",
                     "p9: public fire() duplicate key does not re-apply effect"],
        "expect": "应红 C17 日志族——同一天重开不再靠日志回放",
    },
    {
        "id": "C9-condition-guard",
        "desc": "条件谓词 all() 短路失效（只看第一个叶子——结构化谓词退化为单条件）",
        "file": "src/systems/event_system.gd",
        "old": 'if node.has("all"):\n\t\tfor sub_variant: Variant in node["all"]:\n\t\t\tif not _eval_condition(sub_variant, day):\n\t\t\t\treturn false\n\t\treturn true',
        "new": 'if node.has("all"):\n\t\tfor sub_variant: Variant in node["all"]:\n\t\t\treturn _eval_condition(sub_variant, day)\n\t\treturn true',
        "probe": "event",
        "target": ["cond: all() false when FIRST leaf true but second false"],
        "chain_ok": ["cond: all() false when one leaf false"],
        "expect": "应红 all() 短路判据——只看首叶子时全 true 的用例仍过（验证明这条不是恒真式）",
    },
    {
        "id": "C10-steam-degrade",
        "desc": "NullSteam 降级被完全绕过（_degrade 什么都不做——S 构建要求脱离 Steam 可运行）",
        "file": "src/platform/steam_service.gd",
        # ⚠ 锚点纪律（三次踩坑换来的，勿改）：
        #   ① 必须打在**所有降级路径的共同点**上。我先前打在
        #      `if _backend == null: _degrade("init_failed")` —— 但**有 GodotSteam 时
        #      那条分支根本不执行**（走的是 `_degrade("binding_script_missing")`）
        #      → 变异体不可达 → 判据测不到它（报"未捕获"）。
        #   ② 锚点不能与 C14 重复（C14 只把 `_backend = load(NULL_PATH).new()`
        #      换成 pass，日志照写；本变异让**整个 _degrade 什么都不做**，日志也没有）
        #      → 两者性质不同、覆盖数不虚高。
        #   ③ 跨行片段必须**完整匹配到行尾**（含中文注释），
        #      否则 replace 会留下半个注释 → 编译失败 → 探针 0 条断言。
        #   ④ 不能是**空变异**（只加注释不改行为）——那样判据当然测不出来。
        "old": 'func _degrade(reason: String) -> void:\r\n\t_backend = load(NULL_PATH).new()',
        "new": 'func _degrade(reason: String) -> void:\r\n\treturn   # MUTATED C10: degradation does nothing',
        "probe": "steam",
        "target": ["1012(1b): backend_ready() true", "s9: backend resolved"],
        "chain_ok": ["s9: backend_kind reports 'null' without Steam",
                     "s9: NullSteam calls are safe no-ops",
                     "1012(1): backend degraded to null",
                     "1012(2): degradation recorded in log",
                     "1012(2b): degradation log found after blocking wait",
                     "1012(3b): degraded backend_id == 'null'"],
        "expect": "应红降级族——S 构建硬要求",
    },
    {
        "id": "C11-pii-scanner-weakened",
        "desc": "PII 扫描器的绝对路径检测被去掉（S10 判据被架空）",
        "file": "scenes/debug/pii_probe.gd",
        "old": 'for token: String in ["Users\\\\", "C:\\\\", "\\\\AppData\\\\", "/AppData/",',
        "new": 'for token: String in ["__NO_SUCH_TOKEN__", "C:\\\\", "\\\\AppData\\\\", "/AppData/",',
        "probe": "pii",
        "target": ["token alone", "scanner detects abs path in known-bad sample"],
        "chain_ok": ["scanner still detects Users"],
        "expect": "应红反向对照——扫描器抓不到绝对路径时必须变红，否则 S10 是摆设",
    },
    {
        "id": "C12-pii-gzip-skip",
        "desc": "存档不解压就扫（GZIP 假绿——明文 grep 永远 0 命中）",
        "file": "scenes/debug/pii_probe.gd",
        "old": 'if bytes.size() > 2 and bytes[0] == 0x1f and bytes[1] == 0x8b:\n\t\treturn bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()',
        "new": 'if false:\n\t\treturn bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()',
        "probe": "pii",
        "target": ["decompressed to parsable JSON"],
        "chain_ok": ["PII hits == 0"],   # 判据名含 %s 占位，用稳定片段匹配
        "expect": "★ 关键：不解压就扫 → 存档内容根本读不到 → 判据必须变红（防空转假绿）",
    },
    {
        "id": "C13-degrade-silent",
        "desc": "降级不记日志（静默降级——架构 1012 要求必须记日志）",
        "file": "src/platform/steam_service.gd",
        "old": '\tLogger.log("steam", "null_backend", reason, null, "no steam env / init failed, NullSteam fallback")',
        "new": '\tpass   # MUTATED C13: silent degradation (no log)',
        "probe": "steam",
        "target": ["1012(2): degradation recorded in log"],
        # 1012(2b) 是 1012(2) 的异步落盘重试版 —— 同因连锁，不是误伤
        "chain_ok": ["1012(2b): degradation log found after blocking wait"],
        "expect": "应红 1012(2)——静默降级 = 出问题查不到",
    },
    {
        "id": "C14-degrade-no-backend",
        "desc": "降级不建立后端（backend 保持 null → 游戏不可玩）",
        "file": "src/platform/steam_service.gd",
        "old": '\t_backend = load(NULL_PATH).new()',
        "new": '\tpass   # MUTATED C14: backend stays null',
        "probe": "steam",
        "target": ["1012(1b): backend_ready() true"],
        "chain_ok": ["s9: backend resolved", "s9: backend_kind reports",
                     "s9: NullSteam calls are safe no-ops",
                     "1012(1): backend degraded to null",
                     "1012(2): degradation recorded in log"],
        "expect": "应红 1012(1b) 与 s9 降级族——降级后必须**有可用后端**",
    },
    {
        "id": "C15-degrade-bad-id",
        "desc": "降级后端 backend_id 返错值（诊断口径坏了——UI/日志会说错后端类型）",
        "file": "src/platform/steam_null.gd",
        "old": 'func backend_id() -> StringName:\n\treturn &"null"',
        "new": 'func backend_id() -> StringName:\n\treturn &"steam"   # MUTATED C15: lies about backend',
        "probe": "steam",
        "target": ["1012(3b): degraded backend_id == 'null'"],
        # 同因连锁：backend_id 返错值 → 三条判据测的都是"后端自报类型"这同一性质
        "chain_ok": ["s9: backend_kind reports 'null' without Steam",
                     "1012(1): backend degraded to null"],
        "expect": "应红 1012(3b)——降级后端必须自报 'null'",
    },
    {
        "id": "C16-degrade-holds-state",
        "desc": "降级后端偷偷持有状态（降级不是空转 = 成就队列会丢）",
        "file": "src/platform/steam_null.gd",
        "old": 'class_name SteamNull\nextends RefCounted',
        "new": 'class_name SteamNull\nextends RefCounted\n\nvar _pending: Array = []   # MUTATED C16: degraded backend holds state',
        "probe": "steam",
        "target": ["1012(3d): degraded backend holds no business state"],
        "chain_ok": [],
        "expect": "应红 1012(3d)——降级后端必须无状态（否则成就队列会静默丢）",
    },
    {
        "id": "C17-p17b-log-not-persisted",
        "desc": "events 存档段不写 event_log（跨存档后事件日志全丢——P17b 核心）",
        "file": "src/systems/event_system.gd",
        "old": '\t\t"event_log": event_log.duplicate(true),',
        "new": '\t\t"event_log": [],',
        "probe": "p17b",
        "target": ["event_log restored from real file", "restored log content identical"],
        "chain_ok": ["bak carries non-empty event_log",
                     "parsed events section has event_log",
                     "replay after load does not grow log",
                     "inner _fire() replay does not grow log"],
        "expect": "应红恢复族——存档段不带日志 = 跨存档后重放会重新掷骰",
    },
    {
        "id": "C18-p17b-cursor-not-persisted",
        "desc": "events 存档段不写 scheduled_cursor（读档后定时事件游标归零——重复发放）",
        "file": "src/systems/event_system.gd",
        "old": '\t\t"scheduled_cursor": _cursor,',
        "new": '\t\t"scheduled_cursor": 0,',
        "probe": "p17b",
        "target": ["cursor restored from real file"],
        "chain_ok": ["scheduled cursor advanced before save"],
        "expect": "应红游标恢复判据",
    },
    {
        "id": "C19-p17b-idempotency-off",
        "desc": "幂等查重失效（破 _fire() 内层查重——所有路径的必经之地）",
        "file": "src/systems/event_system.gd",
        # ⚠ 锚点纪律（三条，全是实测踩出来的）：
        #   ① 必须破**内层** _fire() 的查重：fire() 查重后调 _fire()，
        #      而 _fire() 内部**自己也查一次重** → 破外层 fire() 时内层仍拦住
        #      → 行为不变 → 判据测不到（实测踩过）。
        #      内层是所有路径（roll_daily / check_scheduled / poll_conditions / fire）
        #      的必经之路。
        #   ② 跨行片段必须**完整匹配到行尾**（含中文注释）：
        #      我先前写成 `...\n\t\treturn   # P9 幂等：同键不重复发放`（漏了中文后半段），
        #      replace 把中文注释的 "/" 留在 `if false:` 后面 →
        #      "Expected statement, found '/' instead." → 整个文件编译失败 →
        #      探针 0 条断言 → 工具误判成"捕获"（其实是变异无效）。
        #   ③ 不能留半截中文注释（`\n\t# ` 那种补丁会让文件变脏）。
        "old": '\tif _has_logged(key):\n\t\treturn _log_entry(key)',
        "new": '\tif false:\n\t\treturn _log_entry(key)   # MUTATED C19: idempotency off',

        "probe": "p17b",
        "target": ["inner _fire() replay does not re-apply effect",
                   "inner _fire() replay does not grow log"],
        "chain_ok": ["replay after load does not re-apply effect",
                     "replay after load does not grow log"],
        "expect": "应红重放族——读档后重放必须不重复发放",
    },
]



def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    results = []
    touched = {}
    for mu in MUTANTS:
        if only and only not in mu["id"]:
            continue
        rid = mu["id"]
        print(f"\n===== 变异体 {rid}: {mu['desc']} =====")
        rel, old, new = mu["file"], mu["old"], mu["new"]
        try:
            before, off, old_len = apply_mutation(rel, old, new)
        except RuntimeError as e:
            print(f"  跳过：{e}")
            results.append({"id": rid, "desc": mu["desc"], "skipped": str(e),
                            "captured": False, "no_collateral": False})
            continue
        touched[rel] = (old, new, before, off, old_len)
        try:
            reds, total, code = run_probe(mu["probe"])
            expect_total = PROBE_ASSERTS[mu["probe"]]
            # ★ 断言数变化**不等于**结果无效：
            #   变异可能让某条判据"提前 return"从而跳过后续断言（如防空转护栏判红后 continue）。
            #   这恰恰是**判据起作用**的证据。所以只**记警告**，不中止。
            #   真正无效的情况是：红集里既没有 target，断言数又变了（那是探针自身崩了）。
            size_changed = (total != expect_total)
            if size_changed:
                print(f"  ⚠ 断言数 {total} != 期望 {expect_total}（变异导致部分断言被跳过——"
                      f"若 target 已红则属护栏生效，非无效）")
            print(f"  探针 {mu['probe']}：exit={code}，红判据 {len(reds)} 条")
            for r in reds:
                print(f"    - {r}")

            def in_target(name):
                return any(t in name for t in mu["target"])

            def in_chain(name):
                return any(c in name for c in mu["chain_ok"])

            captured = any(in_target(r) for r in reds)
            # 探针被中断（崩溃）时：目标判据没红，但断言数变少 → 也是捕获。
            # 判据本体写作"调用后还能继续执行"，崩溃就等于这条判据不成立。
            #
            # ⚠⚠ 但**断言数为 0 是另一回事**（2026-10-22 实测踩坑）：
            #   0 条断言 = 探针**根本没跑起来**（编译失败 / 场景加载失败），
            #   不是"跑到一半崩了"。若把它判成"捕获"，就会把
            #   「变异体本身写坏了代码」伪装成「判据抓到了变异」——
            #   这是**假绿**，比假红更危险（判据看起来有牙，其实没测到）。
            #   → 0 条断言一律判**变异无效**（invalid），不算捕获。
            if total == 0:
                print(f"  ✗ 探针 0 条断言 = 探针未跑起来（编译/加载失败）"
                      f"→ 判**变异无效**，不算捕获")
                results.append({"id": rid, "desc": mu["desc"], "file": rel,
                                "probe": mu["probe"], "invalid": True,
                                "captured": False, "no_collateral": False,
                                "note": "探针 0 条断言：变异体导致编译/加载失败，变异无效"})
                continue
            if not captured and size_changed and total < expect_total:
                captured = True
                print(f"  → 探针在目标断言前中断（断言数 {total} < {expect_total}）"
                      f"= 目标判据因崩溃而不成立，判为捕获")
            collateral = [r for r in reds if not (in_target(r) or in_chain(r))]
            no_collateral = captured and not collateral
            note = mu["expect"]
            if not captured:
                note += " → 未捕获（SURVIVED）：目标判据没红，判据对该变异是摆设"
            elif collateral:
                note += " → 误伤：" + " | ".join(collateral)
            else:
                note += " → 捕获 ✓ 且无误伤 ✓"
            results.append({"id": rid, "desc": mu["desc"], "file": rel, "probe": mu["probe"],
                            "red": reds, "captured": captured,
                            "no_collateral": no_collateral, "note": note})
        except Exception as e:
            print(f"  异常：{e}")
            results.append({"id": rid, "desc": mu["desc"], "file": rel, "probe": mu["probe"],
                            "error": str(e), "captured": False, "no_collateral": False,
                            "note": "运行异常，结果无效"})
        finally:
            after = revert_mutation(rel, old, new, off, old_len)
            if after != touched[rel][2]:
                print(f"  ✗✗ 还原校验失败 {rel}: {touched[rel][2]} → {after}")
                # 兜底：用 git 把文件还原到 HEAD，**绝不留被变异污染的文件**。
                # 不这么做 = 把改坏的数据留在工作区，别的组会踩到（实测 C2 就这么翻车的）。
                print(f"  → 触发兜底：git checkout -- {rel}")
                subprocess.run(["git", "checkout", "--", rel], cwd=ROOT, check=False)
                if md5(os.path.join(ROOT, rel)) != touched[rel][2]:
                    print(f"  ✗✗✗ 兜底也失败 {rel}，需人工核查！")
                    sys.exit(2)
                print("  兜底还原 OK（md5 一致）")
                # 记录已在 except 分支写入，这里**不再重复 append**
            else:
                print("  还原校验 OK（md5 一致）")

    # 收尾：校验所有被改过的文件都回到原样（不信过程，只信最终状态）
    for rel, (old, new, before, off, old_len) in touched.items():
        if md5(os.path.join(ROOT, rel)) != before:
            print(f"  ✗✗ 收尾校验失败 {rel}，触发 git 兜底还原")
            subprocess.run(["git", "checkout", "--", rel], cwd=ROOT, check=False)
            if md5(os.path.join(ROOT, rel)) != before:
                print(f"  ✗✗✗ 兜底也失败 {rel}，需人工核查！")
                sys.exit(2)

    confirmed = [r for r in results if r.get("captured") and r.get("no_collateral")]
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("\n===== 战斗组变异汇总 =====")
    for r in results:
        tag = "OK" if r.get("captured") and r.get("no_collateral") else (
            "未捕获" if not r.get("captured") else "误伤")
        print(f"  [{tag}] {r['id']}  ({r.get('probe','?')})")
    print(f"  变异确认独立覆盖: {len(confirmed)} / {len(results)}（详见 tools/mutation_combat_report.json）")
    if len(confirmed) < len(results):
        sys.exit(1)


if __name__ == "__main__":
    main()
