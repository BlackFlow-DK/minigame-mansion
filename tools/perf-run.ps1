# Frame-time / render-stats runs of the real game, windowed, through game/tools/perf/perf_driver.tscn.
# Each run: one scene at one quality, warm up, measure, append a row to the CSV, quit. Prints a table.
#
# Usage: tools/perf-run.ps1 [-Scenes title,lobby,dev_arena,bumper_sumo,...] [-Qualities low,medium,high]
#          [-Seconds 10] [-Warmup 3] [-Players 8] [-Resolution 1280x720] [-Label after]
#          [-Out build\perf\after.csv] [-Throttle] [-Exe build\windows\perf.exe] [-Shots]
#   -Scenes     title | lobby | podium | vote | dev_arena | any MinigameRegistry id (default: all
#               of them, the ids read from game/minigames/registry.gd). podium = the 3D podium
#               after a 1-round session of -PodiumGame; vote = the VOTE cards over the lobby hall.
#   -Transitions  instead of frame times: per quality, one offline 8-player playlist session
#               through every minigame (or -Scenes' minigame ids); rows of stage load -> first
#               frame and the worst frame of the next 2 s go to build\perf\<label>.load.csv
#   -ListScenes print the default scene list, one per line, and exit (nothing runs)
#   -Throttle   weak-PC CPU proxy: the process is pinned to 2 logical cores at below-normal priority
#   -Exe        run an exported DEBUG build (export-windows.ps1 -DebugBuild) instead of the editor binary;
#               release templates refuse a scene path on the command line
#   -Shots      also save a PNG per run to build\perf\shots\<label>_<scene>_<quality>.png
#   -Release X  release exe X (export-windows.ps1): launch-to-title-drawn time -Runs times (the
#               PNG of `-- --screenshot --frames=2` appearing), exe size, and the peak working set
#               of one offline 8-player session (-SessionSeconds) -> build\perf\release.log
#   -GameDirOverride X  run the project in X instead of this checkout's game\ (A/B baselines)
#   -Census     also write RenderCensus (lights, surfaces, shadow casters, outlines per node, see
#               game/look/render_census.gd) to build\perf\<label>_census.log
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
    [string[]]$ExtraArgs = @(),
    [switch]$ListScenes,
    [switch]$Transitions,
    [switch]$Census,
    [string]$PodiumGame = 'bumper_sumo',
    [string]$Release = '',
    [int]$Runs = 3,
    [double]$SessionSeconds = 120,
    [string]$GameDirOverride = ''
)
. "$PSScriptRoot\_common.ps1"
# -GameDirOverride: measure another copy of the project (A/B against a baseline, e.g. main's
# game/ exported with `git archive` into build\, plus this branch's game/tools/perf/).
if ($GameDirOverride -ne '') { $GameDir = [System.IO.Path]::GetFullPath($GameDirOverride) }

# Default: title, lobby, dev_arena, then every MinigameRegistry.IDS entry (parsed from
# game/minigames/registry.gd), so a new minigame is measured without editing this script.
function Get-RegistryIds {
    $registry = Join-Path $GameDir 'minigames\registry.gd'
    $line = Get-Content -LiteralPath $registry | Where-Object { $_ -match '^\s*const\s+IDS\b' } | Select-Object -First 1
    if (-not $line) { throw "perf-run: no 'const IDS' in $registry" }
    return @([regex]::Matches($line, '&"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
}
$RegistryIds = @(Get-RegistryIds)
$AllScenes = @('title', 'lobby', 'podium', 'vote', 'dev_arena') + $RegistryIds
if ($ListScenes) { $AllScenes | ForEach-Object { Write-Output $_ }; exit 0 }
# PowerShell -File passes "a,b" as one string: split it.
$Scenes = @($Scenes | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$Qualities = @($Qualities | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Transitions) {
    $ids = @($Scenes | Where-Object { $RegistryIds -contains $_ })
    if ($ids.Count -eq 0) { $ids = $RegistryIds }
    $Scenes = @('transitions')
} elseif ($Scenes.Count -eq 0) { $Scenes = $AllScenes }

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
$loadCsv = [System.IO.Path]::ChangeExtension($Out, '.load.csv')
if ($Transitions) { $timeout = 60 + 25 * $ids.Count }

# Add-Content that retries while another process (a reader) holds the file.
function Add-Line([string]$Path, [string]$Text) {
    for ($try = 0; $try -lt 20; $try++) {
        try { Add-Content -LiteralPath $Path -Value $Text -Encoding ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 100 }
    }
    Write-Host "   !! could not append to $Path"
}

# Release exe: launch -> title drawn (AgentScreenshot at frame 2, then quit), -Runs times, and
# the peak working set over one offline 8-player session (3 short rounds + podium).
if ($Release -ne '') {
    if (-not [System.IO.Path]::IsPathRooted($Release)) { $Release = Join-Path $RepoRoot $Release }
    $exeMb = [Math]::Round((Get-Item -LiteralPath $Release).Length / 1MB, 1)
    $times = @()
    for ($r = 0; $r -lt $Runs; $r++) {
        $png = Join-Path $perfDir "startup_$r.png"
        Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $Release -ArgumentList (ConvertTo-ArgString @('--windowed', '--resolution', $Resolution, '--',
            "--screenshot=$png", '--frames=2')) -PassThru
        $null = $p.Handle
        while (-not (Test-Path -LiteralPath $png) -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 20 }
        $times += [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $null = $p.WaitForExit(20000)
        if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    }
    $sessionArgs = @('--windowed', '--resolution', $Resolution, '--', '--offline', '--name=Perf', "--bots=$($Players - 1)",
        '--auto-start=3', '--round-time=8', "--quality=$($Qualities[0])")
    $p = Start-Process -FilePath $Release -ArgumentList (ConvertTo-ArgString $sessionArgs) -PassThru
    $null = $p.Handle
    $peak = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $SessionSeconds) {
        try { $p.Refresh(); if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 } } catch {}
        Start-Sleep -Milliseconds 250
    }
    if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    $line = "$Label,startup_s=$($times -join '/'),exe_mb=$exeMb,session_peak_ws_mb=$([Math]::Round($peak / 1MB)),quality=$($Qualities[0])"
    Add-Line (Join-Path $perfDir 'release.log') $line
    Write-Host "perf-run: $line"
    exit 0
}

foreach ($scene in $Scenes) {
    foreach ($q in $Qualities) {
        $user = @("--perf-label=$Label", "--perf-out=$Out", "--perf-seconds=$Seconds", "--perf-warmup=$Warmup",
            "--quality=$q", '--fps=0')
        switch ($scene) {
            'title' { $user += @('--perf-target=title', '--name=Perf') }
            'lobby' { $user += @('--perf-target=lobby', '--name=Perf', '--offline', "--bots=$($Players - 1)") }
            'podium' {
                $user += @('--perf-target=podium', '--perf-wait=podium', '--name=Perf', '--offline', "--bots=$($Players - 1)",
                    '--auto-start=1', "--round-minigame=$PodiumGame", '--round-time=2', '--time-scale=6')
            }
            'vote' {
                $user += @('--perf-target=vote', '--perf-wait=vote', '--name=Perf', '--offline', "--bots=$($Players - 1)",
                    '--auto-start=1', '--order=vote')
            }
            'transitions' {
                $user += @('--perf-target=transitions', '--perf-transitions', "--perf-load-out=$loadCsv", '--name=Perf',
                    '--offline', "--bots=$($Players - 1)", "--auto-start=$($ids.Count)", '--order=playlist',
                    "--playlist=$($ids -join ',')", '--round-time=3', '--time-scale=4')
            }
            'dev_arena' { $user += @('--perf-target=sandbox', "--players=$Players") }
            default { $user += @('--perf-target=sandbox', "--minigame=$scene", "--players=$Players") }
        }
        if ($Shots) {
            $shot = Join-Path $perfDir "shots\$($Label)_$($scene)_$q.png"
            $user += "--perf-shot=$shot"
        }
        if ($Census) { $user += '--perf-census' }
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
        if ($Census) {
            Add-Line (Join-Path $perfDir "$($Label)_census.log") "### $scene / $q"
            $lines | Where-Object { $_ -match '^perf: census ' } | ForEach-Object { Add-Line (Join-Path $perfDir "$($Label)_census.log") ($_ -replace '^perf: census ', '') }
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
        w_ticks = $r.w_ticks; w_phys = $r.w_phys_total_ms; w_physscr = $r.w_phys_script_ms; w_proc = $r.w_proc_script_ms; w_rest = $r.w_rest_ms
    }
}
$table | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "perf-run: CSV -> $Out (memory: $memCsv)"
exit 0
