# Headless validation: parses every .gd and loads every scene under game/ (game/tools/check_project.gd).
# Non-zero exit on any parse error, failed load, or Godot ERROR line.
# Usage: tools/godot-check.ps1
param([int]$TimeoutSec = 300)
. "$PSScriptRoot\_common.ps1"

$godot = Get-GodotBin
if (-not (Test-Path -LiteralPath (Join-Path $GameDir '.godot'))) {
    Write-Host 'godot-check: no .godot/ cache yet, importing first'
    & (Join-Path $PSScriptRoot 'godot-import.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
$r = Invoke-Tool -Exe $godot -ArgList @('--headless', '--path', $GameDir, '--script', 'res://tools/check_project.gd') -TimeoutSec $TimeoutSec
$errors = Get-GodotErrors $r.Output
if ($r.ExitCode -ne 0 -or $errors.Count -gt 0) {
    Write-Host "godot-check: FAILED (exit $($r.ExitCode), $($errors.Count) error line(s))"
    exit 1
}
Write-Host 'godot-check: OK'
exit 0
