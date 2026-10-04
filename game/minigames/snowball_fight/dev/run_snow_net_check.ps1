# Snowball Fight multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a host bot fills the roster to 4, then a real 1-round Session of snowball_fight.
# Every peer's own player walks with a BotBrain and throws with the minigame's thrower AI. Each actor
# (game/minigames/snowball_fight/dev/snow_net_check.gd) writes what it sees to
# build/snow-net-check/<stamp>/<name>.json; this runner asserts all peers agree: the same launches
# (id, thrower, time, origin, direction, and the same computed end of every ball), the same confirmed
# hits, scores, snow-ins and final ranking with every slot once; that a client's ball hit a host-owned
# blob and a host-owned blob's ball hit a client's blob; and that the host accepted client throws and
# hit reports and refused none.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\snowball_fight\dev\run_snow_net_check.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\snow-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/snowball_fight/dev/snow_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) launches=$(@($s.launches).Count) confirmed=$(@($s.confirmed).Count) snowins=[$($s.snowins -join ',')] ranking=[$($s.ranking -join ',')] local_hits=$($s.local_hits) accepted_throws=$($s.accepted_throws) accepted_hits=$($s.accepted_hits) rejected=$($s.rejected) ignored=$($s.ignored)"
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
    Wait-For 'the snowball round started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_began' -and $s.scene -like '*snowball_fight.tscn' -and @($s.players.PSObject.Properties).Count -eq 4 }).Count -eq 3
    } 30
    Wait-For 'the round finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']

    # Launches: the same balls, in the same order, from the same data, ending at the same place.
    $launches = @($All | ForEach-Object { (@($states[$_].launches) -join ' ') })
    if (@($launches | Select-Object -Unique).Count -ne 1) {
        foreach ($n in $All) { Write-Host "  $n launches: $(@($states[$n].launches).Count)" }
        throw 'launches differ between peers'
    }
    $nl = @($h.launches).Count
    if ($nl -lt 20) { throw "too few launches to compare ($nl)" }
    Write-Host "PASS identical launches and ball ends on all peers ($nl balls)"

    # Hits, scores, snow-ins, ranking: identical everywhere, decided by the host.
    $conf = @($All | ForEach-Object { (@($states[$_].confirmed) -join ',') })
    if (@($conf | Select-Object -Unique).Count -ne 1) { throw "confirmed hits differ: $($conf -join ' | ')" }
    $scores = @($All | ForEach-Object { ($states[$_].scores | ConvertTo-Json -Compress) })
    if (@($scores | Select-Object -Unique).Count -ne 1) { throw "scores differ: $($scores -join ' | ')" }
    $snows = @($All | ForEach-Object { (@($states[$_].snowins) -join ',') })
    if (@($snows | Select-Object -Unique).Count -ne 1) { throw "snow-ins differ: $($snows -join ' | ')" }
    $rankings = @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw "rankings differ: $($rankings -join ' | ')" }
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    $nh = @($h.confirmed).Count
    if ($nh -lt 5) { throw "too few hits ($nh)" }
    Write-Host "PASS same $nh hits, scores $($scores[0]), snow-ins [$($snows[0])] and ranking [$($rankings[0])] on all peers"

    # Cross-peer hits: a client's ball on a host-owned blob, and a host-owned blob's ball on a client.
    $auth = @{}
    foreach ($prop in $h.players.PSObject.Properties) { $auth[[int]$prop.Name] = [int]$prop.Value.auth }
    $clientOnHost = 0
    $hostOnClient = 0
    foreach ($c in @($h.confirmed)) {
        $m = [regex]::Match($c, '^(\d+):(\d+)>(\d+):(\d+)$')
        $thrower = [int]$m.Groups[2].Value
        $victim = [int]$m.Groups[3].Value
        if ($auth[$thrower] -ne 1 -and $auth[$victim] -eq 1) { $clientOnHost++ }
        if ($auth[$thrower] -eq 1 -and $auth[$victim] -ne 1) { $hostOnClient++ }
    }
    if ($clientOnHost -lt 1) { throw "no client ball hit a host-owned blob ($($conf[0]))" }
    if ($hostOnClient -lt 1) { throw "no host-owned ball hit a client blob ($($conf[0]))" }
    Write-Host "PASS client balls on host blobs: $clientOnHost, host balls on client blobs: $hostOnClient"

    # Client requests travel to the host and pass its checks.
    if ([int]$h.accepted_throws -lt 5) { throw "the host accepted only $($h.accepted_throws) client throws" }
    if ([int]$h.accepted_hits -lt 1) { throw 'the host accepted no client hit report' }
    if ([int]$h.rejected -ne 0) { throw "the host refused $($h.rejected) honest request(s)" }
    Write-Host "PASS host accepted $($h.accepted_throws) client throws and $($h.accepted_hits) client hit reports, refused none (ignored $($h.ignored) late/duplicate)"

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
    Write-Host "snow-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'snow-net-check: OK' } else { Write-Host 'snow-net-check: FAILED' }
exit $exit
