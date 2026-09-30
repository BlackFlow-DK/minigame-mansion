# Runs a Blender Python script headless. Fails (non-zero) if the script raises.
# Usage: tools/blender-run.ps1 art/scripts/test_prop.py [script args...]
# Script args arrive in the script after '--' (see art/scripts/artlib.py: script_args()).
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Script,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArgs,
    [int]$TimeoutSec = 600
)
. "$PSScriptRoot\_common.ps1"

$path = $Script
if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $RepoRoot $path }
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Host "blender-run: script not found: $path"; exit 2 }
$path = (Resolve-Path -LiteralPath $path).Path

$blender = Get-BlenderBin
# --factory-startup: ignore user prefs/add-ons, so runs are reproducible.
# --python-exit-code 1: Blender otherwise exits 0 when the script raises.
$argList = @('--background', '--factory-startup', '--python-exit-code', '1', '--python', $path)
if ($ScriptArgs -and $ScriptArgs.Count -gt 0) { $argList += @('--') + $ScriptArgs }

$r = Invoke-Tool -Exe $blender -ArgList $argList -TimeoutSec $TimeoutSec
$tb = @($r.Output | Where-Object { $_ -match '^Traceback|^Error:|Python: Traceback' })
if ($r.ExitCode -ne 0 -or $tb.Count -gt 0) {
    Write-Host "blender-run: FAILED (exit $($r.ExitCode))"
    if ($r.ExitCode -eq 0) { exit 1 }
    exit $r.ExitCode
}
Write-Host 'blender-run: OK'
exit 0
