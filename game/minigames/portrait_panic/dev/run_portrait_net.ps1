# Portrait Panic multi-process check: one headless host and two headless clients on this PC
# (127.0.0.1) play a real one-round Session of portrait_panic, humans driven by bot brains on
# their own peers, bots filling the roster to 4; the host forces MEMORY, DECOY, SWAP on loops 1-3.
# Each actor (portrait_net.gd) writes what it sees to build/portrait-net/<stamp>/<name>.json; this
# runner asserts that all three peers saw the same spawn layout, loops (layout, target, twist,
# decoy, rows), SHOW / hide / reveal / swap / drop events, eliminations and ranking (with ties).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\minigames\portrait_panic\dev\run_portrait_net.ps1 [-Port 24611]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24611, [int]$StepTimeoutSec = 20, [int]$RoundTimeoutSec = 110)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir, $GodotErrorPattern

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\portrait-net\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://minigames/portrait_panic/dev/portrait_net.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--bind-ip=127.0.0.1', '--life=170', '--portrait-twist=memory,decoy,swap') + $Extra
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
            Write-Host "  $n slot=$($s.local_slot) roster=$($s.roster_size) load=$($s.load_id) players=$($s.players) state=$($s.session_state) rounds=$($s.rounds | ConvertTo-Json -Compress) loops=$(@($s.loops).Count) drops=$(@($s.drops).Count) out=$($s.eliminated -join ',')"
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
        Start-Sleep -Milliseconds 250
    }
    Write-Host "FAIL $Desc"
    Show-States @($script:Procs.Keys)
    throw "portrait-net step failed: $Desc"
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
    Send-Cmd 'Host' 'bots 4'
    Wait-For 'roster of 4 (one bot) on every peer' { @($All | Where-Object { (Read-State $_).roster_size -eq 4 }).Count -eq 3 }

    Send-Cmd 'Host' 'session'
    Wait-For 'portrait_panic loaded with 4 players everywhere' {
        $lid = (Read-State 'Host').load_id
        $lid -ge 1 -and @($All | Where-Object { $s = Read-State $_; $s.load_id -eq $lid -and $s.players -eq 4 }).Count -eq 3
    }
    Wait-For 'tiles are dropping' { @((Read-State 'Host').drops).Count -ge 1 } 40
    Wait-For 'round finished on all three' { @($All | Where-Object { @((Read-State $_).rounds).Count -ge 1 }).Count -eq 3 } $RoundTimeoutSec
    Wait-For 'session finished on all three' { @($All | Where-Object { (Read-State $_).events -contains 'session_finished' }).Count -eq 3 } 60

    $rankings = @($All | ForEach-Object { ((Read-State $_).rounds[0] | ConvertTo-Json -Compress) })
    Write-Host "  rankings: $($rankings -join ' | ')"
    if (@($rankings | Select-Object -Unique).Count -ne 1) { throw 'rankings differ between peers' }
    $r = @((Read-State 'Host').rounds[0])
    if ($r.Count -ne 4 -or @($r | Select-Object -Unique).Count -ne 4) { throw "ranking is not 4 distinct slots: $($rankings[0])" }
    $groups = @($All | ForEach-Object { ((Read-State $_).groups) -join ';' })
    Write-Host "  tied groups: $($groups -join ' | ')"
    if (@($groups | Select-Object -Unique).Count -ne 1) { throw 'tied groups differ between peers' }
    Write-Host 'PASS same ranking and tied groups on every peer, every slot once'

    $layouts = @($All | ForEach-Object { (Read-State $_).layout })
    if (@($layouts | Where-Object { -not $_ }).Count -gt 0) { throw "a peer never applied the spawn layout: $($layouts -join ' | ')" }
    if (@($layouts | Select-Object -Unique).Count -ne 1) { throw "spawn layouts differ: $($layouts -join ' | ')" }
    Write-Host "PASS same spawn layout on every peer ($($layouts[0]))"

    foreach ($key in @('loops', 'shows', 'hides', 'reveals', 'swaps', 'drops')) {
        $seen = @($All | ForEach-Object { ((Read-State $_).$key) -join "`n" })
        if (@($seen | Select-Object -Unique).Count -ne 1) {
            foreach ($n in $All) { Write-Host "    $n ${key}:"; @((Read-State $n).$key) | ForEach-Object { Write-Host "      $_" } }
            throw "$key differ between peers"
        }
        Write-Host "PASS same $key on every peer ($(@((Read-State 'Host').$key).Count))"
    }
    $h = Read-State 'Host'
    @($h.loops) | ForEach-Object { $f = $_ -split '\|'; Write-Host "    loop $($f[0]): target $($f[2]) twist $($f[3]) decoy $($f[4]) rows $($f[5]) show $($f[6]) s" }
    if (@($h.hides).Count -lt 1) { throw 'no MEMORY hide happened' }
    if (@($h.loops).Count -ge 3 -and (@($h.reveals).Count -lt 1 -or @($h.swaps).Count -lt 1)) { throw 'DECOY or SWAP did not happen' }
    $faces = @($All | ForEach-Object { (@((Read-State $_).faces_after_hide)) -join ',' })
    Write-Host "  faces still up 0.8 s after the MEMORY hide: $($faces -join ' | ')"
    foreach ($f in $faces) { if (-not $f -or @($f -split ',' | Where-Object { [int]$_ -ne 0 }).Count -gt 0) { throw "MEMORY did not hide every face on every peer: $($faces -join ' | ')" } }
    Write-Host 'PASS MEMORY hid every face on every peer'
    $outs = @($All | ForEach-Object { (@((Read-State $_).eliminated) | Sort-Object) -join ',' })
    if (@($outs | Select-Object -Unique).Count -ne 1) { throw "eliminations differ: $($outs -join ' | ')" }
    Write-Host "PASS same eliminations everywhere ($($outs[0]))"

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
    Write-Host "portrait-net: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'portrait-net: OK' } else { Write-Host 'portrait-net: FAILED' }
exit $exit
