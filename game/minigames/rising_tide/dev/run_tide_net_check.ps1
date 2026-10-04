# Rising Tide multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), two host bots fill the roster to 5, then a real 1-round Session of rising_tide.
# Every peer's own player is driven by a BotBrain. Each actor
# (game/minigames/rising_tide/dev/tide_net_check.gd) writes what it sees to
# build/tide-net-check/<stamp>/<name>.json; this runner asserts all peers agree: the same seed,
# identical water heights and hanging platform positions at every sampled round time, the same
# host-decided crumble (crack / fall / regrow), drowning, roof and summit events in the same order,
# every crumbling block's collider in step with its state on every peer, and the same final ranking
# with every slot once.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\rising_tide\dev\run_tide_net_check.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 130)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\tide-net-check\' +(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/rising_tide/dev/tide_net_check.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=220') + $Extra
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) seed=$($s.seed) ranking=[$($s.ranking -join ',')] launches=$($s.launches) bad_colliders=$($s.bad_colliders)"
            Write-Host "     crumbles=[$($s.crumbles -join ',')] drowned=[$($s.drowned -join ',')] roof=[$($s.roof -join ',')] summit=$($s.summit)"
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
    Send-Cmd 'Host' 'bot'
    Wait-For 'host bots fill the roster to 5 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 5 }).Count -eq 3 }

    Send-Cmd 'Host' 'session'
    Wait-For 'the tide started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_began' -and $s.scene -like '*rising_tide.tscn' -and @($s.players.PSObject.Properties).Count -eq 5 }).Count -eq 3
    } 30
    Wait-For 'the round finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']

    Assert-Same 'seeds' @($All | ForEach-Object { "$($states[$_].seed)" })
    if ($h.seed -lt 0) { throw 'no seed' }
    Write-Host "PASS same seed on all peers ($($h.seed))"

    # Water and hanging platforms at the sampled round times: identical on every peer that reached them.
    $common = 0
    foreach ($k in @($h.samples.PSObject.Properties.Name)) {
        $hv = $h.samples.$k
        $present = $true
        foreach ($n in @('Alice', 'Bob')) {
            $cv = $states[$n].samples.$k
            if ($null -eq $cv) { $present = $false; continue }
            if ($cv -ne $hv) { throw "water / hanging platforms at $k s differ: $n [$cv] host [$hv]" }
        }
        if ($present) { $common++ }
    }
    if ($common -lt 4) { throw "too few samples to compare ($common)" }
    Write-Host "PASS identical water heights and hanging platform positions at $common sampled times"

    # Host-decided events: same order and content everywhere.
    Assert-Same 'crumble events' @($All | ForEach-Object { ($states[$_].crumbles -join ',') })
    Assert-Same 'drownings' @($All | ForEach-Object { ($states[$_].drowned -join ',') })
    Assert-Same 'roof arrivals' @($All | ForEach-Object { ($states[$_].roof -join ',') })
    Assert-Same 'summit' @($All | ForEach-Object { "$($states[$_].summit)" })
    $falls = @($h.crumbles | Where-Object { $_ -like 'f*' })
    if ($falls.Count -lt 1) { throw "no crumbling block fell ($($h.crumbles -join ','))" }
    if (@($h.drowned).Count -lt 1) { throw 'nobody drowned' }
    foreach ($n in $All) { if ([int]$states[$n].bad_colliders -ne 0) { throw "$n saw a crumble collider out of step ($($states[$n].bad_colliders))" } }
    Write-Host "PASS same crumbles [$($h.crumbles -join ',')] with colliders in step, drownings [$($h.drowned -join ',')], roof [$($h.roof -join ',')], summit $($h.summit) on all peers"

    # Client-owned players climbed (the host saw them from their synced positions).
    $clientSlots = @([int]$states['Alice'].local_slot, [int]$states['Bob'].local_slot)
    $best = 0.0
    foreach ($cs in $clientSlots) { $y = [double]$h.max_y."$cs"; if ($y -gt $best) { $best = $y } }
    if ($best -lt 3.4) { throw "no client-owned player climbed onto floor 1 as the host saw it (best $best m)" }
    Write-Host "PASS client-owned players climbed (host saw one at $([math]::Round($best, 1)) m)"

    # Ranking: identical everywhere, every slot once.
    Assert-Same 'rankings' @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 5 -or @($r | Select-Object -Unique).Count -ne 5) { throw "ranking is not 5 distinct slots: $($r -join ',')" }
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
    Write-Host "tide-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'tide-net-check: OK' } else { Write-Host 'tide-net-check: FAILED' }
exit $exit
