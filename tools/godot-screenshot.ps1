# Runs the game WINDOWED (real GPU renderer), waits N frames, saves the viewport to PNG, quits.
# Usage: tools/godot-screenshot.ps1 [-Scene res://scenes/main.tscn] [-Out build/screenshots/x.png] [-Frames 60]
# Default scene is the project's main scene. Default Out is build/screenshots/<scene name>.png.
# -GameArgs passes space-separated user args to the game, e.g. -GameArgs "--minigame=bumper_sumo --players=8" (sandbox).
# Fails if the PNG is not written, the run times out, or any SCRIPT ERROR / ERROR line is printed.
param(
    [string]$Scene = '',
    [string]$Out = '',
    [int]$Frames = 60,
    [string]$Resolution = '1280x720',
    [int]$TimeoutSec = 60,
    [string]$GameArgs = ''
)
. "$PSScriptRoot\_common.ps1"

if ($Out -eq '') {
    $stem = 'main'
    if ($Scene -ne '') { $stem = [System.IO.Path]::GetFileNameWithoutExtension($Scene) }
    $Out = Join-Path $RepoRoot "build\screenshots\$stem.png"
}
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $RepoRoot $Out }
$Out = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }

$godot = Get-GodotBin
$argList = @('--path', $GameDir, '--windowed', '--resolution', $Resolution)
if ($Scene -ne '') { $argList += $Scene }
# In-game timeout is a little shorter than the process kill, so Godot normally exits cleanly.
$inGameTimeout = [Math]::Max(5, $TimeoutSec - 10)
$argList += @('--', "--screenshot=$Out", "--frames=$Frames", "--timeout=$inGameTimeout")
if ($GameArgs.Trim() -ne '') { $argList += @($GameArgs.Trim() -split '\s+') }

$r = Invoke-Tool -Exe $godot -ArgList $argList -TimeoutSec $TimeoutSec
$errors = Get-GodotErrors $r.Output
$written = Test-Path -LiteralPath $Out
if ($r.ExitCode -ne 0 -or -not $written -or $errors.Count -gt 0) {
    Write-Host "godot-screenshot: FAILED (exit $($r.ExitCode), png written: $written, $($errors.Count) error line(s))"
    exit 1
}
Write-Host "godot-screenshot: OK -> $Out"
exit 0
