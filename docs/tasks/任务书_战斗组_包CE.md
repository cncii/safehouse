# 任务书 · 战斗组（包 C + E · 事件战斗 + 存档平台）

**编号**：TASK-CE v1.0（2026-10-19）｜**上游**：《模块分包说明.md》§2 包 C/E｜**验收人**：老板（红绿以 `tools/test.ps1` 为准）

## 1. 一句话目标

把"近战闪避"做成有手感的核心卖点，把波次/事件/破防结算跑通，并完成 Steam 技术接入——这个项目最贵的两个风险（战斗不达标、必败路径）都在你们手里。

## 2. 范围

| 做 | 不做 |
|---|---|
| `combat_system` 攻击/翻滚/受击三件套 + 波次状态机 | ❌ core 层与 schema 改动 |
| `event_system` 三类触发 + append-only 日志重放 | ❌ 四类能力封闭集（`num/flag/time/spawn`）扩展 |
| `spawn_service`（纯消费者，禁掷骰）+ `data/enemies/**` | ❌ UI/HUD（归表现组） |
| Steam 接入验证（GodotSteam + NullSteam 降级） | ❌ 商店页文案/成就设计（用户侧） |

## 3. 名下文件（可改）

```
src/systems/combat_system.gd    src/systems/event_system.gd
src/systems/spawn_service.gd    src/systems/meta_system.gd
src/platform/**                 data/events/**  data/enemies/**  data/balance/combat.json（新建）
```

## 4. 禁改清单

1. **战斗 5 帧常量**（在 `time_system.gd`：无敌 9 / 前摇 8 / 后摇 6 / 硬直 12 / 失能 216）——C28 契约：帧是唯一权威，秒值由脚本生成。
2. **EffectSink 四类能力**（effect.schema.json 已锁）——事件需要新效果 = 走 `num/flag` 组合，不许提"加第 5 类"。
3. **事件 condition 用结构化谓词**——一个 `!` 字符串都不许出现（第 2 个交界洞）。
4. **RNG 单一入口**——敌人参数全部来自 plan/table 的槽位 hash，`randi()` 出现即 CI exit 1。
5. **夜战进行中不写档**（SaveSystem 已拦，勿绕）；破防目标走 `LoopSystem.pick_breach_target`（字典序+hash）。

## 5. 开工顺序

```
W1  combat 三件套骨架 + scenes/debug/combat_arena.tscn 调参场景
    （3 秒重开、热重载 combat.json、无敌帧可视化——手感判据 R5 的唯一载体）
W2  wave_plan 物化 + spawn 消费 → 跑 M19（实际生成与 plan 逐项相等，18:00±1帧）
W3-4 event_system 日志重放 → 跑 P17/P17b（重放零掷骰）/P8/P9/P10（幂等与回滚）
    Steam 接入 → 验证"初始化失败是否回连 Valve"（S9 出站 0 的唯一不确定项，Process Monitor）
```

## 6. DoD

| 组 | 判据 |
|---|---|
| 手感 | R5：连续 10 场战斗闪避次数 > 挥砍×0.6，且无一场站桩打完 |
| 波次 | M19 γ 采样 20/20 全等；M23（挂机兜底 ≤8min，结算恒 12GH）；P11 系列 5 条（同种子极差 0 / 跨种子中位 17%）|
| 事件 | M10（impact 4 类）P8/P9/P10/P17/P17b/P18/P23 |
| 存档 | P6（写档中强杀 100 次可加载 100/100）P7（读档 diff=0）|
| 平台 | S9（防火墙全禁出站 0 / DNS 0）S10（PII 扫描 0）|

**交付物**：combat_arena 可玩包 + 波次 7 夜完整跑通 + Steam 最小可上传包（能启动/Overlay 呼出/成就触发 1 个）。

## 7. 协作纪律

同 TASK-B §7（改 JSON 不发表格 / 值@版本 / 术语查 glossary / 报告两段式），另加两条：
- 每条风险必须有**证伪方式**（"什么证据能证明它不存在"），没有不许进清单；标"已缓解"必须附守护断言。
- 波次表字段规格已定：一个 batch 只放一个 `enemy_id` + 一个 `entry_point`，`count` 是上限不是硬生成数。
