<#
.SYNOPSIS
    Uninstall / clean up the C2 server on Windows. Stops the running server
    and deletes the virtualenv(s), database(s), agent token, logs, PID/port
    files and build artifacts. Source code and client agents are kept.

.DESCRIPTION
    Removes the artifacts created on this platform (Windows) plus the
    platform-neutral state and build output:
      server\.venv                          (virtualenv)
      server\wym.db                         (database)
      server\.agent_token, server\server.log, server\server.err.log
      server\.server.pid, server\.server.port
      server\shared, server\collected       (staged/pulled agent files)
      server\builds and __pycache__         (build artifacts)
      dist\                                (iOS-builder output, if any)

    Unix/WSL artifacts (.venv-wsl, wym_wsl.db, .agent_token_wsl,
    .server.pid/.port_wsl, server_wsl.log) are left untouched.

    Adds -Force to skip the confirmation prompt.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Force
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = "Stop"
$Root     = $PSScriptRoot
$Server   = Join-Path $Root "server"
$PidFile  = Join-Path $Server ".server.pid"
$PortFile = Join-Path $Server ".server.port"
$Main     = Join-Path $Server "main.py"
$VenvPy   = Join-Path $Server ".venv\Scripts\python.exe"

function Hdr($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Info($m){ Write-Host "  [..] $m" -ForegroundColor Gray }

if (-not (Test-Path -LiteralPath $Server)) {
    Warn "server dir not found: $Server"
    exit 1
}

if (-not $Force) {
    Hdr "Uninstall C2 server"
    Write-Host "This will stop the server and delete virtualenvs, databases,"
    Write-Host "the agent token, logs and build artifacts (source files are kept)."
    $ans = Read-Host "Continue? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted."; exit 0 }
}

function Get-PythonProcesses {
    $procs = @()
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^python' })
    } else {
        $procs = @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^python' })
    }
    return $procs
}

function Test-OurServerPid([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    $running = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $running) { return $false }
    foreach ($p in Get-PythonProcesses) {
        if ([int]$p.ProcessId -ne $ProcessId) { continue }
        $cl = [string]$p.CommandLine
        $exe = [string]$p.ExecutablePath
        if ($cl -and ($cl -like "*$Main*" -or $cl -match 'main\.py')) { return $true }
        if ($exe -and ($exe -eq $VenvPy)) { return $true }
    }
    return $false
}

Hdr "Stopping server"
$stopped = $false
if (Test-Path -LiteralPath $PidFile) {
    $old = 0
    [void][int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(), [ref]$old)
    if ($old -gt 0 -and (Test-OurServerPid $old)) {
        Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
        Info "stopped server (PID $old)"
        $stopped = $true
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}
if (-not $stopped) { Info "no running server found" }

Hdr "Removing files"
$files = @(
    $PidFile,
    $PortFile,
    (Join-Path $Server "server.log"),
    (Join-Path $Server "server.err.log"),
    (Join-Path $Server ".agent_token"),
    (Join-Path $Server "wym.db")
)
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force
        Info "removed $f"
    }
}
$dirs = @(
    (Join-Path $Server ".venv"),
    (Join-Path $Server "builds"),
    (Join-Path $Server "shared"),
    (Join-Path $Server "collected")
)
foreach ($d in $dirs) {
    if (Test-Path -LiteralPath $d) {
        Remove-Item -LiteralPath $d -Recurse -Force
        Info "removed $d"
    }
}
$Dist = Join-Path $Root "dist"
if (Test-Path -LiteralPath $Dist) {
    Remove-Item -LiteralPath $Dist -Recurse -Force
    Info "removed $Dist"
}

Hdr "Cleaning Python bytecode caches"
$caches = @(Get-ChildItem -LiteralPath $Server -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue)
foreach ($c in $caches) {
    Remove-Item -LiteralPath $c.FullName -Recurse -Force
    Info "removed $($c.FullName)"
}

Ok "done. Source code, clients and installer scripts were kept."