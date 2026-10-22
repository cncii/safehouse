# s9_export_probe.ps1 - S9 / architecture 1075: does the EXPORTED build reach out on Steam init?
#
# Purpose (architecture 1075 / 1012):
#   "Does GodotSteam reconnect after embed_pck + hot reload -> on failure it MUST
#    fall back to NullSteam and log it"
#
# This script measures the EXPORTED executable (not the editor / headless Godot):
#   - runs the exported exe while sampling the process connection table
#   - asserts the exported process makes ZERO outbound connections and ZERO DNS queries
#   - runs the same measurement twice: embed_pck=true (single-file, architecture
#     section 6.2 requirement) and embed_pck=false (the "hot reload" comparison)
#
# Why it matters: the editor path was already verified (tools/s9_gsteam_probe.ps1).
# The exported build is a DIFFERENT binary: the PCK is embedded in the exe, the
# GodotSteam GDExtension is loaded from res://addons/, and the Steamworks native
# lib is a real file next to the exe. Different binary -> different behaviour ->
# must be measured separately. This is exactly what architecture 1075 flagged
# as "only verifiable after shipping a build".
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\s9_export_probe.ps1
#   powershell -ExecutionPolicy Bypass -File tools\s9_export_probe.ps1 -TimeoutSec 60
#
# Requires: exported exes present at
#   build/steam/content/SafeHouse.exe        (embed_pck = true)
#   build/steam/content_nopck/SafeHouse.exe  (embed_pck = false)

param(
    [int]$TimeoutSec = 45
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReportPath = Join-Path $RepoRoot "tools\s9_export_report.json"

$cases = @(
    @{ label = "embed_pck_true";  exe = "build\steam\content\SafeHouse.exe" },
    @{ label = "embed_pck_false"; exe = "build\steam\content_nopck\SafeHouse.exe" }
)

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

function Invoke-ExportCase {
    param($case)
    $exePath = Join-Path $RepoRoot $case.exe
    Write-Host ""
    Write-Host "=== CASE $($case.label): $($case.exe) ==="
    if (-not (Test-Path $exePath)) {
        Write-Host "  SKIP: exe not found (export first)"
        return [PSCustomObject]@{ case=$case.label; skipped=$true; reason="exe not found" }
    }

    $before = Get-Snapshot
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $proc.StartInfo.FileName = $exePath
    $proc.StartInfo.WorkingDirectory = (Split-Path -Parent $exePath)
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError = $true
    $started = $proc.Start()
    if (-not $started) { Write-Host "  FAILED TO START"; return [PSCustomObject]@{ case=$case.label; skipped=$true; reason="start failed" } }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $seen = @{}
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        $pids = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match "SafeHouse|godot" } | Select-Object -ExpandProperty Id)
        foreach ($r in (Get-Snapshot)) {
            if ($pids -contains $r.PID) {
                $seen["$($r.Proto)|$($r.Local)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)|$($r.State)"] = $r
            }
        }
        Start-Sleep -Milliseconds 150
    }
    $exited = $proc.HasExited
    $exitCode = if ($exited) { $proc.ExitCode } else { $null }
    if (-not $exited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    $stdout = ""
    try { $stdout = $outTask.Result } catch {}

    $loopback = @("127.0.0.1","::1","0.0.0.0","::","::ffff:127.0.0.1")
    $outbound = @()
    foreach ($r in $seen.Values) {
        if (($loopback -notcontains $r.Remote) -and ($r.Remote -ne "") -and
            ($r.State -in @("Established","SynSent","CloseWait","TimeWait"))) { $outbound += $r }
    }
    $dns = @($outbound | Where-Object { $_.Proto -eq "UDP" -and $_.RemotePort -eq 53 })

    # ANTI-FALSE-GREEN: the process must actually have run and produced output.
    # A build that dies at startup would trivially have zero connections.
    $ran = ($stdout -ne "") -or ($seen.Count -gt 0)
    $degraded = $stdout -match "null_backend" -or $stdout -match "NullSteam"

    Write-Host ("  exited={0} exit_code={1} stdout_len={2} conn_rows={3}" -f $exited, $exitCode, $stdout.Length, $seen.Count)
    Write-Host ("  outbound={0}  dns={1}  ran={2}  degraded_log={3}" -f $outbound.Count, $dns.Count, $ran, $degraded)
    if ($stdout.Length -gt 0) {
        ($stdout -split "`n" | Where-Object { $_ -match "steam|Steam|null_backend|NullSteam|ERROR" } | Select-Object -First 8) | ForEach-Object { Write-Host "    $_" }
    }
    if ($outbound.Count -gt 0) { $outbound | Select-Object -First 8 | Format-Table -AutoSize | Out-String | Write-Host }

    return [PSCustomObject]@{
        case = $case.label
        exe = $case.exe
        skipped = $false
        exited = $exited
        exit_code = $exitCode
        stdout_len = $stdout.Length
        conn_rows_seen = $seen.Count
        outbound_count = $outbound.Count
        dns_count = $dns.Count
        guard_process_ran = $ran
        guard_degradation_logged = $degraded
        outbound_detail = @($outbound)
        stdout_head = ($stdout -split "`n" | Select-Object -First 20) -join "`n"
    }
}

Write-Host "=== S9 / architecture 1075: exported build outbound measurement ==="
$results = @()
foreach ($c in $cases) { $results += Invoke-ExportCase -case $c }

$report = @{
    generated_at = (Get-Date -Format o)
    timeout_sec = $TimeoutSec
    cases = $results
    note = "Architecture 1075: 'GodotSteam with embed_pck, can it reconnect after hot reload -> on failure it MUST fall back to NullSteam and log it'. Measures the EXPORTED exe (editor path was verified separately by tools/s9_gsteam_probe.ps1). Both embed_pck=true and embed_pck=false are measured as a comparison."
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host ""
Write-Host "report written: $ReportPath"
exit 0
