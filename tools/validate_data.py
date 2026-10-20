#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
data/** 源头侧校验器（不需要游戏引擎）

实现 6 条现在就能跑的判据：
  C1/M30  时间链：1GH=4320 帧；阶段A 7 日 = 453600；全季 = 816480
  F0-b    帧数 ↔ 秒值 双向一致
  M28-a   数值键必须带单位后缀
  M28-b   同名键只能出现在 1 个文件
  S7-b    阶段B 食物/净水 7 天收支闭合（按三级升级路径）
  M31     设施等级数 == 1..max（结构）

跑法：python tools/validate_data.py           # 正向
      python tools/validate_data.py --mutate  # 变异测试：验证判据有没有牙齿
"""
import json
import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")

UNIT_SUFFIX = ("hp", "units", "gh", "sec", "s", "ticks", "count", "parts", "px",
               "milli", "day", "pct", "ratio", "mult", "frames", "min", "max")
# ↑ "s" 是老键兼容（attack_interval_s / combat_stamina_sprint_per_s）。
#   新键一律用 "_sec"——不要靠改数据把 _s 改成 _sec，那会动 4 个引用点。

# ── M28-a 判据作用域（2026-10-20 修，勿回滚）──
# 原判据把"不是量纲的数值"一律算违规：71 处里 35 处是误伤，误伤率 49%，
# 直接后果是这条判据被当成噪音、随时可能被关掉。修法是**收窄判据作用域**，
# 而不是给特例开口子（往 no_unit_keys.json 塞白名单 = 开口，且它自带 ≤10 自毁上限）。
SCHEMA_DIRS = ("schema/",)        # JSON Schema 结构声明文件：整体豁免
SCHEMA_KEYWORDS = {"min", "max", "minimum", "maximum", "exclusiveMinimum",
                   "exclusiveMaximum", "multipleOf", "default"}
NON_QUANTITY_FILES = {"rng_salts.json"}   # purpose 名 + 哈希盐；该文件在禁改清单内，
                                          # 契约 6 明写"发布后不可改值"，改名破坏存档兼容
ID_LIKE = re.compile(r"(^|_)(id|index|idx|name|key|salt|purpose|type|version|seed)$")
# 底噪上限：违规数超过它，判据额外报"底噪过高"。
# 让"报错太多"这件事自己变成一条红，而不是靠人自觉——
# 项目已记过教训：误报太多的判据会被关掉，正确做法是修扫描器而非开特例口子。
NOISE_CAP = 10


def load_all():
    files = {}
    for p in glob.glob(os.path.join(DATA, "**", "*.json"), recursive=True):
        rel = os.path.relpath(p, DATA).replace("\\", "/")
        with open(p, "r", encoding="utf-8") as f:
            files[rel] = json.load(f)
    return files


def walk_numeric(d, prefix=""):
    """展开所有数值键： (完整路径, 键名, 值)"""
    out = []
    for k, v in d.items():
        if k.startswith("$"):
            continue
        if isinstance(v, dict):
            out.extend(walk_numeric(v, prefix + k + "."))
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            out.append((prefix + k, k, v))
    return out


def get(d, *keys, default=None):
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur


# ---------------- 判据 ----------------

def c1_time_chain(files):
    """M30 时间链：三级串起来对账。"""
    t = files["balance/time.json"]
    hz = t["tick_hz_count"]
    fpg = t["frames_per_gh_count"]
    spg = t["seconds_per_gh_sec"]
    problems = []
    if fpg != hz * spg:
        problems.append(f"frames_per_gh={fpg} 应等于 {hz}×{spg}={hz*spg}")
    a_days = t["days_stage_a_count"]
    a_gh = t["stage_a_active_gh"]
    b_days = t["nights_stage_b_count"]
    b_gh = t["stage_b_day_gh"]
    a_total = a_days * a_gh * fpg
    b_total = b_days * b_gh * fpg
    total = a_total + b_total
    if a_total != 453600:
        problems.append(f"阶段A 帧数={a_total}，期望 453600")
    if b_total != 362880:
        problems.append(f"阶段B 帧数={b_total}，期望 362880")
    if total != 816480:
        problems.append(f"全季帧数={total}，期望 816480（=189 GH）")
    return (not problems, f"1GH={fpg}帧, A={a_total}, B={b_total}, 总={total}" if not problems
            else "; ".join(problems))


def f0b_frames_seconds(files):
    """F0-b 帧数↔秒值一致。注意：秒值由帧数生成时，此判据结构上恒绿。"""
    t = files["balance/time.json"]
    hz = t["tick_hz_count"]
    cf = t["combat_frames"]
    dc = t["derived_check"]
    pairs = [("iframes", "iframes_ticks", "iframes_sec"),
             ("windup", "windup_ticks", "windup_sec"),
             ("recovery", "recovery_ticks", "recovery_sec"),
             ("hitstun", "hitstun_ticks", "hitstun_sec"),
             ("incap", "incap_ticks", "incap_sec")]
    problems = []
    for name, fk, sk in pairs:
        if fk not in cf or sk not in dc:
            problems.append(f"{name} 缺字段")
            continue
        expect = cf[fk] / hz
        if abs(expect - dc[sk]) > 1e-4:
            problems.append(f"{name}: {cf[fk]}帧={expect:.6f}s ≠ 基线 {dc[sk]}s")
    return (not problems, "5 个战斗常量全部一致" if not problems else "; ".join(problems))


def m28a_bad(files):
    """M28-a 违规清单。拆出来是为了让变异自检能直接比数量（见 mutate 的 M3）。"""
    bad = []
    for rel, d in files.items():
        if rel.startswith(SCHEMA_DIRS):
            continue                      # 结构声明文件，不是量纲
        if rel in NON_QUANTITY_FILES:
            continue                      # purpose 名 + 盐值
        for path, key, val in walk_numeric(d):
            if key.startswith("derived"):
                continue
            if key in SCHEMA_KEYWORDS:
                continue                  # JSON Schema 语法关键字（双保险）
            if ID_LIKE.search(key):
                continue                  # 序号/标识，不是量
            if not any(key.endswith("_" + s) for s in UNIT_SUFFIX):
                bad.append(f"{rel}:{path}")
    return bad


def m28a_unit_suffix(files):
    """M28-a 数值键必须带单位后缀。"""
    bad = m28a_bad(files)
    if not bad:
        return (True, "违规 0 处")
    by_file = {}
    for item in bad:
        rel, path = item.split(":", 1)     # 先拆文件名，再在 path 里取叶子
        leaf = path.rsplit(".", 1)[-1]
        by_file.setdefault(rel, set()).add(leaf)
    noise = ""
    if len(bad) > NOISE_CAP:
        noise = (f"\n        ⚠ 底噪过高：{len(bad)} > 上限 {NOISE_CAP}。"
                 "误报太多的判据会被关掉——正确做法是修扫描器，不是给特例开口。")
    detail = f"违规 {len(bad)} 处" + noise
    for rel in sorted(by_file):
        detail += f"\n          {rel} ({len(by_file[rel])}): " + ", ".join(sorted(by_file[rel]))
    return (False, detail)


def m28b_single_definition(files):
    """M28-b 同名键只能出现在 1 个文件。"""
    seen = {}
    for rel, d in files.items():
        for path, key, val in walk_numeric(d):
            seen.setdefault(key, set()).add(rel)
    dup = {k: v for k, v in seen.items() if len(v) > 1}
    return (not dup, f"重复定义 {len(dup)} 个" + ("" if not dup else f": {dup}"))


def s7a_edge_scan(files):
    """S7-a 边扫描：必需资源的单点依赖 + 可达性 + 公共门槛。

    这是"核边不核点"——所有必败路径都是边的属性，靠人推演永远会漏。
    """
    tech = files["tech/tech_tree.json"]
    nodes = tech["nodes"]
    gates = tech["facility_upgrade_gates"]
    nec = tech["necessities"]

    problems = []
    for nid, n in nodes.items():
        for dep in list(n.get("prereq_all_of", [])) + list(n.get("prereq_any_of", [])):
            if dep not in nodes:
                problems.append(f"{nid}→不存在的 {dep}")
    for g, t in gates.items():
        if t not in nodes:
            problems.append(f"gate {g}→不存在的 {t}")
    for r, deps in nec.items():
        for d in deps:
            if d not in nodes:
                problems.append(f"必需 {r}→不存在的 {d}")

    # 可达性：从无前置节点做 BFS
    roots = [k for k, v in nodes.items()
             if not v.get("prereq_all_of") and not v.get("prereq_any_of")]
    reach = set(roots)
    changed = True
    while changed:
        changed = False
        for k, v in nodes.items():
            if k in reach:
                continue
            all_of = v.get("prereq_all_of", [])
            any_of = v.get("prereq_any_of", [])
            if all(d in reach for d in all_of) and (not any_of or any(d in reach for d in any_of)):
                reach.add(k)
                changed = True
    unreachable = [k for k in nodes if k not in reach]

    # 单点依赖：某必需资源只由 1 个节点提供
    single = [(r, d[0]) for r, d in nec.items() if len(d) == 1]

    # 公共门槛：一个节点 gate 了多个资源族
    fam = {"filter_water_l2": "water", "filter_water_l3": "water",
           "mushroom_bed_l2": "food", "mushroom_bed_l3": "food"}
    gate_fan = {}
    for g, t in gates.items():
        gate_fan.setdefault(t, set()).add(fam.get(g, g))
    shared = [(t, sorted(f)) for t, f in gate_fan.items() if len(f) > 1]

    ok = not problems and not unreachable
    detail = (f"必需 {len(nec)} 个 → 单点 {len(single)} 个"
              + ("（" + "、".join(f"{r}→{n.split('_', 1)[1]}" for r, n in single) + "）" if single else "")
              + f"；不可达节点 {len(unreachable)}"
              + (f"；公共门槛 {len(shared)} 个（" + "、".join(f"{t.split('_',1)[1]}→{f}" for t, f in shared) + "）" if shared else ""))
    if not ok:
        detail += f" ✗ {problems} {unreachable}"
    return (ok, detail)


def s7b_resource_balance(files, upgrades=True):
    """S7-b 阶段B 7 天食物/净水收支。

    设计侧定稿：Lv2 是生存线（食物 5.28/天、净水 6.24/天），Lv3 是裕度。
    路径：D8–D9 Lv1（2 天）→ D10 起 Lv2（5 天）。Lv3 不参与生存判定。
    """
    loop = files["balance/loop.json"]
    surv = files["balance/survival.json"]
    demand_food = surv["derived"]["food_units_per_day"]
    demand_water = surv["derived"]["water_units_per_day"]

    food_rates = [loop["mushroom_food_rate_l1_per_gh"],
                  loop["mushroom_food_rate_l2_per_gh"],
                  loop["mushroom_food_rate_l3_per_gh"]]
    water_rates = [loop["filter_water_rate_l1_per_gh"],
                   loop["filter_water_rate_l2_per_gh"],
                   loop["filter_water_rate_l3_per_gh"]]
    # D8 起即为 Lv2（生存线）；未升级兜底路径 = 全 Lv1
    days_by_level = [0, 7, 0] if upgrades else [7, 0, 0]

    levels = []
    for idx, n in enumerate(days_by_level):
        levels.extend([idx] * n)

    stock_f = loop["carry_in_food_min_units"]
    stock_w = loop["carry_in_water_min_units"]
    min_f, min_w = stock_f, stock_w
    min_day_f = min_day_w = 0

    for day, lvi in enumerate(levels, start=1):
        stock_f += 24 * food_rates[lvi] - demand_food
        stock_w += 24 * water_rates[lvi] - demand_water
        if stock_f < min_f:
            min_f, min_day_f = stock_f, day
        if stock_w < min_w:
            min_w, min_day_w = stock_w, day

    ok = min_f >= 0 and min_w >= 0
    margin_f = stock_f / demand_food
    margin_w = stock_w / demand_water
    zero_tolerance = margin_f < 1.0 or margin_w < 1.0

    detail = (f"末端 食物{stock_f:+.2f}/净水{stock_w:+.2f}；"
              f"最紧处 D{min_day_f}食物{min_f:.2f}·D{min_day_w}净水{min_w:.2f}；"
              f"余量 {margin_f:.2f}天/{margin_w:.2f}天"
              + ("；⚠ 零容错（缺水一天即崩）" if zero_tolerance else "")
              + ("；Lv2 生存线" if upgrades else "；未升级"))
    return (ok, detail)


def m31_facility_levels(files):
    """M31 设施等级结构：max_level 与 rate 表长度一致。"""
    loop = files["balance/loop.json"]
    maxlv = loop["facility_max_level_count"]
    food_keys = [k for k in loop if k.startswith("mushroom_food_rate_l")]
    water_keys = [k for k in loop if k.startswith("filter_water_rate_l")]
    ok = len(food_keys) == maxlv and len(water_keys) == maxlv
    return (ok, f"max_level={maxlv}, 食物速率档={len(food_keys)}, 净水速率档={len(water_keys)}")


def _find_key(d, key):
    if isinstance(d, dict):
        if key in d and isinstance(d[key], (int, float)) and not isinstance(d[key], bool):
            return d[key]
        for v in d.values():
            r = _find_key(v, key)
            if r is not None:
                return r
    return None


def c0_current_md(files):
    """C0：CURRENT.md 是唯一权威表，必须与 data/** 完全一致。

    CURRENT.md 不是副本——它被这条判据盯着；手改一边而不改另一边，立刻红。
    """
    p = os.path.join(DATA, "CURRENT.md")
    if not os.path.exists(p):
        return (False, "缺 data/CURRENT.md")
    text = open(p, "r", encoding="utf-8").read()
    rows = re.findall(r"\|\s*`([a-z0-9_]+)`\s*\|\s*([-0-9.]+)\s*\|\s*([a-zA-Z0-9_./-]+\.json)\s*\|", text)
    problems = []
    for key, val, rel in rows:
        d = files.get(rel)
        if d is None:
            problems.append(f"{key}: 文件 {rel} 不存在")
            continue
        actual = _find_key(d, key)
        if actual is None:
            problems.append(f"{key}: 在 {rel} 中不存在")
        elif abs(float(actual) - float(val)) > 1e-9:
            problems.append(f"{key}: CURRENT={val} ≠ JSON={actual}")
    return (not problems, f"核对 {len(rows)} 行" + ("" if not problems else "; ".join(problems)))


def d1_glossary(files):
    """D1：比较级词必须有唯一定义（"最低可行"在窗口不同时结论相反）。"""
    g = files.get("glossary.json")
    if g is None:
        return (False, "缺 data/glossary.json")
    terms = {k: v for k, v in g.items() if not k.startswith("$")}
    required = ["最低可行", "收支平衡", "足够", "余量", "零容错", "达标", "可行", "平衡"]
    missing = [t for t in required if t not in terms]
    empty = [t for t, v in terms.items() if not str(v).strip()]
    problems = []
    if missing:
        problems.append(f"缺定义: {missing}")
    if empty:
        problems.append(f"空定义: {empty}")
    return (not problems, f"术语 {len(terms)} 条" + ("" if not problems else "; ".join(problems)))


CHECKS = [
    ("C1/M30 时间链 1GH→全季", lambda f: c1_time_chain(f)),
    ("F0-b   帧数↔秒值一致", lambda f: f0b_frames_seconds(f)),
    ("M28-a  数值键单位后缀", lambda f: m28a_unit_suffix(f)),
    ("M28-b  同名键只定义一处", lambda f: m28b_single_definition(f)),
    ("S7-a   边扫描：单点依赖/可达性/公共门槛", lambda f: s7a_edge_scan(f)),
    ("S7-b   阶段B 资源收支闭合", lambda f: s7b_resource_balance(f)),
    ("M31    设施等级结构", lambda f: m31_facility_levels(f)),
]


def run(files=None, verbose=True):
    files = files or load_all()
    results = []
    for name, fn in CHECKS:
        try:
            ok, detail = fn(files)
        except Exception as e:
            ok, detail = False, f"{type(e).__name__}: {e}"
        results.append((name, ok, detail))
    if verbose:
        print("=" * 66)
        print("data/** 源头侧判据（不需要游戏引擎）")
        print("=" * 66)
        for name, ok, detail in results:
            print(f"[{'PASS' if ok else 'FAIL'}] {name}\n        {detail}")
        n = sum(1 for _, o, _ in results if o)
        print("-" * 66)
        print(f"合计 {n}/{len(results)} 通过")
    return results


def _status(results, prefix):
    """取某条判据的 (ok, detail)；判据不存在返回 (None, ...)。"""
    for n, ok, d in results:
        if n.startswith(prefix):
            return (ok, d)
    return (None, "判据不存在")


def mutate():
    print("\n" + "=" * 66)
    print("变异测试（标准：目标变红，且只有目标变红）")
    print("=" * 66)
    base = load_all()
    base_r = run(base, verbose=False)

    # ⚠ 判定口径（2026-10-20 修，勿回滚）：
    # 原来是「red 非空即 KILLED」。但 M28-a 未注入缺陷时 red 已非空，
    # 于是该自检**永远 KILLED = 假绿**，整套自检对这条判据失效。
    # 正确口径是「注入后**变红/增多**才算 KILLED」——必须和基线比，不能看绝对值。

    # M1: 时间链断裂——把 stage_b_day_gh 12 → 13
    f = load_all()
    f["balance/time.json"]["stage_b_day_gh"] = 13
    r = run(f, verbose=False)
    b_ok, _ = _status(base_r, "C1/M30")
    m_ok, _ = _status(r, "C1/M30")
    killed = (b_ok is True) and (m_ok is False)
    print(f"[{'KILLED' if killed else 'SURVIVED'}] stage_b_day_gh 12→13"
          f"（C1/M30 基线 {'PASS' if b_ok else 'FAIL'} → 注入后 {'FAIL' if m_ok is False else 'PASS'}）")

    # M2: 资源不升级（回到只有 L1）
    f = load_all()
    r = run(f, verbose=False)
    ok_up, detail_up = s7b_resource_balance(f, upgrades=True)
    ok_no, detail_no = s7b_resource_balance(f, upgrades=False)
    print(f"[{'KILLED' if not ok_no else 'SURVIVED'}] 去掉三级升级（只走 L1）")
    print(f"        三级路径: {'PASS' if ok_up else 'FAIL'} — {detail_up}")
    print(f"        仅 L1   : {'PASS' if ok_no else 'FAIL'} — {detail_no}")

    # M3: 数字键去掉单位后缀（口径：违规数必须**增多**，不是 red 非空）
    base_bad = m28a_bad(base)
    f = load_all()
    surv = f["balance/survival.json"]
    surv["hunger_rate_broken"] = surv.pop("hunger_rate_per_gh")
    mut_bad = m28a_bad(f)
    killed = len(mut_bad) > len(base_bad)
    print(f"[{'KILLED' if killed else 'SURVIVED'}] 键名去掉单位后缀"
          f"（M28-a 违规 {len(base_bad)} → {len(mut_bad)}）")

    # ── M28-a 作用域自检样例（防止"豁免吞掉真缺陷"，也防止"误伤复发"）──
    print("\n  -- M28-a 作用域自检 --")
    base_set = set(base_bad)

    # 阳性：真缺陷必须仍然被报出来（豁免不许把它们一起免掉）
    def _hit(rel, leaf):
        for b in base_set:
            br, bp = b.split(":", 1)
            if br == rel and bp.rsplit(".", 1)[-1] == leaf:
                return True
        return False

    for rel, leaf in [("enemies/enemies.json", "hp"),
                      ("enemies/enemies.json", "damage"),
                      ("enemies/enemies.json", "speed"),
                      ("enemies/enemies.json", "breach_damage"),
                      ("events/waves.json", "strength_multiplier"),
                      ("balance/combat.json", "combat_damage_base")]:
        got = _hit(rel, leaf)
        print(f"    [{'OK' if got else 'MISS'}] 真缺陷仍报：{rel}:{leaf}")

    # 阴性：ID 型键 / rng_salts / schema 关键字 不得再被报
    f = load_all()
    f["events/waves.json"]["probe_index"] = 3               # ID_LIKE 应豁免（序号，不是量）
    f["rng_salts.json"]["PROBE_SALT_PURPOSE"] = 12345       # 非量纲文件应豁免
    f["schema/state_contract.json"]["probe_min"] = 0        # schema/ 目录应豁免
    mut2 = set(m28a_bad(f))
    added = mut2 - base_set
    print(f"    [{'OK' if not added else 'MISS'}] 注入 3 个非量纲键后新增违规 {len(added)} 处（应为 0）"
          + ("" if not added else f"：{sorted(added)[:5]}"))

    # M4（层2b）：改 windup 8→7 并同步秒值 → F0-b 是否恒绿
    f = load_all()
    t = f["balance/time.json"]
    t["combat_frames"]["windup_ticks"] = 7
    t["derived_check"]["windup_sec"] = 7 / t["tick_hz_count"]
    ok, detail = f0b_frames_seconds(f)
    print(f"[{'SURVIVED(恒绿)' if ok else 'KILLED'}] windup 8→7 且秒值同步重算 → F0-b")
    print(f"        {detail}  ← 说明 F0-b 只防'文档手改秒值'，不防'帧数被改坏'")


if __name__ == "__main__":
    results = run()
    if "--mutate" in sys.argv:
        mutate()
    # ⚠ 退出码（2026-10-20 补，勿回滚）：
    # 原来本脚本无论几条 FAIL 都 exit 0。于是 test.ps1 的 stage 1 恒绿——
    # M28-a 红了 71 处（修完仍 31 处），stage 1 照样报"通过"，门禁等于没接。
    # 判据红了就必须让调用方看得见，否则"修判据"这件事本身没有任何效果。
    n_ok = sum(1 for _, o, _ in results if o)
    sys.exit(0 if n_ok == len(results) else 1)
