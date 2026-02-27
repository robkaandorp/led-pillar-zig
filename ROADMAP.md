# LED Pillar Feature Roadmap

Completed features have been moved to [DONE.md](DONE.md).

> **Parked**: On-Device DSL Compiler — see [ON_DEVICE_DSL_COMPILER.md](ON_DEVICE_DSL_COMPILER.md)

---

## Feature 1: More Shaders (Content)

### Description

The pipeline is complete — DSL authoring, native C compilation, multi-shader registry, telnet shell, audio. The system needs more content to take advantage of it. Currently 11 shaders exist; the goal is a diverse library that showcases the pillar's cylindrical display and audio capabilities.

### Difficulty: **Easy** (per shader)

### What to Do

- Write more audiovisual shaders (tone-pulse is currently the only one with audio)
- Create shaders that use the cylindrical wrap-around creatively (spirals, orbiting objects, barber-pole effects)
- Shaders with dramatic contrast between quiet and intense moments
- Organize into thematic subfolders (see Feature 3)

### Ideas

- Ambient/meditative shaders (slow color drifts, breathing patterns)
- Energetic shaders (fast particles, strobing, rhythmic pulses)
- Audio shaders: chord progressions, arpeggiators, drum-like percussion, generative melodies
- Nature-inspired: water, fire variations, starfield, lightning

### Verification Goals

1. Each shader runs at 40 FPS on the ESP32
2. Audio shaders produce clean sound without clicks or dropouts
3. Shaders look distinct from each other and use the pillar layout well

---

## Feature 2: DSL Language Improvements

### Description

Extend the DSL with builtins and operators that unlock more expressive shaders. Prioritized by how much they expand what's possible.

### Difficulty: **Easy to Medium** (per builtin)

### 2a: `noise(x, y)` / `noise3(x, y, z)` — Perlin/simplex noise

Nearly every procedural graphics system has smooth noise. Currently shaders fake it with `hash01`/`hashSigned` which gives sharp random values, not smooth organic gradients. Noise unlocks clouds, water, terrain, organic movement.

- Implement a noise function in C (~50-80 lines, e.g., simplex noise)
- Add `noise` (2D) and `noise3` (3D) as DSL builtins
- Add to parser, C emitter, bytecode VM
- Performance: must be fast enough that a shader calling noise per pixel still hits 40 FPS

### 2b: `pow(base, exp)` — Power function

Useful for gamma curves, falloff shaping, easing. Currently the only option is `x * x` for square.

- One new builtin entry in parser, emitter, VM
- Calls `powf()` in C

### 2c: `mod(x, y)` — Modulo

Essential for repeating patterns and tiling. Currently no way to do modulo arithmetic in DSL.

- New builtin or `%` operator in parser, emitter, VM
- Calls `fmodf()` in C

### Verification Goals

1. Each new builtin works correctly in DSL → C and DSL → bytecode paths
2. Existing shaders and tests still pass
3. At least one example shader demonstrates each new builtin
4. Performance: noise-heavy shader hits 40 FPS on ESP32

---

## Feature 3: Shader Subfolder Support in Registry

### Description

With more shaders, a flat `/native` folder gets crowded. The telnet shell already supports `cd` and path display, but all shaders currently land in `/native`. The build system already scans subfolders but flattens them.

### Difficulty: **Easy**

### What to Do

1. Organize `examples/dsl/v1/` into subfolders (e.g., `ambient/`, `energetic/`, `audio/`)
2. Update `build_shader_registry.zig` to preserve relative path as the folder field instead of hardcoding `/native`
   - E.g., `examples/dsl/v1/ambient/ocean.dsl` → folder `/native/ambient`, name `ocean`
3. Verify telnet `cd`/`ls` navigation works with nested folders

### Verification Goals

1. `ls` at `/native` shows subdirectories
2. `cd /native/ambient` and `ls` shows only ambient shaders
3. `run` still works with shader names from subdirectories
4. Tab completion works across subfolder boundaries

---

## Feature 4: Real FPS in Telnet `top`

### Description

The `top` command currently shows hardcoded `FPS: 40.0`. When debugging shader performance on the device, you want actual measured FPS.

### Difficulty: **Easy**

### What to Do

1. Track `esp_timer_get_time()` deltas in the shader render loop (fw_tcp_server.c)
2. Compute a rolling average FPS (e.g., exponential moving average over last ~40 frames)
3. Store the computed FPS in `fw_tcp_server_state_t`
4. Update telnet `top` and v3 telemetry to report the measured value
5. Make `top` a live-updating display: refresh the output every ~1 second until the user presses any key, then return to the prompt (similar to Unix `top` behavior)

### Verification Goals

1. `top` shows actual FPS that varies slightly around 40.0
2. A computationally heavy shader shows lower FPS in `top`
3. Shader render performance is not affected by the measurement overhead
4. `top` refreshes automatically every ~1 second with updated stats
5. Pressing any key exits `top` and returns to the shell prompt cleanly

---

## Feature 5: Audio Phase Accumulator

### Description

The current audio generates each sample as `eval_audio(time + i/sample_rate, seed)`. For FM synthesis or complex waveforms, this approach causes phase discontinuities when frequency changes. A proper oscillator uses a phase accumulator that carries state between samples.

### Difficulty: **Medium**

### What to Do

1. Add a `phasor(freq)` builtin that returns a sawtooth 0→1 ramp with continuous phase
   - Internally accumulates `phase += freq / sample_rate` per sample, wraps at 1.0
   - Multiple `phasor()` calls in the same audio block each get independent accumulators
2. Alternative: add a `phase` input to the audio block that auto-increments
3. Requires adding per-sample state to the audio evaluation (currently stateless)
4. Parser, C emitter, and bytecode VM all need updates

### Verification Goals

1. `phasor(440)` produces a clean sawtooth at 440 Hz with no clicks
2. `sin(phasor(440) * TAU)` produces a clean sine tone identical to the current approach for constant frequency
3. FM synthesis (`sin(phasor(440 + sin(time * 5) * 200) * TAU)`) produces smooth frequency sweeps without clicks
4. Multiple independent phasors work in the same audio block

---

## Recommended Implementation Order

```
┌───────────────────────────────────────┐
│  1. More Shaders (Content)            │ ← Immediate: no code changes needed
│     Difficulty: Easy                  │
└───────────────────────────────────────┘

┌───────────────────────────────────────┐
│  2. DSL Builtins: noise, pow, mod     │ ← Unlocks better shader authoring
│     Difficulty: Easy–Medium           │
└──────────────┬────────────────────────┘
               │
    ┌──────────┴──────────┐
    │                     │
    ▼                     ▼
┌──────────────────┐ ┌───────────────────────┐
│ 3. Subfolder     │ │ 4. Real FPS in top    │
│    Support       │ │    Difficulty: Easy   │
│    Diff: Easy    │ └───────────────────────┘
└──────────────────┘

┌───────────────────────────────────────┐
│  5. Audio Phase Accumulator           │ ← When more audio shaders are needed
│     Difficulty: Medium                │
└───────────────────────────────────────┘
```

Items 1–4 are independent and can be done in any order or in parallel. Item 5 should wait until more experience with audio shaders reveals what's actually needed.

---

## Assumptions

- No hardware changes are planned (same ESP32, same 4 MB flash)
- Audio output stays on built-in 8-bit DAC (GPIO25) for now; external I2S DAC upgrade path documented in DONE.md
- Single telnet user is sufficient (personal use device)
- Shader performance target remains 40 FPS
