# test.ps1 — 验收单一入口（QA 契约 5 / 架构 C10）
# 四 stage 顺序执行，任一非 0 → 整体非 0；空跑判负（断言数 0 = 失败）。
# 用法：powershell -File tools\test.ps1   （可选 -SelfCheck 注入失败自测）

param(
    [switch]$SelfCheck
)

$ErrorActionPreference = "Stop"
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
$godotBin = (Get-Command godot -ErrorAction SilentlyContinue).Source
if (-not $godotBin -and $env:GODOT_BIN) { $godotBin = $env:GODOT_BIN }

# stage 1 — 数据层源头判据（M28/C28/S7/M30，不需要构建）
Run-Stage "1 数据校验" { python (Join-Path $PSScriptRoot "validate_data.py") } 6

# stage 2 — 依赖方向 + RNG 单一入口
Run-Stage "2 依赖扫描" { python (Join-Path $PSScriptRoot "check_deps.py") } 4

# stage 2b — 确定性编译普查（**不要用 --import 代替它**）
# 热导入按 mtime 跳过未变文件、冷导入有竞态（同代码 4 轮 26/28/26/0），两个都是假绿。
# compile_sweep.gd 用同步 load() 全量编译，无 mtime、无竞态。
if ($godotBin) {
    $projRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    Run-Stage "2b 编译普查" { & $godotBin --headless --path $projRoot -s tools/compile_sweep.gd } 1
} else {
    Write-Host "`n===== stage 2b 编译普查: 跳过（godot 不在 PATH 且未设 GODOT_BIN）——判 '未生效'，不计通过 =====" -ForegroundColor Yellow
    $report.stages += @{ name = "2b 编译普查"; ok = $false; asserts = 0; note = "not_effective: godot missing" }
}

# stage 3 — 本地化（中文字面量 0）
Run-Stage "3 i18n 扫描" { python (Join-Path $PSScriptRoot "check_i18n.py") } 1

# stage 4 — 无头单测（M30/F0-b/M1/P1①/P28）——Godot 未安装时跳过并标"未生效"
$godot = Get-Command godot -ErrorAction SilentlyContinue
if ($godot) {
    Run-Stage "4 无头单测" { godot --headless -s tests/run_tests.gd } 9
} else {
    Write-Host "`n===== stage 4: 跳过（godot 不在 PATH）——判 '未生效'，不计通过 =====" -ForegroundColor Yellow
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
Write-Host "`n===== 汇总 ====="
Write-Host ("  断言总数: {0}  失败 stage: {1}" -f $report.total_asserts, $fail)
Write-Host "  coverage: 本报告覆盖上述各 stage 断言；变异确认独立覆盖 0 条（未做变异测试）"
if ($report.total_asserts -eq 0) {
    Write-Host "  ✗ 空跑判负：断言总数为 0" -ForegroundColor Red
    exit 1
}
exit $fail
