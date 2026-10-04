# Hide and Sneak multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), three roster bots fill to 6 (so 2 seekers), one Session round of Hide and Sneak.
# The host forces the seekers: Alice's slot (1) and a bot (3). Each actor (hide_net.gd) writes
# what it saw to build/hide-net/<stamp>/<name>.json. Asserts all three peers built the same
# room (layout fingerprint), saw the same seekers, the same prop kind on the same hiders when
# SEEK started, the same reveals in the same order (at least one) and the same ranking (all six
# slots once), that only the seeker's own peer (Alice) was blacked out during HIDE, and that no
# actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\hide_and_sneak\dev\run_hide_net.ps1 [-Port 24598]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24598, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 150, [double]$TimeScale = 3)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\hide-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/hide_and_sneak/dev/hide_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=240',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) seekers=$($s.seekers) blackout=$($s.blackout)"
            Write-Host "     disguises=$($s.disguises) reveals=$($s.reveals -join ' ')"
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
    throw "hide-net step failed: $Desc"
}

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host', '--hide-seekers=1,3')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 }).Count -eq 3 -and (Read-State 'Bob').local_slot -ge 1 }
    if ((Read-State 'Alice').local_slot -ne 1) { throw "Alice is slot $((Read-State 'Alice').local_slot), expected 1" }
    Send-Cmd 'Host' 'bot'
    Send-Cmd 'Host' 'bot'
    Send-Cmd 'Host' 'bot'
    Wait-For 'bots fill the roster to 6 everywhere' { @($All | Where-Object { (Read-State $_).roster_size -eq 6 }).Count -eq 3 }

    Send-Cmd 'Host' 'session 1'
    Wait-For 'Hide and Sneak round intro on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:0:hide_and_sneak' }).Count -eq 3
    }
    Wait-For 'SEEK started on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'phase:2' }).Count -eq 3
    } 40
    Wait-For 'round finished on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3
    } $RoundTimeoutSec

    $st = @{}
    foreach ($n in $All) { $st[$n] = Read-State $n }
    foreach ($key in @('layout', 'seekers', 'disguises')) {
        $vals = @($All | ForEach-Object { [string]$st[$_].$key })
        Write-Host "  $key : $($vals -join ' | ')"
        if (@($vals | Select-Object -Unique).Count -ne 1 -or $vals[0] -eq '') { throw "$key differs between peers (or is empty)" }
        Write-Host "PASS every peer saw the same $key"
    }
    if ($st['Host'].seekers -ne '1,3') { throw "seekers are $($st['Host'].seekers), expected 1,3" }
    $kinds = @(($st['Host'].disguises -split ' ') | Where-Object { $_ -ne '' })
    if ($kinds.Count -ne 4) { throw "expected 4 disguised hiders at SEEK start, saw $($kinds.Count): $($st['Host'].disguises)" }
    Write-Host "PASS 4 hiders wore the same props on every peer: $($st['Host'].disguises)"
    $rev = @($All | ForEach-Object { (@($st[$_].reveals) -join ' ') })
    Write-Host "  reveals: $($rev -join ' | ')"
    if (@($rev | Select-Object -Unique).Count -ne 1) { throw 'reveals differ between peers' }
    if (@($st['Host'].reveals).Count -lt 1) { throw 'nobody was found (expected at least one reveal)' }
    Write-Host "PASS every peer saw the same reveals in the same order ($(@($st['Host'].reveals).Count))"
    $rank = @($All | ForEach-Object { ($st[$_].groups | ConvertTo-Json -Compress -Depth 5) })
    Write-Host "  ranking groups: $($rank -join ' | ')"
    if (@($rank | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $r = @($st['Host'].rankings[0])
    if ($r.Count -ne 6 -or @($r | Select-Object -Unique).Count -ne 6) { throw "ranking is not 6 distinct slots: $($r -join ',')" }
    Write-Host "PASS identical ranking on all peers: $($r -join ',')"
    $black = @($All | ForEach-Object { "$($_)=$($st[$_].blackout)" })
    Write-Host "  blackout: $($black -join ' ')"
    if (-not $st['Alice'].blackout) { throw 'the seeker (Alice) was not blacked out during HIDE' }
    if ($st['Host'].blackout -or $st['Bob'].blackout) { throw 'a hider peer was blacked out' }
    Write-Host 'PASS the blackout showed only on the seeker''s peer'

    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 }
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
    Write-Host "hide-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'hide-net: OK' } else { Write-Host 'hide-net: FAILED' }
exit $exit
