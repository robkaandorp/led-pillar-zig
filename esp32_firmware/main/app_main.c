#include <string.h>
#include <inttypes.h>

#include "esp_err.h"
#include "esp_event.h"
#include "esp_log.h"
#include "mdns.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"

#include "fw_led_config.h"
#include "fw_tcp_server.h"
#include "ota_hooks.h"

static const char *TAG = "fw_main";
static fw_led_layout_config_t g_fw_layout = {0};
static esp_netif_t *g_fw_sta_netif = NULL;
static esp_netif_t *g_fw_ap_netif = NULL;

static void fw_init_nvs(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
}

static void fw_wifi_ap_event_handler(void *arg, esp_event_base_t event_base,
                                     int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_AP_STACONNECTED) {
        wifi_event_ap_staconnected_t *event = (wifi_event_ap_staconnected_t *)event_data;
        ESP_LOGI(TAG, "AP: station " MACSTR " joined, AID=%d",
                 MAC2STR(event->mac), event->aid);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_AP_STADISCONNECTED) {
        wifi_event_ap_stadisconnected_t *event = (wifi_event_ap_stadisconnected_t *)event_data;
        ESP_LOGI(TAG, "AP: station " MACSTR " left, AID=%d",
                 MAC2STR(event->mac), event->aid);
    }
}

static void fw_init_network(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    g_fw_sta_netif = esp_netif_create_default_wifi_sta();
    ESP_ERROR_CHECK(g_fw_sta_netif != NULL ? ESP_OK : ESP_FAIL);
    g_fw_ap_netif = esp_netif_create_default_wifi_ap();
    ESP_ERROR_CHECK(g_fw_ap_netif != NULL ? ESP_OK : ESP_FAIL);

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, WIFI_EVENT_AP_STACONNECTED,
        &fw_wifi_ap_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, WIFI_EVENT_AP_STADISCONNECTED,
        &fw_wifi_ap_event_handler, NULL, NULL));
}

static void fw_init_hostname_and_mdns(void) {
    const char *hostname = CONFIG_FW_HOSTNAME;
    if (hostname[0] != '\0') {
        ESP_ERROR_CHECK(esp_netif_set_hostname(g_fw_sta_netif, hostname));
        ESP_LOGI(TAG, "hostname set to %s", hostname);
    } else {
        ESP_LOGW(TAG, "CONFIG_FW_HOSTNAME is empty; hostname not set");
    }

#if CONFIG_FW_MDNS_ENABLED
    ESP_ERROR_CHECK(mdns_init());
    const char *mdns_hostname = hostname[0] != '\0' ? hostname : "led-pillar";
    ESP_ERROR_CHECK(mdns_hostname_set(mdns_hostname));
    ESP_ERROR_CHECK(mdns_instance_name_set("LED Pillar"));
    ESP_ERROR_CHECK(mdns_service_add(NULL, "_ledpillar", "_tcp", FW_TCP_DEFAULT_PORT, NULL, 0));
    ESP_LOGI(TAG, "mDNS enabled at %s.local", mdns_hostname);
#endif
}

static void fw_init_wifi(void) {
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    wifi_config_t sta_config = {0};
    wifi_config_t ap_config = {0};

    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));

    /* STA config */
    strlcpy((char *)sta_config.sta.ssid, CONFIG_FW_WIFI_SSID, sizeof(sta_config.sta.ssid));
    strlcpy((char *)sta_config.sta.password, CONFIG_FW_WIFI_PASSWORD, sizeof(sta_config.sta.password));
    sta_config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    /* AP config */
    strlcpy((char *)ap_config.ap.ssid, CONFIG_FW_WIFI_AP_SSID, sizeof(ap_config.ap.ssid));
    ap_config.ap.ssid_len = (uint8_t)strlen(CONFIG_FW_WIFI_AP_SSID);
    strlcpy((char *)ap_config.ap.password, CONFIG_FW_WIFI_AP_PASSWORD, sizeof(ap_config.ap.password));
    ap_config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    ap_config.ap.max_connection = CONFIG_FW_WIFI_AP_MAX_CONN;
    ap_config.ap.channel = 0;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap_config));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    ESP_LOGI(TAG, "WiFi AP started: SSID=\"%s\", IP=192.168.4.1", CONFIG_FW_WIFI_AP_SSID);

    if (CONFIG_FW_WIFI_SSID[0] == '\0') {
        ESP_LOGW(TAG, "CONFIG_FW_WIFI_SSID is empty; WiFi STA connect skipped");
        return;
    }
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta_config));
    ESP_LOGI(TAG, "WiFi STA init complete (connection attempt is best-effort)");
    (void)esp_wifi_connect();
}

static void fw_init_led_layout(void) {
    fw_led_physical_index_t first_pixel = {0};

    fw_led_layout_load_default(&g_fw_layout);
    ESP_ERROR_CHECK(fw_led_layout_validate(&g_fw_layout));
    ESP_ERROR_CHECK(fw_led_map_logical_xy(&g_fw_layout, 0, 0, &first_pixel));

    ESP_LOGI(TAG,
             "LED layout ready: %ux%u, segments=%u, total_leds=%" PRIu32 ", serpentine=%s",
             g_fw_layout.width,
             g_fw_layout.height,
             g_fw_layout.segment_count,
             fw_led_layout_total_leds(&g_fw_layout),
             g_fw_layout.serpentine_columns ? "enabled" : "disabled");

    uint8_t segment = 0;
    while (segment < g_fw_layout.segment_count) {
        ESP_LOGI(TAG,
                 "segment[%u]: gpio=%d leds=%u",
                 segment,
                 g_fw_layout.segments[segment].gpio,
                 g_fw_layout.segments[segment].led_count);
        segment += 1;
    }

    ESP_LOGI(TAG,
             "logical(0,0) -> segment=%u led=%u global=%" PRIu32,
             first_pixel.segment_index,
             first_pixel.segment_led_index,
             first_pixel.global_led_index);
}

void app_main(void) {
    ESP_LOGI(TAG, "Bootstrapping firmware scaffold");
    fw_init_nvs();
    fw_init_led_layout();
    fw_init_network();
    fw_init_hostname_and_mdns();
    fw_init_wifi();
    ESP_ERROR_CHECK(fw_tcp_server_start(&g_fw_layout, FW_TCP_DEFAULT_PORT));
    fw_ota_init();
    ESP_LOGI(TAG, "Scaffold initialization complete");
}
