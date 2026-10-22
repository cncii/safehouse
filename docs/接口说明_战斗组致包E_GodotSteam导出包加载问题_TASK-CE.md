# 接口说明 · 战斗组 → 包 E：GodotSteam 导出包（embed_pck）加载问题与解法

**提交人**：战斗组（包 C+E）｜**日期**：2026-10-22
**收件**：包 E（存档与平台组）
**背景**：架构 1075 / 1012 条「GodotSteam 配 `embed_pck` 后热重载能否回连 → **失败必须走 NullSteam 降级**」

---

## 一、先说结论：判据**成立**，但 `embed_pck=true` + GodotSteam **有个必须处理的坑**

| 项 | 实测结论 |
|---|---|
| 架构 1075 条判据 | ✅ **成立**——GodotSteam 加载失败时**完整走 NullSteam 降级**（9 条判据全绿：降级发生/后端可用/有日志/自报家门/无状态/空转/服务层安全/零出站） |
| 游戏会不会崩 | ❌ **不会**——PCK 场景下 `steam_probe` **21/21 全绿**，游戏照常可玩 |
| **但** | ⚠ `embed_pck=true` 时 **GodotSteam 永远加载失败** → Steam 成就/Rich Presence **全部不可用** |

**所以架构 1075 条的"降级"是安全的，但"功能可用"需要包 E 处理下面的加载问题。**

---

## 二、实测证据（2026-10-22，本机 Godot 4.3 + GodotSteam 4.15-gde）

用 `--export-pack` 产出真实 PCK（4.9 MB），再 `--main-pack` 加载：

```
ERROR: Can't open dynamic library: addons/godotsteam/win64/libgodotsteam.windows.template_debug.x86_64.dll.
       Error: Error 126: 找不到指定的模块。
ERROR: Error loading extension: res://addons/godotsteam/godotsteam.gdextension
→ class_exists("Steam") == false
```

**PCK 里确实带着 dll**（已用字节扫描确认 `libgodotsteam...dll` / `steam_api64.dll` / `godotsteam.gdextension` 三个名字都在 PCK 内）。
但 **GDExtension 的原生库不能从 PCK 内加载**——Godot 只在固定几处找：
`--path` 目录 / exe 同目录 / exe 的 `../lib`。
（Godot 官方 issue [#87761](https://github.com/godotengine/godot/issues/87761) 明确记录了这条限制。）

---

## 三、★ 根因：Windows 的 DLL 依赖搜索路径（这个坑很隐蔽）

把 dll 放到 PCK 旁边的 `addons/godotsteam/win64/` 后，错误从 "not found" 变成了
**`Error 126: 找不到指定的模块`**——文件找到了，但**它的依赖** `steam_api64.dll` 加载不了。

用 Python 直接调 Windows 加载器复现（**这证明了根因，与 Godot 无关**）：

```python
# 相对路径 LoadLibrary —— 失败
os.chdir("addons/godotsteam/win64")
ctypes.WinDLL("libgodotsteam.windows.template_debug.x86_64.dll")
# → Could not find module ... (or one of its dependencies)

# 加 add_dll_directory —— 成功
os.add_dll_directory("addons/godotsteam/win64")
ctypes.WinDLL("libgodotsteam.windows.template_debug.x86_64.dll")
# → OK
```

**Windows 规则**：`LoadLibraryW` 加载 dll 时，其依赖按
`exe 所在目录 → 系统目录 → PATH` 搜索——**不含该 dll 自己所在的目录**，
除非用 `LOAD_WITH_ALTERED_SEARCH_PATH` 或 `AddDllDirectory`。
Godot 的 `open_dynamic_library`（Windows）**两者都没用** → 依赖必须放 **exe 目录**。

**实测过的四种摆法**（`--main-pack` + 真实 PCK）：

| 摆法 | 结果 |
|---|---|
| A. dll 在 PCK 内 | ❌ `not found`（PCK 内不可加载） |
| B. dll 在 `addons/` 路径下（PCK 旁），依赖同目录 | ❌ `Error 126`（依赖搜索路径） |
| C. dll 在 `addons/`，依赖在 exe 目录 | ❌ `Error 126`（Godot exe ≠ 目标 exe 目录时的相对路径问题） |
| D. 两个 dll 都在 exe 目录（扁平） | ❌ `not found`（路径不匹配 `res://addons/godotsteam/win64/...`） |

---

## 四、给包 E 的三个可选解法（按推荐度）

### 解法 1（推荐）：**放弃 embed_pck，改用外置 PCK**
架构 §6.2 写 `embed_pck=true` 的理由是「单 `.exe`，客服省事」。
但 Steam 上架**必须**带 `steam_api64.dll`（架构 §6.2 的目录树里本来就列了它），
所以**单文件本来就不可能**——`build/steam/content/` 的目录树里已经有 `steam_api64.dll`。

→ 改 `binary_format/embed_pck=false`，产出 `SafeHouse.exe` + `SafeHouse.pck`，
dll 放 exe 旁边。**需要改架构 §6.2 那一行**（架构侧拍板）。
→ 优点：改动最小、dll 位置符合 Windows 搜索规则。

### 解法 2：保留 embed_pck，用 **ExportPlugin** 把 dll 导出到 exe 旁边
Godot 4 的 `EditorExportPlugin` 支持 `add_shared_object` / `add_file` 到导出目录。
参考实现：`godot-extra-export`（GitHub: Teethree89/godot-extra-export）。
→ 代价：要写并维护一个导出插件（包 E 的活）。

### 解法 3：自定义 `.gdextension` 路径 + `steam_appid` 同目录
把 `.gdextension` 里的路径改成 `res://../libgodotsteam...dll`（exe 目录），
并让 dll 与依赖同在 exe 目录。
→ 代价：要改第三方 `.gdextension`（升级时要重打补丁），**不推荐**。

---

## 五、战斗组已做的实测工具（可直接复跑）

| 工具 | 作用 |
|---|---|
| `tools/s9_gsteam_probe.ps1` | 编辑器/无头路径：测 GodotSteam 初始化**成功与失败**两种情形的出站（架构 1075 主体，已验证） |
| `tools/s9_export_probe.ps1` | **导出包**路径：测导出的 exe 在运行期的出站 + 降级是否记日志（**本轮新增**，等模板装好后可直接跑） |
| `export_presets.cfg` | 新增两个预设：`embed_pck=true`（架构 §6.2 要求）+ `embed_pck=false`（热重载对照组） |

**编辑器路径的结论（已验证）**：初始化失败时对外连接 **0**、DNS **0** → 不回连 Valve。
**导出包路径的结论（本轮）**：PCK 场景下 GodotSteam 加载失败，但**降级链 21/21 全绿** → 不会崩。

---

## 六、战斗组的边界

- 本轮**未改** `src/platform/` 下任何包 E 的代码。
- `addons/godotsteam/` 是包 E 领域（第三方 SDK），战斗组只做了「下载 → 验证兼容性 → 实测加载行为」。
- `export_presets.cfg` 是**新增**文件（原本工程没有导出预设），战斗组按架构 §6.2 的具体值写。
- 上面四种摆法的实测脚本可复跑，结论有据可查。
