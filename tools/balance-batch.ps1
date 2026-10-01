# Balance batches: headless bot-only rounds through the real Session flow, measured per slot
# (game/tools/balance/balance_batch.tscn + balance_runner.gd). Per minigame and player count it
# prints round length mean/median/min/max, win rate and mean place per slot (slot 0 = host
# seat), the place histogram, points per slot, knock-out timing and any "never ends" rounds.
# Usage:
#   tools/balance-batch.ps1 [-Minigame id|all] [-Players N|"2,4,8"] [-Rounds M] [-Seed S]
#                           [-Parallel] [-Verbose] [-Out build\balance\report.txt] [-TimeoutSec 3600]
# -Parallel runs each minigame in its own Godot process (much faster with -Minigame all).
# Exit code non-zero when Godot fails, errors, or a round never ended.
param(
    [string]$Minigame = 'all',
    [string]$Players = '4',
    [int]$Rounds = 30,
    [int]$Seed = 1,
    [switch]$Parallel,
    [switch]$Verbose,
    [string]$Out = '',
    [int]$TimeoutSec = 3600
)
. "$PSScriptRoot\_common.ps1"

$godot = Get-GodotBin
if (-not (Test-Path -LiteralPath (Join-Path $GameDir '.godot'))) {
    Write-Host 'balance-batch: no .godot/ cache yet, importing first'
    & (Join-Path $PSScriptRoot 'godot-import.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

function Get-BatchArgs([string]$ids) {
    $a = @('--headless', '--fixed-fps', '60', '--path', $GameDir, 'res://tools/balance/balance_batch.tscn', '--',
        "--minigame=$ids", "--players=$Players", "--rounds=$Rounds", "--seed=$Seed")
    if ($Verbose) { $a += '--verbose' }
    return $a
}

$ids = @($Minigame)
if ($Parallel -and $Minigame -eq 'all') {
    $registry = Get-Content -LiteralPath (Join-Path $GameDir 'minigames\registry.gd') -Raw
    $m = [regex]::Match($registry, 'IDS[^=]*=\s*\[([^\]]*)\]')
    $ids = @([regex]::Matches($m.Groups[1].Value, '&"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
}

$lines = @()
$failed = $false
if ($ids.Count -le 1) {
    $r = Invoke-Tool -Exe $godot -ArgList (Get-BatchArgs $ids[0]) -TimeoutSec $TimeoutSec
    $lines = $r.Output
    if ($r.ExitCode -ne 0) { $failed = $true }
} else {
    $work = Join-Path $RepoRoot 'build\balance'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $procs = @()
    foreach ($id in $ids) {
        $o = Join-Path $work "$id.out"
        $e = Join-Path $work "$id.err"
        Write-Host ">> $godot $(ConvertTo-ArgString (Get-BatchArgs $id))"
        $p = Start-Process -FilePath $godot -ArgumentList (ConvertTo-ArgString (Get-BatchArgs $id)) -NoNewWindow -PassThru `
            -WorkingDirectory $RepoRoot -RedirectStandardOutput $o -RedirectStandardError $e
        $null = $p.Handle
        $procs += [pscustomobject]@{ Id = $id; Proc = $p; Out = $o; Err = $e }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    foreach ($x in $procs) {
        $left = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $x.Proc.WaitForExit($left)) {
            & taskkill.exe /PID $x.Proc.Id /T /F | Out-Null
            Write-Host "!! $($x.Id): TIMED OUT"
            $failed = $true
        } elseif ($x.Proc.ExitCode -ne 0) {
            $failed = $true
        }
        foreach ($f in @($x.Out, $x.Err)) {
            if (Test-Path -LiteralPath $f) {
                $lines += @(Get-Content -LiteralPath $f | ForEach-Object { $_ -replace "\x1b\[[0-9;]*[A-Za-z]", '' })
            }
        }
    }
    foreach ($l in $lines) { if ($l -ne '') { Write-Host $l } }
}

$errors = Get-GodotErrors $lines
if ($Out -ne '') {
    $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $RepoRoot $Out }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
    $lines | Where-Object { $_ -match '^(==|   |BALANCE_JSON)' } | Set-Content -LiteralPath $outPath -Encoding utf8
    Write-Host "balance-batch: report written to $outPath"
}
if ($failed -or $errors.Count -gt 0) {
    Write-Host "balance-batch: FAILED ($($errors.Count) error line(s))"
    exit 1
}
Write-Host 'balance-batch: OK'
exit 0
