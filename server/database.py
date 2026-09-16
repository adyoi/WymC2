"""SQLite persistence layer for the C2 server."""
import os
import sqlite3
import sys
from datetime import datetime, timezone

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _default_db_name() -> str:
    """Pick a per-OS database so Windows and Unix (Linux/macOS/BSD/WSL)
    deployments never share the same SQLite file by default.

    Windows -> wym.db   (install.ps1, port 8000)
    Unix    -> wym_wsl.db   (install.sh, port 8001)
    """
    return "wym.db" if sys.platform == "win32" else "wym_wsl.db"


DB_PATH = os.environ.get("WYM_DB_PATH", os.path.join(BASE_DIR, _default_db_name()))
# ensure parent dir exists for a custom DB location
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True) if os.path.dirname(DB_PATH) else None

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    last_seen     TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT PRIMARY KEY,
    username   TEXT NOT NULL,
    expires_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
    id         TEXT PRIMARY KEY,
    hostname   TEXT NOT NULL,
    username   TEXT DEFAULT '',
    os         TEXT DEFAULT '',
    arch       TEXT DEFAULT '',
    pid        INTEGER DEFAULT 0,
    ip         TEXT DEFAULT '',
    version    TEXT DEFAULT '',
    type       TEXT DEFAULT '',
    first_seen TEXT NOT NULL,
    last_seen  TEXT NOT NULL,
    note       TEXT DEFAULT '',
    note_by    TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS tokens (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    token      TEXT NOT NULL UNIQUE,
    server_url TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    last_used  TEXT
);

CREATE TABLE IF NOT EXISTS tasks (
    id           TEXT PRIMARY KEY,
    agent_id     TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    type         TEXT NOT NULL,
    args         TEXT NOT NULL DEFAULT '{}',
    created_at   TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'pending',
    sent_at      TEXT,
    result       TEXT,
    exit_code    INTEGER,
    completed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_agent ON tasks(agent_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_agents_seen  ON agents(last_seen);
"""


def utcnow() -> str:
    """Naive UTC timestamp string, e.g. '2026-08-15 12:34:56'."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    conn = get_conn()
    try:
        conn.executescript(SCHEMA)
        # migration: add last_seen to users if missing
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(users)").fetchall()]
        if "last_seen" not in cols:
            conn.execute("ALTER TABLE users ADD COLUMN last_seen TEXT")
        # migration: ADMIN ROLE — first user is admin, others are not
        if "is_admin" not in cols:
            conn.execute("ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")
            conn.execute(
                "UPDATE users SET is_admin=1 WHERE id=(SELECT MIN(id) FROM users)"
            )
        # migration: add note_by to agents if missing
        acols = [r["name"] for r in conn.execute("PRAGMA table_info(agents)").fetchall()]
        if "note_by" not in acols:
            conn.execute("ALTER TABLE agents ADD COLUMN note_by TEXT DEFAULT ''")
        # migration: add type (client language) to agents if missing
        if "type" not in acols:
            conn.execute("ALTER TABLE agents ADD COLUMN type TEXT DEFAULT ''")
        # migration: mark agents that were told to exit
        if "exited_at" not in acols:
            conn.execute("ALTER TABLE agents ADD COLUMN exited_at TEXT")
        conn.commit()
    finally:
        conn.close()


# ── Token CRUD ──────────────────────────────────────────────

def create_token(name: str, token: str, server_url: str = "") -> dict:
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO tokens (name, token, server_url, created_at) VALUES (?, ?, ?, ?)",
            (name, token, server_url, utcnow()),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM tokens WHERE token = ?", (token,)).fetchone()
        return dict(row)
    finally:
        conn.close()


def get_tokens() -> list[dict]:
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM tokens ORDER BY id DESC").fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def get_token(token: str) -> dict | None:
    conn = get_conn()
    try:
        row = conn.execute("SELECT * FROM tokens WHERE token = ?", (token,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def update_token_last_used(token: str) -> None:
    conn = get_conn()
    try:
        conn.execute("UPDATE tokens SET last_used = ? WHERE token = ?", (utcnow(), token))
        conn.commit()
    finally:
        conn.close()


def delete_token(token: str) -> bool:
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM tokens WHERE token = ?", (token,))
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()
