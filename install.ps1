<#
.SYNOPSIS
    Setup / install the C2 server on Windows. Creates a venv, installs
    requirements.txt, validates host/port + username/password, and starts the
    server. When C2_PASSWORD is not provided a strong random password is
    generated and printed, and the admin user is created/reset to it on every
    start (so login always matches).

.DESCRIPTION
    Design:
      1. Resolve & VALIDATE defaults for host, port, username.
      2. Determine password: -Password > $env:C2_PASSWORD > random generated
         password (always printed).
      3. Create server\.venv if missing and pip-install requirements.txt.
      4. Verify builder toolchain for "build on server" (report missing, no
         auto-install).
      5. Start the server (background by default, -Foreground / -Action run
         for console mode). Writes server\.server.pid so uninstall.ps1 can
         stop the right process. On each startup the server re-syncs the admin
         user to the effective password via sync_default_user.

    Port default: 8000 (Windows). Other OS install scripts use their own.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Action check
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Port 8080
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Password "a-strong-password"
#>
[CmdletBinding()]
param(
    [ValidateSet("install", "check", "start", "stop", "run")]
    [string]$Action = "install",
    [Alias("Host")]
    [string]$ListenHost = "",
    [string]$User   = "",
    [string]$Password = "",
    [int]$Port = 0,
    [switch]$Foreground
)

$ErrorActionPreference = "Stop"
$Root     = $PSScriptRoot
$Server   = Join-Path $Root "server"
$Venv     = Join-Path $Server ".venv"
$Py       = Join-Path $Venv "Scripts\python.exe"
$Reqs     = Join-Path $Root "requirements.txt"
$Main     = Join-Path $Server "main.py"
$PidFile  = Join-Path $Server ".server.pid"
$PortFile = Join-Path $Server ".server.port"

function Hdr($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Info($m){ Write-Host "  [..] $m" -ForegroundColor Gray }

function Get-PythonLauncher {
    foreach ($name in @("python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($name -eq "py") { return @{ Path = $cmd.Source; Args = @("-3") } }
        return @{ Path = $cmd.Source; Args = @() }
    }
    return $null
}

# ---------------- defaults + validation ----------------
Hdr "Configuration"
if ($ListenHost -eq "") { $ListenHost = $env:C2_HOST }
if ($ListenHost -eq "") { $ListenHost = "127.0.0.1" }
if ($User -eq "") { $User = $env:C2_USER }
if ($User -eq "") { $User = "admin" }
if ($Port -eq 0)  { if ($env:C2_PORT) { $Port = [int]$env:C2_PORT } else { $Port = 8000 } }

if ($Port -lt 1 -or $Port -gt 65535) { throw "invalid port: $Port" }
if ([string]::IsNullOrWhiteSpace($ListenHost)) { throw "host must not be empty" }
if ([string]::IsNullOrWhiteSpace($User)) { throw "user must not be empty" }

$PasswordFinal = ""
function New-RandomPass {
    return -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object {[char]$_})
}
if ($Password -ne "") {
    $PasswordFinal = $Password
} elseif ($env:C2_PASSWORD) {
    $PasswordFinal = $env:C2_PASSWORD
}
if (-not $PasswordFinal) {
    $PasswordFinal = New-RandomPass
    Warn "no password provided -> generated random password: $PasswordFinal"
}

Info "host   : $ListenHost"
Info "port   : $Port"
Info "user   : $User"
Info "pass   : (set)"

if (-not (Test-Path -LiteralPath $Server)) { throw "server dir not found: $Server" }
if (-not (Test-Path -LiteralPath $Reqs))   { throw "requirements.txt not found: $Reqs" }
if (-not (Test-Path -LiteralPath $Main))   { throw "server entrypoint not found: $Main" }

# ---------------- venv + deps ----------------
function Ensure-Venv {
    Hdr "Python environment"
    if (-not (Test-Path -LiteralPath $Py)) {
        $launcher = Get-PythonLauncher
        if (-not $launcher) { Warn "python not found on PATH"; exit 1 }
        $venvArgs = $launcher.Args + @("-m", "venv", $Venv)
        & $launcher.Path @venvArgs
        if (-not (Test-Path -LiteralPath $Py)) { throw "venv creation failed" }
        Info "venv created at $Venv"
    } else {
        Info "venv already present"
    }
    # Skip slow re-install if the runtime deps are already present.
    # Native stderr can raise NativeCommandError under $ErrorActionPreference=Stop.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Py -c "import fastapi, uvicorn, Crypto, jinja2, psutil, winpty" 2>&1 | Out-Null
    $depsOk = ($LASTEXITCODE -eq 0)
    if (-not $depsOk) {
        & $Py -m pip install --quiet --upgrade pip
        if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prevEAP; throw "pip upgrade failed" }
        & $Py -m pip install --quiet -r $Reqs
        if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prevEAP; throw "pip install failed" }
        $ErrorActionPreference = $prevEAP
        Ok "dependencies installed from requirements.txt"
    } else {
        $ErrorActionPreference = $prevEAP
        Info "dependencies already satisfied (fastapi, uvicorn, Crypto, jinja2, psutil)"
    }
}

# ---------------- builder toolchain ----------------
function Test-BuilderTools {
    Hdr "Builder toolchain (needed for 'build on server')"
    $rules = @(
        @{ name="javac";  label="Java JDK (javac) -> jar";  alts=@("javac.exe") },
        @{ name="go";     label="Go";                        alts=@("go.exe") },
        @{ name="cargo";  label="Rust (cargo)";              alts=@("cargo.exe") },
        @{ name="gcc";    label="C/C++ (gcc/g++)";           alts=@("gcc.exe","x86_64-w64-mingw32-gcc") },
        @{ name="dotnet"; label=".NET SDK";                  alts=@("dotnet.exe") }
    )
    $hints = @{
        "Java JDK (javac) -> jar" = @("winget install --id Oracle.JDK -e","scoop install openjdk")
        "Go"                       = @("winget install --id GoLang.Go -e","scoop install go")
        "Rust (cargo)"             = @("winget install --id Rustlang.Rustup -e","scoop install rustup")
        "C/C++ (gcc/g++)"          = @("winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e","scoop install mingw")
        ".NET SDK"                 = @("winget install --id Microsoft.DotNet.SDK.8 -e","scoop install dotnet-sdk")
    }
    $missing = @()
    foreach ($r in $rules) {
        $hit = $null
        foreach ($n in @($r.name) + $r.alts) {
            if (Get-Command $n -ErrorAction SilentlyContinue) { $hit = $n; break }
        }
        if ($hit) { Ok "$($r.label) ($hit)" }
        else { Warn "$($r.label) NOT FOUND"; $missing += $r.label }
    }
    if ($missing.Count -gt 0) {
        Warn "Missing builder tools (install to enable server-side builds):"
        foreach ($m in $missing) {
            Write-Host "    - $m" -ForegroundColor Yellow
            foreach ($h in $hints[$m]) { Write-Host "        e.g.  $h" -ForegroundColor Gray }
        }
    } else {
        Ok "All builder tools available"
    }
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
        if ($exe -and ($exe -eq $Py)) { return $true }
    }
    return $false
}

function Stop-PreviousServer {
    if (Test-Path -LiteralPath $PidFile) {
        $old = 0
        [void][int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(), [ref]$old)
        if ($old -gt 0 -and (Test-OurServerPid $old)) {
            Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
            Info "stopped previous server (PID $old)"
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Server {
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
}

# ---------------- start server ----------------
function Start-Server {
    Hdr "Starting server"
    if (-not (Test-Path -LiteralPath $Py)) {
        throw "venv python not found: $Py (run install.ps1 first)"
    }
    $env:C2_HOST = $ListenHost
    $env:C2_PORT = [string]$Port
    $env:C2_USER = $User
    $env:C2_PASSWORD = $PasswordFinal
    Stop-PreviousServer
    if ($Foreground -or $Action -eq "run") {
        Remove-Item -LiteralPath $PidFile, $PortFile -Force -ErrorAction SilentlyContinue
        Push-Location -LiteralPath $Server
        try { & $Py $Main } finally { Pop-Location }
        exit $LASTEXITCODE
    }
    # Pass the absolute path so uninstall can match CommandLine. Capture the
    # server's output so a background crash is always diagnosable from the log.
    $LogOut = Join-Path $Server "server.log"
    $LogErr = Join-Path $Server "server.err.log"
    Remove-Item -LiteralPath $LogOut, $LogErr -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $Py -ArgumentList "`"$Main`"" -WorkingDirectory $Server `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
    Set-Content -LiteralPath $PortFile -Value $Port -Encoding ASCII
    # Wait for the process to come up (fresh venvs can be slow to start while
    # Defender/AMSI scans the newly-pip-installed package DLLs), then confirm
    # it is still alive instead of timing out at a fixed 800ms.
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $alive = [bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)
    } while (-not $alive -and (Get-Date) -lt $deadline)
    if (-not $alive) {
        $tail = ""
        if (Test-Path -LiteralPath $LogErr) {
            $tail = "`n" + ((Get-Content -LiteralPath $LogErr -Tail 25) -join "`n")
        }
        throw "server exited immediately; see $LogErr$tail"
    }
    Ok "server started (PID $($proc.Id)) at http://$ListenHost`:$Port"
    Ok "login: $User / $PasswordFinal"
    $tokFile = Join-Path $Server ".agent_token"
    if (Test-Path -LiteralPath $tokFile) {
        Write-Host "  X-Agent-Token: $((Get-Content $tokFile -Raw).Trim())" -ForegroundColor Magenta
    }
    Write-Host "  NOTE: run the same command with -Action run (foreground) to see logs." -ForegroundColor Gray
}

switch ($Action) {
    "install" {
        Ensure-Venv
        Test-BuilderTools
        Start-Server
        Write-Host "`nDone. Open http://$ListenHost`:$Port/login" -ForegroundColor Green
    }
    "check" {
        Ensure-Venv
        Test-BuilderTools
    }
    "start" { Start-Server }
    "stop"  { Stop-Server }
    "run"   {
        Ensure-Venv
        Test-BuilderTools
        Start-Server
    }
}
