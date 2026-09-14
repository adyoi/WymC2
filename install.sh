#!/usr/bin/env bash
# Setup / install the C2 server on Linux / macOS / BSD / WSL.
# Creates a venv, installs requirements.txt, validates host/port + username/
# password, and starts the server. When C2_PASSWORD is not provided a strong
# random password is generated and printed, and the admin user is created/reset
# to it on every start (so login always matches).
#
# Design:
#   1. Resolve & VALIDATE defaults for host, port, username.
#   2. Password: -p / --password / C2_PASSWORD > random generated (printed).
#   3. Create server/.venv-wsl if missing and pip-install requirements.txt.
#   4. Verify builder toolchain for "build on server" (report missing, no
#      auto-install).
#   5. Start server (background by default; `run` for foreground console).
#      Writes server/.server.pid_wsl so uninstall can stop the right process.
#      Runtime state is kept per-OS ("._wsl" suffix) so Windows (install.ps1)
#      and Unix/WSL never collide on a shared project folder: pid/port/token/
#      log follow .venv-wsl and c2_wsl.db naming.
#
# Usage:
#   ./install.sh                         # full setup + start (background)
#   ./install.sh --help
#   ./install.sh -p "a-strong-password"
#   ./install.sh -Host 0.0.0.0 -Port 8001 -User admin
#   ./install.sh check                   # only venv + deps + toolchain
#   ./install.sh run                     # setup then run in the foreground
#
# Env: C2_HOST, C2_PORT (default 8001), C2_USER (default admin), C2_PASSWORD

set -euo pipefail

ACTION="install"
LISTEN_HOST="${C2_HOST:-}"
LISTEN_PORT="${C2_PORT:-}"
C2_USER="${C2_USER:-}"
C2_PASSWORD="${C2_PASSWORD:-}"

usage() {
    cat <<'EOF'
Usage: ./install.sh [options] [install|check|start|run]

  install   Create venv, install deps, check toolchain, start server (default)
  check     Create venv + install deps + check toolchain only
  start     Start server (assumes venv already exists)
  stop      Stop a running server (does not delete anything)
  run       Same as install, but run in the foreground

Options:
  -h, --help                 Show this help
  -Host, --host HOST         Bind address (default: 127.0.0.1, or C2_HOST)
  -Port, --port PORT         Listen port  (default: 8001, or C2_PORT)
  -User, --user USER         Dashboard user (default: admin, or C2_USER)
  -p, -Password, --password  Dashboard password (default: C2_PASSWORD or random)

Virtualenv: server/.venv-wsl   Database: server/c2_wsl.db
State:     server/.server.pid_wsl, .server.port_wsl, .agent_token_wsl,
           server/server_wsl.log

To remove the server later, run ./uninstall.sh (--force skips the prompt).
EOF
}

# Accept README-style flags (-Host/-Port/-User/-Password) and GNU long options.
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        check|start|stop|run|install) ACTION="$1"; shift ;;
        -Host|--host|-H)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
            LISTEN_HOST="$2"; shift 2 ;;
        -Port|--port|-P)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
            LISTEN_PORT="$2"; shift 2 ;;
        -User|--user|-u)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
            C2_USER="$2"; shift 2 ;;
        -p|-Password|--password)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
            C2_PASSWORD="$2"; shift 2 ;;
        --host=*|--port=*|--user=*|--password=*)
            key="${1%%=*}"; val="${1#*=}"
            case "$key" in
                --host) LISTEN_HOST="$val" ;;
                --port) LISTEN_PORT="$val" ;;
                --user) C2_USER="$val" ;;
                --password) C2_PASSWORD="$val" ;;
            esac
            shift ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
REQS="$ROOT/requirements.txt"
MAIN="$SERVER/main.py"
PIDFILE="$SERVER/.server.pid_wsl"
PORTFILE="$SERVER/.server.port_wsl"
VENV="$SERVER/.venv-wsl"
VENV_PY="$VENV/bin/python"

log()   { printf '\n== %s ==\n' "$*"; }
ok()    { printf '  [OK]  %s\n' "$*"; }
warn()  { printf '  [!!]  %s\n' "$*"; }
info()  { printf '  [..]  %s\n' "$*"; }

# ------------ defaults + validation ------------
log "Configuration"
[ -n "$LISTEN_HOST" ] || LISTEN_HOST="127.0.0.1"
[ -n "$LISTEN_PORT" ] || LISTEN_PORT="8001"
[ -n "$C2_USER" ]     || C2_USER="admin"

case "$LISTEN_PORT" in
    *[!0-9]*|'') warn "invalid C2_PORT='$LISTEN_PORT'"; exit 1 ;;
esac
if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
    warn "invalid port: $LISTEN_PORT"; exit 1
fi
if [ -z "$LISTEN_HOST" ]; then warn "host must not be empty"; exit 1; fi
if [ -z "$C2_USER" ]; then warn "user must not be empty"; exit 1; fi

if [ -z "$C2_PASSWORD" ]; then
    C2_PASSWORD="$(head -c24 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c16)"
    warn "no password provided -> generated random password: $C2_PASSWORD"
fi

info "host : $LISTEN_HOST"
info "port : $LISTEN_PORT"
info "user : $C2_USER"
info "pass : (set)"

if [ ! -d "$SERVER" ]; then warn "server dir not found: $SERVER"; exit 1; fi
if [ ! -f "$REQS" ];   then warn "requirements.txt not found: $REQS"; exit 1; fi
if [ ! -f "$MAIN" ];   then warn "server entrypoint not found: $MAIN"; exit 1; fi

# ------------ venv + deps ------------
PY=""
pick_python() {
    if [ -x "$VENV_PY" ]; then
        PY="$VENV_PY"
        return
    fi
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1; then
            PY="$(command -v "$c")"
            return
        fi
    done
    warn "no python3/python found; install Python 3.9+ first"; exit 1
}

ensure_venv() {
    log "Python environment"
    if [ ! -x "$VENV_PY" ]; then
        "$PY" -m venv "$VENV"
        info "created venv at $VENV"
    else
        info "venv already present"
    fi
    PY="$VENV_PY"
    if "$PY" -c "import fastapi, uvicorn, Crypto, jinja2, psutil" >/dev/null 2>&1; then
        info "dependencies already satisfied (fastapi, uvicorn, Crypto, jinja2, psutil)"
    else
        "$PY" -m pip install --quiet --upgrade pip
        "$PY" -m pip install --quiet -r "$REQS"
        ok "dependencies installed from requirements.txt"
    fi
}

# ------------ builder toolchain ------------
persist_dotnet_path() {
    # dotnet-install.sh installs to ~/.dotnet but only exports PATH for the
    # installing shell; make `dotnet` callable from new shells too by adding
    # the export to the user's shell profile (skipped if already present).
    local line='export PATH="$HOME/.dotnet:$PATH"'
    local dest="$HOME/.profile"
    case "${SHELL##*/}" in
        zsh)  dest="$HOME/.zshrc" ;;
        bash) dest="$HOME/.bashrc" ;;
    esac
    if [ -f "$dest" ] && grep -qsF "$line" "$dest"; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    printf '\n# .NET SDK (installed by dotnet-install.sh)\n%s\n' "$line" >> "$dest"
    info "added '$line' to $dest (start a new shell to take effect)"
}

check_toolchain() {
    log "Builder toolchain (needed for 'build on server')"
    # dotnet-install.sh installs to ~/.dotnet; a fresh shell may not have it
    # on PATH yet, so probe the default location as well and persist the
    # export so later shells (and servers) resolve `dotnet` too.
    if ! command -v dotnet >/dev/null 2>&1 &&
       { [ -x "$HOME/.dotnet/dotnet" ] || [ -x "$HOME/.dotnet/bin/dotnet" ]; }; then
        export PATH="$HOME/.dotnet:$PATH"
        persist_dotnet_path
    fi
    missing=()
    missing_count=0
    have() { command -v "$1" >/dev/null 2>&1; }
    detect_os() {
        case "$(uname -s)" in
            Darwin) echo "brew" ;;
            *)      echo "apt-get" ;;
        esac
    }
    OS_PKG="$(detect_os)"
    hint() {
        local tool="$1"; shift
        case "$OS_PKG" in
            brew) printf '        e.g.  brew install %s\n' "$tool" ;;
            *)    printf '        e.g.  sudo apt-get install -y %s\n' "$@" ;;
        esac
    }
    missing_tool() {
        warn "$1 NOT FOUND"
        missing+=("$1")
        missing_count=$((missing_count + 1))
    }

    if have javac; then ok "Java JDK (javac) -> jar"
    else missing_tool "Java (JDK)"; hint openjdk openjdk-17-jdk; fi
    if have go; then ok "Go"
    else missing_tool "Go"; hint go golang; fi
    if have cargo; then ok "Rust (cargo)"
    else missing_tool "Rust (cargo)"; hint rust rustc cargo; fi
    cc=""
    for n in x86_64-w64-mingw32-gcc gcc clang; do
        if have "$n"; then cc="$n"; break; fi
    done
    if [ -n "$cc" ]; then ok "C compiler ($cc)"
    else missing_tool "C/C++ (gcc/clang)"; hint gcc gcc g++; fi
    if have dotnet; then ok ".NET SDK ($(command -v dotnet))"
    else
        missing_tool ".NET SDK"; hint dotnet dotnet-sdk-8.0
        printf '        or run:  %s   (installs to ~/.dotnet)\n' "$ROOT/dotnet-install.sh"
    fi

    if [ "$missing_count" -gt 0 ]; then
        warn "Missing builder tools (install to enable server-side builds):"
        for m in "${missing[@]}"; do warn "  - $m"; done
    else
        ok "All builder tools available"
    fi
}

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

stop_previous() {
    if [ -f "$PIDFILE" ]; then
        old="$(tr -d '[:space:]' < "$PIDFILE" || true)"
        if is_our_pid "$old"; then
            kill "$old" 2>/dev/null || true
            sleep 0.4
            kill -9 "$old" 2>/dev/null || true
            info "stopped previous server (PID $old)"
        fi
        rm -f "$PIDFILE"
    fi
}

# ------------ start server ------------
do_start() {
    log "Starting server"
    if [ ! -x "$PY" ]; then
        warn "venv python not found: $PY (run ./install.sh first)"; exit 1
    fi
    export C2_HOST="$LISTEN_HOST"
    export C2_PORT="$LISTEN_PORT"
    export C2_USER
    export C2_PASSWORD
    stop_previous
    if [ "$ACTION" = "run" ]; then
        rm -f "$PIDFILE" "$PORTFILE"
        exec "$PY" "$MAIN"
    fi
    # Absolute path to main.py so uninstall can match the command line.
    # nohup (not setsid) so this also works on macOS, where setsid is absent.
    nohup "$PY" "$MAIN" >> "$SERVER/server_wsl.log" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    echo "$LISTEN_PORT" > "$PORTFILE"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        warn "server exited immediately — last log lines:"
        tail -n 30 "$SERVER/server_wsl.log" 2>/dev/null || true
        rm -f "$PIDFILE"
        exit 1
    fi
    ok "server started (PID $pid) -> http://$LISTEN_HOST:$LISTEN_PORT"
    ok "login: $C2_USER / $C2_PASSWORD"
    if [ -f "$SERVER/.agent_token_wsl" ]; then
        printf '  X-Agent-Token: %s\n' "$(tr -d '\r\n' < "$SERVER/.agent_token_wsl")"
    fi
    warn "logs: $SERVER/server_wsl.log (use: ./install.sh run  for foreground)"
}

pick_python
case "$ACTION" in
    check)
        ensure_venv
        check_toolchain
        ;;
    start)
        PY="$VENV_PY"
        do_start
        printf '\nDone. Open http://%s:%s/login\n' "$LISTEN_HOST" "$LISTEN_PORT"
        ;;
    stop)
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
        rm -f "$PORTFILE"
        [ "$stopped" = true ] || info "no running server found"
        ;;
    run)
        ensure_venv
        check_toolchain
        do_start
        ;;
    install|*)
        ensure_venv
        check_toolchain
        do_start
        printf '\nDone. Open http://%s:%s/login\n' "$LISTEN_HOST" "$LISTEN_PORT"
        ;;
esac
