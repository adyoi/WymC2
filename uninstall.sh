#!/usr/bin/env bash
# Uninstall / clean up the C2 server on Linux / macOS / BSD / WSL.
# Stops the running server (via server/.server.pid_wsl) and deletes this
# platform's artifacts: virtualenv, database, agent token, logs and build
# output. Source code and client agents are kept.
#
# Usage:
#   ./uninstall.sh            # asks for confirmation first
#   ./uninstall.sh --force    # skip the confirmation prompt
#   ./uninstall.sh --help

set -euo pipefail

FORCE=false

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [--force]

  --force, -f, -y   Skip the confirmation prompt

Removes (Linux/macOS/WSL artifacts only):
  server/.venv-wsl                        (virtualenv)
  server/wym_wsl.db                        (database)
  server/.agent_token_wsl                 (agent token)
  server/.server.pid_wsl, .server.port_wsl
  server/server_wsl.log
  server/builds and __pycache__ dirs      (build artifacts; builds/ is shared)

Windows artifacts (.venv, wym.db, .agent_token, .server.pid/.server.port,
server.log) are left untouched.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-force|-f|-y|--yes) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
PIDFILE="$SERVER/.server.pid_wsl"
PORTFILE="$SERVER/.server.port_wsl"
MAIN="$SERVER/main.py"

log()   { printf '\n== %s ==\n' "$*"; }
ok()    { printf '  [OK]  %s\n' "$*"; }
warn()  { printf '  [!!]  %s\n' "$*"; }
info()  { printf '  [..]  %s\n' "$*"; }

if [ ! -d "$SERVER" ]; then
    warn "server dir not found: $SERVER"
    exit 1
fi

if [ "$FORCE" = false ]; then
    log "Uninstall C2 server"
    printf 'This will stop the server and delete virtualenvs, databases,\n'
    printf 'the agent token, logs and build artifacts (source files are kept).\n'
    ans=""
    read -r -p 'Continue? [y/N] ' ans || ans=""
    case "$ans" in
        y|Y|yes|Yes|YES) ;;
        *) echo "aborted"; exit 0 ;;
    esac
fi

is_our_pid() {
    local p="$1"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
    local cmd=""
    if [ -r "/proc/$p/cmdline" ]; then
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline")"
    elif command -v ps >/dev/null 2>&1; then
        cmd="$(ps -p "$p" -o args= 2>/dev/null || true)"
    fi
    case "$cmd" in
        *"$MAIN"*|*main.py*) return 0 ;;
        *) return 1 ;;
    esac
}

log "Stopping server"
stopped=false
if [ -f "$PIDFILE" ]; then
    pid="$(tr -d '[:space:]' < "$PIDFILE" || true)"
    if is_our_pid "$pid"; then
        kill "$pid" 2>/dev/null || true
        sleep 0.4
        kill -9 "$pid" 2>/dev/null || true
        info "stopped server (PID $pid)"
        stopped=true
    fi
    rm -f "$PIDFILE"
fi
[ "$stopped" = true ] || info "no running server found"

log "Removing files"
rm_file() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        rm -f "$1"
        info "removed $1"
    fi
}
rm_dir() {
    if [ -d "$1" ]; then
        rm -rf "$1"
        info "removed $1"
    fi
}

rm_file "$PIDFILE"
rm_file "$PORTFILE"
rm_file "$SERVER/server_wsl.log"
rm_file "$SERVER/.agent_token_wsl"
rm_file "$SERVER/wym_wsl.db"
rm_dir "$SERVER/.venv-wsl"
rm_dir "$SERVER/builds"

log "Cleaning Python bytecode caches"
find "$SERVER" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

ok "done. Source code, clients and installer scripts were kept."