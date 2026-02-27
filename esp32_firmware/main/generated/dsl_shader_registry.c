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

/* Generated from effect: aurora_v1 */
static void aurora_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_speed_0 = 0.280000f;
    const float dsl_param_thickness_1 = 3.800000f;
    const float dsl_param_alpha_scale_2 = 0.450000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer ribbon */
    const float dsl_let_theta_3 = ((x / width) * 6.28318530717958647692f);
    const float dsl_let_center_4 = ((height * 0.500000f) + (sinf((dsl_let_theta_3 + (time * dsl_param_speed_0))) * 6.000000f));
    const float dsl_let_d_5 = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_center_4) }, (dsl_vec2_t){ .x = width, .y = dsl_param_thickness_1 });
    const float dsl_let_a_6 = ((1.000000f - dsl_smoothstep(0.000000f, 1.900000f, dsl_let_d_5)) * dsl_param_alpha_scale_2);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.350000f, .g = 0.950000f, .b = 0.750000f, .a = fminf(dsl_let_a_6, 1.000000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: aurora_ribbons_classic_v1 */
static void aurora_ribbons_classic_eval_frame(float time, float frame) {
    const float dsl_let_t_warp_0 = (time * 0.120000f);
    const float dsl_let_t_hue_1 = (time * 0.200000f);
    const float dsl_let_t_breathe_2 = (time * 0.350000f);
    const float dsl_let_t_crest_3 = (time * 0.500000f);
    const float dsl_let_t_accent_4 = (time * 0.550000f);
}

/* Generated from effect: aurora_ribbons_classic_v1 */
static void aurora_ribbons_classic_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_let_t_warp_0 = (time * 0.120000f);
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

/* Generated from effect: campfire_v1 */
static void campfire_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_pulse_0 = 0.900000f;
    const float dsl_param_tongue_x_1 = 14.000000f;
    const float dsl_param_tongue_y_2 = 28.000000f;
    const float dsl_param_tongue_r_3 = 2.300000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer embers */
    const float dsl_let_d_4 = dsl_box((dsl_vec2_t){ .x = dsl_wrapdx(x, (width * 0.500000f), width), .y = (y - (height - 1.400000f)) }, (dsl_vec2_t){ .x = 2.000000f, .y = 1.100000f });
    const float dsl_let_a_5 = ((1.000000f - dsl_smoothstep((-(0.100000f)), 1.250000f, dsl_let_d_4)) * 0.550000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.950000f, .g = 0.450000f, .b = 0.080000f, .a = dsl_let_a_5 }, __dsl_out);
    /* layer tongue */
    const float dsl_let_sway_6 = (sinf(((time * 5.800000f) + (y * 0.080000f))) * (0.450000f + (0.550000f * dsl_smoothstep(0.600000f, 0.950000f, ((sinf((time * dsl_param_pulse_0)) + 1.000000f) * 0.500000f)))));
    const float dsl_let_d_7 = dsl_circle((dsl_vec2_t){ .x = dsl_wrapdx(x, (dsl_param_tongue_x_1 + dsl_let_sway_6), width), .y = (y - dsl_param_tongue_y_2) }, dsl_param_tongue_r_3);
    const float dsl_let_body_8 = (1.000000f - dsl_smoothstep(0.000000f, 1.450000f, dsl_let_d_7));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 1.000000f, .g = 0.780000f, .b = 0.250000f, .a = (dsl_let_body_8 * 0.700000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: chaos_nebula_v1 */
static void chaos_nebula_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t_slow_0 = ((time * 0.061800f) + (seed * 100.000000f));
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

/* Generated from effect: dream_weaver_v1 */
static void dream_weaver_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t1_0 = ((time * 0.080900f) + (seed * 100.000000f));
    const float dsl_param_t2_1 = ((time * 0.131100f) + (seed * 200.000000f));
    const float dsl_param_t3_2 = ((time * 0.191800f) + (seed * 300.000000f));
    const float dsl_param_vitality_3 = dsl_clamp((((sinf(((time * 0.083000f) + (seed * 55.000000f))) + sinf(((time * 0.059000f) + (seed * 75.000000f)))) + sinf(((time * 0.037000f) + (seed * 95.000000f)))) - 1.300000f), 0.000000f, 1.000000f);
    const float dsl_param_hue_base_4 = dsl_fract((time * 0.004300f));
    const float dsl_param_src1_x_5 = (width * dsl_fract((dsl_param_t1_0 * 0.800000f)));
    const float dsl_param_src1_y_6 = (height * (0.350000f + (0.150000f * sinf((dsl_param_t2_1 * 3.000000f)))));
    const float dsl_param_src2_x_7 = (width * dsl_fract(((dsl_param_t1_0 * 0.800000f) + 0.500000f)));
    const float dsl_param_src2_y_8 = (height * (0.650000f + (0.150000f * cosf((dsl_param_t3_2 * 2.000000f)))));
    const float dsl_param_src3_x_9 = (width * dsl_fract(((dsl_param_t2_1 * 0.500000f) + 0.250000f)));
    const float dsl_param_src3_y_10 = (height * (0.500000f + (0.250000f * sinf((dsl_param_t3_2 * 1.400000f)))));
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer waves */
    const float dsl_let_dx1_11 = dsl_wrapdx(x, dsl_param_src1_x_5, width);
    const float dsl_let_dy1_12 = (y - dsl_param_src1_y_6);
    const float dsl_let_d1_13 = sqrtf(fmaxf(((dsl_let_dx1_11 * dsl_let_dx1_11) + (dsl_let_dy1_12 * dsl_let_dy1_12)), 0.100000f));
    const float dsl_let_w1_14 = sinf(((dsl_let_d1_13 * 0.800000f) - (time * 2.000000f)));
    const float dsl_let_dx2_15 = dsl_wrapdx(x, dsl_param_src2_x_7, width);
    const float dsl_let_dy2_16 = (y - dsl_param_src2_y_8);
    const float dsl_let_d2_17 = sqrtf(fmaxf(((dsl_let_dx2_15 * dsl_let_dx2_15) + (dsl_let_dy2_16 * dsl_let_dy2_16)), 0.100000f));
    const float dsl_let_w2_18 = sinf(((dsl_let_d2_17 * 0.600000f) - (time * 1.500000f)));
    const float dsl_let_dx3_19 = dsl_wrapdx(x, dsl_param_src3_x_9, width);
    const float dsl_let_dy3_20 = (y - dsl_param_src3_y_10);
    const float dsl_let_d3_21 = sqrtf(fmaxf(((dsl_let_dx3_19 * dsl_let_dx3_19) + (dsl_let_dy3_20 * dsl_let_dy3_20)), 0.100000f));
    const float dsl_let_w3_22 = sinf(((dsl_let_d3_21 * 0.500000f) - (time * 1.100000f)));
    const float dsl_let_interference_23 = (((dsl_let_w1_14 + dsl_let_w2_18) + dsl_let_w3_22) * 0.333000f);
    const float dsl_let_bright_24 = (dsl_smoothstep((-(0.300000f)), 0.700000f, dsl_let_interference_23) * ((0.040000f + (0.200000f * (1.000000f - dsl_param_vitality_3))) + (0.500000f * dsl_param_vitality_3)));
    const float dsl_let_h_25 = dsl_fract((dsl_param_hue_base_4 + (dsl_let_interference_23 * 0.250000f)));
    const float dsl_let_r_26 = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf((dsl_let_h_25 * 6.28318530717958647692f)))));
    const float dsl_let_g_27 = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf(((dsl_let_h_25 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_28 = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf(((dsl_let_h_25 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_26, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_27, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_28, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer ripples */
    const float dsl_let_angle_29 = (dsl_param_t3_2 * 2.000000f);
    const float dsl_let_diag_30 = ((x * cosf(dsl_let_angle_29)) + (y * sinf(dsl_let_angle_29)));
    const float dsl_let_ripple_31 = ((sinf(((dsl_let_diag_30 * 0.500000f) + (time * 0.700000f))) * 0.500000f) + 0.500000f);
    const float dsl_let_mask_32 = (dsl_let_ripple_31 * (0.030000f + (0.180000f * dsl_param_vitality_3)));
    const float dsl_let_h_33 = dsl_fract(((dsl_param_hue_base_4 + 0.500000f) + (dsl_let_diag_30 * 0.010000f)));
    const float dsl_let_r_34 = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf((dsl_let_h_33 * 6.28318530717958647692f)))));
    const float dsl_let_g_35 = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf(((dsl_let_h_33 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_36 = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf(((dsl_let_h_33 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_34, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_35, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_36, 0.000000f, 1.000000f), .a = dsl_let_mask_32 }, __dsl_out);
    /* layer sparkles */
    const float dsl_let_gx_37 = floorf((x * 0.200000f));
    const float dsl_let_gy_38 = floorf((y * 0.130000f));
    const float dsl_let_cell_seed_39 = (((dsl_let_gx_37 * 19.700000f) + (dsl_let_gy_38 * 47.300000f)) + (floorf((time * 0.800000f)) * 31.100000f));
    const float dsl_let_h01_40 = dsl_hash01(dsl_let_cell_seed_39);
    const float dsl_let_sparkle_41 = (dsl_smoothstep(0.900000f, 1.000000f, dsl_let_h01_40) * dsl_param_vitality_3);
    const float dsl_let_sh_42 = dsl_fract((dsl_hash01(((dsl_let_gx_37 * 7.000000f) + (dsl_let_gy_38 * 13.000000f))) + (time * 0.020000f)));
    const float dsl_let_r_43 = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf((dsl_let_sh_42 * 6.28318530717958647692f)))));
    const float dsl_let_g_44 = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf(((dsl_let_sh_42 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_45 = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf(((dsl_let_sh_42 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_43, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_44, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_45, 0.000000f, 1.000000f), .a = dsl_let_sparkle_41 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: gradient */
static void gradient_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer l */
    const float dsl_let_xt_0 = ((cosf(x) * 0.500000f) + 0.500000f);
    const float dsl_let_yt_1 = ((cosf(y) * 0.500000f) + 0.500000f);
    const float dsl_let_at_2 = ((sinf((x * y)) * 0.500000f) + 0.500000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_xt_0, .g = dsl_let_yt_1, .b = dsl_let_xt_0, .a = dsl_let_at_2 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: infinite_lines */
static void infinite_lines_eval_frame(float time, float frame) {
    const float dsl_param_line_half_width_0 = 0.700000f;
    const float dsl_param_rotation_speed_1 = 0.350000f;
    const float dsl_param_color_speed_2 = 0.100000f;
    const float dsl_let_t_3 = (time * dsl_param_rotation_speed_1);
    const float dsl_let_tc_4 = (time * dsl_param_color_speed_2);
}

/* Generated from effect: infinite_lines */
static void infinite_lines_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_line_half_width_0 = 0.700000f;
    const float dsl_param_rotation_speed_1 = 0.350000f;
    const float dsl_param_color_speed_2 = 0.100000f;
    const float dsl_let_t_3 = (time * dsl_param_rotation_speed_1);
    const float dsl_let_tc_4 = (time * dsl_param_color_speed_2);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer lines */
    const float dsl_let_theta_5 = ((x / width) * 6.28318530717958647692f);
    for (int32_t dsl_iter_i_6 = 0; dsl_iter_i_6 < 4; dsl_iter_i_6++) {
        const float dsl_index_i_7 = (float)dsl_iter_i_6;
        const float dsl_let_phase_8 = ((seed * 6.28318530717958647692f) + (dsl_index_i_7 * 1.700000f));
        const float dsl_let_pivot_frac_y_9 = dsl_fract((seed * (3.170000f + (dsl_index_i_7 * 2.310000f))));
        const float dsl_let_pivot_y_10 = (dsl_let_pivot_frac_y_9 * height);
        const float dsl_let_dir_sign_11 = ((floorf((dsl_fract((seed * (7.130000f + (dsl_index_i_7 * 1.930000f)))) + 0.500000f)) * 2.000000f) - 1.000000f);
        const float dsl_let_speed_var_12 = (0.700000f + (dsl_fract((seed * (5.410000f + (dsl_index_i_7 * 3.070000f)))) * 0.600000f));
        const float dsl_let_angle_13 = (dsl_let_phase_8 + ((dsl_let_t_3 * dsl_let_dir_sign_11) * dsl_let_speed_var_12));
        const float dsl_let_nx_14 = (-(sinf(dsl_let_angle_13)));
        const float dsl_let_ny_15 = cosf(dsl_let_angle_13);
        const float dsl_let_pivot_theta_16 = (dsl_fract((seed * (1.730000f + (dsl_index_i_7 * 4.190000f)))) * 6.28318530717958647692f);
        const float dsl_let_pivot_x_norm_17 = ((dsl_let_pivot_theta_16 / 6.28318530717958647692f) * width);
        const float dsl_let_rel_x_18 = (x - dsl_let_pivot_x_norm_17);
        const float dsl_let_rel_y_19 = (y - dsl_let_pivot_y_10);
        const float dsl_let_base_proj_20 = ((dsl_let_rel_x_18 * dsl_let_nx_14) + (dsl_let_rel_y_19 * dsl_let_ny_15));
        const float dsl_let_wrap_step_21 = (width * dsl_let_nx_14);
        const float dsl_let_d_center_22 = fabsf(dsl_let_base_proj_20);
        const float dsl_let_d_left_23 = fabsf((dsl_let_base_proj_20 - dsl_let_wrap_step_21));
        const float dsl_let_d_right_24 = fabsf((dsl_let_base_proj_20 + dsl_let_wrap_step_21));
        const float dsl_let_d_25 = fminf(dsl_let_d_center_22, fminf(dsl_let_d_left_23, dsl_let_d_right_24));
        const float dsl_let_line_alpha_26 = (1.000000f - dsl_smoothstep((dsl_param_line_half_width_0 * 0.300000f), dsl_param_line_half_width_0, dsl_let_d_25));
        const float dsl_let_hue_phase_27 = ((dsl_let_tc_4 * (0.800000f + (dsl_index_i_7 * 0.300000f))) + (seed * (2.000000f + (dsl_index_i_7 * 1.500000f))));
        const float dsl_let_r_28 = (0.500000f + (0.500000f * sinf(dsl_let_hue_phase_27)));
        const float dsl_let_g_29 = (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 2.094000f))));
        const float dsl_let_b_30 = (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 4.189000f))));
        const float dsl_let_max_ch_31 = fmaxf(dsl_let_r_28, fmaxf(dsl_let_g_29, dsl_let_b_30));
        const float dsl_let_boost_32 = dsl_clamp((0.850000f / fmaxf(dsl_let_max_ch_31, 0.010000f)), 1.000000f, 2.000000f);
        const float dsl_let_rb_33 = dsl_clamp((dsl_let_r_28 * dsl_let_boost_32), 0.000000f, 1.000000f);
        const float dsl_let_gb_34 = dsl_clamp((dsl_let_g_29 * dsl_let_boost_32), 0.000000f, 1.000000f);
        const float dsl_let_bb_35 = dsl_clamp((dsl_let_b_30 * dsl_let_boost_32), 0.000000f, 1.000000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_rb_33, .g = dsl_let_gb_34, .b = dsl_let_bb_35, .a = dsl_let_line_alpha_26 }, __dsl_out);
    }
    *out_color = __dsl_out;
}

/* Generated from effect: primal_storm_v1 */
static void primal_storm_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t1_0 = ((time * 0.073200f) + (seed * 100.000000f));
    const float dsl_param_t2_1 = ((time * 0.141400f) + (seed * 200.000000f));
    const float dsl_param_t3_2 = ((time * 0.223600f) + (seed * 300.000000f));
    const float dsl_param_storm_3 = dsl_clamp((((sinf(((time * 0.097000f) + (seed * 60.000000f))) + sinf(((time * 0.067000f) + (seed * 80.000000f)))) + sinf(((time * 0.041000f) + (seed * 40.000000f)))) - 1.400000f), 0.000000f, 1.000000f);
    const float dsl_param_speed_4 = (0.500000f + (2.000000f * dsl_param_storm_3));
    const float dsl_param_epoch_5 = dsl_fract((time * 0.005100f));
    const float dsl_param_scx_6 = (6.28318530717958647692f / width);
    const float dsl_param_scy_7 = (6.28318530717958647692f / height);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer glow */
    const float dsl_let_cy_8 = (height * (0.500000f + (0.100000f * sinf((dsl_param_t1_0 * 2.700000f)))));
    const float dsl_let_dy_9 = (fabsf((y - dsl_let_cy_8)) / height);
    const float dsl_let_g_val_10 = (dsl_smoothstep(0.450000f, 0.000000f, dsl_let_dy_9) * ((0.030000f + (0.180000f * (1.000000f - dsl_param_storm_3))) + (0.300000f * dsl_param_storm_3)));
    const float dsl_let_h_11 = dsl_fract(((dsl_param_epoch_5 + (dsl_let_dy_9 * 0.300000f)) + (0.100000f * sinf((dsl_param_t1_0 * 1.500000f)))));
    const float dsl_let_r_12 = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf((dsl_let_h_11 * 6.28318530717958647692f)))));
    const float dsl_let_g_13 = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf(((dsl_let_h_11 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_14 = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf(((dsl_let_h_11 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_12, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_13, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_14, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer bands */
    const float dsl_let_scroll_15 = (((y * dsl_param_scy_7) * 4.000000f) + (time * dsl_param_speed_4));
    const float dsl_let_wave_16 = (sinf(dsl_let_scroll_15) * cosf((((dsl_let_scroll_15 * 0.700000f) + ((x * dsl_param_scx_6) * 2.000000f)) + (dsl_param_t2_1 * 3.000000f))));
    const float dsl_let_mask_17 = (dsl_smoothstep(0.200000f, 0.900000f, dsl_let_wave_16) * (0.040000f + (0.550000f * dsl_param_storm_3)));
    const float dsl_let_mix_v_18 = ((sinf(((dsl_param_t3_2 * 3.000000f) + (y * dsl_param_scy_7))) * 0.500000f) + 0.500000f);
    const float dsl_let_r_19 = (dsl_let_mask_17 * (0.300000f + (0.600000f * dsl_let_mix_v_18)));
    const float dsl_let_g_20 = (dsl_let_mask_17 * (0.600000f - (0.300000f * dsl_let_mix_v_18)));
    const float dsl_let_b_21 = (dsl_let_mask_17 * 0.900000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_19, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_20, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_21, 0.000000f, 1.000000f), .a = dsl_let_mask_17 }, __dsl_out);
    /* layer lightning */
    const float dsl_let_col_22 = floorf((x * 0.500000f));
    const float dsl_let_t_slice_23 = floorf((time * 4.000000f));
    const float dsl_let_chance_24 = dsl_hash01(((dsl_let_col_22 * 13.700000f) + (dsl_let_t_slice_23 * 71.300000f)));
    const float dsl_let_strike_25 = (dsl_smoothstep(0.930000f, 1.000000f, dsl_let_chance_24) * dsl_param_storm_3);
    const float dsl_let_bolt_y_26 = (dsl_hash01(((dsl_let_col_22 * 29.100000f) + (dsl_let_t_slice_23 * 53.700000f))) * height);
    const float dsl_let_bolt_spread_27 = dsl_smoothstep(0.350000f, 0.000000f, (fabsf((y - dsl_let_bolt_y_26)) / height));
    const float dsl_let_bolt_28 = (dsl_let_strike_25 * dsl_let_bolt_spread_27);
    const float dsl_let_r_29 = (dsl_let_bolt_28 * (0.700000f + (0.300000f * dsl_let_bolt_spread_27)));
    const float dsl_let_g_30 = (dsl_let_bolt_28 * (0.800000f + (0.200000f * dsl_let_bolt_spread_27)));
    const float dsl_let_b_31 = dsl_let_bolt_28;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_29, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_30, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_31, 0.000000f, 1.000000f), .a = dsl_let_bolt_28 }, __dsl_out);
    /* layer embers */
    const float dsl_let_px_32 = floorf((x * 0.250000f));
    const float dsl_let_stripe_seed_33 = dsl_hash01((dsl_let_px_32 * 37.100000f));
    const float dsl_let_rise_speed_34 = (0.500000f + (dsl_let_stripe_seed_33 * 1.500000f));
    const float dsl_let_py_35 = dsl_fract(((dsl_let_stripe_seed_33 * 10.000000f) - ((time * dsl_let_rise_speed_34) * 0.050000f)));
    const float dsl_let_ember_y_36 = (dsl_let_py_35 * height);
    const float dsl_let_dy_37 = (fabsf((y - dsl_let_ember_y_36)) / height);
    const float dsl_let_ember_38 = ((dsl_smoothstep(0.060000f, 0.000000f, dsl_let_dy_37) * dsl_param_storm_3) * dsl_hash01(((dsl_let_px_32 * 53.000000f) + (floorf((time * 0.300000f)) * 17.000000f))));
    const float dsl_let_r_39 = (dsl_let_ember_38 * 1.000000f);
    const float dsl_let_g_40 = (dsl_let_ember_38 * (0.400000f + (0.300000f * dsl_let_stripe_seed_33)));
    const float dsl_let_b_41 = (dsl_let_ember_38 * 0.100000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_39, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_40, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_41, 0.000000f, 1.000000f), .a = dsl_let_ember_38 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: rain_ripple_v1 */
static void rain_ripple_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_lane_x_0 = 8.000000f;
    const float dsl_param_drop_y_1 = ((height * 0.500000f) + (sinf((time * 1.700000f)) * (height * 0.450000f)));
    const float dsl_param_ripple_y_2 = (height - 2.000000f);
    const float dsl_param_ripple_r_3 = (1.200000f + ((sinf((time * 4.500000f)) + 1.000000f) * 3.500000f));
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer drop */
    const float dsl_let_lane_jitter_4 = (dsl_hash_signed((frame + 17.000000f)) * 0.450000f);
    const float dsl_let_dx_5 = dsl_wrapdx(x, (dsl_param_lane_x_0 + dsl_let_lane_jitter_4), width);
    const float dsl_let_streak_6 = dsl_box((dsl_vec2_t){ .x = dsl_let_dx_5, .y = (y - (dsl_param_drop_y_1 - 1.200000f)) }, (dsl_vec2_t){ .x = 0.180000f, .y = 1.200000f });
    const float dsl_let_head_7 = dsl_circle((dsl_vec2_t){ .x = dsl_let_dx_5, .y = (y - dsl_param_drop_y_1) }, 0.400000f);
    const float dsl_let_a_8 = (((1.000000f - dsl_smoothstep(0.000000f, 0.750000f, dsl_let_streak_6)) * 0.360000f) + ((1.000000f - dsl_smoothstep(0.000000f, 0.550000f, dsl_let_head_7)) * 0.480000f));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.700000f, .g = 0.840000f, .b = 1.000000f, .a = fminf(dsl_let_a_8, 0.900000f) }, __dsl_out);
    /* layer ripple */
    const dsl_vec2_t dsl_let_local_9 = (dsl_vec2_t){ .x = dsl_wrapdx(x, dsl_param_lane_x_0, width), .y = (y - dsl_param_ripple_y_2) };
    const float dsl_let_ring_10 = (fabsf(dsl_circle(dsl_let_local_9, dsl_param_ripple_r_3)) - 0.200000f);
    const float dsl_let_a_11 = ((1.000000f - dsl_smoothstep(0.000000f, 0.800000f, dsl_let_ring_10)) * 0.600000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.350000f, .g = 0.780000f, .b = 1.000000f, .a = dsl_let_a_11 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: soap_bubbles_v1 */
static void soap_bubbles_eval_frame(float time, float frame) {
    const float dsl_let_two_pi_0 = (3.14159265358979323846f * 2.000000f);
    const float dsl_let_depth_time_1 = (time * 0.750000f);
    const float dsl_let_tint_time_2 = (time * 0.800000f);
}

/* Generated from effect: soap_bubbles_v1 */
static void soap_bubbles_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_let_two_pi_0 = (3.14159265358979323846f * 2.000000f);
    const float dsl_let_depth_time_1 = (time * 0.750000f);
    const float dsl_let_tint_time_2 = (time * 0.800000f);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer bubbles */
    for (int32_t dsl_iter_i_3 = 0; dsl_iter_i_3 < 14; dsl_iter_i_3++) {
        const float dsl_index_i_4 = (float)dsl_iter_i_3;
        const float dsl_let_id_5 = dsl_index_i_4;
        const float dsl_let_phase01_6 = dsl_hash01(((dsl_let_id_5 * 13.000000f) + 5.000000f));
        const float dsl_let_phase_7 = (dsl_let_phase01_6 * dsl_let_two_pi_0);
        const float dsl_let_depth_phase_8 = (dsl_hash01(((dsl_let_id_5 * 17.000000f) + 3.000000f)) * dsl_let_two_pi_0);
        const float dsl_let_lane_x_9 = (width * dsl_hash01(((dsl_let_id_5 * 31.000000f) + 1.000000f)));
        const float dsl_let_radius_10 = (1.400000f + (dsl_hash01(((dsl_let_id_5 * 41.000000f) + 2.000000f)) * 2.400000f));
        const float dsl_let_rise_speed_11 = (5.000000f + (dsl_hash01(((dsl_let_id_5 * 53.000000f) + 7.000000f)) * 9.000000f));
        const float dsl_let_wobble_amp_12 = (0.200000f + (dsl_hash01(((dsl_let_id_5 * 67.000000f) + 9.000000f)) * 1.500000f));
        const float dsl_let_wobble_freq_13 = (0.450000f + (dsl_hash01(((dsl_let_id_5 * 79.000000f) + 4.000000f)) * 1.450000f));
        const float dsl_let_travel_14 = (height + (dsl_let_radius_10 * 2.200000f));
        const float dsl_let_cycle_15 = dsl_fract(((time * (dsl_let_rise_speed_11 / dsl_let_travel_14)) + dsl_let_phase01_6));
        const float dsl_let_center_x_16 = (dsl_let_lane_x_9 + (sinf(((time * dsl_let_wobble_freq_13) + dsl_let_phase_7)) * dsl_let_wobble_amp_12));
        const float dsl_let_center_y_17 = ((height + dsl_let_radius_10) - (dsl_let_cycle_15 * dsl_let_travel_14));
        const dsl_vec2_t dsl_let_local_18 = (dsl_vec2_t){ .x = dsl_wrapdx(x, dsl_let_center_x_16, width), .y = (y - dsl_let_center_y_17) };
        const float dsl_let_pop_t_19 = dsl_clamp(((dsl_let_cycle_15 - 0.900000f) / 0.100000f), 0.000000f, 1.000000f);
        const float dsl_let_pop_gate_20 = (dsl_smoothstep(0.000000f, 0.150000f, dsl_let_pop_t_19) * (1.000000f - dsl_smoothstep(0.750000f, 1.000000f, dsl_let_pop_t_19)));
        const float dsl_let_body_radius_21 = (dsl_let_radius_10 * (1.000000f - (0.550000f * dsl_let_pop_t_19)));
        const float dsl_let_d_22 = dsl_circle(dsl_let_local_18, dsl_let_body_radius_21);
        const float dsl_let_shell_alpha_23 = (1.000000f - dsl_smoothstep(0.050000f, 0.850000f, fabsf(dsl_let_d_22)));
        const float dsl_let_core_alpha_24 = ((1.000000f - dsl_smoothstep((-(dsl_let_body_radius_21)), 0.000000f, dsl_let_d_22)) * 0.120000f);
        const float dsl_let_hi_d_25 = dsl_circle((dsl_vec2_t){ .x = (dsl_wrapdx(x, dsl_let_center_x_16, width) + (dsl_let_body_radius_21 * 0.400000f)), .y = ((y - dsl_let_center_y_17) - (dsl_let_body_radius_21 * 0.340000f)) }, (dsl_let_body_radius_21 * 0.230000f));
        const float dsl_let_hi_alpha_26 = ((1.000000f - dsl_smoothstep(0.000000f, 0.550000f, dsl_let_hi_d_25)) * 0.260000f);
        const float dsl_let_depth_27 = sinf((dsl_let_depth_time_1 + dsl_let_depth_phase_8));
        const float dsl_let_front_factor_28 = dsl_smoothstep(0.000000f, 0.350000f, dsl_let_depth_27);
        const float dsl_let_depth_alpha_29 = (0.620000f + (0.380000f * dsl_let_front_factor_28));
        const float dsl_let_body_alpha_30 = fminf((((((dsl_let_shell_alpha_23 * 0.460000f) + dsl_let_core_alpha_24) + dsl_let_hi_alpha_26) * (1.000000f - (0.920000f * dsl_let_pop_t_19))) * dsl_let_depth_alpha_29), 0.860000f);
        if (dsl_let_body_alpha_30 > 0.0f) {
            const float dsl_let_tint_31 = (0.500000f + (0.500000f * sinf((dsl_let_tint_time_2 + dsl_let_phase_7))));
            __dsl_out = dsl_blend_over((dsl_color_t){ .r = fminf((0.660000f + (0.200000f * dsl_let_tint_31)), 1.000000f), .g = fminf((0.820000f + (0.120000f * dsl_let_tint_31)), 1.000000f), .b = 1.000000f, .a = dsl_let_body_alpha_30 }, __dsl_out);
        } else {
        }
        if (dsl_let_pop_gate_20 > 0.0f) {
            const float dsl_let_ring_radius_32 = (dsl_let_body_radius_21 + ((dsl_let_radius_10 + 0.800000f) * dsl_let_pop_t_19));
            const float dsl_let_ring_width_33 = (0.120000f + ((1.000000f - dsl_let_pop_t_19) * 0.180000f));
            const float dsl_let_ring_d_34 = (fabsf(dsl_circle(dsl_let_local_18, dsl_let_ring_radius_32)) - dsl_let_ring_width_33);
            const float dsl_let_ring_alpha_35 = ((((1.000000f - dsl_smoothstep(0.000000f, 0.650000f, dsl_let_ring_d_34)) * dsl_let_pop_gate_20) * 0.900000f) * dsl_let_depth_alpha_29);
            __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.580000f, .g = 0.880000f, .b = 1.000000f, .a = dsl_let_ring_alpha_35 }, __dsl_out);
        } else {
        }
    }
    *out_color = __dsl_out;
}

/* Generated from effect: tone_pulse */
static void tone_pulse_eval_frame(float time, float frame) {
    const float dsl_param_base_freq_0 = 220.000000f;
    const float dsl_param_pulse_rate_1 = 2.000000f;
    const float dsl_let_pulse_2 = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_brightness_3 = (dsl_let_pulse_2 * dsl_let_pulse_2);
}

/* Generated from effect: tone_pulse */
static void tone_pulse_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_base_freq_0 = 220.000000f;
    const float dsl_param_pulse_rate_1 = 2.000000f;
    const float dsl_let_pulse_2 = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_brightness_3 = (dsl_let_pulse_2 * dsl_let_pulse_2);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer glow */
    const float dsl_let_hue_4 = dsl_fract(((time * 0.050000f) + seed));
    const float dsl_let_r_5 = dsl_clamp(((sinf((dsl_let_hue_4 * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_g_6 = dsl_clamp(((sinf(((dsl_let_hue_4 * 6.283185f) + 2.094000f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_b_7 = dsl_clamp(((sinf(((dsl_let_hue_4 * 6.283185f) + 4.189000f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_dist_8 = (fabsf(((y / height) - 0.500000f)) * 2.000000f);
    const float dsl_let_mask_9 = dsl_clamp((1.000000f - dsl_let_dist_8), 0.000000f, 1.000000f);
    const float dsl_let_intensity_10 = (dsl_let_brightness_3 * dsl_let_mask_9);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (dsl_let_r_5 * dsl_let_intensity_10), .g = (dsl_let_g_6 * dsl_let_intensity_10), .b = (dsl_let_b_7 * dsl_let_intensity_10), .a = dsl_let_intensity_10 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Audio: generated from effect: tone_pulse */
static float tone_pulse_eval_audio(float time, float seed) {
    const float dsl_param_base_freq_0 = 220.000000f;
    const float dsl_param_pulse_rate_1 = 2.000000f;
    float __dsl_audio_out = 0.0f;
    const float dsl_let_pulse_2 = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_freq_3 = (dsl_param_base_freq_0 + (dsl_let_pulse_2 * dsl_param_base_freq_0));
    const float dsl_let_envelope_4 = ((dsl_let_pulse_2 * dsl_let_pulse_2) * 0.400000f);
    __dsl_audio_out = (sinf(((time * dsl_let_freq_3) * 6.283185f)) * dsl_let_envelope_4);
    return __dsl_audio_out;
}

typedef struct {
    const char *name;
    const char *folder;
    void (*eval_pixel)(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color);
    int has_frame_func;
    void (*eval_frame)(float time, float frame);
    int has_audio_func;
    float (*eval_audio)(float time, float seed);
} dsl_shader_entry_t;

const dsl_shader_entry_t dsl_shader_registry[] = {
    { .name = "aurora", .folder = "/native", .eval_pixel = aurora_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "aurora-ribbons-classic", .folder = "/native", .eval_pixel = aurora_ribbons_classic_eval_pixel, .has_frame_func = 1, .eval_frame = aurora_ribbons_classic_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "campfire", .folder = "/native", .eval_pixel = campfire_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "chaos-nebula", .folder = "/native", .eval_pixel = chaos_nebula_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "dream-weaver", .folder = "/native", .eval_pixel = dream_weaver_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "gradient", .folder = "/native", .eval_pixel = gradient_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "infinite-lines", .folder = "/native", .eval_pixel = infinite_lines_eval_pixel, .has_frame_func = 1, .eval_frame = infinite_lines_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "primal-storm", .folder = "/native", .eval_pixel = primal_storm_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "rain-ripple", .folder = "/native", .eval_pixel = rain_ripple_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "soap-bubbles", .folder = "/native", .eval_pixel = soap_bubbles_eval_pixel, .has_frame_func = 1, .eval_frame = soap_bubbles_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float))0 },
    { .name = "tone-pulse", .folder = "/native", .eval_pixel = tone_pulse_eval_pixel, .has_frame_func = 1, .eval_frame = tone_pulse_eval_frame, .has_audio_func = 1, .eval_audio = tone_pulse_eval_audio },
};

const int dsl_shader_registry_count = 11;

#include <string.h>

const dsl_shader_entry_t *dsl_shader_find(const char *name) {
    for (int i = 0; i < dsl_shader_registry_count; i++) {
        if (strcmp(dsl_shader_registry[i].name, name) == 0) {
            return &dsl_shader_registry[i];
        }
    }
    return (const dsl_shader_entry_t *)0;
}

const dsl_shader_entry_t *dsl_shader_get(int index) {
    if (index < 0 || index >= dsl_shader_registry_count) {
        return (const dsl_shader_entry_t *)0;
    }
    return &dsl_shader_registry[index];
}
