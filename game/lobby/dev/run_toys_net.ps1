# Lobby toys multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1) in the lobby (Stage.follow_roster, as the app loads it). Each actor (toys_net.gd)
# writes what it sees to build/toys-net/<stamp>/<name>.json. Asserts:
#  - every client's lobby says hello and gets the toys' traffic (host toy_peers = 2);
#  - a client's shove on the football is accepted and moves the ball on every peer; every
#    peer's ball agrees with the host's (client prediction within 0.5 m at >= 95 % of host
#    updates, mean < 0.2 m) and, once the ball rests, all three rest within 0.15 m;
#  - a goal: identical goal timelines and tonight's counts on every peer;
#  - a client's shove on the bell rings it on every peer (identical ring logs), and a second
#    shove inside the cooldown does not;
#  - a client standing on the see-saw tilts it the same way on every peer (angles within
#    0.03 rad of the host's), and a client dropping onto the high end catapults the other
#    client (its own authority throws it: it rises > 1.4 m), seen on every peer;
#  - a client's shove on the photo button takes one photo on every peer;
#  - no actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\lobby\dev\run_toys_net.ps1 [-Port 24611]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24611, [int]$StepTimeoutSec = 20)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\toys-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://lobby/dev/toys_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=200') + $Extra
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
            Write-Host ("  {0} slot={1} roster={2} lobby={3} ball=({4}) kicks={5} goals={6} rings={7} seesaw={8:N3} catapults={9} photos={10}" -f `
                $n, $s.local_slot, $s.roster_size, $s.lobby, (@($s.ball | ForEach-Object { '{0:N2}' -f $_ }) -join ','), `
                (@($s.kicks) -join ' '), (@($s.goals) -join ' '), @($s.rings).Count, [double]$s.seesaw, $s.catapults, $s.photos)
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
    throw "toys-net step failed: $Desc"
}

function All([scriptblock]$Cond) {
    return @($All | Where-Object { $s = Read-State $_; $s -and (& $Cond $s) }).Count -eq $All.Count
}

function Dist($a, $b) {
    $dx = [double]$a[0] - [double]$b[0]; $dy = [double]$a[1] - [double]$b[1]; $dz = [double]$a[2] - [double]$b[2]
    return [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz)
}

function Wait-BallRest([string]$Desc) {
    # The host's ball at rest, and every peer's ball within 0.15 m of it.
    Wait-For $Desc {
        $h = Read-State 'Host'
        if ([double]$h.ball_speed -gt 0.02) { return $false }
        foreach ($n in @('Alice', 'Bob')) {
            $s = Read-State $n
            if ((Dist $s.ball $h.ball) -gt 0.15) { return $false }
        }
        return $true
    } 25
}

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up with the lobby' { (Read-State 'Host').events -contains 'host_game:OK' -and (Read-State 'Host').lobby }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three in the lobby with their blobs' { All { param($s) $s.roster_size -eq 3 -and $s.lobby -and $s.players -eq 3 -and (@($s.events | Where-Object { $_ -like 'me:*' }).Count -ge 1) } }
    Wait-For 'both clients said hello (host sends them toy traffic)' { (Read-State 'Host').toy_peers -eq 2 }
    foreach ($n in $All) { Send-Cmd $n "park $([array]::IndexOf($All, $n))" }
    Start-Sleep -Seconds 1
    $alice = [int](Read-State 'Alice').local_slot
    $bob = [int](Read-State 'Bob').local_slot

    # --- Football: a client's kick moves the ball everywhere; balls agree ---
    Wait-BallRest 'the ball rests on the spot everywhere'
    $before = (Read-State 'Host').ball
    Send-Cmd 'Alice' 'kick'
    Wait-For "Alice's kick accepted on every peer" { All { param($s) @($s.kicks) -contains $alice } }
    Wait-For 'the ball moved on every peer' { All { param($s) (Dist $s.ball $before) -gt 1.0 } }
    Send-Cmd 'Alice' 'park 1'
    Wait-BallRest 'after the kick the ball rests at the same place on every peer'
    Send-Cmd 'Bob' 'kick'
    Wait-For "Bob's kick accepted on every peer" { All { param($s) @($s.kicks) -contains $bob } }
    Send-Cmd 'Bob' 'park 2'
    Wait-BallRest 'after the second kick too'
    $kicks = @($All | ForEach-Object { (@((Read-State $_).kicks) -join ' ') })
    if (@($kicks | Select-Object -Unique).Count -ne 1) { throw "kick logs differ: $($kicks -join ' | ')" }
    Write-Host "PASS identical kick logs ($($kicks[0]))"
    Wait-For 'both clients have >= 150 host ball updates' { @('Alice', 'Bob' | Where-Object { [int](Read-State $_).net_error.n -ge 150 }).Count -eq 2 }
    foreach ($n in @('Alice', 'Bob')) {
        $e = (Read-State $n).net_error
        $cnt = [int]$e.n
        if ($cnt -lt 100) { throw "$n got only $cnt ball updates" }
        $mean = [double]$e.sum / $cnt
        $overFrac = [double]$e.over / $cnt
        Write-Host ("  {0}: {1} host updates, ball error mean {2:N3} m, max {3:N2} m, {4:P1} over 0.5 m" -f $n, $cnt, $mean, [double]$e.max, $overFrac)
        if ($overFrac -gt 0.05 -or $mean -gt 0.2) { throw "$n ball disagrees with the host too often" }
    }
    Write-Host 'PASS client balls agree with the host (within 0.5 m at >= 95 % of host updates)'

    # --- Goal ---
    $t0 = (Read-State 'Host').tonight
    Send-Cmd 'Host' 'goal'
    Wait-For 'a goal on every peer' { All { param($s) @($s.goals).Count -ge 1 } }
    Wait-BallRest 'the ball is back on the spot everywhere'
    $goals = @($All | ForEach-Object { (@((Read-State $_).goals) -join ' ') })
    $tonight = @($All | ForEach-Object { (@((Read-State $_).tonight) -join '-') })
    if (@($goals | Select-Object -Unique).Count -ne 1) { throw "goal logs differ: $($goals -join ' | ')" }
    if (@($tonight | Select-Object -Unique).Count -ne 1) { throw "goal counts differ: $($tonight -join ' | ')" }
    if ([int](Read-State 'Host').tonight[1] -ne [int]$t0[1] + 1) { throw "the blue count did not go up by one ($($tonight[0]))" }
    Write-Host "PASS identical goals ($($goals[0])) and counts ($($tonight[0])) on every peer"

    # --- Bell ---
    Send-Cmd 'Bob' 'bell'
    Wait-For 'the bell rings on every peer' { All { param($s) @($s.rings).Count -eq 1 } }
    Send-Cmd 'Bob' 'bell'
    Start-Sleep -Milliseconds 700
    $rings = @($All | ForEach-Object { (@((Read-State $_).rings) -join ' ') })
    if (@($All | Where-Object { @((Read-State $_).rings).Count -ne 1 }).Count -gt 0) { throw "a second shove inside the cooldown rang it: $($rings -join ' | ')" }
    Write-Host 'PASS a second shove inside the cooldown does not ring it'
    Send-Cmd 'Bob' 'park 2'

    # --- See-saw: tilt and catapult ---
    Send-Cmd 'Alice' 'seesaw_on'
    Wait-For 'the +X end goes down on every peer' { All { param($s) [double]$s.seesaw -lt -0.15 } }
    Start-Sleep -Seconds 1
    $h = [double](Read-State 'Host').seesaw
    foreach ($n in @('Alice', 'Bob')) {
        $a = [double](Read-State $n).seesaw
        if ([Math]::Abs($a - $h) -gt 0.03) { throw "$n see-saw angle $a vs host $h" }
    }
    Write-Host ("PASS see-saw angles agree (host {0:N3})" -f $h)
    Send-Cmd 'Alice' 'seesaw_low'
    Wait-For 'the -X end goes down on every peer' { All { param($s) [double]$s.seesaw -gt 0.15 } }
    Start-Sleep -Milliseconds 500
    Send-Cmd 'Bob' 'jump_high'
    Wait-For 'a catapult on every peer' { All { param($s) [int]$s.catapults -ge 1 } }
    Wait-For 'Alice was thrown up by her own peer' { [double](Read-State 'Alice').me_max_y -gt 2.4 } 5
    Start-Sleep -Milliseconds 1500
    Write-Host "  Alice's peak: $('{0:N2}' -f [double](Read-State 'Alice').me_max_y) m"
    Send-Cmd 'Alice' 'park 1'
    Send-Cmd 'Bob' 'park 2'

    # --- Photo ---
    Send-Cmd 'Alice' 'photo'
    Wait-For 'one photo on every peer' { All { param($s) [int]$s.photos -eq 1 } } 10

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
    Write-Host "toys-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'toys-net: OK' } else { Write-Host 'toys-net: FAILED' }
exit $exit
