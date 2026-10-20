#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 data/CURRENT.md —— 值表的唯一副本。

规则（v1.35）：JSON 是源头，CURRENT.md 是**派生物**，由本脚本生成。
  - 禁止手改 CURRENT.md（改了也会被下次生成覆盖）
  - 生成的 source_hash 相同 ⇒ 两人的 JSON 相同；不同 ⇒ 谁是旧版一目了然
  - C0 判据校验 CURRENT.md 与 JSON 一致（本脚本保证，C0 兜底）

跑法：python tools/gen_values.py
"""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(DATA, "CURRENT.md")


def load(rel):
    with open(os.path.join(DATA, rel), "r", encoding="utf-8") as f:
        return json.load(f)


def source_hash(pairs):
    h = hashlib.sha256()
    for rel, d in sorted(pairs):
        h.update(rel.encode())
        h.update(json.dumps(d, sort_keys=True, ensure_ascii=False).encode())
    return h.hexdigest()[:12]


def row(key, val, rel):
    return f"| `{key}` | {val} | {rel} |"


def main():
    time_j = load("balance/time.json")
    surv = load("balance/survival.json")
    loop = load("balance/loop.json")
    tech = load("tech/tech_tree.json")

    pairs = [("balance/time.json", time_j), ("balance/survival.json", surv),
             ("balance/loop.json", loop), ("tech/tech_tree.json", tech)]
    sh = source_hash(pairs)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # 逐日推演（Lv2 生存线）
    demand_f = surv["derived"]["food_units_per_day"]
    demand_w = surv["derived"]["water_units_per_day"]
    food = [loop["mushroom_food_rate_l1_per_gh"], loop["mushroom_food_rate_l2_per_gh"],
            loop["mushroom_food_rate_l3_per_gh"]]
    water = [loop["filter_water_rate_l1_per_gh"], loop["filter_water_rate_l2_per_gh"],
             loop["filter_water_rate_l3_per_gh"]]

    def sim(levels):
        sf = loop["carry_in_food_min_units"]
        sw = loop["carry_in_water_min_units"]
        mf, mw, df, dw = sf, sw, 0, 0
        for day, lv in enumerate(levels, start=1):
            sf += 24 * food[lv] - demand_f
            sw += 24 * water[lv] - demand_w
            if sf < mf:
                mf, df = sf, day
            if sw < mw:
                mw, dw = sw, day
        return sf, sw, mf, mw, df, dw

    end_f, end_w, min_f, min_w, d_f, d_w = sim([1] * 7)      # Lv2 全程
    l1_end_f, l1_end_w, *_ = sim([0] * 7)                     # 仅 Lv1

    lines = []
    lines.append("# CURRENT.md — 现行值表（**由 tools/gen_values.py 生成，禁止手改**）")
    lines.append("")
    lines.append(f"> **source_hash**: `{sh}`　｜　**生成时间**: {now}")
    lines.append("> ")
    lines.append("> 规则：JSON 是源头，本文件是派生物。")
    lines.append("> 若你手里的表 hash 与上面不同，**你就是旧版**，不要合并、不要引用。")
    lines.append("> 要看某个值为什么是这个数 → 看 `data/` 下对应的 JSON 与本方案的对应章节。")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## 一、时间基准")
    lines.append("")
    lines.append("| 键 | 值 | 落点 |")
    lines.append("|---|---|---|")
    for k in ["tick_hz_count", "frames_per_gh_count", "seconds_per_gh_sec",
              "stage_a_active_gh", "stage_b_day_gh", "days_stage_a_count", "nights_stage_b_count"]:
        lines.append(row(k, time_j[k], "balance/time.json"))
    lines.append("")
    lines.append("## 二、战斗时序（权威＝帧数，秒值由帧数生成）")
    lines.append("")
    lines.append("| 键 | 值（帧） | 落点 |")
    lines.append("|---|---|---|")
    for k, v in time_j["combat_frames"].items():
        lines.append(row(k, v, "balance/time.json"))
    lines.append("")
    lines.append("## 三、四条状态")
    lines.append("")
    lines.append("| 键 | 值 | 落点 |")
    lines.append("|---|---|---|")
    for k in ["hunger_rate_per_gh", "thirst_rate_per_gh", "hp_loss_hunger_zero_per_sec",
              "hp_loss_thirst_zero_per_sec", "wild_sleep_hp_penalty_hp"]:
        lines.append(row(k, surv[k], "balance/survival.json"))
    lines.append("")
    lines.append("## 四、循环系统（**原设计值，撤回 (b) 后**）")
    lines.append("")
    lines.append("| 键 | 值 | 落点 |")
    lines.append("|---|---|---|")
    for k in ["mushroom_food_rate_l1_per_gh", "mushroom_food_rate_l2_per_gh",
              "mushroom_food_rate_l3_per_gh", "filter_water_rate_l1_per_gh",
              "filter_water_rate_l2_per_gh", "filter_water_rate_l3_per_gh",
              "facility_upgrade_cost_parts", "parts_store_cap_units",
              "stage_b_parts_demand_units"]:
        lines.append(row(k, loop[k], "balance/loop.json"))
    lines.append("")
    lines.append("> ⛔ **已撤回**：`0.22 / 0.26 / 0.26 / 0.30`（(b) 方案）。若你手上是这组，你是旧版。")
    lines.append("")
    lines.append("## 五、科技树")
    lines.append("")
    lines.append("| 键 | 值 | 落点 |")
    lines.append("|---|---|---|")
    lines.append(row("total_nodes_count", tech["total_nodes_count"], "tech/tech_tree.json"))
    lines.append("")
    lines.append("**24 是下限，不许再砍**（再砍则单局可全开，摧毁多周目卖点）。")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## 六、派生态（本表不手写，由 JSON 现算）")
    lines.append("")
    lines.append("| 量 | 值 | 含义 |")
    lines.append("|---|---|---|")
    lines.append(f"| 7 夜末端食物 | **{end_f:+.2f} 单位** | Lv2 全程，带入 {loop['carry_in_food_min_units']} |")
    lines.append(f"| 7 夜末端净水 | **{end_w:+.2f} 单位** | Lv2 全程，带入 {loop['carry_in_water_min_units']} |")
    lines.append(f"| 食物余量 | **{end_f / demand_f:.2f} 天** | 产出归零后还能活多久 |")
    lines.append(f"| 净水余量 | **{end_w / demand_w:.2f} 天** | ⚠ 零容错，属设计意图 |")
    lines.append(f"| 仅 Lv1 末端 | 食物 {l1_end_f:+.2f} / 净水 {l1_end_w:+.2f} | 不升 Lv2 必死（知识型必败） |")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## 七、风险状态（**不是已关闭**）")
    lines.append("")
    lines.append("| 风险 | 状态 | 说明 |")
    lines.append("|---|---|---|")
    lines.append("| R11 拆解台依赖 | 已缓解 + 守护断言 | D8 06:00 未解锁自动补授，断言计数 == 1 |")
    lines.append("| R13 Lv3 必需 | **撤回（不成立）** | Lv2 即可撑过 7 夜 |")
    lines.append("| **R13' Lv1 必败** | **活跃（知识型）** | 零件够 10 但玩家可能不知道要升 Lv2；**S7-a 扫不出来** |")
    lines.append("")
    lines.append("> **知识型必败不是「边」的问题，是「玩家不知道」的问题。** 它只能靠可感知提示，不能靠扫描。")
    lines.append("")

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    print(f"已生成 {OUT}")
    print(f"source_hash = {sh}")
    print(f"7 夜末端：食物 {end_f:+.2f} / 净水 {end_w:+.2f}")
    print(f"余量：食物 {end_f/demand_f:.2f} 天 / 净水 {end_w/demand_w:.2f} 天")
    print(f"仅 Lv1：食物 {l1_end_f:+.2f} / 净水 {l1_end_w:+.2f}（必死）")


if __name__ == "__main__":
    main()
