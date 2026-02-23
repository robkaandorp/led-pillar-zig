#include "fw_led_output.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "driver/rmt_encoder.h"
#include "esp_log.h"
#include "sdkconfig.h"
#include "soc/soc_caps.h"

static const char *TAG = "fw_led_out";

#ifdef CONFIG_FW_LED_GAMMA_X100
#define FW_LED_GAMMA_X100_DEFAULT CONFIG_FW_LED_GAMMA_X100
#else
#define FW_LED_GAMMA_X100_DEFAULT 280
#endif

#define FW_RMT_RESOLUTION_HZ (10U * 1000U * 1000U)
#define FW_RMT_MEM_BLOCK_SYMBOLS 256U
#define FW_RMT_QUEUE_DEPTH 2U
#define FW_CONTAINER_OF(ptr, type, member) ((type *)((char *)(ptr)-offsetof(type, member)))

typedef struct {
    rmt_encoder_t base;
    rmt_encoder_handle_t bytes_encoder;
    rmt_encoder_handle_t copy_encoder;
    int state;
    rmt_symbol_word_t reset_code;
} fw_led_rmt_encoder_t;

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

static size_t fw_led_rmt_encode(
    rmt_encoder_t *encoder,
    rmt_channel_handle_t channel,
    const void *primary_data,
    size_t data_size,
    rmt_encode_state_t *ret_state
) {
    fw_led_rmt_encoder_t *led_encoder = FW_CONTAINER_OF(encoder, fw_led_rmt_encoder_t, base);
    rmt_encode_state_t session_state = RMT_ENCODING_RESET;
    rmt_encode_state_t state = RMT_ENCODING_RESET;
    size_t encoded_symbols = 0;

    switch (led_encoder->state) {
        case 0:
            encoded_symbols += led_encoder->bytes_encoder->encode(
                led_encoder->bytes_encoder,
                channel,
                primary_data,
                data_size,
                &session_state
            );
            if ((session_state & RMT_ENCODING_COMPLETE) != 0) {
                led_encoder->state = 1;
            }
            if ((session_state & RMT_ENCODING_MEM_FULL) != 0) {
                state |= RMT_ENCODING_MEM_FULL;
                *ret_state = state;
                return encoded_symbols;
            }
            // fallthrough
        case 1:
            encoded_symbols += led_encoder->copy_encoder->encode(
                led_encoder->copy_encoder,
                channel,
                &led_encoder->reset_code,
                sizeof(led_encoder->reset_code),
                &session_state
            );
            if ((session_state & RMT_ENCODING_COMPLETE) != 0) {
                led_encoder->state = 0;
                state |= RMT_ENCODING_COMPLETE;
            }
            if ((session_state & RMT_ENCODING_MEM_FULL) != 0) {
                state |= RMT_ENCODING_MEM_FULL;
            }
            break;
        default:
            state |= RMT_ENCODING_COMPLETE;
            led_encoder->state = 0;
            break;
    }

    *ret_state = state;
    return encoded_symbols;
}

static esp_err_t fw_led_rmt_encoder_del(rmt_encoder_t *encoder) {
    fw_led_rmt_encoder_t *led_encoder = FW_CONTAINER_OF(encoder, fw_led_rmt_encoder_t, base);
    if (led_encoder->bytes_encoder != NULL) {
        (void)rmt_del_encoder(led_encoder->bytes_encoder);
    }
    if (led_encoder->copy_encoder != NULL) {
        (void)rmt_del_encoder(led_encoder->copy_encoder);
    }
    free(led_encoder);
    return ESP_OK;
}

static esp_err_t fw_led_rmt_encoder_reset(rmt_encoder_t *encoder) {
    fw_led_rmt_encoder_t *led_encoder = FW_CONTAINER_OF(encoder, fw_led_rmt_encoder_t, base);
    (void)rmt_encoder_reset(led_encoder->bytes_encoder);
    (void)rmt_encoder_reset(led_encoder->copy_encoder);
    led_encoder->state = 0;
    return ESP_OK;
}

static esp_err_t fw_led_new_rmt_encoder(uint32_t resolution_hz, rmt_encoder_handle_t *out_encoder) {
    if (out_encoder == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    fw_led_rmt_encoder_t *encoder = (fw_led_rmt_encoder_t *)calloc(1U, sizeof(fw_led_rmt_encoder_t));
    if (encoder == NULL) {
        return ESP_ERR_NO_MEM;
    }

    encoder->base.encode = fw_led_rmt_encode;
    encoder->base.del = fw_led_rmt_encoder_del;
    encoder->base.reset = fw_led_rmt_encoder_reset;

    rmt_bytes_encoder_config_t bytes_config = {
        .bit0 =
            {
                .level0 = 1,
                .duration0 = (uint16_t)(0.3f * (float)resolution_hz / 1000000.0f),
                .level1 = 0,
                .duration1 = (uint16_t)(0.9f * (float)resolution_hz / 1000000.0f),
            },
        .bit1 =
            {
                .level0 = 1,
                .duration0 = (uint16_t)(0.9f * (float)resolution_hz / 1000000.0f),
                .level1 = 0,
                .duration1 = (uint16_t)(0.3f * (float)resolution_hz / 1000000.0f),
            },
        .flags.msb_first = 1,
    };
    esp_err_t err = rmt_new_bytes_encoder(&bytes_config, &encoder->bytes_encoder);
    if (err != ESP_OK) {
        free(encoder);
        return err;
    }

    rmt_copy_encoder_config_t copy_config = {};
    err = rmt_new_copy_encoder(&copy_config, &encoder->copy_encoder);
    if (err != ESP_OK) {
        (void)rmt_del_encoder(encoder->bytes_encoder);
        free(encoder);
        return err;
    }

    const uint32_t reset_ticks = (resolution_hz / 1000000U) * 50U / 2U;
    encoder->reset_code = (rmt_symbol_word_t){
        .level0 = 0,
        .duration0 = (uint16_t)reset_ticks,
        .level1 = 0,
        .duration1 = (uint16_t)reset_ticks,
    };

    *out_encoder = &encoder->base;
    return ESP_OK;
}

static esp_err_t fw_led_output_wait_pending(fw_led_output_t *driver) {
    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        if (driver->channels[segment] != NULL) {
            esp_err_t wait_err = rmt_tx_wait_all_done(driver->channels[segment], -1);
            if (wait_err != ESP_OK) {
                return wait_err;
            }
        }
        segment += 1U;
    }

#if SOC_RMT_SUPPORT_TX_SYNCHRO
    if (driver->sync_manager != NULL && driver->sync_needs_reset) {
        esp_err_t sync_err = rmt_sync_reset(driver->sync_manager);
        if (sync_err != ESP_OK) {
            return sync_err;
        }
        driver->sync_needs_reset = false;
    }
#endif

    driver->slot_in_flight[0] = false;
    driver->slot_in_flight[1] = false;
    return ESP_OK;
}

static esp_err_t fw_led_output_prepare_slot_from_frame(
    fw_led_output_t *driver,
    uint8_t slot,
    const uint8_t *frame_buffer,
    uint8_t pixel_format,
    uint8_t bytes_per_pixel
) {
    uint32_t global_led_index = 0U;
    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        uint8_t *segment_buffer = driver->segment_buffers[segment][slot];
        const uint16_t segment_led_count = driver->layout.segments[segment].led_count;
        if (segment_buffer == NULL) {
            return ESP_ERR_INVALID_STATE;
        }

        uint16_t led_index = 0U;
        while (led_index < segment_led_count) {
            const size_t src_offset = (size_t)(global_led_index + led_index) * bytes_per_pixel;
            const size_t dst_offset = (size_t)led_index * 3U;

            uint8_t r = 0U;
            uint8_t g = 0U;
            uint8_t b = 0U;
            if (pixel_format == 0U && bytes_per_pixel == 3U) {
                r = frame_buffer[src_offset];
                g = frame_buffer[src_offset + 1U];
                b = frame_buffer[src_offset + 2U];
            } else {
                uint8_t w = 0U;
                fw_led_unpack_pixel(pixel_format, frame_buffer + src_offset, &r, &g, &b, &w);
                if (bytes_per_pixel == 4U && w > 0U) {
                    r = fw_led_saturating_add(r, w);
                    g = fw_led_saturating_add(g, w);
                    b = fw_led_saturating_add(b, w);
                }
            }

            segment_buffer[dst_offset + 0U] = driver->gamma_lut[g];
            segment_buffer[dst_offset + 1U] = driver->gamma_lut[r];
            segment_buffer[dst_offset + 2U] = driver->gamma_lut[b];
            led_index += 1U;
        }

        global_led_index += segment_led_count;
        segment += 1U;
    }
    return ESP_OK;
}

static esp_err_t fw_led_output_prepare_slot_uniform(
    fw_led_output_t *driver,
    uint8_t slot,
    uint8_t corrected_r,
    uint8_t corrected_g,
    uint8_t corrected_b
) {
    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        uint8_t *segment_buffer = driver->segment_buffers[segment][slot];
        const uint16_t segment_led_count = driver->layout.segments[segment].led_count;
        if (segment_buffer == NULL) {
            return ESP_ERR_INVALID_STATE;
        }

        uint16_t led_index = 0U;
        while (led_index < segment_led_count) {
            const size_t dst_offset = (size_t)led_index * 3U;
            segment_buffer[dst_offset + 0U] = corrected_g;
            segment_buffer[dst_offset + 1U] = corrected_r;
            segment_buffer[dst_offset + 2U] = corrected_b;
            led_index += 1U;
        }
        segment += 1U;
    }
    return ESP_OK;
}

static esp_err_t fw_led_output_transmit_slot(fw_led_output_t *driver, uint8_t slot) {
    const rmt_transmit_config_t transmit_config = {
        .loop_count = 0,
        .flags = {0},
    };

    uint8_t segment = 0U;
    while (segment < driver->layout.segment_count) {
        if (driver->channels[segment] == NULL || driver->encoders[segment] == NULL) {
            return ESP_ERR_INVALID_STATE;
        }
        const uint8_t *segment_buffer = driver->segment_buffers[segment][slot];
        if (segment_buffer == NULL) {
            return ESP_ERR_INVALID_STATE;
        }
        esp_err_t tx_err = rmt_transmit(
            driver->channels[segment],
            driver->encoders[segment],
            segment_buffer,
            driver->segment_buffer_len[segment],
            &transmit_config
        );
        if (tx_err != ESP_OK) {
            return tx_err;
        }
        segment += 1U;
    }

    driver->slot_in_flight[slot] = true;
    driver->sync_needs_reset = true;
    return ESP_OK;
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
        const uint16_t led_count = driver->layout.segments[segment].led_count;
        const size_t segment_bytes = (size_t)led_count * 3U;
        driver->segment_buffer_len[segment] = segment_bytes;
        driver->segment_buffers[segment][0] = (uint8_t *)malloc(segment_bytes);
        driver->segment_buffers[segment][1] = (uint8_t *)malloc(segment_bytes);
        if (driver->segment_buffers[segment][0] == NULL || driver->segment_buffers[segment][1] == NULL) {
            fw_led_output_deinit(driver);
            return ESP_ERR_NO_MEM;
        }

        rmt_tx_channel_config_t tx_config = {
            .gpio_num = driver->layout.segments[segment].gpio,
            .clk_src = RMT_CLK_SRC_DEFAULT,
            .resolution_hz = FW_RMT_RESOLUTION_HZ,
            .mem_block_symbols = FW_RMT_MEM_BLOCK_SYMBOLS,
            .trans_queue_depth = FW_RMT_QUEUE_DEPTH,
            .intr_priority = 0,
            .flags = {0},
        };
        esp_err_t chan_err = rmt_new_tx_channel(&tx_config, &driver->channels[segment]);
        if (chan_err != ESP_OK) {
            ESP_LOGE(TAG, "segment %u channel init failed: %s", segment, esp_err_to_name(chan_err));
            fw_led_output_deinit(driver);
            return chan_err;
        }

        esp_err_t enc_err = fw_led_new_rmt_encoder(FW_RMT_RESOLUTION_HZ, &driver->encoders[segment]);
        if (enc_err != ESP_OK) {
            ESP_LOGE(TAG, "segment %u encoder init failed: %s", segment, esp_err_to_name(enc_err));
            fw_led_output_deinit(driver);
            return enc_err;
        }

        esp_err_t enable_err = rmt_enable(driver->channels[segment]);
        if (enable_err != ESP_OK) {
            ESP_LOGE(TAG, "segment %u channel enable failed: %s", segment, esp_err_to_name(enable_err));
            fw_led_output_deinit(driver);
            return enable_err;
        }
        segment += 1U;
    }

#if SOC_RMT_SUPPORT_TX_SYNCHRO
    if (driver->layout.segment_count > 1U) {
        rmt_sync_manager_config_t sync_config = {
            .tx_channel_array = driver->channels,
            .array_size = driver->layout.segment_count,
        };
        esp_err_t sync_err = rmt_new_sync_manager(&sync_config, &driver->sync_manager);
        if (sync_err != ESP_OK) {
            driver->sync_manager = NULL;
            ESP_LOGW(TAG, "sync manager unavailable; continuing without channel sync: %s", esp_err_to_name(sync_err));
        }
    }
#endif

    driver->initialized = true;
    ESP_LOGI(TAG, "gamma correction configured: %u.%02u", driver->gamma_x100 / 100U, driver->gamma_x100 % 100U);
    return ESP_OK;
}

void fw_led_output_deinit(fw_led_output_t *driver) {
    if (driver == NULL) {
        return;
    }

    if (driver->initialized) {
        (void)fw_led_output_wait_pending(driver);
    }

#if SOC_RMT_SUPPORT_TX_SYNCHRO
    if (driver->sync_manager != NULL) {
        (void)rmt_del_sync_manager(driver->sync_manager);
        driver->sync_manager = NULL;
    }
#endif

    uint8_t segment = 0U;
    while (segment < FW_LED_MAX_SEGMENTS) {
        if (driver->encoders[segment] != NULL) {
            (void)rmt_del_encoder(driver->encoders[segment]);
            driver->encoders[segment] = NULL;
        }
        if (driver->channels[segment] != NULL) {
            (void)rmt_disable(driver->channels[segment]);
            (void)rmt_del_channel(driver->channels[segment]);
            driver->channels[segment] = NULL;
        }
        free(driver->segment_buffers[segment][0]);
        free(driver->segment_buffers[segment][1]);
        driver->segment_buffers[segment][0] = NULL;
        driver->segment_buffers[segment][1] = NULL;
        driver->segment_buffer_len[segment] = 0U;
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

    esp_err_t wait_err = fw_led_output_wait_pending(driver);
    if (wait_err != ESP_OK) {
        return wait_err;
    }
    const uint8_t slot = driver->next_slot;

    esp_err_t prep_err = fw_led_output_prepare_slot_from_frame(driver, slot, frame_buffer, pixel_format, bytes_per_pixel);
    if (prep_err != ESP_OK) {
        return prep_err;
    }
    esp_err_t tx_err = fw_led_output_transmit_slot(driver, slot);
    if (tx_err != ESP_OK) {
        return tx_err;
    }
    esp_err_t done_err = fw_led_output_wait_pending(driver);
    if (done_err != ESP_OK) {
        return done_err;
    }

    driver->next_slot = (uint8_t)(slot ^ 1U);
    return ESP_OK;
}

esp_err_t fw_led_output_push_uniform_rgb(fw_led_output_t *driver, uint8_t r, uint8_t g, uint8_t b) {
    if (driver == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!driver->initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint8_t corrected_r = driver->gamma_lut[r];
    const uint8_t corrected_g = driver->gamma_lut[g];
    const uint8_t corrected_b = driver->gamma_lut[b];

    esp_err_t wait_err = fw_led_output_wait_pending(driver);
    if (wait_err != ESP_OK) {
        return wait_err;
    }
    const uint8_t slot = driver->next_slot;

    esp_err_t prep_err = fw_led_output_prepare_slot_uniform(driver, slot, corrected_r, corrected_g, corrected_b);
    if (prep_err != ESP_OK) {
        return prep_err;
    }
    esp_err_t tx_err = fw_led_output_transmit_slot(driver, slot);
    if (tx_err != ESP_OK) {
        return tx_err;
    }
    esp_err_t done_err = fw_led_output_wait_pending(driver);
    if (done_err != ESP_OK) {
        return done_err;
    }

    driver->next_slot = (uint8_t)(slot ^ 1U);
    return ESP_OK;
}
