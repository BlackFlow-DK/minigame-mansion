# Paint Splat multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1), bots filling to 4. Each actor (paint_net_check.gd) plays one Session round of
# Paint Splat and writes what it sees to build/paint-net-check/<stamp>/<name>.json. Asserts
# that every peer applied the same paint batches and splash bombs, and ends with an identical
# tile ownership map, tile counts and ranking (the minigame's and Session's).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\paint_splat\dev\run_paint_net_check.ps1 [-Port 24661] [-TimeScale 2]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24661, [int]$StepTimeoutSec = 20, [double]$TimeScale = 2)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\paint-net-check\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/paint_splat/dev/paint_net_check.tscn', '--',
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) state=$($s.session_state) batches=$($s.batches) hits=$($s.hits)"
            Write-Host "     live=$($s.live_counts | ConvertTo-Json -Compress) final=$($s.final_counts | ConvertTo-Json -Compress) ranking=$($s.final_ranking -join ',') events=$(($s.events | Select-Object -Last 5) -join ',')"
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
    throw "paint net check failed: $Desc"
}

# Every actor reports the same value (compared as compact JSON).
function Assert-Same([string]$What, [scriptblock]$Get) {
    $vals = @($All | ForEach-Object { ConvertTo-Json -InputObject (& $Get (Read-State $_)) -Compress -Depth 6 })
    $shown = $vals[0]
    if ($shown.Length -gt 160) { $shown = $shown.Substring(0, 160) + '...' }
    Write-Host "  ${What}: $shown"
    if (@($vals | Select-Object -Unique).Count -ne 1) {
        for ($i = 0; $i -lt $All.Count; $i++) { Write-Host "    $($All[$i]): $($vals[$i])" }
        throw "$What differs between peers"
    }
    Write-Host "PASS identical $What on all peers"
}

$All = @('Host', 'Alice', 'Bob')
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Bob joined' { (Read-State 'Bob').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 3 }
    Send-Cmd 'Host' 'bots 1'
    Wait-For 'roster of 4 on every peer' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }
    $A = [int](Read-State 'Alice').local_slot
    $B = [int](Read-State 'Bob').local_slot
    Write-Host "  slots: Host=0 Alice=$A Bob=$B"

    Send-Cmd 'Host' 'start'
    Wait-For 'Paint Splat loaded on every peer' {
        @($All | Where-Object { (Read-State $_).events -contains 'round_intro:paint_splat.tscn' }).Count -eq 3
    }
    $roundSec = [int](48 / $TimeScale) + 30
    Wait-For 'round over on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_over' }).Count -eq 3 } $roundSec
    Wait-For 'Session results on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'round_finished' }).Count -eq 3 }
    Start-Sleep -Milliseconds 500
    Show-States $All

    Assert-Same 'tile ownership map' { param($s) @($s.owner_map) }
    Assert-Same 'final tile counts' { param($s) $s.final_counts }
    Assert-Same 'final ranking' { param($s) @($s.final_ranking) }
    Assert-Same 'Session round ranking' { param($s) @($s.round_ranking) }
    Assert-Same 'paint batches applied' { param($s) $s.batches }
    Assert-Same 'tiles painted per slot' { param($s) $s.painted }
    Assert-Same 'splash bomb log in order' { param($s) @($s.bomb_log) }

    $h = Read-State 'Host'
    $rank = @($h.final_ranking)
    if ($rank.Count -ne 4 -or @($rank | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rank -join ',')" }
    foreach ($s in @(0, $A, $B)) { if ($rank -notcontains $s) { throw "slot $s missing from the ranking" } }
    Write-Host 'PASS ranking holds every slot once'
    $prev = [int]::MaxValue
    foreach ($s in $rank) {
        $c = [int]$h.final_counts."$s"
        if ($c -gt $prev) { throw "ranking not ordered by tiles: $($rank -join ',')" }
        $prev = $c
    }
    Write-Host 'PASS ranking ordered by tiles'
    $owned = @($h.owner_map)
    if ($owned.Count -ne 196) { throw "owner map has $($owned.Count) tiles, expected 196" }
    $sum = 0
    foreach ($s in $rank) {
        $n = @($owned | Where-Object { $_ -eq $s }).Count
        if ($n -ne [int]$h.final_counts."$s") { throw "slot $s owns $n tiles but counts $($h.final_counts."$s")" }
        $sum += $n
    }
    $painted = @($owned | Where-Object { $_ -ge 0 }).Count
    if ($sum -ne $painted) { throw "counts ($sum) do not add up to the painted tiles ($painted)" }
    Write-Host "PASS counts match the ownership map ($painted of 196 painted)"
    $clientTiles = [int]$h.painted."$A" + [int]$h.painted."$B"
    $bombs = @($h.bomb_log | Where-Object { $_[0] -eq 'spawn' }).Count
    Write-Host "  tiles painted by client-owned players (host view): $clientTiles; batches $($h.batches); bombs $bombs; hits $($h.hits)"
    if ($clientTiles -lt 5) { throw 'the host barely credited client-owned players with paint' }
    Write-Host 'PASS host credits paint to client-owned players'
    if ($bombs -lt 1) { throw 'no splash bomb dropped' }

    Wait-For 'session finished on every peer' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 }
    Send-Cmd 'Host' 'quit'
    Wait-For 'clients get server_closed' { @(@('Alice', 'Bob') | Where-Object { (Read-State $_).events -contains 'server_closed' }).Count -eq 2 }
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
    Write-Host "paint-net-check: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'paint-net-check: OK' } else { Write-Host 'paint-net-check: FAILED' }
exit $exit
