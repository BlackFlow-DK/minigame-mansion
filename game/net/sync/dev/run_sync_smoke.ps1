# Player-sync multi-process smoke test: one headless host and two headless clients on this PC
# (127.0.0.1). Each actor (game/net/sync/dev/sync_smoke.gd) writes what it sees to
# build/sync-smoke/<stamp>/<name>.json; this runner drives them through <name>.cmd files and
# asserts they agree: positions after a walk, a shove across clients, a host elimination, a
# full 2-round Session with identical scores, and a client quitting mid-round.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\net\sync\dev\run_sync_smoke.ps1 [-Port 24595]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24595, [int]$StepTimeoutSec = 20, [double]$TimeScale = 10)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\sync-smoke\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://net/sync/dev/sync_smoke.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=180',
        "--time-scale=$TimeScale") + $Extra
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
            $ps = @($s.players.PSObject.Properties | ForEach-Object {
                    "$($_.Name):($('{0:N2}' -f $_.Value.x),$('{0:N2}' -f $_.Value.y),$('{0:N2}' -f $_.Value.z)) alive=$($_.Value.alive) auth=$($_.Value.auth)" })
            Write-Host "  $n slot=$($s.local_slot) load=$($s.load_id) state=$($s.session_state) players=[$($ps -join '; ')]"
            Write-Host "     counts=$($s.counts | ConvertTo-Json -Compress) events=$(($s.events | Select-Object -Last 5) -join ',')"
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
    throw "smoke step failed: $Desc"
}

function Get-Player([string]$Name, [int]$Slot) {
    $s = Read-State $Name
    if ($null -eq $s) { return $null }
    return $s.players."$Slot"
}

function Get-Count([string]$Name, [string]$Key) {
    $s = Read-State $Name
    if ($null -eq $s -or $null -eq $s.counts.$Key) { return 0 }
    return [int]$s.counts.$Key
}

# Every actor sees every slot in $Slots, all at the same place (within $Tol metres).
function Test-Positions([string[]]$Names, [int[]]$Slots, [double]$Tol) {
    foreach ($slot in $Slots) {
        $ref = $null
        foreach ($n in $Names) {
            $p = Get-Player $n $slot
            if ($null -eq $p) { return $false }
            if ($null -eq $ref) { $ref = $p; continue }
            $d = [math]::Sqrt([math]::Pow($p.x - $ref.x, 2) + [math]::Pow($p.y - $ref.y, 2) + [math]::Pow($p.z - $ref.z, 2))
            if ($d -gt $Tol) { return $false }
        }
    }
    return $true
}

function Get-Dist($a, $b) { return [math]::Sqrt([math]::Pow($a.x - $b.x, 2) + [math]::Pow($a.z - $b.z, 2)) }

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 }).Count -eq 3 -and (Read-State 'Bob').local_slot -ge 1 }
    $A = [int](Read-State 'Alice').local_slot
    $B = [int](Read-State 'Bob').local_slot
    $Slots = @(0, $A, $B)
    Write-Host "  slots: Host=0 Alice=$A Bob=$B"

    # 1. Host-only load: clients follow the manifest, same players, authorities per owner.
    Send-Cmd 'Host' 'load dev'
    Wait-For 'every peer spawned the same 3 players (same load id, authority = owner)' {
        $lid = (Read-State 'Host').load_id
        $ok = $lid -ge 1
        foreach ($n in $All) {
            $s = Read-State $n
            if ($s.load_id -ne $lid -or @($s.players.PSObject.Properties).Count -ne 3) { $ok = $false }
            if ((Get-Player $n $A).auth -ne (Read-State 'Alice').peer_id -or (Get-Player $n $B).auth -ne (Read-State 'Bob').peer_id -or (Get-Player $n 0).auth -ne 1) { $ok = $false }
        }
        $ok -and (Get-Player 'Alice' $A).local -and -not (Get-Player 'Alice' $B).local -and -not (Get-Player 'Host' $A).local
    }
    Send-Cmd 'Host' 'unfreeze'
    Wait-For 'unfrozen everywhere' { @($All | Where-Object { -not (Get-Player $_ $A).frozen -and -not (Get-Player $_ $B).frozen }).Count -eq 3 }
    Wait-For 'spawn positions agree' { Test-Positions $All $Slots 0.05 }

    # 2. Alice walks (toward the arena centre, so she stays on the 20 m floor); everyone agrees
    # where everyone is.
    $before = Get-Player 'Host' $A
    Send-Cmd 'Alice' ("walk {0:N3} {1:N3} 1.2" -f (-$before.x), (-$before.z))
    Wait-For 'Alice finished walking' { (Read-State 'Alice').walks_done -ge 1 }
    Start-Sleep -Milliseconds 800
    Wait-For 'all peers agree on positions after the walk (0.15 m)' { Test-Positions $All $Slots 0.15 }
    $after = Get-Player 'Host' $A
    $moved = Get-Dist $before $after
    Write-Host ("  Alice moved {0:N2} m (host view)" -f $moved)
    if ($moved -lt 2.0) { throw "Alice barely moved on the host ($moved m)" }

    # 3. Alice shoves Bob: got_hit on all three, Bob moves (his own client simulates him).
    $bobBefore = Get-Player 'Host' $B
    Send-Cmd 'Alice' "shove $B"
    Wait-For 'shove_hit raised on all three' { @($All | Where-Object { (Get-Count $_ "shove_hit:$A") -ge 1 }).Count -eq 3 } 30
    Wait-For 'got_hit for Bob raised exactly once on all three' { @($All | Where-Object { (Get-Count $_ "got_hit:$B") -eq 1 }).Count -eq 3 }
    Start-Sleep -Milliseconds 1500
    Wait-For 'all peers agree after the shove (0.15 m)' { Test-Positions $All $Slots 0.15 }
    $pushed = Get-Dist $bobBefore (Get-Player 'Host' $B)
    Write-Host ("  Bob pushed {0:N2} m (host view)" -f $pushed)
    if ($pushed -lt 0.5) { throw "Bob was not pushed ($pushed m)" }

    # 4. Host eliminates Bob: gone everywhere, once.
    Send-Cmd 'Host' "eliminate $B"
    Wait-For 'Bob eliminated on all three (event once)' {
        @($All | Where-Object { -not (Get-Player $_ $B).alive -and (Get-Count $_ "eliminated:$B") -eq 1 }).Count -eq 3
    }

    # 5. A full 2-round Session: identical rounds and scores everywhere.
    Send-Cmd 'Host' 'session 2'
    Wait-For 'round 1 playing' { $s = Read-State 'Host'; $s.session_state -eq 2 -and $s.round_index -eq 0 }
    Wait-For 'round 1: same load on every peer' {
        $lid = (Read-State 'Host').load_id
        @($All | Where-Object { (Read-State $_).load_id -eq $lid -and @((Read-State $_).players.PSObject.Properties).Count -eq 3 }).Count -eq 3
    }
    Send-Cmd 'Host' "knockout $B"
    Wait-For 'knock-out reached every peer' { @($All | Where-Object { -not (Get-Player $_ $B).alive }).Count -eq 3 }
    Send-Cmd 'Host' "endround 0 $A $B"
    Wait-For 'round 2 playing' { $s = Read-State 'Host'; $s.session_state -eq 2 -and $s.round_index -eq 1 }
    Send-Cmd 'Host' "endround $A $B 0"
    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 }
    $scores = @($All | ForEach-Object { ((Read-State $_).final_scores | ConvertTo-Json -Compress) })
    $rounds = @($All | ForEach-Object { ((Read-State $_).rounds | ConvertTo-Json -Compress -Depth 5) })
    Write-Host "  final scores: $($scores -join ' | ')"
    if (@($scores | Select-Object -Unique).Count -ne 1) { throw 'final scores differ between peers' }
    if (@($rounds | Select-Object -Unique).Count -ne 1) { throw 'round results differ between peers' }
    $fs = (Read-State 'Host').final_scores
    if ($fs.'0' -ne 6 -or $fs."$A" -ne 7 -or $fs."$B" -ne 5) { throw "unexpected scores $($scores[0])" }
    Write-Host 'PASS identical scores and rounds on all peers'
    Wait-For 'back in the lobby, stage cleared everywhere' {
        @($All | Where-Object { $s = Read-State $_; $s.session_state -eq 0 -and @($s.players.PSObject.Properties).Count -eq 0 }).Count -eq 3
    }

    # 6. Bob quits mid-round: removed everywhere, knocked out on the host.
    Send-Cmd 'Host' 'session 2'
    Wait-For 'new session playing with 3' {
        $lid = (Read-State 'Host').load_id
        (Read-State 'Host').session_state -eq 2 -and
        @($All | Where-Object { (Read-State $_).load_id -eq $lid -and @((Read-State $_).players.PSObject.Properties).Count -eq 3 }).Count -eq 3
    }
    Send-Cmd 'Bob' 'quit'
    Wait-For 'Bob exited' { $script:Procs['Bob'].HasExited }
    Wait-For 'Bob removed on host and Alice, knocked out on the host' {
        $h = Read-State 'Host'; $a = Read-State 'Alice'
        $null -eq $h.players."$B" -and $null -eq $a.players."$B" -and @($h.players.PSObject.Properties).Count -eq 2 -and
        @($a.players.PSObject.Properties).Count -eq 2 -and (@($h.knocked_out) -contains $B) -and $h.roster_size -eq 2
    }
    Wait-For 'round goes on with two' { (Read-State 'Host').session_state -eq 2 }

    Send-Cmd 'Host' 'quit'
    Wait-For 'Alice gets server_closed' { (Read-State 'Alice').events -contains 'server_closed' }
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
    Write-Host "sync-smoke: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'sync-smoke: OK' } else { Write-Host 'sync-smoke: FAILED' }
exit $exit
