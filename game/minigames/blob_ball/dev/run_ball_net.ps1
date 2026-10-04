# Blob Ball multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a roster bot fills to 4 (2v2), one Session round of Blob Ball with every blob
# driven by a bot brain (plus a shove reflex near the ball). Each actor (ball_net.gd) writes
# what it saw to build/ball-net/<stamp>/<name>.json. Asserts:
#  - every peer saw the same goal timeline, the same accepted kicks (in order) and the same
#    final score and tied-group ranking (two whole teams, or one group on a tie);
#  - a client's shove on the ball was accepted and moved it on every peer;
#  - each client's ball agreed with the host's: at every host update (~20 Hz) the client's
#    own simulated ball was within 0.5 m of the host's for >= 95 % of updates (mean < 0.2 m);
#  - no actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\blob_ball\dev\run_ball_net.ps1 [-Port 24599]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24599, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 160, [double]$TimeScale = 2)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\ball-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/blob_ball/dev/ball_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=260',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) phase=$($s.phase) score=$($s.score -join '-')"
            Write-Host "     goals=$($s.goals -join ' ') kicks=$(@($s.kicks).Count)"
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
    throw "ball-net step failed: $Desc"
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
    Wait-For 'Blob Ball round intro on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:0:blob_ball' }).Count -eq 3
    }
    Wait-For 'round finished on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3
    } $RoundTimeoutSec

    $st = @{}
    foreach ($n in $All) { $st[$n] = Read-State $n }
    $goals = @($All | ForEach-Object { (@($st[$_].goals) -join ' ') })
    $kicks = @($All | ForEach-Object { (@($st[$_].kicks | ForEach-Object { ($_ -split ':')[0] }) -join ' ') })
    $scores = @($All | ForEach-Object { (@($st[$_].score) -join '-') })
    $rank = @($All | ForEach-Object { ($st[$_].rankings | ConvertTo-Json -Compress -Depth 5) })
    Write-Host "  goals: $($goals[0])  score: $($scores[0])  kicks: $(@($st['Host'].kicks).Count)"
    Write-Host "  rankings: $($rank -join ' | ')"
    if (@($goals | Select-Object -Unique).Count -ne 1) {
        $All | ForEach-Object { Write-Host "  $_ : $(@($st[$_].goals) -join ' ')" }
        throw 'goal timelines differ between peers'
    }
    Write-Host 'PASS every peer saw the same goal timeline'
    if (@($scores | Select-Object -Unique).Count -ne 1) { throw "scores differ: $($scores -join ' | ')" }
    if (@($rank | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $groups = @($st['Host'].rankings[0])
    $flat = @($groups | ForEach-Object { $_ })
    if ($flat.Count -ne 4 -or @($flat | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($flat -join ',')" }
    $sc = @($st['Host'].score)
    if ($sc[0] -eq $sc[1]) {
        if ($groups.Count -ne 1) { throw "a draw must be one tied group, got $($groups.Count)" }
    } elseif ($groups.Count -ne 2 -or @($groups[0]).Count -ne 2) {
        throw "a win must be two team groups of 2, got $($rank[0])"
    }
    Write-Host "PASS identical score $($scores[0]) and ranking $($rank[0]) on all peers"
    if (@($kicks | Select-Object -Unique).Count -ne 1) {
        $All | ForEach-Object { Write-Host "  $_ : $(@($st[$_].kicks) -join ' ')" }
        throw 'accepted kicks differ between peers'
    }
    $clientSlots = @([int]$st['Alice'].local_slot, [int]$st['Bob'].local_slot)
    foreach ($n in $All) {
        $ck = @($st[$n].kicks | Where-Object { $clientSlots -contains [int](($_ -split ':')[0]) })
        if ($ck.Count -lt 1) { throw "$n saw no accepted client shove on the ball" }
        $fast = @($ck | Where-Object { [double](($_ -split ':')[1]) -gt 5.0 })
        if ($fast.Count -lt 1) { throw "$n : client shoves did not launch the ball ($($ck -join ' '))" }
    }
    Write-Host "PASS client shoves on the ball accepted and moved it on every peer ($(@($st['Host'].kicks | Where-Object { $clientSlots -contains [int](($_ -split ':')[0]) }).Count) of $(@($st['Host'].kicks).Count) kicks)"
    foreach ($n in @('Alice', 'Bob')) {
        $e = $st[$n].net_error
        $cnt = [int]$e.n
        if ($cnt -lt 200) { throw "$n got only $cnt ball updates" }
        $mean = [double]$e.sum / $cnt
        $overFrac = [double]$e.over / $cnt
        Write-Host ("  {0}: {1} host updates, ball error mean {2:N3} m, max {3:N2} m, {4:P1} over 0.5 m" -f $n, $cnt, $mean, [double]$e.max, $overFrac)
        if ($overFrac -gt 0.05 -or $mean -gt 0.2) { throw "$n ball disagrees with the host too often" }
    }
    Write-Host 'PASS client balls agree with the host (within 0.5 m at >= 95 % of host updates)'

    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 } 60
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
    Write-Host "ball-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'ball-net: OK' } else { Write-Host 'ball-net: FAILED' }
exit $exit
