# Crown Keeper multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a roster bot fills to 4, one Session round of Crown Keeper with every blob driven
# by a bot brain. Each actor (crown_net.gd) writes what it saw to
# build/crown-net/<stamp>/<name>.json. Asserts all three peers saw the same crown timeline
# (every pickup, every knock-off with its landing spot, every return, in order), that each
# peer's own crown came to rest exactly on the host's landing spot after every flight it saw
# land, the same final points and the same ranking (all four slots exactly once, following
# the points), and that no actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\crown_keeper\dev\run_crown_net.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 150, [double]$TimeScale = 2, [double]$CrownTimeScale = 1)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\crown-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/crown_keeper/dev/crown_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=240',
        "--time-scale=$TimeScale", "--crown-time-scale=$CrownTimeScale") + $Extra
    $p = Start-Process -FilePath $godot -ArgumentList (ConvertTo-ArgString $argList) -NoNewWindow -PassThru `
        -WorkingDirectory $Root -RedirectStandardOutput (Join-Path $Dir "$Name.out") -RedirectStandardError (Join-Path $Dir "$Name.err")
    $null = $p.Handle
    $script:Procs[$Name] = $p
    Write-Host "started $Name (pid $($p.Id)) $($Extra -join ' ')"
}

function Read-State([string]$Name) {
    $f = Join-Path $Dir "$Name.json"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { return $null }
}

function Send-Cmd([string]$Name, [string]$Line) {
    Add-Content -LiteralPath (Join-Path $Dir "$Name.cmd") -Value $Line -Encoding Ascii
    Write-Host "cmd $Name <- $Line"
}

function Show-States([string[]]$Names) {
    foreach ($n in $Names) {
        $s = Read-State $n
        if ($s) {
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) holder=$($s.holder)"
            Write-Host "     timeline=$(@($s.timeline) -join ' ')"
            Write-Host "     events=$(($s.events | Select-Object -Last 6) -join ',')"
        }
    }
}

function Wait-For([string]$Desc, [scriptblock]$Cond, [int]$Timeout = $StepTimeoutSec) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try { $ok = [bool](& $Cond) } catch { $ok = $false }
        if ($ok) { Write-Host "PASS $Desc"; return }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "FAIL $Desc"
    Show-States @($script:Procs.Keys)
    throw "crown-net step failed: $Desc"
}

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 }).Count -eq 3 -and (Read-State 'Bob').local_slot -ge 1 }
    Send-Cmd 'Host' 'bot'
    Wait-For 'a bot fills the roster to 4 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }

    Send-Cmd 'Host' 'session 1'
    Wait-For 'Crown Keeper round intro on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:0:crown_keeper' }).Count -eq 3
    }
    Wait-For 'first pickup on every peer' {
        @($All | Where-Object { @((Read-State $_).timeline).Count -ge 1 }).Count -eq 3
    } 60
    Wait-For 'round finished on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3
    } $RoundTimeoutSec

    $line = @($All | ForEach-Object { (@((Read-State $_).timeline) -join ' ') })
    $rank = @($All | ForEach-Object { ((Read-State $_).rankings | ConvertTo-Json -Compress -Depth 5) })
    $host_line = @((Read-State 'Host').timeline)
    $wears = @($host_line | Where-Object { $_ -like 'wear:*' }).Count
    $knocks = @($host_line | Where-Object { $_ -like 'knock:*' })
    Write-Host "  host timeline ($($host_line.Count) entries, $wears pickups, $($knocks.Count) knock-offs): $($line[0])"
    Write-Host "  rankings: $($rank -join ' | ')"
    if (@($line | Select-Object -Unique).Count -ne 1) {
        $All | ForEach-Object { Write-Host "  $_ : $(@((Read-State $_).timeline) -join ' ')" }
        throw 'crown timelines differ between peers'
    }
    if ($wears -lt 2) { throw "only $wears pickup(s): too few to compare" }
    Write-Host 'PASS every peer saw the same pickups, knock-offs (landing spots) and returns in the same order'

    # Each peer's own crown rested exactly on the host's landing spot of that knock-off.
    $lands = @{}
    $i = 0
    foreach ($k in $knocks) {
        $i += 1
        $xyz = ($k -split '@')[1] -split ','
        $lands[$i] = "{0},{1}" -f $xyz[0], $xyz[2]
    }
    $checked = 0
    foreach ($n in $All) {
        foreach ($r in @((Read-State $n).rests)) {
            $parts = $r -split '@'
            $want = $lands[[int]$parts[0]]
            if ($parts[1] -ne $want) { throw "$n crown rested at $($parts[1]) after knock-off $($parts[0]), host sent $want" }
            $checked += 1
        }
    }
    Write-Host "PASS every peer's crown came to rest on the host's landing spot ($checked rests checked)"

    $fin = @($All | ForEach-Object { (@((Read-State $_).final_scores) -join ' ') })
    if (@($fin | Select-Object -Unique).Count -ne 1) { throw "final points differ: $($fin -join ' | ')" }
    if (@($rank | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $r = @((Read-State 'Host').rankings[0])
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($r -join ',')" }
    foreach ($s in 0..3) { if ($r -notcontains $s) { throw "slot $s missing from ranking $($r -join ',')" } }
    $order = @((Read-State 'Host').final_scores | ForEach-Object { [int](($_ -split ':')[0]) })
    if (($order -join ',') -ne ($r -join ',')) { throw "ranking $($r -join ',') does not follow the points $($fin[0])" }
    Write-Host "PASS identical points ($($fin[0])) and ranking on all peers: $($r -join ',')"

    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 }
    Send-Cmd 'Host' 'quit'
    Wait-For 'clients get server_closed' { @('Alice', 'Bob' | Where-Object { (Read-State $_).events -contains 'server_closed' }).Count -eq 2 }
    Wait-For 'every process exited on its own' { @($script:Procs.Values | Where-Object { -not $_.HasExited }).Count -eq 0 }

    $bad = @()
    foreach ($n in $script:Procs.Keys) {
        foreach ($f in @("$n.out", "$n.err")) {
            $path = Join-Path $Dir $f
            if (Test-Path -LiteralPath $path) {
                $bad += @(Get-Content -LiteralPath $path | ForEach-Object { $_ -replace "\x1b\[[0-9;]*[A-Za-z]", '' } |
                    Where-Object { $_ -match $GodotErrorPattern } | ForEach-Object { "${n}: $_" })
            }
        }
    }
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { Write-Host "  $_" }
        throw 'error lines in actor logs'
    }
    Write-Host 'PASS no error lines in actor logs'
    $exit = 0
} catch {
    Write-Host "crown-net: $($_.Exception.Message)"
} finally {
    $ErrorActionPreference = 'Continue'
    foreach ($n in $script:Procs.Keys) {
        $p = $script:Procs[$n]
        if (-not $p.HasExited) {
            Write-Host "killing leftover $n (pid $($p.Id))"
            & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        }
    }
    Write-Host "logs: $Dir"
}
if ($exit -eq 0) { Write-Host 'crown-net: OK' } else { Write-Host 'crown-net: FAILED' }
exit $exit
