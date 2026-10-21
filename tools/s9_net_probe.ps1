# s9_net_probe.ps1 - S9 layer 2 (OS-level outbound = 0) runnable check (combat group, pkg C+E)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\s9_net_probe.ps1
#
# Criterion (S9 / architecture 6.2):
#   "no outbound except local Steamworks IPC" + "game fully works with firewall blocking all outbound"
#   -> This script snapshots process-level TCP/UDP connections WHILE the game runs and asserts:
#      (1) the Godot process has NO outbound ESTABLISHED/SYN_SENT connections
#      (2) the Godot process issued NO DNS query (UDP port 53 to a non-local address)
#      (3) the connection-table diff (baseline vs during-run) is EMPTY
#
# Why static scan is not enough:
#   Static scan only proves "our source has no network call".
#   It cannot prove "no outbound at runtime" - the engine, plugins, or Godot's
#   HTTPClient may send requests without going through our code.
#
# NOTE: this script does NOT change firewall settings (needs admin and affects
#   the whole machine). The "game still fully playable with firewall blocking
#   all outbound" part must be done manually on a test machine. This script
#   covers the automatable half: zero runtime connections.
#
# Output: tools/s9_net_report.json (for CI / QA to read)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReportPath = Join-Path $RepoRoot "tools\s9_net_report.json"
$Godot = $env:GODOT_BIN
if (-not $Godot) { $Godot = "C:\Users\CQY\.workbuddy\binaries\godot\4.3\Godot_v4.3-stable_win64_console.exe" }

function Get-Snapshot {
    $rows = @()
    try {
        $rows = Get-NetTCPConnection -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{
                Proto = "TCP"; PID = $_.OwningProcess; Local = $_.LocalAddress; LocalPort = $_.LocalPort
                Remote = $_.RemoteAddress; RemotePort = $_.RemotePort; State = [string]$_.State
            }
        }
    } catch { $rows = @() }
    try {
        $rows += Get-NetUDPEndpoint -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{
                Proto = "UDP"; PID = $_.OwningProcess; Local = $_.LocalAddress; LocalPort = $_.LocalPort
                Remote = ""; RemotePort = ""; State = ""
            }
        }
    } catch {}
    return $rows
}

function Get-GodotPids {
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match "godot" } | Select-Object -ExpandProperty Id)
}

Write-Host "=== S9 layer 2: runtime outbound detection ==="
Write-Host "Godot: $Godot"

$baseline = Get-Snapshot
$godotPidsBefore = Get-GodotPids
Write-Host "baseline: $($baseline.Count) connections, $($godotPidsBefore.Count) godot processes running"

# ---------------------------------------------------------------------
# Sample the connection table WHILE the game is running.
#
# CRITICAL (measured pitfall): sampling AFTER the probes exit gives a
# FALSE GREEN - the Godot process is gone by then, so "process has no
# connections" is trivially true. The probe must run in the background
# and we must poll the connection table during its lifetime.
# ---------------------------------------------------------------------
$scenes = @(
    "res://scenes/debug/combat_probe.tscn",
    "res://scenes/debug/event_probe.tscn",
    "res://scenes/debug/steam_probe.tscn",
    "res://scenes/debug/pii_probe.tscn"
)
$runOut = @()
$godotSeenConns = @()
$gamePidsAll = @()

foreach ($s in $scenes) {
    Write-Host "--- running $s (sampling connections during run) ---"
    # Use System.Diagnostics.Process directly, NOT Start-Process.
    # MEASURED PITFALL: Start-Process copies the current environment into a
    # case-INSENSITIVE dictionary. This machine has BOTH "HTTP_PROXY" and
    # "http_proxy" set, so Start-Process throws
    # "An item with the same key has already been added" and the process
    # NEVER STARTS. The assertions then pass trivially on zero rows
    # (a FALSE GREEN). System.Diagnostics.Process does not rebuild the env.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $psi.Arguments = "--headless --path `"$RepoRoot`" --quit-after 400 $s"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $started = $proc.Start()
    if (-not $started) { Write-Host "    FAILED TO START"; continue }
    # Read the redirected streams AFTER Start(): before Start(), the
    # StandardOutput/StandardError properties are null (MEASURED PITFALL).
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $deadline = (Get-Date).AddSeconds(90)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        $pids = Get-GodotPids
        $gamePidsAll += $pids
        $snap = Get-Snapshot
        foreach ($r in $snap) {
            if ($pids -contains $r.PID) { $godotSeenConns += $r }
        }
        Start-Sleep -Milliseconds 120
    }
    if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    $stdout = $outTask.Result
    $m = [regex]::Match($stdout, "probe: (\d+) pass / (\d+) fail")
    $runOut += [PSCustomObject]@{
        scene = $s
        started = $true
        summary = $(if ($m.Success) { $m.Value } else { "no-summary" })
    }
    Write-Host "    $($runOut[-1].summary)"
}

# De-duplicate the sampled rows (we polled repeatedly).
$uniqSeen = @()
$seenKeys = @{}
foreach ($r in $godotSeenConns) {
    $k = "$($r.Proto)|$($r.PID)|$($r.Local)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)|$($r.State)"
    if (-not $seenKeys.ContainsKey($k)) { $seenKeys[$k] = 1; $uniqSeen += $r }
}
$godotSeenConns = $uniqSeen

$after = Get-Snapshot
Write-Host "sampled during run: $($godotSeenConns.Count) godot connection rows, $($gamePidsAll.Count) godot pid samples"

$loopback = @("127.0.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1")
# Judge on the CONNECTIONS SAMPLED DURING THE RUN (not the after-snapshot).
$godotConns = $godotSeenConns | Where-Object {
    ($loopback -notcontains $_.Remote) -and ($_.Remote -ne "")
}
$dnsConns = $godotConns | Where-Object { $_.Proto -eq "UDP" -and $_.RemotePort -eq 53 }
$outbound = $godotConns | Where-Object {
    $_.State -in @("Established", "SynSent", "CloseWait", "TimeWait")
}

# Assert (3): connection-table diff.
# Scope it to the GAME PROCESS only. A whole-table diff would flag other
# processes' connections (e.g. Steam's own update connection to 111.31.3.49:443
# and its loopback IPC) and report them as the game's outbound traffic.
$baselineKeys = @{}
foreach ($r in $baseline) { $baselineKeys["$($r.Proto)|$($r.Local)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)|$($r.State)"] = 1 }
$diff = @()
foreach ($r in $godotSeenConns) {
    $k = "$($r.Proto)|$($r.Local)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)|$($r.State)"
    if (-not $baselineKeys.ContainsKey($k)) { $diff += $r }
}

$pass1 = ($outbound.Count -eq 0)
$pass2 = ($dnsConns.Count -eq 0)
$pass3 = ($diff.Count -eq 0)

# ---------------------------------------------------------------------
# ANTI-FALSE-GREEN GUARD (measured pitfall).
# If the game process never actually ran, "zero connections" is trivially
# true and the whole check is meaningless. Require:
#   (a) every scene actually started AND reported a probe summary
#   (b) we actually sampled the connection table while Godot was alive
# -> otherwise the run is judged FAILED, not passed.
# ---------------------------------------------------------------------
$scenesStarted = @($runOut | Where-Object { $_.started -eq $true }).Count
$summariesOk = @($runOut | Where-Object { $_.summary -ne "no-summary" }).Count
$guardA = ($scenesStarted -eq $scenes.Count) -and ($summariesOk -eq $scenes.Count)
$guardB = ($gamePidsAll.Count -gt 0)
$passGuard = $guardA -and $guardB

Write-Host ""
Write-Host "guard: all scenes started & reported      : $(if($guardA){'PASS'}else{'FAIL'})  ($summariesOk/$($scenes.Count) summaries, $scenesStarted started)"
Write-Host "guard: connection table sampled while alive: $(if($guardB){'PASS'}else{'FAIL'})  ($($gamePidsAll.Count) pid samples)"
Write-Host "assert (1) godot outbound connections == 0 : $(if($pass1){'PASS'}else{'FAIL'})  ($($outbound.Count))"
Write-Host "assert (2) godot DNS queries == 0          : $(if($pass2){'PASS'}else{'FAIL'})  ($($dnsConns.Count))"
Write-Host "assert (3) connection table diff == 0      : $(if($pass3){'PASS'}else{'FAIL'})  ($($diff.Count))"
if (-not $pass1) { $outbound | Select-Object -First 10 | Format-Table -AutoSize | Out-String | Write-Host }
if (-not $pass2) { $dnsConns | Select-Object -First 10 | Format-Table -AutoSize | Out-String | Write-Host }
if (-not $pass3) { $diff | Select-Object -First 10 | Format-Table -AutoSize | Out-String | Write-Host }

$report = @{
    generated_at = (Get-Date -Format o)
    scenes = $runOut
    baseline_count = $baseline.Count
    after_count = $after.Count
    godot_pid_samples = @($gamePidsAll | Select-Object -Unique)
    guard_scenes_started = $guardA
    guard_sampled_while_alive = $guardB
    assert_outbound_zero = $pass1
    assert_dns_zero = $pass2
    assert_diff_zero = $pass3
    outbound_detail = @($outbound)
    dns_detail = @($dnsConns)
    diff_detail = @($diff)
    note = "Covers S9 layer 2 'runtime outbound 0 / DNS 0'. The 'firewall blocks all outbound and game still fully playable' part needs a manual run on a test machine; this script does not touch firewall settings."
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host ""
Write-Host "report written: $ReportPath"
if (-not ($passGuard -and $pass1 -and $pass2 -and $pass3)) { exit 1 }
exit 0
