#include "fw_telnet_server.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include "esp_log.h"
#include "esp_system.h"

#include "fw_led_output.h"
#include "generated/dsl_shader_registry.h"

static const char *TAG = "fw_telnet";

#define TELNET_LINE_MAX    256
#define TELNET_OUT_MAX     512
#define TELNET_CWD_MAX     64
#define TELNET_TASK_STACK  6144
#define TELNET_TASK_PRIO   3

/* --- Log ring buffer ----------------------------------------------------- */

#define LOG_RINGBUF_SIZE   8192

static char s_log_ringbuf[LOG_RINGBUF_SIZE];
static size_t s_log_head = 0;   // next write position
static size_t s_log_count = 0;  // bytes stored (max LOG_RINGBUF_SIZE)
static SemaphoreHandle_t s_log_mutex = NULL;
static vprintf_like_t s_orig_vprintf = NULL;

// Custom vprintf: writes to ring buffer AND original UART output.
static int log_ringbuf_vprintf(const char *fmt, va_list args) {
    // Format into a stack buffer
    char buf[256];
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    if (len <= 0) {
        return s_orig_vprintf ? s_orig_vprintf(fmt, args) : len;
    }
    if ((size_t)len >= sizeof(buf)) len = (int)(sizeof(buf) - 1);

    // Write to ring buffer under lock
    if (s_log_mutex != NULL && xSemaphoreTake(s_log_mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
        for (int i = 0; i < len; i++) {
            s_log_ringbuf[s_log_head] = buf[i];
            s_log_head = (s_log_head + 1) % LOG_RINGBUF_SIZE;
        }
        if (s_log_count + (size_t)len > LOG_RINGBUF_SIZE) {
            s_log_count = LOG_RINGBUF_SIZE;
        } else {
            s_log_count += (size_t)len;
        }
        xSemaphoreGive(s_log_mutex);
    }

    // Forward to original UART output
    if (s_orig_vprintf != NULL) {
        // Re-print the already-formatted string to UART.
        // Use fputs since we already formatted.
        fwrite(buf, 1, (size_t)len, stdout);
        return len;
    }
    return len;
}

// Read current ring buffer contents into dst. Returns bytes written.
// read_pos tracks where this reader left off (set to s_head on first call).
static size_t log_ringbuf_read(char *dst, size_t dst_size, size_t *read_pos, bool *first_call) {
    if (s_log_mutex == NULL) return 0;
    if (xSemaphoreTake(s_log_mutex, pdMS_TO_TICKS(50)) != pdTRUE) return 0;

    size_t head = s_log_head;
    size_t count = s_log_count;
    size_t written = 0;

    if (*first_call) {
        // On first call, dump entire buffer contents
        *first_call = false;
        if (count > 0) {
            size_t start = (head + LOG_RINGBUF_SIZE - count) % LOG_RINGBUF_SIZE;
            size_t to_read = count < dst_size ? count : dst_size;
            for (size_t i = 0; i < to_read; i++) {
                dst[written++] = s_log_ringbuf[(start + i) % LOG_RINGBUF_SIZE];
            }
        }
        *read_pos = head;
    } else {
        // Subsequent calls: read from read_pos to head
        size_t rp = *read_pos;
        size_t avail = (head + LOG_RINGBUF_SIZE - rp) % LOG_RINGBUF_SIZE;
        if (head == rp) avail = 0; // nothing new
        size_t to_read = avail < dst_size ? avail : dst_size;
        for (size_t i = 0; i < to_read; i++) {
            dst[written++] = s_log_ringbuf[(rp + i) % LOG_RINGBUF_SIZE];
        }
        *read_pos = (rp + to_read) % LOG_RINGBUF_SIZE;
    }

    xSemaphoreGive(s_log_mutex);
    return written;
}

static void log_ringbuf_init(void) {
    if (s_log_mutex != NULL) return; // already initialized
    s_log_mutex = xSemaphoreCreateMutex();
    s_orig_vprintf = esp_log_set_vprintf(log_ringbuf_vprintf);
}

void fw_telnet_log_init(void) {
    log_ringbuf_init();
}

/* --- Telnet negotiation sequences ---------------------------------------- */

// IAC WILL ECHO
static const uint8_t telnet_will_echo[] = { 255, 251, 1 };
// IAC WILL SUPPRESS-GO-AHEAD
static const uint8_t telnet_will_sga[] = { 255, 251, 3 };
// IAC DO SUPPRESS-GO-AHEAD
static const uint8_t telnet_do_sga[] = { 255, 253, 3 };
// IAC WONT LINEMODE
static const uint8_t telnet_wont_linemode[] = { 255, 252, 34 };

/* --- Task context -------------------------------------------------------- */

typedef struct {
    uint16_t port;
    fw_tcp_server_state_t *state;
} telnet_task_ctx_t;

static telnet_task_ctx_t s_ctx;

/* --- Helpers ------------------------------------------------------------- */

static bool telnet_send(int sock, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(sock, p + sent, len - sent, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

static bool telnet_send_str(int sock, const char *s) {
    return telnet_send(sock, s, strlen(s));
}

static void telnet_send_prompt(int sock, const char *cwd) {
    char buf[TELNET_OUT_MAX];
    int n = snprintf(buf, sizeof(buf), "led-pillar:%s> ", cwd);
    if (n > 0) telnet_send(sock, buf, (size_t)n);
}

/* --- Virtual filesystem -------------------------------------------------- */

/// Check if a path is a valid directory in the virtual FS.
/// Valid directories: "/" and any unique folder from the shader registry.
static bool vfs_is_dir(const char *path) {
    if (strcmp(path, "/") == 0) return true;
    size_t plen = strlen(path);
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        const char *f = dsl_shader_registry[i].folder;
        // Exact match (leaf directory) or prefix match (intermediate directory)
        if (strcmp(f, path) == 0) return true;
        if (strncmp(f, path, plen) == 0 && f[plen] == '/') return true;
    }
    return false;
}

/// Resolve a path relative to cwd. Result written to out (size TELNET_CWD_MAX).
/// Returns true if the resolved path is a valid directory.
static bool vfs_resolve(const char *cwd, const char *path, char *out, size_t out_len) {
    char tmp[TELNET_CWD_MAX];

    if (path[0] == '/') {
        // Absolute path
        strlcpy(tmp, path, sizeof(tmp));
    } else {
        // Relative path — build from cwd
        if (strcmp(cwd, "/") == 0) {
            snprintf(tmp, sizeof(tmp), "/%s", path);
        } else {
            snprintf(tmp, sizeof(tmp), "%s/%s", cwd, path);
        }
    }

    // Normalize: resolve . and ..
    char normalized[TELNET_CWD_MAX];
    // Tokenize by '/' and rebuild
    char *parts[16];
    int depth = 0;
    char work[TELNET_CWD_MAX];
    strlcpy(work, tmp, sizeof(work));
    char *saveptr = NULL;
    char *tok = strtok_r(work, "/", &saveptr);
    while (tok != NULL) {
        if (strcmp(tok, ".") == 0) {
            // skip
        } else if (strcmp(tok, "..") == 0) {
            if (depth > 0) depth--;
        } else {
            if (depth < 16) {
                parts[depth++] = tok;
            }
        }
        tok = strtok_r(NULL, "/", &saveptr);
    }

    if (depth == 0) {
        strlcpy(normalized, "/", sizeof(normalized));
    } else {
        normalized[0] = '\0';
        for (int i = 0; i < depth; i++) {
            strlcat(normalized, "/", sizeof(normalized));
            strlcat(normalized, parts[i], sizeof(normalized));
        }
    }

    // Remove trailing slash (unless root)
    size_t nlen = strlen(normalized);
    if (nlen > 1 && normalized[nlen - 1] == '/') {
        normalized[nlen - 1] = '\0';
    }

    strlcpy(out, normalized, out_len);
    return vfs_is_dir(out);
}

/// Check if a shader name exists in the given directory.
static const dsl_shader_entry_t *vfs_find_shader(const char *dir, const char *name) {
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        if (strcmp(dsl_shader_registry[i].folder, dir) == 0 &&
            strcmp(dsl_shader_registry[i].name, name) == 0) {
            return &dsl_shader_registry[i];
        }
    }
    return NULL;
}

/* --- Tab completion ------------------------------------------------------ */

/// Count command/entry matches for prefix; store last single match in out_match.
/// When multiple matches exist, out_match contains their longest common prefix.
static int tab_complete_entries(const char *cwd, const char *prefix, bool dirs_only,
                                char *out_match, size_t out_match_len) {
    int count = 0;
    out_match[0] = '\0';

    if (!dirs_only) {
        // Match shader names in cwd
        for (int i = 0; i < dsl_shader_registry_count; i++) {
            if (strcmp(dsl_shader_registry[i].folder, cwd) != 0) continue;
            if (strncmp(dsl_shader_registry[i].name, prefix, strlen(prefix)) == 0) {
                count++;
                if (count == 1) {
                    strlcpy(out_match, dsl_shader_registry[i].name, out_match_len);
                } else {
                    // Shrink out_match to LCP with this match
                    const char *m = dsl_shader_registry[i].name;
                    size_t j = 0;
                    while (out_match[j] && m[j] && out_match[j] == m[j]) j++;
                    out_match[j] = '\0';
                }
            }
        }
    }

    // Match subdirectory names visible from cwd
    // A subdirectory is a folder that starts with cwd + "/" and has exactly one more component
    size_t cwd_len = strlen(cwd);
    char seen[32][32];
    int seen_count = 0;
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        const char *folder = dsl_shader_registry[i].folder;
        size_t folder_len = strlen(folder);
        const char *child_name = NULL;

        if (strcmp(cwd, "/") == 0) {
            // Children of root: first component after leading /
            if (folder_len <= 1) continue;
            child_name = folder + 1;
            // Only take the first path component
            const char *slash = strchr(child_name, '/');
            // Build a temp name
            static char subdir_name[TELNET_CWD_MAX];
            if (slash) {
                size_t len = (size_t)(slash - child_name);
                if (len >= sizeof(subdir_name)) len = sizeof(subdir_name) - 1;
                memcpy(subdir_name, child_name, len);
                subdir_name[len] = '\0';
            } else {
                strlcpy(subdir_name, child_name, sizeof(subdir_name));
            }
            child_name = subdir_name;
        } else {
            // Children of cwd: folder starts with "cwd/" and has content after
            if (folder_len <= cwd_len + 1) continue;
            if (strncmp(folder, cwd, cwd_len) != 0) continue;
            if (folder[cwd_len] != '/') continue;
            child_name = folder + cwd_len + 1;
            // Only first component
            static char subdir_name2[TELNET_CWD_MAX];
            const char *slash = strchr(child_name, '/');
            if (slash) {
                size_t len = (size_t)(slash - child_name);
                if (len >= sizeof(subdir_name2)) len = sizeof(subdir_name2) - 1;
                memcpy(subdir_name2, child_name, len);
                subdir_name2[len] = '\0';
            } else {
                strlcpy(subdir_name2, child_name, sizeof(subdir_name2));
            }
            child_name = subdir_name2;
        }

        if (strncmp(child_name, prefix, strlen(prefix)) != 0) continue;

        // Deduplicate
        bool dup = false;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen[s], child_name) == 0) { dup = true; break; }
        }
        if (dup) continue;
        if (seen_count < 32) strlcpy(seen[seen_count++], child_name, 32);

        count++;
        if (count == 1) {
            strlcpy(out_match, child_name, out_match_len);
        } else {
            // Shrink out_match to LCP with this match
            size_t j = 0;
            while (out_match[j] && child_name[j] && out_match[j] == child_name[j]) j++;
            out_match[j] = '\0';
        }
    }

    return count;
}

static void tab_print_matches(int sock, const char *cwd, const char *prefix, bool dirs_only) {
    telnet_send_str(sock, "\r\n");

    if (!dirs_only) {
        for (int i = 0; i < dsl_shader_registry_count; i++) {
            if (strcmp(dsl_shader_registry[i].folder, cwd) != 0) continue;
            if (strncmp(dsl_shader_registry[i].name, prefix, strlen(prefix)) == 0) {
                telnet_send_str(sock, dsl_shader_registry[i].name);
                telnet_send_str(sock, "\r\n");
            }
        }
    }

    // Subdirectories (same logic as above, deduplicated)
    size_t cwd_len = strlen(cwd);
    char seen[32][32];
    int seen_count = 0;
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        const char *folder = dsl_shader_registry[i].folder;
        size_t folder_len = strlen(folder);
        char subdir_buf[TELNET_CWD_MAX];
        const char *child_name = NULL;

        if (strcmp(cwd, "/") == 0) {
            if (folder_len <= 1) continue;
            const char *start = folder + 1;
            const char *slash = strchr(start, '/');
            if (slash) {
                size_t len = (size_t)(slash - start);
                if (len >= sizeof(subdir_buf)) len = sizeof(subdir_buf) - 1;
                memcpy(subdir_buf, start, len);
                subdir_buf[len] = '\0';
            } else {
                strlcpy(subdir_buf, start, sizeof(subdir_buf));
            }
            child_name = subdir_buf;
        } else {
            if (folder_len <= cwd_len + 1) continue;
            if (strncmp(folder, cwd, cwd_len) != 0 || folder[cwd_len] != '/') continue;
            const char *start = folder + cwd_len + 1;
            const char *slash = strchr(start, '/');
            if (slash) {
                size_t len = (size_t)(slash - start);
                if (len >= sizeof(subdir_buf)) len = sizeof(subdir_buf) - 1;
                memcpy(subdir_buf, start, len);
                subdir_buf[len] = '\0';
            } else {
                strlcpy(subdir_buf, start, sizeof(subdir_buf));
            }
            child_name = subdir_buf;
        }

        if (strncmp(child_name, prefix, strlen(prefix)) != 0) continue;

        bool dup = false;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen[s], child_name) == 0) { dup = true; break; }
        }
        if (dup) continue;
        if (seen_count < 32) strlcpy(seen[seen_count++], child_name, 32);

        telnet_send_str(sock, child_name);
        telnet_send_str(sock, "/\r\n");
    }
}

static const char *cmd_names[] = { "ls", "cd", "pwd", "run", "stop", "top", "log", "help", "exit", NULL };

static void handle_tab(int sock, char *line, size_t *line_len, const char *cwd) {
    // Determine what we're completing
    char *space = strchr(line, ' ');
    if (space == NULL) {
        // Completing a command name
        const char *prefix = line;
        size_t prefix_len = strlen(prefix);
        int count = 0;
        const char *match = NULL;
        for (int i = 0; cmd_names[i] != NULL; i++) {
            if (strncmp(cmd_names[i], prefix, prefix_len) == 0) {
                count++;
                match = cmd_names[i];
            }
        }
        if (count == 1) {
            // Complete the command and add a space
            const char *suffix = match + prefix_len;
            size_t suffix_len = strlen(suffix);
            if (*line_len + suffix_len + 1 < TELNET_LINE_MAX) {
                memcpy(line + *line_len, suffix, suffix_len);
                *line_len += suffix_len;
                line[*line_len] = ' ';
                (*line_len)++;
                line[*line_len] = '\0';
                // Echo suffix + space
                char echo_buf[TELNET_LINE_MAX];
                memcpy(echo_buf, suffix, suffix_len);
                echo_buf[suffix_len] = ' ';
                telnet_send(sock, echo_buf, suffix_len + 1);
            }
        } else if (count > 1) {
            // Print all matches
            telnet_send_str(sock, "\r\n");
            for (int i = 0; cmd_names[i] != NULL; i++) {
                if (strncmp(cmd_names[i], prefix, prefix_len) == 0) {
                    telnet_send_str(sock, cmd_names[i]);
                    telnet_send_str(sock, "\r\n");
                }
            }
            telnet_send_prompt(sock, cwd);
            telnet_send(sock, line, *line_len);
        }
    } else {
        // Completing an argument
        char cmd[32];
        size_t cmd_len = (size_t)(space - line);
        if (cmd_len >= sizeof(cmd)) cmd_len = sizeof(cmd) - 1;
        memcpy(cmd, line, cmd_len);
        cmd[cmd_len] = '\0';

        const char *arg = space + 1;
        bool dirs_only = (strcmp(cmd, "cd") == 0);

        // Only complete for run and cd
        if (strcmp(cmd, "run") != 0 && strcmp(cmd, "cd") != 0) return;

        // Split arg into dir_prefix and name_prefix at last '/'
        // e.g. "../en" -> dir_prefix="../", name_prefix="en"
        //      "foo"   -> dir_prefix="",    name_prefix="foo"
        const char *last_slash = strrchr(arg, '/');
        char resolve_dir[TELNET_CWD_MAX];
        const char *name_prefix;

        if (last_slash != NULL) {
            // Has path component — resolve directory part relative to cwd
            char dir_part[TELNET_CWD_MAX];
            size_t dp_len = (size_t)(last_slash - arg);
            if (dp_len >= sizeof(dir_part)) dp_len = sizeof(dir_part) - 1;
            memcpy(dir_part, arg, dp_len);
            dir_part[dp_len] = '\0';

            if (!vfs_resolve(cwd, dir_part, resolve_dir, sizeof(resolve_dir))) {
                return; // Invalid directory path, no completions
            }
            name_prefix = last_slash + 1;
        } else {
            strlcpy(resolve_dir, cwd, sizeof(resolve_dir));
            name_prefix = arg;
        }

        char match_buf[TELNET_CWD_MAX];
        int count = tab_complete_entries(resolve_dir, name_prefix, dirs_only, match_buf, sizeof(match_buf));

        if (count == 1) {
            // Build full completion: dir_prefix + match (only append the suffix the user hasn't typed)
            const char *suffix = match_buf + strlen(name_prefix);
            size_t suffix_len = strlen(suffix);
            if (*line_len + suffix_len + 1 < TELNET_LINE_MAX) {
                memcpy(line + *line_len, suffix, suffix_len);
                *line_len += suffix_len;
                line[*line_len] = '\0';
                telnet_send(sock, suffix, suffix_len);
            }
        } else if (count > 1) {
            // Expand to longest common prefix before listing matches
            size_t lcp_len = strlen(match_buf);
            size_t prefix_len = strlen(name_prefix);
            if (lcp_len > prefix_len) {
                const char *suffix = match_buf + prefix_len;
                size_t suffix_len = lcp_len - prefix_len;
                if (*line_len + suffix_len < TELNET_LINE_MAX) {
                    memcpy(line + *line_len, suffix, suffix_len);
                    *line_len += suffix_len;
                    line[*line_len] = '\0';
                    telnet_send(sock, suffix, suffix_len);
                }
            }
            tab_print_matches(sock, resolve_dir, name_prefix, dirs_only);
            telnet_send_prompt(sock, cwd);
            telnet_send(sock, line, *line_len);
        }
    }
}

/* --- Shell commands ------------------------------------------------------- */

static void cmd_help(int sock) {
    telnet_send_str(sock,
        "Available commands:\r\n"
        "  ls              List shaders in current directory\r\n"
        "  cd <path>       Change directory\r\n"
        "  pwd             Print working directory\r\n"
        "  run <name>      Run a shader by name\r\n"
        "  stop            Stop the running shader\r\n"
        "  top             Show shader status (live, any key exits)\r\n"
        "  log             Tail ESP32 log output (any key exits)\r\n"
        "  help            Show this help\r\n"
        "  exit            Disconnect (or Ctrl+D)\r\n");
}

static void cmd_pwd(int sock, const char *cwd) {
    telnet_send_str(sock, cwd);
    telnet_send_str(sock, "\r\n");
}

static void cmd_ls(int sock, const char *cwd) {
    char out[TELNET_OUT_MAX];
    bool any = false;

    // List subdirectories visible from cwd
    size_t cwd_len = strlen(cwd);
    char seen[32][32];
    int seen_count = 0;

    for (int i = 0; i < dsl_shader_registry_count; i++) {
        const char *folder = dsl_shader_registry[i].folder;
        size_t folder_len = strlen(folder);
        char subdir_buf[TELNET_CWD_MAX];
        const char *child_name = NULL;

        if (strcmp(cwd, "/") == 0) {
            if (folder_len <= 1) continue;
            const char *start = folder + 1;
            const char *slash = strchr(start, '/');
            if (slash) {
                size_t len = (size_t)(slash - start);
                if (len >= sizeof(subdir_buf)) len = sizeof(subdir_buf) - 1;
                memcpy(subdir_buf, start, len);
                subdir_buf[len] = '\0';
            } else {
                strlcpy(subdir_buf, start, sizeof(subdir_buf));
            }
            child_name = subdir_buf;
        } else {
            if (folder_len <= cwd_len + 1) continue;
            if (strncmp(folder, cwd, cwd_len) != 0 || folder[cwd_len] != '/') continue;
            const char *start = folder + cwd_len + 1;
            const char *slash = strchr(start, '/');
            if (slash) {
                size_t len = (size_t)(slash - start);
                if (len >= sizeof(subdir_buf)) len = sizeof(subdir_buf) - 1;
                memcpy(subdir_buf, start, len);
                subdir_buf[len] = '\0';
            } else {
                strlcpy(subdir_buf, start, sizeof(subdir_buf));
            }
            child_name = subdir_buf;
        }

        // Deduplicate
        bool dup = false;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen[s], child_name) == 0) { dup = true; break; }
        }
        if (dup) continue;
        if (seen_count < 32) strlcpy(seen[seen_count++], child_name, 32);

        int n = snprintf(out, sizeof(out), "%-25s [dir]\r\n", child_name);
        if (n > 0) telnet_send(sock, out, (size_t)n);
        any = true;
    }

    // List shaders in cwd
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        if (strcmp(dsl_shader_registry[i].folder, cwd) != 0) continue;
        const char *frame_flag = dsl_shader_registry[i].has_frame_func ? " [frame]" : "";
        const char *audio_flag = dsl_shader_registry[i].has_audio_func ? " [audio]" : "";
        int n = snprintf(out, sizeof(out), "%-25s [native]%s%s\r\n", dsl_shader_registry[i].name, frame_flag, audio_flag);
        if (n > 0) telnet_send(sock, out, (size_t)n);
        any = true;
    }

    if (!any) {
        telnet_send_str(sock, "(empty)\r\n");
    }
}

static void cmd_cd(int sock, const char *cwd, const char *arg, char *cwd_out) {
    if (arg == NULL || arg[0] == '\0') {
        strlcpy(cwd_out, "/", TELNET_CWD_MAX);
        return;
    }

    char resolved[TELNET_CWD_MAX];
    if (vfs_resolve(cwd, arg, resolved, sizeof(resolved))) {
        strlcpy(cwd_out, resolved, TELNET_CWD_MAX);
    } else {
        char out[TELNET_OUT_MAX];
        int n = snprintf(out, sizeof(out), "cd: no such directory: %s\r\n", arg);
        if (n > 0) telnet_send(sock, out, (size_t)n);
    }
}

static void cmd_run(int sock, fw_tcp_server_state_t *state, const char *cwd, const char *name) {
    if (name == NULL || name[0] == '\0') {
        telnet_send_str(sock, "Usage: run <shader-name>\r\n");
        return;
    }

    const dsl_shader_entry_t *entry = NULL;

    // If name contains '/', treat as path: split into folder + shader name
    const char *last_slash = strrchr(name, '/');
    if (last_slash != NULL) {
        char folder[TELNET_CWD_MAX];
        size_t dir_len = (size_t)(last_slash - name);
        if (dir_len == 0) {
            strlcpy(folder, "/", sizeof(folder));
        } else if (name[0] == '/') {
            // Absolute path
            if (dir_len >= sizeof(folder)) dir_len = sizeof(folder) - 1;
            memcpy(folder, name, dir_len);
            folder[dir_len] = '\0';
        } else {
            // Relative path — resolve against cwd
            char dir_part[TELNET_CWD_MAX];
            if (dir_len >= sizeof(dir_part)) dir_len = sizeof(dir_part) - 1;
            memcpy(dir_part, name, dir_len);
            dir_part[dir_len] = '\0';
            if (!vfs_resolve(cwd, dir_part, folder, sizeof(folder))) {
                char out[TELNET_OUT_MAX];
                int n = snprintf(out, sizeof(out), "run: invalid path: %s\r\n", name);
                if (n > 0) telnet_send(sock, out, (size_t)n);
                return;
            }
        }
        entry = vfs_find_shader(folder, last_slash + 1);
    } else {
        entry = vfs_find_shader(cwd, name);
    }

    if (entry == NULL) {
        // Fallback: lookup by name alone (ignore path)
        const char *bare_name = last_slash ? last_slash + 1 : name;
        entry = dsl_shader_find(bare_name);
    }
    if (entry == NULL) {
        char out[TELNET_OUT_MAX];
        int n = snprintf(out, sizeof(out), "run: shader not found: %s\r\n", name);
        if (n > 0) telnet_send(sock, out, (size_t)n);
        return;
    }

    xSemaphoreTake(state->state_lock, portMAX_DELAY);
    state->shader_active = true;
    state->shader_source = FW_TCP_SHADER_SOURCE_NATIVE;
    state->active_native_shader = entry;
    state->native_shader_seed = (float)(esp_random() >> 8) / 16777216.0f;
    state->shader_frame_count = 0;
    state->shader_slow_frame_count = 0;
    state->measured_fps = 0.0f;
    xSemaphoreGive(state->state_lock);

    char out[TELNET_OUT_MAX];
    int n = snprintf(out, sizeof(out), "Running: %s\r\n", entry->name);
    if (n > 0) telnet_send(sock, out, (size_t)n);
}

static void cmd_stop(int sock, fw_tcp_server_state_t *state) {
    xSemaphoreTake(state->state_lock, portMAX_DELAY);
    state->shader_active = false;
    state->active_native_shader = NULL;
    xSemaphoreGive(state->state_lock);

    fw_led_output_push_uniform_rgb(&state->led_output, 0, 0, 0);
    telnet_send_str(sock, "Shader stopped.\r\n");
}

static bool telnet_key_available(int sock) {
    while (true) {
        struct timeval tv = { .tv_sec = 0, .tv_usec = 0 };
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(sock, &fds);
        int ret = select(sock + 1, &fds, NULL, NULL, &tv);
        if (ret <= 0) return false;

        // Peek at next byte — skip IAC and ESC sequences
        uint8_t peek;
        int n = recv(sock, &peek, 1, MSG_PEEK);
        if (n <= 0) return false;

        if (peek == 255) {
            // Consume IAC sequence so it doesn't trigger false keypress
            recv(sock, &peek, 1, 0);
            uint8_t cmd;
            if (recv(sock, &cmd, 1, 0) <= 0) return false;
            if (cmd >= 251 && cmd <= 254) {
                uint8_t opt;
                if (recv(sock, &opt, 1, 0) <= 0) return false;
            }
            if (cmd == 250) {
                uint8_t sb;
                while (recv(sock, &sb, 1, 0) > 0) {
                    if (sb == 255) {
                        uint8_t se;
                        if (recv(sock, &se, 1, 0) <= 0) break;
                        if (se == 240) break;
                    }
                }
            }
            continue; // Check again for real data
        }

        if (peek == 0x1B) {
            // Consume ANSI escape sequence (ESC [ ... final_byte)
            recv(sock, &peek, 1, 0); // consume ESC
            uint8_t next;
            if (recv(sock, &next, 1, MSG_DONTWAIT) > 0) {
                if (next == '[') {
                    // CSI sequence: consume until 0x40-0x7E (final byte)
                    uint8_t csi;
                    while (recv(sock, &csi, 1, MSG_DONTWAIT) > 0) {
                        if (csi >= 0x40 && csi <= 0x7E) break;
                    }
                }
                // Otherwise single ESC+char — consumed
            }
            continue; // Check again for real data
        }

        return true; // Non-IAC, non-ESC data available
    }
}

// Drain any pending telnet negotiation/escape data with a brief grace period.
// Call before entering top/log loops to let slow clients finish negotiating.
static void telnet_drain_pending(int sock) {
    for (int i = 0; i < 5; i++) {
        vTaskDelay(pdMS_TO_TICKS(100));
        // Drain all IAC/ESC sequences and any stale bytes
        while (telnet_key_available(sock)) {
            uint8_t drain[32];
            recv(sock, drain, sizeof(drain), MSG_DONTWAIT);
        }
    }
}

static void cmd_top(int sock, fw_tcp_server_state_t *state) {
    char out[TELNET_OUT_MAX];

    telnet_drain_pending(sock);

    while (true) {
        const char *name = "(none)";
        const char *status = "stopped";
        uint32_t frames = 0;
        uint32_t slow = 0;
        float fps = 0.0f;
        bool has_audio = false;
        float display_us = 0.0f;
        float audio_us = 0.0f;
        uint32_t target_fps = 0;

        xSemaphoreTake(state->state_lock, portMAX_DELAY);
        if (state->shader_active && state->active_native_shader != NULL) {
            name = state->active_native_shader->name;
            status = "running";
            has_audio = state->active_native_shader->has_audio_func != 0;
        }
        frames = state->shader_frame_count;
        slow = state->shader_slow_frame_count;
        fps = state->measured_fps;
        display_us = state->render_time_display_us;
        audio_us = state->render_time_audio_us;
        target_fps = state->target_fps;
        xSemaphoreGive(state->state_lock);

        uint32_t free_heap = esp_get_free_heap_size();

        /* Compute render budget */
        float display_ms = display_us / 1000.0f;
        float audio_ms = audio_us / 1000.0f;
        float combined_ms = display_ms + audio_ms;
        float target_frame_ms = target_fps > 0 ? 1000.0f / (float)target_fps : 0.0f;
        float percent = target_frame_ms > 0.0f ? combined_ms / target_frame_ms * 100.0f : 0.0f;

        /* Clear screen and home cursor */
        telnet_send_str(sock, "\033[2J\033[H");

        int n = snprintf(out, sizeof(out),
            "Shader:      %s\r\n"
            "Status:      %s\r\n"
            "FPS:         %.1f\r\n"
            "Frames:      %" PRIu32 "\r\n"
            "Slow frames: %" PRIu32 "\r\n"
            "Audio:       %s\r\n"
            "Render:      %.1f ms display + %.1f ms audio = %.1f ms (%.1f%% of %.1f ms)\r\n"
            "Free heap:   %" PRIu32 "\r\n"
            "\r\n"
            "Press any key to exit...\r\n",
            name, status, (double)fps, frames, slow,
            has_audio ? "active" : "none",
            (double)display_ms, (double)audio_ms, (double)combined_ms,
            (double)percent, (double)target_frame_ms,
            free_heap);
        if (n > 0 && !telnet_send(sock, out, (size_t)n)) break;

        /* Wait ~1 second, checking for keypress every 100ms */
        for (int i = 0; i < 10; i++) {
            if (telnet_key_available(sock)) goto done;
            vTaskDelay(pdMS_TO_TICKS(100));
        }
    }

done:
    /* Drain any pending input bytes */
    if (telnet_key_available(sock)) {
        uint8_t drain[16];
        recv(sock, drain, sizeof(drain), MSG_DONTWAIT);
    }
    telnet_send_str(sock, "\r\n");
}

static void cmd_log(int sock) {
    char buf[512];
    size_t read_pos = 0;
    bool first_call = true;

    telnet_drain_pending(sock);
    telnet_send_str(sock, "--- Log output (press any key to stop) ---\r\n");

    while (true) {
        // Read available log data
        size_t n = log_ringbuf_read(buf, sizeof(buf), &read_pos, &first_call);
        if (n > 0) {
            // Convert bare LF to CR+LF for telnet
            for (size_t i = 0; i < n; i++) {
                if (buf[i] == '\n' && (i == 0 || buf[i - 1] != '\r')) {
                    telnet_send_str(sock, "\r\n");
                } else if (buf[i] != '\r') {
                    if (!telnet_send(sock, &buf[i], 1)) return;
                }
            }
        }

        // Check for keypress to exit (poll 5 times per second)
        for (int i = 0; i < 5; i++) {
            if (telnet_key_available(sock)) goto done;
            vTaskDelay(pdMS_TO_TICKS(200));
            // Check for new data between polls
            size_t n2 = log_ringbuf_read(buf, sizeof(buf), &read_pos, &first_call);
            if (n2 > 0) {
                for (size_t j = 0; j < n2; j++) {
                    if (buf[j] == '\n' && (j == 0 || buf[j - 1] != '\r')) {
                        telnet_send_str(sock, "\r\n");
                    } else if (buf[j] != '\r') {
                        if (!telnet_send(sock, &buf[j], 1)) return;
                    }
                }
            }
        }
    }

done:
    /* Drain any pending input bytes */
    if (telnet_key_available(sock)) {
        uint8_t drain[16];
        recv(sock, drain, sizeof(drain), MSG_DONTWAIT);
    }
    telnet_send_str(sock, "\033[0m\r\n--- Log stopped ---\r\n");
}

// Returns true if the client should be disconnected.
static bool dispatch_command(int sock, fw_tcp_server_state_t *state,
                             const char *line, char *cwd) {
    // Skip leading whitespace
    while (*line == ' ') line++;
    if (*line == '\0') return false;

    // Split command and argument
    char cmd[32];
    const char *arg = NULL;
    const char *space = strchr(line, ' ');
    if (space != NULL) {
        size_t cmd_len = (size_t)(space - line);
        if (cmd_len >= sizeof(cmd)) cmd_len = sizeof(cmd) - 1;
        memcpy(cmd, line, cmd_len);
        cmd[cmd_len] = '\0';
        arg = space + 1;
        while (*arg == ' ') arg++;
        if (*arg == '\0') arg = NULL;
    } else {
        strlcpy(cmd, line, sizeof(cmd));
    }

    if (strcmp(cmd, "help") == 0) {
        cmd_help(sock);
    } else if (strcmp(cmd, "ls") == 0) {
        cmd_ls(sock, cwd);
    } else if (strcmp(cmd, "cd") == 0) {
        cmd_cd(sock, cwd, arg, cwd);
    } else if (strcmp(cmd, "pwd") == 0) {
        cmd_pwd(sock, cwd);
    } else if (strcmp(cmd, "run") == 0) {
        cmd_run(sock, state, cwd, arg);
    } else if (strcmp(cmd, "stop") == 0) {
        cmd_stop(sock, state);
    } else if (strcmp(cmd, "top") == 0) {
        cmd_top(sock, state);
    } else if (strcmp(cmd, "log") == 0) {
        cmd_log(sock);
    } else if (strcmp(cmd, "exit") == 0 || strcmp(cmd, "quit") == 0) {
        telnet_send_str(sock, "Bye.\r\n");
        return true;
    } else {
        char out[TELNET_OUT_MAX];
        int n = snprintf(out, sizeof(out), "Unknown command: %s\r\n", cmd);
        if (n > 0) telnet_send(sock, out, (size_t)n);
    }
    return false;
}

/* --- Client session ------------------------------------------------------ */

static void telnet_handle_client(int sock, fw_tcp_server_state_t *state) {
    char line[TELNET_LINE_MAX];
    size_t line_len = 0;
    char cwd[TELNET_CWD_MAX];
    strlcpy(cwd, "/", sizeof(cwd));

    // Send telnet negotiation
    telnet_send(sock, telnet_will_echo, sizeof(telnet_will_echo));
    telnet_send(sock, telnet_will_sga, sizeof(telnet_will_sga));
    telnet_send(sock, telnet_do_sga, sizeof(telnet_do_sga));
    telnet_send(sock, telnet_wont_linemode, sizeof(telnet_wont_linemode));

    // Welcome banner
    telnet_send_str(sock, "\r\nLED Pillar Telnet Console\r\n");
    telnet_send_str(sock, "Type 'help' for available commands.\r\n");
    telnet_send_prompt(sock, cwd);

    while (true) {
        uint8_t ch;
        ssize_t n = recv(sock, &ch, 1, 0);
        if (n <= 0) break; // Disconnect or error

        // IAC sequence: skip telnet negotiation bytes
        if (ch == 255) {
            uint8_t iac_buf[2];
            // Read command byte
            if (recv(sock, &iac_buf[0], 1, 0) <= 0) break;
            // WILL/WONT/DO/DONT have one option byte
            if (iac_buf[0] >= 251 && iac_buf[0] <= 254) {
                if (recv(sock, &iac_buf[1], 1, 0) <= 0) break;
            }
            // SB ... SE: skip subnegotiation
            if (iac_buf[0] == 250) {
                uint8_t sb;
                while (recv(sock, &sb, 1, 0) > 0) {
                    if (sb == 255) {
                        uint8_t se;
                        if (recv(sock, &se, 1, 0) <= 0) break;
                        if (se == 240) break; // SE
                    }
                }
            }
            continue;
        }

        // Ctrl+D: disconnect
        if (ch == 0x04) {
            telnet_send_str(sock, "Bye.\r\n");
            break;
        }

        // Ctrl+C: cancel current input
        if (ch == 0x03) {
            telnet_send_str(sock, "^C\r\n");
            line_len = 0;
            line[0] = '\0';
            telnet_send_prompt(sock, cwd);
            continue;
        }

        // Tab: trigger completion
        if (ch == 0x09) {
            line[line_len] = '\0';
            handle_tab(sock, line, &line_len, cwd);
            continue;
        }

        // Backspace
        if (ch == 0x7F || ch == 0x08) {
            if (line_len > 0) {
                line_len--;
                telnet_send_str(sock, "\b \b");
            }
            continue;
        }

        // Enter
        if (ch == 0x0D) {
            // Consume optional LF
            uint8_t peek;
            // Use MSG_PEEK + MSG_DONTWAIT to check for trailing LF without blocking
            if (recv(sock, &peek, 1, MSG_PEEK | MSG_DONTWAIT) > 0 && peek == 0x0A) {
                recv(sock, &peek, 1, 0); // consume it
            }
            telnet_send_str(sock, "\r\n");
            line[line_len] = '\0';
            if (dispatch_command(sock, state, line, cwd)) break;
            line_len = 0;
            telnet_send_prompt(sock, cwd);
            continue;
        }

        // Ignore non-printable characters
        if (ch < 0x20 || ch > 0x7E) continue;

        // Printable character: echo and add to buffer
        if (line_len < TELNET_LINE_MAX - 1) {
            line[line_len++] = (char)ch;
            telnet_send(sock, &ch, 1);
        }
    }
}

/* --- Task ---------------------------------------------------------------- */

static void telnet_task(void *arg) {
    telnet_task_ctx_t *ctx = (telnet_task_ctx_t *)arg;
    const uint16_t port = ctx->port;
    fw_tcp_server_state_t *state = ctx->state;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_sock < 0) {
        ESP_LOGE(TAG, "socket() failed: errno=%d", errno);
        vTaskDelete(NULL);
        return;
    }

    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    if (bind(listen_sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        ESP_LOGE(TAG, "bind() failed: errno=%d", errno);
        close(listen_sock);
        vTaskDelete(NULL);
        return;
    }

    if (listen(listen_sock, 1) != 0) {
        ESP_LOGE(TAG, "listen() failed: errno=%d", errno);
        close(listen_sock);
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "Telnet server listening on port %u", port);

    while (true) {
        struct sockaddr_in client_addr;
        socklen_t client_addr_len = sizeof(client_addr);
        int client_sock = accept(listen_sock, (struct sockaddr *)&client_addr, &client_addr_len);
        if (client_sock < 0) {
            ESP_LOGW(TAG, "accept() failed: errno=%d", errno);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }

        ESP_LOGI(TAG, "Client connected from %s", inet_ntoa(client_addr.sin_addr));
        telnet_handle_client(client_sock, state);
        close(client_sock);
        ESP_LOGI(TAG, "Client disconnected");
    }
}

/* --- Public API ---------------------------------------------------------- */

esp_err_t fw_telnet_server_start(uint16_t port, fw_tcp_server_state_t *state) {
    if (state == NULL) return ESP_ERR_INVALID_ARG;

    log_ringbuf_init();

    s_ctx.port = port;
    s_ctx.state = state;

    BaseType_t ret = xTaskCreatePinnedToCore(
        telnet_task,
        "telnet_srv",
        TELNET_TASK_STACK,
        &s_ctx,
        TELNET_TASK_PRIO,
        NULL,
        0  /* Pin to core 0 — shader runs on core 1, so telnet is never starved */
    );

    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create telnet task");
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Telnet server started on port %u", port);
    return ESP_OK;
}
