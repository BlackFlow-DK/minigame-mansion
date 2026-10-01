# Cannon Alley multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a host bot fills the roster to 4, then a real 1-round Session of cannon_alley.
# Every peer's own player is driven by a BotBrain. Each actor
# (game/minigames/cannon_alley/dev/cannon_net_check.gd) writes what it sees to
# build/cannon-net-check/<stamp>/<name>.json; this runner asserts all peers agree: the same
# schedule seed, identical ball positions at every sampled round time, the same confirmed hits,
# the same eliminations (order and reason) and the same final ranking with every slot once;
# and that the host accepted hit reports from the clients and refused none.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\cannon_alley\dev\run_cannon_net_check.ps1 [-Port 24597]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24597, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\cannon-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/cannon_alley/dev/cannon_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) seed=$($s.seed) shots=$($s.shot_count) outs=[$($s.eliminations -join ',')] ranking=[$($s.ranking -join ',')] confirmed=[$($s.confirmed -join ',')] local_hits=$($s.local_hits) accepted_remote=$($s.accepted_remote) rejected=$($s.rejected)"
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
    Wait-For 'the cannon round started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_began' -and $s.scene -like '*cannon_alley.tscn' -and @($s.players.PSObject.Properties).Count -eq 4 }).Count -eq 3
    } 30
    Wait-For 'the round finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']

    # Schedule: the same seed and number of shots everywhere.
    $seeds = @($All | ForEach-Object { "$($states[$_].seed)/$($states[$_].shot_count)" })
    if (@($seeds | Select-Object -Unique).Count -ne 1 -or $h.seed -lt 0 -or $h.shot_count -lt 20) { throw "schedules differ: $($seeds -join ' | ')" }
    Write-Host "PASS same schedule on all peers (seed/shots $($seeds[0]))"

    # Ball positions at the sampled round times: identical on every peer that reached them.
    $keys = @($h.samples.PSObject.Properties.Name)
    $common = 0
    $flying = 0
    foreach ($k in $keys) {
        $hv = $h.samples.$k
        $present = $true
        foreach ($n in @('Alice', 'Bob')) {
            $cv = $states[$n].samples.$k
            if ($null -eq $cv) { $present = $false; continue }
            if ($cv -ne $hv) { throw "ball positions at $k s differ: $n [$cv] host [$hv]" }
        }
        if ($present) {
            $common++
            if ($hv -ne '-') { $flying += @($hv -split ',' | Where-Object { $_ -like '*:*' }).Count }
        }
    }
    if ($common -lt 4 -or $flying -lt 4) { throw "too few sampled balls to compare ($common samples, $flying balls)" }
    Write-Host "PASS identical ball positions at $common sampled times ($flying balls in flight)"

    # Ranking: identical everywhere, every slot exactly once.
    $rankings = @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw "rankings differ: $($rankings -join ' | ')" }
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    Write-Host "PASS same ranking on all peers: [$($rankings[0])]"

    # Hits and eliminations: same order and reasons everywhere, decided by the host.
    $conf = @($All | ForEach-Object { ($states[$_].confirmed -join ',') })
    if (@($conf | Select-Object -Unique).Count -ne 1) { throw "confirmed hits differ: $($conf -join ' | ')" }
    $outs = @($All | ForEach-Object { ($states[$_].eliminations -join ',') })
    if (@($outs | Select-Object -Unique).Count -ne 1) { throw "eliminations differ: $($outs -join ' | ')" }
    if (@($h.eliminations | Where-Object { $_ -like '*:cannon' }).Count -lt 1) { throw "nobody was knocked out by a cannon ($($outs[0]))" }
    Write-Host "PASS same confirmed hits [$($conf[0])] and eliminations [$($outs[0])] on all peers"

    # Client hits travel to the host and pass its plausibility check.
    $clientHits = [int]$states['Alice'].local_hits + [int]$states['Bob'].local_hits
    if ($clientHits -lt 1) { throw 'no client-owned player was hit: the report path was not exercised' }
    if ([int]$h.accepted_remote -lt 1) { throw "the host accepted no client hit report ($clientHits client hits)" }
    if ([int]$h.rejected -ne 0) { throw "the host refused $($h.rejected) honest hit report(s)" }
    Write-Host "PASS host accepted $($h.accepted_remote) client hit report(s) ($clientHits client-side hits), refused none"

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
    Write-Host "cannon-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'cannon-net-check: OK' } else { Write-Host 'cannon-net-check: FAILED' }
exit $exit
