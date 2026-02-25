# ESP32 Bytecode Runtime Findings

## Scope
This document evaluates practical ways to send compiled bytecode to an ESP32 and execute it there, with emphasis on:
- reliable WiFi/networking
- preference for wireless firmware updates (OTA)
- realistic reuse of the current Zig shader runtime

---

## Practical model for bytecode-on-ESP32
Across all options, the working pattern is the same:
1. Compile effect/shader logic on host (PC/server) into compact bytecode.
2. Deliver bytecode to device over network (HTTP/MQTT/TCP/WebSocket).
3. Validate payload (version, size, CRC/signature), then store in flash (NVS/LittleFS/partition).
4. Execute inside a constrained runtime loop with watchdog-safe timing and memory limits.
5. Keep a safe fallback program if new bytecode crashes or times out.

This is feasible on ESP32, but runtime design must be conservative (bounded memory, bounded instruction count, crash-safe rollback).

---

## Option comparison

| Choice | Viability for bytecode runtime | Networking reliability | OTA/firmware update story | Implementation effort |
|---|---|---|---|---|
| 1) ESPHome external component runtime | Medium | High (ESPHome WiFi stack is mature) | High (ESPHome OTA is built-in and easy) | Low-Medium |
| 2) Custom firmware with ESP-IDF | High | Very High (native control over WiFi/event/reconnect/tasking) | High (native OTA APIs, robust partition strategy) | High |
| 3) Custom firmware with Arduino framework | Medium-High | Medium-High (good in many projects, less control than IDF) | Medium-High (ArduinoOTA/HTTP OTA available) | Medium |

---

## 1) ESPHome external component runtime

### Pros
- Fastest path if you want configuration-driven deployment and existing Home Assistant integration.
- Built-in WiFi handling, logging, provisioning, and OTA are already solved.
- External components allow custom C++ logic, so a simple bytecode VM is possible.
- Good operational ergonomics for field updates and diagnostics.

### Cons
- Runtime flexibility is constrained by ESPHome architecture and update cycle.
- Harder to build a deeply custom scheduler/memory model for strict real-time rendering.
- Non-trivial custom VM/runtime code can become awkward in ESPHome component boundaries.
- Tighter coupling to ESPHome ecosystem than a standalone firmware.

### Fit vs requirements
- **Reliable WiFi/networking:** good.
- **Wireless firmware update preference:** very good.
- Best when operational convenience beats low-level control.

---

## 2) Custom firmware with ESP-IDF

### Pros
- Maximum control over networking, FreeRTOS tasks, memory, watchdog behavior, and timing.
- Best foundation for a robust bytecode runtime (sandboxing, instruction budget, dual-buffering, crash recovery).
- Strong OTA support (rollback, partition-table strategies, signed images if needed).
- Easier to implement production-grade resilience (backoff/reconnect strategies, telemetry, safe-mode boot).

### Cons
- Highest engineering effort and maintenance burden.
- More platform code to own (network stack integration, update orchestration, diagnostics surfaces).
- Slower to first demo compared to ESPHome/Arduino.

### Fit vs requirements
- **Reliable WiFi/networking:** strongest option.
- **Wireless firmware update preference:** strong and flexible.
- Best when reliability and long-term control are primary.

---

## 3) Custom firmware with Arduino framework

### Pros
- Faster development than raw ESP-IDF for many teams.
- Broad library ecosystem and simpler onboarding.
- OTA and networking are readily available and sufficient for many deployments.
- Practical compromise when full IDF complexity is not desired.

### Cons
- Less direct control and observability than ESP-IDF in edge/failure cases.
- Library quality variability can impact long-term reliability.
- Complex runtime behavior (strict scheduling, memory guarantees) is harder to enforce cleanly.

### Fit vs requirements
- **Reliable WiFi/networking:** usually good, but less deterministic under stress than IDF-first designs.
- **Wireless firmware update preference:** good.
- Best for moderate complexity with faster iteration.

---

## Can the current Zig shader runtime run directly on ESP32?

## Short answer
Not as a straightforward, low-risk path today.

## Toolchain/cross-compilation reality
- ESP32 family is split across Xtensa (ESP32/S2/S3) and RISC-V (C3/C6), which complicates a single embedded Zig path.
- Zig can cross-compile in many scenarios, but direct, smooth ESP-IDF integration for production firmware is not the common path teams use.
- In practice, ESP32 firmware ecosystems are centered on ESP-IDF/Arduino C/C++; Zig-on-ESP32 remains a higher-friction setup with integration/debug risk.
- For this project, direct port of the full Zig runtime onto device is likely higher risk than value for first production iteration.

## Practical reuse strategy
Reuse the Zig investment where it is strongest:
1. Keep Zig as the **host-side compiler/tooling** for effects/shaders and bytecode generation.
2. Freeze a versioned bytecode spec (opcodes, limits, fixed-point rules, safety checks).
3. Implement a minimal interpreter VM on ESP32 in **ESP-IDF C/C++** (or Arduino C++ if that path is chosen).
4. Share conformance tests/vectors between Zig compiler output and ESP32 VM behavior.
5. Add runtime guards (instruction count cap, stack cap, memory cap, watchdog-friendly yielding).

This preserves core logic/IP while minimizing embedded toolchain risk.

---

## Recommendation

Choose **Custom firmware with ESP-IDF** as the primary path.

Why:
- It best satisfies the explicit requirements for reliable networking and robust wireless updates.
- It gives the control needed for a safe, deterministic bytecode runtime on constrained hardware.
- It enables long-term maintainability for production-grade fault handling and performance tuning.

Recommended rollout:
1. Build an ESP-IDF MVP: bytecode download + validate + execute + fallback.
2. Keep Zig runtime/compiler host-side; do not block on full Zig-on-device.
3. Add OTA rollback and network resilience early (before feature expansion).
4. If speed-to-demo is critical, optionally prototype runtime semantics in ESPHome first, then migrate to IDF for production.

---

## ESP32 runtime optimization findings (implemented)

### Measured baseline behavior
- Complex shaders (for example `aurora-ribbons-classic`) showed very low on-device throughput.
- Host-side v3 monitor telemetry reported slow-frame timings in the multi-hundred ms range, and in some regression cases above 1 second.

### Optimizations that were implemented
1. **Continuous shader render loop + diagnostics**
   - Added persistent shader render task and slow-frame telemetry counters exposed via v3 query.
2. **Fast trig approximation**
   - Switched VM `sin/cos` builtins from libm calls to lightweight approximation.
3. **Expression hot-path cleanup**
   - Reduced scalar opcode overhead in expression eval (`negate/add/sub/mul/div`).
4. **VM compile flags**
   - Forced VM translation unit to build with `-O3` and math-focused optimization flags.
5. **Dynamic param evaluation refinement**
   - Added `x`/`y` dependency tracking and cached `y`-only dynamic params per row.
6. **Runtime scheduling/power tuning**
   - Disabled Wi-Fi power save and raised default CPU frequency target to 240 MHz.
7. **Fixed-point scalar arithmetic (experiment)**
   - VM scalar expression math is currently Q16.16 fixed-point for core scalar ops (`negate/add/sub/mul/div`), while builtin boundaries remain float.
8. **Fixed-slot conversion reduction**
   - Inputs and param cache are now stored/loaded as fixed-point scalars directly to avoid repeated float->fixed conversion in hot slot-load paths.
9. **Fixed scalar builtin fast paths**
   - Scalar-heavy builtins (`abs`, `floor`, `fract`, `min`, `max`, `clamp`) now execute directly in fixed-point without float conversion.
10. **Spatially uniform frame fast path**
   - Runtime now detects programs that do not depend on `x/y` in layer execution and renders a single VM pixel per frame, then fills the whole frame buffer with that color.
11. **Frame pacing + unchanged uniform frame skip**
   - Shader task now uses fixed-period scheduling (`vTaskDelayUntil`) so render cost does not add an extra full frame interval delay.
   - For uniform shaders, repeated identical colors skip LED push entirely to avoid redundant output overhead on static frames.
12. **LED output hot-path specialization**
   - Added dedicated fast paths for RGB frame uploads and uniform RGB pushes to reduce per-pixel decode overhead in firmware output code.
13. **Parallel segment RMT transmit**
   - Updated `led_strip` RMT refresh path to enqueue transmit without per-segment blocking wait, allowing segment transmissions to overlap instead of serializing each segment refresh.

### Regressions observed
- A LUT-based `sin/cos` path regressed significantly on-device and was reverted.
- One mapping-cache attempt caused startup `ESP_ERR_NO_MEM` and was reverted.

### Current conclusion (phase 1)
- The dominant cost for heavy shaders is still in per-pixel VM work (especially builtin-heavy expressions), not just transport or rendering I/O.
- The dominant remaining win is reducing builtin-heavy work per pixel (compiler-side simplification/CSE/constant folding and cheaper builtin execution), because builtin boundaries still require float math.

---

## Bytecode VM deep optimization (phase 2)

### Context
Phase 1 optimizations (above) brought performance to a reasonable level but the VM remained slow for complex shaders like `aurora-ribbons-classic` (4 layers with for loops, ~1000 expression ops per pixel). This phase investigated fundamental interpreter architecture changes.

**Benchmark shader:** `aurora-ribbons-classic.dsl` — 1200 pixels (30×40), 4-iteration for loop per pixel.

### Performance progression

| # | Optimization | µs/frame | µs/pixel | FPS | vs baseline |
|---|---|---|---|---|---|
| 0 | Baseline (Q16.16 + fast math builtins) | 933,335 | 777 | 1.1 | 1.0× |
| 1 | Q16.16 → native float | 839,581 | 699 | 1.2 | 1.1× |
| 2 | Pre-decoded instruction dispatch | 429,089 | 357 | 2.3 | 2.2× |
| 3 | Inline 14 common builtins | 421,715 | 351 | 2.4 | 2.2× |
| 4 | Computed goto + 8-byte ops + HALT + IRAM | 260,000 | 217 | 3.8 | 3.6× |
| 5 | IRAM all hot-path + flatten | 257,000 | 214 | 3.9 | 3.6× |
| — | **Native C shader (reference)** | **14,700** | **12** | **66** | **— (18× faster)** |

### Optimization details

#### 1. Q16.16 → native float (10% improvement)
- Removed all Q16.16 fixed-point infrastructure (6 helper functions, 5 defines)
- Changed `fw_bc3_value_t.as.scalar` from `int32_t` to `float`
- All arithmetic operations now use hardware FPU directly
- **Why only 10%:** The bottleneck was not arithmetic but interpreter dispatch overhead — per-instruction cursor reads with bounds checks, if-else chain opcode dispatch, and tag checking on every operation

#### 2. Pre-decoded instruction dispatch (2.2× total speedup)
- Added `fw_bc3_decoded_op_t` struct and `fw_bc3_decoded_opcode_t` enum (13 opcodes)
- Pre-decode pass at parse time converts byte stream to flat decoded-op array
- Runtime evaluator uses tight switch on contiguous enum values → GCC generates jump table
- Split generic opcodes into specialized variants (e.g., `PUSH_LITERAL` → `PUSH_SCALAR_LIT`/`PUSH_VEC2_LIT`/`PUSH_RGBA_LIT`; `PUSH_SLOT` → `PUSH_INPUT`/`PUSH_PARAM`/`PUSH_FRAME_LET`/`PUSH_LET`)
- Eliminated ALL runtime bounds checks and type-tag checks from the hot path
- **This was the single largest improvement** — demonstrates that dispatch overhead, not computation, dominated VM cost

#### 3. Inline builtins as separate decoded opcodes (marginal improvement)
- Added 14 new enum values (SIN, COS, SQRT, ABS, FLOOR, FRACT, LN, LOG, MIN, MAX, CLAMP, SMOOTHSTEP, VEC2, RGBA)
- Each builtin operates directly on the stack without generic call/dispatch overhead
- **Why marginal:** Function call overhead for builtins was small relative to total dispatch cost already eliminated by optimization #2

#### 4. Computed goto + compact ops + IRAM (3.6× total speedup)
This was a multi-part optimization:

**Compact decoded ops (20 → 8 bytes):**
- Removed `vec2` and `rgba` members from `fw_bc3_decoded_op_t` union
- Vec2/RGBA literals decomposed at decode time into multiple scalar pushes + constructor call
- Result: 2048 ops × 8 bytes = 16 KB (vs 1024 × 20 = 20 KB before) — less memory AND more capacity
- Better cache utilization: ~1000 ops × 8 bytes fits well in 32 KB d-cache

**Computed goto dispatch (replacing switch):**
- Each instruction handler ends with `goto *dispatch_table[op->op]` — eliminates central switch indirect jump
- Each dispatch site has its own branch prediction entry (vs shared prediction for switch)
- Added HALT sentinel at end of each expression to eliminate loop counter check entirely

**IRAM_ATTR on eval_expression:**
- Places hot interpreter function in zero-wait-state IRAM (single-cycle access vs potential i-cache misses from flash)
- Used ~2 KB of IRAM (25 KB remaining after phase 2 full IRAM expansion)

#### 5. IRAM all hot-path + flatten (~1% improvement)
- Added `IRAM_ATTR` to: `execute_statement_block`, `evaluate_params`, `runtime_eval_pixel`, `clamp01`, `linearstep`, `smoothstep`, `blend_over`
- Added `__attribute__((flatten))` to `eval_expression` to force-inline all math callees
- **Why minimal:** The eval_expression inner loop was already the dominant cost; outer call overhead was negligible

### Analysis of remaining overhead

At 214 µs/pixel with 240 MHz clock = **51,360 cycles per pixel**. With ~1000 decoded ops per pixel:
- **~51 cycles per decoded op** (actual measured)
- Theoretical minimum for computed-goto interpreter: ~15–20 cycles per op
- Native compiler output: ~2.9 cycles per op (12 µs × 240 MHz / ~1000 ops)

The **18× gap** between VM and native shader is a fundamental consequence of interpretation:
- Each VM instruction requires: fetch op struct from memory, dispatch via indirect jump, execute, advance pointer, dispatch next
- Native code executes arithmetic inline with no dispatch overhead, enables register allocation across expressions, and allows compiler to reorder/pipeline instructions

### Memory impact
- Free heap before buffer alloc: 178,808 bytes (improved from 174,712 due to smaller decoded ops)
- IRAM remaining: 25 KiB (from original 31 KiB; used ~6 KB for IRAM_ATTR functions)
- Decoded ops storage: 16 KB (2048 × 8 bytes) — allocated within bytecode program struct

### Conclusion

The bytecode VM has been optimized **3.6× from baseline** through architectural changes (pre-decode, computed goto, compact ops, IRAM placement). Further micro-optimizations yield diminishing returns (<1%).

The **18× performance gap vs native C shader** is inherent to interpretation and cannot be closed without fundamentally different approaches (JIT compilation, which is impractical on ESP32 due to Harvard architecture). For complex shaders like `aurora-ribbons-classic`, the bytecode VM achieves ~3.9 FPS vs the native shader's 66 FPS.

**Recommendation:**
- Use the **native C shader path** for production deployments requiring high frame rates
- Use the **bytecode VM** for rapid development/iteration (upload new shader without reflashing)
- The DSL compiler's C code emission path bridges both: develop in DSL → emit C → compile into firmware for native-speed execution
