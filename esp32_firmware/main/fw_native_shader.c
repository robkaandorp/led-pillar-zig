#include "fw_native_shader.h"
#include <math.h>

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

// Redirect math calls inside the generated shader to fast versions.
#define sinf   dsl_fast_sinf
#define cosf   dsl_fast_cosf
#define sqrtf  dsl_fast_sqrtf
#define floorf dsl_fast_floorf

#include "generated/dsl_shader_generated.c"

#undef sinf
#undef cosf
#undef sqrtf
#undef floorf

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
