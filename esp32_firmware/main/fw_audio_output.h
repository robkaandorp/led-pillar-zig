#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/**
 * Audio output configuration.
 */
typedef struct {
    uint32_t sample_rate;  // e.g. 22050
    size_t dma_buf_count;  // Number of DMA buffers (e.g. 4)
    size_t dma_buf_len;    // Samples per DMA buffer (e.g. 256)
} fw_audio_config_t;

/**
 * Default audio configuration: 22050 Hz, 16 DMA buffers x 64 samples.
 *
 * Native shaders generate audio once per video frame (~40 Hz). Smaller DMA
 * buffers reduce startup glitches because the producer doesn't have to land on
 * large, partially filled descriptors before the queue settles.
 */
#define FW_AUDIO_CONFIG_DEFAULT() { \
    .sample_rate = 22050, \
    .dma_buf_count = 16, \
    .dma_buf_len = 64, \
}

/**
 * Initialize the DAC asynchronous DMA driver on GPIO25 (DAC channel 0).
 * DMA runs continuously in a ring, outputting midscale silence (0x80) until
 * audio samples are pushed.  A fill task on core 0 bridges between the
 * render-loop push calls and the ISR-driven DMA buffer refill.
 */
esp_err_t fw_audio_output_init(const fw_audio_config_t *config);

/**
 * Start audio output. DAC begins outputting silence (0x80).
 */
esp_err_t fw_audio_output_start(void);

/**
 * Stop audio output. DAC goes idle.
 */
esp_err_t fw_audio_output_stop(void);

/**
 * Push audio samples to the DAC DMA buffer.
 * @param samples  Array of unsigned 8-bit PCM samples [0..255], where 128 = silence
 * @param count    Number of samples
 * @param timeout_ms  Maximum time to wait if buffer is full
 * @return ESP_OK on success
 *
 * This function blocks until all samples are written or timeout expires.
 * Samples may be queued before start; starting playback begins consuming the
 * already queued PCM stream immediately.
 */
esp_err_t fw_audio_output_push(const uint8_t *samples, size_t count, uint32_t timeout_ms);

/**
 * Push midscale silence (0x80) into the DAC DMA buffer.
 */
esp_err_t fw_audio_output_push_silence(size_t count, uint32_t timeout_ms);

/**
 * Check if audio output is currently active (started and not stopped).
 */
bool fw_audio_output_is_active(void);

/**
 * Get the configured sample rate.
 */
uint32_t fw_audio_output_get_sample_rate(void);
