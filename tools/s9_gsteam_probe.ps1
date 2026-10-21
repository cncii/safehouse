# s9_gsteam_probe.ps1 — 架构 1075 条「GodotSteam 失败是否回连 Valve」的进程级出站检测
#
# 背景：架构 1075 / 1012 条把「GodotSteam 配 embed_pck 后热重载能否回连」列为唯一待验证项，
# 原文：「失败必须走 NullSteam 降级」。本脚本验证**失败时到底有没有出站**。
#
# 测法：跑一个只做「Steam.steamInitEx()」的最小 Godot 脚本，
#      在其运行期间采样进程级 TCP/UDP 连接表，
#      断言：Godot 进程在 GodotSteam 初始化失败时**没有任何对外连接**（期望 0）。
#
# 两种情形都要测：
#   A. 无 appID（steam_appid.txt 不存在）—— 本仓库的默认状态
#   B. 有 appID（临时放一个 steam_appid.txt）—— 初始化可能成功
# 无论哪种，都要回答同一个问题：**失败路径会不会回连 Valve**。
#
# ⚠ 若「失败时也零出站」成立 → 架构 1075 条的「零出站」与「NullSteam 降级」可同时满足。
#   若「失败时会出站」→ 必须用**进程级出站阻断**（防火墙规则）来兜，
#   否则 S9 的零出站硬约束在 GodotSteam 路径上不成立。
#
# 用法：powershell -ExecutionPolicy Bypass -File tools\s9_gsteam_probe.ps1

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReportPath = Join-Path $RepoRoot "tools\s9_gsteam_report.json"
$Godot = $env:GODOT_BIN
if (-not $Godot) { $Godot = "C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe" }

$ProbeScript = Join-Path $RepoRoot "tests\_gsteam_init_probe.gd"

# The probe script: initialize GodotSteam and report the result.
# Kept ASCII-only (PS 5.1 reads UTF-8 without BOM as GBK -> mojibake -> parse error).
$probeSrc = @'
extends SceneTree
func _initialize() -> void:
	print("PROBE_BEGIN")
	print("godotsteam_version=", Steam.get_godotsteam_version())
	print("is_steam_running_before=", Steam.isSteamRunning())
	var r = Steam.steamInitEx()
	print("steamInitEx_result=", JSON.stringify(r))
	print("is_steam_running_after=", Steam.isSteamRunning())
	print("PROBE_END")
	quit(0)
'@
[System.IO.File]::WriteAllText($ProbeScript, $probeSrc, (New-Object System.Text.UTF8Encoding($false)))

function Get-Snapshot {
    $rows = @()
    try {
        $rows = Get-NetTCPConnection -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ Proto="TCP"; PID=$_.OwningProcess; Local=$_.LocalAddress; LocalPort=$_.LocalPort
                Remote=$_.RemoteAddress; RemotePort=$_.RemotePort; State=[string]$_.State }
        }
    } catch { $rows = @() }
    try {
        $rows += Get-NetUDPEndpoint -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ Proto="UDP"; PID=$_.OwningProcess; Local=$_.LocalAddress; LocalPort=$_.LocalPort
                Remote=""; RemotePort=""; State="" }
        }
    } catch {}
    return $rows
}

function Invoke-Case {
    param([string]$Label, [bool]$WithAppId)
    Write-Host ""
    Write-Host "=== CASE $Label (appid present: $WithAppId) ==="

    $appidPath = Join-Path $RepoRoot "steam_appid.txt"
    if (Test-Path $appidPath) { Remove-Item $appidPath -Force }
    if ($WithAppId) {
        # 480 is Spacewar (Valve's public test app) -- used only to see whether
        # a *successful* init path also stays offline.
        [System.IO.File]::WriteAllText($appidPath, "480`n")
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $psi.Arguments = "--headless --path `"$RepoRoot`" -s res://tests/_gsteam_init_probe.gd"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $started = $proc.Start()
    if (-not $started) { Write-Host "  FAILED TO START"; return $null }
    $outTask = $proc.StandardOutput.ReadToEndAsync()

    $seen = @()
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        $pids = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match "godot" } | Select-Object -ExpandProperty Id)
        foreach ($r in (Get-Snapshot)) { if ($pids -contains $r.PID) { $seen += $r } }
        Start-Sleep -Milliseconds 100
    }
    if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    $stdout = $outTask.Result
    if (Test-Path $appidPath) { Remove-Item $appidPath -Force }

    $loopback = @("127.0.0.1","::1","0.0.0.0","::","::ffff:127.0.0.1")
    $uniq = @{}
    foreach ($r in $seen) {
        $k = "$($r.Proto)|$($r.Local)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)|$($r.State)"
        if (-not $uniq.ContainsKey($k)) { $uniq[$k] = $r }
    }
    $outbound = @()
    foreach ($r in $uniq.Values) {
        if (($loopback -notcontains $r.Remote) -and ($r.Remote -ne "") -and
            ($r.State -in @("Established","SynSent","CloseWait","TimeWait"))) { $outbound += $r }
    }
    $dns = @($outbound | Where-Object { $_.Proto -eq "UDP" -and $_.RemotePort -eq 53 })
    Write-Host "  --- probe output ---"
    ($stdout -split "`n" | Where-Object { $_ -match "PROBE_|steamInitEx|godotsteam_version|is_steam_running" }) | ForEach-Object { Write-Host "    $_" }
    Write-Host ("  outbound connections: {0}   dns: {1}" -f $outbound.Count, $dns.Count)
    if ($outbound.Count -gt 0) { $outbound | Select-Object -First 8 | Format-Table -AutoSize | Out-String | Write-Host }
    return [PSCustomObject]@{
        case = $Label
        appid_present = $WithAppId
        outbound_count = $outbound.Count
        dns_count = $dns.Count
        outbound_detail = @($outbound)
        stdout = $stdout
    }
}

Write-Host "=== S9 / architecture 1075: does a FAILED GodotSteam init reach out to Valve? ==="
Write-Host "Godot: $Godot"

$caseA = Invoke-Case -Label "A_no_appid" -WithAppId $false
$caseB = Invoke-Case -Label "B_with_appid" -WithAppId $true

$report = @{
    generated_at = (Get-Date -Format o)
    godotsteam_version = "4.15"
    cases = @($caseA, $caseB)
    note = "Answers architecture 1075: when GodotSteam init FAILS, does the process make any outbound connection? case A = no appid (default). case B = with steam_appid.txt (Spacewar 480)."
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
if (Test-Path $ProbeScript) { Remove-Item $ProbeScript -Force }
Write-Host ""
Write-Host "report written: $ReportPath"
exit 0
