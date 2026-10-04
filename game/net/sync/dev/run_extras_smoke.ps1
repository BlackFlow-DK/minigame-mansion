# NPC extras multi-process smoke: one headless host and two headless clients on this PC
# (127.0.0.1), using the sync smoke actor (game/net/sync/dev/sync_smoke.gd). Checks: every peer
# gets the same 20 extras (names X100.., host authority) through the manifest; after 3 s of
# wandering they moved and every peer sees them in the same place (loose while walking, strict
# once frozen); a client shoves an extra (got_hit once on every peer, the extra is knocked, peers
# agree after); despawn reaches every peer; no error lines. Also measures the host's ENet send
# rate without and with the 20 extras and prints the extra bytes/s per client.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\net\sync\dev\run_extras_smoke.ps1 [-Port 24596]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24596, [int]$StepTimeoutSec = 20, [int]$Extras = 20)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\extras-smoke\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}
$script:Reported = $false

function Fail([string]$Reason) {
    Write-Host "FAIL $Reason"
    $script:Reported = $true
    throw $Reason
}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://net/sync/dev/sync_smoke.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=120') + $Extra
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

function Wait-For([string]$Desc, [scriptblock]$Cond, [int]$Timeout = $StepTimeoutSec) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try { $ok = [bool](& $Cond) } catch { $ok = $false }
        if ($ok) { Write-Host "PASS $Desc"; return }
        Start-Sleep -Milliseconds 200
    }
    foreach ($n in $script:Procs.Keys) {
        $s = Read-State $n
        if ($s) { Write-Host "  $n extras=$(@($s.extras.PSObject.Properties).Count) counts=$($s.counts | ConvertTo-Json -Compress) events=$(($s.events | Select-Object -Last 4) -join ',')" }
    }
    Fail "timed out: $Desc"
}

function Get-Extras([string]$Name) {
    $s = Read-State $Name
    if ($null -eq $s) { return @() }
    return @($s.extras.PSObject.Properties)
}

function Get-Count([string]$Name, [string]$Key) {
    $s = Read-State $Name
    if ($null -eq $s -or $null -eq $s.counts.$Key) { return 0 }
    return [int]$s.counts.$Key
}

function Get-Dist($a, $b) { return [math]::Sqrt([math]::Pow($a.x - $b.x, 2) + [math]::Pow($a.z - $b.z, 2)) }

# Largest distance between the host's view of any extra and a client's view of it ($null if a
# peer lacks one). The states are read back to back.
function Get-ExtrasSpread([string[]]$Names) {
    $states = @{}
    foreach ($n in $Names) { $states[$n] = Read-State $n }
    $worst = 0.0
    foreach ($e in @($states['Host'].extras.PSObject.Properties)) {
        foreach ($n in $Names) {
            $o = $states[$n].extras."$($e.Name)"
            if ($null -eq $o) { return $null }
            $d = Get-Dist $e.Value $o
            if ($d -gt $worst) { $worst = $d }
        }
    }
    return $worst
}

# Host's ENet send rate (bytes/s): mean of $Samples one-second readings.
function Get-TxRate([int]$Samples = 3) {
    $sum = 0.0
    for ($i = 0; $i -lt $Samples; $i++) {
        Start-Sleep -Milliseconds 1050
        $sum += [double](Read-State 'Host').tx_bps
    }
    return $sum / $Samples
}

$All = @('Host', 'Alice', 'Bob')
$Clients = 2
$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up' { (Read-State 'Host').events -contains 'host_game:OK' }
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'Alice joined' { (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Host').roster_size -eq 2 }
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all joined' { @($All | Where-Object { (Read-State $_).roster_size -eq 3 }).Count -eq 3 -and (Read-State 'Bob').local_slot -ge 1 }
    $A = [int](Read-State 'Alice').local_slot

    Send-Cmd 'Host' 'load dev'
    Wait-For 'every peer loaded the arena with 3 players' {
        $lid = (Read-State 'Host').load_id
        @($All | Where-Object { $s = Read-State $_; $s.load_id -eq $lid -and $lid -ge 1 -and @($s.players.PSObject.Properties).Count -eq 3 }).Count -eq 3
    }
    Send-Cmd 'Host' 'unfreeze'
    $base = Get-TxRate
    Write-Host ("  host sends {0:N0} B/s with 3 players and no extras" -f $base)

    # 1. Spawn: same extras everywhere, owned by the host.
    Send-Cmd 'Host' "extras $Extras wander"
    Wait-For "every peer has the same $Extras extras (X100.., host authority, simulated on the host only)" {
        $ok = $true
        $names = (@(Get-Extras 'Host') | ForEach-Object { $_.Value.name }) -join ','
        if (@(Get-Extras 'Host').Count -ne $Extras -or -not $names.StartsWith('X100,X101')) { $ok = $false }
        foreach ($n in $All) {
            $xs = @(Get-Extras $n)
            if ($xs.Count -ne $Extras -or (($xs | ForEach-Object { $_.Value.name }) -join ',') -ne $names) { $ok = $false }
            foreach ($x in $xs) { if ($x.Value.auth -ne 1 -or [bool]$x.Value.local -ne ($n -eq 'Host')) { $ok = $false } }
        }
        $ok
    }
    $spawn = @{}
    foreach ($x in @(Get-Extras 'Host')) { $spawn[$x.Name] = $x.Value }

    # 2. Three seconds of wandering: they moved; peers agree (loosely while walking).
    Start-Sleep -Seconds 3
    $moved = @(Get-Extras 'Host' | Where-Object { (Get-Dist $_.Value $spawn[$_.Name]) -gt 0.5 }).Count
    Write-Host "  $moved of $Extras extras moved more than 0.5 m on the host"
    if ($moved -lt [math]::Ceiling($Extras / 2)) { Fail "only $moved extras wandered" }
    $spread = Get-ExtrasSpread $All
    Write-Host ("  while wandering: worst host/client difference {0:N2} m" -f $spread)
    if ($null -eq $spread -or $spread -gt 1.0) { Fail "peers disagree on walking extras ($spread m)" }
    $rate = Get-TxRate
    $perClient = ($rate - $base) / $Clients
    Write-Host ("  host sends {0:N0} B/s with {1} extras: +{2:N0} B/s per client ({3:N0} B/s per extra per client)" -f $rate, $Extras, $perClient, ($perClient / $Extras))
    Wait-For 'peers agree on wandering extras within 1.0 m' { $s = Get-ExtrasSpread $All; $null -ne $s -and $s -le 1.0 }

    # 3. Frozen: exact agreement.
    Send-Cmd 'Host' 'freeze_extras 1'
    Start-Sleep -Milliseconds 1200
    Wait-For 'peers agree on stopped extras within 0.1 m' { $s = Get-ExtrasSpread $All; $null -ne $s -and $s -le 0.1 }

    # 4. Alice shoves X100 (idle, unfrozen: frozen blobs ignore hits).
    Send-Cmd 'Host' 'extras_mode idle'
    Send-Cmd 'Host' 'freeze_extras 0'
    Start-Sleep -Milliseconds 500
    $before = (Read-State 'Host').extras.'100'
    Send-Cmd 'Alice' 'shove 100'
    Wait-For 'shove_hit on X100 raised on every peer' { @($All | Where-Object { (Get-Count $_ "shove_hit:$A") -ge 1 }).Count -eq 3 } 30
    Wait-For 'got_hit for X100 raised exactly once on every peer' { @($All | Where-Object { (Get-Count $_ 'got_hit:100') -eq 1 }).Count -eq 3 }
    Start-Sleep -Milliseconds 1500
    $pushed = Get-Dist $before (Read-State 'Host').extras.'100'
    Write-Host ("  X100 pushed {0:N2} m (host view)" -f $pushed)
    if ($pushed -lt 0.5) { Fail "X100 was not pushed ($pushed m)" }
    Wait-For 'peers agree after the shove within 0.15 m' { $s = Get-ExtrasSpread $All; $null -ne $s -and $s -le 0.15 }

    # 5. Despawn reaches every peer; players stay.
    Send-Cmd 'Host' 'despawn_extras'
    Wait-For 'extras gone on every peer, players kept' {
        @($All | Where-Object { $s = Read-State $_; @($s.extras.PSObject.Properties).Count -eq 0 -and @($s.players.PSObject.Properties).Count -eq 3 }).Count -eq 3
    }

    foreach ($n in $All) { Send-Cmd $n 'quit' }
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
        Fail 'error lines in actor logs'
    }
    Write-Host 'PASS no error lines in actor logs'
    $exit = 0
} catch {
    if (-not $script:Reported) { Write-Host "FAIL $($_.Exception.Message)" }
    Write-Host "extras-smoke: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'extras-smoke: OK' } else { Write-Host 'extras-smoke: FAILED' }
exit $exit
