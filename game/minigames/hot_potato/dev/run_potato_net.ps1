# Hot Potato multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), a roster bot fills to 4, one Session round of Hot Potato with every blob driven
# by a bot brain. Each actor (potato_net.gd) writes what it saw to
# build/potato-net/<stamp>/<name>.json. Asserts all three peers saw the same hand-overs
# (every new bomb, pass and explosion, in order) and the same final ranking, which holds all
# four slots exactly once, and that no actor logged an error.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\hot_potato\dev\run_potato_net.ps1 [-Port 24597]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24597, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 150, [double]$TimeScale = 10, [double]$PotatoTimeScale = 2)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\potato-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/hot_potato/dev/potato_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=240',
        "--time-scale=$TimeScale", "--potato-time-scale=$PotatoTimeScale") + $Extra
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) holder=$($s.holder) out=$($s.knocked_out -join ',')"
            Write-Host "     handovers=$($s.handovers -join ' ')"
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
    throw "potato-net step failed: $Desc"
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
    Wait-For 'Hot Potato round intro on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:0:hot_potato' }).Count -eq 3
    }
    Wait-For 'first bomb handed out on every peer' {
        @($All | Where-Object { @((Read-State $_).handovers).Count -ge 1 }).Count -eq 3
    }
    Wait-For 'round finished on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3
    } $RoundTimeoutSec

    $hand = @($All | ForEach-Object { (@((Read-State $_).handovers) -join ' ') })
    $rank = @($All | ForEach-Object { ((Read-State $_).rankings | ConvertTo-Json -Compress -Depth 5) })
    Write-Host "  host hand-overs ($(@((Read-State 'Host').handovers).Count)): $($hand[0])"
    Write-Host "  rankings: $($rank -join ' | ')"
    if (@($hand | Select-Object -Unique).Count -ne 1) {
        $All | ForEach-Object { Write-Host "  $_ : $(@((Read-State $_).handovers) -join ' ')" }
        throw 'hand-overs differ between peers'
    }
    Write-Host 'PASS every peer saw the same hand-overs in the same order'
    if (@($rank | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $r = @((Read-State 'Host').rankings[0])
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($r -join ',')" }
    foreach ($s in 0..3) { if ($r -notcontains $s) { throw "slot $s missing from ranking $($r -join ',')" } }
    $booms = @((Read-State 'Host').handovers | Where-Object { $_ -like 'boom:*' })
    if ($booms.Count -ne 3) { throw "expected 3 explosions, saw $($booms.Count)" }
    $order = @($booms | ForEach-Object { [int]($_ -replace 'boom:', '') })
    [array]::Reverse($order)
    $expect = @($r | Select-Object -Skip 1)
    if (($order -join ',') -ne ($expect -join ',')) { throw "ranking $($r -join ',') does not follow the explosions $($booms -join ',')" }
    Write-Host "PASS identical ranking on all peers: $($r -join ',') (winner first, then reverse explosion order)"

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
    Write-Host "potato-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'potato-net: OK' } else { Write-Host 'potato-net: FAILED' }
exit $exit
