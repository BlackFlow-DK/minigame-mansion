# Windowed frame-time runs of the extras sandbox: 8 players with 0 and with N extras, per quality.
# Uses the PerfProbe (game/tools/perf) through game/stage/dev/extras_sandbox.tscn; rows go to
# build\perf\extras.csv. Prints avg ms, CPU/GPU ms, draw calls and the cost per extra.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\stage\dev\run_extras_perf.ps1
#          [-Extras 20] [-Qualities low,high] [-Seconds 8] [-Warmup 3] [-Minigame ''] [-Label extras]
param([int]$Extras = 20, [string[]]$Qualities = @('low', 'high'), [double]$Seconds = 8, [double]$Warmup = 3,
    [string]$Minigame = '', [string]$Label = 'extras')
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')
$godot = Get-GodotBin
$Qualities = @($Qualities | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$perfDir = Join-Path $Root 'build\perf'
New-Item -ItemType Directory -Force -Path $perfDir | Out-Null
$out = Join-Path $perfDir "$Label.csv"
$rows = @()
foreach ($q in $Qualities) {
    foreach ($n in @(0, $Extras)) {
        $user = @('--players=8', "--extras=$n", "--quality=$q", '--fps=0', "--perf-seconds=$Seconds", "--perf-warmup=$Warmup",
            "--perf-out=$out", "--perf-label=$Label")
        if ($Minigame -ne '') { $user += "--minigame=$Minigame" }
        $argList = @('--path', $GameDir, '--windowed', '--resolution', '1280x720', 'res://stage/dev/extras_sandbox.tscn', '--') + $user
        Write-Host ">> $q, $n extras"
        $lines = & $godot @argList 2>&1 | ForEach-Object { "$_" -replace "\x1b\[[0-9;]*[A-Za-z]", '' }
        $errs = @($lines | Where-Object { $_ -match $GodotErrorPattern })
        if ($errs.Count -gt 0) { $errs | ForEach-Object { Write-Host "   $_" } }
        $row = $lines | Where-Object { $_ -match '^perf: ' -and $_ -notmatch '^perf: label,' -and $_ -match ',' } | Select-Object -Last 1
        if (-not $row) { Write-Host '   !! no result row'; continue }
        $c = ($row -replace '^perf: ', '') -split ','
        # label,target,minigame,quality,players,frames,avg_ms,p99_ms,low1_ms,max_ms,fps,cpu_render_ms,gpu_ms,process_ms,physics_ms,draw_calls
        $rows += [pscustomobject]@{ quality = $q; extras = $n; avg_ms = [double]$c[6]; low1_ms = [double]$c[8]; cpu_render_ms = [double]$c[11];
            gpu_ms = [double]$c[12]; process_ms = [double]$c[13]; physics_ms = [double]$c[14]; draws = [double]$c[15] }
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
foreach ($q in $Qualities) {
    $a = $rows | Where-Object { $_.quality -eq $q -and $_.extras -eq 0 }
    $b = $rows | Where-Object { $_.quality -eq $q -and $_.extras -eq $Extras }
    if ($a -and $b -and $Extras -gt 0) {
        Write-Host ("{0}: per extra {1:N3} ms frame, {2:N3} ms process, {3:N3} ms physics, {4:N3} ms GPU, {5:N1} draws" -f $q,
            (($b.avg_ms - $a.avg_ms) / $Extras), (($b.process_ms - $a.process_ms) / $Extras), (($b.physics_ms - $a.physics_ms) / $Extras),
            (($b.gpu_ms - $a.gpu_ms) / $Extras), (($b.draws - $a.draws) / $Extras))
    }
}
Write-Host "extras-perf: CSV -> $out"
exit 0
