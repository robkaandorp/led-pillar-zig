/**
 * @file fw_fast_math.h
 * @brief Fast math approximations for ESP32 Xtensa DSL shaders.
 *
 * These replace expensive newlib software implementations of sinf, cosf,
 * sqrtf, floorf, logf, and log10f with lightweight inline approximations.
 * Used by both the native C shader and the bytecode VM.
 *
 * NOT redirected: fabsf, fminf, fmaxf — Xtensa compiler already emits
 * single-instruction sequences (ABS.S, MOVF.S) for these.
 *
 * Compile with -O3 -ffast-math -fno-math-errno for best results.
 */
#pragma once

#include <math.h>
#include <stdint.h>

// Fast floor: cast-based inline compiles to TRUNC.S + FLOAT.S (~3-4
// instructions vs ~50+ for the newlib floorf library call).
static inline float dsl_fast_floorf(float x) {
    float t = (float)(int)x;
    return t - (t > x);
}

// Fast sin: parabolic approximation with correction pass.
// Max |error| < 0.001.
static inline float dsl_fast_sinf(float x) {
    const float TWO_PI     = 6.283185307f;
    const float INV_TWO_PI = 0.159154943f;
    x -= TWO_PI * dsl_fast_floorf(x * INV_TWO_PI + 0.5f);

    const float B = 1.27323954f;   // 4 / pi
    const float C = -0.40528473f;  // -4 / pi^2
    float y = B * x + C * x * fabsf(x);

    const float P = 0.225f;
    y = P * (y * fabsf(y) - y) + y;
    return y;
}

// Fast cos via sin shift.
static inline float dsl_fast_cosf(float x) {
    return dsl_fast_sinf(x + 1.5707963268f);
}

// Fast sqrt: Quake-style inverse-sqrt + one Newton-Raphson step.
// Max relative error ~0.03%.
static inline float dsl_fast_sqrtf(float x) {
    if (x <= 0.0f) return 0.0f;
    union { float f; uint32_t i; } conv = { .f = x };
    conv.i = 0x5f3759dfU - (conv.i >> 1);
    float y = conv.f;
    y = y * (1.5f - (0.5f * x * y * y));
    return x * y;
}

// Fast natural log: IEEE 754 bit decomposition + cubic polynomial.
// Max relative error ~0.06% for x > 0.
static inline float dsl_fast_logf(float x) {
    if (x <= 0.0f) return -87.33f;
    union { float f; uint32_t i; } conv = { .f = x };
    int e = (int)((conv.i >> 23) & 0xFF) - 127;
    conv.i = (conv.i & 0x007fffffU) | 0x3f800000U;
    float m = conv.f;
    float t = m - 1.0f;
    float ln_m = t * (0.99949556f + t * (-0.49190896f + t * 0.28947478f));
    return (float)e * 0.6931471806f + ln_m;
}

// Fast base-10 log: ln(x) / ln(10).
static inline float dsl_fast_log10f(float x) {
    return dsl_fast_logf(x) * 0.4342944819f;
}

// Fast fabsf: bit-clear sign bit.  Kept as utility but NOT recommended
// as a redirect on Xtensa (compiler ABS.S is faster).
static inline float dsl_fast_fabsf(float x) {
    union { float f; uint32_t i; } conv = { .f = x };
    conv.i &= 0x7fffffffU;
    return conv.f;
}

// Fast fminf/fmaxf: branchless ternary.  Kept as utility but NOT
// recommended as a redirect on Xtensa (compiler MOVF.S is faster).
static inline float dsl_fast_fminf(float a, float b) {
    return (a < b) ? a : b;
}
static inline float dsl_fast_fmaxf(float a, float b) {
    return (a > b) ? a : b;
}
