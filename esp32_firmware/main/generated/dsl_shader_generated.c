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

/* Generated from effect: infinite_lines */
void dsl_shader_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {    const float dsl_param_line_half_width_0 = 0.700000f;
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
