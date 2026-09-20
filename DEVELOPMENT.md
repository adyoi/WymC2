# DEVELOPMENT.md

Build, run and develop the C2 server + agents.

## Prerequisites

- Python 3.10+ (server; venv in `server/.venv` on Windows,
  `server/.venv-wsl` on Linux/macOS/WSL).
- A builder toolchain per language you want to compile on the server
  (`/generate` → "build on server"). Installers probe for them and print
  ready-to-run install commands when missing; they never auto-download.

### Toolchain reference

| Toolchain | Windows (`winget`/`scoop`) | Linux (`apt-get`) | macOS (`brew`) | Probed by server |
|-----------|----------------------------|-------------------|----------------|------------------|
| Go        | `GoLang.Go` / `go`         | `golang`          | `go`           | `go`             |
| Rust      | `Rustlang.Rustup` / `rustup` | `rustc cargo`   | `rust`         | `cargo`          |
| C / C++   | WinLibs / `mingw`          | `build-essential libcurl4-openssl-dev` | `gcc` / Xcode CLT | `gcc`/`g++`/`clang` |
| .NET SDK  | `Microsoft.DotNet.SDK.8` / `dotnet-sdk` | `dotnet-sdk-8.0` | `dotnet` | `dotnet` |
| Java      | Oracle.JDK / `openjdk`     | `openjdk-17-jdk`  | `openjdk`      | `javac`          |
| Android   | Android Studio / SDK cmdline-tools (any OS) | same | same | `gradle` + `ANDROID_HOME`/`ANDROID_SDK_ROOT` |
| iOS       | — (or `tools/ios-builder-setup.ps1`)  | — (or `tools/ios-builder-setup.sh`)  | `xcode-select --install` | `builder` (ios-builder) or `xcrun` + iphoneos SDK |

**Rust on Linux/WSL** additionally needs X11/input dev headers because the
`rdev` dependency (keylog) compiles `evdev-sys`:

```
sudo apt-get install autoconf automake libtool libevdev-dev \
    libx11-dev libxi-dev libxtst-dev libxrandr-dev libxinerama-dev \
    libxcursor-dev libxext-dev libxrender-dev libxfixes-dev
```

**Android template** (`clients/mobile/android/`) is a minimal Gradle project
(package `com.wym.c2`, no external deps, `assembleRelease`). AGP 8.2.2 needs
**Gradle 8.x** — Gradle 9 is incompatible — so build the server's Android SDK
path with Gradle 8.2–8.x (the checked-in template has no gradle wrapper; the
server uses the `gradle` on PATH). iOS
(`clients/mobile/ios/`) builds with the **MobAI ios-builder** CLI on any host —
it snapshots the working tree, compiles on a GitHub macOS runner and downloads
the IPA to `./dist/`; without the CLI, a macOS server falls back to a bare
`xcrun swiftc` (the XcodeGen manifest `project.yml` is not used by that path).
Server URL/token/interval are injected into `Config.java`/`Config.swift`; the
artifact name + disguise icon are rendered by `server/icons.py`. Both are
folded into the cache hash, so a cached build is never stale.

### Installing the .NET SDK on Unix

Bundled `dotnet-install.sh` (upstream) installs to `~/.dotnet` without root and
persists PATH to the shell profile. The server probes `~/.dotnet` directly, so
builds work even before a new shell.

```bash
./dotnet-install.sh                  # latest LTS SDK
./dotnet-install.sh --channel 8.0    # specific major
./dotnet-install.sh --version 8.0.404
```

### Rust cross targets

Cargo builds the host by default; add targets first:

```bash
rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-pc-windows-gnu
```

## Server

```bash
cd server && python -m venv .venv
# Windows: .venv\Scripts\pip install -r ..\requirements.txt
# Unix:    .venv-wsl/bin/pip install -r ..\requirements.txt
# then run with the dashboard password pinned (below)
```

### Environment knobs (as defined in `server/main.py` / `server/database.py`)

| Env var                    | Meaning |
|----------------------------|---------|
| `WYM_HOST` / `WYM_PORT`    | listen address/port (Windows default `8000`, Unix `8001`) |
| `WYM_USER` / `WYM_PASSWORD`| dashboard user + password; when **unset on boot** a random password is generated and printed, and the existing stored hash is **kept** |
| `WYM_AGENT_TOKEN`          | override the generated agent token (or `server/.agent_token{_wsl}`) |
| `WYM_DB_PATH`              | override the SQLite location |
| `WYM_STALE_AFTER` / `WYM_DEAD_AFTER` | agent staleness windows (defaults 90/600 s) |
| `WYM_RETRY_AFTER`          | seconds before an unacknowledged task is retried (default 180) |
| `WYM_MAX_UPLOAD_MB` / `WYM_RESULT_LIMIT` | upload cap (512) / result char cap (50000) |
| `WYM_TLS`                  | `1` for a production reverse-proxy/TLS setup |
| `WYM_API_DOCS`             | `1` enables `/api/docs` |
| `WYM_ENC_KEY`              | optional fixed obfuscation key |
| `WYM_EXPLORER_ROOT` / `WYM_EXPLORER_UNRESTRICTED` | file-explorer root / allow-any flag |

### Per-OS state files

Every runtime artifact is per-OS so a folder shared Windows↔WSL never
collides:

| Asset          | Windows        | Unix / WSL        |
|----------------|----------------|-------------------|
| SQLite DB      | `server/wym.db`       | `server/wym_wsl.db` |
| Agent token    | `server/.agent_token` | `server/.agent_token_wsl` |
| PID / port     | `server/.server.pid` / `.server.port` | `_wsl` suffixed |
| Log            | `server/server.log`   | `server/server_wsl.log` |
| Agent PID file | `clients/.wymagent.json` | same (per-agent state) |

Sessions + CSRF tokens live in `server/auth.py`; CSRF secret is per-process.
The DB schema is created idempotently at boot in `server/database.py`.

## Build pipeline (touching `server/main.py`)

- **Keep `generate_post`/`api_build_agent` sync (non-async).** A compile must
  run in FastAPI's thread pool, not the event loop. A global `_BUILD_LOCK`
  serializes builds.
- **Per-build temp dir** (`tempfile.mkdtemp`). One shared work dir races when
  the Windows server and a WSL build script run at once (drvfs) — it produced
  Gradle `R-def.txt missing` and flaky binaries.
- **Rust pins:** the generated `Cargo.toml` sets `rust-version = "1.80"` and
  pins `url = "=2.5.2"`, `encoding_rs = "=0.8.35"` — unlocked crates resolve
  MSRV 1.86+ via `idna_adapter`/`icu`.
- **Rust host fallback only:** a foreign target with std missing errors out;
  fallback to the host default *only* when they match.
- **Cache markers:** `server/builds/wym_<lang>_<target>.<ext>` + `.hash`.
  A build is reused only while the marker matches `_source_hash(...)`; mobile
  hashes include the injected config variant.
- **C# is Windows-only** (`win_x64`/`win_x86`).
- Per-language runners and the `AGENT_FILES` map live in `server/main.py`;
  `download`-staged files come from `server/shared/`; agent source is served
  from `clients/`.
- Mobile template path must match `clients/mobile/android/app/.../com/wym/c2/`.

## Tests

`pytest` suite under `server/tests/` (`test_api.py`, `test_mobile.py`).

```bash
python -m pytest -q            # from the repo root
```

Covers the agent API/auth, task flow, and mobile builder (icons, naming,
toolchain guards). Plus a live loop for any touched agent:

1. [ ] Start the server; register an agent with `--interval 3 --jitter 0`.
2. [ ] Insert a `shell` task; confirm `exit_code=0`.
3. [ ] Restart the agent; confirm same `agent_id` and advancing `last_seen`.
4. [ ] Cross-compile the affected language and check the `.hash` marker.

## Regression lessons (keep these)

- Rust Linux build: missing system libs (autotools, `libevdev`, X11 dev)
  surface as `evdev-sys`/`rdev` build.rs panics, not Cargo errors.
- WSL builds: drive via a real script (`wsl -d Debian bash /mnt/c/.../x.sh`),
  never inline `-c` quoting — wsl.exe mangles it.
- `agent.sh`: `set -u` + top-level `${AGENT_ID}` → unbound-variable crash;
  derive per-id paths lazily inside a function, and use dot-paths (`.agent_id`)
  so `jq -r` and the python fallback agree.
- `agent.py`: argparse rejects tokens starting with `-`; pre-normalize
  `--foo=bar`.
- Mobile serves disguised names via the `name` param on
  `/download/build/{lang}`; mobile requests ignore `target` (forced to the
  language) so the `/download/build/android` URL needs no `target`.

## Key learnings

- The protocol is the contract, not any runtime — keep JSON shapes frozen.
- Env knobs are the only portable config (flags > env > baked defaults).
- Fix "missing toolchain" by reading the real build log
  (`server/builds/logs/`), not by guessing the command.
- Guard concurrent builds with per-build temp dirs and cache hash markers.