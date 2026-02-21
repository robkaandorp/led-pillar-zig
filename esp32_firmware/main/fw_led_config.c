#include "fw_led_config.h"

#include <stddef.h>

static esp_err_t fw_led_resolve_global_index(const fw_led_layout_config_t *layout, uint32_t global_index, fw_led_physical_index_t *out) {
    uint32_t offset = 0;
    uint8_t segment = 0;

    while (segment < layout->segment_count) {
        const uint32_t segment_len = layout->segments[segment].led_count;
        if (global_index < (offset + segment_len)) {
            out->segment_index = segment;
            out->segment_led_index = (uint16_t)(global_index - offset);
            out->global_led_index = global_index;
            return ESP_OK;
        }

        offset += segment_len;
        segment += 1;
    }

    return ESP_ERR_INVALID_STATE;
}

void fw_led_layout_load_default(fw_led_layout_config_t *layout) {
    if (layout == NULL) {
        return;
    }

    *layout = (fw_led_layout_config_t){
        .width = FW_LED_DEFAULT_WIDTH,
        .height = FW_LED_DEFAULT_HEIGHT,
        .serpentine_columns = true,
        .segment_count = 3,
        .segments =
            {
                {.gpio = GPIO_NUM_13, .led_count = 400},
                {.gpio = GPIO_NUM_32, .led_count = 400},
                {.gpio = GPIO_NUM_33, .led_count = 400},
            },
    };
}

uint32_t fw_led_layout_total_leds(const fw_led_layout_config_t *layout) {
    uint32_t total = 0;

    if (layout == NULL) {
        return 0;
    }

    uint8_t segment = 0;
    while (segment < layout->segment_count) {
        total += layout->segments[segment].led_count;
        segment += 1;
    }

    return total;
}

esp_err_t fw_led_layout_validate(const fw_led_layout_config_t *layout) {
    if (layout == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (layout->width == 0 || layout->height == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    if (layout->segment_count == 0 || layout->segment_count > FW_LED_MAX_SEGMENTS) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t segment = 0;
    while (segment < layout->segment_count) {
        if (!GPIO_IS_VALID_OUTPUT_GPIO(layout->segments[segment].gpio) || layout->segments[segment].led_count == 0) {
            return ESP_ERR_INVALID_ARG;
        }
        segment += 1;
    }

    const uint32_t expected_leds = (uint32_t)layout->width * (uint32_t)layout->height;
    if (fw_led_layout_total_leds(layout) != expected_leds) {
        return ESP_ERR_INVALID_SIZE;
    }

    return ESP_OK;
}

esp_err_t fw_led_map_logical_xy(const fw_led_layout_config_t *layout, uint16_t x, uint16_t y, fw_led_physical_index_t *out) {
    if (layout == NULL || out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (x >= layout->width || y >= layout->height) {
        return ESP_ERR_INVALID_ARG;
    }

    uint16_t mapped_y = y;
    if (layout->serpentine_columns && ((x & 1U) != 0U)) {
        mapped_y = (uint16_t)(layout->height - 1U - y);
    }

    const uint32_t global_index = ((uint32_t)x * (uint32_t)layout->height) + mapped_y;
    return fw_led_resolve_global_index(layout, global_index, out);
}

esp_err_t fw_led_map_logical_linear(const fw_led_layout_config_t *layout, uint32_t logical_index, fw_led_physical_index_t *out) {
    if (layout == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint32_t logical_len = (uint32_t)layout->width * (uint32_t)layout->height;
    if (logical_index >= logical_len) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint16_t x = (uint16_t)(logical_index % layout->width);
    const uint16_t y = (uint16_t)(logical_index / layout->width);
    return fw_led_map_logical_xy(layout, x, y, out);
}
