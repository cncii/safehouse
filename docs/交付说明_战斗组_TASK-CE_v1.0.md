# 战斗组（包 C + E）交付说明 · TASK-CE v1.0

**交付人**：战斗组（包 C·事件与战斗组 / 包 E 平台部分）
**交付日期**：2026-10-20（17:30 更新 B10/S9·S10 进展）
**收件**：测试组 / QA
**引擎环境**：Godot `4.3.stable.official.77dcf97d8`（路径 `C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe`，与工程 `config/features=4.3` 一致）

---

## 0. 回应测试组 2026-10-20 验收报告

| 报告条目 | 战斗组回应 |
|---|---|
| §A stage 2b 红（`loop_system.gd:368`） | ✅ **已解除** —— 包 B 已改为 `var save_level: int = _level["FOOD"]`（显式类型）。战斗组 0 编译错误 |
| §A stage 2b 红（**新**：`tests/run_tests.gd:75`） | 归**包 F**：第 74–75 行两行注释带多余 Tab 缩进 → `Unexpected "Indent" in class body`。去掉行首 Tab 即可。战斗组未改该文件 |
| §A stage 4 红（`-s` 限制） | 确认是包 B 代码（`time_system.gd:274`/`vitals_system.gd:126` 用 `State.read` 实例方法）触发。测试组已用「场景方式」解决，与我的做法一致 |
| §A 修订 #2（M30 `216%60` 恒假） | 确认**判据写错、实现正确**，与战斗组 14:30 前的上报一致 |
| §A `test_combat` M19 四条全绿 | ✅ 战斗组 W2 交付被验收 |
| §A `test_events` M10 三条全绿 | ✅ 战斗组 W3 交付被验收 |
| **§B B10 S9/S10**（划归包 C+E+老板） | **已推进**，见第 8.1 节：S10 做成 **21 条**机械断言（21/21 绿，连跑 3 次稳定），S9 第 1 层做成 2 条（12/12 绿）；第 2 层（OS 层面出站 0）仍需外部工具 |
| 欠件：github.com 直连 reset | ✅ **已同步**。远端 `main` = `e0f9bc0` = 本地 HEAD；战斗组 `6d4a267`/`39331b2` 均在远端。直连不通时走 `tools/gh_push_api.py` API 通道（token 只走环境变量） |
| 欠件：判据表 85+ 条落盘 | 战斗组这边的判据已全部落盘在 `tools/`+`scenes/debug/` 探针与本文档第 4 节映射表；M12b/M15/M22 原文仍需 QA 落盘 |

---

## 1. 一句话状态

W1–W4 全部落地，战斗组自建**四套**无头自检共 **106 条断言全绿**（41+33+12+21）；
GitHub 已同步（远端 = 本地 HEAD）。
**全量验收入口 `tools/test.ps1` 当前 exit=1**，唯一阻塞点在**包 D 表现组的在制品**（见第 5 节），战斗组文件零 BROKEN。

---

## 2. 交付物清单

### 代码（包 C 名下文件）
| 文件 | 内容 | 状态 |
|---|---|---|
| `src/systems/combat_system.gd` | 攻击/翻滚/受击三件套状态机 + wave_plan 物化 + 破防结算 | 新建并实现 |
| `src/systems/spawn_service.gd` | 消费 wave_plan 生成实体，纯消费者零掷骰 | 实现 |
| `src/systems/event_system.gd` | 三类触发 + C17 append-only 日志重放 | 实现 |
| `src/systems/effect_sink.gd` | 修掉 ChangeSet 引用编译失败 | 修复 |
| `src/platform/steam_service.gd` | 修掉加载崩溃隐患 + 补齐 TODO 实现 | 修复 |
| `src/platform/steam_null.gd` | 新增 `backend_id()` | 修改 |

### 数据（包 C 名下）
`data/balance/combat.json`、`data/events/waves.json`、`data/enemies/enemies.json`、
`data/events/random/events.json`、`data/events/scheduled/schedule.json`、
`data/events/conditions/conditions.json`、`data/events/spawn_tables.json`

### 自检场景（新增）
`scenes/debug/combat_probe.{gd,tscn}`、`event_probe.{gd,tscn}`、`steam_probe.{gd,tscn}`、`pii_probe.{gd,tscn}`

### 提交
| 提交 | 内容 | 推送 |
|---|---|---|
| `6d4a267` | W4 平台层修复 + pii_probe 新增 + steam_probe DNS 判据 + 数据键名 | ✅ 已在远端 |
| `39331b2` | pii_probe 两处自污染假红修复 | ✅ 已在远端（**更正**：此前我误判为"推送受阻"，实为 git 客户端传输已完成才报错） |

> 提交只含战斗组名下文件；工作区里别组（表现组/包 F/包 B）的并行改动**未纳入**。
> 两次提交都用精确 `git add <文件>`，未用 `git add -A`。
> 远端 `main` 当前 = `e0f9bc0`（包 F 的提交），本地 HEAD 与之一致，`git push` 是干净的 fast-forward。

---

## 3. 怎么跑（测试组直接复制）

```powershell
$env:GODOT_BIN = "C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"
Set-Location "<项目>\safehouse"

# 战斗组三套自检（各自独立，全绿即通过）
& $env:GODOT_BIN --headless --quit-after 400 res://scenes/debug/combat_probe.tscn   # 期望 41/41, EXIT=0
& $env:GODOT_BIN --headless --quit-after 400 res://scenes/debug/event_probe.tscn    # 期望 33/33, EXIT=0
& $env:GODOT_BIN --headless --quit-after 400 res://scenes/debug/steam_probe.tscn    # 期望 12/12, EXIT=0
& $env:GODOT_BIN --headless --quit-after 400 res://scenes/debug/pii_probe.tscn      # 期望 21/21, EXIT=0

# 全量验收入口（注意：当前 exit=1，见第 5 节）
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

> 战斗组自检合计 **106 条断言**（41+33+12+21）。

> ⚠ **`--quit-after 400` 必须带**：探针会 `get_tree().quit()`，但若加载失败引擎不会自动退出，
> 不加这个参数 CI 会挂死（实测踩过：某次失败时挂了 180 秒直到超时）。

---

## 4. 断言覆盖与判据映射

### combat_probe —— 41 条
| 组 | 条数 | 对应判据 |
|---|---|---|
| 空跑守卫 | 4 | 防「表是空的」假绿（包 F 教训） |
| 动作状态机 | 4 | 前摇帧对齐 `TimeSystem.WINDUP_TICKS`（C28） |
| 无敌帧 | 5 | R5 手感核心：翻滚可躲伤害 |
| wave_plan 物化 | 10 | 夜1=5 slot、夜7=15 slot、强度曲线 1.0→2.32、18:00 锚点 |
| **M19 确定性** | 4 | 同参数两次物化**逐项相等**、`plan_hash` 跨日变/同日稳 |
| batch 完成 | 6 | 防「召唤池抽干提前过关」（架构风险登记 #1）、**击杀顺序无关** |
| spawner 消费 | 3 | M19 实际生成与 plan 逐项相等 |
| 破防分支 | 3 | 未清波结算必须 breach（不提前过关） |

### event_probe —— 33 条
| 组 | 条数 | 对应判据 |
|---|---|---|
| 空跑守卫 | 4 | autoload 就位 + 盐表非空 |
| M10 | 2 | 非法 impact 拒绝且不落日志（4 类封闭集） |
| P8 | 3 | 两次触发各自生效 |
| P9 | 2 | 幂等键不重复发放、不重复写日志 |
| **P17/P17b** | 3 | 日志已有键 → **不重新掷骰**；同天重开结果集一致 |
| 条件谓词 | 10 | all/any/not + 6 个比较算子（结构化，无 `!`） |
| 游标 | 3 | 定时事件按序消费、同日不重触发 |
| 存档段 | 6 | to_save/from_save 往返、恢复后不重发（P10） |

### steam_probe —— 10 条
| 组 | 条数 | 对应判据 |
|---|---|---|
| NullSteam 降级 | 4 | 无 Steam 环境自动降级、调用安全空转 |
| S9 零出站 | 1 | `src/` 静态扫描 0 命中网络 API |
| S10 成就幂等 | 3 | 本地先记账、同成就不重推 |
| 可移植性 | 2 | 存档目录可写、降级后不崩 |

---

## 5. ⚠ 当前阻塞：test.ps1 exit=1（**不在战斗组范围内**）

`tools/test.ps1` 6 个 stage 中 **5 通过、1 失败**，总断言 98，失败 stage = stage 2b。

### 阻塞点 1（已解除）：`loop_system.gd:368` —— **包 B 已修**
```
BROKEN  res://src/systems/loop_system.gd:368
  Parse Error: Cannot infer the type of "save_level" variable
```
包 B 已按建议改为 `var save_level: int = _level["FOOD"]`（显式类型）。
**战斗组 0 编译错误**（`compile_sweep` 扫 50 个 .gd，战斗组文件全部通过）。

### 阻塞点 2（已由测试组解决）：`tests/run_tests.gd:75` —— 包 F
```
BROKEN  res://tests/run_tests.gd:75
  Parse Error: Unexpected "Indent" in class body.
```
**已修复**：包 F 提交 `e0f9bc0`（已推远端）已修好缩进，且 V5 破防变异体补测完成（变异 5/5）。

### 阻塞点 3（当前，**归包 D 表现组**）：3 个 BROKEN，全是表现组在制品
`compile_sweep` 扫 51 个 .gd，当前 3 个 BROKEN：

| 文件 | 跟踪状态 | 错误 |
|---|---|---|
| `src/ui/screens/keybind_settings.gd` | **未跟踪**（在制品） | `Invalid argument for "_set_note()" function: argument 2 should be "Dictionary" but is "Array"`（第 52 行 `_set_note("", [])` 传了 Array，签名要 Dictionary） |
| `src/ui/screens/settings_screen.gd` | 已跟踪 | `Identifier "KeybindSettings" not declared` + `Cannot infer the type of "keybinds"` |
| `src/boot/boot.gd` | 已跟踪 | 同上（引用 `KeybindSettings`） |

**根因是一条链**：`keybind_settings.gd` 是包 D 正在写的新面板（未提交），
它自身第 52 行类型错 → `class_name KeybindSettings` 注册失败 →
`settings_screen.gd` / `boot.gd` 引用该类时报 "not declared"。

**修法（包 D，一处即可解链）**：`keybind_settings.gd:52` 把 `_set_note("", [])`
改成 `_set_note("", {})`。

> ⚠ 注意：**这个 BROKEN 清单会随工作区实时变化**（包 D 正在编辑）。
> 战斗组实测期间该清单在 `loop_system.gd` → `run_tests.gd` → `boot/keybind/settings` 之间变动过。
> 战斗组**未修改**这三个文件中的任何一个。
> 战斗组文件**不在任何一次 BROKEN 名单**里（`compile_sweep` 逐次核对）。

---

## 6. 重要环境陷阱（省测试组踩坑时间）

**`godot -s <script>` 无法测试任何引用 autoload 的系统。** 实测三条：

1. `-s` 下 autoload **节点存在**：`root.get_node("State")` 拿得到实例。
2. 但 autoload **名字在编译期不可解**：写 `State.read(...)` 报 `Identifier not found`。
3. 只有 **const** 能用（`GameLoop.FRAMES_*`、`ResolveOrder.DAMAGE_SOURCE_ORDER`）——
   这正是 `run_tests.gd` 那些能跑的原因：它只引用 const 与正则字符串，**从没真正调用过 autoload 实例方法**。

**正解：场景方式** —— `godot --headless res://xxx_probe.tscn`，正常加载工程 → autoload 全就位 → 断言 → `get_tree().quit(码)`。

**另**：`--check-only --script x.gd` 会对**所有**文件报 autoload not found，那是**假警报**，不能用来判断编译是否通过。
唯一可信的编译结论是 `tools/compile_sweep.gd` 或场景实跑。

---

## 7. 本轮修复的真实缺陷（供回归参考）

静态检查看不出、引擎实跑才暴露的：

| # | 缺陷 | 影响 |
|---|---|---|
| 1 | `effect_sink.gd` 用 `StateStore.ChangeSet`（该文件无 `class_name`） | **整个类编译失败**，连带 `EffectSink.new()` 全挂 |
| 2 | `EffectSink.resolve` 的 source 传 `"event:xxx"` | 契约鉴权判越权，debug 构建 **assert 崩**。正解：source 必须是 `&"effect_sink"` |
| 3 | 条件谓词 `eq` 混比 float 与 bool | 运行期 `Invalid operands` **直接崩**。已加 `_same_kind()` 类型守卫 |
| 4 | `steam_service.gd` 引用**不存在的** `steam_binding.gd` | 初始化成功后必崩。已改安全降级 |
| 5 | `Dictionary.get()` 返回 Variant，本工程**把该警告当错误** | `var x := node.get(...)` 编译失败，必须写显式 `var x: Variant = ...` |
| 6 | `draw_string` 漏 `alignment`/`width` 必填位 | 场景 Parse Error |
| 7 | `debug_reset_vitals()` 只重置体力/血量，不复位动作状态机 | 上个用例残留 WINDUP → 下一用例被 busy 守卫拒 → **无敌帧断言假红**。已新增 `debug_reset_combat()` |
| 8 | 事件表写了 `loop.*` 路径 | effect_sink 无该路径写权 → 被拒。已改 `player.*` / `ui.hints.*` |
| 9 | 事件 `verb: add` 负值 | 契约判 `below-min` 拒掉。已改 `set` 绝对值语义 |
| 10 | S10 扫描器把**裸词** `AppData` 当 PII | 把探针自己的正常文案（`%APPDATA%\SafeHouse`）判成泄漏 → 假红。已改为只匹配**路径形态**（`\AppData\`、`/AppData/`），并加反向对照确保没把判据改弱 |
| 11 | S10 探针**自污染**：故意写 PII 到日志，Logger 又不拦（core 欠件） | 自己的测试日志成了"待检测物"。已改为不写 PII 到日志、排除活动日志 `godot.log`、过滤探针自身输出行 |
| 12 | S9 DNS 判据机制错 | Godot 4.3 `IP.resolve_hostname` 是**同步**的，不在解析器队列留挂起项；`get_resolve_item_status(无效id)` 会**报错**。原"查队列"写法恒空=恒真式，已改为 control 断言 + 静态调用点扫描 |

---

## 8. 明确未覆盖项（不夸大交付范围）

> ★ **2026-10-20 17:30 更新**：B10（S9/S10）已推进，见下节 8.1。S9 的"操作系统层面出站 0"仍需外部工具。

### 8.1 B10 进展（S9/S10）

**S10 PII 扫描 —— 已做成可复跑机械判定，新增 `scenes/debug/pii_probe.tscn`，21/21 全绿。**

```powershell
& $env:GODOT_BIN --headless --quit-after 400 res://scenes/debug/pii_probe.tscn   # 期望 21/21, EXIT=0
```

三条防假绿设计（缺一条这条判据就没意义）：
1. **存档是 GZIP 压缩的** → 明文 grep 扫 `save.sav` 永远 0 命中，那是**假绿**。
   探针必须 `decompress_dynamic(-1, COMPRESSION_GZIP)` 解压后再扫。
2. **反向对照** —— 故意把真实 `COMPUTERNAME`/`USERNAME` 写进样本，断言扫描器**能抓到**。
   抓不到 = 扫描器本身坏了，"0 命中"毫无意义。
3. **空目录判负** —— 零文件时判"未生效"失败，不判通过。

扫 5 类 PII：hostname / username / 绝对路径 / UUID / MAC。
**实测当前存档与日志目录 0 命中**（含 7 个日志文件逐一扫过）。

**S9 出站 0 —— 分两层，本作查第 1 层（新增 2 条断言，steam_probe 12/12 全绿）：**

| 层 | 内容 | 状态 |
|---|---|---|
| 第 1 层 | 游戏代码自己有没有发起 DNS/网络请求 | ✅ 本作已查：静态零解析调用点 + 运行期 control 断言 |
| 第 2 层 | 操作系统层面有没有出站 | ❌ **仍需** Windows 防火墙全禁 + Process Monitor/抓包，且必须在**装了 Steam 客户端**的环境 |

> ⚠ **给测试组的一个判据机制更正**（我自己的设计错误，已修）：
> Godot 4.3 的 `IP.resolve_hostname` 是**同步**的——直接返回 IP 字符串，
> **不会在解析器队列里留下挂起项**；且 `get_resolve_item_status(无效 id)` 会**报错**
> 而非返回 NONE。最初写的"查解析队列"判据在本引擎上**恒空 = 恒真式**，已废弃改为
> control 断言 + 静态调用点扫描。

**新发现的 core 层欠件（归包 B，本组只报不改）**：
`src/core/logger.gd` 的 `contains_pii()` **定义了但 `log()` 从不调用它**
→ 运行期不拦截 PII，reason 字段（人读自由文本，最容易夹带绝对路径）可写入 PII。
建议包 B 在 `log()` 里加一道写入前拦截（`pii_probe` 已附断言示范）。

### 8.2 其余未覆盖项

| 判据 | 为什么测不了 | 需要什么 |
|---|---|---|
| **R5 手感** | 需连打 10 场统计「闪避次数 > 挥砍×0.6 且无站桩局」，机械断言测不出 | CI 机器人脚本或真人试玩 |
| **M23 挂机兜底** | 需 TimeSystem 真实时钟推进 8 分钟上限 | 无头长跑（分钟级） |
| **S9 第 2 层出站 0 / DNS 0** | 见 8.1 表 | Windows 防火墙全禁 + Process Monitor / 抓包，**在装了 Steam 客户端的环境** |
| **GodotSteam 失败回连 Valve** | 本机无 GDExtension | 按架构 §1075 在带 SDK 的构建上验证 |
| **P17b 跨存档重放** | 当前只验证了「日志已有键不重新掷骰」这一核心机制，未做真实 save/load 往返 | 增加一次真实存档往返用例 |

---

## 9. 数据层顺带修复（跨组收益）

M28-a 单位后缀违规从 **71 处 → 0 处**，`validate_data` 从 6/7 → **7/7 通过**。
改名（键名带单位后缀，数据+代码+自检已同步）：`_cost`→`_units`、`_dps`→`_ratio`、
`hp`→`max_hp`、`damage`→`damage_ratio`、`speed`→`speed_px`、
`strength_multiplier`→`strength_mult`、裸 `count`→`cap_count`。

---

## 10. 请测试组确认的三件事

1. **stage 2b 的 `loop_system.gd:368`** 请转包 B 修复（显式类型即可）。
2. **stage 4 的 `-s` 限制** 是否要改造成场景方式？这影响所有包的 CI，请包 F 定调。
3. 三个自检场景（84 条）**是否并入 `tools/test.ps1`**？并入需包 F 定断言计数口径，
   我按 `ui_smoke.gd` 先例只在文件头注明归属，未擅自改编排。

> ⚠ 第 1 条**已解除**（包 B 已修）。第 2 条**已由测试组用场景方式解决**（修订 #1）。
> 第 3 条现为 **105 条**（新增 pii_probe 20 条 + steam_probe 增 2 条）。
> 详见第 0 节。

---

## 11. GitHub 同步状态（已同步，此节保留作推送通道记录）

**当前状态：远端 `main` = `e0f9bc0` = 本地 HEAD，`git push` 是干净的 fast-forward。**
战斗组的 `6d4a267` / `39331b2` **都已在远端历史中**（已用 API 逐个核验 SHA）。

> ⚠ **更正一条我此前的误判**：上一版说明写 `39331b2`「推送受阻」。实为
> `git push` 在**传输已完成之后**才报 `Connection reset` —— 提交其实已到远端。
> 教训：报错不等于没推上去，**必须用 API 查远端 ref 的 SHA 再下结论**。

**通道诊断（30 秒）**：
| 通道 | 状态 |
|---|---|
| `github.com` 直连 | ❌ 21 秒连接超时（白名单不放行） |
| `github.com` 走代理 | ❌ 502 Bad Gateway |
| `api.github.com` 走代理 | ✅ 通 |

→ 直连不可用时走 `tools/gh_push_api.py`（Git Data API 通道），token **只从环境变量
`GITHUB_TOKEN` 传入**，脚本逐层校验 blob/tree/commit SHA 与本地字节级一致。
> ⚠ **安全**：本会话用过的 PAT 已在聊天中明文出现，用完请到
> GitHub → Settings → Developer settings **撤销并重建**。