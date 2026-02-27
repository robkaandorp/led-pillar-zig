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
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        if (strcmp(dsl_shader_registry[i].folder, path) == 0) return true;
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

/// Count command/entry matches for prefix; store single match in out_match.
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
                strlcpy(out_match, dsl_shader_registry[i].name, out_match_len);
            }
        }
    }

    // Match subdirectory names visible from cwd
    // A subdirectory is a folder that starts with cwd + "/" and has exactly one more component
    size_t cwd_len = strlen(cwd);
    const char *seen[32];
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
        if (seen_count < 32) seen[seen_count++] = child_name;

        count++;
        strlcpy(out_match, child_name, out_match_len);
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
    const char *seen[32];
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
        if (seen_count < 32) seen[seen_count++] = child_name;

        telnet_send_str(sock, child_name);
        telnet_send_str(sock, "/\r\n");
    }
}

static const char *cmd_names[] = { "ls", "cd", "pwd", "run", "stop", "top", "help", NULL };

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

        char match_buf[TELNET_CWD_MAX];
        int count = tab_complete_entries(cwd, arg, dirs_only, match_buf, sizeof(match_buf));

        if (count == 1) {
            const char *suffix = match_buf + strlen(arg);
            size_t suffix_len = strlen(suffix);
            if (*line_len + suffix_len + 1 < TELNET_LINE_MAX) {
                memcpy(line + *line_len, suffix, suffix_len);
                *line_len += suffix_len;
                line[*line_len] = '\0';
                telnet_send(sock, suffix, suffix_len);
            }
        } else if (count > 1) {
            tab_print_matches(sock, cwd, arg, dirs_only);
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
        "  top             Show shader status\r\n"
        "  help            Show this help\r\n");
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
    const char *seen[32];
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
        if (seen_count < 32) seen[seen_count++] = child_name;

        int n = snprintf(out, sizeof(out), "%-25s [dir]\r\n", child_name);
        if (n > 0) telnet_send(sock, out, (size_t)n);
        any = true;
    }

    // List shaders in cwd
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        if (strcmp(dsl_shader_registry[i].folder, cwd) != 0) continue;
        const char *flags = dsl_shader_registry[i].has_frame_func ? " [native] [frame]" : " [native]";
        int n = snprintf(out, sizeof(out), "%-25s%s\r\n", dsl_shader_registry[i].name, flags);
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

    const dsl_shader_entry_t *entry = vfs_find_shader(cwd, name);
    if (entry == NULL) {
        // Try absolute lookup by name alone
        entry = dsl_shader_find(name);
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

static void cmd_top(int sock, fw_tcp_server_state_t *state) {
    char out[TELNET_OUT_MAX];
    const char *name = "(none)";
    const char *status = "stopped";
    uint32_t frames = 0;
    uint32_t slow = 0;

    xSemaphoreTake(state->state_lock, portMAX_DELAY);
    if (state->shader_active && state->active_native_shader != NULL) {
        name = state->active_native_shader->name;
        status = "running";
    }
    frames = state->shader_frame_count;
    slow = state->shader_slow_frame_count;
    xSemaphoreGive(state->state_lock);

    int n = snprintf(out, sizeof(out),
        "Shader:      %s\r\n"
        "Status:      %s\r\n"
        "FPS:         40.0\r\n"
        "Frames:      %" PRIu32 "\r\n"
        "Slow frames: %" PRIu32 "\r\n",
        name, status, frames, slow);
    if (n > 0) telnet_send(sock, out, (size_t)n);
}

/* --- Command dispatch ---------------------------------------------------- */

static void dispatch_command(int sock, fw_tcp_server_state_t *state,
                             const char *line, char *cwd) {
    // Skip leading whitespace
    while (*line == ' ') line++;
    if (*line == '\0') return;

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
    } else {
        char out[TELNET_OUT_MAX];
        int n = snprintf(out, sizeof(out), "Unknown command: %s\r\n", cmd);
        if (n > 0) telnet_send(sock, out, (size_t)n);
    }
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
            dispatch_command(sock, state, line, cwd);
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

        ESP_LOGI(TAG, "Client connected from " IPSTR, IP2STR(&client_addr.sin_addr));
        telnet_handle_client(client_sock, state);
        close(client_sock);
        ESP_LOGI(TAG, "Client disconnected");
    }
}

/* --- Public API ---------------------------------------------------------- */

esp_err_t fw_telnet_server_start(uint16_t port, fw_tcp_server_state_t *state) {
    if (state == NULL) return ESP_ERR_INVALID_ARG;

    s_ctx.port = port;
    s_ctx.state = state;

    BaseType_t ret = xTaskCreate(
        telnet_task,
        "telnet_srv",
        TELNET_TASK_STACK,
        &s_ctx,
        TELNET_TASK_PRIO,
        NULL
    );

    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create telnet task");
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Telnet server started on port %u", port);
    return ESP_OK;
}
