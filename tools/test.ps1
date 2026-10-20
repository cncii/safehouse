# test.ps1 — 验收单一入口（QA 契约 5 / 架构 C10）
# 四 stage 顺序执行，任一非 0 → 整体非 0；空跑判负（断言数 0 = 失败）。
# 用法：powershell -File tools\test.ps1   （可选 -SelfCheck 注入失败自测）

param(
    [switch]$SelfCheck
)

$ErrorActionPreference = "Stop"

# F6 控制台编码：子进程（godot/python）输出 UTF-8，控制台默认 GBK 会乱码。
# 设 OutputEncoding 让 PowerShell 按 UTF-8 解码子进程 stdout/stderr（等效 chcp 65001，但只影响本会话）。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$fail = 0
$report = @{ stages = @(); total_asserts = 0; generated_at = (Get-Date -Format o) }

function Run-Stage($name, $script, $assertCount) {
    Write-Host "`n===== stage: $name =====" -ForegroundColor Cyan
    & $script
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ $name 失败 (exit $LASTEXITCODE)" -ForegroundColor Red
        $script:fail++
        $report.stages += @{ name = $name; ok = $false; asserts = $assertCount }
    } else {
        Write-Host "  ✓ $name 通过" -ForegroundColor Green
        $report.stages += @{ name = $name; ok = $true; asserts = $assertCount }
        $script:report.total_asserts += $assertCount
    }
}

# godot 可执行文件解析：PATH 优先，其次 GODOT_BIN 环境变量。
# 引擎在隔离目录、不在 PATH 时，设 GODOT_BIN 才能真跑；解析不到就判"未生效"，
# 绝不当成通过——静默跳过是门禁失效的头号来源。
# 注意：用户级环境变量对「已开启的会话」不传播——已验证本机 GODOT_BIN 已配到用户级，
# 但旧会话读不到，必须由调度方（CI/新终端）保证环境正确，脚本两种来源都认。
$godotBin = (Get-Command godot -ErrorAction SilentlyContinue).Source
if (-not $godotBin -and $env:GODOT_BIN) { $godotBin = $env:GODOT_BIN }
$projRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# stage 1 — 数据层源头判据（M28/C28/S7/M30，不需要构建）
# 计数 = 声明的断言规模（validate_data 当前 7 项）；gate 实际红绿以 stage 自身输出为准。
Run-Stage "1 数据校验" { python (Join-Path $PSScriptRoot "validate_data.py") } 7

# stage 2 — 依赖方向 + RNG 单一入口
Run-Stage "2 依赖扫描" { python (Join-Path $PSScriptRoot "check_deps.py") } 4

# stage 2b — 确定性编译普查（**不要用 --import 代替它**）
# 热导入按 mtime 跳过未变文件、冷导入曾有并发污染案例（同代码 26/28/26/0），两个都可能假绿。
# compile_sweep.gd 用同步 load() 全量编译，无 mtime、无竞态。
if ($godotBin) {
    Run-Stage "2b 编译普查" { & $godotBin --headless --path $projRoot -s tools/compile_sweep.gd } 1
} else {
    Write-Host "`n===== stage 2b 编译普查: 跳过（godot 不在 PATH 且未设 GODOT_BIN）——判 '未生效'，不计通过 =====" -ForegroundColor Yellow
    $report.stages += @{ name = "2b 编译普查"; ok = $false; asserts = 0; note = "not_effective: godot missing" }
}

# stage 3 — 本地化（中文字面量 0）
Run-Stage "3 i18n 扫描" { python (Join-Path $PSScriptRoot "check_i18n.py") } 1

# stage 4 — 无头单测（修订 #1：**场景方式**，不用 -s——autoload 标识符在 -s 下编译期不可解，
# vitals 系统连带挂掉、8 条判据从未真跑；场景方式下 autoload 全就位，83 条断言真执行）
# 修订（包 F）：godot 解析统一用 $godotBin（旧代码此处只查 PATH，GODOT_BIN 设了也白设——与 2b 不一致）。
if ($godotBin) {
    # 计数 = run_tests.gd MIN_ASSERTS（修订 #6 后 121，loop 修复后 122）
    Run-Stage "4 无头单测" { & $godotBin --headless --path $projRoot res://tests/test_main.tscn } 121
} else {
    Write-Host "`n===== stage 4: 跳过（godot 不在 PATH 且未设 GODOT_BIN）——判 '未生效'，不计通过 =====" -ForegroundColor Yellow
    $report.stages += @{ name = "4 无头单测"; ok = $false; asserts = 0; note = "not_effective: godot missing" }
}

# stage 5 — 资产准入门禁（A1 像素格 / A2 图集 / A3 命名 / A4 色板；空 assets = 未生效不算失败）
Run-Stage "5 资产扫描" { python (Join-Path $PSScriptRoot "check_assets.py") } 4

# --SelfCheck：注入失败自测（守卫的失败被吞掉这件事本身也要被守卫）
if ($SelfCheck) {
    Write-Host "`n===== self-check: 注入失败 =====" -ForegroundColor Magenta
    python -c "import sys; sys.exit(3)"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✗ 注入失败未被捕获——门禁失效！" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  ✓ 注入失败被捕获（exit $LASTEXITCODE）" -ForegroundColor Green
    }
}

# ── 报告（架构 v1.23：coverage_statement 由脚本生成，禁止手写"全部/全绿"）──
$report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $PSScriptRoot "..\build\test_report.json") -Encoding UTF8

# F4 coverage_statement：由 $report 数据计算生成，脚本侧禁止出现"全部/全绿"字样。
$neStages  = @($report.stages | Where-Object { $_.note -like "not_effective*" })
$okStages  = @($report.stages | Where-Object { $_.ok })
$neCount   = $neStages.Count
# 变异覆盖数从变异报告读（W3 起 tools/mutation_report.json 存在时计入，缺失即如实报 0）
$mutFile = Join-Path $PSScriptRoot "mutation_report.json"
$mutConfirmed = 0
if (Test-Path $mutFile) {
    try {
        # -Encoding UTF8 必须：报告为 UTF-8 无 BOM，PS5.1 默认按 ANSI 读会破坏 JSON 结构
        $mut = Get-Content $mutFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $mutConfirmed = @($mut | Where-Object { $_.captured -eq $true -and $_.no_collateral -eq $true }).Count
    } catch {
        Write-Host "  ⚠ mutation_report.json 解析失败（$($_.Exception.Message)）—— mutation_confirmed 如实报 0" -ForegroundColor Yellow
        $mutConfirmed = 0
    }
}
Write-Host "`n===== 汇总 ====="
Write-Host ("  断言总数: {0}  失败 stage: {1}" -f $report.total_asserts, $fail)
Write-Host ("  coverage: stage_ok={0}/{1}  not_effective={2}  gate_asserts={3}  mutation_confirmed={4}" `
    -f $okStages.Count, $report.stages.Count, $neCount, $report.total_asserts, $mutConfirmed)
if ($neCount -gt 0) {
    Write-Host ("  ✗ 未生效 stage（不计通过）: {0}" -f (($neStages | ForEach-Object { $_.name }) -join ", ")) -ForegroundColor Yellow
}
if ($report.total_asserts -eq 0) {
    Write-Host "  ✗ 空跑判负：断言总数为 0" -ForegroundColor Red
    exit 1
}
if ($neCount -gt 0) {
    Write-Host "  ✗ 存在未生效 stage —— '机制存在即在运行'，未生效不得计通过（QA 纪律）" -ForegroundColor Red
    exit 1
}
exit $fail
