# Shared helpers for the tools/*.ps1 wrappers. Dot-source it: . "$PSScriptRoot\_common.ps1"
# PowerShell 5.1 compatible. Paths resolve relative to the repo root (parent of tools/).

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$GameDir = Join-Path $RepoRoot 'game'

function Find-Exe {
    param([string]$EnvName, [string[]]$Candidates, [string[]]$PathNames)
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) {
        if (Test-Path -LiteralPath $fromEnv -PathType Leaf) { return $fromEnv }
        throw "$EnvName is set to '$fromEnv' but that file does not exist."
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    foreach ($n in $PathNames) {
        $cmd = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    throw "Could not find $($PathNames[0]). Set $EnvName to its full path."
}

function Get-GodotBin {
    Find-Exe 'GODOT_BIN' @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\godot_console.exe')
    ) @('godot_console', 'godot')
}

function Get-BlenderBin {
    Find-Exe 'BLENDER_BIN' @(
        (Join-Path $env:ProgramFiles 'Blender Foundation\Blender 5.2\blender.exe')
    ) @('blender')
}

function ConvertTo-ArgString {
    param([string[]]$ArgList)
    $quoted = foreach ($a in $ArgList) {
        if ($a -eq '') { '""' }
        elseif ($a -match '[\s"]') { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
        else { $a }
    }
    return ($quoted -join ' ')
}

# Runs an executable with a hard timeout, echoes its stdout+stderr, returns
# @{ ExitCode; Output (string[]); TimedOut }. Kills the whole process tree on timeout.
function Invoke-Tool {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 600)
    $id = [guid]::NewGuid().ToString('N')
    $tmp = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tmp "gg_$id.out"
    $errFile = Join-Path $tmp "gg_$id.err"
    Write-Host ">> $Exe $(ConvertTo-ArgString $ArgList)"
    $spArgs = @{
        FilePath               = $Exe
        NoNewWindow            = $true
        PassThru               = $true
        WorkingDirectory       = $RepoRoot
        RedirectStandardOutput = $outFile
        RedirectStandardError  = $errFile
    }
    if ($ArgList -and $ArgList.Count -gt 0) { $spArgs.ArgumentList = (ConvertTo-ArgString $ArgList) }
    $p = Start-Process @spArgs
    $null = $p.Handle  # PS 5.1: caching the handle is required for ExitCode to be populated
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        $null = $p.WaitForExit(10000)
    }
    $lines = @()
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) {
            # Godot colours its output even when redirected; strip ANSI codes so patterns match.
            $lines += @(Get-Content -LiteralPath $f | ForEach-Object { $_ -replace "\x1b\[[0-9;]*[A-Za-z]", '' })
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    # Echo everything except Godot's editor progress-bar chatter.
    foreach ($l in $lines) {
        if ($l -match '^\[\s*(\d+% |DONE )\]' -or $l -eq '') { continue }
        Write-Host $l
    }
    $code = $p.ExitCode
    if ($timedOut) { $code = 124; Write-Host "!! TIMED OUT after $TimeoutSec s (process tree killed)" }
    if ($null -eq $code) { $code = -1 }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines; TimedOut = $timedOut }
}

# Lines Godot prints for real problems (script/parse errors, failed loads, engine errors).
$GodotErrorPattern = '^\s*(SCRIPT ERROR|Parse Error|ERROR|USER ERROR)\b'

function Get-GodotErrors {
    param([string[]]$Lines)
    return @($Lines | Where-Object { $_ -match $GodotErrorPattern })
}
