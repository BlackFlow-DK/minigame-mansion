# Ghost Tag multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), five roster bots fill to 8 (two starting ghosts), one Session round of Ghost Tag
# with every blob driven by a bot brain. Each actor (ghost_net.gd) writes what it saw to
# build/ghost-net/<stamp>/<name>.json. Asserts all three peers saw the same conversion timeline
# (the wake, every catch with its round time, every turn, the end, in order) with the ghost look
# on the same slots at every step, and the same final ranking and tied groups (all eight slots
# exactly once), and that no actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\ghost_tag\dev\run_ghost_net.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 150, [double]$TimeScale = 2.5, [double]$GhostTimeScale = 1)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\ghost-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/ghost_tag/dev/ghost_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=240',
        "--time-scale=$TimeScale", "--ghost-time-scale=$GhostTimeScale") + $Extra
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) ghosts=$($s.ghosts -join ',')"
            Write-Host "     timeline=$($s.timeline -join ' | ')"
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
    throw "ghost-net step failed: $Desc"
}

# "... looks=[1, 4]" -> @(1, 4)
function Get-Slots([string]$Text) {
    $inner = $Text.Trim().TrimStart('[').TrimEnd(']')
    return @($inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
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
    foreach ($k in 1..5) { Send-Cmd 'Host' 'bot' }
    Wait-For 'bots fill the roster to 8 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 8 }).Count -eq 3 }

    Send-Cmd 'Host' 'session 1'
    Wait-For 'Ghost Tag round intro on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:0:ghost_tag' }).Count -eq 3
    }
    Wait-For 'the ghosts wake on every peer' {
        @($All | Where-Object { @((Read-State $_).timeline | Where-Object { $_ -like 'woke*' }).Count -ge 1 }).Count -eq 3
    }
    Wait-For 'round finished on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3
    } $RoundTimeoutSec

    $line = @($All | ForEach-Object { (@((Read-State $_).timeline) -join ' | ') })
    $rank = @($All | ForEach-Object { ((Read-State $_).rankings | ConvertTo-Json -Compress -Depth 5) })
    $grp = @($All | ForEach-Object { ((Read-State $_).groups | ConvertTo-Json -Compress -Depth 6) })
    $tl = @((Read-State 'Host').timeline)
    Write-Host "  host timeline ($($tl.Count) steps):"
    $tl | ForEach-Object { Write-Host "    $_" }
    Write-Host "  rankings: $($rank -join ' | ')"
    Write-Host "  groups: $($grp[0])"
    if (@($line | Select-Object -Unique).Count -ne 1) {
        $All | ForEach-Object { Write-Host "  $_ : $(@((Read-State $_).timeline) -join ' | ')" }
        throw 'conversion timelines (or ghost looks) differ between peers'
    }
    $catches = @($tl | Where-Object { $_ -like 'catch:*' })
    $turns = @($tl | Where-Object { $_ -like 'turn:*' })
    if ($catches.Count -lt 1) { throw 'no catch happened: nothing to compare' }
    # every turned slot wears the ghost look at its turn step (the lines are identical on all peers)
    foreach ($t in $turns) {
        $slot = [int](($t -split ' ')[0] -replace 'turn:', '')
        $looks = Get-Slots (($t -split 'looks=')[1])
        if ($looks -notcontains $slot) { throw "slot $slot turned but does not look like a ghost: $t" }
    }
    $woke = @($tl | Where-Object { $_ -like 'woke*' })[0]
    $orig = Get-Slots ((($woke -split 'ghosts=')[1] -split ' looks=')[0])
    $wlooks = Get-Slots (($woke -split 'looks=')[1])
    if ($orig.Count -ne 2) { throw "8 players should start with 2 ghosts: $woke" }
    if (($wlooks -join ',') -ne ($orig -join ',')) { throw "starting ghosts $($orig -join ',') but ghost looks on $($wlooks -join ','): $woke" }
    $over = @($tl | Where-Object { $_ -like 'over:*' })[0]
    if ((Get-Slots (($over -split 'looks=')[1])).Count -ne 0) { throw "ghost looks left after the round: $over" }
    Write-Host "PASS every peer saw the same $($catches.Count) catches and $($turns.Count) turns in the same order, ghost looks on the same slots, all restored at the end"
    if (@($rank | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    if (@($grp | Select-Object -Unique).Count -ne 1) { throw 'tied groups differ between peers' }
    $r = @((Read-State 'Host').rankings[0])
    if ($r.Count -ne 8 -or @($r | Select-Object -Unique).Count -ne 8) { throw "ranking is not 8 distinct slots: $($r -join ',')" }
    foreach ($s in 0..7) { if ($r -notcontains $s) { throw "slot $s missing from ranking $($r -join ',')" } }
    Write-Host "PASS identical ranking and tied groups on all peers: $($r -join ',') $($grp[0])"

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
    Write-Host "ghost-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'ghost-net: OK' } else { Write-Host 'ghost-net: FAILED' }
exit $exit
