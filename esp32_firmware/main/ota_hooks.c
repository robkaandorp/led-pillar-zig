#include "ota_hooks.h"

#include <stdbool.h>

#include "esp_crt_bundle.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "sdkconfig.h"

static const char *TAG = "fw_ota";

#if CONFIG_FW_OTA_ENABLED
#ifdef CONFIG_FW_OTA_ALLOW_INSECURE
#define FW_OTA_ALLOW_INSECURE_DEFAULT true
#else
#define FW_OTA_ALLOW_INSECURE_DEFAULT false
#endif

static const fw_ota_request_t FW_OTA_DEFAULT_REQUEST = {
    .url = CONFIG_FW_OTA_DEFAULT_URL,
    .cert_pem = NULL,
    .use_crt_bundle = CONFIG_FW_OTA_USE_CRT_BUNDLE,
    .skip_cert_common_name_check = FW_OTA_ALLOW_INSECURE_DEFAULT,
    .timeout_ms = CONFIG_FW_OTA_HTTP_TIMEOUT_MS,
};

static bool fw_ota_has_string(const char *value) {
    return value != NULL && value[0] != '\0';
}
#endif

static esp_err_t fw_ota_mark_running_app_valid_if_pending(void) {
    const esp_partition_t *running_partition = esp_ota_get_running_partition();
    esp_ota_img_states_t ota_state = ESP_OTA_IMG_UNDEFINED;
    esp_err_t err = esp_ota_get_state_partition(running_partition, &ota_state);

    if (err == ESP_ERR_NOT_FOUND || err == ESP_ERR_NOT_SUPPORTED) {
        return ESP_OK;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read OTA image state: %s", esp_err_to_name(err));
        return err;
    }
    if (ota_state != ESP_OTA_IMG_PENDING_VERIFY) {
        return ESP_OK;
    }

    err = esp_ota_mark_app_valid_cancel_rollback();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to mark app valid: %s", esp_err_to_name(err));
        return err;
    }

    ESP_LOGI(TAG, "Marked running OTA image as valid");
    return ESP_OK;
}

void fw_ota_init(void) {
    esp_err_t err = fw_ota_mark_running_app_valid_if_pending();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Proceeding without rollback confirmation");
    }

#if CONFIG_FW_OTA_ENABLED
    ESP_LOGI(TAG, "OTA module ready (default URL: %s)",
             fw_ota_has_string(CONFIG_FW_OTA_DEFAULT_URL) ? CONFIG_FW_OTA_DEFAULT_URL : "<unset>");
#else
    ESP_LOGI(TAG, "OTA module disabled at compile time");
#endif
}

esp_err_t fw_ota_trigger_default(void) {
    return fw_ota_trigger(NULL);
}

esp_err_t fw_ota_trigger(const fw_ota_request_t *request) {
#if !CONFIG_FW_OTA_ENABLED
    (void)request;
    ESP_LOGW(TAG, "OTA request rejected: feature disabled");
    return ESP_ERR_NOT_SUPPORTED;
#else
    const fw_ota_request_t *effective_request = request != NULL ? request : &FW_OTA_DEFAULT_REQUEST;
    int timeout_ms = effective_request->timeout_ms > 0 ? effective_request->timeout_ms : FW_OTA_DEFAULT_REQUEST.timeout_ms;

    if (!fw_ota_has_string(effective_request->url)) {
        ESP_LOGE(TAG, "OTA URL is empty");
        return ESP_ERR_INVALID_ARG;
    }

    esp_http_client_config_t http_config = {
        .url = effective_request->url,
        .timeout_ms = timeout_ms,
        .keep_alive_enable = true,
        .skip_cert_common_name_check = effective_request->skip_cert_common_name_check,
    };

    if (fw_ota_has_string(effective_request->cert_pem)) {
        http_config.cert_pem = effective_request->cert_pem;
    } else if (effective_request->use_crt_bundle) {
#if CONFIG_MBEDTLS_CERTIFICATE_BUNDLE
        http_config.crt_bundle_attach = esp_crt_bundle_attach;
#else
        ESP_LOGW(TAG, "Certificate bundle requested but disabled in sdkconfig");
#endif
    }

    if (http_config.cert_pem == NULL && http_config.crt_bundle_attach == NULL &&
        !http_config.skip_cert_common_name_check) {
        ESP_LOGE(TAG, "No TLS verification strategy configured (cert or bundle required)");
        return ESP_ERR_INVALID_STATE;
    }

    esp_https_ota_config_t ota_config = {
        .http_config = &http_config,
    };

    ESP_LOGI(TAG, "Starting HTTPS OTA from %s", effective_request->url);
    esp_err_t err = esp_https_ota(&ota_config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "HTTPS OTA failed: %s", esp_err_to_name(err));
        return err;
    }

    ESP_LOGI(TAG, "HTTPS OTA complete; restarting");
    esp_restart();
    return ESP_OK;
#endif
}
