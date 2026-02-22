#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "fw_led_config.h"
#include "led_strip.h"

typedef struct {
    bool initialized;
    fw_led_layout_config_t layout;
    led_strip_handle_t segments[FW_LED_MAX_SEGMENTS];
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
