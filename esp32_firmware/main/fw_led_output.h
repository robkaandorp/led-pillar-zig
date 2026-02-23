#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/rmt_tx.h"
#include "esp_err.h"
#include "fw_led_config.h"

typedef struct {
    bool initialized;
    fw_led_layout_config_t layout;
    rmt_channel_handle_t channels[FW_LED_MAX_SEGMENTS];
    rmt_encoder_handle_t encoders[FW_LED_MAX_SEGMENTS];
    rmt_sync_manager_handle_t sync_manager;
    uint8_t *segment_buffers[FW_LED_MAX_SEGMENTS][2];
    size_t segment_buffer_len[FW_LED_MAX_SEGMENTS];
    bool slot_in_flight[2];
    uint8_t next_slot;
    bool sync_needs_reset;
    uint16_t gamma_x100;
    uint8_t gamma_lut[256];
} fw_led_output_t;

esp_err_t fw_led_output_init(fw_led_output_t *driver, const fw_led_layout_config_t *layout);
void fw_led_output_deinit(fw_led_output_t *driver);
esp_err_t fw_led_output_push_frame(
    fw_led_output_t *driver,
    const uint8_t *frame_buffer,
    size_t frame_buffer_len,
    uint8_t pixel_format,
    uint8_t bytes_per_pixel
);
esp_err_t fw_led_output_push_uniform_rgb(fw_led_output_t *driver, uint8_t r, uint8_t g, uint8_t b);
