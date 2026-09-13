# SKILL.md — working on this C2 codebase

A compact operator's manual for AI coding agents (and humans) editing a C2
framework. Read [`PROTOCOL.md`](PROTOCOL.md) first for the wire format and
[`AGENTS.md`](AGENTS.md) for the client-side contract.

## Ground rules

- **Dual-use, authorized testing only.** Never add persistence/evasion/stealth
  features. Keep the code open and reviewable; the README's warning box applies.
- **Two live-server layouts** are used for verification: Windows host on port
  `8000` (DB `server/c2.db`) and WSL guest on port `8001`
  (DB `server/c2_wsl.db`, on the shared drvfs folder — the installers start
  the server from the project dir). Don't hand-edit the live SQLite file while
  its server is running unless you hold a real write lock; prefer the API.
- **Windows Defender/AMSI will flag `agent.ps1`** (and may flag any full
  PowerShell C2 agent). It is a script-heuristic false-positive, not a sign of
  a bug; do **not** "fix" it by obfuscating the source. Test with the client
  dir excluded from real-time scanning, or drive verification with the Go/Python
  reference agents and validate the ps1 core (parse + protocol probe) elsewhere.
- Agents must stay **backward compatible**: same flags, same task shapes, same
  result fields, same re-register-on-404 behavior. Any new script agent must
  pass the register → checkin → shell → result → same-id-restart loop.

## Where things live

| Concern                          | File(s)                                        |
|----------------------------------|------------------------------------------------|
| Server routes + agent API        | `server/main.py`                               |
| Build pipeline (toolchains)      | `server/main.py` (`_build_binary` / `_build_installer`, `AGENT_FILES`) |
| Auth/sessions                    | `server/auth.py`, `server/database.py`         |
| Dashboard/Generate pages         | `server/templates/*.html`                      |
| CodeMirror editor                | `server/static/codemirror/` (v5.65.16)         |
| Agents                           | `clients/agent.{py,js,lua,php,pl,rb,sh,go,rs,c,cpp,cs,java}` + `keylog_*.go` |
| Service install (Win)            | `clients/agent-service.ps1` (single-file, `watch` action) |
| Service install (Unix)           | `clients/agent-service.sh`                     |
| Protocol                          | `PROTOCOL.md`                                  |

## Common pitfalls (learned the hard way)

1. **Never make build routes `async`.** `generate_post`/`api_build_agent` are
   sync `def` so a cross-compile doesn't block the uvicorn event loop (this
   froze the whole dashboard once). Builds are serialized by `_BUILD_LOCK`.
2. **Rust fallback must match host target only**, else return an error banner
   (`gen_build_error`) — never emit a mislabeled binary.
3. **`agent.sh` + `set -u`:** don't touch `${AGENT_ID}` at file scope; compute
   per-id paths lazily (`CLONE_DIR()` as a function).
4. **`agent.sh` json paths:** use dot-paths (`.agent_id`); bracket paths
   (`["agent_id"]`) return garbage under `jq -r`.
5. **`agent.py` argparse:** tokens starting with `-` are normalized to
   `--token=...` before `parse_args`, or argparse rejects them.
6. **CodeMirror `defineSimpleMode`:** require `addon/mode/simple.min.js` after
   `codemirror.min.js` whenever a simple-mode highlight (rust/go/...) is loaded,
   in every page that loads editor modes.
7. **`C2_PASSWORD`:** an unset password on boot keeps the existing dashboard
   password (fresh installs get a printed random one). Don't overwrite the
   stored hash when the env var is absent.

## Verification workflow

1. Grep + read before editing; keep edits minimal and idiomatic.
2. After edits, run the live loop for at least the affected platform:
   launch agent (`--interval 3 --jitter 0 --state <tmp>`), insert a `shell`
   task, confirm `exit_code=0`, kill, relaunch, confirm same id + fresh
   `last_seen`.
3. On WSL, drive everything through `wsl -e python3 <file>` / `wsl -e bash <file>`
   scripts placed under `/mnt/c/...` (no spaces) — wsl.exe mangles `-c` quoting.
4. Report results as a per-language matrix, and flag anything unreviewed
   (e.g., macOS = code-review only, no runner).