# export.ps1 - SafeHouse Windows 导出（打包/CI 唯一入口，内联 S10 缓解 B）
#
# 职责：
#   1) [S10-B] 导出前清空 user://logs/，避免构建机残留日志（含绝对路径）随流程外发
#   2) 调用 Godot 导出 Windows Desktop x86_64 preset（embed_pck=true，对应架构 §6.2）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools/export.ps1
#   powershell -ExecutionPolicy Bypass -File tools/export.ps1 -GodotBin "C:\Tools\Godot_v4.3-stable_win64.exe"

param(
    [string]$GodotBin = "Godot_v4.3-stable_win64.exe",
    [string]$Preset   = "Windows Desktop x86_64",
    [string]$OutExe   = "build/steam/content/SafeHouse.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # safehouse/
$ProjRoot = $RepoRoot

# ---------- [S10-B] 导出前清空 user://logs/ ----------
# Godot 的 user:// 在 Windows 上落 %APPDATA%\<product> 与 %LOCALAPPDATA%\<product>。
# 两处都清，确保构建机残留日志（可能含 C:/Users/<name>/... 绝对路径）不随流程外发。
function Clear-LogDir {
    $candidates = @(
        (Join-Path $env:APPDATA      "SafeHouse\logs"),
        (Join-Path $env:LOCALAPPDATA "SafeHouse\logs")
    )
    foreach ($d in $candidates) {
        if (Test-Path $d) {
            Remove-Item $d -Recurse -Force
            Write-Host "[S10-B] cleared: $d"
        } else {
            Write-Host "[S10-B] not present (skip): $d"
        }
    }
}
Clear-LogDir

# ---------- 导出 ----------
Write-Host "exporting preset '$Preset' -> $OutExe"
& $GodotBin --headless --path $ProjRoot --export-release $Preset $OutExe
if ($LASTEXITCODE -ne 0) {
    throw "Godot export failed with exit code $LASTEXITCODE"
}
Write-Host "export done: $OutExe"
