# Headless tests: runs every test_* method in game/tests/test_*.gd (game/tests/run_tests.gd).
# --fixed-fps 60 makes physics step exactly 1/60 s per frame, as fast as the CPU allows.
# Non-zero exit on any failed test, script error, Godot ERROR line, or timeout.
# Usage: tools/godot-test.ps1 [-Filter text]   (substring of "<file>::<test>", case-insensitive)
param([string]$Filter = '', [int]$TimeoutSec = 600)
. "$PSScriptRoot\_common.ps1"

$godot = Get-GodotBin
if (-not (Test-Path -LiteralPath (Join-Path $GameDir '.godot'))) {
    Write-Host 'godot-test: no .godot/ cache yet, importing first'
    & (Join-Path $PSScriptRoot 'godot-import.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
$argList = @('--headless', '--fixed-fps', '60', '--path', $GameDir, '--script', 'res://tests/run_tests.gd')
if ($Filter -ne '') { $argList += @('--', "--filter=$Filter") }
$r = Invoke-Tool -Exe $godot -ArgList $argList -TimeoutSec $TimeoutSec
$errors = Get-GodotErrors $r.Output
if ($r.ExitCode -ne 0 -or $errors.Count -gt 0) {
    Write-Host "godot-test: FAILED (exit $($r.ExitCode), $($errors.Count) error line(s))"
    exit 1
}
Write-Host 'godot-test: OK'
exit 0
