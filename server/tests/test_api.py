"""Agent API + auth tests for the Wym C2 server."""
import os
import re
import uuid
from datetime import datetime, timedelta, timezone

from main import COLLECTED_DIR, SHARED_DIR

from conftest import AGENT_HEADERS, insert_task, task_row


def _register(client, agent_id: str | None = None, hostname: str = "win-host") -> dict:
    body = {
        "agent_id": agent_id,
        "hostname": hostname,
        "username": "alice",
        "os": "windows",
        "arch": "amd64",
        "pid": 4242,
        "ip": "192.168.1.10",
        "version": "1.0",
        "type": "python",
    }
    r = client.post("/api/register", json=body, headers=AGENT_HEADERS)
    assert r.status_code == 200, r.text
    return r.json()


def test_register_new_agent_assigns_id(client):
    data = _register(client)
    assert data["status"] == "registered"
    assert len(data["agent_id"]) == 32


def test_reregister_same_id_returns_known(client):
    first = _register(client)
    data = _register(client, agent_id=first["agent_id"])
    assert data["status"] == "known"
    assert data["agent_id"] == first["agent_id"]


def test_register_requires_agent_token(client):
    body = {"hostname": "nohost", "username": "u", "os": "linux"}
    assert client.post("/api/register", json=body).status_code == 401
    assert client.post("/api/register", json=body,
                       headers={"X-Agent-Token": "wrong"}).status_code == 401


def test_checkin_unknown_agent_returns_404(client):
    r = client.post("/api/checkin", json={"agent_id": "does-not-exist"},
                    headers=AGENT_HEADERS)
    assert r.status_code == 404


def test_full_roundtrip_pending_task(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, args={"command": "whoami", "timeout": 12})

    checkin = client.post("/api/checkin", json={"agent_id": agent_id},
                          headers=AGENT_HEADERS).json()
    tasks = checkin["tasks"]
    assert [t["task_id"] for t in tasks] == [tid]
    assert tasks[0]["type"] == "shell"
    assert tasks[0]["args"]["command"] == "whoami"

    # task is now `sent`, not delivered twice on a second checkin
    assert task_row(tid)["status"] == "sent"
    second = client.post("/api/checkin", json={"agent_id": agent_id},
                         headers=AGENT_HEADERS).json()
    assert [t["task_id"] for t in second["tasks"]] == []

    # report the result
    r = client.post("/api/result", json={
        "agent_id": agent_id, "task_id": tid,
        "output": "alice\n", "exit_code": 0,
    }, headers=AGENT_HEADERS)
    assert r.status_code == 200 and r.json()["ok"] is True
    row = task_row(tid)
    assert row["status"] == "completed"
    assert row["result"] == "alice\n"
    assert row["exit_code"] == 0


def test_unacked_sent_task_is_requeued_and_redelivered(client):
    agent_id = _register(client)["agent_id"]
    stale = (datetime.now(timezone.utc).replace(tzinfo=None)
             - timedelta(seconds=10)).strftime("%Y-%m-%d %H:%M:%S")
    tid = insert_task(agent_id, status="sent", sent_at=stale)

    checkin = client.post("/api/checkin", json={"agent_id": agent_id},
                          headers=AGENT_HEADERS).json()
    assert [t["task_id"] for t in checkin["tasks"]] == [tid]
    assert task_row(tid)["sent_at"] is not None


def test_result_for_unknown_task_returns_404(client):
    agent_id = _register(client)["agent_id"]
    r = client.post("/api/result", json={
        "agent_id": agent_id, "task_id": "missing-task",
    }, headers=AGENT_HEADERS)
    assert r.status_code == 404


def test_exit_task_marks_agent_exited(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, task_type="exit")
    client.post("/api/checkin", json={"agent_id": agent_id}, headers=AGENT_HEADERS)
    r = client.post("/api/result", json={
        "agent_id": agent_id, "task_id": tid, "output": "", "exit_code": 0,
    }, headers=AGENT_HEADERS)
    assert r.status_code == 200
    conn = __import__("database", fromlist=["get_conn"]).get_conn()
    try:
        row = conn.execute("SELECT exited_at FROM agents WHERE id=?",
                           (agent_id,)).fetchone()
    finally:
        conn.close()
    assert row and row["exited_at"]


def test_login_wrong_password_returns_401(client):
    r = client.post("/login", data={"username": "admin", "password": "nope"})
    assert r.status_code == 401


def test_login_correct_password_redirects_to_dashboard(client):
    r = client.post("/login", data={"username": "admin", "password": "testpass"},
                    follow_redirects=False)
    assert r.status_code == 303
    assert r.headers["location"].endswith("/dashboard")
    assert client.get("/dashboard").status_code == 200


def test_metrics_endpoint_reports_registered_agent(client):
    _register(client, hostname="metric-host")
    client.post("/login", data={"username": "admin", "password": "testpass"},
                follow_redirects=False)
    r = client.get("/api/metrics")
    assert r.status_code == 200
    body = r.json()
    assert body["agents"]["total"] >= 1
    assert body["tasks"]["total"] >= 0


def test_environment_vars_seeded(client):
    assert os.environ["WYM_AGENT_TOKEN"] == "test-agent-token"


# ---------------------------------------------------------------------------
# File staging: `download` (server pushes to agent) and `upload` (agent pulls
# a file back to the server).
# ---------------------------------------------------------------------------


def test_download_pull_serves_staged_file(client):
    agent_id = _register(client)["agent_id"]
    staging = SHARED_DIR / f"seed_{uuid.uuid4().hex[:8]}.txt"
    try:
        staging.write_text("payload-1234", encoding="utf-8")
        tid = insert_task(agent_id, task_type="download",
                          args={"file": staging.name})
        r = client.get(f"/api/files/{tid}", headers=AGENT_HEADERS)
        assert r.status_code == 200
        assert r.content == b"payload-1234"
        assert staging.name in r.headers.get("content-disposition", "")
    finally:
        staging.unlink(missing_ok=True)


def test_upload_push_saves_file_under_collected(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, task_type="upload")
    r = client.post(f"/api/files/{tid}",
                    files={"file": ("beacon.bin", b"\x00\x01\x02secret")},
                    headers=AGENT_HEADERS)
    assert r.status_code == 200 and r.json()["ok"] is True
    saved = r.json()["saved"]
    assert saved == f"{agent_id}__{tid}__beacon.bin"
    dest = COLLECTED_DIR / saved
    try:
        assert dest.read_bytes() == b"\x00\x01\x02secret"
    finally:
        dest.unlink(missing_ok=True)


def test_files_endpoint_rejects_wrong_task_type(client):
    agent_id = _register(client)["agent_id"]
    up_tid = insert_task(agent_id, task_type="upload")
    sh_tid = insert_task(agent_id, task_type="shell", args={"command": "id"})
    # GET serves only `download` tasks
    assert client.get(f"/api/files/{up_tid}", headers=AGENT_HEADERS).status_code == 404
    assert client.get(f"/api/files/{sh_tid}", headers=AGENT_HEADERS).status_code == 404
    # POST accepts only upload/screenshot/steal
    r = client.post(f"/api/files/{sh_tid}",
                    files={"file": ("x.bin", b"x")}, headers=AGENT_HEADERS)
    assert r.status_code == 404


def test_pending_pull_file_missing_is_404(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, task_type="download", args={"file": "nope.bin"})
    assert client.get(f"/api/files/{tid}", headers=AGENT_HEADERS).status_code == 404


# ---------------------------------------------------------------------------
# Task routing semantics
# ---------------------------------------------------------------------------


def test_checkin_delivers_only_own_agents_tasks(client):
    a = _register(client, hostname="agent-a")["agent_id"]
    b = _register(client, hostname="agent-b")["agent_id"]
    tid = insert_task(a, args={"command": "whoami"})

    given_b = client.post("/api/checkin", json={"agent_id": b},
                          headers=AGENT_HEADERS).json()
    assert given_b["tasks"] == []

    given_a = client.post("/api/checkin", json={"agent_id": a},
                          headers=AGENT_HEADERS).json()
    assert [t["task_id"] for t in given_a["tasks"]] == [tid]


def test_pending_tasks_delivered_in_creation_order(client):
    agent_id = _register(client)["agent_id"]
    ids = [insert_task(agent_id, args={"command": c}) for c in ("a", "b", "c")]
    checkin = client.post("/api/checkin", json={"agent_id": agent_id},
                          headers=AGENT_HEADERS).json()
    assert [t["task_id"] for t in checkin["tasks"]] == ids


def test_result_for_wrong_agent_returns_404(client):
    a = _register(client, hostname="agent-a")["agent_id"]
    b = _register(client, hostname="agent-b")["agent_id"]
    tid = insert_task(a, args={"command": "whoami"})
    r = client.post("/api/result", json={
        "agent_id": b, "task_id": tid, "output": "oops", "exit_code": 1,
    }, headers=AGENT_HEADERS)
    assert r.status_code == 404


def test_cancel_pending_task_prevents_delivery(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, args={"command": "whoami"})
    client.post("/login", data={"username": "admin", "password": "testpass"},
                follow_redirects=False)
    # forms need the CSRF token served by every page (base.html meta tag)
    page = client.get("/dashboard").text
    csrf = re.search(r'name="csrf-token" content="([^"]+)"', page).group(1)
    r = client.post(f"/tasks/{tid}/cancel",
                    data={"csrf_token": csrf}, follow_redirects=False)
    assert r.status_code == 303
    assert task_row(tid)["status"] == "cancelled"
    checkin = client.post("/api/checkin", json={"agent_id": agent_id},
                          headers=AGENT_HEADERS).json()
    assert checkin["tasks"] == []


def test_clone_status_endpoint_reports_target_state(client):
    agent_id = _register(client)["agent_id"]
    r = client.get(f"/api/clone/status/{agent_id}", headers=AGENT_HEADERS)
    assert r.status_code == 200
    body = r.json()
    assert body["agent_id"] == agent_id
    assert body["status"] == "alive"
    assert body["last_seen"]
    assert client.get("/api/clone/status/missing-agent",
                      headers=AGENT_HEADERS).status_code == 404


def test_screenshot_task_upload_lands_in_collected(client):
    agent_id = _register(client)["agent_id"]
    tid = insert_task(agent_id, task_type="screenshot")
    r = client.post(f"/api/files/{tid}",
                    files={"file": ("shot.png", b"\x89PNGfake")},
                    headers=AGENT_HEADERS)
    assert r.status_code == 200 and r.json()["ok"] is True
    dest = COLLECTED_DIR / r.json()["saved"]
    try:
        assert dest.read_bytes().startswith(b"\x89PNG")
    finally:
        dest.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Builder / generate surface
# ---------------------------------------------------------------------------


def _login(client) -> None:
    client.post("/login", data={"username": "admin", "password": "testpass"},
                follow_redirects=False)


def test_oneliner_for_compiled_language(client):
    _login(client)
    r = client.get("/api/download/agent/rust/oneliner")
    assert r.status_code == 200
    body = r.json()
    assert body["language"] == "rust"
    assert "irm" in body["oneliner"] and "iex" in body["oneliner"]
    assert "installer.ps1" in body["oneliner"]
    assert body["installer"].endswith("/agent/rust/installer.ps1")
    assert client.get("/api/download/agent/rust/oneliner",
                      params={"format": "raw"}).status_code == 200


def test_agent_source_requires_auth(client):
    client.cookies.clear()
    assert client.get("/download/agent/rust").status_code == 401
    r = client.get("/download/agent/rust", params={"token": "test-agent-token"})
    assert r.status_code == 200
    assert r.content.startswith(b"//")
    r = client.get("/download/agent/does-not-exist",
                   params={"token": "test-agent-token"})
    assert r.status_code == 404


def test_installer_endpoints_serve_valid_scripts(client):
    # token-authed installer generation works for compiled languages
    for lang in ("rust", "csharp"):
        r = client.get(f"/download/agent/{lang}/installer",
                       params={"token": "test-agent-token"})
        assert r.status_code == 200, (lang, r.status_code)
        assert r.headers["X-Installer"] == "bash"
        assert "--server" in r.text and "--interval" in r.text
        assert r.text.splitlines()[0].startswith("#!")
    # clean /agent/{lang}/installer.* URLs stay 404 until a Build Agent run
    # baked the script (no unauthenticated on-demand fallback → no token leak)
    assert client.get("/agent/rust/installer.sh").status_code == 404
    assert client.get("/agent/rust/installer.ps1").status_code == 404


def test_server_info_exposes_platform(client):
    _login(client)
    r = client.get("/api/server-info")
    assert r.status_code == 200
    body = r.json()
    assert body["host"].startswith("http")
    assert body["platform"] in ("win32", "linux", "darwin")