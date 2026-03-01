#pragma once

#include <stdint.h>

#include "esp_err.h"
#include "fw_tcp_server.h"

/**
 * Initialize log capture ring buffer. Call as early as possible in app_main()
 * to capture boot messages. Safe to call before fw_telnet_server_start().
 */
void fw_telnet_log_init(void);

/**
 * Start the telnet server on the given port.
 * Creates a FreeRTOS task that listens for a single client connection.
 */
esp_err_t fw_telnet_server_start(uint16_t port, fw_tcp_server_state_t *state);
