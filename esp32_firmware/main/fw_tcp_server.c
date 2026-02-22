#include "fw_tcp_server.h"

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/inet.h"

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "nvs.h"
#include "sdkconfig.h"

#include "fw_bytecode_vm.h"
#include "fw_led_output.h"

#ifdef CONFIG_FW_V12_REMAP_LOGICAL
#define FW_V12_REMAP_LOGICAL true
#else
#define FW_V12_REMAP_LOGICAL false
#endif

#define FW_TCP_HEADER_LEN 10U
#define FW_TCP_ACK_BYTE 0x06U

#define FW_TCP_PROTOCOL_V1 0x01U
#define FW_TCP_PROTOCOL_V2 0x02U
#define FW_TCP_PROTOCOL_V3 0x03U

#define FW_TCP_MAX_BYTES_PER_PIXEL 4U
#define FW_TCP_MAX_BYTECODE_BLOB (64U * 1024U)

#define FW_TCP_V3_CMD_UPLOAD_BYTECODE 0x01U
#define FW_TCP_V3_CMD_ACTIVATE_SHADER 0x02U
#define FW_TCP_V3_CMD_SET_DEFAULT_HOOK 0x03U
#define FW_TCP_V3_CMD_CLEAR_DEFAULT_HOOK 0x04U
#define FW_TCP_V3_CMD_QUERY_DEFAULT_HOOK 0x05U
#define FW_TCP_V3_CMD_UPLOAD_FIRMWARE 0x06U
#define FW_TCP_V3_RESPONSE_FLAG 0x80U

#define FW_TCP_V3_STATUS_OK 0U
#define FW_TCP_V3_STATUS_INVALID_ARG 1U
#define FW_TCP_V3_STATUS_UNSUPPORTED_CMD 2U
#define FW_TCP_V3_STATUS_TOO_LARGE 3U
#define FW_TCP_V3_STATUS_NOT_READY 4U
#define FW_TCP_V3_STATUS_VM_ERROR 5U
#define FW_TCP_V3_STATUS_INTERNAL 6U

// Persistence format assumption: store raw BC3 bytecode as an NVS blob; blob length comes from NVS metadata.
#define FW_TCP_NVS_NAMESPACE "fw_shader"
#define FW_TCP_NVS_KEY_DEFAULT_SHADER "default_bc3"
#define FW_TCP_V3_STATUS_PAYLOAD_LEN 8U

typedef struct {
    bool started;
    fw_led_layout_config_t layout;
    uint32_t led_count;
    uint8_t *frame_buffer;
    size_t frame_buffer_len;
    uint8_t *rx_buffer;
    size_t rx_buffer_len;
    uint8_t *bytecode_blob;
    size_t bytecode_blob_len;
    bool has_uploaded_program;
    bool shader_active;
    bool default_shader_persisted;
    bool default_shader_faulted;
    fw_bc3_program_t uploaded_program;
    fw_bc3_runtime_t runtime;
    uint16_t port;
    fw_led_output_t led_output;
} fw_tcp_server_state_t;

static const char *TAG = "fw_tcp_srv";
static fw_tcp_server_state_t g_fw_tcp_server = {0};

static uint32_t fw_tcp_read_be_u32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) | ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static void fw_tcp_write_be_u32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)((value >> 24U) & 0xffU);
    bytes[1] = (uint8_t)((value >> 16U) & 0xffU);
    bytes[2] = (uint8_t)((value >> 8U) & 0xffU);
    bytes[3] = (uint8_t)(value & 0xffU);
}

static bool fw_tcp_recv_exact(int sock, uint8_t *buffer, size_t len) {
    size_t read_total = 0;
    while (read_total < len) {
        const ssize_t read_now = recv(sock, buffer + read_total, len - read_total, 0);
        if (read_now == 0) {
            return false;
        }
        if (read_now < 0) {
            if (errno == EINTR) {
                continue;
            }
            ESP_LOGW(TAG, "recv failed: errno=%d", errno);
            return false;
        }
        read_total += (size_t)read_now;
    }
    return true;
}

static bool fw_tcp_send_exact(int sock, const uint8_t *buffer, size_t len) {
    size_t sent_total = 0;
    while (sent_total < len) {
        const ssize_t sent_now = send(sock, buffer + sent_total, len - sent_total, 0);
        if (sent_now <= 0) {
            if (sent_now < 0 && errno == EINTR) {
                continue;
            }
            ESP_LOGW(TAG, "send failed: errno=%d", errno);
            return false;
        }
        sent_total += (size_t)sent_now;
    }
    return true;
}

static bool fw_tcp_drain_bytes(int sock, size_t len) {
    uint8_t scratch[256];
    size_t remaining = len;
    while (remaining > 0U) {
        const size_t chunk = (remaining < sizeof(scratch)) ? remaining : sizeof(scratch);
        const ssize_t read_now = recv(sock, scratch, chunk, 0);
        if (read_now <= 0) {
            return false;
        }
        remaining -= (size_t)read_now;
    }
    return true;
}

static bool fw_tcp_pixel_format_bytes(uint8_t pixel_format, uint8_t *out_bytes_per_pixel) {
    if (out_bytes_per_pixel == NULL) {
        return false;
    }
    switch (pixel_format) {
        case 0:
        case 2:
        case 4:
            *out_bytes_per_pixel = 3U;
            return true;
        case 1:
        case 3:
            *out_bytes_per_pixel = 4U;
            return true;
        default:
            return false;
    }
}

static esp_err_t fw_tcp_blit_frame(fw_tcp_server_state_t *state, uint8_t bytes_per_pixel, const uint8_t *payload, size_t payload_len) {
    if (state == NULL || payload == NULL || bytes_per_pixel == 0U) {
        return ESP_ERR_INVALID_ARG;
    }

    if (state->led_count > (UINT32_MAX / bytes_per_pixel)) {
        return ESP_ERR_INVALID_SIZE;
    }

    const size_t expected_len = (size_t)state->led_count * bytes_per_pixel;
    if (payload_len != expected_len || payload_len > state->frame_buffer_len) {
        return ESP_ERR_INVALID_SIZE;
    }

    if (!FW_V12_REMAP_LOGICAL) {
        memcpy(state->frame_buffer, payload, expected_len);
        return ESP_OK;
    }

    uint32_t logical_index = 0;
    while (logical_index < state->led_count) {
        fw_led_physical_index_t mapped = {0};
        esp_err_t map_err = fw_led_map_logical_linear(&state->layout, logical_index, &mapped);
        if (map_err != ESP_OK) {
            return map_err;
        }

        const size_t src_offset = (size_t)logical_index * bytes_per_pixel;
        const size_t dst_offset = (size_t)mapped.global_led_index * bytes_per_pixel;
        if (dst_offset + bytes_per_pixel > state->frame_buffer_len) {
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(state->frame_buffer + dst_offset, payload + src_offset, bytes_per_pixel);
        logical_index += 1U;
    }

    return ESP_OK;
}

static bool fw_tcp_send_v3_response(int sock, uint8_t response_type, uint8_t status, const uint8_t *payload, size_t payload_len) {
    if (payload_len > UINT32_MAX - 1U) {
        return false;
    }

    uint8_t header[FW_TCP_HEADER_LEN] = {'L', 'E', 'D', 'S', FW_TCP_PROTOCOL_V3, 0, 0, 0, 0, response_type};
    const uint32_t wire_payload_len = (uint32_t)(payload_len + 1U);
    fw_tcp_write_be_u32(&header[5], wire_payload_len);

    if (!fw_tcp_send_exact(sock, header, sizeof(header))) {
        return false;
    }
    if (!fw_tcp_send_exact(sock, &status, 1U)) {
        return false;
    }
    if (payload_len > 0U && payload != NULL) {
        if (!fw_tcp_send_exact(sock, payload, payload_len)) {
            return false;
        }
    }
    return true;
}

static esp_err_t fw_tcp_clear_persisted_default_shader(void) {
    nvs_handle_t nvs = 0;
    esp_err_t err = nvs_open(FW_TCP_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_erase_key(nvs, FW_TCP_NVS_KEY_DEFAULT_SHADER);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        nvs_close(nvs);
        return ESP_OK;
    }
    if (err != ESP_OK) {
        nvs_close(nvs);
        return err;
    }

    err = nvs_commit(nvs);
    nvs_close(nvs);
    return err;
}

static esp_err_t fw_tcp_persist_default_shader(const fw_tcp_server_state_t *state) {
    if (state == NULL || state->bytecode_blob == NULL || state->bytecode_blob_len == 0U || state->bytecode_blob_len > FW_TCP_MAX_BYTECODE_BLOB) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs = 0;
    esp_err_t err = nvs_open(FW_TCP_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_blob(nvs, FW_TCP_NVS_KEY_DEFAULT_SHADER, state->bytecode_blob, state->bytecode_blob_len);
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

static esp_err_t fw_tcp_load_persisted_default_shader(fw_tcp_server_state_t *state) {
    if (state == NULL || state->bytecode_blob == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs = 0;
    esp_err_t err = nvs_open(FW_TCP_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    size_t blob_len = 0U;
    err = nvs_get_blob(nvs, FW_TCP_NVS_KEY_DEFAULT_SHADER, NULL, &blob_len);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        nvs_close(nvs);
        return ESP_ERR_NOT_FOUND;
    }
    if (err != ESP_OK) {
        nvs_close(nvs);
        return err;
    }
    if (blob_len == 0U || blob_len > FW_TCP_MAX_BYTECODE_BLOB) {
        nvs_close(nvs);
        (void)fw_tcp_clear_persisted_default_shader();
        return ESP_ERR_INVALID_SIZE;
    }

    size_t read_len = blob_len;
    err = nvs_get_blob(nvs, FW_TCP_NVS_KEY_DEFAULT_SHADER, state->bytecode_blob, &read_len);
    nvs_close(nvs);
    if (err != ESP_OK) {
        return err;
    }
    if (read_len != blob_len) {
        (void)fw_tcp_clear_persisted_default_shader();
        return ESP_ERR_INVALID_SIZE;
    }

    fw_bc3_status_t vm_status = fw_bc3_program_load(&state->uploaded_program, state->bytecode_blob, read_len);
    if (vm_status != FW_BC3_OK) {
        ESP_LOGW(TAG, "persisted bytecode load failed: %s", fw_bc3_status_to_string(vm_status));
        (void)fw_tcp_clear_persisted_default_shader();
        return ESP_ERR_INVALID_RESPONSE;
    }

    vm_status = fw_bc3_runtime_init(&state->runtime, &state->uploaded_program, state->layout.width, state->layout.height);
    if (vm_status != FW_BC3_OK) {
        ESP_LOGW(TAG, "persisted shader activate failed: %s", fw_bc3_status_to_string(vm_status));
        (void)fw_tcp_clear_persisted_default_shader();
        return ESP_ERR_INVALID_RESPONSE;
    }

    state->bytecode_blob_len = read_len;
    state->has_uploaded_program = true;
    state->shader_active = true;
    state->default_shader_persisted = true;
    state->default_shader_faulted = false;
    return ESP_OK;
}

static uint8_t fw_tcp_handle_v3_upload(fw_tcp_server_state_t *state, const uint8_t *payload, size_t payload_len) {
    if (state == NULL || payload == NULL || payload_len == 0U) {
        return FW_TCP_V3_STATUS_INVALID_ARG;
    }
    if (payload_len > FW_TCP_MAX_BYTECODE_BLOB) {
        return FW_TCP_V3_STATUS_TOO_LARGE;
    }

    memcpy(state->bytecode_blob, payload, payload_len);
    fw_bc3_status_t vm_status = fw_bc3_program_load(&state->uploaded_program, state->bytecode_blob, payload_len);
    if (vm_status != FW_BC3_OK) {
        ESP_LOGW(TAG, "bytecode load failed: %s", fw_bc3_status_to_string(vm_status));
        state->has_uploaded_program = false;
        state->bytecode_blob_len = 0U;
        state->shader_active = false;
        return FW_TCP_V3_STATUS_VM_ERROR;
    }

    state->bytecode_blob_len = payload_len;
    state->has_uploaded_program = true;
    state->shader_active = false;
    return FW_TCP_V3_STATUS_OK;
}

static uint8_t fw_tcp_handle_v3_activate(fw_tcp_server_state_t *state) {
    if (state == NULL) {
        return FW_TCP_V3_STATUS_INTERNAL;
    }
    if (!state->has_uploaded_program) {
        return FW_TCP_V3_STATUS_NOT_READY;
    }

    fw_bc3_status_t vm_status = fw_bc3_runtime_init(
        &state->runtime,
        &state->uploaded_program,
        state->layout.width,
        state->layout.height
    );
    if (vm_status != FW_BC3_OK) {
        ESP_LOGW(TAG, "shader activate failed: %s", fw_bc3_status_to_string(vm_status));
        state->shader_active = false;
        return FW_TCP_V3_STATUS_VM_ERROR;
    }

    state->shader_active = true;
    return FW_TCP_V3_STATUS_OK;
}

static uint8_t fw_tcp_handle_v3_set_hook(fw_tcp_server_state_t *state, const uint8_t *payload, size_t payload_len) {
    (void)payload;
    if (state == NULL || payload_len != 0U) {
        return FW_TCP_V3_STATUS_INVALID_ARG;
    }
    if (!state->has_uploaded_program || state->bytecode_blob_len == 0U) {
        return FW_TCP_V3_STATUS_NOT_READY;
    }

    esp_err_t persist_err = fw_tcp_persist_default_shader(state);
    if (persist_err != ESP_OK) {
        ESP_LOGW(TAG, "default shader persist failed: %s", esp_err_to_name(persist_err));
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    state->default_shader_persisted = true;
    state->default_shader_faulted = false;
    return FW_TCP_V3_STATUS_OK;
}

static uint8_t fw_tcp_handle_v3_clear_hook(fw_tcp_server_state_t *state, const uint8_t *payload, size_t payload_len) {
    (void)payload;
    if (state == NULL || payload_len != 0U) {
        return FW_TCP_V3_STATUS_INVALID_ARG;
    }

    esp_err_t clear_err = fw_tcp_clear_persisted_default_shader();
    if (clear_err != ESP_OK) {
        ESP_LOGW(TAG, "default shader clear failed: %s", esp_err_to_name(clear_err));
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    state->default_shader_persisted = false;
    state->default_shader_faulted = false;
    return FW_TCP_V3_STATUS_OK;
}

static uint8_t fw_tcp_handle_v3_query_hook(
    fw_tcp_server_state_t *state,
    const uint8_t *payload,
    size_t payload_len,
    uint8_t *response_payload,
    size_t response_capacity,
    size_t *out_response_len
) {
    (void)payload;
    if (state == NULL || response_payload == NULL || out_response_len == NULL || payload_len != 0U) {
        return FW_TCP_V3_STATUS_INVALID_ARG;
    }
    if (response_capacity < FW_TCP_V3_STATUS_PAYLOAD_LEN) {
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    response_payload[0] = state->default_shader_persisted ? 1U : 0U;
    response_payload[1] = state->has_uploaded_program ? 1U : 0U;
    response_payload[2] = state->shader_active ? 1U : 0U;
    response_payload[3] = state->default_shader_faulted ? 1U : 0U;
    fw_tcp_write_be_u32(&response_payload[4], (uint32_t)state->bytecode_blob_len);
    *out_response_len = FW_TCP_V3_STATUS_PAYLOAD_LEN;
    return FW_TCP_V3_STATUS_OK;
}

static bool fw_tcp_handle_v3_message(int sock, fw_tcp_server_state_t *state, uint8_t cmd, const uint8_t *payload, size_t payload_len) {
    uint8_t response_payload[FW_TCP_V3_STATUS_PAYLOAD_LEN];
    size_t response_len = 0U;
    uint8_t status = FW_TCP_V3_STATUS_OK;

    switch (cmd) {
        case FW_TCP_V3_CMD_UPLOAD_BYTECODE:
            status = fw_tcp_handle_v3_upload(state, payload, payload_len);
            break;
        case FW_TCP_V3_CMD_ACTIVATE_SHADER:
            if (payload_len != 0U) {
                status = FW_TCP_V3_STATUS_INVALID_ARG;
            } else {
                status = fw_tcp_handle_v3_activate(state);
            }
            break;
        case FW_TCP_V3_CMD_SET_DEFAULT_HOOK:
            status = fw_tcp_handle_v3_set_hook(state, payload, payload_len);
            break;
        case FW_TCP_V3_CMD_CLEAR_DEFAULT_HOOK:
            status = fw_tcp_handle_v3_clear_hook(state, payload, payload_len);
            break;
        case FW_TCP_V3_CMD_QUERY_DEFAULT_HOOK:
            status = fw_tcp_handle_v3_query_hook(
                state,
                payload,
                payload_len,
                response_payload,
                sizeof(response_payload),
                &response_len
            );
            break;
        default:
            status = FW_TCP_V3_STATUS_UNSUPPORTED_CMD;
            break;
    }

    return fw_tcp_send_v3_response(sock, (uint8_t)(cmd | FW_TCP_V3_RESPONSE_FLAG), status, response_payload, response_len);
}

static uint8_t fw_tcp_handle_v3_firmware_upload_stream(int sock, fw_tcp_server_state_t *state, size_t payload_len) {
    if (state == NULL || payload_len == 0U) {
        return FW_TCP_V3_STATUS_INVALID_ARG;
    }

    const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
    if (update_partition == NULL) {
        (void)fw_tcp_drain_bytes(sock, payload_len);
        return FW_TCP_V3_STATUS_INTERNAL;
    }
    if (payload_len > update_partition->size) {
        (void)fw_tcp_drain_bytes(sock, payload_len);
        ESP_LOGW(TAG, "firmware payload too large: %u > %u", (unsigned)payload_len, (unsigned)update_partition->size);
        return FW_TCP_V3_STATUS_TOO_LARGE;
    }

    esp_ota_handle_t ota_handle = 0;
    esp_err_t ota_err = esp_ota_begin(update_partition, payload_len, &ota_handle);
    if (ota_err != ESP_OK) {
        (void)fw_tcp_drain_bytes(sock, payload_len);
        ESP_LOGW(TAG, "esp_ota_begin failed: %s", esp_err_to_name(ota_err));
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    size_t remaining = payload_len;
    while (remaining > 0U) {
        const size_t chunk_len = (remaining < state->rx_buffer_len) ? remaining : state->rx_buffer_len;
        if (!fw_tcp_recv_exact(sock, state->rx_buffer, chunk_len)) {
            (void)esp_ota_abort(ota_handle);
            return FW_TCP_V3_STATUS_INTERNAL;
        }

        ota_err = esp_ota_write(ota_handle, state->rx_buffer, chunk_len);
        if (ota_err != ESP_OK) {
            (void)esp_ota_abort(ota_handle);
            if (remaining > chunk_len) {
                (void)fw_tcp_drain_bytes(sock, remaining - chunk_len);
            }
            ESP_LOGW(TAG, "esp_ota_write failed: %s", esp_err_to_name(ota_err));
            return FW_TCP_V3_STATUS_INTERNAL;
        }
        remaining -= chunk_len;
    }

    ota_err = esp_ota_end(ota_handle);
    if (ota_err != ESP_OK) {
        ESP_LOGW(TAG, "esp_ota_end failed: %s", esp_err_to_name(ota_err));
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    ota_err = esp_ota_set_boot_partition(update_partition);
    if (ota_err != ESP_OK) {
        ESP_LOGW(TAG, "esp_ota_set_boot_partition failed: %s", esp_err_to_name(ota_err));
        return FW_TCP_V3_STATUS_INTERNAL;
    }

    ESP_LOGI(TAG, "firmware upload complete (%u bytes), rebooting into new partition", (unsigned)payload_len);
    return FW_TCP_V3_STATUS_OK;
}

static bool fw_tcp_handle_frame_message(
    int sock,
    fw_tcp_server_state_t *state,
    uint8_t version,
    uint8_t pixel_format,
    uint32_t pixel_count,
    const uint8_t *payload,
    size_t payload_len
) {
    if (state == NULL || payload == NULL) {
        return false;
    }

    uint8_t bytes_per_pixel = 0;
    if (!fw_tcp_pixel_format_bytes(pixel_format, &bytes_per_pixel)) {
        ESP_LOGW(TAG, "unsupported pixel format: %u", pixel_format);
        return false;
    }
    if (pixel_count != state->led_count) {
        ESP_LOGW(TAG, "pixel count mismatch: expected=%" PRIu32 " got=%" PRIu32, state->led_count, pixel_count);
        return false;
    }

    esp_err_t blit_err = fw_tcp_blit_frame(state, bytes_per_pixel, payload, payload_len);
    if (blit_err != ESP_OK) {
        ESP_LOGW(TAG, "frame blit failed: %s", esp_err_to_name(blit_err));
        return false;
    }
    esp_err_t push_err =
        fw_led_output_push_frame(&state->led_output, state->frame_buffer, state->frame_buffer_len, pixel_format, bytes_per_pixel);
    if (push_err != ESP_OK) {
        ESP_LOGW(TAG, "frame output failed: %s", esp_err_to_name(push_err));
        return false;
    }

    if (version == FW_TCP_PROTOCOL_V2) {
        const uint8_t ack = FW_TCP_ACK_BYTE;
        if (!fw_tcp_send_exact(sock, &ack, 1U)) {
            return false;
        }
    }
    return true;
}

static bool fw_tcp_client_loop(int client_sock, fw_tcp_server_state_t *state) {
    uint8_t header[FW_TCP_HEADER_LEN];

    while (true) {
        if (!fw_tcp_recv_exact(client_sock, header, sizeof(header))) {
            return false;
        }
        if (memcmp(header, "LEDS", 4U) != 0) {
            ESP_LOGW(TAG, "invalid magic from client");
            return false;
        }

        const uint8_t version = header[4];
        if (version == FW_TCP_PROTOCOL_V1 || version == FW_TCP_PROTOCOL_V2) {
            const uint32_t pixel_count = fw_tcp_read_be_u32(&header[5]);
            const uint8_t pixel_format = header[9];
            uint8_t bytes_per_pixel = 0;
            if (!fw_tcp_pixel_format_bytes(pixel_format, &bytes_per_pixel)) {
                ESP_LOGW(TAG, "invalid frame pixel format: %u", pixel_format);
                return false;
            }

            if (pixel_count > (UINT32_MAX / bytes_per_pixel)) {
                return false;
            }
            const size_t payload_len = (size_t)pixel_count * bytes_per_pixel;
            if (payload_len > state->rx_buffer_len) {
                if (!fw_tcp_drain_bytes(client_sock, payload_len)) {
                    return false;
                }
                ESP_LOGW(TAG, "frame payload too large: %u", (unsigned)payload_len);
                return false;
            }

            if (!fw_tcp_recv_exact(client_sock, state->rx_buffer, payload_len)) {
                return false;
            }
            if (!fw_tcp_handle_frame_message(
                    client_sock,
                    state,
                    version,
                    pixel_format,
                    pixel_count,
                    state->rx_buffer,
                    payload_len
                )) {
                return false;
            }
            continue;
        }

        if (version == FW_TCP_PROTOCOL_V3) {
            const uint32_t payload_len_u32 = fw_tcp_read_be_u32(&header[5]);
            const size_t payload_len = (size_t)payload_len_u32;
            const uint8_t cmd = header[9];
            if (cmd == FW_TCP_V3_CMD_UPLOAD_FIRMWARE) {
                const uint8_t status = fw_tcp_handle_v3_firmware_upload_stream(client_sock, state, payload_len);
                if (!fw_tcp_send_v3_response(
                        client_sock,
                        (uint8_t)(cmd | FW_TCP_V3_RESPONSE_FLAG),
                        status,
                        NULL,
                        0U
                    )) {
                    return false;
                }
                if (status == FW_TCP_V3_STATUS_OK) {
                    vTaskDelay(pdMS_TO_TICKS(200));
                    esp_restart();
                    return false;
                }
                continue;
            }
            if (payload_len > state->rx_buffer_len) {
                if (!fw_tcp_drain_bytes(client_sock, payload_len)) {
                    return false;
                }
                if (!fw_tcp_send_v3_response(
                        client_sock,
                        (uint8_t)(cmd | FW_TCP_V3_RESPONSE_FLAG),
                        FW_TCP_V3_STATUS_TOO_LARGE,
                        NULL,
                        0U
                    )) {
                    return false;
                }
                continue;
            }

            if (payload_len > 0U) {
                if (!fw_tcp_recv_exact(client_sock, state->rx_buffer, payload_len)) {
                    return false;
                }
            }
            if (!fw_tcp_handle_v3_message(client_sock, state, cmd, state->rx_buffer, payload_len)) {
                return false;
            }
            continue;
        }

        ESP_LOGW(TAG, "unsupported protocol version: %u", version);
        return false;
    }
}

static int fw_tcp_open_listen_socket(uint16_t port) {
    const int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (listen_sock < 0) {
        ESP_LOGE(TAG, "socket() failed: errno=%d", errno);
        return -1;
    }

    int reuse = 1;
    if (setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0) {
        ESP_LOGW(TAG, "setsockopt(SO_REUSEADDR) failed: errno=%d", errno);
    }

    struct sockaddr_in listen_addr = {0};
    listen_addr.sin_family = AF_INET;
    listen_addr.sin_port = htons(port);
    listen_addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(listen_sock, (struct sockaddr *)&listen_addr, sizeof(listen_addr)) < 0) {
        ESP_LOGE(TAG, "bind() failed: errno=%d", errno);
        close(listen_sock);
        return -1;
    }
    if (listen(listen_sock, 1) < 0) {
        ESP_LOGE(TAG, "listen() failed: errno=%d", errno);
        close(listen_sock);
        return -1;
    }

    ESP_LOGI(TAG, "TCP protocol server listening on port %u", port);
    return listen_sock;
}

static void fw_tcp_server_task(void *arg) {
    fw_tcp_server_state_t *state = (fw_tcp_server_state_t *)arg;
    int listen_sock = -1;

    while (listen_sock < 0) {
        listen_sock = fw_tcp_open_listen_socket(state->port);
        if (listen_sock < 0) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    while (true) {
        struct sockaddr_storage source_addr = {0};
        socklen_t source_addr_len = sizeof(source_addr);
        const int client_sock = accept(listen_sock, (struct sockaddr *)&source_addr, &source_addr_len);
        if (client_sock < 0) {
            ESP_LOGW(TAG, "accept() failed: errno=%d", errno);
            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }

        ESP_LOGI(TAG, "client connected");
        (void)fw_tcp_client_loop(client_sock, state);
        shutdown(client_sock, 0);
        close(client_sock);
        ESP_LOGI(TAG, "client disconnected");
    }
}

esp_err_t fw_tcp_server_start(const fw_led_layout_config_t *layout, uint16_t port) {
    if (layout == NULL || port == 0U) {
        return ESP_ERR_INVALID_ARG;
    }
    if (g_fw_tcp_server.started) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t layout_err = fw_led_layout_validate(layout);
    if (layout_err != ESP_OK) {
        return layout_err;
    }

    memset(&g_fw_tcp_server, 0, sizeof(g_fw_tcp_server));
    g_fw_tcp_server.layout = *layout;
    g_fw_tcp_server.led_count = fw_led_layout_total_leds(layout);
    g_fw_tcp_server.port = port;

    if (g_fw_tcp_server.led_count == 0U || g_fw_tcp_server.led_count > (UINT32_MAX / FW_TCP_MAX_BYTES_PER_PIXEL)) {
        return ESP_ERR_INVALID_SIZE;
    }

    g_fw_tcp_server.frame_buffer_len = (size_t)g_fw_tcp_server.led_count * FW_TCP_MAX_BYTES_PER_PIXEL;
    g_fw_tcp_server.rx_buffer_len =
        (g_fw_tcp_server.frame_buffer_len > FW_TCP_MAX_BYTECODE_BLOB) ? g_fw_tcp_server.frame_buffer_len : FW_TCP_MAX_BYTECODE_BLOB;

    g_fw_tcp_server.frame_buffer = (uint8_t *)calloc(1U, g_fw_tcp_server.frame_buffer_len);
    g_fw_tcp_server.rx_buffer = (uint8_t *)malloc(g_fw_tcp_server.rx_buffer_len);
    g_fw_tcp_server.bytecode_blob = (uint8_t *)malloc(FW_TCP_MAX_BYTECODE_BLOB);

    if (g_fw_tcp_server.frame_buffer == NULL || g_fw_tcp_server.rx_buffer == NULL || g_fw_tcp_server.bytecode_blob == NULL) {
        free(g_fw_tcp_server.frame_buffer);
        free(g_fw_tcp_server.rx_buffer);
        free(g_fw_tcp_server.bytecode_blob);
        memset(&g_fw_tcp_server, 0, sizeof(g_fw_tcp_server));
        return ESP_ERR_NO_MEM;
    }

    esp_err_t led_output_err = fw_led_output_init(&g_fw_tcp_server.led_output, &g_fw_tcp_server.layout);
    if (led_output_err != ESP_OK) {
        free(g_fw_tcp_server.frame_buffer);
        free(g_fw_tcp_server.rx_buffer);
        free(g_fw_tcp_server.bytecode_blob);
        memset(&g_fw_tcp_server, 0, sizeof(g_fw_tcp_server));
        return led_output_err;
    }

    esp_err_t default_shader_err = fw_tcp_load_persisted_default_shader(&g_fw_tcp_server);
    if (default_shader_err == ESP_OK) {
        ESP_LOGI(TAG, "loaded persisted default shader (%u bytes)", (unsigned)g_fw_tcp_server.bytecode_blob_len);
    } else if (default_shader_err == ESP_ERR_NOT_FOUND) {
        g_fw_tcp_server.default_shader_persisted = false;
    } else {
        g_fw_tcp_server.default_shader_persisted = false;
        g_fw_tcp_server.default_shader_faulted = true;
        ESP_LOGW(TAG, "default shader restore failed: %s", esp_err_to_name(default_shader_err));
    }

    if (xTaskCreate(fw_tcp_server_task, "fw_tcp_server", 8192, &g_fw_tcp_server, 5, NULL) != pdPASS) {
        fw_led_output_deinit(&g_fw_tcp_server.led_output);
        free(g_fw_tcp_server.frame_buffer);
        free(g_fw_tcp_server.rx_buffer);
        free(g_fw_tcp_server.bytecode_blob);
        memset(&g_fw_tcp_server, 0, sizeof(g_fw_tcp_server));
        return ESP_ERR_NO_MEM;
    }

    g_fw_tcp_server.started = true;
    return ESP_OK;
}
