# CURRENT.md — 现行值表（**由 tools/gen_values.py 生成，禁止手改**）

> **source_hash**: `c141aed7b684`　｜　**生成时间**: 2026-10-19T08:44:22Z
> 
> 规则：JSON 是源头，本文件是派生物。
> 若你手里的表 hash 与上面不同，**你就是旧版**，不要合并、不要引用。
> 要看某个值为什么是这个数 → 看 `data/` 下对应的 JSON 与本方案的对应章节。

---

## 一、时间基准

| 键 | 值 | 落点 |
|---|---|---|
| `tick_hz_count` | 60 | balance/time.json |
| `frames_per_gh_count` | 4320 | balance/time.json |
| `seconds_per_gh_sec` | 72 | balance/time.json |
| `stage_a_active_gh` | 15 | balance/time.json |
| `stage_b_day_gh` | 12 | balance/time.json |
| `days_stage_a_count` | 7 | balance/time.json |
| `nights_stage_b_count` | 7 | balance/time.json |

## 二、战斗时序（权威＝帧数，秒值由帧数生成）

| 键 | 值（帧） | 落点 |
|---|---|---|
| `iframes_ticks` | 9 | balance/time.json |
| `windup_ticks` | 8 | balance/time.json |
| `recovery_ticks` | 6 | balance/time.json |
| `hitstun_ticks` | 12 | balance/time.json |
| `incap_ticks` | 216 | balance/time.json |

## 三、四条状态

| 键 | 值 | 落点 |
|---|---|---|
| `hunger_rate_per_gh` | 5.0 | balance/survival.json |
| `thirst_rate_per_gh` | 7.0 | balance/survival.json |
| `hp_loss_hunger_zero_per_sec` | 1.0 | balance/survival.json |
| `hp_loss_thirst_zero_per_sec` | 1.5 | balance/survival.json |
| `wild_sleep_hp_penalty_hp` | 15 | balance/survival.json |

## 四、循环系统（**原设计值，撤回 (b) 后**）

| 键 | 值 | 落点 |
|---|---|---|
| `mushroom_food_rate_l1_per_gh` | 0.12 | balance/loop.json |
| `mushroom_food_rate_l2_per_gh` | 0.19 | balance/loop.json |
| `mushroom_food_rate_l3_per_gh` | 0.22 | balance/loop.json |
| `filter_water_rate_l1_per_gh` | 0.15 | balance/loop.json |
| `filter_water_rate_l2_per_gh` | 0.2 | balance/loop.json |
| `filter_water_rate_l3_per_gh` | 0.24 | balance/loop.json |
| `facility_upgrade_cost_parts` | 5 | balance/loop.json |
| `parts_store_cap_units` | 20 | balance/loop.json |
| `stage_b_parts_demand_units` | 48 | balance/loop.json |

> ⛔ **已撤回**：`0.22 / 0.26 / 0.26 / 0.30`（(b) 方案）。若你手上是这组，你是旧版。

## 五、科技树

| 键 | 值 | 落点 |
|---|---|---|
| `total_nodes_count` | 24 | tech/tech_tree.json |

**24 是下限，不许再砍**（再砍则单局可全开，摧毁多周目卖点）。

---

## 六、派生态（本表不手写，由 JSON 现算）

| 量 | 值 | 含义 |
|---|---|---|
| 7 夜末端食物 | **+4.32 单位** | Lv2 全程，带入 6 |
| 7 夜末端净水 | **+2.40 单位** | Lv2 全程，带入 8 |
| 食物余量 | **0.90 天** | 产出归零后还能活多久 |
| 净水余量 | **0.43 天** | ⚠ 零容错，属设计意图 |
| 仅 Lv1 末端 | 食物 -7.44 / 净水 -6.00 | 不升 Lv2 必死（知识型必败） |

---

## 七、风险状态（**不是已关闭**）

| 风险 | 状态 | 说明 |
|---|---|---|
| R11 拆解台依赖 | 已缓解 + 守护断言 | D8 06:00 未解锁自动补授，断言计数 == 1 |
| R13 Lv3 必需 | **撤回（不成立）** | Lv2 即可撑过 7 夜 |
| **R13' Lv1 必败** | **活跃（知识型）** | 零件够 10 但玩家可能不知道要升 Lv2；**S7-a 扫不出来** |

> **知识型必败不是「边」的问题，是「玩家不知道」的问题。** 它只能靠可感知提示，不能靠扫描。
