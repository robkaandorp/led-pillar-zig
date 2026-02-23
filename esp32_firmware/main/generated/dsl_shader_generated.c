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

/* Generated from effect: aurora_ribbons_classic_v1 */
void dsl_shader_eval_pixel(float time, float frame, float x, float y, float width, float height, dsl_color_t *out_color) {    const float dsl_let_t_warp_0 = (time * 0.120000f);
    const float dsl_let_t_hue_1 = (time * 0.200000f);
    const float dsl_let_t_breathe_2 = (time * 0.350000f);
    const float dsl_let_t_crest_3 = (time * 0.500000f);
    const float dsl_let_t_accent_4 = (time * 0.550000f);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer ribbons */
    const float dsl_let_theta_5 = ((x / width) * 6.28318530717958647692f);
    for (int32_t dsl_iter_i_6 = 0; dsl_iter_i_6 < 4; dsl_iter_i_6++) {
        const float dsl_index_i_7 = (float)dsl_iter_i_6;
        const float dsl_let_layer_index_8 = dsl_index_i_7;
        const float dsl_let_w0_9 = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 0.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w1_10 = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 1.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w2_11 = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 2.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w3_12 = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 3.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_phase_13 = ((((0.000000f * dsl_let_w0_9) + (1.500000f * dsl_let_w1_10)) + (2.700000f * dsl_let_w2_11)) + (4.000000f * dsl_let_w3_12));
        const float dsl_let_speed_14 = ((((0.280000f * dsl_let_w0_9) + (0.340000f * dsl_let_w1_10)) + (0.220000f * dsl_let_w2_11)) + (0.300000f * dsl_let_w3_12));
        const float dsl_let_wave_15 = ((((0.900000f * dsl_let_w0_9) + (1.200000f * dsl_let_w1_10)) + (1.600000f * dsl_let_w2_11)) + (1.050000f * dsl_let_w3_12));
        const float dsl_let_width_base_16 = ((((4.200000f * dsl_let_w0_9) + (3.800000f * dsl_let_w1_10)) + (3.200000f * dsl_let_w2_11)) + (2.900000f * dsl_let_w3_12));
        const float dsl_let_alpha_scale_17 = (0.160000f + (dsl_let_layer_index_8 * 0.050000f));
        const float dsl_let_warp_18 = (sinf((((dsl_let_theta_5 * 3.000000f) + dsl_let_t_warp_0) + (dsl_let_phase_13 * 0.500000f))) * (0.220000f * dsl_let_wave_15));
        const float dsl_let_flow_19 = sinf((((dsl_let_theta_5 + (time * dsl_let_speed_14)) + dsl_let_phase_13) + dsl_let_warp_18));
        const float dsl_let_sweep_20 = sinf(((((dsl_let_theta_5 * 2.000000f) - (time * (0.220000f + (dsl_let_speed_14 * 0.150000f)))) + (dsl_let_phase_13 * 0.700000f)) + dsl_let_warp_18));
        const float dsl_let_base_21 = ((0.500000f + (0.340000f * dsl_let_flow_19)) + (0.080000f * dsl_let_warp_18));
        const float dsl_let_centerline_22 = (((1.000000f - dsl_let_base_21) * (height - 1.000000f)) + (dsl_let_sweep_20 * 2.900000f));
        const float dsl_let_breathing_23 = sinf(((dsl_let_t_breathe_2 + dsl_let_phase_13) + (dsl_let_layer_index_8 * 0.400000f)));
        const float dsl_let_thickness_24 = (dsl_let_width_base_16 + (dsl_let_breathing_23 * 0.900000f));
        const float dsl_let_band_d_25 = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_centerline_22) }, (dsl_vec2_t){ .x = width, .y = dsl_let_thickness_24 });
        const float dsl_let_band_alpha_26 = ((1.000000f - dsl_smoothstep(0.000000f, 1.900000f, dsl_let_band_d_25)) * dsl_let_alpha_scale_17);
        const float dsl_let_hue_phase_27 = ((dsl_let_t_hue_1 + dsl_let_phase_13) + dsl_let_theta_5);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = (0.180000f + (0.220000f * (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 2.000000f)))))), .g = (0.420000f + (0.460000f * (0.500000f + (0.500000f * sinf(dsl_let_hue_phase_27))))), .b = (0.460000f + (0.420000f * (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 4.000000f)))))), .a = dsl_let_band_alpha_26 }, __dsl_out);
        const float dsl_let_accent_center_28 = (dsl_let_centerline_22 + (sinf((((dsl_let_theta_5 * 4.000000f) + dsl_let_t_accent_4) + dsl_let_phase_13)) * 1.300000f));
        const float dsl_let_accent_d_29 = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_accent_center_28) }, (dsl_vec2_t){ .x = width, .y = fmaxf(0.400000f, (dsl_let_thickness_24 * 0.260000f)) });
        const float dsl_let_crest_30 = dsl_smoothstep(0.550000f, 1.000000f, sinf((((dsl_let_theta_5 * 2.000000f) + dsl_let_t_crest_3) + dsl_let_phase_13)));
        const float dsl_let_accent_alpha_31 = (((1.000000f - dsl_smoothstep(0.000000f, 0.950000f, dsl_let_accent_d_29)) * dsl_let_crest_30) * 0.200000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.880000f, .g = 0.900000f, .b = 0.950000f, .a = dsl_let_accent_alpha_31 }, __dsl_out);
    }
    *out_color = __dsl_out;
}
