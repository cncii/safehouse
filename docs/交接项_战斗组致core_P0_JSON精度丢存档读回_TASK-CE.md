# 交接项 · P0 缺陷：Godot JSON 解析丢 int64 精度 → 玩家存档读不回来

**发现人**：战斗组（包 C+E）｜**发现日期**：2026-10-22
**发现途径**：做 P17b「跨存档重放」判据时，用**真实文件级** save/load 往返撞上的
**性质**：**P0 —— 阻断级**（玩家每一次真实读档都失败）
**归属**：**core 层**（`src/core/rng_service.gd` + `src/core/save_system.gd` + `data/schema/save.schema.json`）
**战斗组处置**：**只报不改**（任务书 §2「不做」列明写"core 层与 schema 改动"；
core 与 schema 只由源头统一修，各组自行修改会分叉出第二个版本）

---

## 一、一句话结论

> **Godot 4.3 的 `JSON.parse_string()` 会把超出 2^53 的整数转成 `float`（精度丢失）。
> `day_seed` 是 splitmix64 的 64 位输出，8/8 天全部超出 2^53。
> 存档读回时 `day_seed` 必然失真 → `_verify_seed()` 必然判失败 →
> **`Save.load_run()` 恒返回空字典 → 玩家每一次真实读档都失败。**

---

## 二、复现（可复跑，判据归战斗组）

```powershell
$env:GODOT_BIN = "C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"
Set-Location "<仓库根>"
& $env:GODOT_BIN --headless --path (Resolve-Path ".").Path --quit-after 120 res://scenes/debug/core_seed_probe.tscn
# 期望当前输出：5 pass / 3 fail（EXIT=1）—— 红的含义是"缺陷仍在"
```

新增文件：`scenes/debug/core_seed_probe.gd` + `.tscn`（**故意判红**的缺陷检测器，
不并入任何门禁——跑一次就红会污染信号）。

### 关键实测数据

| 观测项 | 结果 |
|---|---|
| `JSON.stringify({"v": -2152535657050944081})` | `{"v":-2152535657050944081}` ✅ **文本正确** |
| `JSON.parse_string(...)` 解析后 | `-2152535657050944000` ❌ **差 81** |
| 解析结果的 `typeof` | `3`（`TYPE_FLOAT`），**不是** `2`（`TYPE_INT`） |
| 2^53 − 1 = 9007199254740991 | 往返无损 ✅ |
| **2^53 = 9007199254740992** | 往返**仍精确** ✅（double 在此处可精确表示） |
| 2^53 + 1 = 9007199254740993 | 往返 → 9007199254740992 ❌ |
| `Rng.day_seed(1..8)` | **8/8 天全部超出 2^53**（不是偶发） |

> ⚠ 边界选点注意：**2^53 本身是可精确表示的**——拿它当"会丢精度"的样本会得到假绿。
> 真正开始丢的是 **2^53 + 1**。

---

## 三、失效链（逐层）

```
Rng.day_seed(day) = splitmix64(global_seed ^ day * GOLDEN)     ← 64 位输出
        ↓
save_system._build_payload()  "day_seed": Rng.day_seed(1)     ← JSON.stringify 文本正确
        ↓ 落盘（GZIP）
user://save.sav
        ↓ 读档
save_system._read_parsed()    JSON.parse_string(text)         ← ★ 这里丢精度 → float
        ↓
save_system._verify_seed()    Rng.verify_day(day, stored)
                             = day_seed(day) == stored_day_seed
                             = 精确值 == 失真值 → **必然 false**
        ↓
load_run()  →  return {}     ← 主档与 .bak 都失败 → 恒返回空
        ↓
★ 玩家读档 = 静默失败（只有 push_error，玩家看不到任何提示）
```

实测日志（战斗组 P17b 探针首次运行时抓到的）：

```
ERROR: load: seed check failed (user://save.sav) - corrupt
ERROR: load: seed check failed (user://save.sav.bak) - corrupt
```

---

## 四、影响面

| 项 | 影响 |
|---|---|
| **玩家读档** | **完全失效**——`load_run()` 恒空。主档与 `.bak` 双双被拒 |
| 破坏性 | 玩家以为读档成功（游戏继续跑），实则**回到新游戏状态**——比直接报错更糟（进度静默丢失） |
| 触发条件 | **必现**，不是概率问题（8/8 天命中） |
| 何时暴露 | 玩家第一次尝试读档时。**此前无任何自动化判据覆盖真实读档**——`tests/` 下搜不到 `Save.save` / `load_run` 的调用 |
| QA 判据表 | P7「读档瞬间快照 vs 存档瞬间 diff = 0」标着 ⛔ C-01 连带——**真实读档从未跑通**，这条判据实际上也没被真正验证过 |
| 架构条款 | 架构 §5.5 契约 5「读档强校验：day_index_of_seed == time.day 且 day_seed 重算匹配」——**校验逻辑本身是对的，但被 JSON 精度问题连坐** |

---

## 五、给 core owner 的三条修法（推荐第 1 条）

| # | 修法 | 改动面 | 评价 |
|---|---|---|---|
| **1** | **seed 存字符串**：`"day_seed": str(Rng.day_seed(1))`，读档时 `int(str(...))` 还原 | `save_system.gd` 写/读各 1 处 + `rng_service.gd` 可加一个 `day_seed_text()` | ✅ **推荐**：改动最小、不动 RNG 算法、JSON 字符串无精度问题 |
| 2 | 拆成高低两半存（`seed_hi` / `seed_lo`，各自 < 2^53） | 同上 + schema | 可行，但读档要重组，多一处出错面 |
| 3 | 存档改二进制（`var_to_bytes`） | 整个存档格式 + 迁移链 + schema | 最彻底，**但代价远超收益**——不建议为这一个 bug 重做格式 |

### ⚠ 无论选哪条，都要同步改 schema

`data/schema/save.schema.json` 的 `random` 段字段类型要跟着改（`day_seed`: `int` → `string` 等）。
**schema 属 core 域**（战斗组不碰），必须同一批改，否则 schema 校验与实现分叉。

### ⚠ 修完后的验收

1. `core_seed_probe` 由 3 红转全绿
2. **新增**：一条"真实读档端到端成功"的判据（现在 `p17b_probe` 走的是自己读文件的路径，
   因为 `load_run()` 恒失败；core 修好后应把判据切回 `load_run()` + `apply_persisted()`）
3. 现有存档（`user://save.sav`）是**旧格式**——迁移链要么兼容旧的 int 格式，
   要么在迁移里加一步（`int` → `str`）。**这一步别漏**，否则玩家旧档仍然读不了。

---

## 六、战斗组这边的状态

- **P17b 判据已可复跑**（`scenes/debug/p17b_probe.gd`，**31/31 全绿**，连跑 3 次稳定）：
  走**真实文件级**链路（`Save.save()` 落盘 → 真实读文件 → 真实 GZIP 解压 → 真实 `JSON.parse_string`
  → 取 `events` 段 → `_from_save` 恢复），**不经过** core 的 `load_run()`。
  证明的是**包 C 自己的责任边界**：events 段在真实存档格式下能否无损往返、重放是否仍不掷骰。
- **core 修好后**，P17b 的判据主体结论依然成立（真实格式往返与格式无关），
  只应把"读回"那一步从"自己读文件"切回 `load_run()` + `apply_persisted()`，补一条端到端判据。

---

## 七、附：另一条同源风险（顺带发现，优先级低）

`register_persistence` 的回调是**实例方法**：

```gdscript
# src/systems/event_system.gd:44
Save.register_persistence(&"events", _to_save, _from_save)
```

`static var _persist_registered` 只保证**不重复注册**，但**回调绑的是"第一个被 new 的实例"**。
若将来有第二个 `EventSystem` 实例被 new 出来（读档重建、或场景重载），
后续 `Save.save()` 序列化的仍是**第一个实例**的容器 → **存档内容错位且不报错**。

当前游戏里 `EventSystem` **只被探针 new 过**（`src/boot/`、`scenes/` 下无 new 点），
所以这是**待接线风险**而非活 bug。战斗组会在接线前把容器与回调一并 static 化
（与项目内已有的 static 容器纪律一致）。本条仅作提示，不紧急。

---

**复跑命令**

```powershell
& $env:GODOT_BIN --headless --path (Resolve-Path ".").Path --quit-after 120  res://scenes/debug/core_seed_probe.tscn
& $env:GODOT_BIN --headless --path (Resolve-Path ".").Path --quit-after 600 res://scenes/debug/p17b_probe.tscn
```
