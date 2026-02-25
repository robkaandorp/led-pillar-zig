#include "fw_native_shader.h"
#include <math.h>
#include "esp_timer.h"
#include "esp_log.h"

static const char *BENCH_TAG = "shader_bench";

// ---------------------------------------------------------------------------
// Fast math approximations for generated shaders
// ---------------------------------------------------------------------------
// The aurora-ribbons shader calls sinf ~43,200 times per frame and sqrtf
// ~9,600 times.  On ESP32 at 240 MHz these dominate the per-frame cost.
// The approximations below trade a tiny amount of precision (max error
// ~0.001 for sin, ~0.03% for sqrt) for a large speed-up so that we can
// hit 40 FPS.

// Fast floor: avoid the newlib C library floorf() (which on Xtensa goes
// through software sf_floor.c) and use a cast-based inline that compiles
// to just TRUNC.S + FLOAT.S + a conditional subtract (~3–4 instructions
// vs ~50+ for the library call).  43,200 calls per frame makes this the
// single largest win.
static inline float dsl_fast_floorf(float x) {
    float t = (float)(int)x;
    return t - (t > x);  // adjust for negative non-integers
}

// Fast sin approximation – parabolic with one correction pass.
// Input: any float.  Output: ≈ sinf(x), max |error| < 0.001.
static inline float dsl_fast_sinf(float x) {
    // Wrap x into [-PI, PI]
    const float TWO_PI     = 6.283185307f;
    const float INV_TWO_PI = 0.159154943f;
    x -= TWO_PI * dsl_fast_floorf(x * INV_TWO_PI + 0.5f);

    // Parabolic core:  y = (4/π)x + (−4/π²)x|x|
    const float B = 1.27323954f;   // 4 / π
    const float C = -0.40528473f;  // −4 / π²
    float y = B * x + C * x * fabsf(x);

    // Extra-precision correction (raises peak error from ~0.056 to ~0.001)
    const float P = 0.225f;
    y = P * (y * fabsf(y) - y) + y;
    return y;
}

// Fast cosf via sin shift.
static inline float dsl_fast_cosf(float x) {
    return dsl_fast_sinf(x + 1.5707963268f);
}

// Fast sqrtf – Quake-style inverse-sqrt turned into sqrt.
// Max relative error ≈ 0.03 %.
static inline float dsl_fast_sqrtf(float x) {
    if (x <= 0.0f) return 0.0f;
    union { float f; uint32_t i; } conv = { .f = x };
    conv.i = 0x5f3759dfU - (conv.i >> 1);          // initial 1/√x guess
    float y = conv.f;
    y = y * (1.5f - (0.5f * x * y * y));            // one Newton-Raphson step
    return x * y;                                    // x * (1/√x) = √x
}

// Fast natural log approximation using IEEE 754 float bit tricks.
// Decomposes x = 2^e * m, then ln(x) = e*ln(2) + ln(m).
// Uses a polynomial to approximate ln(m) for m in [1,2).
// Max relative error ≈ 0.06% for x > 0.
static inline float dsl_fast_logf(float x) {
    if (x <= 0.0f) return -87.33f;  // -FLT_MAX-ish, avoids -inf
    union { float f; uint32_t i; } conv = { .f = x };
    int e = (int)((conv.i >> 23) & 0xFF) - 127;
    conv.i = (conv.i & 0x007fffffU) | 0x3f800000U;  // m in [1,2)
    float m = conv.f;
    // Polynomial approximation: ln(m) ≈ a*(m-1) + b*(m-1)^2 + c*(m-1)^3
    float t = m - 1.0f;
    float ln_m = t * (0.99949556f + t * (-0.49190896f + t * 0.28947478f));
    return (float)e * 0.6931471806f + ln_m;
}

// Fast base-10 log: log10(x) = ln(x) / ln(10).
static inline float dsl_fast_log10f(float x) {
    return dsl_fast_logf(x) * 0.4342944819f;  // 1/ln(10)
}

// Fast fabsf – bit-clear the sign bit.  On Xtensa with -O3 the compiler
// already emits ABS.S for fabsf(), so this is mainly a safety net.
static inline float dsl_fast_fabsf(float x) {
    union { float f; uint32_t i; } conv = { .f = x };
    conv.i &= 0x7fffffffU;
    return conv.f;
}

// Fast fminf/fmaxf – branchless using ternary (compiler can use
// Xtensa MOVF.S conditional-move instruction).
static inline float dsl_fast_fminf(float a, float b) {
    return (a < b) ? a : b;
}
static inline float dsl_fast_fmaxf(float a, float b) {
    return (a > b) ? a : b;
}

// Redirect math calls inside the generated shader to fast versions.
#define sinf   dsl_fast_sinf
#define cosf   dsl_fast_cosf
#define sqrtf  dsl_fast_sqrtf
#define floorf dsl_fast_floorf
#define logf   dsl_fast_logf
#define log10f dsl_fast_log10f
// Note: fabsf, fminf, and fmaxf are NOT redirected — the Xtensa compiler
// already emits single-instruction ABS.S / conditional-move for these,
// making them faster than any wrapper function.

#include "generated/dsl_shader_generated.c"

#undef sinf
#undef cosf
#undef sqrtf
#undef floorf
#undef logf
#undef log10f

void fw_native_shader_eval_pixel(
    float time_seconds,
    float frame_counter,
    float x,
    float y,
    float width,
    float height,
    fw_native_shader_color_t *out_color
) {
    if (out_color == 0) {
        return;
    }
    dsl_color_t generated_color = {0};
    dsl_shader_eval_pixel(time_seconds, frame_counter, x, y, width, height, &generated_color);
    out_color->r = generated_color.r;
    out_color->g = generated_color.g;
    out_color->b = generated_color.b;
    out_color->a = generated_color.a;
}

static inline uint8_t fw_native_channel_to_u8(float value) {
    if (value <= 0.0f) return 0U;
    if (value >= 1.0f) return 255U;
    return (uint8_t)(value * 255.0f + 0.5f);
}

int __attribute__((flatten)) fw_native_shader_render_frame(
    float time_seconds,
    float frame_counter,
    uint16_t width,
    uint16_t height,
    int serpentine,
    uint8_t *frame_buffer,
    size_t buffer_len
) {
    const size_t bytes_per_pixel = 3U;
    const size_t required = (size_t)width * height * bytes_per_pixel;
    if (frame_buffer == 0 || buffer_len < required) {
        return -1;
    }

    const float fw = (float)width;
    const float fh = (float)height;

    for (uint16_t y = 0; y < height; y++) {
        for (uint16_t x = 0; x < width; x++) {
            dsl_color_t c = {0};
            dsl_shader_eval_pixel(time_seconds, frame_counter, (float)x, (float)y, fw, fh, &c);

            uint16_t mapped_y = y;
            if (serpentine && ((x & 1U) != 0U)) {
                mapped_y = (uint16_t)(height - 1U - y);
            }
            const size_t offset = ((size_t)x * height + mapped_y) * bytes_per_pixel;
            frame_buffer[offset]     = fw_native_channel_to_u8(c.r);
            frame_buffer[offset + 1] = fw_native_channel_to_u8(c.g);
            frame_buffer[offset + 2] = fw_native_channel_to_u8(c.b);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Microbenchmark: measure each math function's per-call cost.
// ---------------------------------------------------------------------------
// Uses volatile sink to prevent dead-code elimination.
static volatile float bench_sink;

#define BENCH_ITERS 100000

static void bench_one(const char *name,
                      float (*lib_fn)(float), float (*fast_fn)(float),
                      float input) {
    volatile float s = 0.0f;
    int64_t t0, t1;

    // Library version
    t0 = esp_timer_get_time();
    for (int i = 0; i < BENCH_ITERS; i++) {
        s += lib_fn(input + (float)i * 0.0001f);
    }
    t1 = esp_timer_get_time();
    bench_sink = s;
    int64_t lib_us = t1 - t0;

    // Fast version
    s = 0.0f;
    t0 = esp_timer_get_time();
    for (int i = 0; i < BENCH_ITERS; i++) {
        s += fast_fn(input + (float)i * 0.0001f);
    }
    t1 = esp_timer_get_time();
    bench_sink = s;
    int64_t fast_us = t1 - t0;

    float speedup = (lib_us > 0) ? (float)lib_us / (float)fast_us : 0.0f;
    int ns_lib  = (int)((lib_us  * 1000) / BENCH_ITERS);
    int ns_fast = (int)((fast_us * 1000) / BENCH_ITERS);
    ESP_LOGI(BENCH_TAG, "%-10s  lib=%5lld us  fast=%5lld us  (%.1fx)  per-call: %d -> %d ns",
             name, (long long)lib_us, (long long)fast_us, speedup, ns_lib, ns_fast);
}

// Two-argument function benchmark
static void bench_one2(const char *name,
                       float (*lib_fn)(float, float), float (*fast_fn)(float, float),
                       float a, float b) {
    volatile float s = 0.0f;
    int64_t t0, t1;

    t0 = esp_timer_get_time();
    for (int i = 0; i < BENCH_ITERS; i++) {
        s += lib_fn(a + (float)i * 0.0001f, b);
    }
    t1 = esp_timer_get_time();
    bench_sink = s;
    int64_t lib_us = t1 - t0;

    s = 0.0f;
    t0 = esp_timer_get_time();
    for (int i = 0; i < BENCH_ITERS; i++) {
        s += fast_fn(a + (float)i * 0.0001f, b);
    }
    t1 = esp_timer_get_time();
    bench_sink = s;
    int64_t fast_us = t1 - t0;

    float speedup = (lib_us > 0) ? (float)lib_us / (float)fast_us : 0.0f;
    int ns_lib  = (int)((lib_us  * 1000) / BENCH_ITERS);
    int ns_fast = (int)((fast_us * 1000) / BENCH_ITERS);
    ESP_LOGI(BENCH_TAG, "%-10s  lib=%5lld us  fast=%5lld us  (%.1fx)  per-call: %d -> %d ns",
             name, (long long)lib_us, (long long)fast_us, speedup, ns_lib, ns_fast);
}

// Wrappers to make library functions into function pointers
// (can't take address of macros)
static float wrap_sinf(float x)   { return sinf(x); }
static float wrap_cosf(float x)   { return cosf(x); }
static float wrap_sqrtf(float x)  { return sqrtf(x > 0.0f ? x : 0.01f); }
static float wrap_floorf(float x) { return floorf(x); }
static float wrap_logf(float x)   { return logf(x > 0.0f ? x : 0.01f); }
static float wrap_log10f(float x) { return log10f(x > 0.0f ? x : 0.01f); }
static float wrap_fabsf(float x)  { return fabsf(x); }
static float wrap_fminf(float a, float b) { return fminf(a, b); }
static float wrap_fmaxf(float a, float b) { return fmaxf(a, b); }

static float wrap_fast_sinf(float x)   { return dsl_fast_sinf(x); }
static float wrap_fast_cosf(float x)   { return dsl_fast_cosf(x); }
static float wrap_fast_sqrtf(float x)  { return dsl_fast_sqrtf(x > 0.0f ? x : 0.01f); }
static float wrap_fast_floorf(float x) { return dsl_fast_floorf(x); }
static float wrap_fast_logf(float x)   { return dsl_fast_logf(x > 0.0f ? x : 0.01f); }
static float wrap_fast_log10f(float x) { return dsl_fast_log10f(x > 0.0f ? x : 0.01f); }
static float wrap_fast_fabsf(float x)  { return dsl_fast_fabsf(x); }
static float wrap_fast_fminf(float a, float b) { return dsl_fast_fminf(a, b); }
static float wrap_fast_fmaxf(float a, float b) { return dsl_fast_fmaxf(a, b); }

// Benchmarks for single-argument functions using function pointer + timing
static void bench_timing(const char *name, int64_t us) {
    int ns_per_call = (int)((us * 1000) / BENCH_ITERS);
    ESP_LOGI(BENCH_TAG, "%-14s  %5lld us  per-call: %d ns", name, (long long)us, ns_per_call);
}

void fw_native_shader_run_benchmarks(void) {
    ESP_LOGI(BENCH_TAG, "=== Math function microbenchmarks (%d iterations each) ===", BENCH_ITERS);

    bench_one("sinf",   wrap_sinf,   wrap_fast_sinf,   2.5f);
    bench_one("cosf",   wrap_cosf,   wrap_fast_cosf,   2.5f);
    bench_one("sqrtf",  wrap_sqrtf,  wrap_fast_sqrtf,  7.3f);
    bench_one("floorf", wrap_floorf, wrap_fast_floorf,  3.7f);
    bench_one("logf",   wrap_logf,   wrap_fast_logf,    2.0f);
    bench_one("log10f", wrap_log10f, wrap_fast_log10f,  5.0f);
    bench_one("fabsf",  wrap_fabsf,  wrap_fast_fabsf,  -3.2f);
    bench_one2("fminf", wrap_fminf,  wrap_fast_fminf,   1.5f, 2.3f);
    bench_one2("fmaxf", wrap_fmaxf,  wrap_fast_fmaxf,   1.5f, 2.3f);

    // Composite function timing (using generated helpers with fast redirects)
    ESP_LOGI(BENCH_TAG, "--- Composite functions (with fast math redirects) ---");
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_smoothstep(0.2f, 0.8f, 0.1f + (float)i * 0.000008f);
        }
        bench_sink = s;
        bench_timing("smoothstep", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_clamp(0.1f + (float)i * 0.00001f, 0.0f, 1.0f);
        }
        bench_sink = s;
        bench_timing("clamp", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_fract(1.7f + (float)i * 0.00001f);
        }
        bench_sink = s;
        bench_timing("fract", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            dsl_color_t src = { .r = 0.5f, .g = 0.3f, .b = 0.1f, .a = 0.7f + (float)i * 0.000001f };
            dsl_color_t dst = { .r = 0.2f, .g = 0.6f, .b = 0.8f, .a = 0.9f };
            dsl_color_t result = dsl_blend_over(src, dst);
            s += result.r;
        }
        bench_sink = s;
        bench_timing("blend_over", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            dsl_vec2_t p = { .x = 3.0f + (float)i * 0.00001f, .y = 4.0f };
            s += dsl_circle(p, 5.0f);
        }
        bench_sink = s;
        bench_timing("circle", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            dsl_vec2_t p = { .x = 3.0f + (float)i * 0.00001f, .y = 4.0f };
            dsl_vec2_t b = { .x = 5.0f, .y = 6.0f };
            s += dsl_box(p, b);
        }
        bench_sink = s;
        bench_timing("box", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_wrapdx(15.0f + (float)i * 0.0001f, 10.0f, 30.0f);
        }
        bench_sink = s;
        bench_timing("wrapdx", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_hash01((float)i);
        }
        bench_sink = s;
        bench_timing("hash01", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_hash_signed((float)i);
        }
        bench_sink = s;
        bench_timing("hashSigned", esp_timer_get_time() - t0);
    }
    {
        volatile float s = 0.0f;
        int64_t t0 = esp_timer_get_time();
        for (int i = 0; i < BENCH_ITERS; i++) {
            s += dsl_hash_coords01((float)(i & 0xFF), (float)((i >> 8) & 0xFF), 42.0f);
        }
        bench_sink = s;
        bench_timing("hashCoords01", esp_timer_get_time() - t0);
    }

    ESP_LOGI(BENCH_TAG, "=== Benchmark complete ===");
}
