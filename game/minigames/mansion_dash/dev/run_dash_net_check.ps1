# Mansion Dash multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a host bot fills the roster to 4, then a real 1-round Session of mansion_dash.
# Every peer's own player is driven by a BotBrain. Each actor
# (game/minigames/mansion_dash/dev/dash_net_check.gd) writes what it sees to
# build/dash-net-check/<stamp>/<name>.json; this runner asserts all peers agree: the same layout
# seed, identical hazard positions (hammers, rafts, sweeper, turntable, logs) at every sampled
# round time, the same host-decided checkpoint, fall and finish events in the same order, and the
# same final ranking with every slot once; and that client-owned players made it through
# checkpoints (the host decides from their synced positions).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\mansion_dash\dev\run_dash_net_check.ps1 [-Port 24599]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24599, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 130)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\dash-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/mansion_dash/dev/dash_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) seed=$($s.seed) ranking=[$($s.ranking -join ',')] local_hits=$($s.local_hits)"
            Write-Host "     checkpoints=[$($s.checkpoints -join ',')] falls=[$($s.falls -join ',')] finishes=[$($s.finishes -join ',')]"
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

function Assert-Same([string]$What, [string[]]$Values) {
    if (@($Values | Select-Object -Unique).Count -ne 1) { throw "$What differ: $($Values -join ' | ')" }
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
    Wait-For 'the dash started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_began' -and $s.scene -like '*mansion_dash.tscn' -and @($s.players.PSObject.Properties).Count -eq 4 }).Count -eq 3
    } 30
    Wait-For 'the race finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']

    Assert-Same 'layout seeds' @($All | ForEach-Object { "$($states[$_].seed)" })
    if ($h.seed -lt 0) { throw 'no layout seed' }
    Write-Host "PASS same layout seed on all peers ($($h.seed))"

    # Hazard positions at the sampled round times: identical on every peer that reached them.
    $common = 0
    $logs = 0
    foreach ($k in @($h.samples.PSObject.Properties.Name)) {
        $hv = $h.samples.$k
        $present = $true
        foreach ($n in @('Alice', 'Bob')) {
            $cv = $states[$n].samples.$k
            if ($null -eq $cv) { $present = $false; continue }
            if ($cv -ne $hv) { throw "hazards at $k s differ: $n [$cv] host [$hv]" }
        }
        if ($present) {
            $common++
            $logs += @($hv -split ' ' | Where-Object { $_ -like 'log*' }).Count
        }
    }
    if ($common -lt 5 -or $logs -lt 5) { throw "too few samples to compare ($common samples, $logs logs)" }
    Write-Host "PASS identical hazard positions at $common sampled times ($logs live logs among them)"

    # Host-decided events: same order and content everywhere.
    Assert-Same 'checkpoint events' @($All | ForEach-Object { ($states[$_].checkpoints -join ',') })
    Assert-Same 'fall events' @($All | ForEach-Object { ($states[$_].falls -join ',') })
    Assert-Same 'finish events' @($All | ForEach-Object { ($states[$_].finishes -join ',') })
    $cps = @($h.checkpoints)
    if ($cps.Count -lt 4) { throw "too few checkpoint events ($($cps -join ','))" }
    if (@($h.finishes).Count -lt 1) { throw 'nobody finished' }
    $clientSlots = @([int]$states['Alice'].local_slot, [int]$states['Bob'].local_slot)
    $clientCps = @($cps | Where-Object { $clientSlots -contains [int](($_ -split ':')[0]) })
    if ($clientCps.Count -lt 1) { throw "no client-owned player reached a checkpoint ($($cps -join ','))" }
    Write-Host "PASS same checkpoints [$($cps -join ',')], falls [$($h.falls -join ',')] and finishes [$($h.finishes -join ',')] on all peers"

    # Ranking: identical everywhere, every slot once, finishers first in finish order.
    Assert-Same 'rankings' @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($r -join ',')" }
    $fin = @($h.finishes | ForEach-Object { [int](($_ -split ':')[0]) })
    for ($i = 0; $i -lt $fin.Count; $i++) { if ($r[$i] -ne $fin[$i]) { throw "ranking [$($r -join ',')] does not start with the finish order [$($fin -join ',')]" } }
    Write-Host "PASS same ranking on all peers: [$($r -join ',')]"

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
    Write-Host "dash-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'dash-net-check: OK' } else { Write-Host 'dash-net-check: FAILED' }
exit $exit
