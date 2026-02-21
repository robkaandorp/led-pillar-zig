idf_component_register(
    SRCS "app_main.c" "ota_hooks.c" "fw_led_config.c" "fw_bytecode_vm.c" "fw_tcp_server.c" "fw_led_output.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_event esp_netif esp_wifi nvs_flash lwip led_strip esp_https_ota app_update
)
