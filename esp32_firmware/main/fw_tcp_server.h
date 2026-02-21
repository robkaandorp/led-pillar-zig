#pragma once

#include <stdint.h>

#include "esp_err.h"

#include "fw_led_config.h"

#define FW_TCP_DEFAULT_PORT 7777U

esp_err_t fw_tcp_server_start(const fw_led_layout_config_t *layout, uint16_t port);
