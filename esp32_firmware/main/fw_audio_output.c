#include "fw_audio_output.h"

#include <string.h>
#include "driver/i2s.h"
#include "esp_log.h"

static const char *TAG = "fw_audio";

#define I2S_NUM  I2S_NUM_0

static bool s_initialized = false;
static bool s_active = false;
static uint32_t s_sample_rate = 22050;

esp_err_t fw_audio_output_init(const fw_audio_config_t *config) {
    if (s_initialized) return ESP_ERR_INVALID_STATE;

    s_sample_rate = config->sample_rate;

    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_TX | I2S_MODE_DAC_BUILT_IN,
        .sample_rate = config->sample_rate,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,  // Required for built-in DAC
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,   // DAC needs stereo format
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = (int)config->dma_buf_count,
        .dma_buf_len = (int)config->dma_buf_len,
        .use_apll = false,
        .tx_desc_auto_clear = true,  // Auto-clear DMA buffer on underflow (outputs silence)
    };

    esp_err_t ret = i2s_driver_install(I2S_NUM, &i2s_config, 0, NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_driver_install failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Enable DAC output on channel 1 (GPIO25) only
    ret = i2s_set_dac_mode(I2S_DAC_CHANNEL_RIGHT_EN);  // GPIO25 = right channel = DAC1
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_set_dac_mode failed: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Audio output initialized: %lu Hz, 8-bit DAC on GPIO25",
             (unsigned long)config->sample_rate);
    return ESP_OK;
}

esp_err_t fw_audio_output_start(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (s_active) return ESP_OK;

    esp_err_t ret = i2s_start(I2S_NUM);
    if (ret != ESP_OK) return ret;

    s_active = true;
    ESP_LOGI(TAG, "Audio output started");
    return ESP_OK;
}

esp_err_t fw_audio_output_stop(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (!s_active) return ESP_OK;

    // Write a short silence buffer to flush
    uint8_t silence[64];
    memset(silence, 128, sizeof(silence));
    fw_audio_output_push(silence, sizeof(silence), 100);

    esp_err_t ret = i2s_stop(I2S_NUM);
    if (ret != ESP_OK) return ret;

    s_active = false;
    ESP_LOGI(TAG, "Audio output stopped");
    return ESP_OK;
}

esp_err_t fw_audio_output_push(const uint8_t *samples, size_t count, uint32_t timeout_ms) {
    if (!s_initialized || !s_active) return ESP_ERR_INVALID_STATE;
    if (count == 0) return ESP_OK;

    // The built-in DAC expects 16-bit samples in a specific format:
    // For I2S_DAC_CHANNEL_RIGHT_EN (GPIO25), the 8-bit sample goes into
    // the high byte of the right channel (16-bit stereo frame).
    //
    // I2S built-in DAC format per stereo frame (4 bytes):
    //   [left_high, left_low, right_high, right_low]
    // We write to right channel (DAC1/GPIO25): sample in right_high byte.
    //
    // Process in chunks to limit stack usage.

    #define CHUNK_SAMPLES 128
    uint16_t buf[CHUNK_SAMPLES * 2];  // stereo: 2 x 16-bit per sample

    size_t offset = 0;
    while (offset < count) {
        size_t chunk = count - offset;
        if (chunk > CHUNK_SAMPLES) chunk = CHUNK_SAMPLES;

        for (size_t i = 0; i < chunk; i++) {
            uint16_t sample16 = (uint16_t)samples[offset + i] << 8;
            buf[i * 2] = 0;             // left channel = silent
            buf[i * 2 + 1] = sample16;  // right channel = our sample
        }

        size_t bytes_written = 0;
        esp_err_t ret = i2s_write(I2S_NUM, buf, chunk * 4, &bytes_written,
                                  pdMS_TO_TICKS(timeout_ms));
        if (ret != ESP_OK) return ret;

        offset += chunk;
    }

    return ESP_OK;
    #undef CHUNK_SAMPLES
}

bool fw_audio_output_is_active(void) {
    return s_active;
}

uint32_t fw_audio_output_get_sample_rate(void) {
    return s_sample_rate;
}
