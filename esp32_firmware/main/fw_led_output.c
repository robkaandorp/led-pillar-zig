#include "fw_led_output.h"

#include <math.h>
#include <string.h>

#include "esp_log.h"
#include "sdkconfig.h"

static const char *TAG = "fw_led_out";

#ifdef CONFIG_FW_LED_GAMMA_X100
#define FW_LED_GAMMA_X100_DEFAULT CONFIG_FW_LED_GAMMA_X100
#else
#define FW_LED_GAMMA_X100_DEFAULT 280
#endif

static uint8_t fw_led_saturating_add(uint8_t lhs, uint8_t rhs) {
    const uint16_t sum = (uint16_t)lhs + (uint16_t)rhs;
    return (sum > UINT8_MAX) ? UINT8_MAX : (uint8_t)sum;
}

static void fw_led_build_gamma_lut(fw_led_output_t *driver, uint16_t gamma_x100) {
    driver->gamma_x100 = gamma_x100;
    if (gamma_x100 == 100U) {
        for (uint16_t i = 0; i < 256U; i += 1U) {
            driver->gamma_lut[i] = (uint8_t)i;
        }
        return;
    }

    const float gamma = (float)gamma_x100 / 100.0f;
    for (uint16_t i = 0; i < 256U; i += 1U) {
        const float normalized = (float)i / 255.0f;
        const float corrected = powf(normalized, gamma);
        int corrected_u8 = (int)lroundf(corrected * 255.0f);
        if (corrected_u8 < 0) {
            corrected_u8 = 0;
        } else if (corrected_u8 > 255) {
            corrected_u8 = 255;
        }
        driver->gamma_lut[i] = (uint8_t)corrected_u8;
    }
}

static void fw_led_unpack_pixel(uint8_t pixel_format, const uint8_t *pixel, uint8_t *r, uint8_t *g, uint8_t *b, uint8_t *w) {
    *w = 0U;
    switch (pixel_format) {
        case 1U:  // RGBW
            *r = pixel[0];
            *g = pixel[1];
            *b = pixel[2];
            *w = pixel[3];
            return;
        case 2U:  // GRB
            *g = pixel[0];
            *r = pixel[1];
            *b = pixel[2];
            return;
        case 3U:  // GRBW
            *g = pixel[0];
            *r = pixel[1];
            *b = pixel[2];
            *w = pixel[3];
            return;
        case 4U:  // BGR
            *b = pixel[0];
            *g = pixel[1];
            *r = pixel[2];
            return;
        case 0U:  // RGB
        default:
            *r = pixel[0];
            *g = pixel[1];
            *b = pixel[2];
            return;
    }
}

esp_err_t fw_led_output_init(fw_led_output_t *driver, const fw_led_layout_config_t *layout) {
    if (driver == NULL || layout == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (driver->initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t layout_err = fw_led_layout_validate(layout);
    if (layout_err != ESP_OK) {
        return layout_err;
    }

    memset(driver, 0, sizeof(*driver));
    driver->layout = *layout;
    fw_led_build_gamma_lut(driver, FW_LED_GAMMA_X100_DEFAULT);

    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        led_strip_config_t strip_config = {
            .strip_gpio_num = driver->layout.segments[segment].gpio,
            .max_leds = driver->layout.segments[segment].led_count,
        };
#if defined(LED_MODEL_WS2812)
        strip_config.led_model = LED_MODEL_WS2812;
#endif

        led_strip_rmt_config_t rmt_config = {
            .resolution_hz = 10 * 1000 * 1000,
        };
#if defined(RMT_CLK_SRC_DEFAULT)
        rmt_config.clk_src = RMT_CLK_SRC_DEFAULT;
#endif

        esp_err_t err = led_strip_new_rmt_device(&strip_config, &rmt_config, &driver->segments[segment]);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "segment %u init failed: %s", segment, esp_err_to_name(err));
            fw_led_output_deinit(driver);
            return err;
        }

        err = led_strip_clear(driver->segments[segment]);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "segment %u clear failed: %s", segment, esp_err_to_name(err));
            fw_led_output_deinit(driver);
            return err;
        }

        segment += 1U;
    }

    driver->initialized = true;
    ESP_LOGI(TAG, "gamma correction configured: %u.%02u", driver->gamma_x100 / 100U, driver->gamma_x100 % 100U);
    return ESP_OK;
}

void fw_led_output_deinit(fw_led_output_t *driver) {
    if (driver == NULL) {
        return;
    }

    uint8_t segment = 0U;
    while (segment < FW_LED_MAX_SEGMENTS) {
        if (driver->segments[segment] != NULL) {
            (void)led_strip_clear(driver->segments[segment]);
            (void)led_strip_del(driver->segments[segment]);
            driver->segments[segment] = NULL;
        }
        segment += 1U;
    }

    memset(driver, 0, sizeof(*driver));
}

esp_err_t fw_led_output_push_frame(
    fw_led_output_t *driver,
    const uint8_t *frame_buffer,
    size_t frame_buffer_len,
    uint8_t pixel_format,
    uint8_t bytes_per_pixel
) {
    if (driver == NULL || frame_buffer == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!driver->initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    if (bytes_per_pixel != 3U && bytes_per_pixel != 4U) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint32_t total_leds = fw_led_layout_total_leds(&driver->layout);
    if (total_leds > (SIZE_MAX / bytes_per_pixel)) {
        return ESP_ERR_INVALID_SIZE;
    }
    const size_t expected_len = (size_t)total_leds * bytes_per_pixel;
    if (frame_buffer_len < expected_len) {
        return ESP_ERR_INVALID_SIZE;
    }

    uint32_t global_led_index = 0U;
    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        led_strip_handle_t strip = driver->segments[segment];
        if (strip == NULL) {
            return ESP_ERR_INVALID_STATE;
        }

        const uint16_t segment_led_count = driver->layout.segments[segment].led_count;
        uint16_t led_index = 0U;
        while (led_index < segment_led_count) {
            const size_t src_offset = (size_t)(global_led_index + led_index) * bytes_per_pixel;
            uint8_t r = 0U;
            uint8_t g = 0U;
            uint8_t b = 0U;
            uint8_t w = 0U;
            fw_led_unpack_pixel(pixel_format, frame_buffer + src_offset, &r, &g, &b, &w);
            if (bytes_per_pixel == 4U && w > 0U) {
                r = fw_led_saturating_add(r, w);
                g = fw_led_saturating_add(g, w);
                b = fw_led_saturating_add(b, w);
            }
            r = driver->gamma_lut[r];
            g = driver->gamma_lut[g];
            b = driver->gamma_lut[b];

            esp_err_t set_err = led_strip_set_pixel(strip, led_index, r, g, b);
            if (set_err != ESP_OK) {
                return set_err;
            }
            led_index += 1U;
        }

        esp_err_t refresh_err = led_strip_refresh(strip);
        if (refresh_err != ESP_OK) {
            return refresh_err;
        }

        global_led_index += segment_led_count;
        segment += 1U;
    }

    return ESP_OK;
}
