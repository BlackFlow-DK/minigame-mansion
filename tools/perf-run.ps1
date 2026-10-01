# Frame-time / render-stats runs of the real game, windowed, through game/tools/perf/perf_driver.tscn.
# Each run: one scene at one quality, warm up, measure, append a row to the CSV, quit. Prints a table.
#
# Usage: tools/perf-run.ps1 [-Scenes title,lobby,dev_arena,bumper_sumo,...] [-Qualities low,medium,high]
#          [-Seconds 10] [-Warmup 3] [-Players 8] [-Resolution 1280x720] [-Label after]
#          [-Out build\perf\after.csv] [-Throttle] [-Exe build\windows\perf.exe] [-Shots]
#   -Scenes     title | lobby | dev_arena | any MinigameRegistry id (default: all of them)
#   -Throttle   weak-PC CPU proxy: the process is pinned to 2 logical cores at below-normal priority
#   -Exe        run an exported DEBUG build (export-windows.ps1 -DebugBuild) instead of the editor binary;
#               release templates refuse a scene path on the command line
#   -Shots      also save a PNG per run to build\perf\shots\<label>_<scene>_<quality>.png
# Also records per run: peak working set / private bytes of the process (MB) and every
# ERROR / SCRIPT ERROR / SHADER ERROR line (build\perf\<label>_errors.log).
param(
    [string[]]$Scenes = @(),
    [string[]]$Qualities = @('low', 'medium', 'high'),
    [double]$Seconds = 10,
    [double]$Warmup = 3,
    [int]$Players = 8,
    [string]$Resolution = '1280x720',
    [string]$Label = 'run',
    [string]$Out = '',
    [switch]$Throttle,
    [string]$Exe = '',
    [switch]$Shots,
    [string[]]$ExtraArgs = @()
)
. "$PSScriptRoot\_common.ps1"

$AllScenes = @('title', 'lobby', 'dev_arena', 'floor_is_lava', 'bumper_sumo', 'hot_potato', 'coin_scramble',
    'paint_splat', 'cannon_alley', 'spotlight_chairs')
if ($Scenes.Count -eq 0) { $Scenes = $AllScenes }
# PowerShell -File passes "a,b" as one string: split it.
$Scenes = @($Scenes | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$Qualities = @($Qualities | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

$perfDir = Join-Path $RepoRoot 'build\perf'
New-Item -ItemType Directory -Force -Path $perfDir | Out-Null
if ($Out -eq '') { $Out = Join-Path $perfDir "$Label.csv" }
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $RepoRoot $Out }
$Out = [System.IO.Path]::GetFullPath($Out)
$memCsv = [System.IO.Path]::ChangeExtension($Out, '.mem.csv')
$errLog = Join-Path $perfDir "$($Label)_errors.log"
if (-not (Test-Path -LiteralPath $memCsv)) {
    'label,scene,quality,peak_ws_mb,private_mb,wall_s,exit,errors' | Set-Content -LiteralPath $memCsv -Encoding ascii
}

if ($Exe -ne '') {
    if (-not [System.IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path $RepoRoot $Exe }
    $bin = $Exe
    $base = @()
} else {
    $bin = Get-GodotBin
    $base = @('--path', $GameDir)
}
$timeout = [int]($Warmup + $Seconds + 60)

# Add-Content that retries while another process (a reader) holds the file.
function Add-Line([string]$Path, [string]$Text) {
    for ($try = 0; $try -lt 20; $try++) {
        try { Add-Content -LiteralPath $Path -Value $Text -Encoding ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 100 }
    }
    Write-Host "   !! could not append to $Path"
}

foreach ($scene in $Scenes) {
    foreach ($q in $Qualities) {
        $user = @("--perf-label=$Label", "--perf-out=$Out", "--perf-seconds=$Seconds", "--perf-warmup=$Warmup",
            "--quality=$q", '--fps=0')
        switch ($scene) {
            'title' { $user += @('--perf-target=title', '--name=Perf') }
            'lobby' { $user += @('--perf-target=lobby', '--name=Perf', '--offline', "--bots=$($Players - 1)") }
            'dev_arena' { $user += @('--perf-target=sandbox', "--players=$Players") }
            default { $user += @('--perf-target=sandbox', "--minigame=$scene", "--players=$Players") }
        }
        if ($Shots) {
            $shot = Join-Path $perfDir "shots\$($Label)_$($scene)_$q.png"
            $user += "--perf-shot=$shot"
        }
        $user += $ExtraArgs
        $argList = $base + @('--windowed', '--resolution', $Resolution, 'res://tools/perf/perf_driver.tscn', '--') + $user
        $id = [guid]::NewGuid().ToString('N')
        $outFile = Join-Path $perfDir "log_$id.out"
        $errFile = Join-Path $perfDir "log_$id.err"
        Write-Host ">> $scene / $q"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $bin -ArgumentList (ConvertTo-ArgString $argList) -NoNewWindow -PassThru `
            -WorkingDirectory $RepoRoot -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $p.Handle
        # godot_console.exe is a thin wrapper that starts godot.exe: measure (and pin) the child.
        $game = $p
        for ($k = 0; $k -lt 40 -and -not $p.HasExited; $k++) {
            $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'godot*' -or $_.Name -like '*.exe' } | Select-Object -First 1
            if ($child) { $game = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue; break }
            if ($Exe -ne '') { break }
            Start-Sleep -Milliseconds 50
        }
        if ($null -eq $game) { $game = $p }
        if ($Throttle) {
            foreach ($t in @($p, $game) | Select-Object -Unique) {
                try {
                    $t.ProcessorAffinity = [IntPtr]3
                    $t.PriorityClass = 'BelowNormal'
                } catch { Write-Host "   (could not throttle: $($_.Exception.Message))" }
            }
        }
        $peak = 0; $priv = 0
        while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $timeout) {
            try {
                $game.Refresh()
                if ($game.WorkingSet64 -gt $peak) { $peak = $game.WorkingSet64 }
                if ($game.PrivateMemorySize64 -gt $priv) { $priv = $game.PrivateMemorySize64 }
            } catch {}
            Start-Sleep -Milliseconds 250
        }
        if (-not $p.HasExited) {
            & taskkill.exe /PID $p.Id /T /F | Out-Null
            Write-Host "   !! timed out after $timeout s"
        }
        $null = $p.WaitForExit(10000)
        $wall = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $lines = @()
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) {
                $lines += @(Get-Content -LiteralPath $f | ForEach-Object { $_ -replace "\x1b\[[0-9;]*[A-Za-z]", '' })
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        }
        $errs = @($lines | Where-Object { $_ -match '^\s*(SCRIPT ERROR|SHADER ERROR|Parse Error|ERROR|USER ERROR)\b' })
        if ($errs.Count -gt 0) {
            Add-Line $errLog "### $scene / $q"
            # keep the line after each error too (Godot prints the source location there)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*(SCRIPT ERROR|SHADER ERROR|Parse Error|ERROR|USER ERROR)\b') {
                    Add-Line $errLog $lines[$i]
                    if ($i + 1 -lt $lines.Count) { Add-Line $errLog $lines[$i + 1] }
                }
            }
            Write-Host "   $($errs.Count) error line(s) -> $errLog"
        }
        $row = $lines | Where-Object { $_ -match '^perf: ' -and $_ -notmatch '^perf: label,' -and $_ -match ',' } | Select-Object -Last 1
        if (-not $row) { Write-Host "   !! no result row (exit $($p.ExitCode))" }
        Add-Line $memCsv "$Label,$scene,$q,$([Math]::Round($peak / 1MB)),$([Math]::Round($priv / 1MB)),$wall,$($p.ExitCode),$($errs.Count)"
    }
}

# Table: this label's rows joined with the memory rows.
$rows = @(Import-Csv -LiteralPath $Out | Where-Object { $_.label -eq $Label })
$mem = @(Import-Csv -LiteralPath $memCsv | Where-Object { $_.label -eq $Label })
$table = foreach ($r in $rows) {
    $sceneName = if ($r.target -eq 'sandbox') { $r.minigame } else { $r.target }
    $m = $mem | Where-Object { $_.scene -eq $sceneName -and $_.quality -eq $r.quality } | Select-Object -Last 1
    [pscustomobject]@{
        scene = $sceneName; quality = $r.quality; avg_ms = $r.avg_ms; low1_ms = $r.low1_ms; gpu_ms = $r.gpu_ms
        cpu_ms = $r.cpu_render_ms; draws = $r.draw_calls; prims = $r.primitives; vram = $r.vram_mb
        ram = if ($m) { $m.peak_ws_mb } else { '' }; start_ms = $r.startup_ms
    }
}
$table | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "perf-run: CSV -> $Out (memory: $memCsv)"
exit 0
