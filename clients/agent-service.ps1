<#
.SYNOPSIS
  Install / manage a Wym C2 agent as a Windows service or scheduled task.
.DESCRIPTION
  Supports every agent shipped in clients/:
    - Interpreted scripts  : agent.py (py), agent.js (js), agent.lua (lua),
                             agent.php (php), agent.pl (perl), agent.rb (ruby)
    - Compiled binaries    : any .exe / extension-less binary
    - Compilable sources   : agent.c/.cpp/.cs/.go/.rs/.java compiled at
                             install time with -Build
  The runtime is auto-detected from the agent file and the C2 flags stay the
  same across agents (--server/--token/--interval/--jitter/--verbose).

  Backends (picked automatically):
    - NSSM (nssm.exe on PATH)  -> a real Windows service named
      "Wym C2 Agent <lang>".
      start: Start-Service "Wym C2 Agent <lang>"   relaunch: same
    - Fallback: Windows Task Scheduler task "Wym C2 Agent <lang>" (runs on
      logon/startup) that wraps the agent in an auto-restart watchdog so a
      crash relaunches the agent automatically.
      relaunch: schtasks /Run /I /TN "Wym C2 Agent <lang>"
.DESCRIPTION
  Token resolution order: -Token, then project server/.agent_token (or
  server/.agent_token_wsl).  Re-running install with different flags rewrites
  the task/service definition (update-in-place).
.EXAMPLE
  # Python agent (default)
  powershell -ExecutionPolicy Bypass -File agent-service.ps1 install -Server http://127.0.0.1:8000 -Token <TOKEN>

  # Any other script agent
  agent-service.ps1 install -Server http://127.0.0.1:8000 -Token <TOKEN> -Agent clients\agent.go -Build
  agent-service.ps1 install -Server http://127.0.0.1:8000 -Token <TOKEN> -Agent C:\tools\wymagent.exe
  agent-service.ps1 install -Server http://127.0.0.1:8000 -Token <TOKEN> -Agent clients\agent.c -Build

  # Quick management
  agent-service.ps1 start / stop / status / restart
  agent-service.ps1 relaunch          # alias for start; used by clone watchers
  agent-service.ps1 uninstall

  # Survive reboot-without-login use:  install -AtStartup
#>
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("install", "uninstall", "start", "stop", "restart", "status", "relaunch", "watch")]
    [string]$Action,

    [string]$Server,
    [string]$Token,
    [int]$Interval = 10,
    [int]$Jitter = 2,

    [Alias("Agent")]
    [string]$AgentScript = "",

    [ValidateSet("auto", "python", "node", "lua", "php", "perl", "ruby", "bash", "binary", "java", "jar")]
    [string]$Lang = "auto",

    [ValidateSet("auto", "nssm", "sc", "schtasks")]
    [string]$Backend = "auto",   # nssm | sc (sc.exe native service) | schtasks | auto (nssm->sc->schtasks)

    [switch]$Build,          # compile agent.c/.cpp/.cs/.go/.rs/.java before installing
    [switch]$AtStartup,      # fallback scheduler trigger at startup vs. logon
    [switch]$VerboseService
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $Root
$AgentFile = if ($AgentScript) { $AgentScript } else { Join-Path $Root "agent.py" }

[String]$ServiceDesc = "Wym C2 are What you missed is Command and Control Frameworks"
$ServiceName = ""          # resolved at install / detection time
$TaskName = ""             # resolved at install / detection time
$LegacyNames = @("C2Agent", "wymagent")

$WatchFile = Join-Path $Root "wymagent-watch.ps1"
$WatchLog = Join-Path $Root "C2Agent.log"
$WatchPidFile = Join-Path $Root ".wymagent-watch.pid"

function Write-Line($msg) { Write-Host $msg }

function Get-AgentLangLabel {
    $ext = [System.IO.Path]::GetExtension($AgentFile).ToLower()
    switch ($ext) {
        ".py"   { return "python" }
        ".js"   { return "node" }
        ".lua"  { return "lua" }
        ".php"  { return "php" }
        ".pl"   { return "perl" }
        ".rb"   { return "ruby" }
        ".sh"   { return "bash" }
        ".jar"  { return "java" }
        ".c"    { return "c" }
        ".cpp"  { return "cpp" }
        ".cs"   { return "csharp" }
        ".go"   { return "go" }
        ".rs"   { return "rust" }
        default {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($AgentFile)
            if ($base) { return $base }
            return "binary"
        }
    }
}

function Get-ServiceNameFor {
    param([string]$lang)
    return "Wym C2 Agent $lang"
}

function Get-Prog([string]$name, [string[]]$aliases = @()) {
    foreach ($cand in @($name) + $aliases) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

function Require-Prog([string]$name, [string[]]$aliases = @()) {
    $p = Get-Prog $name $aliases
    if (-not $p) {
        $hint = [string]::Join(", ", @($name) + $aliases)
        throw "required tool not found ($hint) - install it or pass a prebuilt -Agent file"
    }
    return $p
}

function Resolve-TokenFile {
    $cands = @(
        (Join-Path $ProjectRoot "server\.agent_token"),
        (Join-Path $ProjectRoot "server\.agent_token_wsl")
    )
    foreach ($c in $cands) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-CheckArguments {
    if (-not $Build -and -not (Test-Path $AgentFile)) {
        throw "agent file not found: $AgentFile"
    }
    if (-not $Server) { $script:Server = Read-Host "C2 server URL (e.g. http://127.0.0.1:8000)" }
    if (-not $Token) {
        $tok = Resolve-TokenFile
        if ($tok) {
            $script:Token = (Get-Content $tok | Select-Object -First 1).Trim()
        }
        if (-not $Token) {
            throw "Token is required (pass -Token or run from a checkout that has server\.agent_token)"
        }
    }
}

function Invoke-BuildAgent {
    $ext = [System.IO.Path]::GetExtension($AgentFile).ToLower()
    switch ($ext) {
        ".c" {
            $cc = Require-Prog "gcc" @("cc", "clang")
            & $cc -O2 -o (Join-Path $Root "wymagent-c.exe") $AgentFile
            if ($LASTEXITCODE -ne 0) { throw "gcc build failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $Root "wymagent-c.exe"
        }
        ".cpp" {
            $cxx = Require-Prog "g++" @("clang++")
            & $cxx -O2 -o (Join-Path $Root "wymagent-cpp.exe") $AgentFile
            if ($LASTEXITCODE -ne 0) { throw "g++ build failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $Root "wymagent-cpp.exe"
        }
        ".cs" {
            $dot = Require-Prog "dotnet"
            $tmp = Join-Path $Root ".wymcsbuild"
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            Copy-Item $AgentFile (Join-Path $tmp "Program.cs") -Force
            Push-Location $tmp
            try {
                & $dot new console --force -o . | Out-Null
                & $dot build -o (Join-Path $tmp "out") -q
            }
            finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { throw "dotnet build failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $tmp "out\a.exe"
        }
        ".go" {
            $g = Require-Prog "go"
            & $g build -o (Join-Path $Root "wymagent-go.exe") $AgentFile
            if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $Root "wymagent-go.exe"
        }
        ".rs" {
            $rt = Require-Prog "rustc"
            & $rt -O --edition 2021 -o (Join-Path $Root "wymagent-rs.exe") $AgentFile
            if ($LASTEXITCODE -ne 0) { throw "rustc build failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $Root "wymagent-rs.exe"
        }
        ".java" {
            $jc = Require-Prog "javac"
            $jar = Require-Prog "jar"
            $d = Join-Path $Root ".wymjbuild"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            & $jc --release 8 -encoding UTF-8 -d $d $AgentFile
            if ($LASTEXITCODE -ne 0) { throw "javac failed (exit $LASTEXITCODE)" }
            & $jar cfe (Join-Path $Root "wymagent-java.jar") Agent -C $d .
            if ($LASTEXITCODE -ne 0) { throw "jar failed (exit $LASTEXITCODE)" }
            $script:AgentFile = Join-Path $Root "wymagent-java.jar"
        }
        default { throw "cannot build $ext source; pass a prebuilt -Agent binary or an interpreted script" }
    }
    if (-not (Test-Path $AgentFile)) { throw "build produced no output: $AgentFile" }
    Write-Line "built agent: $AgentFile"
}

function Get-RuntimeCmd([string]$file, [string]$lang) {
    $ext = [System.IO.Path]::GetExtension($file).ToLower()
    $L = $lang.Trim().ToLower()

    $kind = switch ($L) {
        "auto" { switch ($ext) {
                    ".py"   { "py" }   ".js"  { "js" }   ".lua" { "lua" }
                    ".php"  { "php" }  ".pl"  { "pl" }   ".rb"  { "rb" }
                    ".sh"   { "sh" }   ".jar" { "jar" }  default { "bin" } } }
        "python" { "py" } "node" { "js" } "lua" { "lua" } "php" { "php" }
        "perl" { "pl" }   "ruby" { "rb" } "bash" { "sh" } "java" { "jar" }
        "jar" { "jar" }   "binary" { "bin" } default { "bin" }
    }

    switch ($kind) {
        "py"   { return @((Require-Prog "python" @("python3")), $file) }
        "js"   { return @((Require-Prog "node"), $file) }
        "lua"  { return @((Require-Prog "lua" @("lua5.4", "lua5.3")), $file) }
        "php"  { return @((Require-Prog "php"), $file) }
        "pl"   { return @((Require-Prog "perl"), $file) }
        "rb"   { return @((Require-Prog "ruby"), $file) }
        "sh"   { throw "agent.sh is Bash-only - use agent-service.sh on Linux/macOS" }
        "jar"  { return @((Require-Prog "java"), "-jar", $file) }
        default { if (-not (Test-Path $file)) { throw "agent binary not found: $file" }
                  return @($file) }
    }
}

function Get-TokenArg([string]$label) {
    switch ($label) {
        "python" { return @("--token=$Token") }
        "go"     { return @("--token=$Token") }
        "php"    { return @("--token=$Token") }
        "perl"   { return @("--token=$Token") }
        "ruby"   { return @("--token=$Token") }
        default  { return @("--token", $Token) }
    }
}

function Get-AgentArgv {
    $cmd = Get-RuntimeCmd $AgentFile $Lang
    $argv = $cmd + @("--server", "$Server") + (Get-TokenArg (Get-AgentLangLabel)) +
           @("--interval", "$Interval", "--jitter", "$Jitter")
    # per-install state file: distinct across hosts/ports so WIN+WSL never
    # fight over the same .wymagent.json (which caused re-register churn).
    if ((Get-AgentLangLabel) -eq "lua") {
        $port = "$Server" -replace '^.*:', ''
        $argv += @("--state", (Join-Path $env:USERPROFILE (".wymagent-" + $port + ".json")))
    }
    if ($VerboseService) { $argv += "--verbose" }
    return $argv
}

function Join-CmdLine([string[]]$argv) {
    return (($argv | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ' ')
}

function Join-SchTasks([string[]]$argv) {
    return (($argv | ForEach-Object { '\"' + $_ + '\"' }) -join ' ')
}

function Get-NssmPath {
    return Get-Prog "nssm" @((Join-Path $Root "nssm.exe"), "C:\tools\nssm\nssm.exe", "C:\nssm\nssm.exe")
}

function Get-SvcEnabled {
    $svc = @(Get-Service -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'Wym C2 Agent *' } |
             Select-Object -First 1)
    if ($svc.Count -gt 0) { $script:ServiceName = $svc[0].Name; return $true }
    return $false
}

function Get-TaskEnabled {
    $t = @()
    $ErrorActionPreference = "Continue"
    try { $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Wym C2 Agent *' } | Select-Object -First 1) } catch { }
    if ($t.Count -gt 0) { $script:TaskName = $t[0].TaskName; return $true }
    foreach ($legacy in $LegacyNames) {
        try { $null = schtasks /Query /TN $legacy 2>$null } catch { }
        if ($LASTEXITCODE -eq 0) { $script:TaskName = $legacy; return $true }
    }
    return $false
}

function Get-Backend {
    if (Get-SvcEnabled) {
        if (Get-NssmPath) { return "nssm" }
        return "sc"
    }
    if (Get-TaskEnabled) { return "schtasks" }
    return "none"
}

function Get-WatchArgv {
    # Single-file watchdog: the scheduled task / SC service re-invokes THIS
    # script with the 'watch' action, so the scheduler needs no separate
    # wymagent-watch.ps1 file. The full install-time config travels as args.
    $self = $PSCommandPath
    $argv = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $self, "watch",
              "-Agent", $AgentFile, "-Server", $Server, "-Token", $Token,
              "-Lang", (Get-AgentLangLabel), "-Interval", "$Interval",
              "-Jitter", "$Jitter")
    if ($VerboseService) { $argv += "-VerboseService" }
    return $argv
}

function Invoke-Watch {
    # Runs inside the scheduled task / SC service. Auto-relaunches the agent
    # after a crash (the behaviour the old wymagent-watch.ps1 provided).
    $argv = Get-AgentArgv
    [System.IO.File]::WriteAllText($WatchPidFile, [string]$PID)
    Write-Line ("watch: pid {0}, server {1}, agent {2}" -f $PID, $Server, $AgentFile)
    $prog = $argv[0]
    $rest = $argv[1..($argv.Count - 1)]
    while ($true) {
        try { & $prog @($rest) *>> $WatchLog } catch { }
        Start-Sleep -Seconds 3
    }
}

function Remove-Watchdog {
    Remove-Item -LiteralPath $WatchFile -Force -ErrorAction SilentlyContinue
}

function Install-Nssm {
    $nssm = Get-NssmPath
    if (-not $nssm) {
        throw "nssm.exe not found on PATH. Either install NSSM (https://nssm.cc) or use -Backend sc / schtasks."
    }
    $display = $ServiceName
    $argv = Get-AgentArgv
    if (Get-SvcEnabled) {
        & $nssm set $ServiceName Application $argv[0]
        & $nssm set $ServiceName AppParameters (Join-CmdLine $argv)
        & $nssm set $ServiceName AppDirectory $Root
        & $nssm set $ServiceName DisplayName $display
        & $nssm set $ServiceName Description $ServiceDesc
        & $nssm set $ServiceName AppRestartDelay 5000
        Write-Line "updated NSSM service '$ServiceName'"
    } else {
        & $nssm install $ServiceName $argv[0] (Join-CmdLine $argv)
        & $nssm set $ServiceName AppDirectory $Root
        & $nssm set $ServiceName DisplayName $display
        & $nssm set $ServiceName Description $ServiceDesc
        & $nssm set $ServiceName AppStdout "$Root\C2Agent.log"
        & $nssm set $ServiceName AppStderr "$Root\C2Agent.err.log"
        & $nssm set $ServiceName AppRestartDelay 5000
        & $nssm set $ServiceName Start SERVICE_AUTO_START
        Write-Line "installed NSSM service '$ServiceName'"
    }
}

function Install-Sc {
    if (-not (Get-Prog "sc.exe" @("sc"))) {
        throw "sc.exe not found - this backend requires the Windows Service Control"
    }
    # The service runs cmd which detaches a powershell that re-invokes THIS
    # script in 'watch' mode, so SCM never awaits a StartServiceCtrlDispatcher
    # payload and no separate wymagent-watch.ps1 file is needed.
    $watchline = '"' + (Join-CmdLine (@("powershell.exe") + (Get-WatchArgv))) + '"'
    $cmdline = 'cmd.exe /c start "" /b ' + $watchline
    $img = '"' + $cmdline.Replace('"', '\"') + '"'

    if (Get-SvcEnabled) {
        $ErrorActionPreference = "Continue"
        try { & sc.exe stop $ServiceName 2>$null | Out-Null } catch { }
        & sc.exe config $ServiceName "binPath=" $img "start=" "auto"
        & sc.exe description $ServiceName $ServiceDesc | Out-Null
        $LASTEXITCODE = 0
        Write-Line "updated SC service '$ServiceName'"
    } else {
        & sc.exe create $ServiceName "binPath=" $img "start=" "auto" "DisplayName=" $ServiceName
        if ($LASTEXITCODE -ne 0) { throw "sc create failed (exit $LASTEXITCODE)" }
        & sc.exe description $ServiceName $ServiceDesc | Out-Null
        Write-Line "installed SC service '$ServiceName'"
    }
    Remove-Item -LiteralPath $WatchPidFile -Force -ErrorAction SilentlyContinue
}

function Get-WatchdogPid {
    if (-not (Test-Path $WatchPidFile)) { return 0 }
    $w = (Get-Content $WatchPidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    $n = 0
    if (-not [int]::TryParse($w, [ref]$n)) { return 0 }
    if (-not (Get-Process -Id $n -ErrorAction SilentlyContinue)) { return 0 }
    return $n
}

function Install-Task {
    $tr = Join-SchTasks (@("powershell.exe") + (Get-WatchArgv))

    $trigger = if ($AtStartup) { "/SC", "ONSTART" } else { "/SC", "ONLOGON" }
    $ErrorActionPreference = "Continue"
    try { schtasks /Create /F /TN $TaskName /TR $tr ${trigger} /RL LIMITED 2>$null | Out-Null } catch { }
    $safe = $true
    if ($LASTEXITCODE -ne 0) {
        # Non-elevated shells cannot create ONLOGON/ONSTART tasks. Fall back to
        # a one-shot schedule (future time) so the task can still be started
        # with 'schtasks /Run /I'; the watch loop keeps the agent alive. Use an
        # elevated shell to get auto-start at logon/boot.
        & schtasks /Create /F /TN $TaskName /TR $tr /SC ONCE /ST "23:59" 2>$null | Out-Null
        $safe = $false
    }
    if ($LASTEXITCODE -ne 0) {
        throw "schtasks create failed (exit $LASTEXITCODE)"
    }
    if ($safe) {
        Write-Line "installed scheduled task '$TaskName' (trigger: $($trigger[1]))"
    } else {
        Write-Line "installed scheduled task '$TaskName' (one-shot fallback - run elevated for logon/boot auto-start)"
    }
}

function Install-Agent {
    Invoke-CheckArguments
    if ($Build) { Invoke-BuildAgent }
    $lang = Get-AgentLangLabel
    $script:ServiceName = Get-ServiceNameFor $lang
    $script:TaskName = Get-ServiceNameFor $lang
    Remove-Legacy
    $be = $Backend
    if ($be -eq "auto") {
        if (Get-NssmPath) { $be = "nssm" }
        elseif (Get-Prog "sc.exe" @("sc")) { $be = "sc" }
        else { $be = "schtasks" }
    }
    try {
        switch ($be) {
            "nssm"      { Install-Nssm }
            "sc"        { Install-Sc }
            default     { Install-Task }
        }
    } catch {
        # elevation is required for nssm/sc; auto and sc fall back to the
        # scheduled-task watchdog which works in a non-elevated shell
        if ($be -ne "schtasks" -and $Backend -ne $be) {
            Write-Line "backend $be failed ($($_.Exception.Message)); falling back to scheduled task"
            Install-Task
        } else { throw }
    }
}

function Remove-Legacy {
    foreach ($legacy in $LegacyNames) {
        $s = Get-Service -Name $legacy -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service $legacy -Force -ErrorAction SilentlyContinue
            sc.exe delete $legacy | Out-Null
            Write-Line "removed legacy service '$legacy'"
        }
        $ErrorActionPreference = "Continue"
        try { $null = schtasks /Query /TN $legacy 2>$null } catch { }
        if ($LASTEXITCODE -eq 0) {
            try { schtasks /Delete /TN $legacy /F 2>$null | Out-Null } catch { }
            Write-Line "removed legacy task '$legacy'"
        }
    }
}

function Uninstall-Agent {
    if (Get-SvcEnabled) {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete $ServiceName | Out-Null
        Write-Line "removed service '$ServiceName'"
    }
    if (Get-TaskEnabled) {
        $ErrorActionPreference = "Continue"
        try { schtasks /Delete /TN $TaskName /F 2>$null | Out-Null } catch { }
        Write-Line "removed task '$TaskName'"
    }
    if (Test-Path $WatchPidFile) {
        $wp = Get-WatchdogPid
        if ($wp) { Stop-Process -Id $wp -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $WatchPidFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Watchdog
    if (-not (Get-SvcEnabled) -and -not (Get-TaskEnabled)) {
        Write-Line "nothing installed"
    }
}

function Start-Agent {
    $backend = Get-Backend
    switch ($backend) {
        "nssm"     { Start-Service $ServiceName; Write-Line "started service '$ServiceName'" }
        "sc" {
            $wp = Get-WatchdogPid
            if ($wp) { Write-Line "agent already running (watchdog pid $wp)"; return }
            $ErrorActionPreference = "Continue"
            try { & sc.exe start $ServiceName 2>$null | Out-Null } catch { }
            Start-Sleep -Seconds 3
            $wp = Get-WatchdogPid
            if ($wp) { Write-Line "started SC service '$ServiceName' (watchdog pid $wp)" }
            else { throw "sc start did not spawn the agent watchdog" }
        }
        "schtasks" {
            $wp = Get-WatchdogPid
            if ($wp) { Write-Line "agent already running (watchdog pid $wp)"; return }
            $ErrorActionPreference = "Continue"
            try { schtasks /Run /I /TN $TaskName 2>$null | Out-Null } catch { }
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Run failed (exit $LASTEXITCODE)" }
            Write-Line "started task '$TaskName'"
        }
        default  { throw "nothing installed - run 'install' first" }
    }
}

function Stop-Agent {
    $backend = Get-Backend
    switch ($backend) {
        "nssm"     { Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue; Write-Line "stopped service '$ServiceName'" }
        "sc" {
            $ErrorActionPreference = "Continue"
            try { & sc.exe stop $ServiceName 2>$null | Out-Null } catch { }
            $wp = Get-WatchdogPid
            if ($wp) { Stop-Process -Id $wp -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $WatchPidFile -Force -ErrorAction SilentlyContinue
            Write-Line "stopped SC service '$ServiceName' (watchdog stopped)"
        }
        "schtasks" {
            $ErrorActionPreference = "Continue"
            try { schtasks /End /TN $TaskName 2>$null | Out-Null } catch { }
            $wp = Get-WatchdogPid
            if ($wp) { & taskkill.exe /PID $wp /T /F 2>$null | Out-Null }
            try { schtasks /End /TN $TaskName 2>$null | Out-Null } catch { }
            Remove-Item -LiteralPath $WatchPidFile -Force -ErrorAction SilentlyContinue
            Write-Line "stopped task '$TaskName' (watchdog stopped)"
        }
        default    { Write-Line "nothing installed" }
    }
}

function Get-Status {
    $backend = Get-Backend
    switch ($backend) {
        "nssm" {
            $svc = Get-Service $ServiceName
            Write-Line "backend : nssm service"
            Write-Line "name    : $ServiceName"
            Write-Line "status  : $($svc.Status)"
            if (Test-Path "$Root\C2Agent.err.log") {
                $tail = Get-Content "$Root\C2Agent.err.log" -Tail 5 -ErrorAction SilentlyContinue
                if ($tail) { Write-Line "recent stderr:"; $tail | ForEach-Object { Write-Line "  $_" } }
            }
        }
        "schtasks" {
            Write-Line "backend : scheduled task (watchdog)"
            Write-Line "name    : $TaskName"
            $q = & schtasks /Query /TN $TaskName /V /FO LIST 2>$null
            if ($q) {
                $runline = ($q | Select-String -Pattern "Task To Run:" | Select-Object -First 1).Line
                if ($runline) {
                    $agv = $null
                    $sr  = $null
                    $m = [regex]::Match($runline, '-Agent\s+"([^"]+)"')
                    if ($m.Success) { $agv = $m.Groups[1].Value }
                    else { $m = [regex]::Match($runline, 'agent-service\.ps1\s+"?([^"\s]+)'); if ($m.Success) { $agv = $m.Groups[1].Value } }
                    $m = [regex]::Match($runline, '-Server\s+"([^"]+)"')
                    if ($m.Success) { $sr = $m.Groups[1].Value }
                    if ($agv) { Write-Line "agent   : $agv" }
                    if ($sr)  { Write-Line "server  : $sr" }
                }
                $q | Select-String -Pattern "Status:|Last Run Time:|Next Run Time:|Task To Run:" | ForEach-Object { Write-Line ($_.Line.Trim()) }
            }
            if (Test-Path $WatchLog) {
                $tail = Get-Content $WatchLog -Tail 3 -ErrorAction SilentlyContinue
                if ($tail) { Write-Line "recent log:"; $tail | ForEach-Object { Write-Line "  $_" } }
            }
        }
        "sc" {
            Write-Line "backend : SC service (sc.exe)"
            Write-Line "name    : $ServiceName"
            & sc.exe query $ServiceName | Select-String -Pattern "STATE" | ForEach-Object { Write-Line ($_.Line.Trim()) }
            $wp = Get-WatchdogPid
            if ($wp) { Write-Line "watchdog: running (pid $wp)" }
            else     { Write-Line "watchdog: not running" }
            if (Test-Path $WatchLog) {
                $tail = Get-Content $WatchLog -Tail 3 -ErrorAction SilentlyContinue
                if ($tail) { Write-Line "recent log:"; $tail | ForEach-Object { Write-Line "  $_" } }
            }
        }
        default { Write-Line "backend : none (not installed)" }
    }
}

switch ($Action) {
    "install"   { Install-Agent }
    "uninstall" { Uninstall-Agent }
    "start"     { Start-Agent }
    "stop"      { Stop-Agent }
    "restart"   { Stop-Agent; Start-Agent }
    "status"    { Get-Status }
    "relaunch"  { Start-Agent }
    "watch"     { Invoke-Watch }
}