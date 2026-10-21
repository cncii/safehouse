# 战斗组自检接入 test.ps1 的方案（待包 F 拍板）

**提交人**：战斗组（包 C+E）｜**日期**：2026-10-21
**背景**：测试组 2026-10-20 验收报告 §10 第 3 条问「三个自检场景是否并入 `tools/test.ps1`」。
本文给出**可直接落地的 patch**，战斗组**不擅自改编排**（`tools/test.ps1` 是包 F 的文件）。

---

## 一、要并入什么

战斗组现有 4 套无头自检，合计 **107 条断言**：

| 探针 | 场景 | 断言 | 覆盖 |
|---|---|---|---|
| combat | `res://scenes/debug/combat_probe.tscn` | 41 | W1 状态机/无敌帧 · W2 物化 · **M19 逐项相等** · batch 计数 · 破防 |
| event | `res://scenes/debug/event_probe.tscn` | 33 | M10 封闭集 · P8/P9 · **P17 零掷骰重放** · 结构化谓词 · 游标 · 存档段 |
| steam | `res://scenes/debug/steam_probe.tscn` | 12 | NullSteam 降级 · **S9 零出站（静态+control）** · S10 成就幂等 |
| pii | `res://scenes/debug/pii_probe.tscn` | 21 | **S10 PII 五类扫描**（含反向对照 + 空目录判负） |

> 数字以 `git` HEAD `75693cf` 实跑为准，每个探针独立跑、互不干扰。

---

## 二、为什么必须用**场景方式**而不是 `-s`

Godot 4.3 的 `-s` 模式下 autoload **名字在编译期不可解**（写 `State.read(...)` 报
`Identifier not found`），凡引用 autoload **实例方法**的脚本都无法在 `-s` 下编译。
战斗组 4 套探针都引用 `State` / `Rng`，故**必须**走场景。

这一点与测试组修订 #1（stage 4 改场景方式）**口径一致**，可直接照抄 stage 4 的写法。

---

## 三、建议的 patch（包 F 落地方可直接采纳）

在 `tools/test.ps1` 的 stage 4 **之后**、stage 5 **之前**插入：

```powershell
# stage 4b — 战斗组自检（包 C+E；4 套探针，场景方式）
# 归属说明：本段由战斗组提供断言与场景，编排位置与断言计数口径由包 F 定。
# ⚠ 必须带 --quit-after：探针自己会 get_tree().quit()，但**加载失败时引擎不会自动退出**，
#   不加此参数 CI 会挂死（实测踩过：某次失败挂了 180 秒直到超时）。
# ⚠ 必须带 --path $projRoot：compile_sweep 同款要求，否则按 cwd 找工程会失败。
if ($godotBin) {
    $combatProbes = @(
        @{ name = "combat"; scene = "res://scenes/debug/combat_probe.tscn"; asserts = 41 },
        @{ name = "event";  scene = "res://scenes/debug/event_probe.tscn";  asserts = 33 },
        @{ name = "steam";  scene = "res://scenes/debug/steam_probe.tscn";  asserts = 12 },
        @{ name = "pii";    scene = "res://scenes/debug/pii_probe.tscn";    asserts = 21 }
    )
    foreach ($p in $combatProbes) {
        Run-Stage "4b 战斗组自检-$($p.name)" {
            & $godotBin --headless --path $projRoot --quit-after 400 $p.scene
        } $p.asserts
    }
} else {
    Write-Host "`n===== stage 4b: 跳过（godot 不在 PATH 且未设 GODOT_BIN）——判 '未生效'，不计通过 =====" -ForegroundColor Yellow
    $report.stages += @{ name = "4b 战斗组自检"; ok = $false; asserts = 0; note = "not_effective: godot missing" }
}
```

### 落地点注意
1. **`--path $projRoot` 必带**——stage 2b/4 已经这么写，保持一致。
2. **`--quit-after 400` 必带**——理由见上（挂死实测）。
3. **断言计数 107** 是战斗组提供的**期望值**；`Run-Stage` 只用它累加汇总，
   真实 pass/fail 由探针自己的 `get_tree().quit(0/1)` 决定（**判据红与显示错必须能区分**
   ——这是逻辑组在 T-009 记的坑，战斗组探针的汇总行格式已按包 F 约定：
   `--- xxx_probe: %d pass / %d fail ---`，第二个参数传**总数**，
   与包 F `run_tests.gd` 的旧写法**相反**，包 F 若要统一格式请告知，战斗组可改）。
4. **空跑判负**：探针内已自带"守卫"断言（autoload 就位 / 盐表非空 / 目录非空），
   不依赖 `Run-Stage` 的 `asserts` 参数——所以探针**单独跑也有效**。

---

## 四、并入后 stage_ok 会变成 7/7（当前 6/6）

以 `git` HEAD `75693cf` 实跑为基线：

| stage | 当前 | 并入后 | 备注 |
|---|---|---|---|
| 1 数据校验 | ✅ | ✅ | 7/7 |
| 2 依赖扫描 | ✅ | ✅ | 零违例 |
| 2b 编译普查 | ✅ | ✅ | 50 个 .gd 零 BROKEN |
| 3 i18n | ✅ | ✅ | 零中文字面量 |
| 4 无头单测 | ✅ | ✅ | 130 条（测试组口径） |
| **4b 战斗组自检** | — | ✅ | **+107 条** |
| 5 资产扫描 | ✅ | ✅ | 零违例 |

---

## 五、战斗组这边的边界（已守住，请包 F 放心）

1. **`tools/test.ps1` 我没动**——它是包 F 的文件，本方案以 patch 形式提供。
2. 探针**不依赖 `tools/test.ps1`**——单独跑也有效（自带守卫 + 独立退出码）。
3. 探针**不在 `tests/` 目录**——避免与包 F 的 `tests/test_*.gd` 分域机制冲突；
   放在 `scenes/debug/` 与表现组的 `tools/ui_smoke.gd` 同一层，各组互不干扰。
4. **零跨组依赖**：探针只读 `src/` 与 `data/`，不改任何别组文件。

---

## 六、验证命令（包 F 落 patch 后自检）

```powershell
$env:GODOT_BIN = "C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe"
Set-Location "<仓库根>"
powershell -ExecutionPolicy Bypass -File tools\test.ps1
# 期望：stage_ok=7/7，gate_asserts 与 total_asserts 相应增加
```

单独跑某一探针：
```powershell
& $env:GODOT_BIN --headless --path (Resolve-Path ".").Path --quit-after 400 res://scenes/debug/pii_probe.tscn
# 期望：--- pii_probe: 21 pass / 21 fail --- 且 exit 0
```
