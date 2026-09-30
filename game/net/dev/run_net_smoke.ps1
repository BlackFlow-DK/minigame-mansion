# Net multi-process smoke test: one headless host, two headless clients and a LAN scanner on
# this PC (127.0.0.1), plus short-lived clients that must be refused. Each actor
# (game/net/dev/net_smoke.gd) writes what it sees to build/net-smoke/<stamp>/<name>.json; this
# runner drives them through <name>.cmd files and asserts they agree.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File game\net\dev\run_net_smoke.ps1 [-Port 24585] [-BindIp 127.0.0.1]
# Exit 0 when every check passes. Always kills the processes it started.
param([int]$Port = 24585, [int]$StepTimeoutSec = 15, [string]$BindIp = '')
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Root 'tools\_common.ps1')  # Get-GodotBin, ConvertTo-ArgString, $GameDir

$godot = Get-GodotBin
$Dir = Join-Path $Root ('build\net-smoke\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$GodotDir = $Dir -replace '\\', '/'
$script:Procs = [ordered]@{}

function Start-Actor([string]$Name, [string[]]$Extra) {
    $argList = @('--headless', '--path', $GameDir, 'res://net/dev/net_smoke.tscn', '--',
        "--name=$Name", "--dir=$GodotDir", "--port=$Port", '--life=120') + $Extra
    if ($BindIp) { $argList += "--bind-ip=$BindIp" }
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

function Wait-For([string]$Desc, [scriptblock]$Cond) {
    $deadline = (Get-Date).AddSeconds($StepTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try { $ok = [bool](& $Cond) } catch { $ok = $false }
        if ($ok) { Write-Host "PASS $Desc"; return }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "FAIL $Desc"
    foreach ($n in $script:Procs.Keys) {
        $s = Read-State $n
        if ($s) { Write-Host "  $n : slot=$($s.local_slot) roster=$($s.roster_key) events=$(($s.events | Select-Object -Last 6) -join ',')" }
    }
    throw "smoke step failed: $Desc"
}

function Get-Events([string]$Name) { $s = Read-State $Name; if ($s) { return @($s.events) } else { return @() } }

# True when every named actor reports the same roster with $Count entries.
function Test-Agree([string[]]$Names, [int]$Count) {
    $keys = @()
    foreach ($n in $Names) {
        $s = Read-State $n
        if ($null -eq $s) { return $false }
        if (@($s.roster).Count -ne $Count) { return $false }
        $keys += $s.roster_key
    }
    return (@($keys | Select-Object -Unique).Count -eq 1)
}

function Get-Roster([string]$Name) { return @((Read-State $Name).roster) }

$exit = 1
try {
    Start-Actor 'Host' @('--role=host')
    Wait-For 'host is up (slot 0)' { (Get-Events 'Host') -contains 'host_game:OK' -and (Read-State 'Host').local_slot -eq 0 }

    Start-Actor 'Scan' @('--role=scan')
    Start-Actor 'Alice' @('--role=client', "--join=127.0.0.1:$Port")
    Start-Actor 'Bob' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'all three agree after joins' {
        (Test-Agree @('Host', 'Alice', 'Bob') 3) -and
        ((@(Get-Roster 'Host' | ForEach-Object { $_.name }) | Sort-Object) -join ',') -eq 'Alice,Bob,Host' -and
        (Read-State 'Alice').local_slot -ge 1 -and (Read-State 'Bob').local_slot -ge 1 -and
        (Read-State 'Alice').local_slot -ne (Read-State 'Bob').local_slot -and
        (Read-State 'Host').local_slot -eq 0 -and -not (Read-State 'Alice').is_host
    }
    Write-Host "  roster: $((Read-State 'Host').roster_key)"

    Wait-For 'discovery (second process) lists the host once, 3 players, in lobby' {
        $g = @((Read-State 'Scan').games | Where-Object { $_.port -eq $Port })
        $g.Count -eq 1 -and $g[0].players -eq 3 -and $g[0].in_lobby -and $g[0].game_name -eq 'Smoke Game' -and $g[0].compatible
    }
    $g = @((Read-State 'Scan').games | Where-Object { $_.port -eq $Port })[0]
    Write-Host "  found: $($g.address) '$($g.game_name)' host=$($g.host_name) $($g.players)/$($g.max_players)"

    Send-Cmd 'Alice' 'profile Alice2 #112233'
    Wait-For 'all three agree after a profile change' {
        (Test-Agree @('Host', 'Alice', 'Bob') 3) -and
        @(Get-Roster 'Bob' | Where-Object { $_.name -eq 'Alice2' -and $_.primary -eq '#112233' }).Count -eq 1
    }

    Send-Cmd 'Host' 'add_bot'
    Wait-For 'all three agree after adding a bot' {
        (Test-Agree @('Host', 'Alice', 'Bob') 4) -and @(Get-Roster 'Alice' | Where-Object { $_.is_bot -and $_.peer_id -eq 1 }).Count -eq 1
    }

    Send-Cmd 'Bob' 'quit'
    Wait-For 'Bob exited' { $script:Procs['Bob'].HasExited }
    Wait-For 'host and Alice agree after Bob quit (slot freed)' {
        (Test-Agree @('Host', 'Alice') 3) -and @(Get-Roster 'Host' | Where-Object { $_.name -eq 'Bob' }).Count -eq 0
    }

    Start-Actor 'OldVersion' @('--role=client', "--join=127.0.0.1:$Port", '--proto=999')
    Wait-For 'mismatched protocol is refused: version mismatch' { (Get-Events 'OldVersion') -contains 'join_failed:version mismatch' }

    Send-Cmd 'Host' 'in_progress 1'
    Wait-For 'in_progress replicated to Alice' { (Read-State 'Alice').in_progress -eq $true }
    Start-Actor 'Late' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'late joiner is refused: in progress' { (Get-Events 'Late') -contains 'join_failed:in progress' }
    Send-Cmd 'Host' 'in_progress 0'

    Send-Cmd 'Host' 'fill_bots'
    Wait-For 'host and Alice agree on a full roster' { Test-Agree @('Host', 'Alice') 8 }
    Start-Actor 'Extra' @('--role=client', "--join=127.0.0.1:$Port")
    Wait-For 'ninth player is refused: full' { (Get-Events 'Extra') -contains 'join_failed:full' }
    Wait-For 'refused clients never entered the roster' {
        (Test-Agree @('Host', 'Alice') 8) -and
        @(Get-Roster 'Host' | Where-Object { $_.name -in @('OldVersion', 'Late', 'Extra') }).Count -eq 0
    }

    Send-Cmd 'Host' 'quit'
    Wait-For 'Alice gets server_closed and is back offline with no roster' {
        $s = Read-State 'Alice'
        (@($s.events) -contains 'server_closed') -and $s.offline_peer -and @($s.roster).Count -eq 0 -and $s.local_slot -eq -1
    }
    Send-Cmd 'Scan' 'quit'
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
        throw "error lines in actor logs"
    }
    Write-Host 'PASS no error lines in actor logs'
    $exit = 0
} catch {
    Write-Host "net-smoke: $($_.Exception.Message)"
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
if ($exit -eq 0) { Write-Host 'net-smoke: OK' } else { Write-Host 'net-smoke: FAILED' }
exit $exit
