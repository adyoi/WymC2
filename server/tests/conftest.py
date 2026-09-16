"""Pytest fixtures for the Wym C2 server.

Environment is pinned to a throwaway temp DB + token BEFORE importing any
server module, so tests never touch the real server data.
"""
import os
import sys
import tempfile
from pathlib import Path

import pytest

_TMP = Path(tempfile.mkdtemp(prefix="wymtest_"))
os.environ["WYM_DB_PATH"] = str(_TMP / "test.db")
os.environ["WYM_AGENT_TOKEN"] = "test-agent-token"
os.environ["WYM_RETRY_AFTER"] = "1"
os.environ["WYM_STALE_AFTER"] = "5"
os.environ["WYM_USER"] = "admin"
os.environ["WYM_PASSWORD"] = "testpass"
os.environ["WYM_API_DOCS"] = "1"
os.environ.pop("WYM_EXPLORER_UNRESTRICTED", None)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import database  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402

AGENT_HEADERS = {"X-Agent-Token": os.environ["WYM_AGENT_TOKEN"]}


@pytest.fixture(scope="session")
def client():
    """Run the app with its lifespan (creates DB, user, token files)."""
    with TestClient(app) as c:
        yield c


def insert_task(agent_id: str, task_type: str = "shell",
                args: dict | None = None, status: str = "pending",
                sent_at: str | None = None) -> str:
    """Insert a task directly and return its id (imports database)."""
    import json as _json
    import uuid

    tid = uuid.uuid4().hex
    conn = database.get_conn()
    try:
        conn.execute(
            "INSERT INTO tasks (id, agent_id, type, args, created_at, status, sent_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (tid, agent_id, task_type, _json.dumps(args or {}),
             database.utcnow(), status, sent_at),
        )
        conn.commit()
    finally:
        conn.close()
    return tid


def task_row(task_id: str) -> dict:
    conn = database.get_conn()
    try:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None