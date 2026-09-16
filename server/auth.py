"""Dashboard authentication: PBKDF2 password hashing + server-side sessions."""
import hashlib
import hmac
import os
import secrets
import time

from database import get_conn, utcnow

# Cookie names are port-scoped so multiple server instances (Windows 8000,
# Linux/WSL 8001) running on the same host (127.0.0.1) in one browser do not
# overwrite each other's session cookie.
_COOKIE_PORT = os.environ.get("WYM_PORT", "8000")
COOKIE_NAME = f"wym_session_{_COOKIE_PORT}"
CSRF_COOKIE_NAME = f"wym_csrf_{_COOKIE_PORT}"
SESSION_TTL = 8 * 3600  # 8 hours

_iterations = 200_000

# CSRF secret — persisted to a file so the dashboard's CSRF tokens survive
# server restarts (otherwise every form opened before a restart fails with
# 403 invalid CSRF token until the page is reloaded).
_CSRF_SECRET_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".csrf_secret")


def _load_csrf_secret() -> str:
    try:
        if os.path.exists(_CSRF_SECRET_FILE):
            val = open(_CSRF_SECRET_FILE, encoding="utf-8").read().strip()
            if val:
                return val
    except OSError:
        pass
    secret = secrets.token_hex(32)
    try:
        with open(_CSRF_SECRET_FILE, "w", encoding="utf-8") as fh:
            fh.write(secret)
    except OSError:
        pass
    return secret


_csrf_secret = _load_csrf_secret()


def generate_csrf_token(session_token: str) -> str:
    """Generate a CSRF token bound to the user's session."""
    return hmac.new(_csrf_secret.encode(), session_token.encode(), "sha256").hexdigest()


def verify_csrf_token(session_token: str, csrf_token: str) -> bool:
    """Verify a CSRF token matches the session."""
    expected = generate_csrf_token(session_token)
    return hmac.compare_digest(expected, csrf_token)


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("ascii"), _iterations
    ).hex()
    return f"pbkdf2_sha256${salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, salt, digest = stored.split("$")
        if scheme != "pbkdf2_sha256":
            return False
        candidate = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt.encode("ascii"), _iterations
        ).hex()
        return secrets.compare_digest(candidate, digest)
    except (ValueError, AttributeError):
        return False


def sync_default_user(username: str, password: str = "") -> tuple[bool, str]:
    """Create the bootstrap dashboard user, and if `password` is non-empty,
    (re)set it on every startup so a reinstall with WYM_PASSWORD always logs in
    with that password (never a stale/random one).

    Returns (created_or_updated, effective_password).
    """
    conn = get_conn()
    try:
        row = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
        if row is None:
            password = password or secrets.token_urlsafe(16)
            conn.execute(
                "INSERT INTO users (username, password_hash, created_at, is_admin) VALUES (?, ?, ?, 1)",
                (username, hash_password(password), utcnow()),
            )
            conn.commit()
            return True, password
        if password:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (hash_password(password), row["id"]),
            )
            conn.commit()
            return True, password
        return False, ""
    finally:
        conn.close()


def authenticate(username: str, password: str) -> bool:
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT password_hash FROM users WHERE username = ?", (username,)
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        # burn the same PBKDF2 cost so user enumeration via timing is not feasible
        hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), b"wym-salt", _iterations
        )
        return False
    return verify_password(password, row["password_hash"])


def is_admin(username: str) -> bool:
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT is_admin FROM users WHERE username = ?", (username,)
        ).fetchone()
        return bool(row and row["is_admin"])
    finally:
        conn.close()


def touch_user(username: str) -> None:
    """Update the user's last-seen/activity timestamp."""
    conn = get_conn()
    try:
        conn.execute(
            "UPDATE users SET last_seen = COALESCE(?, last_seen) WHERE username = ?",
            (utcnow(), username),
        )
        conn.commit()
    finally:
        conn.close()


def create_session(username: str) -> str:
    token = secrets.token_urlsafe(32)
    expires_at = time.time() + SESSION_TTL
    conn = get_conn()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO sessions (token, username, expires_at) VALUES (?, ?, ?)",
            (token, username, expires_at),
        )
        conn.commit()
    finally:
        conn.close()
    return token


def get_session_user(token: str) -> str | None:
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT username, expires_at FROM sessions WHERE token = ?", (token,)
        ).fetchone()
        if row is None:
            return None
        if time.time() > row["expires_at"]:
            conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
            conn.commit()
            return None
        return row["username"]
    finally:
        conn.close()


def destroy_session(token: str) -> None:
    conn = get_conn()
    try:
        conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
        conn.commit()
    finally:
        conn.close()


def change_password(username: str, new_password: str, keep_token: str = "") -> None:
    conn = get_conn()
    try:
        conn.execute(
            "UPDATE users SET password_hash = ? WHERE username = ?",
            (hash_password(new_password), username),
        )
        # invalidate other active sessions; keep the current one
        if keep_token:
            conn.execute(
                "DELETE FROM sessions WHERE username = ? AND token <> ?",
                (username, keep_token),
            )
        else:
            conn.execute("DELETE FROM sessions WHERE username = ?", (username,))
        conn.commit()
    finally:
        conn.close()


def cleanup_expired_sessions() -> int:
    """Remove expired sessions. Returns count of deleted rows."""
    conn = get_conn()
    try:
        cur = conn.execute(
            "DELETE FROM sessions WHERE expires_at < ?", (time.time(),)
        )
        conn.commit()
        return cur.rowcount
    finally:
        conn.close()


def create_user(username: str, password: str) -> tuple[bool, str]:
    """Create a new dashboard user. Returns (ok, error_message)."""
    if not username or not password:
        return False, "Username and password required"
    if len(username) < 2:
        return False, "Username must be at least 2 characters"
    if len(password) < 8:
        return False, "Password must be at least 8 characters"
    conn = get_conn()
    try:
        row = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
        if row is not None:
            return False, "Username already exists"
        conn.execute(
            "INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?)",
            (username, hash_password(password), utcnow()),
        )
        conn.commit()
        return True, ""
    finally:
        conn.close()


def delete_user(username: str) -> bool:
    """Delete a user. Cannot delete the last admin."""
    conn = get_conn()
    try:
        count = conn.execute("SELECT COUNT(*) as c FROM users").fetchone()["c"]
        if count <= 1:
            return False
        cur = conn.execute("DELETE FROM users WHERE username = ?", (username,))
        conn.commit()
        if cur.rowcount > 0:
            conn.execute("DELETE FROM sessions WHERE username = ?", (username,))
            conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def list_users() -> list[dict]:
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT id, username, created_at, last_seen FROM users ORDER BY id"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()
