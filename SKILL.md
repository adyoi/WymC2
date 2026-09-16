# SKILL.md — working on this C2 codebase

A compact operator's manual for AI coding agents (and humans) editing a C2
framework. Read [`PROTOCOL.md`](PROTOCOL.md) first for the wire format and
[`AGENTS.md`](AGENTS.md) for the client-side contract.

## Ground rules (todo check-list)

- [ ] **Dual-use, authorized testing only.** No persistence/evasion/stealth
      features unless operator-initiated and reviewable.
- [ ] Keep the wire protocol **frozen** (task/result shapes) across all agents.
- [ ] Agents must stay backward compatible: same flags, same env fallbacks,
      same `404` → re-register behavior.
- [ ] Never "fix" AV flags by obfuscating source — Defender/AMSI flags
      `agent.ps1` by script-heuristic; it is a false positive.
- [ ] Don't hand-edit a live SQLite DB while its server runs; use the API.
- [ ] Don't start DB-races: builds use per-build temp dirs, never one shared
      work dir between concurrent processes.

## Where things live

| Concern                      | File(s) |
|------------------------------|---------|
| Server routes + agent API    | `server/main.py` |
| Build pipeline (toolchains)  | `server/main.py` (`_build_binary_locked` / `_build_mobile_locked`, `AGENT_FILES`) |
| Icon rendering (mobile)      | `server/icons.py` |
| Auth/sessions                | `server/auth.py`, `server/database.py` |
| Dashboard / Generate pages   | `server/templates/*.html` |
| Agents (14 languages)        | `clients/agent.{py,js,lua,php,pl,rb,sh,go,rs,c,cpp,cs,java}` |
| Mobile templates             | `clients/mobile/{android,ios}` |
| Tests                        | `server/tests/` (`pytest`) |
| Service install              | `clients/agent-service.ps1` (single-file) / `agent-service.sh` |

## Build rules (learned the hard way)

1. **Never make build routes `async`.** `generate_post`/`api_build_agent` are
   sync `def` so a compile runs in the thread pool, not the event loop.
   Builds are serialized by `_BUILD_LOCK`.
2. **Rust fallback = host default only.** A requested foreign target must
   return an error banner (`gen_build_error`), never a mislabeled binary.
3. **Rust pinned crates:** generate `url = "=2.5.2"` and
   `encoding_rs = "=0.8.35"` + `rust-version = "1.80"` — unlocked versions
   need rustc 1.86+ (via `idna_adapter`/`icu`), which breaks old toolchains.
4. **Rust Linux builds need system libs in WSL:** `autoconf automake libtool
   libevdev-dev` + X11 dev (`libxi-dev libxtst-dev libx11-dev ...`), or the
   `rdev` dep fails (`autoreconf: not found`, `xi.pc missing`).
5. **C# is Windows-only** (`win_x64`/`win_x86`) — `_build_binary_locked`
   rejects other targets; docs must not claim all-RID publish.
6. **Mobile package must match the template:** android template lives under
   `com/wym/c2/` (`applicationId com.wym.c2`); keep `_build_android_apk`'s
   `Config.java` path in sync or the build fails "Config.java missing".
7. **`WYM_PASSWORD`:** unset on boot keeps the existing dashboard password
   (fresh installs print a random one). Never overwrite the stored hash when
   absent.
8. **Per-build temp dir:** `tempfile.mkdtemp` per build. One shared work dir
   (Windows server + WSL script on drvfs) races and yields `R-def.txt missing`
   in Gradle and flaky artifacts.
9. **`agent.sh` + `set -u`:** don't touch `${AGENT_ID}` at file scope.
10. **`agent.py` argparse:** tokens starting with `-` are pre-normalized to
    `--foo=bar`, or argparse rejects them.

## Verification workflow (todo)

1. [ ] Grep + read before editing; keep edits minimal and idiomatic.
2. [ ] Run the suite: `python -m pytest -q` (repo root) — API + icon/mobile
      tests must pass before commit.
3. [ ] Live loop at least once per touched agent: launch (`--interval 3
      --jitter 0 --state <tmp>`), insert `shell`, confirm `exit_code=0`,
      relaunch, confirm same id + fresh `last_seen`.
4. [ ] Cross-compile check: build the affected language on the server
      (`/generate`, or call `_build_binary_locked` in-process) and verify the
      artifact + `.hash` marker.
5. [ ] WSL: drive build scripts via `wsl -d Debian bash /mnt/c/.../x.sh`
      (no inline `-c` quoting — wsl.exe mangles it); write logs to
      `/mnt/c/...` so they are readable from Windows.
6. [ ] Report a per-language matrix; flag anything unreviewed (e.g. macOS =
      code review only).

## Key learnings

- Facts to verify before trusting docs: env var names, DB names, per-OS token
  files, and which targets each toolchain actually supports.
- A "missing" toolchain normally means missing system libs, not a bad command:
  read the real build log under `server/builds/logs/` before editing source.
- Cache markers (`.hash`) force rebuilds when config/source changes; keep
  marker inputs identical between the build and cache-hit checks.