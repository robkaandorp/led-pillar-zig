# ESP32 DSL Math Function Optimization — Findings

**Platform:** ESP32 (Xtensa LX6, 240 MHz, single-precision FPU)  
**Compiler:** GCC 14.2 with `-O3 -ffast-math -fno-math-errno`  
**Benchmark:** 100,000 iterations per function, `esp_timer_get_time()` µs precision  

## Summary

Six math functions in the DSL shader pipeline were replaced with custom
fast approximations.  Three others were evaluated but found to already be
optimal on Xtensa.  All composite/helper functions were profiled; none
required changes since they are already defined as `static inline` and
benefit transitively from the primitive-level optimizations.

**Net effect:** The aurora-ribbons-classic shader went from **~9 FPS** (all
library math) to a **stable 40 FPS** (target rate).  A comprehensive 6-layer
benchmark shader exercising every DSL function also achieves 40 FPS with
~7.7 ms compute per frame (well within the 25 ms budget).

---

## Primitive Math Functions

### Optimized (redirected via `#define`)

| Function | Library (ns/call) | Fast (ns/call) | Speedup | Technique | Max Error | Visual Impact |
|----------|------------------:|---------------:|--------:|-----------|-----------|---------------|
| `sinf`   | 1,637 | 307–339 | **4.8–5.3×** | Parabolic + correction pass | < 0.001 | None visible |
| `cosf`   | 1,658 | 294–360 | **4.6–5.8×** | `sin(x + π/2)` | < 0.001 | None visible |
| `sqrtf`  | 617–695 | 232–246 | **2.6–3.0×** | Quake inverse-sqrt + Newton | ~0.03% relative | None visible |
| `floorf` | 500–518 | 125–196 | **2.6–4.0×** | Cast-to-int trick | Exact for \|x\| < 2²³ | None |
| `logf`   | 1,592–1,669 | 259–273 | **6.1×** | IEEE 754 bit decomposition + cubic polynomial | ~0.06% relative | None visible |
| `log10f` | 2,026–2,118 | 258–305 | **6.6–7.9×** | `fast_logf × (1/ln10)` | ~0.06% relative | None visible |

### Not Redirected (library is already optimal)

| Function | Library (ns/call) | Fast Wrapper (ns/call) | Reason |
|----------|------------------:|-----------------------:|--------|
| `fabsf`  | 54–76 | 100–128 | Compiler emits Xtensa `ABS.S` (single instruction). Wrapper adds overhead. |
| `fminf`  | 66–111 | 66–139 | Compiler emits `MOVF.S` conditional-move. Wrapper adds function-call overhead. |
| `fmaxf`  | 66–140 | 66–128 | Same as `fminf`. |

**Key insight:** On Xtensa with `-O3 -ffast-math`, the compiler already
generates single-instruction sequences for `fabsf`, `fminf`, and `fmaxf`.
Any C wrapper — even `static inline` — adds overhead via the function-pointer
indirection needed by the benchmark harness.  In actual shader code (where
the compiler inlines directly) these are already a single instruction.

---

## Composite / Helper Functions

These are `static inline` functions defined in the DSL-generated C code.
They compose the primitive math functions above and benefit transitively
from the fast redirects.  All timings below include the fast math redirects.

| Function | ns/call | Notes |
|----------|--------:|-------|
| `dsl_smoothstep` | 104–185 | Uses division `1.0/(edge1-edge0)`, clamp, cubic Hermite. Fast enough. |
| `dsl_clamp` | 100–151 | Two comparisons + conditional assigns. Already optimal. |
| `dsl_fract` | 137–173 | `x - floorf(x)`. Benefits from fast `floorf`. |
| `dsl_blend_over` | 657–669 | **Most expensive composite.** Does alpha blending with `1.0/out_a` division. Division is inherently expensive on Xtensa (~14 cycles for `DIV0S.S` sequence), but blend_over is called once per layer overlap, not per-pixel-per-function. |
| `dsl_circle` | 239–248 | `sqrtf(x²+y²) - radius`. Benefits from fast `sqrtf`. |
| `dsl_box` | 368–410 | Uses `fabsf`, `fmaxf`, `sqrtf`. Benefits from fast `sqrtf`. |
| `dsl_wrapdx` | 101–168 | Modular distance calculation. Cheap. |
| `dsl_hash01` | 192–207 | Bitwise float manipulation. No math library calls. |
| `dsl_hash_signed` | 132–189 | Same as hash01, remapped to [-1,1]. |
| `dsl_hash_coords01` | 216–236 | Two-input coordinate hash. No library calls. |

**No composite function warranted a dedicated fast replacement** — their costs
are dominated by the primitive math they call (already optimized) or by
integer/bitwise operations that are already single-cycle on Xtensa.

---

## Optimization Techniques — Detail

### `dsl_fast_sinf` / `dsl_fast_cosf`
Parabolic approximation: wraps input to [-π, π], then computes
`y = (4/π)x + (-4/π²)x|x|` with one correction pass `y = 0.225(y|y| - y) + y`.
Peak error < 0.001 (vs max 1.0 output range).  `cosf` is just `sinf(x + π/2)`.

**Downside:** At extreme input values (|x| > 10⁶), the floor-based wrap
accumulates floating-point error.  In practice, shader `time` values stay
well below this.

### `dsl_fast_sqrtf`
Quake III–style inverse square root: uses IEEE 754 bit manipulation for an
initial guess, one Newton-Raphson refinement, then multiplies by `x` to get
`√x`.  Returns 0 for non-positive inputs.

**Downside:** ~0.03% relative error.  Visually indistinguishable for LED
color values (8-bit output = 0.4% quantization anyway).

### `dsl_fast_floorf`
Casts to `int` then back to `float`, adjusting for negative non-integers.
Compiles to Xtensa `TRUNC.S` + `FLOAT.S` (2 instructions vs ~50 for newlib).

**Downside:** Only exact for |x| < 2²³ (~8.4M).  Shader coordinates and time
values never approach this limit.

### `dsl_fast_logf` / `dsl_fast_log10f`
Decomposes the IEEE 754 float into exponent `e` and mantissa `m ∈ [1,2)`,
then `ln(x) = e·ln(2) + polynomial(m-1)`.  Uses a 3rd-degree polynomial
fitted to minimize max error over [1,2).  `log10f` multiplies by `1/ln(10)`.

**Downside:** ~0.06% relative error.  For the DSL's `ln` and `log` functions
(used in distance falloff and intensity curves), this is invisible at 8-bit
LED output precision.

### `fabsf`, `fminf`, `fmaxf` — NOT optimized
The Xtensa FPU has dedicated instructions for these operations.  With
`-O3 -ffast-math`, GCC emits them directly.  Our wrapper functions actually
*regressed* performance by 0.5–0.6× due to function-call overhead that
prevents the compiler from using the native instructions.

---

## Benchmark Methodology

- **Location:** Benchmarks run on the TCP handler thread (core 0). The shader
  render loop runs on core 1.  Both cores operate at the same 240 MHz clock.
- **Iteration count:** 100,000 per function.  Input values vary per iteration
  (`input + i*0.0001f`) to prevent the compiler from hoisting the computation.
- **Dead-code prevention:** Results accumulated into a `volatile float` sink.
- **Timing:** `esp_timer_get_time()` provides µs-precision timestamps.
- **Variability:** WiFi interrupts (core 0) cause ±10% jitter on individual
  runs.  The ranges shown above span two separate measurement runs.

To re-run benchmarks, define `FW_RUN_SHADER_BENCH=1` (e.g., via
`CMakeLists.txt` or `-DFW_RUN_SHADER_BENCH=1`) and activate the native shader
via the CLI `native-shader-activate` command.

---

## Frame-Level Performance

| Shader | Compute (µs/frame) | LED Push (µs/frame) | Total (µs/frame) | FPS |
|--------|-------------------:|--------------------:|-----------------:|----:|
| aurora-ribbons-classic (4 layers, trig-heavy) | ~14,700 | ~391 | ~15,100 | 40 |
| math-benchmark (6 layers, all functions) | ~7,710 | ~395 | ~8,100 | 40 |

The math-benchmark shader is lighter despite having more layers because it
doesn't use deeply nested `sin(sin(cos(…)))` chains like aurora-ribbons.

**Remaining headroom:** With a 25 ms frame budget (40 FPS), aurora-ribbons
uses ~60% of the budget.  Shaders up to ~24 ms compute could still hit 40 FPS.
Beyond that, the frame rate will degrade proportionally.
