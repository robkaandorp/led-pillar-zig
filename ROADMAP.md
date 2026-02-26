# LED Pillar Feature Roadmap

## Current System Summary

| Resource | Value |
|---|---|
| ESP32 chip | ESP32 (dual-core Xtensa, 240 MHz, no PSRAM) |
| Flash | 4 MB (DIO mode) |
| Partition scheme | Two OTA (factory ~1 MB, ota_0 ~1 MB, ota_1 ~1 MB) |
| Current firmware size | ~823 KB |
| Free heap at boot | ~197 KB |
| WiFi mode | STA only |
| Bluetooth | Disabled |
| FreeRTOS tasks | 2 custom (TCP server on core 0, shader renderer on core 1) |
| Shader target | 40 FPS, 30×40 pixels (1200 LEDs) |
| Native shader | 1 hardcoded C file compiled into firmware |
| DSL shaders | 12 example files in `examples/dsl/v1/` |
| Protocol | V1/V2 (raw frames), V3 (bytecode + native shader + OTA) |

---

## Feature 1: Multiple Native Shaders

### Description

Store all DSL shader files from a folder tree in the firmware as compiled native C shaders. Extend the activate-native-shader command to select which shader to run by name or index.

### Difficulty: **Medium**

### What Needs to Be Done

1. **Build-time shader collection**: Modify `build.zig` and/or a build script to:
   - Scan `examples/dsl/v1/` (and subfolders) for `.dsl` files
   - Compile each to C via the DSL C emitter
   - Generate a single `dsl_shader_registry.c` file that contains all shaders (each with a unique function name) plus a lookup table (name → function pointer)

2. **Firmware shader registry**: Create a `fw_shader_registry.h/.c` module with:
   - A struct: `{ const char *name; const char *folder; void (*eval_pixel)(...); }`
   - A flat array of all compiled shaders
   - Lookup functions: by name, by index, list all

3. **Protocol extension**: Extend the `ACTIVATE_NATIVE_SHADER` (0x07) command:
   - Currently takes an empty payload
   - New: payload contains a shader name (null-terminated string) or index (u16)
   - Empty payload = activate default/first shader (backward compatible)

4. **CLI update**: Extend `native-shader-activate` command to accept an optional shader name argument

5. **Simulator update**: Mirror the registry so the simulator can also select among multiple shaders

### Choices to Make

- **Q1**: Should we use a build-time Zig script (a build step in `build.zig`) to compile all DSL files to C, or a separate pre-build script?
  - *Assumption*: Use a Zig build step for consistency. The build step invokes the DSL compiler for each `.dsl` file and concatenates results.
- **Q2**: How should shader names be derived — from the DSL `effect` name or the file name?
  - *Assumption*: Use the DSL `effect` name (already required in every shader), but fall back to file name stem if needed.
- **Q3**: Should subfolders map to a virtual directory structure (e.g., `/native/gradients/aurora`)?
  - *Assumption*: Yes — the relative folder path from the shader root becomes the virtual directory prefix. This maps naturally to the telnet `cd`/`ls` commands later.
- **Q4**: Flash size concern — 12 shaders at ~2-5 KB each is ~30-60 KB. With the current 1 MB OTA partition, there's ~170 KB headroom. Is that enough?
  - *Assumption*: Yes for now. If we add many more shaders we may need to revisit partition sizes.

### Verification Goals

1. ✅ `zig build` compiles all `.dsl` files from the shader folder into the firmware
2. ✅ Firmware boots and lists available shaders in serial log
3. ✅ `native-shader-activate` with no argument activates the default shader at 40 FPS
4. ✅ `native-shader-activate <name>` activates a specific shader by name
5. ✅ Activating a non-existent shader returns an error status
6. ✅ Simulator supports the same multi-shader selection
7. ✅ All existing Zig tests pass
8. ✅ Adding a new `.dsl` file to the folder automatically includes it on next build

---

## Feature 2: Telnet Server

### Description

Run a telnet server on the ESP32 (on a separate port) that provides a shell-like interface for managing shaders from a phone or any telnet client.

### Difficulty: **Medium-Hard**

### What Needs to Be Done

1. **Telnet server task**: New FreeRTOS task (`fw_telnet_server`) listening on a configurable port (e.g., 23 or 2323):
   - Accept one client at a time (single-user is sufficient for a phone)
   - Line-buffered input, ANSI-capable output
   - Telnet protocol negotiation (minimal: suppress go-ahead, echo mode)

2. **Virtual filesystem**: An in-memory directory tree built from the shader registry:
   - `/native/` — native shaders organized by subfolder
   - `/bytecode/` — uploaded bytecode shaders (if any are persisted)
   - Each entry has: name, type (native/bytecode), size info

3. **Shell commands**:

   | Command | Description |
   |---|---|
   | `ls` | List shaders in current directory with info (name, type, size) |
   | `cd <path>` | Change directory (supports `.`, `..`, absolute paths) |
   | `pwd` | Print current directory |
   | `run <name>` | Activate shader by name (relative or absolute path) |
   | `stop` | Stop currently running shader |
   | `top` | Show running shader stats (name, FPS, frame count, uptime, slow frames) |
   | `help` | List available commands |

4. **Tab completion**: The shell must support tab-expansion so the user does not need to type full path or shader names:
   - Pressing Tab after a partial name completes it if there is a single match
   - If multiple matches exist, pressing Tab a second time lists all matching options
   - Works for `cd`, `run`, and any command that takes a path/name argument
   - Completes both directory names and shader names depending on context
   - Implementation: buffer keystrokes character-by-character (telnet character mode), detect `\t` (0x09), perform prefix matching against the virtual filesystem entries in the current directory
   - Send the completed portion back to the client as echoed characters so the input line stays consistent

5. **Prompt**: Display useful info, e.g., `led-pillar:/native> `

6. **Shared state**: The telnet commands must interact with the same `fw_tcp_server_state_t` (or a shared shader-control interface) to start/stop shaders. Need careful mutex usage to not block the shader renderer.

### Choices to Make

- **Q5**: What port for the telnet server?
  - *Assumption*: Port 23 (standard telnet). Configurable via `menuconfig` or `#define`.
- **Q6**: Single client or multiple simultaneous clients?
  - *Assumption*: Single client. The ESP32 has limited RAM, and this is for personal use.
- **Q7**: Should the telnet server run on its own FreeRTOS task, or share with the TCP server?
  - *Assumption*: Own task (low priority, small stack ~4 KB). It must not interfere with the shader renderer on core 1.
- **Q8**: How much RAM does the telnet server need?
  - *Assumption*: ~4-6 KB stack + ~1 KB line buffer. Negligible compared to the 64 KB bytecode blob.
- **Q9**: Should `top` be a one-shot print or a live-updating display (like Unix `top`)?
  - *Assumption*: Start with one-shot. Live updating is nice but adds complexity (ANSI cursor control, periodic refresh, Ctrl+C to exit).
- **Q10**: Tab completion requires character-mode telnet (not line-mode). Is this acceptable?
  - *Assumption*: Yes. We negotiate character mode (WILL ECHO, WILL SUPPRESS-GO-AHEAD) during telnet handshake. Most telnet clients (Termius, PuTTY, etc.) support this.

### Verification Goals

1. ✅ Telnet to ESP32 from iPhone (e.g., using Termius or similar app)
2. ✅ `ls` lists all native shaders with names
3. ✅ `cd /native` and `ls` shows shader list
4. ✅ `run aurora_ribbons_classic_v1` starts the shader at 40 FPS
5. ✅ `top` shows shader name, FPS, and frame count
6. ✅ `stop` stops the shader and clears the display
7. ✅ `cd ..` works, `pwd` shows correct path
8. ✅ Tab-completing `run aur<Tab>` expands to `run aurora_ribbons_classic_v1`
9. ✅ Tab on ambiguous prefix shows all matching options
10. ✅ Invalid commands show helpful error messages
11. ✅ Shader performance (40 FPS) is unaffected while telnet session is active
12. ✅ Disconnecting telnet does not stop the running shader

---

## Feature 3: WiFi Access Point Fallback

### Description

When the configured WiFi network is not available, the ESP32 creates its own password-protected WiFi access point so a phone can connect directly to manage shaders via telnet.

### Difficulty: **Easy**

### What Needs to Be Done

1. **APSTA mode**: Change WiFi init from `WIFI_MODE_STA` to `WIFI_MODE_APSTA`:
   - STA interface tries to connect to configured network
   - AP interface always active with configurable SSID/password
   - Both interfaces share the same radio channel

2. **Configuration**: Add `menuconfig` / `sdkconfig.defaults` entries:
   - AP SSID (default: `led-pillar`)
   - AP password (default: configurable, WPA2-PSK)
   - AP channel (default: auto, matches STA)
   - Max connections (default: 2)

3. **Status indication**: Log AP status (IP, connected clients) on serial console

4. **mDNS on AP**: Ensure mDNS (`led-pillar.local`) works on the AP interface too, so the phone can discover it without knowing the IP

### Choices to Make

- **Q11**: Should the AP always be active, or only when STA connection fails?
  - *Assumption*: Always active (APSTA mode). Simpler, and the overhead is negligible. This way you can always connect from your phone even when the home network is up.
- **Q12**: What should the default AP password be?
  - *Assumption*: Configurable via `menuconfig`. A reasonable default like `ledpillar` or empty string for open network. Open network is simpler for personal use but less secure.
- **Q13**: Should we assign a static IP on the AP interface?
  - *Assumption*: Yes, use the default ESP32 AP IP `192.168.4.1`. The phone will get an IP in the `192.168.4.x` range from the built-in DHCP server.

### Verification Goals

1. ✅ ESP32 boots and creates WiFi AP `led-pillar` with password
2. ✅ Phone can connect to the AP
3. ✅ Phone can telnet to `192.168.4.1` (or `led-pillar.local`) and control shaders
4. ✅ When home WiFi is available, STA connection still works normally
5. ✅ The PC can still connect via the home network while the phone is on the AP
6. ✅ Shader performance (40 FPS) is unaffected by AP mode

---

## Feature 4: Sound / Audio Synthesis

### Description

Extend the DSL language to generate audio waveforms alongside visuals. The ESP32 outputs synthesized mono audio through its built-in 8-bit DAC (GPIO25), connected to the Dayton Audio amplifier's AUX input. This approach requires no extra hardware, no Bluetooth stack, and has negligible flash/RAM cost.

### Difficulty: **Medium**

### What Needs to Be Done

#### Phase 1: Built-in DAC Audio Output (8-bit, GPIO25)

1. **I2S DAC driver**: Configure the ESP32's I2S peripheral in built-in DAC mode:
   - Output on GPIO25 (DAC channel 1), mono
   - Sample rate: configurable, start with 22050 Hz (8-bit DAC doesn't benefit much from 44.1 kHz)
   - Use DMA double-buffering so audio output is continuous without CPU stalls
   - ⚠️ **Flash impact**: Negligible (I2S driver is already in ESP-IDF)
   - ⚠️ **RAM impact**: ~2-4 KB for DMA buffers
   - **Hardware**: Single wire from GPIO25 to the amplifier's AUX input (+ common ground)

2. **Audio buffer**: Ring buffer between the shader renderer and I2S DMA:
   - Shader renderer fills it with 8-bit unsigned PCM samples each frame
   - I2S DMA callback drains it
   - Size: ~1-2 KB (enough for ~45-90 ms at 22050 Hz mono 8-bit)

3. **Audio task**: Either feed from the shader task on core 1 (after each frame) or use the I2S DMA write-blocking pattern. The I2S driver handles timing — we just need to keep the buffer fed.

#### Phase 2: DSL Sound Extension

4. **DSL language extension**: Add an `audio` block type to the DSL:
   ```dsl
   effect my_effect
   
   // visual layers...
   layer visuals {
     blend rgba(...)
   }
   emit
   
   audio {
     // mono output sample in [-1, 1], will be quantized to 8-bit unsigned
     let freq = 440.0 + sin(time * 2.0) * 100.0
     let envelope = clamp(1.0 - fract(time * 4.0) * 2.0, 0.0, 1.0)
     out sin(time * freq * TAU) * envelope * 0.5
   }
   ```

5. **Audio evaluation**: The audio block runs at the audio sample rate (22050 Hz), not the pixel rate. It receives the same `time` and `seed` inputs, plus an `audio_phase` accumulator for continuous oscillator phase.

6. **8-bit quantization**: Map the DSL output range [-1, 1] → unsigned 8-bit [0, 255]. The 8-bit limitation means ~48 dB dynamic range — embrace it as a lo-fi aesthetic. Dithering (adding tiny noise before quantization) can reduce audible stepping artifacts cheaply.

7. **ADSR envelopes**: Add builtin functions:
   - `adsr(attack, decay, sustain, release, trigger)` → envelope value [0, 1]
   - Or build from existing `clamp`/`smoothstep` functions

8. **C emitter update**: Emit a second function `dsl_shader_eval_audio(float time, float seed, float *out_sample)` alongside the pixel shader

9. **Bytecode VM update**: Add audio evaluation path to the VM

#### Phase 3: Integration

10. **Sync**: Audio and video must stay in sync. The shader task generates both pixel frames and audio sample buffers on the same timeline.

11. **Telnet integration**: `top` command shows audio status (DAC active, buffer level)

#### Phase 4: Higher Quality (Future)

12. **I2S external DAC upgrade**: If the 8-bit quality is too limiting, add a small I2S DAC breakout (e.g., PCM5102, MAX98357A, ~$2) for 16-bit output. The software architecture (ring buffer, DSL audio block, I2S driver) stays the same — only the I2S config and sample format change.

13. **Bluetooth A2DP (optional)**: If wireless audio to the Dayton amplifier is desired later:
    - ⚠️ **Flash impact**: +350-500 KB for `libbt.a`. Current firmware is ~823 KB in a ~1 MB partition. **Will NOT fit with OTA.**
    - **Mitigation**: Switch to single-factory partition (no OTA) or larger flash chip
    - ⚠️ **RAM impact**: +50-100 KB heap
    - Audio format: 44100 Hz, 16-bit stereo (A2DP/SBC requirement)

### Choices to Make

- **Q14**: Sample rate for built-in DAC: 22050 Hz or 44100 Hz?
  - *Assumption*: Start with 22050 Hz. The 8-bit DAC doesn't benefit much from higher rates, and lower rate means fewer samples to compute per frame (~551 samples/frame at 40 FPS vs. ~1102).
- **Q15**: Should the audio DSL block be in the same `.dsl` file as visuals, or a separate file?
  - *Assumption*: Same file. The audio should react to the same time/seed/params as the visuals for synchronized audiovisual effects.
- **Q16**: Should audio play continuously or only when a shader with an `audio` block is active?
  - *Assumption*: Only when a shader with an `audio` block is active. Silent shaders produce no audio (DAC idle).
- **Q17**: The shader renderer runs on core 1. Should audio sample generation happen on core 0 or core 1?
  - *Assumption*: Core 1 alongside rendering, at the end of each frame. At 22050 Hz / 40 FPS = ~551 samples per frame. With simple sine/math ops this should take <0.5 ms.
- **Q18**: Should we add dithering to the 8-bit output to reduce quantization noise?
  - *Assumption*: Yes, a simple triangular dither (1 random add before truncation) is nearly free and noticeably improves quality.
- **Q19**: Which GPIO for DAC output? GPIO25 (DAC1) or GPIO26 (DAC2)?
  - *Assumption*: GPIO25 (DAC1). Verify it's not already in use by the LED RMT output.

### Verification Goals

1. ✅ A simple test tone (440 Hz sine) plays through the speaker via GPIO25 → AUX input
2. ✅ A DSL shader with an `audio` block produces synchronized sound and visuals
3. ✅ Audio quality is acceptable for synthesized tones/effects (no major clicks or dropouts)
4. ✅ Shader rendering stays at 40 FPS while audio is playing
5. ✅ `stop` command stops both audio and visuals
6. ✅ Shaders without an `audio` block produce no audio (DAC idle)
7. ✅ `top` shows audio buffer status
8. ✅ Audio phase is continuous across frames (no clicks at frame boundaries)
9. ✅ 8-bit lo-fi character is audible but not unpleasant for synth sounds
10. ✅ WiFi and telnet still work while audio plays (no resource conflict)

---

## Feature 5: On-Device DSL Compiler (Stretch Goal)

### Description

Run a DSL-to-bytecode compiler on the ESP32 itself, so users can paste a DSL script into the telnet session and have it compile and run without a PC.

### Difficulty: **Hard**

### What Needs to Be Done

1. **Port DSL parser to C**: The current parser is written in Zig (`src/dsl_parser.zig`, ~830 lines). It would need to be rewritten in C for the ESP32 firmware.
   - The parser is a hand-written recursive descent parser
   - Token scanning, AST construction, validation
   - ~2000-3000 lines of C estimated

2. **Port bytecode compiler to C**: The runtime/compiler (`src/dsl_runtime.zig`, ~1200 lines) compiles the AST to bytecode. Also needs C port.
   - Expression compilation, slot allocation, serialization
   - ~1500-2000 lines of C estimated

3. **Telnet integration**: Add a `compile` command or a multi-line input mode:
   - User pastes DSL source
   - End marker (e.g., blank line, `EOF`, or Ctrl+D)
   - Compile to bytecode in-memory
   - Activate the compiled shader

4. **Memory management**: The parser/compiler needs temporary allocations:
   - AST nodes, string storage, bytecode buffer
   - Estimate: 20-50 KB peak for a complex shader
   - Must use a scratch allocator and free after compilation

### Choices to Make

- **Q20**: Is the effort of porting ~2000+ lines of Zig parser+compiler to C worthwhile?
  - *Alternative*: Instead of porting, we could have the phone send the DSL source to the ESP32, which forwards it to a PC for compilation, then receives the bytecode back. But this defeats the "no PC" goal.
  - *Alternative*: Write a minimal "DSL-lite" parser in C that supports a subset of the language.
  - *Assumption*: If implemented, do a faithful port of the full parser.
- **Q21**: Should compiled bytecode be persistable (saved to NVS like the default shader hook)?
  - *Assumption*: Yes, so you can set a telnet-compiled shader as the default.

### Verification Goals

1. ✅ Paste a simple DSL shader into telnet and it compiles and runs
2. ✅ Compilation errors are reported with line numbers
3. ✅ Complex shaders (multi-layer, for loops, if statements) compile correctly
4. ✅ Compiled bytecode matches the PC-compiled bytecode for the same source
5. ✅ Memory is fully reclaimed after compilation
6. ✅ Setting the compiled shader as default persists across reboots

---

## Feature 6: Remove Pre-DSL Zig Effect Code

### Description

Remove the legacy hand-coded Zig shader/effect implementations that predate the DSL system. These effects are now superseded by DSL shaders which can target both native C and bytecode paths. Removing the old code simplifies the codebase and reduces binary size.

### Difficulty: **Easy**

### What Needs to Be Removed

1. **`src/effects.zig`** — Contains 8 legacy effects (~1500 lines):
   - `runPixelHealthSequence` / `runPixelHealthEffect` / `runPixelHealthPhases` (pixel health test)
   - `runRunningDotEffect` / `runRunningPixelLoop` / `drawRunningPixelFrame` (running pixel)
   - `runInfiniteLineEffect` / `drawInfiniteWrappedLineFrame` (single rotating line)
   - `runInfiniteLinesEffect` / `shadeInfiniteLinesPixel` (multiple rotating lines)
   - `runSoapBubblesEffect` / `updateSoapBubbles` / `renderSoapBubblesFrame` (soap bubbles)
   - `runCampfireEffect` / `updateCampfireTongues` / `renderCampfireFrame` (campfire)
   - `runAuroraRibbonsEffect` / `renderAuroraRibbonsFrame` (aurora ribbons)
   - `runRainRippleEffect` / `updateRainSystem` / `renderRainRippleFrame` (rain ripple)
   - All associated config structs, state structs, and helper functions

2. **`src/main.zig`** — Remove the CLI command paths and switch cases that invoke the old effects (lines ~128-176)

3. **`src/root.zig`** — Remove the re-export of `effects` if it becomes empty or is deleted

4. **Tests** — Remove or update any tests specific to the old effects

### What to Keep

- The DSL runtime, parser, compiler, and C emitter (these are the replacement)
- Any shared utility functions from `effects.zig` that the DSL runtime or other modules still use (verify before deleting)
- The `display_logic.zig` coordinate mapping — this is used by everything

### Port to DSL

Before deleting the old Zig effects, port the **Infinite Lines** effect to a DSL shader file (`examples/dsl/v1/infinite-lines.dsl`). This effect features multiple rotating lines with coverage limiting and color transitions — worth preserving as a DSL shader. Use the Zig implementation as reference for the math and parameters.

### Verification Goals

1. ✅ `src/effects.zig` is deleted or contains only shared utilities (if any)
2. ✅ Old effect CLI commands (pixel-health, running-dot, etc.) are removed from `src/main.zig`
3. ✅ `zig build test` passes with all remaining tests
4. ✅ `zig build` produces a smaller binary
5. ✅ DSL-based effects (`dsl-file`, `bytecode-upload`, `native-shader-activate`) still work
6. ✅ Simulator still works with DSL shaders
7. ✅ `infinite-lines.dsl` visually reproduces the old Infinite Lines effect

---

## Recommended Implementation Order

```
┌─────────────────────────────────────┐
│  1. Multiple Native Shaders         │ ← Foundation: shader registry,
│     Difficulty: Medium              │   build pipeline, protocol ext.
└──────────────┬──────────────────────┘
               │
    ┌──────────┴──────────┐
    │                     │
    ▼                     ▼
┌──────────────────┐ ┌───────────────────────┐
│ 2. WiFi AP       │ │ 3. Telnet Server      │ ← Depends on shader registry
│    Fallback      │ │    Difficulty: Med-Hard│   for ls/cd/run commands
│    Diff: Easy    │ └───────────┬───────────┘
└──────────────────┘             │
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
          ┌──────────────────┐   ┌────────────────────────┐
          │ 4. Sound / Audio │   │ 5. On-Device Compiler  │
          │    Diff: Hard    │   │    Diff: Hard (stretch)│
          └──────────────────┘   └────────────────────────┘
```
┌─────────────────────────────────────┐
│  0. Remove Pre-DSL Zig Effects      │ ← Cleanup: simplify codebase first
│     Difficulty: Easy                │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│  1. Multiple Native Shaders         │ ← Foundation: shader registry,
│     Difficulty: Medium              │   build pipeline, protocol ext.
└──────────────┬──────────────────────┘
               │
    ┌──────────┴──────────┐
    │                     │
    ▼                     ▼
┌──────────────────┐ ┌───────────────────────┐
│ 2. WiFi AP       │ │ 3. Telnet Server      │ ← Depends on shader registry
│    Fallback      │ │    Difficulty: Med-Hard│   for ls/cd/run commands
│    Diff: Easy    │ └───────────┬───────────┘
└──────────────────┘             │
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
          ┌──────────────────┐   ┌────────────────────────┐
          │ 4. Sound / Audio │   │ 5. On-Device Compiler  │
          │    Diff: Hard    │   │    Diff: Hard (stretch)│
          └──────────────────┘   └────────────────────────┘
```

### Rationale

0. **Remove Pre-DSL Zig Effects first** — Quick cleanup that reduces code complexity and binary size before building new features on top. The old effects in `src/effects.zig` (~1500 lines, 8 hand-coded shaders) are fully superseded by DSL shaders.

1. **Multiple Native Shaders** — This is the foundation. The telnet server's `ls`/`cd`/`run` commands all depend on having a shader registry. It also establishes the build pipeline for managing many shaders.

2. **WiFi AP Fallback** can be done at any point (no dependencies), but doing it early means you can test the telnet server from your phone right away. It's easy and quick.

3. **Telnet Server** depends on having multiple shaders to browse. Combined with WiFi AP, this gives you full phone-based control.

4. **Sound** uses the built-in 8-bit DAC (GPIO25) — negligible flash/RAM cost, no Bluetooth complexity. The main unknown is whether 8-bit quality is sufficient; a future upgrade path to an external I2S DAC or Bluetooth A2DP is documented.

5. **On-Device Compiler** is a stretch goal. It's substantial effort (~4000 lines of C) for a "fun to have" feature. Implement only if the other features are stable and there's appetite for it.

---

## Summary Table

| # | Feature | Difficulty | Est. Files Changed | Key Risk |
|---|---------|------------|-------------------|----------|
| 1 | Multiple Native Shaders | Medium | ~8-10 | Build pipeline complexity |
| 2 | WiFi AP Fallback | Easy | ~2-3 | None significant |
| 3 | Telnet Server | Medium-Hard | ~5-8 (new module) | RAM budget, mutex design |
| 4 | Sound / Audio (8-bit DAC) | Medium | ~6-8 (new module + DSL ext.) | 8-bit quality, GPIO conflict check |
| 5 | On-Device DSL Compiler | Hard | ~3-5 (new C modules) | Effort vs. value, RAM for parsing |
| 6 | Remove Pre-DSL Zig Effects | Easy | ~3 (delete/trim) | Verify no shared utilities lost |

---

## Open Questions Summary

| # | Question | Context |
|---|----------|---------|
| Q1 | Zig build step vs. separate script for shader compilation? | Multiple Shaders |
| Q2 | Shader name from DSL `effect` name or file name? | Multiple Shaders |
| Q3 | Map subfolder structure to virtual directories? | Multiple Shaders |
| Q4 | Flash budget for ~12+ compiled shaders (~60 KB)? | Multiple Shaders |
| Q5 | Telnet port number (23 vs. custom)? | Telnet |
| Q6 | Single or multiple telnet clients? | Telnet |
| Q7 | Dedicated FreeRTOS task for telnet? | Telnet |
| Q8 | RAM budget for telnet (~5 KB)? | Telnet |
| Q9 | `top` one-shot or live-updating? | Telnet |
| Q10 | Tab completion: character-mode telnet acceptable? | Telnet |
| Q11 | AP always on (APSTA) or only on STA failure? | WiFi AP |
| Q12 | Default AP password? | WiFi AP |
| Q13 | Static IP on AP interface? | WiFi AP |
| Q14 | Audio sample rate (22050 Hz vs. 44100 Hz)? | Sound |
| Q15 | Audio in same DSL file as visuals? | Sound |
| Q16 | Audio only when shader has `audio` block? | Sound |
| Q17 | Audio eval on core 0 or core 1? | Sound |
| Q18 | Add dithering for 8-bit quantization? | Sound |
| Q19 | Which GPIO for DAC output (GPIO25 vs. GPIO26)? | Sound |
| Q20 | Port full parser to C or use DSL-lite subset? | On-Device Compiler |
| Q21 | Persist telnet-compiled bytecode to NVS? | On-Device Compiler |

---

## Assumptions

- Audio output starts with the built-in 8-bit DAC on GPIO25, wired to the amplifier's AUX input
- The Dayton Audio amplifier board has an AUX/line-in that can accept the ESP32 DAC output level
- 8-bit audio quality is acceptable for synthesized tones/effects (lo-fi aesthetic); upgrade path to I2S DAC or Bluetooth A2DP is documented
- The ESP32 has enough CPU headroom on core 1 for audio sample generation alongside 40 FPS rendering
- Single telnet user is sufficient (personal use device)
- WiFi AP overhead is negligible for shader performance
- No hardware changes are planned (same ESP32, same 4 MB flash)
