# ESP32 Firmware (`esp32_firmware`)

ESP-IDF firmware scaffold for the LED pillar receiver.  
It boots Wi-Fi STA mode, starts the TCP LED protocol server on port `7777`, drives segmented LED output via ESP-IDF `led_strip` (RMT backend), and hosts the v3 bytecode runtime/control path.

## Board baseline

- Baseline configuration follows `led-pillar.yaml`: **`esp32dev` board + ESP-IDF framework**.
- This folder is the ESP-IDF-native implementation (`CMakeLists.txt` + `idf.py` workflow).

## Folder structure

- `CMakeLists.txt` (project root): ESP-IDF project entrypoint.
- `sdkconfig.defaults`: default ESP-IDF config values.
- `main/app_main.c`: boot flow (NVS, Wi-Fi, layout init, OTA hook init, TCP server start).
- `main/fw_led_config.{h,c}`: LED layout config + logical-to-physical mapping (segments + serpentine columns).
- `main/fw_led_output.{h,c}`: segmented `led_strip` output driver (RMT devices, per-segment refresh, pixel format unpacking).
- `main/fw_tcp_server.{h,c}`: TCP protocol server (v1/v2 frames + v3 bytecode/control messages + NVS persistence).
- `main/fw_bytecode_vm.{h,c}`: BC3/v3 bytecode loader/runtime and safety limits.
- `main/ota_hooks.{h,c}`: HTTPS OTA helpers (rollback validity confirmation + URL-triggered update API).
- `main/Kconfig.projbuild`: project Kconfig options (OTA enable/default URL/TLS strategy/timeout).

## Build / flash / OTA (ESP-IDF)

From this directory:

```bash
idf.py set-target esp32
idf.py menuconfig
idf.py build
idf.py -p <serial-port> flash monitor
```

Set credentials in `menuconfig` under `LED Pillar Firmware -> WiFi SSID / WiFi password`.
Set hostname/mDNS in `menuconfig` under `LED Pillar Firmware -> Device hostname / Enable mDNS advertisement`.
Set gamma correction in `menuconfig` under `LED Pillar Firmware -> LED output gamma x100` (default `280` = gamma `2.8`).

Common monitor exit: `Ctrl+]`.

OTA (ESP-IDF-centric):

- `fw_ota_init()` checks running app state and calls `esp_ota_mark_app_valid_cancel_rollback()` when image state is `ESP_OTA_IMG_PENDING_VERIFY`.
- Trigger OTA in firmware with:
  - `fw_ota_trigger(const fw_ota_request_t *request)` for explicit URL/TLS config.
  - `fw_ota_trigger_default()` to use compile-time defaults.
- OTA runs through `esp_https_ota()` and restarts on success.
- Compile-time options (see `main/Kconfig.projbuild`, defaults in `sdkconfig.defaults`):
  - `CONFIG_FW_OTA_ENABLED`
  - `CONFIG_FW_OTA_DEFAULT_URL`
  - `CONFIG_FW_OTA_USE_CRT_BUNDLE`
  - `CONFIG_FW_OTA_ALLOW_INSECURE`
  - `CONFIG_FW_OTA_HTTP_TIMEOUT_MS`

## LED strip/layout configuration

Default layout is in `fw_led_layout_load_default()`:

- `width=30`, `height=40`
- `segment_count=3`
- segment GPIO pins: `13`, `32`, `33`
- segment lengths: `400`, `400`, `400` (must total `width * height`)
- `serpentine_columns=true`
- maximum supported segments: `FW_LED_MAX_SEGMENTS` (`8`)

Configurable properties:

- **RMT/data output pins**: `segments[i].gpio`
- **Per-segment LED counts**: `segments[i].led_count`
- **Serpentine mapping toggle**: `serpentine_columns`
- **Logical dimensions**: `width`, `height`
- **Output gamma correction**: `CONFIG_FW_LED_GAMMA_X100` (default `280`)

Validation/safety checks enforce:

- non-zero width/height
- `segment_count` in bounds (`<= FW_LED_MAX_SEGMENTS`)
- valid output GPIOs
- exact LED total match (`sum(segment lengths) == width * height`)

RMT output behavior (`fw_led_output`):

- Creates one `led_strip_new_rmt_device()` instance per segment.
- Uses `led_strip_rmt_config_t.resolution_hz = 10_000_000`.
- Clears strips on init/deinit and refreshes each segment per frame.
- Supports RGB/RGBW/GRB/GRBW/BGR input encodings; for 4-byte formats, W is added into RGB with saturation before output.
- Applies configurable gamma correction through a 256-entry LUT before writing RGB values to the strip.

## Protocol support summary

All messages start with `LEDS` magic and version byte.

- **v1 (`0x01`)**: frame stream; no ACK.
- **v2 (`0x02`)**: frame stream; sends per-frame ACK byte `0x06`.
- **v3 (`0x03`)**: control channel for bytecode upload/activation/default-hook management and push OTA firmware upload.

### v1/v2 frame behavior

- Header encodes pixel count + pixel format.
- Supported pixel formats map to 3 or 4 bytes/pixel.
- Payload remapping is configurable:
  - default (`CONFIG_FW_V12_REMAP_LOGICAL=n`): payload is treated as already physical order.
  - enabled (`CONFIG_FW_V12_REMAP_LOGICAL=y`): payload is remapped from logical order to physical segmented-serpentine order.
- Size/overflow guards reject mismatched or oversized frames.

### v3 bytecode/control behavior

Supported commands:

- `0x01` upload BC3 bytecode blob (max `64 KiB`)
- `0x02` activate uploaded shader
- `0x03` set default shader hook (persist to NVS)
- `0x04` clear default shader hook (erase from NVS)
- `0x05` query hook/upload/active/fault state (+ persisted blob size)
- `0x06` upload and apply firmware image (raw app `.bin` bytes streamed in payload; device reboots on success)

Responses use command|`0x80` with status byte (`OK`, `INVALID_ARG`, `UNSUPPORTED_CMD`, `TOO_LARGE`, `NOT_READY`, `VM_ERROR`, `INTERNAL`).

`QUERY_DEFAULT_HOOK (0x05)` response payload is 8 bytes:
`[persisted, uploaded, active, faulted, blob_len_be_u32]`.

Default shader persistence behavior:

- Persisted in NVS namespace/key: `fw_shader/default_bc3`.
- On boot, firmware attempts to load and activate persisted shader automatically.
- If persisted shader is invalid/corrupt or fails VM init, it is cleared from NVS and flagged as faulted.

## Practical notes / limitations

- TCP server is **single-client at a time** (accept loop handles one connection, then returns to listen).
- v1/v2 frames are pushed to hardware through ESP-IDF `led_strip` (RMT) drivers; optional logical->physical remap is controlled by `CONFIG_FW_V12_REMAP_LOGICAL` (default off).
- OTA can be triggered via v3 push upload command (`0x06`) without an HTTPS URL.
- OTA call is synchronous in caller context; successful OTA reboots immediately.
- Wi-Fi credentials come from `CONFIG_FW_WIFI_SSID` / `CONFIG_FW_WIFI_PASSWORD` (local `sdkconfig`); `sdkconfig` is gitignored to reduce credential leak risk.
- Hostname comes from `CONFIG_FW_HOSTNAME` (default `led-pillar`) and mDNS can be toggled with `CONFIG_FW_MDNS_ENABLED`.
- With mDNS enabled, the firmware advertises `_ledpillar._tcp` and is reachable at `<hostname>.local:7777`.
- Resource/safety bounds are explicit (fixed-size buffers, bytecode cap, mapping validation, payload checks).
