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

### Current conclusion
- The dominant cost for heavy shaders is still in per-pixel VM work (especially builtin-heavy expressions), not just transport or rendering I/O.
- The dominant remaining win is reducing builtin-heavy work per pixel (compiler-side simplification/CSE/constant folding and cheaper builtin execution), because builtin boundaries still require float math.
