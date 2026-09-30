# Headless import of the Godot project (reimports new/changed assets, e.g. .glb from Blender).
# Usage: tools/godot-import.ps1
param([int]$TimeoutSec = 600)
. "$PSScriptRoot\_common.ps1"

$godot = Get-GodotBin
$r = Invoke-Tool -Exe $godot -ArgList @('--headless', '--path', $GameDir, '--import') -TimeoutSec $TimeoutSec
$errors = Get-GodotErrors $r.Output
if ($r.ExitCode -ne 0 -or $errors.Count -gt 0) {
    Write-Host "godot-import: FAILED (exit $($r.ExitCode), $($errors.Count) error line(s))"
    exit 1
}
Write-Host 'godot-import: OK'
exit 0
