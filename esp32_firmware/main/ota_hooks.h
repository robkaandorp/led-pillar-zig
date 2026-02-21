#pragma once

#include <stdbool.h>

#include "esp_err.h"

typedef struct {
    const char *url;
    const char *cert_pem;
    bool use_crt_bundle;
    bool skip_cert_common_name_check;
    int timeout_ms;
} fw_ota_request_t;

void fw_ota_init(void);
esp_err_t fw_ota_trigger(const fw_ota_request_t *request);
esp_err_t fw_ota_trigger_default(void);
