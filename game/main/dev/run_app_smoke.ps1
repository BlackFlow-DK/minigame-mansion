# Full-game multi-process smoke test: one headless host and two headless clients on this PC
# (127.0.0.1), each running the REAL main scene (game/main/dev/app_smoke.tscn wraps it and
# drives its menus). Each actor writes what its app shows to build/app-smoke/<stamp>/<name>.json;
# this runner drives them through command files (<name>.cmd.<seq>) and asserts:
#   host + a bot in the lobby; Alice finds the game by LAN discovery, Bob joins by address;
#   all three see 3 humans + 1 bot, Alice (who joins wearing body size small) small on every
#   peer, at agreeing positions after scripted walking; the host
#   starts a 2-round session from the overlay (round 1 is -FirstRound, default bumper_sumo);
#   on every peer each round's minigame is the one Session set up and started, with the same
#   players and tuning, and round 1 ends with the same host-decided state (sumo rings);
#   all reach the podium with identical scores;
#   the host's "Back to lobby" returns everyone to the hall (podiums close by themselves); Bob leaves and is gone everywhere;
#   the host quits and Alice lands on the title screen with the message.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\main\dev\run_app_smoke.ps1 [-Port 24605]
# Exit 0 when every check passes. Always kills the processes it started.
# -AllowError <regex>: log lines matching it do not fail the run (a known bug owned elsewhere).
param([int]$Port = 24605, [int]$StepTimeoutSec = 25, [double]$TimeScale = 10, [double]$RoundTime = 25, [string]$AllowError = '', [string]$FirstRound = 'bumper_sumo')
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\app-smoke\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra = @()) {
    $argList = @('--headless', '--path', $GameDir, 'res://main/dev/app_smoke.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=240',
        "--time-scale=$TimeScale", "--round-time=$RoundTime") + $Extra
    $p = Start-Process -FilePath $godot -ArgumentList (ConvertTo-ArgString $argList) -NoNewWindow -PassThru `
        -WorkingDirectory $Root -RedirectStandardOutput (Join-Path $Dir "$Name.out") -RedirectStandardError (Join-Path $Dir "$Name.err")
    $null = $p.Handle
    $script:Procs[$Name] = $p
    Write-Host "started $Name (pid $($p.Id))"
}

# The actor rewrites <name>.json ten times a second (truncate, then write), so a read can
# catch it empty or half-written: retry for up to ~0.5 s before giving up with $null. A
# bare $null used to slip through as "1 element" in @($s.list) checks.
function Read-State([string]$Name) {
    $f = Join-Path $Dir "$Name.json"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $s = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $s) { return $s }
        } catch { }
        Start-Sleep -Milliseconds 25
    }
    return $null
}

# Command handoff: one file per command, written under a temp name and renamed into place
# (atomic), so the actor never sees a half-written command and runner and actor never hold
# the same file (the old shared <name>.cmd, appended here while the actor read it, hit
# "file is being used by another process"). The actor deletes each file after reading it;
# <name>.cmdlog keeps the record.
$script:CmdSeq = 0
function Send-Cmd([string]$Name, [string]$Line) {
    $script:CmdSeq += 1
    $final = Join-Path $Dir ('{0}.cmd.{1}' -f $Name, $script:CmdSeq)
    $tmp = "$final.tmp"
    [System.IO.File]::WriteAllText($tmp, $Line)
    $deadline = (Get-Date).AddSeconds(2)
    while ($true) {
        try { [System.IO.File]::Move($tmp, $final); break }
        catch {
            if ((Get-Date) -gt $deadline) { throw "could not hand '$Line' to ${Name}: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 50
        }
    }
    Add-Content -LiteralPath (Join-Path $Dir "$Name.cmdlog") -Value $Line -Encoding Ascii
    Write-Host "cmd $Name <- $Line"
}

function Show-States([string[]]$Names) {
    foreach ($n in $Names) {
        $s = Read-State $n
        if ($s) {
            $ps = @($s.players.PSObject.Properties | ForEach-Object {
                    "$($_.Name):($('{0:N2}' -f $_.Value.x),$('{0:N2}' -f $_.Value.z)) frozen=$($_.Value.frozen)" })
            Write-Host "  $n slot=$($s.local_slot) screen=$($s.screen) state=$($s.session_state) view=$($s.round_view) roster=$($s.roster_size) scene=$($s.scene) players=[$($ps -join '; ')]"
            Write-Host "     msg='$($s.message)' events=$(($s.events | Select-Object -Last 6) -join ',')"
        }
    }
}

# Every check: its name, how long it took, and on failure the reason. Written to
# <logdir>/result.txt whatever happens (with every actor's last state).
$script:Check = '(setup)'
$script:Passed = @()

function Wait-For([string]$Desc, [scriptblock]$Cond, [int]$Timeout = $StepTimeoutSec) {
    $script:Check = $Desc
    $start = Get-Date
    $deadline = $start.AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try { $ok = [bool](& $Cond) } catch { $ok = $false }
        if ($ok) {
            $took = ((Get-Date) - $start).TotalSeconds
            $script:Passed += ('PASS {0} ({1:N1} s)' -f $Desc, $took)
            Write-Host ('PASS {0} ({1:N1} s)' -f $Desc, $took)
            $script:Check = "(after: $Desc)"
            return
        }
        Start-Sleep -Milliseconds 200
    }
    Show-States @($script:Procs.Keys)
    throw "not true within $Timeout s"
}

# A check done inline (not by Wait-For): names it for the result file, throws with the reason.
function Assert-Check([string]$Desc, [bool]$Ok, [string]$Reason) {
    $script:Check = $Desc
    if (-not $Ok) { throw $Reason }
    $script:Passed += "PASS $Desc"
    Write-Host "PASS $Desc"
    $script:Check = "(after: $Desc)"
}

function Write-Result([string]$Status, [string]$Reason) {
    $lines = @("app-smoke: $Status")
    if ($Status -ne 'OK') { $lines += "FAIL ${script:Check}: $Reason" }
    $lines += '' ; $lines += $script:Passed
    foreach ($n in $script:Procs.Keys) {
        $f = Join-Path $Dir "$n.json"
        $lines += ''; $lines += "--- $n (exited: $($script:Procs[$n].HasExited))"
        if (Test-Path -LiteralPath $f) { $lines += (Get-Content -LiteralPath $f -Raw) }
    }
    Set-Content -LiteralPath (Join-Path $Dir 'result.txt') -Value $lines -Encoding UTF8
}

function Get-Player([string]$Name, [int]$Slot) {
    $s = Read-State $Name
    if ($null -eq $s) { return $null }
    return $s.players."$Slot"
}

function Get-PlayerCount([string]$Name) {
    $s = Read-State $Name
    if ($null -eq $s) { return -1 }
    return @($s.players.PSObject.Properties).Count
}

# Every actor sees every slot in $Slots, all at the same place (within $Tol metres, XZ).
function Test-Positions([string[]]$Names, [int[]]$Slots, [double]$Tol) {
    foreach ($slot in $Slots) {
        $ref = $null
        foreach ($n in $Names) {
            $p = Get-Player $n $slot
            if ($null -eq $p) { return $false }
            if ($null -eq $ref) { $ref = $p; continue }
            $d = [math]::Sqrt([math]::Pow($p.x - $ref.x, 2) + [math]::Pow($p.z - $ref.z, 2))
            if ($d -gt $Tol) { return $false }
        }
    }
    return $true
}

function Test-All([string[]]$Names, [scriptblock]$Cond) {
    foreach ($n in $Names) {
        $s = Read-State $n
        if ($null -eq $s -or -not (& $Cond $s)) { return $false }
    }
    return $true
}

$Lobby = 'res://lobby/lobby.tscn'
$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    # 1. Host from the title screen, plus a bot from the overlay: the hall loads with both.
    Start-Actor 'Host'
    Wait-For 'host app ready' { (Read-State 'Host').events -contains 'ready' }
    Send-Cmd 'Host' 'host'
    Wait-For 'host in the lobby (overlay, hall loaded, 1 player)' {
        $s = Read-State 'Host'; $s.screen -eq 'lobby' -and $s.scene -eq $Lobby -and $s.follow_roster -and (Get-PlayerCount 'Host') -eq 1
    }
    Send-Cmd 'Host' 'addbot'
    Wait-For 'bot spawned in the hall' { (Get-PlayerCount 'Host') -eq 2 -and (Read-State 'Host').roster_size -eq 2 }

    # 2. Alice finds the game by LAN discovery; Bob joins by address.
    Start-Actor 'Alice' @('--size=small')
    Wait-For 'Alice app ready' { (Read-State 'Alice').events -contains 'ready' }
    Send-Cmd 'Alice' 'discover'
    Wait-For 'Alice discovered the host (other LAN games may be listed too)' { (@((Read-State 'Alice').game_ports) -contains $Port) -and (Read-State 'Alice').screen -eq 'join' }
    Send-Cmd 'Alice' "join_found $Port"
    Wait-For 'Alice joined (lobby screen, slot >= 1)' { $s = Read-State 'Alice'; $s.local_slot -ge 1 -and $s.screen -eq 'lobby' }
    Start-Actor 'Bob'
    Wait-For 'Bob app ready' { (Read-State 'Bob').events -contains 'ready' }
    Send-Cmd 'Bob' "join 127.0.0.1:$Port"
    Wait-For 'Bob joined (lobby screen, slot >= 1)' { $s = Read-State 'Bob'; $s.local_slot -ge 1 -and $s.screen -eq 'lobby' }
    $A = [int](Read-State 'Alice').local_slot
    $B = [int](Read-State 'Bob').local_slot
    $Bot = [int](@((Read-State 'Host').roster.PSObject.Properties | Where-Object { $_.Value.bot })[0].Name)
    Write-Host "  slots: Host=0 Alice=$A Bob=$B Bot=$Bot"
    $Humans = @(0, $A, $B)

    # 3. Everyone sees 3 humans + 1 bot in the hall, unfrozen; positions agree after walking.
    Wait-For 'all three see the hall with 3 humans + 1 bot, all unfrozen' {
        Test-All $All { param($s)
            $ps = @($s.players.PSObject.Properties)
            $s.scene -eq $Lobby -and $s.roster_size -eq 4 -and $ps.Count -eq 4 -and
            @($ps | Where-Object { $_.Value.bot }).Count -eq 1 -and @($ps | Where-Object { $_.Value.frozen }).Count -eq 0 -and
            $s.overlay_visible
        }
    }
    Wait-For 'every player has its own colour (all peers)' {
        Test-All $All { param($s) @($s.roster.PSObject.Properties | ForEach-Object { $_.Value.primary } | Where-Object { $_ -ne '' } | Select-Object -Unique).Count -eq 4 }
    }
    # Alice joined wearing size small: every peer shows her small (model and capsule), the others normal.
    Wait-For 'Alice''s body size (small) reaches the host and Bob: scale 0.82, capsule 0.328' {
        Test-All $All { param($s)
            $a = $s.players."$A"; $b = $s.players."$B"
            $a.size -eq 'small' -and [math]::Abs($a.scale - 0.82) -lt 0.005 -and [math]::Abs($a.radius - 0.328) -lt 0.001 -and
            $b.size -eq 'normal' -and [math]::Abs($b.scale - 1.0) -lt 0.005 -and [math]::Abs($b.radius - 0.4) -lt 0.001
        }
    }
    Send-Cmd 'Alice' 'walk 0 1 0.8'
    Send-Cmd 'Bob' 'walk 1 0.3 0.6'
    Wait-For 'walks done' { (Read-State 'Alice').walks_done -ge 1 -and (Read-State 'Bob').walks_done -ge 1 }
    Start-Sleep -Milliseconds 1000
    Wait-For 'all peers agree on the humans (0.15 m) and the bot (1.5 m)' { (Test-Positions $All $Humans 0.15) -and (Test-Positions $All @($Bot) 1.5) }
    Show-States $All

    # 4. The host starts a 2-round session from the overlay; round 1 has knock-outs.
    Send-Cmd 'Host' 'podium_time 600'
    Send-Cmd 'Host' "first_round $FirstRound"
    Send-Cmd 'Host' 'start 2'
    Wait-For 'round 1 playing everywhere, overlay hidden, same minigame' {
        $scene = (Read-State 'Host').scene
        $scene -ne $Lobby -and (Test-All $All { param($s) $s.session_state -eq 2 -and $s.round_index -eq 0 -and $s.scene -eq $scene -and
                -not $s.overlay_visible -and $s.in_progress -and -not $s.follow_roster -and @($s.players.PSObject.Properties).Count -eq 4 })
    }
    Send-Cmd 'Host' "knockout $B"
    Send-Cmd 'Host' "knockout $Bot"
    Wait-For 'podium on all three' { Test-All $All { param($s) $s.session_state -eq 4 -and $s.round_view -eq 4 -and ($s.events -contains 'session_finished') } } 60
    $scores = @($All | ForEach-Object { ((Read-State $_).final_scores | ConvertTo-Json -Compress) })
    $rounds = @($All | ForEach-Object { ((Read-State $_).rounds | ConvertTo-Json -Compress -Depth 5) })
    Write-Host "  final scores: $($scores -join ' | ')"
    $script:Check = 'identical scores and rounds on all peers'
    if (@($scores | Select-Object -Unique).Count -ne 1) { throw 'final scores differ between peers' }
    if (@($rounds | Select-Object -Unique).Count -ne 1) { throw 'round results differ between peers' }
    if (@((Read-State 'Host').rounds).Count -ne 2) { throw 'expected 2 rounds' }
    Write-Host 'PASS identical scores and rounds on all peers'
    Write-Host "  rounds played: $(@((Read-State 'Host').rounds | ForEach-Object { $_.scene }) -join ', ')"
    $script:Check = 'every peer: each round''s minigame got _setup/_start from Session'
    if ((Read-State 'Host').rounds[0].scene -notmatch $FirstRound) { throw "round 1 was not $FirstRound" }
    foreach ($n in $All) {
        $s = Read-State $n
        if ($null -eq $s) { throw "${n}: state file unreadable" }
        $starts = @($s.round_starts)
        if ($starts.Count -ne 2) { throw "${n}: expected 2 round starts, got $($starts.Count)" }
        foreach ($r in $starts) {
            if (-not $r.cm_ok) { throw "${n}: round $($r.index) minigame is not the one Session set up and started" }
            if ($r.players -ne 4) { throw "${n}: round $($r.index) minigame has $($r.players) players" }
        }
        foreach ($r in @($s.rounds)) { if (-not $r.cm_ok) { throw "${n}: a round ended on a minigame Session did not drive" } }
    }
    Write-Host 'PASS every peer: each round''s minigame got _setup/_start from Session (4 players)'
    $tunings = @($All | ForEach-Object { ((Read-State $_).round_starts | ConvertTo-Json -Compress -Depth 5) })
    $script:Check = 'same minigames, players and tuning at every round start'
    if (@($tunings | Select-Object -Unique).Count -ne 1) { throw "round-start tuning differs between peers: $($tunings -join ' | ')" }
    Write-Host "PASS same minigames, players and tuning at every round start on all peers"
    $states = @($All | ForEach-Object { (Read-State $_).rounds[0].mg_state })
    Write-Host "  round 1 end state: $($states -join ' | ')"
    $script:Check = 'round 1 host-decided state identical on all peers'
    if (@($states | Select-Object -Unique).Count -ne 1) { throw 'round 1 host-decided state differs between peers' }
    if ($FirstRound -eq 'bumper_sumo' -and $states[0] -notmatch '2') { throw 'no sumo ring dropped in round 1 (nothing compared)' }
    Write-Host 'PASS round 1 host-decided state identical on all peers'

    # 5. Host: Back to lobby. Everyone is in the hall again; every podium closes by itself.
    Send-Cmd 'Host' 'back'
    Wait-For 'everyone back in the hall (4 unfrozen players), session over' {
        Test-All $All { param($s)
            $ps = @($s.players.PSObject.Properties)
            $s.session_state -eq 0 -and $s.scene -eq $Lobby -and $ps.Count -eq 4 -and -not $s.in_progress -and
            @($ps | Where-Object { $_.Value.frozen }).Count -eq 0
        }
    }
    Wait-For 'podium closed and lobby overlay back on all three (no client presses anything)' {
        Test-All $All { param($s) $s.screen -eq 'lobby' -and $s.round_view -eq 0 -and $s.overlay_visible }
    }

    # 6. Bob leaves from the overlay: gone everywhere.
    Send-Cmd 'Bob' 'leave'
    Wait-For 'Bob is on the title screen with an empty world' { $s = Read-State 'Bob'; $s.screen -eq 'title' -and (Get-PlayerCount 'Bob') -eq 0 -and $s.roster_size -eq 0 }
    Wait-For 'Bob removed on host and Alice' {
        Test-All @('Host', 'Alice') { param($s) $s.roster_size -eq 3 -and @($s.players.PSObject.Properties).Count -eq 3 -and $null -eq $s.players."$B" }
    }
    Send-Cmd 'Bob' 'quit'

    # 6b. Carl joins, then his PC "drops" (process killed, no goodbye): the short ENet
    # timeout removes his blob everywhere within a few seconds (no frozen ghost).
    Start-Actor 'Carl'
    Wait-For 'Carl app ready' { (Read-State 'Carl').events -contains 'ready' }
    Send-Cmd 'Carl' "join 127.0.0.1:$Port"
    Wait-For 'Carl in the hall on host and Alice' { Test-All @('Host', 'Alice') { param($s) $s.roster_size -eq 4 -and @($s.players.PSObject.Properties).Count -eq 4 } }
    $C = [int](Read-State 'Carl').local_slot
    # Through cmd: taskkill's stderr (e.g. "child process could not be terminated" for a
    # console host already on its way out) must not become a PowerShell error under Stop.
    & cmd.exe /c "taskkill /PID $($script:Procs['Carl'].Id) /T /F >nul 2>&1"
    $killedAt = Get-Date
    Wait-For 'Carl process gone' { $script:Procs['Carl'].HasExited } 10
    # ENet only checks its 6 s timeout when a retransmit timer expires, and those back off
    # (doubling), so on loopback removal lands anywhere in ~7-13 s (measured). 20 s still
    # proves the short timeout: ENet's defaults take up to 30 s.
    Wait-For 'dropped Carl removed on host and Alice within 20 s' {
        Test-All @('Host', 'Alice') { param($s) $s.roster_size -eq 3 -and $null -eq $s.players."$C" }
    } 20
    Write-Host ("  ghost gone after {0:N1} s" -f ((Get-Date) - $killedAt).TotalSeconds)

    # 7. The host quits: Alice lands on the title screen with the message.
    Send-Cmd 'Host' 'quit'
    Wait-For 'Alice on the title screen with the message, world empty' {
        $s = Read-State 'Alice'
        $s.screen -eq 'title' -and $s.message -match 'closed' -and (Get-PlayerCount 'Alice') -eq 0 -and $s.session_state -eq 0 -and $s.round_view -eq 0
    }
    Write-Host "  Alice sees: '$((Read-State 'Alice').message)'"
    Send-Cmd 'Alice' 'quit'
    Wait-For 'every process exited on its own' { @($script:Procs.Values | Where-Object { -not $_.HasExited }).Count -eq 0 }

    $script:Check = 'no error lines in actor logs'
    $bad = @()
    foreach ($n in $script:Procs.Keys) {
        foreach ($f in @("$n.out", "$n.err")) {
            $path = Join-Path $Dir $f
            if (Test-Path -LiteralPath $path) {
                $bad += @(Get-Content -LiteralPath $path | ForEach-Object { $_ -replace "\x1b\[[0-9;]*[A-Za-z]", '' } |
                    Where-Object { $_ -match $GodotErrorPattern -and ($AllowError -eq '' -or $_ -notmatch $AllowError) } | ForEach-Object { "${n}: $_" })
            }
        }
    }
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { Write-Host "  $_" }
        throw 'error lines in actor logs'
    }
    Write-Host 'PASS no error lines in actor logs'
    $exit = 0
    Write-Result 'OK' ''
} catch {
    Write-Host "FAIL ${script:Check}: $($_.Exception.Message)"
    Write-Result 'FAILED' $_.Exception.Message
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
if ($exit -eq 0) { Write-Host 'app-smoke: OK' } else { Write-Host 'app-smoke: FAILED' }
exit $exit
