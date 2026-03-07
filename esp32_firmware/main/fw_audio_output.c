#include "fw_audio_output.h"

#include <string.h>
#include "driver/i2s.h"
#include "esp_log.h"

static const char *TAG = "fw_audio";

#define I2S_NUM  I2S_NUM_0

static bool s_initialized = false;
static bool s_active = false;
static uint32_t s_sample_rate = 22050;

static esp_err_t fw_audio_output_write_raw(const uint8_t *samples, size_t count, uint32_t timeout_ms) {
    if (count == 0) return ESP_OK;

    #define CHUNK_SAMPLES 512
    uint16_t buf[CHUNK_SAMPLES];

    size_t offset = 0;
    while (offset < count) {
        size_t chunk = count - offset;
        if (chunk > CHUNK_SAMPLES) chunk = CHUNK_SAMPLES;

        for (size_t i = 0; i < chunk; i++) {
            buf[i] = (uint16_t)samples[offset + i] << 8;
        }

        size_t bytes_written = 0;
        esp_err_t ret = i2s_write(I2S_NUM, buf, chunk * sizeof(uint16_t), &bytes_written,
                                  pdMS_TO_TICKS(timeout_ms));
        if (ret != ESP_OK) return ret;
        if (bytes_written != chunk * sizeof(uint16_t)) return ESP_ERR_TIMEOUT;

        offset += chunk;
    }

    return ESP_OK;
    #undef CHUNK_SAMPLES
}

static esp_err_t fw_audio_output_prime_silence(size_t sample_count, uint32_t timeout_ms) {
    uint8_t silence[128];
    memset(silence, 128, sizeof(silence));

    size_t remaining = sample_count;
    while (remaining > 0) {
        const size_t chunk = remaining < sizeof(silence) ? remaining : sizeof(silence);
        esp_err_t ret = fw_audio_output_write_raw(silence, chunk, timeout_ms);
        if (ret != ESP_OK) return ret;
        remaining -= chunk;
    }
    return ESP_OK;
}

esp_err_t fw_audio_output_init(const fw_audio_config_t *config) {
    if (s_initialized) return ESP_ERR_INVALID_STATE;

    s_sample_rate = config->sample_rate;

    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_TX | I2S_MODE_DAC_BUILT_IN,
        .sample_rate = config->sample_rate,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = (int)config->dma_buf_count,
        .dma_buf_len = (int)config->dma_buf_len,
        .use_apll = false,
        .tx_desc_auto_clear = true,
    };

    esp_err_t ret = i2s_driver_install(I2S_NUM, &i2s_config, 0, NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_driver_install failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = i2s_set_pin(I2S_NUM, NULL);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_set_pin failed: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    ret = i2s_set_dac_mode(I2S_DAC_CHANNEL_RIGHT_EN);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_set_dac_mode failed: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    ret = i2s_set_clk(I2S_NUM, config->sample_rate, I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_MONO);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_set_clk failed: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    ret = i2s_start(I2S_NUM);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "i2s_start failed during init: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    ret = fw_audio_output_prime_silence(config->dma_buf_count * config->dma_buf_len, 100);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "prime silence failed during init: %s", esp_err_to_name(ret));
        i2s_driver_uninstall(I2S_NUM);
        return ret;
    }

    s_initialized = true;
    s_active = true;
    ESP_LOGI(TAG, "Audio output initialized: %lu Hz, 8-bit DAC on GPIO25 (held at silence)",
             (unsigned long)config->sample_rate);
    return ESP_OK;
}

esp_err_t fw_audio_output_start(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (s_active) return ESP_OK;

    esp_err_t ret = i2s_start(I2S_NUM);
    if (ret != ESP_OK) return ret;

    ret = fw_audio_output_prime_silence(256, 100);
    if (ret != ESP_OK) return ret;

    s_active = true;
    ESP_LOGI(TAG, "Audio output started");
    return ESP_OK;
}

esp_err_t fw_audio_output_stop(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (!s_active) return ESP_OK;

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
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    return fw_audio_output_write_raw(samples, count, timeout_ms);
}

esp_err_t fw_audio_output_push_silence(size_t count, uint32_t timeout_ms) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    return fw_audio_output_prime_silence(count, timeout_ms);
}

bool fw_audio_output_is_active(void) {
    return s_active;
}

uint32_t fw_audio_output_get_sample_rate(void) {
    return s_sample_rate;
}
