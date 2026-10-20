# 任务书 · 逻辑组（包 B · 模拟系统）

**编号**：TASK-B v1.0（2026-10-19）｜**上游**：《模块分包说明.md》§2 包 B｜**验收人**：老板（红绿以 `tools/test.ps1` 为准）

## 1. 一句话目标

让游戏"活着"：四条状态、时间日程、地图生成、背包、科技树、循环产线全部可跑——这是另外两个团队的依赖底座。

## 2. 范围

| 做 | 不做 |
|---|---|
| `src/systems/` 下 6 个系统函数体实现 | ❌ 任何 `src/core/**` 改动（地基已交付禁改） |
| `data/balance/*.json`、`data/locations/**` 数值补全 | ❌ 战斗/事件/UI（归战斗组、表现组） |
| 灰盒第一环：玩家能走、能饿死、能存读档 | ❌ 美术、音效、剧情文本 |

## 3. 名下文件（可改）

```
src/systems/time_system.gd          src/systems/tech_tree_system.gd
src/systems/vitals_system.gd        src/systems/loop_system.gd
src/systems/map_system.gd           src/systems/inventory_system.gd
src/systems/continuous_action.gd    data/balance/**  data/locations/**  data/items/**
```

## 4. 禁改清单（改 = 返工）

1. **core 层与 data/schema/** 全部——状态写入只走 `StateStore.apply(ChangeSet)`，越权 debug 崩溃。
2. **文件头标注"定稿数值"的常量**（饥 5/GH、渴 7/GH、野睡 -15HP、失能 216 帧等）——改数值=设计变更，退回需求方。
3. **键名三段式**：`data/**` 新增键必须 `<域>_<量>_<单位>`，域查 `data/schema/domains.json`；validate_data.py 会拦。
4. **同帧结算序**走 `ResolveOrder` 常量表，禁止字典遍历（判据 M14：10 次死亡归因必须一致）。
5. **ContinuousAction 的 `refund_on_cancel` 恒 false**——探针判据在盯着（"无限刷零件"洞已封）。
6. 循环产线一律 **milli 整数定点**（C26）；`Lv2 七天累计产出 < 七天总需求`（M32 会自动否掉"Lv2 盈余"类改动）。

## 5. 开工顺序（第 1–2 周）

```
W1  vitals_system 实现 → 跑 M1/M2/M2b/M3/M3b（1GH=72s；饥饿0→死100±2s；渴0→死66.7s；跨零单帧份额）
    map_system.generate_layout 纯函数化 → 跑 M9/P16（同种子同日重开哈希全等 / 开箱顺序无关）
W2  time_system 三模式状态机（REALTIME/WAVE_DRIVEN/SCRIPTED）→ 跑 P12b（夜间结算恒 12GH ±0.001）
    loop_system 收支闭合 → 跑 M32/S7-b（window_days 必填 + margin_days 输出）
    存读档挂接 → 跑 M7/M8/P7
```

## 6. DoD（红绿验收，判据编号见 tests/run_tests.gd 与 QA 判据表）

| 组 | 判据 |
|---|---|
| 状态 | M1 M2 M2b M3 M3b M4 M5 M13 M14 M15 |
| 地图 | M9（重开 20/20 全等）P16（顺序无关）|
| 背包 | P12（D8 基线：食物≥5 净水≥6 零件15–25）P13（满仓守恒）|
| 科技 | P28（单局 [12,16] 分母 24）M31（tier↔前置深度）P22-0（拆解台守护）|
| 循环 | P12b M32 S7-b M30（锚点全等）|

**交付物**：`tools/test.ps1` 全绿截图/报告 + 可进安全屋走一天的灰盒 + `data/UNDEFINED.md`（缺数清单，五格格式）。

## 7. 协作纪律（违反 = 打回）

- 改数直接编辑 `data/**/*.json`，**禁止在群里发表格**（副本 ≠ 来源，实测事故）。
- 引用别人的数必须复算；跨团队传数格式 `值@来源版本`。
- 术语先查 `data/glossary.json`（"最低/足够/余量"已撞车 5 次）。
- 新增状态路径改 `data/schema/state_contract.json`，writers 变更需需求方+架构+QA 三方确认。
- 报告两段式：机器判定（gate）/人工审查（review）分开列，不许写"全部通过"。
