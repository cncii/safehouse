# data/UNDEFINED.md — 缺数清单（逻辑组 · 包 B）

**版本**：v0.1（2026-10-19）｜**填写人**：逻辑组｜**验收人**：老板
**格式**：五格 = 被谁需要 / 缺什么 / 影响什么 / 谁能定 / 阻塞什么

> **这份清单为什么存在**：任务书 §4 禁改清单第 2 条写死「改数值 = 设计变更，退回需求方」，
> 而设计基线 9.6 只给了 9 类地点的**语义**（谁产什么），没给**数值**。
> 所以逻辑组现在的做法是：**结构我建、数值不编**——先把可校验的结构落进 `data/**`，
> 把每一个编不出来的数登记在这张表上。`locations.json` / `themes.json` / `loot_tables.json`
> 顶部都带 `$provisional` 标记，**在对应格签字前，任何一个数都不构成「定稿数值」**。

---

## A. 阻塞可玩性（不填就玩不到第一天的决策点）

| # | 被谁需要 | 缺什么 | 影响什么 | 谁能定 | 阻塞什么 |
|---|---|---|---|---|---|
| D-001 | `map_system.travel_cost()` | `locations.json` 12 条 `travel_cost_gh` 的真实单程 GH 成本 | 「今天去不去郊区农场」是阶段 A 唯一的空间决策，成本定错 = 时间预算全错 | 创意总监（配设计侧时间账） | **灰盒走一天的出门选择**；P12 背包基线的上游 |
| D-002 | `map_system.travel_cost()` | 节点图**拓扑**是否就这么定（当前 12 条边是我按"安全屋为枢纽"推的） | 决定"必须两次往返才能拿的东西"是否存在——直接决定门禁 20:00 的挤压强度 | 创意总监 | 灰盒；M11a/M11b 门禁两侧 |
| D-003 | `map_system.is_refilled()` | `refill_from_day_count`（当前统一 D4）与回填命中比例（当前 1/3） | 高频地点二次前往的价值 = 搜刮期是否允许"为一件零件跑两趟" | 创意总监 | 搜刮期 7 天的资源可及性 |

## B. 阻塞内容落地（结构已通、数值空转）

| # | 被谁需要 | 缺什么 | 影响什么 | 谁能定 | 阻塞什么 |
|---|---|---|---|---|---|
| D-004 | `map_system._build_rooms()` | `themes.json` 三主题的 `layout_room_count` / `layout_corridor_count` / `layout_loot_point_count` | 单地点的搜索密度与"一趟能带走多少"，直接决定 P12（食物≥5 净水≥6 零件 15–25）能不能成立 | 创意总监 + 需求方 | P12 背包基线；P13 满仓守恒 |
| D-005 | `map_system._build_rooms()` | 9 类地点 → 3 套 tile 主题的映射（当前 commercial/residential/industrial 是我按"用途相近"分的） | 决定哪几类地点共用一套 tile 与危险基调 | 美术总监 + 创意总监 | 9 类地点的场景拼装 |
| D-006 | `map_system.loot_point()` | `loot_tables.json` 全部 `entry_weight_ratio` / `entry_min_count` / `entry_max_count` | **D8 食物/净水是否够**——背包基线与阶段 B 生存线的共同上游 | 创意总监 | P12、S7-b 的现实侧、M32 |
| D-007 | 背包 | `items.json` 的 `weight_units` / `durability_units` / `effect` 引用 | 背包容量 24 格（P12 的分母）与"带得动多少零件" | 创意总监 | P12 / P13；随身物资取舍 |
| D-014 | `inventory_system._effect_delta()` | `item_med_gauze` 的回血量（`effect` 引用）。survival.json 只定稿了食物/净水/能量棒三条效果，医疗包没定 | 决定"受伤后多久能回本"，直接影响野睡扣血后的容错 | 创意总监 | 阶段 B 医疗消耗闭合；`items.json` 的 effect 字段整体 |
| D-008 | `map_system._build_rooms()` | 布局专用 RNG 子流。当前**借用 `FLAVOR`**（房间排布属呈现随机，不耦合玩法数值） | 若日后把 FLAVOR 派给他用，布局会跟着变——RNG 盐值表只许末尾追加，改不了旧值 | **架构总监**（追加 `LAYOUT` 盐值到 `data/rng_salts.json` 末尾） | 不阻塞，但**记账**：这是本轮唯一一次借用他人数值 |
| D-009 | `map_system` 搜刮标记 | `state_contract.json` 缺 `map.looted_nodes`（已搜刮标记）与 `map.refilled_nodes`（回填状态）两条路径 | 搜过即打空是设计基线 2.6 明写的规则，**没有状态路径就存不进档** | 需求方 + 架构 + QA（三方过审，协作纪律 5） | ~~阻塞搜刮/回填的存档一致性~~ **已裁决（见下）** |
| D-010 | P24 隐藏状态 | `locations.json` 缺"隐藏时遭遇率 -60%"的落点与作用范围 | P24 判据无判据对象 | 创意总监 | P24 |
| D-011 | `loop_system.production_rate_milli(POWER)` | `loop.json` 只有 `generator_fuel_duration_gh: 8`（一箱油能烧多久），**没有发电速率**（每秒/每 GH 产多少电）。本轮用 `1.0/GH` 占位 | 电力是 L3 全链的总开关——速率错了，"断电时全 L3 产出×50%"的痛感就不对 | 创意总监 | L3 三条链的实际收益；断电决策是否成立 |
| D-012 | `loop_system.production_rate_milli(MEDS)` | `medical_kit_rate_per_day: 0.4` 是**每天**口径，但没说是「医疗台持续产出」还是「可制作速率」；解锁条件也没定（medical_bench 是 L3） | 决定医疗包是稳定来源还是一次性制作动作 | 创意总监 | MEDS 链状态面板；阶段 B 消耗闭合 |
| D-013 | S7-b 判据口径 | `tools/validate_data.py` 的 `s7b_resource_balance` **docstring 与代码不一致**：docstring 写「D8–D9 Lv1（2 天）→ D10 起 Lv2（5 天）」，代码 `days_by_level = [0, 7, 0]`（D8 起全程 Lv2） | 两种口径的末端余量不同，判据结论会跟着漂。逻辑组 `balance_closure()` **按代码口径实现**（与已交付判据逐位对齐） | 包 F + 创意总监 | 不阻塞逻辑组，但 S7-b 的"权威口径"目前是代码说了算、文档说了不算 |

---

## C. 逻辑组自持的已知技术债（不需设计侧签字）

| # | 项 | 现状 | 处理时机 |
|---|---|---|---|
| T-001 | `tests/run_tests.gd` | 名义归包 F。逻辑组只在本文件内自带 `verify_determinism()`，M9/P16 判据本体在 `map_system.gd` | 包 F 接线：`run_tests.gd` 里加一行读 `verify_determinism()` 即可红绿 |
| T-002 | `themes.json` 单文件而非 `themes/*.json` | M28-b 判据是"同名叶子键只能出现在 1 个文件"，拆多文件会让 `layout_room_count` 这类同名不同值的键被误判为重复定义 | 已按现行判据收敛；若包 F 放宽 M28-b，可再拆回目录 |
| T-003 | `StateStore._authorize` 对 op 值本身做 min/max 校验 | 负增量走 `add()` 会被判"低于 min 0"拒写。`vitals_system` 已改走绝对值 `setv` 规避 | core 是否语义化由架构总监定；不改也不影响逻辑组 |
| T-004 | `travel_cost` 无连线返回 `-1` 而非 `0` | `-1` = 不可达，调用方必须处理。**返回 0 会被当成免费传送** | 已实现，调用方（战斗组/表现组）需知会 |

---

## D-009 裁决落地（2026-10-20 · 老板裁定）

**裁决要点**：① 不等三方过审、不动 core；② 挂接点由源头补齐（已补）；
③ **容器型状态不进 contract 是设计本来如此**——ChangeSet 是数值 Op 流，塞不进容器；
④ core/schema 只由源头统一修，我们自己改会分叉出第二个版本；⑤ 确需数值型新路径才报。

**已接的四个挂接点**（判据本体在各自系统文件内，经注册表挂接）：

| key | 文件 | 容器型（不进 contract） | 数值型（走 State 单点源） |
|---|---|---|---|
| `inventory` | `inventory_system.gd` | `items[]` / `next_instance_seq` | `inventory.auto_ration` |
| `tech` | `tech_tree_system.gd` | `blueprints` / `cost_multiplier` | `tech.unlocked` / `tech.researching` |
| `facilities` | `loop_system.gd` | 5 件设施的同构段 | `facilities.dismantle_bench.progress_milli` |
| `map` | `map_system.gd` | `locations`（visited/looted/refill_generation）/ `pending_refills` | `map.current_node` / `map.unlocked_nodes` |

**分层纪律**：数值型字段一律 `to_save` 从 State 读、`from_save` 往 State 写，
**不维护本地副本**——副本就是第二个来源，P7（读档 diff=0）会开始挑刺。
容器型字段走本地 state，不进 contract。

**本轮结论：不需要新增任何数值型 contract 路径。** 所有写入路径均已在 `state_contract.json` 内。

## 本轮新发现（core 侧 · 需源头修，逻辑组未动）

| # | 位置 | 问题 | 影响 |
|---|---|---|---|
| **C-01** | `src/core/save_system.gd` `_build_payload()` | `"time"` 段是**硬编码常量**（`day:1, stage:"A", phase:"PREP", night_index:0, gh_elapsed_today:0.0, mode:"REALTIME"`），不取 `TimeSystem` 真实状态；且 **`save.schema.json` 要求的 `time.k_overtime` 整段缺失** | 存档里的时间永远是最新的第 1 天。读档后 day/阶段/时段全回到初始——**M7/M8/P7 三条判据直接失效**。逻辑组**没有**自行注册 `"time"` 段来覆盖：那会造成 core 与 systems 两个写入方，正是裁决里点名要避免的「分叉出第二个版本」 |
| **C-02** | `data/schema/save.schema.json` | `time` 段没有 `k_overtime`，而 `save.schema.json` 是存档字段蓝图 | 同上；schema 与 core payload 两边都要补 |

---

## 表现组（包 D）登记（2026-10-20 · W4）

| # | 被谁需要 | 缺什么 | 影响什么 | 谁能定 | 阻塞什么 |
|---|---|---|---|---|---|
| D-015 | `tools/ui_screenshot_runner.gd`（S5） | 27 组合的具体清单：三分辨率（工具默认 1280×720 / 1920×1080 / 2560×1440）、三模式（窗口 / 无边框 / 独占全屏）、DPI 100/125/150（以 content_scale_factor 模拟系统 DPI，CANVAS_ITEMS 口径） | 27 组合截图包口径与 S5 红绿结论（本轮按默认清单已跑：**0 越界 PASS**，见 `build/s5_report.md`） | 老板 | S5 交付定稿 |
| D-016 | `src/systems/audio_system.gd` | 音频素材全套：`assets/audio/sfx/{alarm_hunger, alarm_thirst, heartbeat}.ogg`（循环）；溢出预警一次性音效（P20，触发源等 W2 库存两级预警接线）；任一 BGM（`assets/audio/bgm/`） | M 组"可听警报"判据代码侧已绿（ui_smoke 8 条断言），听感无法佐证；素材按 `<id>.ogg\|wav\|mp3` 约定路径落位后**零代码改动自动生效** | 老板 / 美术（素材包接入） | 音频判据的录屏佐证；试玩听感 |