#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "fw_bytecode_vm.h"
#include "fw_led_config.h"
#include "fw_led_output.h"
#include "generated/dsl_shader_registry.h"

#define FW_TCP_DEFAULT_PORT 7777U

typedef enum {
    FW_TCP_SHADER_SOURCE_NONE = 0,
    FW_TCP_SHADER_SOURCE_BYTECODE = 1,
    FW_TCP_SHADER_SOURCE_NATIVE = 2,
} fw_tcp_shader_source_t;

typedef struct fw_tcp_server_state {
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
    fw_tcp_shader_source_t shader_source;
    const dsl_shader_entry_t *active_native_shader;
    float native_shader_seed;
    bool default_shader_persisted;
    bool default_shader_faulted;
    uint32_t shader_slow_frame_count;
    uint32_t shader_last_slow_frame_ms;
    uint32_t shader_frame_count;
    bool uniform_last_color_valid;
    uint8_t uniform_last_r;
    uint8_t uniform_last_g;
    uint8_t uniform_last_b;
    fw_bc3_program_t uploaded_program;
    fw_bc3_runtime_t runtime;
    SemaphoreHandle_t state_lock;
    uint16_t port;
    fw_led_output_t led_output;
} fw_tcp_server_state_t;

esp_err_t fw_tcp_server_start(const fw_led_layout_config_t *layout, uint16_t port);

/**
 * Get a pointer to the global TCP server state.
 * The state is valid after fw_tcp_server_start() has been called.
 */
fw_tcp_server_state_t *fw_tcp_server_get_state(void);
