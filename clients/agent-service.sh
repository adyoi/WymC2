#!/usr/bin/env bash
# agent-service.sh - Install/manage a Wym C2 agent as a service (Linux/macOS)
#
# Supports every agent shipped in clients/:
#   - Interpreted scripts : agent.py (py), agent.js (js), agent.lua (lua),
#                           agent.php (php), agent.pl (perl), agent.rb (ruby),
#                           agent.sh (bash)
#   - Compiled binaries   : any executable built in ahead of time
#   - Compilable sources  : agent.c/.cpp/.cs/.go/.rs/.java compiled at install
#                           time with --build
# The runtime is auto-detected from the agent file and the C2 flags stay the
# same across agents (--server/--token/--interval/--jitter/--verbose).
#
# Backends (picked per --backend):
#   Linux  :
#     - systemd (systemctl) -> service named "c2agent" (Description = the Wym
#       C2 agent label).  start: systemctl start c2agent  relaunch: same
#     - Fallback / forced  : cron keeps the agent alive (@hourly, --at-boot for
#       @reboot) with a pidfile for clean stop/status
#   macOS (Darwin):
#     - launchd (launchctl) -> LaunchAgent "com.c2agent.agent"
#     - Fallback / forced  : cron (same as above)
#
# Token resolution order: -t, then project server/.agent_token_wsl (or
# server/.agent_token).  Re-running install rewrites the unit/config so a
# changed server/token is applied in place.
#
# Usage:
#   ./agent-service.sh <action> [options]
#
# Actions:
#   install     Install as native service (systemd/launchd) or cron job
#   uninstall   Remove service/cron
#   start       Start the agent
#   stop        Stop the agent
#   restart     Restart the agent
#   status      Show status
#   relaunch    Alias for start (used by clone watchers)
#
# Options (can also be env vars):
#   -s, --server URL       C2 server URL (e.g. http://127.0.0.1:8000)
#   -t, --token TOKEN      Agent token
#   -i, --interval SEC     Beacon interval (default: 10)
#   -j, --jitter SEC       Jitter seconds (default: 2)
#   -a, --agent PATH       Path to agent file (default: ./agent.py)
#   -b, --backend NAME     systemd|launchd|auto (default: auto)
#   --cron                 Use cron instead of native service (alias for -b cron)
#   --build                Compile agent.c/.cpp/.cs/.go/.rs/.java first
#   -l, --lang NAME        Force runtime: python|node|lua|php|perl|ruby|bash|java|binary
#   --at-boot              With cron: run @reboot instead of hourly
#   -v, --verbose          Verbose agent logging
#   -h, --help             Show this help

set -euo pipefail

ACTION="${1:-}"
SERVER="${SERVER:-}"
TOKEN="${TOKEN:-}"
INTERVAL="${INTERVAL:-10}"
JITTER="${JITTER:-2}"
AGENT_PY="${AGENT_SCRIPT:-}"
USE_CRON="${USE_CRON:-false}"
AT_BOOT="${AT_BOOT:-false}"
VERBOSE="${VERBOSE:-false}"
BACKEND="${BACKEND:-auto}"
AGENT_LANG="auto"
BUILD="${BUILD:-false}"

SERVICE_NAME="c2agent"
LAUNCHD_LABEL="com.c2agent.agent"
CRON_TAG="# Wym C2 Agent managed by agent-service.sh"
PID_FILE=""
AGENT_DESC="Wym C2 are What you missed is Command and Control Frameworks"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$ROOT_DIR")"
AGENT_FILE="${AGENT_PY:-$ROOT_DIR/agent.py}"

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Linux)   PLATFORM="linux" ;;
    Darwin)  PLATFORM="darwin" ;;
    *)       die "Unsupported OS: $OS" ;;
esac

usage() {
    sed -n '2,/^# -h/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | grep -v '^$' || true
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        install|uninstall|start|stop|restart|status|relaunch) ACTION="$1"; shift ;;
        -s|--server) SERVER="$2"; shift 2 ;;
        -t|--token) TOKEN="$2"; shift 2 ;;
        -i|--interval) INTERVAL="$2"; shift 2 ;;
        -j|--jitter) JITTER="$2"; shift 2 ;;
        -a|--agent) AGENT_FILE="$2"; shift 2 ;;
        -b|--backend) BACKEND="$2"; shift 2 ;;
        -l|--lang) AGENT_LANG="$2"; shift 2 ;;
        --build) BUILD=true; shift ;;
        --cron) USE_CRON=true; shift ;;
        --at-boot) AT_BOOT=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "$ACTION" ]] && { usage; die "Action required"; }

resolve_py() {
    command -v python3 || command -v python || echo "python3"
}

tools() {
    local want="$1"
    shift
    local t
    local found
    for t in "$@"; do
        found="$(type -P "$t" 2>/dev/null)"
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    done
    die "required tool not found: $want - install it or pass a prebuilt -a agent"
}

lang_label() {
    local file="$1"
    case "$file" in
        *.py) echo "python" ;; *.js) echo "node" ;; *.lua) echo "lua" ;;
        *.php) echo "php" ;; *.pl) echo "perl" ;; *.rb) echo "ruby" ;;
        *.sh) echo "bash" ;; *.jar) echo "java" ;; *.c) echo "c" ;;
        *.cpp) echo "cpp" ;; *.cs) echo "csharp" ;; *.go) echo "go" ;;
        *.rs) echo "rust" ;;
        *) local b; b="$(basename "$file")"; b="${b%.*}"; echo "${b:-binary}" ;;
    esac
}

build_agent() {
    local ext="$1"
    local src="$AGENT_FILE"
    case "$ext" in
        c)
            local cc; cc="$(tools gcc gcc cc clang)"
            "$cc" -O2 -o "$ROOT_DIR/c2agent-c" "$src"
            AGENT_FILE="$ROOT_DIR/c2agent-c"
            ;;
        cpp)
            local cxx; cxx="$(tools g++ g++ clang++)"
            "$cxx" -O2 -o "$ROOT_DIR/c2agent-cpp" "$src"
            AGENT_FILE="$ROOT_DIR/c2agent-cpp"
            ;;
        go)
            local go; go="$(tools go go)"
            "$go" build -o "$ROOT_DIR/c2agent-go" "$src"
            AGENT_FILE="$ROOT_DIR/c2agent-go"
            ;;
        rs)
            local rustc; rustc="$(tools rustc rustc)"
            "$rustc" -O --edition 2021 -o "$ROOT_DIR/c2agent-rs" "$src"
            AGENT_FILE="$ROOT_DIR/c2agent-rs"
            ;;
        cs)
            local dot; dot="$(tools dotnet dotnet)"
            local tmp="$ROOT_DIR/.c2csbuild-$RANDOM"
            mkdir -p "$tmp"
            cp "$src" "$tmp/Program.cs"
            ( cd "$tmp" && "$dot" new console --force -o . >/dev/null 2>&1 && "$dot" build -o "$tmp/out" -q ) \
                || { rm -rf "$tmp"; die "dotnet build failed"; }
            AGENT_FILE="$(find "$tmp/out" -maxdepth 1 -type f ! -name '*.pdb' ! -name '*.dll' 2>/dev/null | head -n1)"
            [[ -n "$AGENT_FILE" ]] || { rm -rf "$tmp"; die "dotnet produced no binary"; }
            ;;
        java)
            local jc jar; jc="$(tools javac javac)"; jar="$(tools jar jar)"
            local d="$ROOT_DIR/.c2jbuild-$RANDOM"
            mkdir -p "$d"
            "$jc" --release 8 -encoding UTF-8 -d "$d" "$src" || { rm -rf "$d"; die "javac failed"; }
            "$jar" cfe "$ROOT_DIR/c2agent-java.jar" Agent -C "$d" . || { rm -rf "$d"; die "jar failed"; }
            rm -rf "$d"
            AGENT_FILE="$ROOT_DIR/c2agent-java.jar"
            ;;
        *) die "cannot build .$ext source; pass a prebuilt -a agent" ;;
    esac
    [[ -e "$AGENT_FILE" ]] || die "build produced no output: $AGENT_FILE"
    log "built agent: $AGENT_FILE"
}

CMD_LEAD=()
resolve_cmd() {
    local file="$1"
    local p
    CMD_LEAD=()
    if [[ "$AGENT_LANG" != "auto" ]]; then
        case "$AGENT_LANG" in
            python) CMD_LEAD=( "$(resolve_py)" "$file" ) ;;
            node)   CMD_LEAD=( "$(tools node node)" "$file" ) ;;
            lua)    CMD_LEAD=( "$(tools lua lua5.4 lua5.3)" "$file" ) ;;
            php)    CMD_LEAD=( "$(tools php php)" "$file" ) ;;
            perl)   CMD_LEAD=( "$(tools perl perl)" "$file" ) ;;
            ruby)   CMD_LEAD=( "$(tools ruby ruby)" "$file" ) ;;
            bash)   CMD_LEAD=( bash "$file" ) ;;
            java)   CMD_LEAD=( "$(tools java java)" -jar "$file" ) ;;
            binary) CMD_LEAD=( "$file" ) ;;
        esac
    else
        case "$file" in
            *.py)  CMD_LEAD=( "$(resolve_py)" "$file" ) ;;
            *.js)  CMD_LEAD=( "$(tools node node)" "$file" ) ;;
            *.lua) CMD_LEAD=( "$(tools lua lua5.4 lua5.3)" "$file" ) ;;
            *.php) CMD_LEAD=( "$(tools php php)" "$file" ) ;;
            *.pl)  CMD_LEAD=( "$(tools perl perl)" "$file" ) ;;
            *.rb)  CMD_LEAD=( "$(tools ruby ruby)" "$file" ) ;;
            *.sh)  CMD_LEAD=( bash "$file" ) ;;
            *.jar) CMD_LEAD=( "$(tools java java)" -jar "$file" ) ;;
            *)     CMD_LEAD=( "$file" ) ;;
        esac
    fi
    p="${CMD_LEAD[0]-}"
    if [[ "$AGENT_LANG" == "binary" || "$(case "${CMD_LEAD[0]-}" in *"$file"*) echo bin;; esac)" == "bin" ]]; then
        [[ -x "$p" ]] || die "agent binary not executable: $p"
    else
        type -P "$p" >/dev/null 2>&1 || die "runtime not found: $p"
    fi
}

# Backend detection
svc_enabled() {
    case "$PLATFORM" in
        linux)   [[ -n "$(systemctl list-unit-files --type=service 2>/dev/null | grep "^${SERVICE_NAME}\.service")" ]] ;;
        darwin)  [[ -n "$(launchctl list 2>/dev/null | grep "$LAUNCHD_LABEL")" ]] ;;
    esac
}

cron_enabled() {
    [[ -n "$(crontab -l 2>/dev/null | grep "$CRON_TAG")" ]]
}

get_backend() {
    if [[ "$BACKEND" == "cron" ]]; then
        cron_enabled && echo "cron" || echo "none"
        return
    fi
    if [[ "$BACKEND" == "systemd" ]]; then
        svc_enabled && echo "systemd" || echo "none"
        return
    fi
    if [[ "$BACKEND" == "launchd" ]]; then
        svc_enabled && echo "launchd" || echo "none"
        return
    fi
    # auto
    if svc_enabled; then
        case "$PLATFORM" in
            linux)  echo "systemd" ;;
            darwin) echo "launchd" ;;
        esac
    elif cron_enabled; then
        echo "cron"
    else
        echo "none"
    fi
}

token_flag() {
    # Parsers differ: python/go/php/perl/ruby accept '--token=TOKEN' (required
    # for argv parsers when the token starts with '-'); the C-like/raw parsers
    # consume the next token literally, so pass '--token TOKEN'.
    case "$(lang_label "$AGENT_FILE")" in
        python|go|php|perl|ruby) printf '%s' "--token=$TOKEN" ;;
        *) printf '%s' "--token"; printf ' %s' "$TOKEN" ;;
    esac
}

build_cmd() {
    local cmd=("${CMD_LEAD[@]}" --server "$SERVER" $(token_flag) --interval "$INTERVAL" --jitter "$JITTER")
    # per-install state file (distinct across hosts/ports to avoid
    # WIN+WSL fighting over the same .c2agent.json and re-registering).
    if [[ "$(lang_label "$AGENT_FILE")" == "lua" ]]; then
        local port="${SERVER##*:}"
        local sf="/root/.c2agent-${port}.json"
        if [[ -d "$HOME" ]]; then sf="$HOME/.c2agent-${port}.json"; fi
        cmd+=(--state "$sf")
    fi
    [[ "$VERBOSE" == "true" ]] && cmd+=(--verbose)
    local out="" a
    for a in "${cmd[@]}"; do
        out+="$(printf '"%s" ' "$a")"
    done
    printf '%s' "$out"
}

check_args() {
    [[ -e "$AGENT_FILE" ]] || die "agent file not found: $AGENT_FILE"
    resolve_cmd "$AGENT_FILE"
    [[ -n "$SERVER" ]] || { read -rp "C2 server URL (e.g. http://127.0.0.1:8000): " SERVER; [[ -n "$SERVER" ]] || die "Server required"; }
    [[ -n "$TOKEN" ]] || {
        local tok_file
        for tok_file in "$PROJECT_DIR/server/.agent_token_wsl" "$PROJECT_DIR/server/.agent_token" \
                         "$ROOT_DIR/server/.agent_token_wsl" "$ROOT_DIR/server/.agent_token"; do
            if [[ -f "$tok_file" ]]; then
                TOKEN="$(head -n1 "$tok_file" | tr -d '[:space:]')"
                break
            fi
        done
        [[ -n "$TOKEN" ]] || die "Token required (pass -t or have server/.agent_token_wsl)"
    }
}

# ---------- Linux: systemd ----------
install_systemd() {
    check_args
    local cmd; cmd="$(build_cmd)"
    local label; label="$(lang_label "$AGENT_FILE")"

    log "Installing systemd service: $SERVICE_NAME"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Wym C2 Agent $label - $AGENT_DESC
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
ExecStart=$cmd
Restart=always
RestartSec=5
StandardOutput=append:/var/log/c2agent.log
StandardError=append:/var/log/c2agent.err.log
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl restart "$SERVICE_NAME"
        log "Updated+restarted systemd service '$SERVICE_NAME'"
    else
        log "Installed systemd service '$SERVICE_NAME' (enabled, not started)"
    fi
}

uninstall_systemd() {
    if svc_enabled; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        log "Removed systemd service '$SERVICE_NAME'"
    fi
}

start_systemd() {
    systemctl start "$SERVICE_NAME"
    log "Started systemd service '$SERVICE_NAME'"
}

stop_systemd() {
    systemctl stop "$SERVICE_NAME"
    log "Stopped systemd service '$SERVICE_NAME'"
}

status_systemd() {
    echo "backend : systemd"
    echo "name    : $SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager -l | head -12 || true
    if [[ -f /var/log/c2agent.err.log ]]; then
        echo "recent stderr:"
        tail -5 /var/log/c2agent.err.log | sed 's/^/  /'
    fi
}

# ---------- macOS: launchd ----------
install_launchd() {
    check_args
    local cmd; cmd="$(build_cmd)"
    local label; label="$(lang_label "$AGENT_FILE")"

    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/${LAUNCHD_LABEL}.plist"

    log "Installing launchd agent: $LAUNCHD_LABEL"
    mkdir -p "$plist_dir"

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
EOF
    local arr=("${CMD_LEAD[@]}" --server "$SERVER" $(token_flag) --interval "$INTERVAL" --jitter "$JITTER")
    if [[ "$(lang_label "$AGENT_FILE")" == "lua" ]]; then
        local port="${SERVER##*:}"
        arr+=(--state "$HOME/.c2agent-${port}.json")
    fi
    [[ "$VERBOSE" == "true" ]] && arr+=(--verbose)
    local a
    for a in "${arr[@]}"; do
        printf '        <string>%s</string>\n' "$a" >> "$plist_file"
    done
    cat >> "$plist_file" <<EOF
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>$ROOT_DIR/C2Agent.log</string>
    <key>StandardErrorPath</key>
    <string>$ROOT_DIR/C2Agent.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
</dict>
</plist>
EOF

    launchctl unload "$plist_file" 2>/dev/null || true
    launchctl load "$plist_file" 2>/dev/null || true
    log "Installed launchd agent '$LAUNCHD_LABEL' ($label, loaded, not started)"
}

uninstall_launchd() {
    local plist_file="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
    if [[ -f "$plist_file" ]] || launchctl list 2>/dev/null | grep -q "$LAUNCHD_LABEL"; then
        launchctl unload "$plist_file" 2>/dev/null || true
        launchctl remove "$LAUNCHD_LABEL" 2>/dev/null || true
        rm -f "$plist_file"
        log "Removed launchd agent '$LAUNCHD_LABEL'"
    fi
}

start_launchd() {
    launchctl start "$LAUNCHD_LABEL"
    log "Started launchd agent '$LAUNCHD_LABEL'"
}

stop_launchd() {
    launchctl stop "$LAUNCHD_LABEL" 2>/dev/null || true
    log "Stopped launchd agent '$LAUNCHD_LABEL'"
}

status_launchd() {
    echo "backend : launchd"
    echo "name    : $LAUNCHD_LABEL"
    launchctl list | grep "$LAUNCHD_LABEL" || true
    if [[ -f "$ROOT_DIR/C2Agent.err.log" ]]; then
        echo "recent stderr:"
        tail -5 "$ROOT_DIR/C2Agent.err.log" | sed 's/^/  /'
    fi
}

# ---------- Cron (fallback / forced) ----------
PID_FILE="$ROOT_DIR/.c2agent-cron.pid"

install_cron() {
    check_args
    local cmd; cmd="$(build_cmd)"
    local schedule
    schedule=$([[ "$AT_BOOT" == "true" ]] && echo "@reboot" || echo "0 * * * *")

    log "Installing cron job: $SERVICE_NAME"
    local tmpfile="/tmp/c2cron.$$"
    ( crontab -l 2>/dev/null || true ) | grep -v "$CRON_TAG" > "$tmpfile" || true
    echo "$schedule $cmd $CRON_TAG" >> "$tmpfile"
    crontab "$tmpfile"
    rm -f "$tmpfile"
    printf '%s\n' "$cmd" > "${HOME}/.c2agent-cron.cmd"
    log "Installed cron job '$SERVICE_NAME' (schedule: $schedule)"
}

uninstall_cron() {
    if cron_enabled; then
        local tmpfile="/tmp/c2cron.$$"
        ( crontab -l 2>/dev/null || true ) | grep -v "$CRON_TAG" > "$tmpfile" || true
        crontab "$tmpfile"
        rm -f "$tmpfile"
        log "Removed cron job '$SERVICE_NAME'"
    fi
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid="$(head -n1 "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    rm -f "${HOME}/.c2agent-cron.cmd"
}

start_cron() {
    if [[ -f "$PID_FILE" ]]; then
        local old; old="$(head -n1 "$PID_FILE" | tr -d '[:space:]')"
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            log "Agent already running (pid $old; cron backend)"
            return
        fi
        rm -f "$PID_FILE"
    fi
    local runcmd=""
    if [[ -f "${HOME}/.c2agent-cron.cmd" ]]; then
        runcmd="$(<"${HOME}/.c2agent-cron.cmd")"
    fi
    if [[ -z "$runcmd" ]]; then
        resolve_cmd "$AGENT_FILE"
        runcmd="$(build_cmd)"
    fi
    nohup bash -c "$runcmd" >/var/log/c2agent-cron.log 2>&1 </dev/null &
    echo $! > "$PID_FILE"
    log "Launched agent directly (pid $(cat "$PID_FILE"); cron backend)"
}

stop_cron() {
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid="$(head -n1 "$PID_FILE" | tr -d '[:space:]')"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log "Stopped agent (pid $pid)"
        fi
        rm -f "$PID_FILE"
    else
        log "No tracked agent pid (cron backend)"
    fi
}

status_cron() {
    echo "backend : cron"
    echo "name    : $SERVICE_NAME"
    crontab -l 2>/dev/null | grep "$CRON_TAG" || true
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid="$(head -n1 "$PID_FILE" | tr -d '[:space:]')"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "status  : running (pid $pid)"
        else
            echo "status  : not running (stale pid $pid)"
        fi
    else
        echo "status  : not running"
    fi
}

# ---------- Dispatch ----------
install_agent() {
    local ext="${AGENT_FILE##*.}"
    case "$ext" in c|cpp|cs|go|rs|java)
        if [[ "$BUILD" == "true" ]]; then
            build_agent "$ext"
        else
            die ".$ext source needs --build (or pass a prebuilt -a agent)"
        fi
        ;;
    esac
    local be="$BACKEND"
    if [[ "$USE_CRON" == "true" ]]; then
        be="cron"
    elif [[ "$be" == "auto" ]]; then
        case "$PLATFORM" in
            linux)  be="systemd" ;;
            darwin) be="launchd" ;;
        esac
    fi
    case "$be" in
        systemd)  install_systemd ;;
        launchd)  install_launchd ;;
        cron)     install_cron ;;
        *)        die "unknown backend: $be (systemd|launchd|cron)" ;;
    esac
}

uninstall_agent() {
    case "$PLATFORM" in
        linux)  uninstall_systemd ;;
        darwin) uninstall_launchd ;;
    esac
    uninstall_cron
    [[ "$(get_backend)" == "none" ]] && log "Nothing was installed"
}

start_agent() {
    local backend; backend="$(get_backend)"
    case "$backend" in
        systemd)  start_systemd ;;
        launchd)  start_launchd ;;
        cron)     start_cron ;;
        none)     die "Nothing installed - run 'install' first" ;;
    esac
}

stop_agent() {
    local backend; backend="$(get_backend)"
    case "$backend" in
        systemd)  stop_systemd ;;
        launchd)  stop_launchd ;;
        cron)     stop_cron ;;
        none)     log "Nothing installed" ;;
    esac
}

status_agent() {
    local backend; backend="$(get_backend)"
    case "$backend" in
        systemd)  status_systemd ;;
        launchd)  status_launchd ;;
        cron)     status_cron ;;
        none)     echo "backend : none (not installed)" ;;
    esac
}

# Main
case "$ACTION" in
    install)   install_agent ;;
    uninstall) uninstall_agent ;;
    start)     start_agent ;;
    stop)      stop_agent ;;
    restart)   stop_agent; sleep 1; start_agent ;;
    status)    status_agent ;;
    relaunch)  start_agent ;;
    *)         die "Unknown action: $ACTION" ;;
esac