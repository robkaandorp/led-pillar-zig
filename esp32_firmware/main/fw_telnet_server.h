#pragma once

#include <stdint.h>

#include "esp_err.h"
#include "fw_tcp_server.h"

/**
 * Start the telnet server on the given port.
 * Creates a FreeRTOS task that listens for a single client connection.
 */
esp_err_t fw_telnet_server_start(uint16_t port, fw_tcp_server_state_t *state);
