# Statue Garden multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a host bot fills the roster to 4, then a real 1-round Session of statue_garden.
# Host and Bob drive their own player with a BotBrain; Alice (a client) is reckless: she never
# stops walking. Each actor (game/minigames/statue_garden/dev/statue_net_check.gd) writes what
# it sees to build/statue-net-check/<stamp>/<name>.json; this runner asserts all peers agree:
# the same phase timeline (index, phase, length; seen at about the same time), the same
# catches, Alice caught (on every peer) in every full RED, the same winner and the same final
# ranking with every slot once.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\statue_garden\dev\run_statue_net_check.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\statue-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/statue_garden/dev/statue_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) phases=$(@($s.phases).Count) catches=[$($s.catches -join ',')] wins=[$($s.wins -join ',')] ranking=[$($s.ranking -join ',')]"
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
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port", '--reckless')
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 -and (Read-State $_).local_slot -ge 0 }).Count -eq 3 }
    Send-Cmd 'Host' 'bot'
    Wait-For 'a host bot fills the roster to 4 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }

    Send-Cmd 'Host' 'session'
    Wait-For 'the statue round started on every peer' {
        @($All | Where-Object { $s = Read-State $_; $s.events -contains 'round_started' -and $s.scene -like '*statue_garden.tscn' -and @($s.players.PSObject.Properties).Count -eq 4 }).Count -eq 3
    } 30
    Wait-For 'the round finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 } $RoundTimeoutSec
    Start-Sleep -Milliseconds 500
    Show-States $All

    $states = @{}
    foreach ($n in $All) { $states[$n] = Read-State $n }
    $h = $states['Host']
    $alice = [int]$states['Alice'].local_slot

    # Ranking: identical everywhere, every slot exactly once.
    $rankings = @($All | ForEach-Object { ($states[$_].ranking -join ',') })
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw "rankings differ: $($rankings -join ' | ')" }
    $r = @($h.ranking | ForEach-Object { [int]$_ })
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    Write-Host "PASS same ranking on all peers: [$($rankings[0])]"

    # Winner (or -1 at the time limit): the same everywhere, and ranked first.
    $wins = @($All | ForEach-Object { ($states[$_].wins -join ',') })
    if (@($wins | Select-Object -Unique).Count -ne 1 -or @($h.wins).Count -ne 1) { throw "wins differ: $($wins -join ' | ')" }
    if ([int]$h.wins[0] -ge 0 -and [int]$h.wins[0] -ne $r[0]) { throw "winner $($h.wins[0]) is not ranked first" }
    Write-Host "PASS same winner on all peers: $($wins[0])"

    # Phase timeline: same indices, phases and lengths everywhere, seen at about the same time.
    $tl = @($All | ForEach-Object { ($states[$_].phases -join ' | ') })
    if (@($tl | Select-Object -Unique).Count -ne 1) { throw "phase timelines differ: $($tl -join ' || ')" }
    $np = @($h.phases).Count
    if ($np -lt 6) { throw "only $np phases" }
    for ($i = 0; $i -lt $np; $i++) {
        $th = [double]$h.phase_times[$i]
        foreach ($n in @('Alice', 'Bob')) {
            $tc = [double]$states[$n].phase_times[$i]
            if ([math]::Abs($tc - $th) -gt 0.5) { throw "$n saw phase $i at $tc s, host at $th s" }
        }
    }
    Write-Host "PASS same phase timeline on all peers ($np phases: $($h.phases[0]) ... $($h.phases[$np - 1]))"

    # Catches: the same list everywhere; the reckless client is caught in every full RED.
    $ca = @($All | ForEach-Object { ($states[$_].catches -join ',') })
    if (@($ca | Select-Object -Unique).Count -ne 1) { throw "catches differ: $($ca -join ' | ')" }
    $reds = @($h.phases | Where-Object { ($_ -split ':')[1] -eq '3' } | ForEach-Object { [int](($_ -split ':')[0]) })
    $aliceCaught = @($h.catches | Where-Object { [int](($_ -split ':')[1]) -eq $alice } | ForEach-Object { [int](($_ -split ':')[0]) })
    # The last RED may have been cut short by the end of the round.
    $judged = @($reds | Select-Object -First ([math]::Max(0, $reds.Count - 1)))
    $missed = @($judged | Where-Object { $aliceCaught -notcontains $_ })
    if ($aliceCaught.Count -lt 1) { throw "the reckless client (slot $alice) was never caught" }
    if ($missed.Count -gt 0) { throw "the reckless client walked through RED $($missed -join ',') uncaught" }
    Write-Host "PASS same catches on all peers ($(@($h.catches).Count)); reckless slot $alice caught in all $($judged.Count) full REDs: [$($ca[0])]"

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
    Write-Host "statue-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'statue-net-check: OK' } else { Write-Host 'statue-net-check: FAILED' }
exit $exit
