# LED Pillar — Completed Features

This file documents features that have been implemented and verified.

---

## Feature 0: Remove Pre-DSL Zig Effect Code ✅

Removed the legacy hand-coded Zig shader/effect implementations (`src/effects.zig`, ~1500 lines, 8 hand-coded shaders) that were superseded by DSL shaders. Ported the Infinite Lines effect to `examples/dsl/v1/infinite-lines.dsl` before removal.

**Commit**: `b79d0e1`

---

## Feature 1: Multiple Native Shaders ✅

Build-time shader registry that scans `examples/dsl/v1/` for `.dsl` files, compiles each to native C via `gen_registry_main.zig`, and generates `dsl_shader_registry.c/h` with a lookup table. Protocol v3 `ACTIVATE_NATIVE_SHADER` (0x07) extended to accept a shader name. CLI `native-shader-activate <name>` selects a shader. Simulator mirrors the registry.

**Commits**: `b1bc6a9` (Zig registry + simulator), `79f4aa9` (firmware + CLI)

---

## Feature 2: WiFi Access Point Fallback ✅

ESP32 runs in APSTA mode: STA connects to configured home network, AP always active with SSID `led-pillar` (password `ledpillar`, configurable via Kconfig). Phone can connect to AP at `192.168.4.1` when no home network is available.

**Commit**: `ace4e75`

---

## Feature 3: Telnet Server ✅

FreeRTOS task (6 KB stack, priority 3) running a character-mode telnet server on port 23. Telnet negotiation (WILL ECHO, SGA, WONT LINEMODE). Virtual filesystem from shader registry. Commands: `ls`, `cd`, `pwd`, `run`, `stop`, `top`, `help`, `exit`. Tab completion for commands, shader names, and directories. Ctrl+C cancels input, Ctrl+D disconnects.

**Commits**: `033017c` (initial), `d61b923` (exit/Ctrl+D)

---

## Feature 4: Sound / Audio Synthesis ✅

### Phase 1: I2S DAC Driver
`fw_audio_output.c/h` — built-in DAC on GPIO25, 22050 Hz, 8-bit mono, DMA double-buffering (4 buffers × 256 samples). API: init/start/stop/push/is_active/get_sample_rate.

### Phase 2: DSL Audio Block
`audio { ... out <expr> }` block added to DSL parser, C emitter, and bytecode runtime. `out` statement sets a scalar audio output value. C emitter generates `eval_audio(float time, float seed)` function. Registry struct extended with `has_audio_func` and `eval_audio` fields.

### Phase 3: Firmware Integration
Audio sample generation on core 1 after pixel render (~551 samples/frame). Triangular dither via LFSR. Maps [-1,1] → [0,255]. Auto-starts audio when shader with audio block is activated, auto-stops otherwise. Telnet `top` shows audio status, `ls` shows `[audio]` flag.

### Phase 4: Higher Quality (future, not yet needed)
External I2S DAC upgrade path documented. Bluetooth A2DP documented but won't fit with OTA.

**Commit**: `e6b8df1`

**Example shader**: `examples/dsl/v1/tone-pulse.dsl`

---

## Design Decisions (for reference)

| # | Question | Decision |
|---|----------|----------|
| Q1 | Build-time DSL compilation method | Zig build step |
| Q2 | Shader naming | From file name |
| Q3 | Subfolder → virtual directory | Yes |
| Q4 | Flash size for shaders | ~60 KB fine, 170 KB headroom |
| Q5 | Telnet port | 23 (configurable) |
| Q6 | Telnet clients | Single client |
| Q7 | Telnet task | Own FreeRTOS task, low priority |
| Q8 | Telnet RAM | ~5 KB total |
| Q9 | `top` display mode | One-shot (not live) |
| Q10 | Telnet character mode | Yes (for tab completion) |
| Q11 | AP mode | Always active (APSTA) |
| Q12 | AP password | `ledpillar` (configurable) |
| Q13 | AP static IP | `192.168.4.1` (ESP32 default) |
| Q14 | Audio sample rate | 22050 Hz |
| Q15 | Audio block location | Same `.dsl` file as visuals |
| Q16 | Audio playback | Only when shader has `audio` block |
| Q17 | Audio generation core | Core 1, after pixel render |
| Q18 | 8-bit dithering | Yes, triangular dither |
| Q19 | DAC GPIO | GPIO25 (DAC1) |

---

## System Summary (as of completion)

| Resource | Value |
|---|---|
| ESP32 chip | ESP32 (dual-core Xtensa, 240 MHz, no PSRAM) |
| Flash | 4 MB (DIO mode) |
| Firmware size | ~891 KB |
| Free heap at boot | ~85 KB |
| WiFi mode | APSTA (STA + AP simultaneous) |
| FreeRTOS tasks | TCP server (core 0), shader renderer (core 1), telnet (unpinned) |
| Shader target | 40 FPS, 30×40 pixels (1200 LEDs) |
| Native shaders | 11 compiled from DSL into registry |
| Audio | 8-bit DAC on GPIO25, 22050 Hz mono |
| Protocol | V1/V2 (raw frames), V3 (bytecode + native shader + OTA) |
