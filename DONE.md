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

Audio quality upgrade paths (external I2S DAC, Bluetooth A2DP) documented in [FUTURE_IDEAS.md](FUTURE_IDEAS.md).

**Commit**: `e6b8df1`

**Example shader**: `examples/dsl/v1/tone-pulse.dsl`

---

## ESP32 Shader Performance Optimization ✅

### Problem

The heaviest native shader (forest-wind) rendered at 55–67 ms per frame on ESP32, exceeding the 25 ms budget (40 FPS target) by 2.5×. The telnet console became unresponsive during heavy shaders because the shader task starved lower-priority tasks.

### Root Causes

1. **Flash bandwidth** — The ESP32 was running flash in DIO mode at 40 MHz (80 Mbit/s effective). Every instruction cache miss fetches from flash; heavy shaders that don't fit in the 32 KB I-cache spent most of their time waiting for flash.
2. **I-cache thrashing (GCC 14 only)** — With 19 shaders compiled into a single translation unit, GCC 14's aggressive `-O3` inlining duplicated large helper functions (`noise2`, `noise3`, `blend_over`) at every call site, bloating `.text` to 50+ KB — far exceeding the 32 KB I-cache. Each cache miss evicted code that would be needed moments later.
3. **Telnet starvation** — The shader task (core 1, priority 4) never yielded enough CPU for the telnet task (unpinned, priority 3). When telnet happened to be scheduled on core 1, it couldn't preempt the shader.

### Fixes Applied

| Fix | Effect | Files |
|-----|--------|-------|
| **QIO@80 MHz flash** | 4× flash bandwidth (320 Mbit/s vs 80 Mbit/s). Cache misses refill 4× faster. | `sdkconfig.defaults` |
| **GCC-version-conditional DSL\_NOINLINE** | On GCC 14+: `__attribute__((noinline))` prevents duplicating heavy helpers across 19 call sites, keeping `.text` ≤ 32 KB. On GCC 13 and earlier: expands to `inline`, preserving the original `static inline` hint that GCC 13 needs for good interprocedural optimization. | `fw_native_shader.c`, `dsl_c_emitter.zig`, `dsl_shader_registry.c` |
| **Telnet pinned to core 0** | Telnet always has a free core; shader runs undisturbed on core 1. | `fw_telnet_server.c` |
| **Disable IDLE1 watchdog** | Shader monopolises core 1 by design; IDLE1 never runs. Disabling its watchdog check prevents spurious triggers on overbudget frames. | `sdkconfig.defaults` |

### Performance Results

| Shader | Before | After | Speedup |
|--------|--------|-------|---------|
| forest-wind | 55–67 ms | 20–24 ms | ~3× |
| chaos-nebula | 125 ms | 9.5 ms | 13× |
| gradient | 2.0 ms | 2.0 ms | (already fast) |

17 of 19 shaders now run at 40 FPS. The two heaviest SDF shaders (soap-bubbles, void-tendrils) run at ~21 FPS due to inherent algorithmic complexity.

### Key Insight

GCC 13 and GCC 14 have opposite inlining behavior for `static inline` functions with `-O3`:
- **GCC 14** aggressively inlines → code bloat → I-cache thrash → `noinline` fixes it
- **GCC 13** does not aggressively inline → `noinline` (or removing `inline`) prevents beneficial interprocedural optimization → 2× regression

The solution uses a preprocessor version check (`__GNUC__ >= 14`) so both compiler generations produce optimal code.

**Commits**: `4a709b7`, `496e1de`, `86fefb3`, `cbfdcc9`

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
| Flash | 4 MB (QIO mode, 80 MHz) |
| Firmware size | ~891 KB |
| Free heap at boot | ~85 KB |
| WiFi mode | APSTA (STA + AP simultaneous) |
| FreeRTOS tasks | TCP server (core 0), shader renderer (core 1), telnet (core 0) |
| Shader target | 40 FPS, 30×40 pixels (1200 LEDs) |
| Native shaders | 19 compiled from DSL into registry |
| Audio | 8-bit DAC on GPIO25, 22050 Hz mono |
| Protocol | V1/V2 (raw frames), V3 (bytecode + native shader + OTA) |
