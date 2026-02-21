#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"

#define FW_LED_DEFAULT_WIDTH 30
#define FW_LED_DEFAULT_HEIGHT 40
#define FW_LED_MAX_SEGMENTS 8

typedef struct {
    gpio_num_t gpio;
    uint16_t led_count;
} fw_led_segment_config_t;

typedef struct {
    uint16_t width;
    uint16_t height;
    bool serpentine_columns;
    uint8_t segment_count;
    fw_led_segment_config_t segments[FW_LED_MAX_SEGMENTS];
} fw_led_layout_config_t;

typedef struct {
    uint8_t segment_index;
    uint16_t segment_led_index;
    uint32_t global_led_index;
} fw_led_physical_index_t;

void fw_led_layout_load_default(fw_led_layout_config_t *layout);
uint32_t fw_led_layout_total_leds(const fw_led_layout_config_t *layout);
esp_err_t fw_led_layout_validate(const fw_led_layout_config_t *layout);
esp_err_t fw_led_map_logical_xy(const fw_led_layout_config_t *layout, uint16_t x, uint16_t y, fw_led_physical_index_t *out);
esp_err_t fw_led_map_logical_linear(const fw_led_layout_config_t *layout, uint32_t logical_index, fw_led_physical_index_t *out);
