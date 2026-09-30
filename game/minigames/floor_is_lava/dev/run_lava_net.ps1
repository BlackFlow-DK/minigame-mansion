# Floor Is Lava multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1) play a real one-round Session of floor_is_lava, humans driven by bot brains on
# their own peers, bots filling the roster to 4. Each actor (lava_net.gd) writes what it sees
# to build/lava-net/<stamp>/<name>.json; this runner asserts that all three peers end with the
# same ranking and saw the same tiles crack and fall, in the same order.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\floor_is_lava\dev\run_lava_net.ps1 [-Port 24597]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24597, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\lava-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/floor_is_lava/dev/lava_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=170') + $Extra
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) load=$($s.load_id) players=$($s.players) state=$($s.session_state) rounds=$($s.rounds | ConvertTo-Json -Compress) cracked=$(@($s.cracked).Count) fell=$(@($s.fell).Count) out=$($s.eliminated -join ',')"
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
        Start-Sleep -Milliseconds 250
    }
    Write-Host "FAIL $Desc"
    Show-States @($script:Procs.Keys)
    throw "lava-net step failed: $Desc"
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
    Send-Cmd 'Host' 'bots 4'
    Wait-For 'roster of 4 (one bot) on every peer' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }

    Send-Cmd 'Host' 'session'
    Wait-For 'floor_is_lava loaded with 4 players everywhere' {
        $lid = (Read-State 'Host').load_id
        $lid -ge 1 -and @($All | Where-Object { $s = Read-State $_; $s.load_id -eq $lid -and $s.players -eq 4 }).Count -eq 3
    }
    Wait-For 'tiles are cracking and falling' { @((Read-State 'Host').fell).Count -ge 3 } 40
    Wait-For 'round finished on all three' { @($All | Where-Object { @((Read-State $_).rounds).Count -ge 1 }).Count -eq 3 } $RoundTimeoutSec
    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 } 60

    $rankings = @($All | ForEach-Object { ((Read-State $_).rounds[0] | ConvertTo-Json -Compress) })
    Write-Host "  rankings: $($rankings -join ' | ')"
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $r = @((Read-State 'Host').rounds[0])
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    Write-Host 'PASS same ranking on every peer, every slot once'

    $falls = @($All | ForEach-Object { ((Read-State $_).fell) -join ',' })
    $cracks = @($All | ForEach-Object { ((Read-State $_).cracked) -join ',' })
    $atFinish = @($All | ForEach-Object { (Read-State $_).fell_at_finish[0] })
    Write-Host "  tiles fell (host): $(@((Read-State 'Host').fell).Count), cracked: $(@((Read-State 'Host').cracked).Count), fell when the round ended: $($atFinish -join ' | ')"
    if (@($falls | Select-Object -Unique).Count -ne 1) { $falls | ForEach-Object { Write-Host "    $_" }; throw 'fallen tiles differ between peers' }
    if (@($cracks | Select-Object -Unique).Count -ne 1) { throw 'cracked tiles differ between peers' }
    if (@($atFinish | Select-Object -Unique).Count -ne 1) { throw 'peers had seen different falls when the round ended' }
    Write-Host 'PASS same tiles cracked and fell, in the same order, on every peer'
    $outs = @($All | ForEach-Object { (@((Read-State $_).eliminated) | Sort-Object) -join ',' })
    if (@($outs | Select-Object -Unique).Count -ne 1) { throw "eliminations differ: $($outs -join ' | ')" }
    Write-Host "PASS same eliminations everywhere ($($outs[0]))"

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
    Write-Host "lava-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'lava-net: OK' } else { Write-Host 'lava-net: FAILED' }
exit $exit
