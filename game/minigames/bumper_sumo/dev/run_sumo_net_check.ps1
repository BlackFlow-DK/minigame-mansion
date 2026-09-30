# Bumper Sumo multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a host bot fills the roster to 4, then a real 1-round Session of bumper_sumo.
# Every peer's own player is driven by a BotBrain. Each actor
# (game/minigames/bumper_sumo/dev/sumo_net_check.gd) writes what it sees to
# build/sumo-net-check/<stamp>/<name>.json; this runner asserts all peers agree: the same
# ring warnings/drops in the same order at about the same time, the same eliminations
# (order and reason) and the same final ranking with every slot once.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\bumper_sumo\dev\run_sumo_net_check.ps1 [-Port 24596]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24596, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\sumo-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/bumper_sumo/dev/sumo_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) rings=[$($s.ring_events -join ',')] outs=[$($s.eliminations -join ',')] ranking=[$($s.ranking -join ',')]"
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
    throw "check step failed: $Desc"
}

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 -and (Read-State $_).local_slot -ge 0 }).Count -eq 3 }
    Send-Cmd 'Host' 'bot'
    Wait-For 'a host bot fills the roster to 4 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }

    Send-Cmd 'Host' 'session'
    Wait-For 'the sumo round started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_started' -and $s.scene -like '*bumper_sumo.tscn' -and @($s.players.PSObject.Properties).Count -eq 4 }).Count -eq 3
    } 30
    Wait-For 'the round finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']

    # Ranking: identical everywhere, every slot exactly once.
    $rankings = @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw "rankings differ: $($rankings -join ' | ')" }
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    Write-Host "PASS same ranking on all peers: [$($rankings[0])]"

    # Ring events: same sequence everywhere, at least one drop, about the same time.
    $rings = @($All | ForEach-Object { ($states[$_].ring_events -join ',') })
    if (@($rings | Select-Object -Unique).Count -ne 1) { throw "ring events differ: $($rings -join ' | ')" }
    if (@($h.ring_events | Where-Object { $_ -like 'drop:*' }).Count -lt 1) { throw "no ring dropped during the round ($($rings[0]))" }
    foreach ($k in $h.ring_events) {
        $th = [double]$h.ring_times.$k
        foreach ($n in @('Alice', 'Bob')) {
            $tc = [double]$states[$n].ring_times.$k
            if ([math]::Abs($tc - $th) -gt 0.5) { throw "$n saw $k at $tc s, host at $th s" }
        }
        Write-Host ("  {0} at {1:N2} s (host)" -f $k, $th)
    }
    Write-Host "PASS same ring warnings/drops on all peers: [$($rings[0])]"

    # Eliminations: same order and reasons everywhere.
    $outs = @($All | ForEach-Object { ($states[$_].eliminations -join ',') })
    if (@($outs | Select-Object -Unique).Count -ne 1) { throw "eliminations differ: $($outs -join ' | ')" }
    Write-Host "PASS same eliminations on all peers: [$($outs[0])]"

    foreach ($n in $All) { Send-Cmd $n 'quit' }
    Wait-For 'every process exited' { @($script:Procs.Values | Where-Object { -not $_.HasExited }).Count -eq 0 }

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
    Write-Host "sumo-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'sumo-net-check: OK' } else { Write-Host 'sumo-net-check: FAILED' }
exit $exit
