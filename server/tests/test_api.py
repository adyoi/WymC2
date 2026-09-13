"""Agent API + auth tests for the Wym C2 server."""
import os
from datetime import datetime, timedelta, timezone

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
    assert os.environ["C2_AGENT_TOKEN"] == "test-agent-token"