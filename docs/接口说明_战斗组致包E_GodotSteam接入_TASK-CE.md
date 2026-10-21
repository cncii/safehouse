# 接口说明 · 战斗组 → 包 E：GodotSteam 接入与架构 1075 条的实测结论

**提交人**：战斗组（包 C+E）｜**日期**：2026-10-21
**收件**：包 E（存档与平台组）
**背景**：架构 §6.1 第 529 行把「SDK 初始化」列为 ✅ 必须项；
架构 1075 / 1012 条把「GodotSteam 配 `embed_pck` 后热重载能否回连」列为**唯一待验证项**。

---

## 一、结论先写：架构 1075 条**已验证通过**

原文：「GodotSteam 配 `embed_pck` 后热重载能否回连 → **失败必须走 `NullSteam` 降级**」
以及 1012 条：「启动期崩溃 → **回连失败必须走 `NullSteam` 降级并记日志**」

实测（2026-10-21，本机 Steam 客户端已登录）：

| 情形 | `steamInitEx()` 结果 | 进程对外连接 | DNS 查询 | 降级链 |
|---|---|---|---|---|
| A 无 `steam_appid.txt` | **失败**：`"No appID found. Either launch the game from Steam, or put the file steam_appid.txt..."` | **0** | **0** | ✅ 9 条判据全绿 |
| B 有 `steam_appid.txt`（Spacewar 480） | **成功**（`status=0`） | **0** | **0** | — |

**回答了那个待验证项：GodotSteam 初始化失败时**不会**回连 Valve**（零出站、零 DNS），
且**失败后走 NullSteam 降级并记日志**（架构 1012 条的四段链已做成 9 条可复跑判据）。

→ **S9 的零出站硬约束在 GodotSteam 路径上成立**，不需要"防火墙全禁"来兜底。
→ 架构 §6.2 说的「返回非 OK 走 `NullSteam` 降级」**已由代码实现且已由判据守护**。

复跑命令：
```powershell
powershell -ExecutionPolicy Bypass -File tools\s9_gsteam_probe.ps1
# 期望：两个 case 的 outbound=0 / dns=0
```

---

## 二、包 E 还需要做的一件事：`src/platform/steam_binding.gd`

**现状**：文件**不存在**。`steam_service.gd` 的逻辑是：
```gdscript
if _try_init_godotsteam():              # ClassDB 有 "Steam" 类 → true
    var b := load(BINDING_PATH)          # → 加载失败
    if b != null: ... else:
        _degrade("binding_script_missing")   # → 降级 + 记日志 ✅
```
所以**现在跑起来是正确的**（降级路径工作正常，21/21 判据全绿）。
但**一旦包 E 补上 binding，GodotSteam 就会真正接管**——那时才需要：

1. `steam_binding.gd` 实现 `backend_id()` / `set_achievement()` / `set_rich_presence()`，
   对接 GodotSteam 的 `Steam.setAchievement()` / `Steam.storeStats()` / Rich Presence。
2. **GodotSteam 的 `Steam` 单例是全局的**，`steam_service` 通过 `ClassDB.instantiate("Steam")`
   拿实例——实测可用（`getSteamID` / `getPersonaName` / `isAnonAccount` 等方法齐全）。
3. 补上后，`steam_probe` 的 **1012(3b) 判据（`backend_id == "null"`）会变红**——
   这是**预期的**：那时后端不再是 null，判据应改成"有 Steam 时 backend_id == 'steam'"。
   **请包 E 补 binding 时同步改这条判据**（或让判据按"后端类型"分支断言）。

> ⚠ 实测细节：`Steam.steamInitEx()` 是**静态方法、0 参数**，返回 Dictionary
> `{"status": int, "verbal": String}`。`getSteamID()` 等是**实例方法**，
> 且未成功初始化时会报 `[STEAM] User class not found`（不崩，返回 0）。
> `getSteamID32()` / `isAnonAccount()` 需要**参数**（编译期就会报参数不足）。

---

## 三、已入库的 SDK（请包 E 复核）

`addons/godotsteam/` 已放进工程，**只保留 win64**（首发平台，架构 §6.2「Windows Desktop x86_64」）：

| 项 | 值 |
|---|---|
| 版本 | **GodotSteam 4.15-gde**（对应 Godot 4.1–4.3，本工程 4.3 ✅） |
| 兼容声明 | `compatibility_minimum = "4.1"`（实测 Godot 4.3 正常加载） |
| 许可 | **MIT**（`addons/godotsteam/license.txt`，GodotSteam 本体） |
| 内含 | `win64/steam_api64.dll`（Steamworks SDK，Valve 分发条款，随 GodotSteam 官方包提供） |
| 体积 | **5.7 MB**（完整包 37 MB，其余 4 个平台已移除） |

**其余平台（win32 / linux32 / linux64 / osx）没入库**——需要时从官方源取回：
```
https://codeberg.org/godotsteam/godotsteam/releases/download/v4.15-gde/godotsteam-4.15-gdextension-plugin-4.1-4.3.zip
```
> ⚠ 本机网络：`github.com` 的 release 下载被墙（exit 52/56），
> **Codeberg 走代理可通**（实测 11.5 MB 下载成功）。`api.github.com` 也通。

**版本锁定**：已按架构 529 行要求写进 `docs/architecture.md` 的「Steam 平台」段。

---

## 四、给包 E 的三个提醒

1. **S9 零出站**：`steam_service._try_init_godotsteam()` 只查 `ClassDB.class_exists("Steam")`，
   **不发任何网络请求**——连"探测 SDK"都不许连网。补 binding 时**别**在探测阶段发请求。
2. **Steam 未登录时也必须能玩**：`steamInitEx()` 返回 "No appID found" 是**正常路径**，
   走 NullSteam 降级，不是错误。判据已按"降级发生且记日志且仍可玩"来判。
3. **`embed_pck` 场景还没测**：架构 1075 条的完整语境是「配 `embed_pck` 后**热重载**能否回连」。
   本轮测的是**编辑器/无头运行**路径。**导出包 + `embed_pck` + 热重载**那条需要
   包 E 导出后实测——`tools/s9_gsteam_probe.ps1` 可直接复用于导出包（改 Godot 路径为 exe 即可）。

---

## 五、战斗组这边的边界

- `addons/` 是**第三方 SDK**（包 E 领域），战斗组只做了「下载 → 验证兼容性 → 实测出站行为」，
  **未改任何 `src/platform/` 下的包 E 代码**。
- `tools/s9_gsteam_probe.ps1` + `tools/s9_gsteam_report.json` 是战斗组自建的检测工具（战斗组名下）。
- `scenes/debug/steam_probe.gd` 的 1012 条降级链判据是战斗组自检（战斗组名下）。
- **架构 1075 条的结论已落在交付说明 8.3 / 8.4 节**（战斗组交付说明）。
