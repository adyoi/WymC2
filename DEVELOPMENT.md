# DEVELOPMENT.md

Build, run and develop the C2 server + agents.

## Prerequisites

- Python 3.10+ (server; virtualenvs are created in `server/.venv`).
- For agent **builder** targets, the matching toolchain is detected at install
  time and required only when you build that language:
  - Go (`go`), Rust (`cargo`), C/CPP (gcc/clang, MinGW on Windows), C# (`dotnet`),
    Java (`javac`/`java`), Node (`node`), PowerShell (bundled with Windows),
    Lua, PHP, Ruby, Perl (runtime must exist on the *target*, not the server).
- Installers **validate** the toolchain and print ready-to-run install commands
  if something is missing; they do not auto-download toolchains. A kickstart
  script for .NET lives at the repo root (`dotnet-install.sh`). Builds the
  server runs live under `server/builds/` (gitignored).

## Server

```bash
cd server
python -m venv .venv
# Windows: .venv\Scripts\pip install -r requirements.txt
# Unix:    .venv/bin/pip install -r requirements.txt
# then run with the dashboard password pinned (see below)
```

Environment knobs (see `server/main.py`):

| Env var              | Meaning                                                  |
|----------------------|----------------------------------------------------------|
| `C2_PASSWORD`        | Dashboard password. When **unset on boot**, a random one is generated and **printed**; on every subsequent boot with it unset the existing user password is **kept** (a key is printed instead). Use `-P/--password` from the installers for a fixed password. |
| `C2_PORT`            | Listen port (`8000` Windows default, `8001` Unix default). |
| `C2_TOKEN`           | Override the generated agent token.                       |
| `AGENT_TOKEN_FILE`   | Read the agent token from a file if the env var is unset. |
| `C2_RETRY_AFTER`     | Seconds before an unacknowledged task is retried.         |
| `C2_ALLOWED_ORIGINS` | CORS origins (same-origin by default — leave unset).      |

### Database layout

- SQLite, one file per platform: `server/c2.db` (Windows), `server/c2_wsl.db`
  (Unix). Schema is created idempotently at boot in `server/database.py`
  (`SCHEMA`), not a separate `.sql` file.
- WSL note: the installer starts the server from inside the shared project
  folder (drvfs), so the live DB is `server/c2_wsl.db` on `/mnt/d/...`. A DB
  living only on the ext4 side (e.g. `/home/<user>/c2_wsl.db`) was used during
  an older install layout — if you find a stale drvfs copy of the WSL DB,
  remove it so it does not shadow the live one.

### Config/state files

- `server/.agent_token` — shared agent token sent to agents (`X-Agent-Token`).
- Dashboard users + password hashes live in the SQLite `users` table
  (`server/c2.db` / `c2_wsl.db`); sessions and CSRF tokens are managed by
  `server/auth.py` (CSRF secret is per-process, not persisted).
- Per-agent state on the *agent side*: `--state FILE` (default `~/.c2agent.json`).
  The agent id is persisted there so restarts keep the same id.

## The agent build pipeline

`main.py` routes `POST /api/build/{language}` and the Generate page
(`/generate`). Notes that matter when touching it:

- **Do not make `generate_post`/`api_build_agent` `async`.** A compile blocks the
  event loop; these endpoints are **sync `def`** so FastAPI runs them in the
  thread pool. There is a global `_BUILD_LOCK` so only one build runs at a time.
- The Rust fallback: a requested target falls back to the host default target
  **only** when they match (e.g. `win_x64` on Windows); otherwise the build
  errors out with a visible banner rather than emitting a mislabeled binary.
- Build errors are surfaced to the UI via `gen_build_error` + the red banner in
  `server/templates/generate.html` (`build failed for <target>: <error>`).
- Each language's toolchain runner lives in `server/main.py` (the builder
  helpers `_build_binary` / `_build_agent_command` / `_build_installer`); agent
  source files are served from `clients/`, and staged files for `download`
  tasks come from `server/shared/`.

## CodeMirror note

The editor in `generate.html`/`explorer.html` is CodeMirror **5.65.16**. Modes
that use `defineSimpleMode` (rust, go, etc.) require
`addon/mode/simple.min.js` after `codemirror.min.js`. If a new highlight mode
is added, include that addon first or `rust.min.js ... defineSimpleMode is not a
function` appears in the console.

## Tests / verification

There is no unit-test harness baked into the repo yet; verification is a live
battery:

1. Start a server; register an agent with `--interval 3 --jitter 0`.
2. Insert `shell` tasks (directly into `tasks` table or via the dashboard) and
   confirm `exit_code=0`.
3. Restart the agent and confirm it re-checks-in with the **same** id
   (`last_seen` advances) — this is the stability check.

A harness that does exactly this (Windows host + WSL guest, both live servers)
has been used during development; the core loop is:

```
launch agent -> poll DB for new agent row -> insert shell task -> poll result
-> kill -> relaunch with same --state -> confirm same id + fresh last_seen
```

## Regression lessons (keep these)

- `agent.sh`: `set -u` + top-level `${AGENT_ID}` → **unbound variable** crash.
  Derive per-id paths lazily (`CLONE_DIR()` in a function), never at file scope.
- `agent.sh`: `json_get '["agent_id"]'` breaks when `json_get` is `jq -r`
  (returns the literal array, pretty-printed). Always use dot-paths
  (`.agent_id`) so jq and the python fallback agree.
- `agent.py`: argparse rejects tokens starting with `-`. Args with a value
  (`--token`, `--server`, ...) are pre-normalized to `--foo=bar` before parsing.