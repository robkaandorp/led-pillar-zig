#include "fw_audio_output.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "driver/dac_continuous.h"
#include "esp_log.h"
#include "esp_attr.h"

static const char *TAG = "fw_audio";

static dac_continuous_handle_t s_dac_handle = NULL;
static bool s_initialized = false;
static bool s_active = false;
static uint32_t s_sample_rate = 22050;

/* DMA configuration: 8 descriptors × 256 bytes each.
 * With CONFIG_DAC_DMA_AUTO_16BIT_ALIGN each 8-bit input sample expands to
 * 2 bytes, so each descriptor holds 128 samples.  Total buffering is
 * 1024 samples ≈ 46 ms at 22050 Hz. */
#define DAC_DESC_NUM  8
#define DAC_BUF_SIZE  256

/* --- Lock-free SPSC ring buffer (single producer, single consumer) ---
 * Producer: render task (fw_audio_output_push / push_silence).
 * Consumer: DMA ISR callback (on_convert_done via audio_fill_task).
 * Ring capacity must be a power of two for fast modulo. */
#define RING_SIZE_SHIFT  12
#define RING_SIZE        (1U << RING_SIZE_SHIFT)   /* 4096 samples ≈ 186 ms */
#define RING_MASK        (RING_SIZE - 1U)

static uint8_t  s_ring[RING_SIZE];
static volatile uint32_t s_ring_wr = 0;  /* written by producer only */
static volatile uint32_t s_ring_rd = 0;  /* written by consumer only */

#define MIDSCALE 128

static inline uint32_t ring_readable(void) {
    return s_ring_wr - s_ring_rd;
}

static inline uint32_t ring_writable(void) {
    return RING_SIZE - ring_readable();
}

/* Queue transports DMA event data from ISR to the audio fill task. */
static QueueHandle_t s_evt_queue = NULL;

/* Task handle for the DMA buffer fill task. */
static TaskHandle_t s_fill_task = NULL;

/* ISR callback: DMA finished a buffer; forward the event to our fill task. */
static bool IRAM_ATTR on_convert_done(dac_continuous_handle_t handle,
                                      const dac_event_data_t *event,
                                      void *user_data)
{
    BaseType_t need_wake = pdFALSE;
    BaseType_t tmp = pdFALSE;
    QueueHandle_t q = (QueueHandle_t)user_data;
    if (xQueueIsQueueFullFromISR(q)) {
        dac_event_data_t dummy;
        xQueueReceiveFromISR(q, &dummy, &tmp);
        need_wake |= tmp;
    }
    xQueueSendFromISR(q, event, &tmp);
    need_wake |= tmp;
    return need_wake;
}

/* Task that refills DMA buffers from the ring buffer (runs on core 0). */
static void audio_fill_task(void *arg)
{
    dac_continuous_handle_t handle = (dac_continuous_handle_t)arg;
    dac_event_data_t evt;

    for (;;) {
        if (xQueueReceive(s_evt_queue, &evt, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        /* How many 8-bit samples fit in this DMA buffer?
         * With AUTO_16BIT_ALIGN the DMA buffer is 16-bit wide so each
         * sample occupies 2 bytes → capacity = buf_size / 2. */
        size_t capacity = evt.buf_size / 2;
        uint32_t avail = ring_readable();
        size_t n = avail < capacity ? avail : capacity;

        if (n > 0) {
            /* Build a temporary 8-bit source buffer from the ring. */
            uint8_t tmp[DAC_BUF_SIZE / 2];
            uint32_t rd = s_ring_rd;
            for (size_t i = 0; i < n; i++) {
                tmp[i] = s_ring[(rd + i) & RING_MASK];
            }
            s_ring_rd = rd + n;
            /* Fill remaining capacity with midscale silence. */
            if (n < capacity) {
                memset(tmp + n, MIDSCALE, capacity - n);
            }
            dac_continuous_write_asynchronously(handle, evt.buf, evt.buf_size,
                                               tmp, capacity, NULL);
        } else {
            /* Ring empty → output silence. */
            uint8_t silence[DAC_BUF_SIZE / 2];
            memset(silence, MIDSCALE, sizeof(silence));
            dac_continuous_write_asynchronously(handle, evt.buf, evt.buf_size,
                                               silence, capacity, NULL);
        }
    }
}

esp_err_t fw_audio_output_init(const fw_audio_config_t *config) {
    if (s_initialized) return ESP_ERR_INVALID_STATE;

    s_sample_rate = config->sample_rate;

    /* Pre-fill ring with silence. */
    memset(s_ring, MIDSCALE, sizeof(s_ring));
    s_ring_wr = 0;
    s_ring_rd = 0;

    dac_continuous_config_t cont_cfg = {
        .chan_mask = DAC_CHANNEL_MASK_CH0,
        .desc_num = DAC_DESC_NUM,
        .buf_size = DAC_BUF_SIZE,
        .freq_hz  = config->sample_rate,
        .offset   = 0,
        .clk_src  = DAC_DIGI_CLK_SRC_APLL,
        .chan_mode = DAC_CHANNEL_MODE_SIMUL,
    };

    esp_err_t ret = dac_continuous_new_channels(&cont_cfg, &s_dac_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "dac_continuous_new_channels failed: %s", esp_err_to_name(ret));
        return ret;
    }

    /* Create event queue and register async callback. */
    s_evt_queue = xQueueCreate(DAC_DESC_NUM, sizeof(dac_event_data_t));
    if (!s_evt_queue) {
        ESP_LOGE(TAG, "failed to create event queue");
        dac_continuous_del_channels(s_dac_handle);
        s_dac_handle = NULL;
        return ESP_ERR_NO_MEM;
    }

    dac_event_callbacks_t cbs = {
        .on_convert_done = on_convert_done,
        .on_stop = NULL,
    };
    ret = dac_continuous_register_event_callback(s_dac_handle, &cbs, s_evt_queue);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "register callback failed: %s", esp_err_to_name(ret));
        vQueueDelete(s_evt_queue);
        s_evt_queue = NULL;
        dac_continuous_del_channels(s_dac_handle);
        s_dac_handle = NULL;
        return ret;
    }

    ret = dac_continuous_enable(s_dac_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "dac_continuous_enable failed: %s", esp_err_to_name(ret));
        vQueueDelete(s_evt_queue);
        s_evt_queue = NULL;
        dac_continuous_del_channels(s_dac_handle);
        s_dac_handle = NULL;
        return ret;
    }

    /* Start the fill task on core 0 (core 1 is reserved for shader render). */
    BaseType_t xret = xTaskCreatePinnedToCore(audio_fill_task, "dac_fill",
                                              2048, s_dac_handle, 5,
                                              &s_fill_task, 0);
    if (xret != pdPASS) {
        ESP_LOGE(TAG, "failed to create fill task");
        dac_continuous_disable(s_dac_handle);
        vQueueDelete(s_evt_queue);
        s_evt_queue = NULL;
        dac_continuous_del_channels(s_dac_handle);
        s_dac_handle = NULL;
        return ESP_ERR_NO_MEM;
    }

    /* Start async DMA.  All DMA buffers are zeroed and linked in a ring;
     * the ISR fires on_convert_done per descriptor so our fill task
     * continuously provides midscale silence or real audio. */
    ret = dac_continuous_start_async_writing(s_dac_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "start_async_writing failed: %s", esp_err_to_name(ret));
        vTaskDelete(s_fill_task);
        s_fill_task = NULL;
        dac_continuous_disable(s_dac_handle);
        vQueueDelete(s_evt_queue);
        s_evt_queue = NULL;
        dac_continuous_del_channels(s_dac_handle);
        s_dac_handle = NULL;
        return ret;
    }

    s_initialized = true;
    s_active = false;
    ESP_LOGI(TAG, "Audio output initialized: %lu Hz, DAC async DMA on GPIO25",
             (unsigned long)config->sample_rate);
    return ESP_OK;
}

esp_err_t fw_audio_output_start(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (s_active) return ESP_OK;

    s_active = true;
    ESP_LOGI(TAG, "Audio output started");
    return ESP_OK;
}

esp_err_t fw_audio_output_stop(void) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (!s_active) return ESP_OK;

    s_active = false;
    /* Drain the ring so DMA transitions to silence immediately. */
    s_ring_rd = s_ring_wr;
    ESP_LOGI(TAG, "Audio output stopped");
    return ESP_OK;
}

esp_err_t fw_audio_output_push(const uint8_t *samples, size_t count,
                               uint32_t timeout_ms)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (count == 0) return ESP_OK;

    /* Write samples into the ring buffer.  If the ring is full we drop
     * the oldest samples (advance read pointer) to avoid blocking the
     * render loop — a brief audio glitch is preferable to stalling. */
    uint32_t wr = s_ring_wr;
    for (size_t i = 0; i < count; i++) {
        s_ring[(wr + i) & RING_MASK] = samples[i];
    }
    /* If we overwrote unread data, advance the read pointer. */
    uint32_t new_wr = wr + count;
    if (new_wr - s_ring_rd > RING_SIZE) {
        s_ring_rd = new_wr - RING_SIZE;
    }
    s_ring_wr = new_wr;

    (void)timeout_ms;
    return ESP_OK;
}

esp_err_t fw_audio_output_push_silence(size_t count, uint32_t timeout_ms) {
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (count == 0) return ESP_OK;

    /* Push midscale silence bytes into the ring. */
    uint8_t silence[256];
    memset(silence, MIDSCALE, sizeof(silence));

    while (count > 0) {
        size_t chunk = count < sizeof(silence) ? count : sizeof(silence);
        esp_err_t ret = fw_audio_output_push(silence, chunk, timeout_ms);
        if (ret != ESP_OK) return ret;
        count -= chunk;
    }
    return ESP_OK;
}

bool fw_audio_output_is_active(void) {
    return s_active;
}

uint32_t fw_audio_output_get_sample_rate(void) {
    return s_sample_rate;
}
