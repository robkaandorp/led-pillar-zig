#include <math.h>
#include <stdint.h>

typedef struct {
    float x;
    float y;
} dsl_vec2_t;

typedef struct {
    float r;
    float g;
    float b;
    float a;
} dsl_color_t;

static inline float dsl_clamp(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline float dsl_fract(float v) {
    return v - floorf(v);
}

static inline float dsl_smoothstep(float edge0, float edge1, float x) {
    if (edge0 == edge1) {
        return (x < edge0) ? 0.0f : 1.0f;
    }
    const float t = dsl_clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - (2.0f * t));
}

static inline float dsl_wrapdx(float px, float center_x, float width) {
    float dx = px - center_x;
    if (width <= 0.0f) return dx;
    if (dx > width * 0.5f) dx -= width;
    if (dx < -width * 0.5f) dx += width;
    return dx;
}

static inline uint32_t dsl_hash_u32(uint32_t value) {
    uint32_t x = value;
    x ^= x >> 16U;
    x *= 0x7feb352dU;
    x ^= x >> 15U;
    x *= 0x846ca68bU;
    x ^= x >> 16U;
    return x;
}

static inline float dsl_hash01(float value) {
    const uint32_t hashed = dsl_hash_u32((uint32_t)((int32_t)value)) & 0x00ffffffU;
    return (float)hashed / 16777215.0f;
}

static inline float dsl_hash_signed(float value) {
    return (dsl_hash01(value) * 2.0f) - 1.0f;
}

static inline float dsl_hash_coords01(float x, float y, float seed) {
    uint32_t mixed = (uint32_t)((int32_t)x) * 0x9e3779b9U;
    mixed ^= (uint32_t)((int32_t)y) * 0x85ebca6bU;
    mixed ^= (uint32_t)((int32_t)seed);
    return dsl_hash01((float)((int32_t)mixed));
}

static inline float dsl_circle(dsl_vec2_t p, float radius) {
    return sqrtf((p.x * p.x) + (p.y * p.y)) - radius;
}

static inline float dsl_box(dsl_vec2_t p, dsl_vec2_t b) {
    dsl_vec2_t q = { .x = fabsf(p.x) - b.x, .y = fabsf(p.y) - b.y };
    dsl_vec2_t outside = { .x = fmaxf(q.x, 0.0f), .y = fmaxf(q.y, 0.0f) };
    const float inside = fminf(fmaxf(q.x, q.y), 0.0f);
    return sqrtf((outside.x * outside.x) + (outside.y * outside.y)) + inside;
}

static inline dsl_color_t dsl_blend_over(dsl_color_t src, dsl_color_t dst) {
    const float src_a = dsl_clamp(src.a, 0.0f, 1.0f);
    const float dst_a = dsl_clamp(dst.a, 0.0f, 1.0f);
    const float out_a = src_a + (dst_a * (1.0f - src_a));
    if (out_a <= 0.000001f) {
        return (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 0.0f };
    }
    const float inv_out_a = 1.0f / out_a;
    return (dsl_color_t){
        .r = ((src.r * src_a) + (dst.r * dst_a * (1.0f - src_a))) * inv_out_a,
        .g = ((src.g * src_a) + (dst.g * dst_a * (1.0f - src_a))) * inv_out_a,
        .b = ((src.b * src_a) + (dst.b * dst_a * (1.0f - src_a))) * inv_out_a,
        .a = out_a,
    };
}

/* Generated from effect: chaos_nebula_v1 */
void dsl_shader_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {    const float dsl_param_t_slow_0 = ((time * 0.061800f) + (seed * 100.000000f));
    const float dsl_param_t_med_1 = ((time * 0.173200f) + (seed * 200.000000f));
    const float dsl_param_t_fast_2 = ((time * 0.289600f) + (seed * 300.000000f));
    const float dsl_param_energy_3 = dsl_clamp((((sinf(((time * 0.110000f) + (seed * 50.000000f))) + sinf(((time * 0.077000f) + (seed * 70.000000f)))) + sinf(((time * 0.053000f) + (seed * 90.000000f)))) - 1.500000f), 0.000000f, 1.000000f);
    const float dsl_param_base_4 = (0.025000f + (0.015000f * sinf((time * 0.029000f))));
    const float dsl_param_cx_5 = (width * 0.500000f);
    const float dsl_param_cy_6 = (height * 0.500000f);
    const float dsl_param_scx_7 = (6.28318530717958647692f / width);
    const float dsl_param_scy_8 = (6.28318530717958647692f / height);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer nebula */
    const float dsl_let_dx_9 = dsl_wrapdx(x, (dsl_param_cx_5 + ((sinf((dsl_param_t_slow_0 * 3.700000f)) * width) * 0.250000f)), width);
    const float dsl_let_dy_10 = ((y - dsl_param_cy_6) + ((cosf((dsl_param_t_slow_0 * 2.300000f)) * height) * 0.150000f));
    const float dsl_let_field1_11 = (sinf((((dsl_let_dx_9 * dsl_param_scx_7) * 2.000000f) + (dsl_param_t_slow_0 * 4.000000f))) * cosf((((dsl_let_dy_10 * dsl_param_scy_8) * 1.500000f) + (dsl_param_t_slow_0 * 3.000000f))));
    const float dsl_let_field2_12 = (cosf((((dsl_let_dx_9 * dsl_param_scx_7) * 1.300000f) - (dsl_param_t_med_1 * 2.500000f))) * sinf((((dsl_let_dy_10 * dsl_param_scy_8) * 2.200000f) + (dsl_param_t_med_1 * 1.800000f))));
    const float dsl_let_glow_13 = (dsl_smoothstep((-(0.200000f)), 0.600000f, (dsl_let_field1_11 + (dsl_let_field2_12 * 0.500000f))) * ((dsl_param_base_4 + 0.150000f) + (0.350000f * dsl_param_energy_3)));
    const float dsl_let_r_14 = (dsl_let_glow_13 * (0.550000f + (0.450000f * sinf((dsl_param_t_slow_0 * 1.900000f)))));
    const float dsl_let_g_15 = (dsl_let_glow_13 * (0.250000f + (0.350000f * sinf(((dsl_param_t_slow_0 * 2.700000f) + 2.000000f)))));
    const float dsl_let_b_16 = (dsl_let_glow_13 * (0.450000f + (0.450000f * cosf(((dsl_param_t_slow_0 * 1.400000f) + 1.000000f)))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_14, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_15, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_16, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer streams */
    const float dsl_let_drift_17 = ((dsl_param_t_med_1 * 5.000000f) + ((y * dsl_param_scy_8) * 3.000000f));
    const float dsl_let_wx_18 = dsl_wrapdx(x, (width * (0.300000f + (0.200000f * sinf((dsl_param_t_fast_2 * 1.600000f))))), width);
    const float dsl_let_stream_19 = (sinf((((dsl_let_wx_18 * dsl_param_scx_7) * 3.500000f) + dsl_let_drift_17)) * cosf((((dsl_let_wx_18 * dsl_param_scx_7) * 1.800000f) - (dsl_param_t_fast_2 * 3.000000f))));
    const float dsl_let_mask_20 = (dsl_smoothstep(0.250000f, 0.850000f, dsl_let_stream_19) * (0.080000f + (0.700000f * dsl_param_energy_3)));
    const float dsl_let_r_21 = (dsl_let_mask_20 * (0.200000f + (0.500000f * sinf(((dsl_param_t_fast_2 * 2.300000f) + 1.000000f)))));
    const float dsl_let_g_22 = (dsl_let_mask_20 * (0.500000f + (0.400000f * cosf((dsl_param_t_med_1 * 3.100000f)))));
    const float dsl_let_b_23 = (dsl_let_mask_20 * (0.700000f + (0.300000f * sinf(((dsl_param_t_slow_0 * 5.000000f) + 3.000000f)))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_21, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_22, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_23, 0.000000f, 1.000000f), .a = dsl_let_mask_20 }, __dsl_out);
    /* layer sparks */
    const float dsl_let_cell_x_24 = floorf((x * 0.200000f));
    const float dsl_let_cell_y_25 = floorf((y * 0.150000f));
    const float dsl_let_cell_seed_26 = (((dsl_let_cell_x_24 * 17.310000f) + (dsl_let_cell_y_25 * 43.170000f)) + (floorf((time * 1.500000f)) * 7.130000f));
    const float dsl_let_brightness_27 = dsl_hash01(dsl_let_cell_seed_26);
    const float dsl_let_spark_28 = (dsl_smoothstep(0.880000f, 1.000000f, dsl_let_brightness_27) * (0.150000f + (0.850000f * dsl_param_energy_3)));
    const float dsl_let_hue_29 = dsl_fract((dsl_hash01(((dsl_let_cell_x_24 * 13.000000f) + (dsl_let_cell_y_25 * 29.000000f))) + (time * 0.030000f)));
    const float dsl_let_r_30 = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf((dsl_let_hue_29 * 6.28318530717958647692f)))));
    const float dsl_let_g_31 = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf(((dsl_let_hue_29 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_32 = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf(((dsl_let_hue_29 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_30, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_31, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_32, 0.000000f, 1.000000f), .a = dsl_let_spark_28 }, __dsl_out);
    *out_color = __dsl_out;
}
