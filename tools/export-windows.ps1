# Exports a release Windows build (PCK embedded -> single .exe) to build/windows/<repo-folder-name>.exe.
# Uses the "Windows Desktop" preset in game/export_presets.cfg. Needs Godot export templates installed.
# Usage: tools/export-windows.ps1 [-DebugBuild]
param([switch]$DebugBuild, [int]$TimeoutSec = 900)
. "$PSScriptRoot\_common.ps1"

$name = Split-Path -Leaf $RepoRoot
$outDir = Join-Path $RepoRoot 'build\windows'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$exe = Join-Path $outDir "$name.exe"
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

$mode = '--export-release'
if ($DebugBuild) { $mode = '--export-debug' }
$godot = Get-GodotBin
$r = Invoke-Tool -Exe $godot -ArgList @('--headless', '--path', $GameDir, $mode, 'Windows Desktop', $exe) -TimeoutSec $TimeoutSec
$errors = Get-GodotErrors $r.Output
if ($r.ExitCode -ne 0 -or $errors.Count -gt 0 -or -not (Test-Path -LiteralPath $exe)) {
    Write-Host "export-windows: FAILED (exit $($r.ExitCode), $($errors.Count) error line(s))"
    exit 1
}
$size = [Math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
Write-Host "export-windows: OK -> $exe ($size MB)"
exit 0
