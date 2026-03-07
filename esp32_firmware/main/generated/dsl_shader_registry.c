#include <math.h>
#include <stdint.h>

/* DSL_NOINLINE: defined by the ESP32 build to control inlining of
 * large helper functions (noise2, noise3, blend_over).
 * On desktop/simulator builds this defaults to `inline`. */
#ifndef DSL_NOINLINE
#define DSL_NOINLINE inline
#endif

#ifndef DSL_MAYBE_UNUSED
#if defined(__GNUC__)
#define DSL_MAYBE_UNUSED __attribute__((unused))
#else
#define DSL_MAYBE_UNUSED
#endif
#endif

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

static DSL_NOINLINE dsl_color_t dsl_blend_over(dsl_color_t src, dsl_color_t dst) {
    const float src_a = dsl_clamp(src.a, 0.0f, 1.0f);
    const float dst_a = dsl_clamp(dst.a, 0.0f, 1.0f);
    const float out_a = src_a + (dst_a * (1.0f - src_a));
    if (out_a <= 0.000001f) {
        return (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 0.0f };
    }
    const float inv_out_a = 1.0f / out_a;
    const float one_minus_src_a = 1.0f - src_a;
    return (dsl_color_t){
        .r = dsl_clamp(((src.r * src_a) + (dst.r * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        .g = dsl_clamp(((src.g * src_a) + (dst.g * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        .b = dsl_clamp(((src.b * src_a) + (dst.b * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        .a = out_a,
    };
}

static const unsigned char dsl_perm[512] = {
    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
    119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
    129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
    81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
    184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
    222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180,
    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
    119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
    129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
    81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
    184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
    222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
};

static inline float dsl_grad2(int hash, float x, float y) {
    const int h = hash & 7;
    const float u = h < 4 ? x : y;
    const float v = h < 4 ? y : x;
    return ((h & 1) ? -u : u) + ((h & 2) ? -2.0f * v : 2.0f * v);
}

static DSL_NOINLINE float dsl_noise2(float x, float y) {
    const float F2 = 0.3660254037844386f;
    const float G2 = 0.21132486540518713f;
    const float s = (x + y) * F2;
    const int i = (int)floorf(x + s);
    const int j = (int)floorf(y + s);
    const float t = (float)(i + j) * G2;
    const float x0 = x - ((float)i - t);
    const float y0 = y - ((float)j - t);
    int i1, j1;
    if (x0 > y0) { i1 = 1; j1 = 0; } else { i1 = 0; j1 = 1; }
    const float x1 = x0 - (float)i1 + G2;
    const float y1 = y0 - (float)j1 + G2;
    const float x2 = x0 - 1.0f + 2.0f * G2;
    const float y2 = y0 - 1.0f + 2.0f * G2;
    const int ii = i & 255;
    const int jj = j & 255;
    float n = 0.0f;
    float t0 = 0.5f - x0*x0 - y0*y0;
    if (t0 >= 0.0f) { t0 *= t0; n += t0 * t0 * dsl_grad2(dsl_perm[ii + dsl_perm[jj]], x0, y0); }
    float t1 = 0.5f - x1*x1 - y1*y1;
    if (t1 >= 0.0f) { t1 *= t1; n += t1 * t1 * dsl_grad2(dsl_perm[ii + i1 + dsl_perm[jj + j1]], x1, y1); }
    float t2 = 0.5f - x2*x2 - y2*y2;
    if (t2 >= 0.0f) { t2 *= t2; n += t2 * t2 * dsl_grad2(dsl_perm[ii + 1 + dsl_perm[jj + 1]], x2, y2); }
    return 70.0f * n;
}

static inline float dsl_grad3(int hash, float x, float y, float z) {
    const int h = hash & 15;
    const float u = h < 8 ? x : y;
    const float v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
    return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
}

static DSL_NOINLINE float dsl_noise3(float x, float y, float z) {
    const float F3 = 1.0f / 3.0f;
    const float G3 = 1.0f / 6.0f;
    const float s = (x + y + z) * F3;
    const int i = (int)floorf(x + s);
    const int j = (int)floorf(y + s);
    const int k = (int)floorf(z + s);
    const float t = (float)(i + j + k) * G3;
    const float x0 = x - ((float)i - t);
    const float y0 = y - ((float)j - t);
    const float z0 = z - ((float)k - t);
    int i1, j1, k1, i2, j2, k2;
    if (x0 >= y0) {
        if (y0 >= z0) { i1=1;j1=0;k1=0;i2=1;j2=1;k2=0; }
        else if (x0 >= z0) { i1=1;j1=0;k1=0;i2=1;j2=0;k2=1; }
        else { i1=0;j1=0;k1=1;i2=1;j2=0;k2=1; }
    } else {
        if (y0 < z0) { i1=0;j1=0;k1=1;i2=0;j2=1;k2=1; }
        else if (x0 < z0) { i1=0;j1=1;k1=0;i2=0;j2=1;k2=1; }
        else { i1=0;j1=1;k1=0;i2=1;j2=1;k2=0; }
    }
    const float x1 = x0 - (float)i1 + G3;
    const float y1 = y0 - (float)j1 + G3;
    const float z1 = z0 - (float)k1 + G3;
    const float x2 = x0 - (float)i2 + 2.0f*G3;
    const float y2 = y0 - (float)j2 + 2.0f*G3;
    const float z2 = z0 - (float)k2 + 2.0f*G3;
    const float x3 = x0 - 1.0f + 3.0f*G3;
    const float y3 = y0 - 1.0f + 3.0f*G3;
    const float z3 = z0 - 1.0f + 3.0f*G3;
    const int ii = i & 255;
    const int jj = j & 255;
    const int kk = k & 255;
    float n = 0.0f;
    float c0 = 0.6f - x0*x0 - y0*y0 - z0*z0;
    if (c0 >= 0.0f) { c0 *= c0; n += c0*c0*dsl_grad3(dsl_perm[ii+dsl_perm[jj+dsl_perm[kk]]], x0, y0, z0); }
    float c1 = 0.6f - x1*x1 - y1*y1 - z1*z1;
    if (c1 >= 0.0f) { c1 *= c1; n += c1*c1*dsl_grad3(dsl_perm[ii+i1+dsl_perm[jj+j1+dsl_perm[kk+k1]]], x1, y1, z1); }
    float c2 = 0.6f - x2*x2 - y2*y2 - z2*z2;
    if (c2 >= 0.0f) { c2 *= c2; n += c2*c2*dsl_grad3(dsl_perm[ii+i2+dsl_perm[jj+j2+dsl_perm[kk+k2]]], x2, y2, z2); }
    float c3 = 0.6f - x3*x3 - y3*y3 - z3*z3;
    if (c3 >= 0.0f) { c3 *= c3; n += c3*c3*dsl_grad3(dsl_perm[ii+1+dsl_perm[jj+1+dsl_perm[kk+1]]], x3, y3, z3); }
    return 32.0f * n;
}

static inline float dsl_phasor_advance(float *state, float freq, float sample_rate) {
    *state += freq / sample_rate;
    *state -= floorf(*state);
    return *state;
}


/* Generated from effect: a440_test_tone */
static void a440_test_tone_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer background */
    const float dsl_let_pulse_0 DSL_MAYBE_UNUSED = ((sinf(((time * 0.250000f) * 6.28318530717958647692f)) * 0.500000f) + 0.500000f);
    const float dsl_let_intensity_1 DSL_MAYBE_UNUSED = (0.180000f + (dsl_let_pulse_0 * 0.220000f));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_intensity_1, .g = (dsl_let_intensity_1 * 0.350000f), .b = (dsl_let_intensity_1 * 0.050000f), .a = 1.000000f }, __dsl_out);
    /* layer status_glow */
    const float dsl_let_cy_2 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_dist_3 DSL_MAYBE_UNUSED = fabsf((y - dsl_let_cy_2));
    const float dsl_let_band_4 DSL_MAYBE_UNUSED = dsl_smoothstep(10.000000f, 0.000000f, dsl_let_dist_3);
    const float dsl_let_intensity_5 DSL_MAYBE_UNUSED = (dsl_let_band_4 * 0.850000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_intensity_5, .g = (dsl_let_intensity_5 * 0.750000f), .b = (dsl_let_intensity_5 * 0.100000f), .a = dsl_let_intensity_5 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Audio: generated from effect: a440_test_tone */
static float a440_test_tone_eval_audio(float time, float seed, float sample_rate, float *phasor_state) {
    float __dsl_audio_out = 0.0f;
    const float dsl_let_attack_0 DSL_MAYBE_UNUSED = dsl_clamp((time / 0.200000f), 0.000000f, 1.000000f);
    __dsl_audio_out = ((sinf(((time * 440.000000f) * 6.28318530717958647692f)) * 0.350000f) * dsl_let_attack_0);
    return __dsl_audio_out;
}

/* Generated from effect: aurora_v1 */
static void aurora_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_speed_0 DSL_MAYBE_UNUSED = 0.280000f;
    const float dsl_param_thickness_1 DSL_MAYBE_UNUSED = 3.800000f;
    const float dsl_param_alpha_scale_2 DSL_MAYBE_UNUSED = 0.450000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer ribbon */
    const float dsl_let_theta_3 DSL_MAYBE_UNUSED = ((x / width) * 6.28318530717958647692f);
    const float dsl_let_center_4 DSL_MAYBE_UNUSED = ((height * 0.500000f) + (sinf((dsl_let_theta_3 + (time * dsl_param_speed_0))) * 6.000000f));
    const float dsl_let_d_5 DSL_MAYBE_UNUSED = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_center_4) }, (dsl_vec2_t){ .x = width, .y = dsl_param_thickness_1 });
    const float dsl_let_a_6 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep(0.000000f, 1.900000f, dsl_let_d_5)) * dsl_param_alpha_scale_2);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.350000f, .g = 0.950000f, .b = 0.750000f, .a = fminf(dsl_let_a_6, 1.000000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: aurora_ribbons_classic_v1 */
static void aurora_ribbons_classic_eval_frame(float time, float frame) {
    const float dsl_let_t_warp_0 DSL_MAYBE_UNUSED = (time * 0.120000f);
    const float dsl_let_t_hue_1 DSL_MAYBE_UNUSED = (time * 0.200000f);
    const float dsl_let_t_breathe_2 DSL_MAYBE_UNUSED = (time * 0.350000f);
    const float dsl_let_t_crest_3 DSL_MAYBE_UNUSED = (time * 0.500000f);
    const float dsl_let_t_accent_4 DSL_MAYBE_UNUSED = (time * 0.550000f);
}

/* Generated from effect: aurora_ribbons_classic_v1 */
static void aurora_ribbons_classic_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_let_t_warp_0 DSL_MAYBE_UNUSED = (time * 0.120000f);
    const float dsl_let_t_hue_1 DSL_MAYBE_UNUSED = (time * 0.200000f);
    const float dsl_let_t_breathe_2 DSL_MAYBE_UNUSED = (time * 0.350000f);
    const float dsl_let_t_crest_3 DSL_MAYBE_UNUSED = (time * 0.500000f);
    const float dsl_let_t_accent_4 DSL_MAYBE_UNUSED = (time * 0.550000f);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer ribbons */
    const float dsl_let_theta_5 DSL_MAYBE_UNUSED = ((x / width) * 6.28318530717958647692f);
    for (int32_t dsl_iter_i_6 = 0; dsl_iter_i_6 < 4; dsl_iter_i_6++) {
        const float dsl_index_i_7 DSL_MAYBE_UNUSED = (float)dsl_iter_i_6;
        const float dsl_let_layer_index_8 DSL_MAYBE_UNUSED = dsl_index_i_7;
        const float dsl_let_w0_9 DSL_MAYBE_UNUSED = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 0.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w1_10 DSL_MAYBE_UNUSED = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 1.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w2_11 DSL_MAYBE_UNUSED = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 2.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_w3_12 DSL_MAYBE_UNUSED = dsl_clamp((1.000000f - fabsf((dsl_let_layer_index_8 - 3.000000f))), 0.000000f, 1.000000f);
        const float dsl_let_phase_13 DSL_MAYBE_UNUSED = ((((0.000000f * dsl_let_w0_9) + (1.500000f * dsl_let_w1_10)) + (2.700000f * dsl_let_w2_11)) + (4.000000f * dsl_let_w3_12));
        const float dsl_let_speed_14 DSL_MAYBE_UNUSED = ((((0.280000f * dsl_let_w0_9) + (0.340000f * dsl_let_w1_10)) + (0.220000f * dsl_let_w2_11)) + (0.300000f * dsl_let_w3_12));
        const float dsl_let_wave_15 DSL_MAYBE_UNUSED = ((((0.900000f * dsl_let_w0_9) + (1.200000f * dsl_let_w1_10)) + (1.600000f * dsl_let_w2_11)) + (1.050000f * dsl_let_w3_12));
        const float dsl_let_width_base_16 DSL_MAYBE_UNUSED = ((((4.200000f * dsl_let_w0_9) + (3.800000f * dsl_let_w1_10)) + (3.200000f * dsl_let_w2_11)) + (2.900000f * dsl_let_w3_12));
        const float dsl_let_alpha_scale_17 DSL_MAYBE_UNUSED = (0.160000f + (dsl_let_layer_index_8 * 0.050000f));
        const float dsl_let_warp_18 DSL_MAYBE_UNUSED = (sinf((((dsl_let_theta_5 * 3.000000f) + dsl_let_t_warp_0) + (dsl_let_phase_13 * 0.500000f))) * (0.220000f * dsl_let_wave_15));
        const float dsl_let_flow_19 DSL_MAYBE_UNUSED = sinf((((dsl_let_theta_5 + (time * dsl_let_speed_14)) + dsl_let_phase_13) + dsl_let_warp_18));
        const float dsl_let_sweep_20 DSL_MAYBE_UNUSED = sinf(((((dsl_let_theta_5 * 2.000000f) - (time * (0.220000f + (dsl_let_speed_14 * 0.150000f)))) + (dsl_let_phase_13 * 0.700000f)) + dsl_let_warp_18));
        const float dsl_let_base_21 DSL_MAYBE_UNUSED = ((0.500000f + (0.340000f * dsl_let_flow_19)) + (0.080000f * dsl_let_warp_18));
        const float dsl_let_centerline_22 DSL_MAYBE_UNUSED = (((1.000000f - dsl_let_base_21) * (height - 1.000000f)) + (dsl_let_sweep_20 * 2.900000f));
        const float dsl_let_breathing_23 DSL_MAYBE_UNUSED = sinf(((dsl_let_t_breathe_2 + dsl_let_phase_13) + (dsl_let_layer_index_8 * 0.400000f)));
        const float dsl_let_thickness_24 DSL_MAYBE_UNUSED = (dsl_let_width_base_16 + (dsl_let_breathing_23 * 0.900000f));
        const float dsl_let_band_d_25 DSL_MAYBE_UNUSED = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_centerline_22) }, (dsl_vec2_t){ .x = width, .y = dsl_let_thickness_24 });
        const float dsl_let_band_alpha_26 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep(0.000000f, 1.900000f, dsl_let_band_d_25)) * dsl_let_alpha_scale_17);
        const float dsl_let_hue_phase_27 DSL_MAYBE_UNUSED = ((dsl_let_t_hue_1 + dsl_let_phase_13) + dsl_let_theta_5);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = (0.180000f + (0.220000f * (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 2.000000f)))))), .g = (0.420000f + (0.460000f * (0.500000f + (0.500000f * sinf(dsl_let_hue_phase_27))))), .b = (0.460000f + (0.420000f * (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 4.000000f)))))), .a = dsl_let_band_alpha_26 }, __dsl_out);
        const float dsl_let_accent_center_28 DSL_MAYBE_UNUSED = (dsl_let_centerline_22 + (sinf((((dsl_let_theta_5 * 4.000000f) + dsl_let_t_accent_4) + dsl_let_phase_13)) * 1.300000f));
        const float dsl_let_accent_d_29 DSL_MAYBE_UNUSED = dsl_box((dsl_vec2_t){ .x = 0.000000f, .y = (y - dsl_let_accent_center_28) }, (dsl_vec2_t){ .x = width, .y = fmaxf(0.400000f, (dsl_let_thickness_24 * 0.260000f)) });
        const float dsl_let_crest_30 DSL_MAYBE_UNUSED = dsl_smoothstep(0.550000f, 1.000000f, sinf((((dsl_let_theta_5 * 2.000000f) + dsl_let_t_crest_3) + dsl_let_phase_13)));
        const float dsl_let_accent_alpha_31 DSL_MAYBE_UNUSED = (((1.000000f - dsl_smoothstep(0.000000f, 0.950000f, dsl_let_accent_d_29)) * dsl_let_crest_30) * 0.200000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.880000f, .g = 0.900000f, .b = 0.950000f, .a = dsl_let_accent_alpha_31 }, __dsl_out);
    }
    *out_color = __dsl_out;
}

/* Generated from effect: campfire_v1 */
static void campfire_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_pulse_0 DSL_MAYBE_UNUSED = 0.900000f;
    const float dsl_param_tongue_x_1 DSL_MAYBE_UNUSED = 14.000000f;
    const float dsl_param_tongue_y_2 DSL_MAYBE_UNUSED = 28.000000f;
    const float dsl_param_tongue_r_3 DSL_MAYBE_UNUSED = 2.300000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer embers */
    const float dsl_let_d_4 DSL_MAYBE_UNUSED = dsl_box((dsl_vec2_t){ .x = dsl_wrapdx(x, (width * 0.500000f), width), .y = (y - (height - 1.400000f)) }, (dsl_vec2_t){ .x = 2.000000f, .y = 1.100000f });
    const float dsl_let_a_5 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep((-(0.100000f)), 1.250000f, dsl_let_d_4)) * 0.550000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.950000f, .g = 0.450000f, .b = 0.080000f, .a = dsl_let_a_5 }, __dsl_out);
    /* layer tongue */
    const float dsl_let_sway_6 DSL_MAYBE_UNUSED = (sinf(((time * 5.800000f) + (y * 0.080000f))) * (0.450000f + (0.550000f * dsl_smoothstep(0.600000f, 0.950000f, ((sinf((time * dsl_param_pulse_0)) + 1.000000f) * 0.500000f)))));
    const float dsl_let_d_7 DSL_MAYBE_UNUSED = dsl_circle((dsl_vec2_t){ .x = dsl_wrapdx(x, (dsl_param_tongue_x_1 + dsl_let_sway_6), width), .y = (y - dsl_param_tongue_y_2) }, dsl_param_tongue_r_3);
    const float dsl_let_body_8 DSL_MAYBE_UNUSED = (1.000000f - dsl_smoothstep(0.000000f, 1.450000f, dsl_let_d_7));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 1.000000f, .g = 0.780000f, .b = 0.250000f, .a = (dsl_let_body_8 * 0.700000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: chaos_nebula_v1 */
static void chaos_nebula_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t_slow_0 DSL_MAYBE_UNUSED = ((time * 0.061800f) + (seed * 100.000000f));
    const float dsl_param_t_med_1 DSL_MAYBE_UNUSED = ((time * 0.173200f) + (seed * 200.000000f));
    const float dsl_param_t_fast_2 DSL_MAYBE_UNUSED = ((time * 0.289600f) + (seed * 300.000000f));
    const float dsl_param_energy_3 DSL_MAYBE_UNUSED = dsl_clamp((((sinf(((time * 0.110000f) + (seed * 50.000000f))) + sinf(((time * 0.077000f) + (seed * 70.000000f)))) + sinf(((time * 0.053000f) + (seed * 90.000000f)))) - 1.500000f), 0.000000f, 1.000000f);
    const float dsl_param_base_4 DSL_MAYBE_UNUSED = (0.025000f + (0.015000f * sinf((time * 0.029000f))));
    const float dsl_param_cx_5 DSL_MAYBE_UNUSED = (width * 0.500000f);
    const float dsl_param_cy_6 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_param_scx_7 DSL_MAYBE_UNUSED = (6.28318530717958647692f / width);
    const float dsl_param_scy_8 DSL_MAYBE_UNUSED = (6.28318530717958647692f / height);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer nebula */
    const float dsl_let_dx_9 DSL_MAYBE_UNUSED = dsl_wrapdx(x, (dsl_param_cx_5 + ((sinf((dsl_param_t_slow_0 * 3.700000f)) * width) * 0.250000f)), width);
    const float dsl_let_dy_10 DSL_MAYBE_UNUSED = ((y - dsl_param_cy_6) + ((cosf((dsl_param_t_slow_0 * 2.300000f)) * height) * 0.150000f));
    const float dsl_let_field1_11 DSL_MAYBE_UNUSED = (sinf((((dsl_let_dx_9 * dsl_param_scx_7) * 2.000000f) + (dsl_param_t_slow_0 * 4.000000f))) * cosf((((dsl_let_dy_10 * dsl_param_scy_8) * 1.500000f) + (dsl_param_t_slow_0 * 3.000000f))));
    const float dsl_let_field2_12 DSL_MAYBE_UNUSED = (cosf((((dsl_let_dx_9 * dsl_param_scx_7) * 1.300000f) - (dsl_param_t_med_1 * 2.500000f))) * sinf((((dsl_let_dy_10 * dsl_param_scy_8) * 2.200000f) + (dsl_param_t_med_1 * 1.800000f))));
    const float dsl_let_glow_13 DSL_MAYBE_UNUSED = (dsl_smoothstep((-(0.200000f)), 0.600000f, (dsl_let_field1_11 + (dsl_let_field2_12 * 0.500000f))) * ((dsl_param_base_4 + 0.150000f) + (0.350000f * dsl_param_energy_3)));
    const float dsl_let_r_14 DSL_MAYBE_UNUSED = (dsl_let_glow_13 * (0.550000f + (0.450000f * sinf((dsl_param_t_slow_0 * 1.900000f)))));
    const float dsl_let_g_15 DSL_MAYBE_UNUSED = (dsl_let_glow_13 * (0.250000f + (0.350000f * sinf(((dsl_param_t_slow_0 * 2.700000f) + 2.000000f)))));
    const float dsl_let_b_16 DSL_MAYBE_UNUSED = (dsl_let_glow_13 * (0.450000f + (0.450000f * cosf(((dsl_param_t_slow_0 * 1.400000f) + 1.000000f)))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_14, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_15, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_16, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer streams */
    const float dsl_let_drift_17 DSL_MAYBE_UNUSED = ((dsl_param_t_med_1 * 5.000000f) + ((y * dsl_param_scy_8) * 3.000000f));
    const float dsl_let_wx_18 DSL_MAYBE_UNUSED = dsl_wrapdx(x, (width * (0.300000f + (0.200000f * sinf((dsl_param_t_fast_2 * 1.600000f))))), width);
    const float dsl_let_stream_19 DSL_MAYBE_UNUSED = (sinf((((dsl_let_wx_18 * dsl_param_scx_7) * 3.500000f) + dsl_let_drift_17)) * cosf((((dsl_let_wx_18 * dsl_param_scx_7) * 1.800000f) - (dsl_param_t_fast_2 * 3.000000f))));
    const float dsl_let_mask_20 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.250000f, 0.850000f, dsl_let_stream_19) * (0.080000f + (0.700000f * dsl_param_energy_3)));
    const float dsl_let_r_21 DSL_MAYBE_UNUSED = (dsl_let_mask_20 * (0.200000f + (0.500000f * sinf(((dsl_param_t_fast_2 * 2.300000f) + 1.000000f)))));
    const float dsl_let_g_22 DSL_MAYBE_UNUSED = (dsl_let_mask_20 * (0.500000f + (0.400000f * cosf((dsl_param_t_med_1 * 3.100000f)))));
    const float dsl_let_b_23 DSL_MAYBE_UNUSED = (dsl_let_mask_20 * (0.700000f + (0.300000f * sinf(((dsl_param_t_slow_0 * 5.000000f) + 3.000000f)))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_21, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_22, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_23, 0.000000f, 1.000000f), .a = dsl_let_mask_20 }, __dsl_out);
    /* layer sparks */
    const float dsl_let_cell_x_24 DSL_MAYBE_UNUSED = floorf((x * 0.200000f));
    const float dsl_let_cell_y_25 DSL_MAYBE_UNUSED = floorf((y * 0.150000f));
    const float dsl_let_cell_seed_26 DSL_MAYBE_UNUSED = (((dsl_let_cell_x_24 * 17.310000f) + (dsl_let_cell_y_25 * 43.170000f)) + (floorf((time * 1.500000f)) * 7.130000f));
    const float dsl_let_brightness_27 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_cell_seed_26);
    const float dsl_let_spark_28 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.880000f, 1.000000f, dsl_let_brightness_27) * (0.150000f + (0.850000f * dsl_param_energy_3)));
    const float dsl_let_hue_29 DSL_MAYBE_UNUSED = dsl_fract((dsl_hash01(((dsl_let_cell_x_24 * 13.000000f) + (dsl_let_cell_y_25 * 29.000000f))) + (time * 0.030000f)));
    const float dsl_let_r_30 DSL_MAYBE_UNUSED = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf((dsl_let_hue_29 * 6.28318530717958647692f)))));
    const float dsl_let_g_31 DSL_MAYBE_UNUSED = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf(((dsl_let_hue_29 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_32 DSL_MAYBE_UNUSED = (dsl_let_spark_28 * (0.500000f + (0.500000f * sinf(((dsl_let_hue_29 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_30, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_31, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_32, 0.000000f, 1.000000f), .a = dsl_let_spark_28 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: dream_weaver_v1 */
static void dream_weaver_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t1_0 DSL_MAYBE_UNUSED = ((time * 0.080900f) + (seed * 100.000000f));
    const float dsl_param_t2_1 DSL_MAYBE_UNUSED = ((time * 0.131100f) + (seed * 200.000000f));
    const float dsl_param_t3_2 DSL_MAYBE_UNUSED = ((time * 0.191800f) + (seed * 300.000000f));
    const float dsl_param_vitality_3 DSL_MAYBE_UNUSED = dsl_clamp((((sinf(((time * 0.083000f) + (seed * 55.000000f))) + sinf(((time * 0.059000f) + (seed * 75.000000f)))) + sinf(((time * 0.037000f) + (seed * 95.000000f)))) - 1.300000f), 0.000000f, 1.000000f);
    const float dsl_param_hue_base_4 DSL_MAYBE_UNUSED = dsl_fract((time * 0.004300f));
    const float dsl_param_src1_x_5 DSL_MAYBE_UNUSED = (width * dsl_fract((dsl_param_t1_0 * 0.800000f)));
    const float dsl_param_src1_y_6 DSL_MAYBE_UNUSED = (height * (0.350000f + (0.150000f * sinf((dsl_param_t2_1 * 3.000000f)))));
    const float dsl_param_src2_x_7 DSL_MAYBE_UNUSED = (width * dsl_fract(((dsl_param_t1_0 * 0.800000f) + 0.500000f)));
    const float dsl_param_src2_y_8 DSL_MAYBE_UNUSED = (height * (0.650000f + (0.150000f * cosf((dsl_param_t3_2 * 2.000000f)))));
    const float dsl_param_src3_x_9 DSL_MAYBE_UNUSED = (width * dsl_fract(((dsl_param_t2_1 * 0.500000f) + 0.250000f)));
    const float dsl_param_src3_y_10 DSL_MAYBE_UNUSED = (height * (0.500000f + (0.250000f * sinf((dsl_param_t3_2 * 1.400000f)))));
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer waves */
    const float dsl_let_dx1_11 DSL_MAYBE_UNUSED = dsl_wrapdx(x, dsl_param_src1_x_5, width);
    const float dsl_let_dy1_12 DSL_MAYBE_UNUSED = (y - dsl_param_src1_y_6);
    const float dsl_let_d1_13 DSL_MAYBE_UNUSED = sqrtf(fmaxf(((dsl_let_dx1_11 * dsl_let_dx1_11) + (dsl_let_dy1_12 * dsl_let_dy1_12)), 0.100000f));
    const float dsl_let_w1_14 DSL_MAYBE_UNUSED = sinf(((dsl_let_d1_13 * 0.800000f) - (time * 2.000000f)));
    const float dsl_let_dx2_15 DSL_MAYBE_UNUSED = dsl_wrapdx(x, dsl_param_src2_x_7, width);
    const float dsl_let_dy2_16 DSL_MAYBE_UNUSED = (y - dsl_param_src2_y_8);
    const float dsl_let_d2_17 DSL_MAYBE_UNUSED = sqrtf(fmaxf(((dsl_let_dx2_15 * dsl_let_dx2_15) + (dsl_let_dy2_16 * dsl_let_dy2_16)), 0.100000f));
    const float dsl_let_w2_18 DSL_MAYBE_UNUSED = sinf(((dsl_let_d2_17 * 0.600000f) - (time * 1.500000f)));
    const float dsl_let_dx3_19 DSL_MAYBE_UNUSED = dsl_wrapdx(x, dsl_param_src3_x_9, width);
    const float dsl_let_dy3_20 DSL_MAYBE_UNUSED = (y - dsl_param_src3_y_10);
    const float dsl_let_d3_21 DSL_MAYBE_UNUSED = sqrtf(fmaxf(((dsl_let_dx3_19 * dsl_let_dx3_19) + (dsl_let_dy3_20 * dsl_let_dy3_20)), 0.100000f));
    const float dsl_let_w3_22 DSL_MAYBE_UNUSED = sinf(((dsl_let_d3_21 * 0.500000f) - (time * 1.100000f)));
    const float dsl_let_interference_23 DSL_MAYBE_UNUSED = (((dsl_let_w1_14 + dsl_let_w2_18) + dsl_let_w3_22) * 0.333000f);
    const float dsl_let_bright_24 DSL_MAYBE_UNUSED = (dsl_smoothstep((-(0.300000f)), 0.700000f, dsl_let_interference_23) * ((0.040000f + (0.200000f * (1.000000f - dsl_param_vitality_3))) + (0.500000f * dsl_param_vitality_3)));
    const float dsl_let_h_25 DSL_MAYBE_UNUSED = dsl_fract((dsl_param_hue_base_4 + (dsl_let_interference_23 * 0.250000f)));
    const float dsl_let_r_26 DSL_MAYBE_UNUSED = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf((dsl_let_h_25 * 6.28318530717958647692f)))));
    const float dsl_let_g_27 DSL_MAYBE_UNUSED = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf(((dsl_let_h_25 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_28 DSL_MAYBE_UNUSED = (dsl_let_bright_24 * (0.500000f + (0.500000f * sinf(((dsl_let_h_25 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_26, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_27, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_28, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer ripples */
    const float dsl_let_angle_29 DSL_MAYBE_UNUSED = (dsl_param_t3_2 * 2.000000f);
    const float dsl_let_diag_30 DSL_MAYBE_UNUSED = ((x * cosf(dsl_let_angle_29)) + (y * sinf(dsl_let_angle_29)));
    const float dsl_let_ripple_31 DSL_MAYBE_UNUSED = ((sinf(((dsl_let_diag_30 * 0.500000f) + (time * 0.700000f))) * 0.500000f) + 0.500000f);
    const float dsl_let_mask_32 DSL_MAYBE_UNUSED = (dsl_let_ripple_31 * (0.030000f + (0.180000f * dsl_param_vitality_3)));
    const float dsl_let_h_33 DSL_MAYBE_UNUSED = dsl_fract(((dsl_param_hue_base_4 + 0.500000f) + (dsl_let_diag_30 * 0.010000f)));
    const float dsl_let_r_34 DSL_MAYBE_UNUSED = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf((dsl_let_h_33 * 6.28318530717958647692f)))));
    const float dsl_let_g_35 DSL_MAYBE_UNUSED = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf(((dsl_let_h_33 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_36 DSL_MAYBE_UNUSED = (dsl_let_mask_32 * (0.500000f + (0.500000f * sinf(((dsl_let_h_33 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_34, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_35, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_36, 0.000000f, 1.000000f), .a = dsl_let_mask_32 }, __dsl_out);
    /* layer sparkles */
    const float dsl_let_gx_37 DSL_MAYBE_UNUSED = floorf((x * 0.200000f));
    const float dsl_let_gy_38 DSL_MAYBE_UNUSED = floorf((y * 0.130000f));
    const float dsl_let_cell_seed_39 DSL_MAYBE_UNUSED = (((dsl_let_gx_37 * 19.700000f) + (dsl_let_gy_38 * 47.300000f)) + (floorf((time * 0.800000f)) * 31.100000f));
    const float dsl_let_h01_40 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_cell_seed_39);
    const float dsl_let_sparkle_41 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.900000f, 1.000000f, dsl_let_h01_40) * dsl_param_vitality_3);
    const float dsl_let_sh_42 DSL_MAYBE_UNUSED = dsl_fract((dsl_hash01(((dsl_let_gx_37 * 7.000000f) + (dsl_let_gy_38 * 13.000000f))) + (time * 0.020000f)));
    const float dsl_let_r_43 DSL_MAYBE_UNUSED = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf((dsl_let_sh_42 * 6.28318530717958647692f)))));
    const float dsl_let_g_44 DSL_MAYBE_UNUSED = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf(((dsl_let_sh_42 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_45 DSL_MAYBE_UNUSED = (dsl_let_sparkle_41 * (0.500000f + (0.500000f * sinf(((dsl_let_sh_42 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_43, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_44, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_45, 0.000000f, 1.000000f), .a = dsl_let_sparkle_41 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: electric_arcs */
static void electric_arcs_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_arc_speed_0 DSL_MAYBE_UNUSED = 1.500000f;
    const float dsl_param_intensity_1 DSL_MAYBE_UNUSED = 0.800000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer dark_base */
    const float dsl_let_ny_2 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_bg_3 DSL_MAYBE_UNUSED = (0.020000f + (0.010000f * dsl_let_ny_2));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.000000f, .g = 0.000000f, .b = dsl_let_bg_3, .a = 1.000000f }, __dsl_out);
    /* layer arcs */
    const float dsl_let_nx_4 DSL_MAYBE_UNUSED = (x / width);
    const float dsl_let_ny_5 DSL_MAYBE_UNUSED = (y / height);
    for (int32_t dsl_iter_i_6 = 0; dsl_iter_i_6 < 3; dsl_iter_i_6++) {
        const float dsl_index_i_7 DSL_MAYBE_UNUSED = (float)dsl_iter_i_6;
        const float dsl_let_offset_8 DSL_MAYBE_UNUSED = (dsl_index_i_7 * 0.333000f);
        const float dsl_let_ax_9 DSL_MAYBE_UNUSED = dsl_fract((dsl_let_nx_4 + dsl_let_offset_8));
        const float dsl_let_n_10 DSL_MAYBE_UNUSED = dsl_noise3((dsl_let_ax_9 * 4.000000f), (dsl_let_ny_5 * 6.000000f), ((time * dsl_param_arc_speed_0) + (dsl_index_i_7 * 2.700000f)));
        const float dsl_let_displaced_x_11 DSL_MAYBE_UNUSED = (dsl_let_ax_9 + (dsl_let_n_10 * 0.150000f));
        const float dsl_let_dx_12 DSL_MAYBE_UNUSED = fabsf((dsl_let_displaced_x_11 - 0.500000f));
        const float dsl_let_arc_val_13 DSL_MAYBE_UNUSED = (powf(fmaxf((1.000000f - (dsl_let_dx_12 * 8.000000f)), 0.000000f), 6.000000f) * dsl_param_intensity_1);
        const float dsl_let_flicker_14 DSL_MAYBE_UNUSED = dsl_noise3((dsl_let_ax_9 * 10.000000f), (dsl_let_ny_5 * 10.000000f), ((time * 3.000000f) + (dsl_index_i_7 * 5.000000f)));
        const float dsl_let_arc_bright_15 DSL_MAYBE_UNUSED = (dsl_let_arc_val_13 * (0.600000f + (0.400000f * ((dsl_let_flicker_14 * 0.500000f) + 0.500000f))));
        const float dsl_let_r_16 DSL_MAYBE_UNUSED = (dsl_let_arc_bright_15 * 0.800000f);
        const float dsl_let_g_17 DSL_MAYBE_UNUSED = (dsl_let_arc_bright_15 * 0.850000f);
        const float dsl_let_b_18 DSL_MAYBE_UNUSED = dsl_let_arc_bright_15;
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_16, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_17, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_18, 0.000000f, 1.000000f), .a = dsl_let_arc_bright_15 }, __dsl_out);
    }
    /* layer glow_pulse */
    const float dsl_let_nx_19 DSL_MAYBE_UNUSED = (x / width);
    const float dsl_let_ny_20 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_pulse_21 DSL_MAYBE_UNUSED = (powf(((sinf((time * 3.000000f)) * 0.500000f) + 0.500000f), 3.000000f) * 0.150000f);
    const float dsl_let_n_22 DSL_MAYBE_UNUSED = dsl_noise2(((dsl_let_nx_19 * 3.000000f) + (time * 0.500000f)), (dsl_let_ny_20 * 3.000000f));
    const float dsl_let_glow_23 DSL_MAYBE_UNUSED = (dsl_let_pulse_21 * ((dsl_let_n_22 * 0.500000f) + 0.500000f));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (0.200000f * dsl_let_glow_23), .g = (0.300000f * dsl_let_glow_23), .b = dsl_let_glow_23, .a = dsl_let_glow_23 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: forest_wind */
static void forest_wind_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_sway_speed_0 DSL_MAYBE_UNUSED = 0.600000f;
    const float dsl_param_sway_amount_1 DSL_MAYBE_UNUSED = 0.120000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer ground */
    const float dsl_let_ny_2 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_ground_mask_3 DSL_MAYBE_UNUSED = dsl_smoothstep(0.600000f, 0.900000f, dsl_let_ny_2);
    const float dsl_let_r_4 DSL_MAYBE_UNUSED = (dsl_let_ground_mask_3 * 0.250000f);
    const float dsl_let_g_5 DSL_MAYBE_UNUSED = (dsl_let_ground_mask_3 * 0.150000f);
    const float dsl_let_b_6 DSL_MAYBE_UNUSED = (dsl_let_ground_mask_3 * 0.050000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_4, .g = dsl_let_g_5, .b = dsl_let_b_6, .a = dsl_let_ground_mask_3 }, __dsl_out);
    /* layer trees */
    const float dsl_let_nx_7 DSL_MAYBE_UNUSED = (x / width);
    const float dsl_let_ny_8 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_wind_9 DSL_MAYBE_UNUSED = ((dsl_noise2(((dsl_let_nx_7 * 2.000000f) + (time * dsl_param_sway_speed_0)), (time * 0.300000f)) * dsl_param_sway_amount_1) * (1.000000f - dsl_let_ny_8));
    for (int32_t dsl_iter_i_10 = 0; dsl_iter_i_10 < 5; dsl_iter_i_10++) {
        const float dsl_index_i_11 DSL_MAYBE_UNUSED = (float)dsl_iter_i_10;
        const float dsl_let_tree_x_12 DSL_MAYBE_UNUSED = (width * dsl_hash01(((dsl_index_i_11 * 31.000000f) + 7.000000f)));
        const float dsl_let_tree_w_13 DSL_MAYBE_UNUSED = (0.400000f + (dsl_hash01(((dsl_index_i_11 * 17.000000f) + 3.000000f)) * 0.300000f));
        const float dsl_let_trunk_top_14 DSL_MAYBE_UNUSED = (0.300000f + (dsl_hash01(((dsl_index_i_11 * 23.000000f) + 11.000000f)) * 0.300000f));
        const float dsl_let_dx_15 DSL_MAYBE_UNUSED = dsl_wrapdx(x, (dsl_let_tree_x_12 + (dsl_let_wind_9 * height)), width);
        const float dsl_let_trunk_16 DSL_MAYBE_UNUSED = (dsl_smoothstep(dsl_let_tree_w_13, (dsl_let_tree_w_13 * 0.500000f), fabsf(dsl_let_dx_15)) * dsl_smoothstep(dsl_let_trunk_top_14, (dsl_let_trunk_top_14 + 0.100000f), dsl_let_ny_8));
        const float dsl_let_r_17 DSL_MAYBE_UNUSED = (dsl_let_trunk_16 * 0.300000f);
        const float dsl_let_g_18 DSL_MAYBE_UNUSED = (dsl_let_trunk_16 * 0.180000f);
        const float dsl_let_b_19 DSL_MAYBE_UNUSED = (dsl_let_trunk_16 * 0.080000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_17, .g = dsl_let_g_18, .b = dsl_let_b_19, .a = (dsl_let_trunk_16 * 0.800000f) }, __dsl_out);
    }
    /* layer foliage */
    const float dsl_let_nx_20 DSL_MAYBE_UNUSED = (x / width);
    const float dsl_let_ny_21 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_wind_22 DSL_MAYBE_UNUSED = dsl_noise2(((dsl_let_nx_20 * 3.000000f) + ((time * dsl_param_sway_speed_0) * 1.200000f)), ((dsl_let_ny_21 * 2.000000f) + (time * 0.200000f)));
    const float dsl_let_n1_23 DSL_MAYBE_UNUSED = ((dsl_noise2(((dsl_let_nx_20 * 5.000000f) + (dsl_let_wind_22 * 0.300000f)), ((dsl_let_ny_21 * 4.000000f) - (time * 0.100000f))) * 0.500000f) + 0.500000f);
    const float dsl_let_n2_24 DSL_MAYBE_UNUSED = ((dsl_noise2(((dsl_let_nx_20 * 8.000000f) - (time * 0.150000f)), ((dsl_let_ny_21 * 6.000000f) + (dsl_let_wind_22 * 0.200000f))) * 0.500000f) + 0.500000f);
    const float dsl_let_height_mask_25 DSL_MAYBE_UNUSED = dsl_smoothstep(0.700000f, 0.200000f, dsl_let_ny_21);
    const float dsl_let_leaf_26 DSL_MAYBE_UNUSED = (powf((dsl_let_n1_23 * dsl_let_n2_24), 1.500000f) * dsl_let_height_mask_25);
    const float dsl_let_shade_27 DSL_MAYBE_UNUSED = ((dsl_noise3((dsl_let_nx_20 * 4.000000f), (dsl_let_ny_21 * 3.000000f), (time * 0.100000f)) * 0.500000f) + 0.500000f);
    const float dsl_let_r_28 DSL_MAYBE_UNUSED = (dsl_let_leaf_26 * (0.080000f + (0.100000f * dsl_let_shade_27)));
    const float dsl_let_g_29 DSL_MAYBE_UNUSED = (dsl_let_leaf_26 * (0.350000f + (0.350000f * dsl_let_shade_27)));
    const float dsl_let_b_30 DSL_MAYBE_UNUSED = (dsl_let_leaf_26 * (0.050000f + (0.080000f * dsl_let_shade_27)));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_28, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_29, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_30, 0.000000f, 1.000000f), .a = (dsl_let_leaf_26 * 0.750000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Audio: generated from effect: forest_wind */
static float forest_wind_eval_audio(float time, float seed, float sample_rate, float *phasor_state) {
    const float dsl_param_sway_speed_0 DSL_MAYBE_UNUSED = 0.600000f;
    const float dsl_param_sway_amount_1 DSL_MAYBE_UNUSED = 0.120000f;
    float __dsl_audio_out = 0.0f;
    const float dsl_let_n_2 DSL_MAYBE_UNUSED = dsl_noise3((time * 80.000000f), (seed * 10.000000f), (time * 0.500000f));
    const float dsl_let_low_mod_3 DSL_MAYBE_UNUSED = ((sinf((time * 0.700000f)) * 0.500000f) + 0.500000f);
    const float dsl_let_wind_4 DSL_MAYBE_UNUSED = (dsl_let_n_2 * (0.100000f + (0.100000f * dsl_let_low_mod_3)));
    __dsl_audio_out = dsl_clamp(dsl_let_wind_4, (-(1.000000f)), 1.000000f);
    return __dsl_audio_out;
}

/* Generated from effect: gradient */
static void gradient_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer l */
    const float dsl_let_xt_0 DSL_MAYBE_UNUSED = ((cosf(x) * 0.500000f) + 0.500000f);
    const float dsl_let_yt_1 DSL_MAYBE_UNUSED = ((cosf(y) * 0.500000f) + 0.500000f);
    const float dsl_let_at_2 DSL_MAYBE_UNUSED = ((sinf((x * y)) * 0.500000f) + 0.500000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_xt_0, .g = dsl_let_yt_1, .b = dsl_let_xt_0, .a = dsl_let_at_2 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: heartbeat_pulse */
static void heartbeat_pulse_eval_frame(float time, float frame) {
    const float dsl_param_bpm_0 DSL_MAYBE_UNUSED = 72.000000f;
    const float dsl_let_beat_period_1 DSL_MAYBE_UNUSED = (60.000000f / dsl_param_bpm_0);
    const float dsl_let_phase_2 DSL_MAYBE_UNUSED = dsl_fract((time / dsl_let_beat_period_1));
    const float dsl_let_lub_3 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_phase_2 * 8.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_dub_phase_4 DSL_MAYBE_UNUSED = fmaxf((dsl_let_phase_2 - 0.200000f), 0.000000f);
    const float dsl_let_dub_5 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_dub_phase_4 * 10.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_beat_6 DSL_MAYBE_UNUSED = (dsl_let_lub_3 + (dsl_let_dub_5 * 0.700000f));
}

/* Generated from effect: heartbeat_pulse */
static void heartbeat_pulse_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_bpm_0 DSL_MAYBE_UNUSED = 72.000000f;
    const float dsl_let_beat_period_1 DSL_MAYBE_UNUSED = (60.000000f / dsl_param_bpm_0);
    const float dsl_let_phase_2 DSL_MAYBE_UNUSED = dsl_fract((time / dsl_let_beat_period_1));
    const float dsl_let_lub_3 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_phase_2 * 8.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_dub_phase_4 DSL_MAYBE_UNUSED = fmaxf((dsl_let_phase_2 - 0.200000f), 0.000000f);
    const float dsl_let_dub_5 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_dub_phase_4 * 10.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_beat_6 DSL_MAYBE_UNUSED = (dsl_let_lub_3 + (dsl_let_dub_5 * 0.700000f));
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer pulse_ring */
    const float dsl_let_cx_7 DSL_MAYBE_UNUSED = (width * 0.500000f);
    const float dsl_let_cy_8 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_dx_9 DSL_MAYBE_UNUSED = dsl_wrapdx(x, dsl_let_cx_7, width);
    const float dsl_let_dy_10 DSL_MAYBE_UNUSED = (y - dsl_let_cy_8);
    const float dsl_let_dist_11 DSL_MAYBE_UNUSED = sqrtf(((dsl_let_dx_9 * dsl_let_dx_9) + (dsl_let_dy_10 * dsl_let_dy_10)));
    const float dsl_let_max_r_12 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_ring_pos_13 DSL_MAYBE_UNUSED = (dsl_let_beat_6 * dsl_let_max_r_12);
    const float dsl_let_ring_dist_14 DSL_MAYBE_UNUSED = fabsf((dsl_let_dist_11 - dsl_let_ring_pos_13));
    const float dsl_let_ring_15 DSL_MAYBE_UNUSED = (dsl_smoothstep(2.500000f, 0.000000f, dsl_let_ring_dist_14) * dsl_let_beat_6);
    const float dsl_let_r_16 DSL_MAYBE_UNUSED = (dsl_let_ring_15 * 0.900000f);
    const float dsl_let_g_17 DSL_MAYBE_UNUSED = (dsl_let_ring_15 * 0.100000f);
    const float dsl_let_b_18 DSL_MAYBE_UNUSED = (dsl_let_ring_15 * 0.150000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_16, 0.000000f, 1.000000f), .g = dsl_let_g_17, .b = dsl_let_b_18, .a = dsl_let_ring_15 }, __dsl_out);
    /* layer core_glow */
    const float dsl_let_cx_19 DSL_MAYBE_UNUSED = (width * 0.500000f);
    const float dsl_let_cy_20 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_dx_21 DSL_MAYBE_UNUSED = dsl_wrapdx(x, dsl_let_cx_19, width);
    const float dsl_let_dy_22 DSL_MAYBE_UNUSED = (y - dsl_let_cy_20);
    const float dsl_let_dist_23 DSL_MAYBE_UNUSED = sqrtf(((dsl_let_dx_21 * dsl_let_dx_21) + (dsl_let_dy_22 * dsl_let_dy_22)));
    const float dsl_let_glow_24 DSL_MAYBE_UNUSED = (powf(fmaxf((1.000000f - (dsl_let_dist_23 / 8.000000f)), 0.000000f), 2.000000f) * (0.150000f + (0.850000f * dsl_let_beat_6)));
    const float dsl_let_r_25 DSL_MAYBE_UNUSED = (dsl_let_glow_24 * 1.000000f);
    const float dsl_let_g_26 DSL_MAYBE_UNUSED = (dsl_let_glow_24 * 0.200000f);
    const float dsl_let_b_27 DSL_MAYBE_UNUSED = (dsl_let_glow_24 * 0.250000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_25, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_26, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_27, 0.000000f, 1.000000f), .a = dsl_let_glow_24 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Audio: generated from effect: heartbeat_pulse */
static float heartbeat_pulse_eval_audio(float time, float seed, float sample_rate, float *phasor_state) {
    const float dsl_param_bpm_0 DSL_MAYBE_UNUSED = 72.000000f;
    float __dsl_audio_out = 0.0f;
    const float dsl_let_beat_period_1 DSL_MAYBE_UNUSED = (60.000000f / dsl_param_bpm_0);
    const float dsl_let_phase_2 DSL_MAYBE_UNUSED = dsl_fract((time / dsl_let_beat_period_1));
    const float dsl_let_lub_env_3 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_phase_2 * 8.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_lub_4 DSL_MAYBE_UNUSED = ((sinf(((time * 55.000000f) * 6.28318530717958647692f)) * dsl_let_lub_env_3) * 0.500000f);
    const float dsl_let_dub_phase_5 DSL_MAYBE_UNUSED = fmaxf((dsl_let_phase_2 - 0.200000f), 0.000000f);
    const float dsl_let_dub_env_6 DSL_MAYBE_UNUSED = powf(fmaxf((1.000000f - (dsl_let_dub_phase_5 * 10.000000f)), 0.000000f), 3.000000f);
    const float dsl_let_dub_7 DSL_MAYBE_UNUSED = ((sinf(((time * 70.000000f) * 6.28318530717958647692f)) * dsl_let_dub_env_6) * 0.350000f);
    __dsl_audio_out = dsl_clamp((dsl_let_lub_4 + dsl_let_dub_7), (-(1.000000f)), 1.000000f);
    return __dsl_audio_out;
}

/* Generated from effect: infinite_lines */
static void infinite_lines_eval_frame(float time, float frame) {
    const float dsl_param_line_half_width_0 DSL_MAYBE_UNUSED = 0.700000f;
    const float dsl_param_rotation_speed_1 DSL_MAYBE_UNUSED = 0.350000f;
    const float dsl_param_color_speed_2 DSL_MAYBE_UNUSED = 0.100000f;
    const float dsl_let_t_3 DSL_MAYBE_UNUSED = (time * dsl_param_rotation_speed_1);
    const float dsl_let_tc_4 DSL_MAYBE_UNUSED = (time * dsl_param_color_speed_2);
}

/* Generated from effect: infinite_lines */
static void infinite_lines_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_line_half_width_0 DSL_MAYBE_UNUSED = 0.700000f;
    const float dsl_param_rotation_speed_1 DSL_MAYBE_UNUSED = 0.350000f;
    const float dsl_param_color_speed_2 DSL_MAYBE_UNUSED = 0.100000f;
    const float dsl_let_t_3 DSL_MAYBE_UNUSED = (time * dsl_param_rotation_speed_1);
    const float dsl_let_tc_4 DSL_MAYBE_UNUSED = (time * dsl_param_color_speed_2);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer lines */
    const float dsl_let_theta_5 DSL_MAYBE_UNUSED = ((x / width) * 6.28318530717958647692f);
    for (int32_t dsl_iter_i_6 = 0; dsl_iter_i_6 < 4; dsl_iter_i_6++) {
        const float dsl_index_i_7 DSL_MAYBE_UNUSED = (float)dsl_iter_i_6;
        const float dsl_let_phase_8 DSL_MAYBE_UNUSED = ((seed * 6.28318530717958647692f) + (dsl_index_i_7 * 1.700000f));
        const float dsl_let_pivot_frac_y_9 DSL_MAYBE_UNUSED = dsl_fract((seed * (3.170000f + (dsl_index_i_7 * 2.310000f))));
        const float dsl_let_pivot_y_10 DSL_MAYBE_UNUSED = (dsl_let_pivot_frac_y_9 * height);
        const float dsl_let_dir_sign_11 DSL_MAYBE_UNUSED = ((floorf((dsl_fract((seed * (7.130000f + (dsl_index_i_7 * 1.930000f)))) + 0.500000f)) * 2.000000f) - 1.000000f);
        const float dsl_let_speed_var_12 DSL_MAYBE_UNUSED = (0.700000f + (dsl_fract((seed * (5.410000f + (dsl_index_i_7 * 3.070000f)))) * 0.600000f));
        const float dsl_let_angle_13 DSL_MAYBE_UNUSED = (dsl_let_phase_8 + ((dsl_let_t_3 * dsl_let_dir_sign_11) * dsl_let_speed_var_12));
        const float dsl_let_nx_14 DSL_MAYBE_UNUSED = (-(sinf(dsl_let_angle_13)));
        const float dsl_let_ny_15 DSL_MAYBE_UNUSED = cosf(dsl_let_angle_13);
        const float dsl_let_pivot_theta_16 DSL_MAYBE_UNUSED = (dsl_fract((seed * (1.730000f + (dsl_index_i_7 * 4.190000f)))) * 6.28318530717958647692f);
        const float dsl_let_pivot_x_norm_17 DSL_MAYBE_UNUSED = ((dsl_let_pivot_theta_16 / 6.28318530717958647692f) * width);
        const float dsl_let_rel_x_18 DSL_MAYBE_UNUSED = (x - dsl_let_pivot_x_norm_17);
        const float dsl_let_rel_y_19 DSL_MAYBE_UNUSED = (y - dsl_let_pivot_y_10);
        const float dsl_let_base_proj_20 DSL_MAYBE_UNUSED = ((dsl_let_rel_x_18 * dsl_let_nx_14) + (dsl_let_rel_y_19 * dsl_let_ny_15));
        const float dsl_let_wrap_step_21 DSL_MAYBE_UNUSED = (width * dsl_let_nx_14);
        const float dsl_let_d_center_22 DSL_MAYBE_UNUSED = fabsf(dsl_let_base_proj_20);
        const float dsl_let_d_left_23 DSL_MAYBE_UNUSED = fabsf((dsl_let_base_proj_20 - dsl_let_wrap_step_21));
        const float dsl_let_d_right_24 DSL_MAYBE_UNUSED = fabsf((dsl_let_base_proj_20 + dsl_let_wrap_step_21));
        const float dsl_let_d_25 DSL_MAYBE_UNUSED = fminf(dsl_let_d_center_22, fminf(dsl_let_d_left_23, dsl_let_d_right_24));
        const float dsl_let_line_alpha_26 DSL_MAYBE_UNUSED = (1.000000f - dsl_smoothstep((dsl_param_line_half_width_0 * 0.300000f), dsl_param_line_half_width_0, dsl_let_d_25));
        const float dsl_let_hue_phase_27 DSL_MAYBE_UNUSED = ((dsl_let_tc_4 * (0.800000f + (dsl_index_i_7 * 0.300000f))) + (seed * (2.000000f + (dsl_index_i_7 * 1.500000f))));
        const float dsl_let_r_28 DSL_MAYBE_UNUSED = (0.500000f + (0.500000f * sinf(dsl_let_hue_phase_27)));
        const float dsl_let_g_29 DSL_MAYBE_UNUSED = (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 2.094000f))));
        const float dsl_let_b_30 DSL_MAYBE_UNUSED = (0.500000f + (0.500000f * sinf((dsl_let_hue_phase_27 + 4.189000f))));
        const float dsl_let_max_ch_31 DSL_MAYBE_UNUSED = fmaxf(dsl_let_r_28, fmaxf(dsl_let_g_29, dsl_let_b_30));
        const float dsl_let_boost_32 DSL_MAYBE_UNUSED = dsl_clamp((0.850000f / fmaxf(dsl_let_max_ch_31, 0.010000f)), 1.000000f, 2.000000f);
        const float dsl_let_rb_33 DSL_MAYBE_UNUSED = dsl_clamp((dsl_let_r_28 * dsl_let_boost_32), 0.000000f, 1.000000f);
        const float dsl_let_gb_34 DSL_MAYBE_UNUSED = dsl_clamp((dsl_let_g_29 * dsl_let_boost_32), 0.000000f, 1.000000f);
        const float dsl_let_bb_35 DSL_MAYBE_UNUSED = dsl_clamp((dsl_let_b_30 * dsl_let_boost_32), 0.000000f, 1.000000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_rb_33, .g = dsl_let_gb_34, .b = dsl_let_bb_35, .a = dsl_let_line_alpha_26 }, __dsl_out);
    }
    *out_color = __dsl_out;
}

/* Generated from effect: lava_lamp */
static void lava_lamp_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_drift_0 DSL_MAYBE_UNUSED = 0.300000f;
    const float dsl_param_blob_scale_1 DSL_MAYBE_UNUSED = 0.070000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer warm_bg */
    const float dsl_let_ny_2 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_r_3 DSL_MAYBE_UNUSED = (0.120000f + (0.080000f * dsl_let_ny_2));
    const float dsl_let_g_4 DSL_MAYBE_UNUSED = (0.030000f + (0.020000f * dsl_let_ny_2));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_3, .g = dsl_let_g_4, .b = 0.010000f, .a = 1.000000f }, __dsl_out);
    /* layer blobs */
    const float dsl_let_nx_5 DSL_MAYBE_UNUSED = (x * dsl_param_blob_scale_1);
    const float dsl_let_ny_6 DSL_MAYBE_UNUSED = (y * dsl_param_blob_scale_1);
    const float dsl_let_t_7 DSL_MAYBE_UNUSED = (time * dsl_param_drift_0);
    const float dsl_let_n1_8 DSL_MAYBE_UNUSED = ((dsl_noise2((dsl_let_nx_5 + (dsl_let_t_7 * 0.700000f)), (dsl_let_ny_6 - dsl_let_t_7)) * 0.500000f) + 0.500000f);
    const float dsl_let_n2_9 DSL_MAYBE_UNUSED = ((dsl_noise2(((dsl_let_nx_5 * 1.500000f) - (dsl_let_t_7 * 0.400000f)), ((dsl_let_ny_6 * 1.500000f) + (dsl_let_t_7 * 0.600000f))) * 0.500000f) + 0.500000f);
    const float dsl_let_combined_10 DSL_MAYBE_UNUSED = ((dsl_let_n1_8 + dsl_let_n2_9) * 0.500000f);
    const float dsl_let_blob_11 DSL_MAYBE_UNUSED = powf(dsl_smoothstep(0.350000f, 0.650000f, dsl_let_combined_10), 1.500000f);
    const float dsl_let_hue_noise_12 DSL_MAYBE_UNUSED = ((dsl_noise2(((dsl_let_nx_5 * 0.500000f) + (dsl_let_t_7 * 0.200000f)), (dsl_let_ny_6 * 0.500000f)) * 0.500000f) + 0.500000f);
    const float dsl_let_r_13 DSL_MAYBE_UNUSED = (dsl_let_blob_11 * (0.900000f + (0.100000f * dsl_let_hue_noise_12)));
    const float dsl_let_g_14 DSL_MAYBE_UNUSED = (dsl_let_blob_11 * (0.250000f + (0.450000f * dsl_let_hue_noise_12)));
    const float dsl_let_b_15 DSL_MAYBE_UNUSED = ((dsl_let_blob_11 * 0.050000f) * dsl_let_hue_noise_12);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_13, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_14, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_15, 0.000000f, 1.000000f), .a = (dsl_let_blob_11 * 0.850000f) }, __dsl_out);
    /* layer hot_spots */
    const float dsl_let_nx_16 DSL_MAYBE_UNUSED = ((x * dsl_param_blob_scale_1) * 1.300000f);
    const float dsl_let_ny_17 DSL_MAYBE_UNUSED = ((y * dsl_param_blob_scale_1) * 1.300000f);
    const float dsl_let_t_18 DSL_MAYBE_UNUSED = ((time * dsl_param_drift_0) * 0.800000f);
    const float dsl_let_n_19 DSL_MAYBE_UNUSED = dsl_noise2((dsl_let_nx_16 - (dsl_let_t_18 * 0.500000f)), (dsl_let_ny_17 + (dsl_let_t_18 * 0.300000f)));
    const float dsl_let_hot_20 DSL_MAYBE_UNUSED = (powf(fmaxf(dsl_let_n_19, 0.000000f), 4.000000f) * 0.600000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (1.000000f * dsl_let_hot_20), .g = (0.900000f * dsl_let_hot_20), .b = (0.400000f * dsl_let_hot_20), .a = dsl_let_hot_20 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: ocean_waves */
static void ocean_waves_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_speed_0 DSL_MAYBE_UNUSED = 0.400000f;
    const float dsl_param_scale1_1 DSL_MAYBE_UNUSED = 0.150000f;
    const float dsl_param_scale2_2 DSL_MAYBE_UNUSED = 0.080000f;
    const float dsl_param_scale3_3 DSL_MAYBE_UNUSED = 0.220000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer deep_water */
    const float dsl_let_nx_4 DSL_MAYBE_UNUSED = (x * dsl_param_scale1_1);
    const float dsl_let_ny_5 DSL_MAYBE_UNUSED = (y * dsl_param_scale1_1);
    const float dsl_let_n_6 DSL_MAYBE_UNUSED = dsl_noise2((dsl_let_nx_4 + ((time * dsl_param_speed_0) * 0.600000f)), (dsl_let_ny_5 + ((time * dsl_param_speed_0) * 0.300000f)));
    const float dsl_let_val_7 DSL_MAYBE_UNUSED = ((dsl_let_n_6 * 0.500000f) + 0.500000f);
    const float dsl_let_dark_8 DSL_MAYBE_UNUSED = (dsl_let_val_7 * 0.350000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.000000f, .g = (dsl_let_dark_8 * 0.600000f), .b = dsl_let_dark_8, .a = 1.000000f }, __dsl_out);
    /* layer mid_waves */
    const float dsl_let_nx_9 DSL_MAYBE_UNUSED = (x * dsl_param_scale2_2);
    const float dsl_let_ny_10 DSL_MAYBE_UNUSED = (y * dsl_param_scale2_2);
    const float dsl_let_n_11 DSL_MAYBE_UNUSED = dsl_noise2((dsl_let_nx_9 + (time * dsl_param_speed_0)), (dsl_let_ny_10 - ((time * dsl_param_speed_0) * 0.500000f)));
    const float dsl_let_val_12 DSL_MAYBE_UNUSED = ((dsl_let_n_11 * 0.500000f) + 0.500000f);
    const float dsl_let_bright_13 DSL_MAYBE_UNUSED = (powf(dsl_let_val_12, 1.500000f) * 0.550000f);
    const float dsl_let_a_14 DSL_MAYBE_UNUSED = dsl_smoothstep(0.150000f, 0.500000f, dsl_let_bright_13);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.050000f, .g = (dsl_let_bright_13 * 0.800000f), .b = dsl_let_bright_13, .a = dsl_let_a_14 }, __dsl_out);
    /* layer surface_foam */
    const float dsl_let_nx_15 DSL_MAYBE_UNUSED = (x * dsl_param_scale3_3);
    const float dsl_let_ny_16 DSL_MAYBE_UNUSED = (y * dsl_param_scale3_3);
    const float dsl_let_n_17 DSL_MAYBE_UNUSED = dsl_noise2((dsl_let_nx_15 - ((time * dsl_param_speed_0) * 1.200000f)), (dsl_let_ny_16 + ((time * dsl_param_speed_0) * 0.700000f)));
    const float dsl_let_foam_18 DSL_MAYBE_UNUSED = powf(((dsl_let_n_17 * 0.500000f) + 0.500000f), 3.000000f);
    const float dsl_let_crest_19 DSL_MAYBE_UNUSED = dsl_smoothstep(0.300000f, 0.600000f, dsl_let_foam_18);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (0.700000f * dsl_let_crest_19), .g = (0.950000f * dsl_let_crest_19), .b = (1.000000f * dsl_let_crest_19), .a = (dsl_let_crest_19 * 0.700000f) }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: primal_storm_v1 */
static void primal_storm_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_t1_0 DSL_MAYBE_UNUSED = ((time * 0.073200f) + (seed * 100.000000f));
    const float dsl_param_t2_1 DSL_MAYBE_UNUSED = ((time * 0.141400f) + (seed * 200.000000f));
    const float dsl_param_t3_2 DSL_MAYBE_UNUSED = ((time * 0.223600f) + (seed * 300.000000f));
    const float dsl_param_storm_3 DSL_MAYBE_UNUSED = dsl_clamp((((sinf(((time * 0.097000f) + (seed * 60.000000f))) + sinf(((time * 0.067000f) + (seed * 80.000000f)))) + sinf(((time * 0.041000f) + (seed * 40.000000f)))) - 1.400000f), 0.000000f, 1.000000f);
    const float dsl_param_speed_4 DSL_MAYBE_UNUSED = (0.500000f + (2.000000f * dsl_param_storm_3));
    const float dsl_param_epoch_5 DSL_MAYBE_UNUSED = dsl_fract((time * 0.005100f));
    const float dsl_param_scx_6 DSL_MAYBE_UNUSED = (6.28318530717958647692f / width);
    const float dsl_param_scy_7 DSL_MAYBE_UNUSED = (6.28318530717958647692f / height);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer glow */
    const float dsl_let_cy_8 DSL_MAYBE_UNUSED = (height * (0.500000f + (0.100000f * sinf((dsl_param_t1_0 * 2.700000f)))));
    const float dsl_let_dy_9 DSL_MAYBE_UNUSED = (fabsf((y - dsl_let_cy_8)) / height);
    const float dsl_let_g_val_10 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.450000f, 0.000000f, dsl_let_dy_9) * ((0.030000f + (0.180000f * (1.000000f - dsl_param_storm_3))) + (0.300000f * dsl_param_storm_3)));
    const float dsl_let_h_11 DSL_MAYBE_UNUSED = dsl_fract(((dsl_param_epoch_5 + (dsl_let_dy_9 * 0.300000f)) + (0.100000f * sinf((dsl_param_t1_0 * 1.500000f)))));
    const float dsl_let_r_12 DSL_MAYBE_UNUSED = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf((dsl_let_h_11 * 6.28318530717958647692f)))));
    const float dsl_let_g_13 DSL_MAYBE_UNUSED = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf(((dsl_let_h_11 * 6.28318530717958647692f) + (6.28318530717958647692f / 3.000000f))))));
    const float dsl_let_b_14 DSL_MAYBE_UNUSED = (dsl_let_g_val_10 * (0.500000f + (0.500000f * sinf(((dsl_let_h_11 * 6.28318530717958647692f) + ((6.28318530717958647692f * 2.000000f) / 3.000000f))))));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_12, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_13, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_14, 0.000000f, 1.000000f), .a = 1.000000f }, __dsl_out);
    /* layer bands */
    const float dsl_let_scroll_15 DSL_MAYBE_UNUSED = (((y * dsl_param_scy_7) * 4.000000f) + (time * dsl_param_speed_4));
    const float dsl_let_wave_16 DSL_MAYBE_UNUSED = (sinf(dsl_let_scroll_15) * cosf((((dsl_let_scroll_15 * 0.700000f) + ((x * dsl_param_scx_6) * 2.000000f)) + (dsl_param_t2_1 * 3.000000f))));
    const float dsl_let_mask_17 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.200000f, 0.900000f, dsl_let_wave_16) * (0.040000f + (0.550000f * dsl_param_storm_3)));
    const float dsl_let_mix_v_18 DSL_MAYBE_UNUSED = ((sinf(((dsl_param_t3_2 * 3.000000f) + (y * dsl_param_scy_7))) * 0.500000f) + 0.500000f);
    const float dsl_let_r_19 DSL_MAYBE_UNUSED = (dsl_let_mask_17 * (0.300000f + (0.600000f * dsl_let_mix_v_18)));
    const float dsl_let_g_20 DSL_MAYBE_UNUSED = (dsl_let_mask_17 * (0.600000f - (0.300000f * dsl_let_mix_v_18)));
    const float dsl_let_b_21 DSL_MAYBE_UNUSED = (dsl_let_mask_17 * 0.900000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_19, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_20, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_21, 0.000000f, 1.000000f), .a = dsl_let_mask_17 }, __dsl_out);
    /* layer lightning */
    const float dsl_let_col_22 DSL_MAYBE_UNUSED = floorf((x * 0.500000f));
    const float dsl_let_t_slice_23 DSL_MAYBE_UNUSED = floorf((time * 4.000000f));
    const float dsl_let_chance_24 DSL_MAYBE_UNUSED = dsl_hash01(((dsl_let_col_22 * 13.700000f) + (dsl_let_t_slice_23 * 71.300000f)));
    const float dsl_let_strike_25 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.930000f, 1.000000f, dsl_let_chance_24) * dsl_param_storm_3);
    const float dsl_let_bolt_y_26 DSL_MAYBE_UNUSED = (dsl_hash01(((dsl_let_col_22 * 29.100000f) + (dsl_let_t_slice_23 * 53.700000f))) * height);
    const float dsl_let_bolt_spread_27 DSL_MAYBE_UNUSED = dsl_smoothstep(0.350000f, 0.000000f, (fabsf((y - dsl_let_bolt_y_26)) / height));
    const float dsl_let_bolt_28 DSL_MAYBE_UNUSED = (dsl_let_strike_25 * dsl_let_bolt_spread_27);
    const float dsl_let_r_29 DSL_MAYBE_UNUSED = (dsl_let_bolt_28 * (0.700000f + (0.300000f * dsl_let_bolt_spread_27)));
    const float dsl_let_g_30 DSL_MAYBE_UNUSED = (dsl_let_bolt_28 * (0.800000f + (0.200000f * dsl_let_bolt_spread_27)));
    const float dsl_let_b_31 DSL_MAYBE_UNUSED = dsl_let_bolt_28;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_29, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_30, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_31, 0.000000f, 1.000000f), .a = dsl_let_bolt_28 }, __dsl_out);
    /* layer embers */
    const float dsl_let_px_32 DSL_MAYBE_UNUSED = floorf((x * 0.250000f));
    const float dsl_let_stripe_seed_33 DSL_MAYBE_UNUSED = dsl_hash01((dsl_let_px_32 * 37.100000f));
    const float dsl_let_rise_speed_34 DSL_MAYBE_UNUSED = (0.500000f + (dsl_let_stripe_seed_33 * 1.500000f));
    const float dsl_let_py_35 DSL_MAYBE_UNUSED = dsl_fract(((dsl_let_stripe_seed_33 * 10.000000f) - ((time * dsl_let_rise_speed_34) * 0.050000f)));
    const float dsl_let_ember_y_36 DSL_MAYBE_UNUSED = (dsl_let_py_35 * height);
    const float dsl_let_dy_37 DSL_MAYBE_UNUSED = (fabsf((y - dsl_let_ember_y_36)) / height);
    const float dsl_let_ember_38 DSL_MAYBE_UNUSED = ((dsl_smoothstep(0.060000f, 0.000000f, dsl_let_dy_37) * dsl_param_storm_3) * dsl_hash01(((dsl_let_px_32 * 53.000000f) + (floorf((time * 0.300000f)) * 17.000000f))));
    const float dsl_let_r_39 DSL_MAYBE_UNUSED = (dsl_let_ember_38 * 1.000000f);
    const float dsl_let_g_40 DSL_MAYBE_UNUSED = (dsl_let_ember_38 * (0.400000f + (0.300000f * dsl_let_stripe_seed_33)));
    const float dsl_let_b_41 DSL_MAYBE_UNUSED = (dsl_let_ember_38 * 0.100000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_clamp(dsl_let_r_39, 0.000000f, 1.000000f), .g = dsl_clamp(dsl_let_g_40, 0.000000f, 1.000000f), .b = dsl_clamp(dsl_let_b_41, 0.000000f, 1.000000f), .a = dsl_let_ember_38 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: rain_matrix */
static void rain_matrix_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_fall_speed_0 DSL_MAYBE_UNUSED = 6.000000f;
    const float dsl_param_trail_len_1 DSL_MAYBE_UNUSED = 8.000000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer dark_bg */
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.000000f, .g = 0.020000f, .b = 0.000000f, .a = 1.000000f }, __dsl_out);
    /* layer rain_drops */
    for (int32_t dsl_iter_i_2 = 0; dsl_iter_i_2 < 6; dsl_iter_i_2++) {
        const float dsl_index_i_3 DSL_MAYBE_UNUSED = (float)dsl_iter_i_2;
        const float dsl_let_col_id_4 DSL_MAYBE_UNUSED = (floorf(x) + (dsl_index_i_3 * 7.000000f));
        const float dsl_let_col_seed_5 DSL_MAYBE_UNUSED = dsl_hash01(((dsl_let_col_id_4 * 17.310000f) + (dsl_index_i_3 * 53.000000f)));
        const float dsl_let_speed_6 DSL_MAYBE_UNUSED = (dsl_param_fall_speed_0 * (0.500000f + dsl_let_col_seed_5));
        const float dsl_let_phase_7 DSL_MAYBE_UNUSED = dsl_hash01(((dsl_let_col_id_4 * 41.700000f) + (dsl_index_i_3 * 29.000000f)));
        const float dsl_let_cycle_8 DSL_MAYBE_UNUSED = dsl_fract((((time * dsl_let_speed_6) / (height + dsl_param_trail_len_1)) + dsl_let_phase_7));
        const float dsl_let_drop_y_9 DSL_MAYBE_UNUSED = ((dsl_let_cycle_8 * (height + dsl_param_trail_len_1)) - (dsl_param_trail_len_1 * 0.500000f));
        const float dsl_let_dy_10 DSL_MAYBE_UNUSED = (dsl_let_drop_y_9 - y);
        const float dsl_let_head_bright_11 DSL_MAYBE_UNUSED = dsl_smoothstep(1.500000f, 0.000000f, fabsf(dsl_let_dy_10));
        const float dsl_let_trail_12 DSL_MAYBE_UNUSED = (dsl_smoothstep(dsl_param_trail_len_1, 0.000000f, dsl_let_dy_10) * dsl_smoothstep((-(1.000000f)), 0.500000f, dsl_let_dy_10));
        const float dsl_let_char_cell_13 DSL_MAYBE_UNUSED = floorf(y);
        const float dsl_let_char_hash_14 DSL_MAYBE_UNUSED = dsl_hash01((((dsl_let_char_cell_13 * 13.700000f) + (dsl_let_col_id_4 * 7.300000f)) + floorf((time * 4.000000f))));
        const float dsl_let_char_flicker_15 DSL_MAYBE_UNUSED = (0.700000f + (0.300000f * dsl_let_char_hash_14));
        const float dsl_let_brightness_16 DSL_MAYBE_UNUSED = (fmaxf(dsl_let_head_bright_11, (dsl_let_trail_12 * 0.400000f)) * dsl_let_char_flicker_15);
        const float dsl_let_is_head_17 DSL_MAYBE_UNUSED = dsl_smoothstep(1.000000f, 0.000000f, fabsf(dsl_let_dy_10));
        const float dsl_let_r_18 DSL_MAYBE_UNUSED = ((dsl_let_brightness_16 * dsl_let_is_head_17) * 0.700000f);
        const float dsl_let_g_19 DSL_MAYBE_UNUSED = dsl_let_brightness_16;
        const float dsl_let_b_20 DSL_MAYBE_UNUSED = ((dsl_let_brightness_16 * dsl_let_is_head_17) * 0.500000f);
        __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_18, .g = dsl_clamp(dsl_let_g_19, 0.000000f, 1.000000f), .b = dsl_let_b_20, .a = dsl_let_brightness_16 }, __dsl_out);
    }
    *out_color = __dsl_out;
}

/* Generated from effect: rain_ripple_v1 */
static void rain_ripple_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_lane_x_0 DSL_MAYBE_UNUSED = 8.000000f;
    const float dsl_param_drop_y_1 DSL_MAYBE_UNUSED = ((height * 0.500000f) + (sinf((time * 1.700000f)) * (height * 0.450000f)));
    const float dsl_param_ripple_y_2 DSL_MAYBE_UNUSED = (height - 2.000000f);
    const float dsl_param_ripple_r_3 DSL_MAYBE_UNUSED = (1.200000f + ((sinf((time * 4.500000f)) + 1.000000f) * 3.500000f));
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer drop */
    const float dsl_let_lane_jitter_4 DSL_MAYBE_UNUSED = (dsl_hash_signed((frame + 17.000000f)) * 0.450000f);
    const float dsl_let_dx_5 DSL_MAYBE_UNUSED = dsl_wrapdx(x, (dsl_param_lane_x_0 + dsl_let_lane_jitter_4), width);
    const float dsl_let_streak_6 DSL_MAYBE_UNUSED = dsl_box((dsl_vec2_t){ .x = dsl_let_dx_5, .y = (y - (dsl_param_drop_y_1 - 1.200000f)) }, (dsl_vec2_t){ .x = 0.180000f, .y = 1.200000f });
    const float dsl_let_head_7 DSL_MAYBE_UNUSED = dsl_circle((dsl_vec2_t){ .x = dsl_let_dx_5, .y = (y - dsl_param_drop_y_1) }, 0.400000f);
    const float dsl_let_a_8 DSL_MAYBE_UNUSED = (((1.000000f - dsl_smoothstep(0.000000f, 0.750000f, dsl_let_streak_6)) * 0.360000f) + ((1.000000f - dsl_smoothstep(0.000000f, 0.550000f, dsl_let_head_7)) * 0.480000f));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.700000f, .g = 0.840000f, .b = 1.000000f, .a = fminf(dsl_let_a_8, 0.900000f) }, __dsl_out);
    /* layer ripple */
    const dsl_vec2_t dsl_let_local_9 DSL_MAYBE_UNUSED = (dsl_vec2_t){ .x = dsl_wrapdx(x, dsl_param_lane_x_0, width), .y = (y - dsl_param_ripple_y_2) };
    const float dsl_let_ring_10 DSL_MAYBE_UNUSED = (fabsf(dsl_circle(dsl_let_local_9, dsl_param_ripple_r_3)) - 0.200000f);
    const float dsl_let_a_11 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep(0.000000f, 0.800000f, dsl_let_ring_10)) * 0.600000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.350000f, .g = 0.780000f, .b = 1.000000f, .a = dsl_let_a_11 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: soap_bubbles_v1 */
static void soap_bubbles_eval_frame(float time, float frame) {
    const float dsl_let_two_pi_0 DSL_MAYBE_UNUSED = (3.14159265358979323846f * 2.000000f);
    const float dsl_let_depth_time_1 DSL_MAYBE_UNUSED = (time * 0.750000f);
    const float dsl_let_tint_time_2 DSL_MAYBE_UNUSED = (time * 0.800000f);
}

/* Generated from effect: soap_bubbles_v1 */
static void soap_bubbles_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_let_two_pi_0 DSL_MAYBE_UNUSED = (3.14159265358979323846f * 2.000000f);
    const float dsl_let_depth_time_1 DSL_MAYBE_UNUSED = (time * 0.750000f);
    const float dsl_let_tint_time_2 DSL_MAYBE_UNUSED = (time * 0.800000f);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer bubbles */
    for (int32_t dsl_iter_i_3 = 0; dsl_iter_i_3 < 14; dsl_iter_i_3++) {
        const float dsl_index_i_4 DSL_MAYBE_UNUSED = (float)dsl_iter_i_3;
        const float dsl_let_id_5 DSL_MAYBE_UNUSED = dsl_index_i_4;
        const float dsl_let_phase01_6 DSL_MAYBE_UNUSED = dsl_hash01(((dsl_let_id_5 * 13.000000f) + 5.000000f));
        const float dsl_let_phase_7 DSL_MAYBE_UNUSED = (dsl_let_phase01_6 * dsl_let_two_pi_0);
        const float dsl_let_depth_phase_8 DSL_MAYBE_UNUSED = (dsl_hash01(((dsl_let_id_5 * 17.000000f) + 3.000000f)) * dsl_let_two_pi_0);
        const float dsl_let_lane_x_9 DSL_MAYBE_UNUSED = (width * dsl_hash01(((dsl_let_id_5 * 31.000000f) + 1.000000f)));
        const float dsl_let_radius_10 DSL_MAYBE_UNUSED = (1.400000f + (dsl_hash01(((dsl_let_id_5 * 41.000000f) + 2.000000f)) * 2.400000f));
        const float dsl_let_rise_speed_11 DSL_MAYBE_UNUSED = (5.000000f + (dsl_hash01(((dsl_let_id_5 * 53.000000f) + 7.000000f)) * 9.000000f));
        const float dsl_let_wobble_amp_12 DSL_MAYBE_UNUSED = (0.200000f + (dsl_hash01(((dsl_let_id_5 * 67.000000f) + 9.000000f)) * 1.500000f));
        const float dsl_let_wobble_freq_13 DSL_MAYBE_UNUSED = (0.450000f + (dsl_hash01(((dsl_let_id_5 * 79.000000f) + 4.000000f)) * 1.450000f));
        const float dsl_let_travel_14 DSL_MAYBE_UNUSED = (height + (dsl_let_radius_10 * 2.200000f));
        const float dsl_let_cycle_15 DSL_MAYBE_UNUSED = dsl_fract(((time * (dsl_let_rise_speed_11 / dsl_let_travel_14)) + dsl_let_phase01_6));
        const float dsl_let_center_x_16 DSL_MAYBE_UNUSED = (dsl_let_lane_x_9 + (sinf(((time * dsl_let_wobble_freq_13) + dsl_let_phase_7)) * dsl_let_wobble_amp_12));
        const float dsl_let_center_y_17 DSL_MAYBE_UNUSED = ((height + dsl_let_radius_10) - (dsl_let_cycle_15 * dsl_let_travel_14));
        const dsl_vec2_t dsl_let_local_18 DSL_MAYBE_UNUSED = (dsl_vec2_t){ .x = dsl_wrapdx(x, dsl_let_center_x_16, width), .y = (y - dsl_let_center_y_17) };
        const float dsl_let_pop_t_19 DSL_MAYBE_UNUSED = dsl_clamp(((dsl_let_cycle_15 - 0.900000f) / 0.100000f), 0.000000f, 1.000000f);
        const float dsl_let_pop_gate_20 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.000000f, 0.150000f, dsl_let_pop_t_19) * (1.000000f - dsl_smoothstep(0.750000f, 1.000000f, dsl_let_pop_t_19)));
        const float dsl_let_body_radius_21 DSL_MAYBE_UNUSED = (dsl_let_radius_10 * (1.000000f - (0.550000f * dsl_let_pop_t_19)));
        const float dsl_let_d_22 DSL_MAYBE_UNUSED = dsl_circle(dsl_let_local_18, dsl_let_body_radius_21);
        const float dsl_let_shell_alpha_23 DSL_MAYBE_UNUSED = (1.000000f - dsl_smoothstep(0.050000f, 0.850000f, fabsf(dsl_let_d_22)));
        const float dsl_let_core_alpha_24 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep((-(dsl_let_body_radius_21)), 0.000000f, dsl_let_d_22)) * 0.120000f);
        const float dsl_let_hi_d_25 DSL_MAYBE_UNUSED = dsl_circle((dsl_vec2_t){ .x = (dsl_wrapdx(x, dsl_let_center_x_16, width) + (dsl_let_body_radius_21 * 0.400000f)), .y = ((y - dsl_let_center_y_17) - (dsl_let_body_radius_21 * 0.340000f)) }, (dsl_let_body_radius_21 * 0.230000f));
        const float dsl_let_hi_alpha_26 DSL_MAYBE_UNUSED = ((1.000000f - dsl_smoothstep(0.000000f, 0.550000f, dsl_let_hi_d_25)) * 0.260000f);
        const float dsl_let_depth_27 DSL_MAYBE_UNUSED = sinf((dsl_let_depth_time_1 + dsl_let_depth_phase_8));
        const float dsl_let_front_factor_28 DSL_MAYBE_UNUSED = dsl_smoothstep(0.000000f, 0.350000f, dsl_let_depth_27);
        const float dsl_let_depth_alpha_29 DSL_MAYBE_UNUSED = (0.620000f + (0.380000f * dsl_let_front_factor_28));
        const float dsl_let_body_alpha_30 DSL_MAYBE_UNUSED = fminf((((((dsl_let_shell_alpha_23 * 0.460000f) + dsl_let_core_alpha_24) + dsl_let_hi_alpha_26) * (1.000000f - (0.920000f * dsl_let_pop_t_19))) * dsl_let_depth_alpha_29), 0.860000f);
        if (dsl_let_body_alpha_30 > 0.0f) {
            const float dsl_let_tint_31 DSL_MAYBE_UNUSED = (0.500000f + (0.500000f * sinf((dsl_let_tint_time_2 + dsl_let_phase_7))));
            __dsl_out = dsl_blend_over((dsl_color_t){ .r = fminf((0.660000f + (0.200000f * dsl_let_tint_31)), 1.000000f), .g = fminf((0.820000f + (0.120000f * dsl_let_tint_31)), 1.000000f), .b = 1.000000f, .a = dsl_let_body_alpha_30 }, __dsl_out);
        } else {
        }
        if (dsl_let_pop_gate_20 > 0.0f) {
            const float dsl_let_ring_radius_32 DSL_MAYBE_UNUSED = (dsl_let_body_radius_21 + ((dsl_let_radius_10 + 0.800000f) * dsl_let_pop_t_19));
            const float dsl_let_ring_width_33 DSL_MAYBE_UNUSED = (0.120000f + ((1.000000f - dsl_let_pop_t_19) * 0.180000f));
            const float dsl_let_ring_d_34 DSL_MAYBE_UNUSED = (fabsf(dsl_circle(dsl_let_local_18, dsl_let_ring_radius_32)) - dsl_let_ring_width_33);
            const float dsl_let_ring_alpha_35 DSL_MAYBE_UNUSED = ((((1.000000f - dsl_smoothstep(0.000000f, 0.650000f, dsl_let_ring_d_34)) * dsl_let_pop_gate_20) * 0.900000f) * dsl_let_depth_alpha_29);
            __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.580000f, .g = 0.880000f, .b = 1.000000f, .a = dsl_let_ring_alpha_35 }, __dsl_out);
        } else {
        }
    }
    *out_color = __dsl_out;
}

/* Generated from effect: spiral_galaxy */
static void spiral_galaxy_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_rotation_speed_0 DSL_MAYBE_UNUSED = 0.150000f;
    const float dsl_param_arm_count_1 DSL_MAYBE_UNUSED = 2.000000f;
    const float dsl_param_arm_tightness_2 DSL_MAYBE_UNUSED = 3.000000f;
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer nebula_bg */
    const float dsl_let_nx_3 DSL_MAYBE_UNUSED = (x / width);
    const float dsl_let_ny_4 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_n_5 DSL_MAYBE_UNUSED = ((dsl_noise2((dsl_let_nx_3 * 3.000000f), (dsl_let_ny_4 * 3.000000f)) * 0.500000f) + 0.500000f);
    const float dsl_let_bg_6 DSL_MAYBE_UNUSED = (dsl_let_n_5 * 0.060000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (dsl_let_bg_6 * 0.300000f), .g = (dsl_let_bg_6 * 0.100000f), .b = (dsl_let_bg_6 * 0.500000f), .a = 1.000000f }, __dsl_out);
    /* layer spiral_arms */
    const float dsl_let_cx_7 DSL_MAYBE_UNUSED = (width * 0.500000f);
    const float dsl_let_cy_8 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_dx_9 DSL_MAYBE_UNUSED = (dsl_wrapdx(x, dsl_let_cx_7, width) / width);
    const float dsl_let_dy_10 DSL_MAYBE_UNUSED = ((y - dsl_let_cy_8) / height);
    const float dsl_let_dist_11 DSL_MAYBE_UNUSED = sqrtf(((dsl_let_dx_9 * dsl_let_dx_9) + (dsl_let_dy_10 * dsl_let_dy_10)));
    const float dsl_let_angle_12 DSL_MAYBE_UNUSED = ((dsl_let_dx_9 * 6.000000f) + (dsl_let_dy_10 * 6.000000f));
    const float dsl_let_spiral_13 DSL_MAYBE_UNUSED = sinf((((dsl_let_angle_12 + ((dsl_let_dist_11 * dsl_param_arm_tightness_2) * 6.28318530717958647692f)) - (time * dsl_param_rotation_speed_0)) * dsl_param_arm_count_1));
    const float dsl_let_arm_14 DSL_MAYBE_UNUSED = powf(((dsl_let_spiral_13 * 0.500000f) + 0.500000f), 3.000000f);
    const float dsl_let_radial_15 DSL_MAYBE_UNUSED = dsl_smoothstep(0.500000f, 0.050000f, dsl_let_dist_11);
    const float dsl_let_brightness_16 DSL_MAYBE_UNUSED = ((dsl_let_arm_14 * dsl_let_radial_15) * 0.700000f);
    const float dsl_let_r_17 DSL_MAYBE_UNUSED = (dsl_let_brightness_16 * 0.600000f);
    const float dsl_let_g_18 DSL_MAYBE_UNUSED = (dsl_let_brightness_16 * 0.400000f);
    const float dsl_let_b_19 DSL_MAYBE_UNUSED = dsl_let_brightness_16;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_17, .g = dsl_let_g_18, .b = dsl_let_b_19, .a = dsl_let_brightness_16 }, __dsl_out);
    /* layer arm_stars */
    const float dsl_let_cell_x_20 DSL_MAYBE_UNUSED = floorf((x * 0.400000f));
    const float dsl_let_cell_y_21 DSL_MAYBE_UNUSED = floorf((y * 0.300000f));
    const float dsl_let_star_seed_22 DSL_MAYBE_UNUSED = ((dsl_let_cell_x_20 * 47.310000f) + (dsl_let_cell_y_21 * 29.170000f));
    const float dsl_let_presence_23 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_star_seed_22);
    const float dsl_let_twinkle_24 DSL_MAYBE_UNUSED = ((sinf(((time * 1.500000f) + (dsl_hash01((dsl_let_star_seed_22 + 3.000000f)) * 6.28318530717958647692f))) * 0.500000f) + 0.500000f);
    const float dsl_let_cx_25 DSL_MAYBE_UNUSED = (width * 0.500000f);
    const float dsl_let_cy_26 DSL_MAYBE_UNUSED = (height * 0.500000f);
    const float dsl_let_dx_27 DSL_MAYBE_UNUSED = (dsl_wrapdx(x, dsl_let_cx_25, width) / width);
    const float dsl_let_dy_28 DSL_MAYBE_UNUSED = ((y - dsl_let_cy_26) / height);
    const float dsl_let_dist_29 DSL_MAYBE_UNUSED = sqrtf(((dsl_let_dx_27 * dsl_let_dx_27) + (dsl_let_dy_28 * dsl_let_dy_28)));
    const float dsl_let_angle_30 DSL_MAYBE_UNUSED = ((dsl_let_dx_27 * 6.000000f) + (dsl_let_dy_28 * 6.000000f));
    const float dsl_let_spiral_31 DSL_MAYBE_UNUSED = sinf((((dsl_let_angle_30 + ((dsl_let_dist_29 * dsl_param_arm_tightness_2) * 6.28318530717958647692f)) - (time * dsl_param_rotation_speed_0)) * dsl_param_arm_count_1));
    const float dsl_let_arm_proximity_32 DSL_MAYBE_UNUSED = powf(((dsl_let_spiral_31 * 0.500000f) + 0.500000f), 2.000000f);
    const float dsl_let_threshold_33 DSL_MAYBE_UNUSED = (0.970000f - (0.050000f * dsl_let_arm_proximity_32));
    const float dsl_let_bright_34 DSL_MAYBE_UNUSED = (dsl_smoothstep(dsl_let_threshold_33, 1.000000f, dsl_let_presence_23) * (0.500000f + (0.500000f * dsl_let_twinkle_24)));
    const float dsl_let_r_35 DSL_MAYBE_UNUSED = (dsl_let_bright_34 * 0.900000f);
    const float dsl_let_g_36 DSL_MAYBE_UNUSED = (dsl_let_bright_34 * 0.850000f);
    const float dsl_let_b_37 DSL_MAYBE_UNUSED = dsl_let_bright_34;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_35, .g = dsl_let_g_36, .b = dsl_let_b_37, .a = dsl_let_bright_34 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: starfield */
static void starfield_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer background */
    const float dsl_let_ny_0 DSL_MAYBE_UNUSED = (y / height);
    const float dsl_let_grad_1 DSL_MAYBE_UNUSED = (dsl_let_ny_0 * 0.060000f);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = 0.010000f, .g = 0.010000f, .b = (0.040000f + dsl_let_grad_1), .a = 1.000000f }, __dsl_out);
    /* layer far_stars */
    const float dsl_let_cell_x_2 DSL_MAYBE_UNUSED = floorf((x * 0.500000f));
    const float dsl_let_cell_y_3 DSL_MAYBE_UNUSED = floorf((y * 0.500000f));
    const float dsl_let_star_seed_4 DSL_MAYBE_UNUSED = ((dsl_let_cell_x_2 * 31.170000f) + (dsl_let_cell_y_3 * 57.930000f));
    const float dsl_let_presence_5 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_star_seed_4);
    const float dsl_let_flicker_6 DSL_MAYBE_UNUSED = dsl_hash01((dsl_let_star_seed_4 + (floorf((time * 0.800000f)) * 11.300000f)));
    const float dsl_let_bright_7 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.920000f, 1.000000f, dsl_let_presence_5) * (0.300000f + (0.700000f * dsl_let_flicker_6)));
    const float dsl_let_tint_8 DSL_MAYBE_UNUSED = dsl_hash01((dsl_let_star_seed_4 + 7.000000f));
    const float dsl_let_r_9 DSL_MAYBE_UNUSED = (dsl_let_bright_7 * (0.700000f + (0.300000f * dsl_let_tint_8)));
    const float dsl_let_g_10 DSL_MAYBE_UNUSED = (dsl_let_bright_7 * (0.700000f + (0.300000f * (1.000000f - dsl_let_tint_8))));
    const float dsl_let_b_11 DSL_MAYBE_UNUSED = dsl_let_bright_7;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_9, .g = dsl_let_g_10, .b = dsl_let_b_11, .a = dsl_let_bright_7 }, __dsl_out);
    /* layer mid_stars */
    const float dsl_let_cell_x_12 DSL_MAYBE_UNUSED = floorf((x * 0.330000f));
    const float dsl_let_cell_y_13 DSL_MAYBE_UNUSED = floorf((y * 0.330000f));
    const float dsl_let_star_seed_14 DSL_MAYBE_UNUSED = ((dsl_let_cell_x_12 * 43.710000f) + (dsl_let_cell_y_13 * 23.170000f));
    const float dsl_let_presence_15 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_star_seed_14);
    const float dsl_let_twinkle_16 DSL_MAYBE_UNUSED = ((sinf(((time * 2.500000f) + (dsl_hash01((dsl_let_star_seed_14 + 3.000000f)) * 6.28318530717958647692f))) * 0.500000f) + 0.500000f);
    const float dsl_let_bright_17 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.950000f, 1.000000f, dsl_let_presence_15) * (0.500000f + (0.500000f * dsl_let_twinkle_16)));
    const float dsl_let_warm_18 DSL_MAYBE_UNUSED = dsl_hash01((dsl_let_star_seed_14 + 13.000000f));
    const float dsl_let_r_19 DSL_MAYBE_UNUSED = (dsl_let_bright_17 * (0.800000f + (0.200000f * dsl_let_warm_18)));
    const float dsl_let_g_20 DSL_MAYBE_UNUSED = (dsl_let_bright_17 * (0.850000f + (0.150000f * dsl_let_warm_18)));
    const float dsl_let_b_21 DSL_MAYBE_UNUSED = (dsl_let_bright_17 * (1.000000f - (0.200000f * dsl_let_warm_18)));
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_19, .g = dsl_let_g_20, .b = dsl_let_b_21, .a = dsl_let_bright_17 }, __dsl_out);
    /* layer bright_stars */
    const float dsl_let_cell_x_22 DSL_MAYBE_UNUSED = floorf((x * 0.200000f));
    const float dsl_let_cell_y_23 DSL_MAYBE_UNUSED = floorf((y * 0.200000f));
    const float dsl_let_star_seed_24 DSL_MAYBE_UNUSED = ((dsl_let_cell_x_22 * 71.310000f) + (dsl_let_cell_y_23 * 37.910000f));
    const float dsl_let_presence_25 DSL_MAYBE_UNUSED = dsl_hash01(dsl_let_star_seed_24);
    const float dsl_let_twinkle_26 DSL_MAYBE_UNUSED = powf(((sinf(((time * 1.800000f) + (dsl_hash01((dsl_let_star_seed_24 + 5.000000f)) * 6.28318530717958647692f))) * 0.500000f) + 0.500000f), 2.000000f);
    const float dsl_let_bright_27 DSL_MAYBE_UNUSED = (dsl_smoothstep(0.970000f, 1.000000f, dsl_let_presence_25) * (0.600000f + (0.400000f * dsl_let_twinkle_26)));
    const float dsl_let_r_28 DSL_MAYBE_UNUSED = dsl_let_bright_27;
    const float dsl_let_g_29 DSL_MAYBE_UNUSED = dsl_let_bright_27;
    const float dsl_let_b_30 DSL_MAYBE_UNUSED = dsl_let_bright_27;
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = dsl_let_r_28, .g = dsl_let_g_29, .b = dsl_let_b_30, .a = dsl_let_bright_27 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Generated from effect: tone_pulse */
static void tone_pulse_eval_frame(float time, float frame) {
    const float dsl_param_base_freq_0 DSL_MAYBE_UNUSED = 220.000000f;
    const float dsl_param_pulse_rate_1 DSL_MAYBE_UNUSED = 2.000000f;
    const float dsl_let_pulse_2 DSL_MAYBE_UNUSED = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_brightness_3 DSL_MAYBE_UNUSED = (dsl_let_pulse_2 * dsl_let_pulse_2);
}

/* Generated from effect: tone_pulse */
static void tone_pulse_eval_pixel(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {
    const float dsl_param_base_freq_0 DSL_MAYBE_UNUSED = 220.000000f;
    const float dsl_param_pulse_rate_1 DSL_MAYBE_UNUSED = 2.000000f;
    const float dsl_let_pulse_2 DSL_MAYBE_UNUSED = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_brightness_3 DSL_MAYBE_UNUSED = (dsl_let_pulse_2 * dsl_let_pulse_2);
    dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };
    /* layer glow */
    const float dsl_let_hue_4 DSL_MAYBE_UNUSED = dsl_fract(((time * 0.050000f) + seed));
    const float dsl_let_r_5 DSL_MAYBE_UNUSED = dsl_clamp(((sinf((dsl_let_hue_4 * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_g_6 DSL_MAYBE_UNUSED = dsl_clamp(((sinf(((dsl_let_hue_4 * 6.283185f) + 2.094000f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_b_7 DSL_MAYBE_UNUSED = dsl_clamp(((sinf(((dsl_let_hue_4 * 6.283185f) + 4.189000f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_dist_8 DSL_MAYBE_UNUSED = (fabsf(((y / height) - 0.500000f)) * 2.000000f);
    const float dsl_let_mask_9 DSL_MAYBE_UNUSED = dsl_clamp((1.000000f - dsl_let_dist_8), 0.000000f, 1.000000f);
    const float dsl_let_intensity_10 DSL_MAYBE_UNUSED = (dsl_let_brightness_3 * dsl_let_mask_9);
    __dsl_out = dsl_blend_over((dsl_color_t){ .r = (dsl_let_r_5 * dsl_let_intensity_10), .g = (dsl_let_g_6 * dsl_let_intensity_10), .b = (dsl_let_b_7 * dsl_let_intensity_10), .a = dsl_let_intensity_10 }, __dsl_out);
    *out_color = __dsl_out;
}

/* Audio: generated from effect: tone_pulse */
static float tone_pulse_eval_audio(float time, float seed, float sample_rate, float *phasor_state) {
    const float dsl_param_base_freq_0 DSL_MAYBE_UNUSED = 220.000000f;
    const float dsl_param_pulse_rate_1 DSL_MAYBE_UNUSED = 2.000000f;
    float __dsl_audio_out = 0.0f;
    const float dsl_let_pulse_2 DSL_MAYBE_UNUSED = dsl_clamp(((sinf(((time * dsl_param_pulse_rate_1) * 6.283185f)) * 0.500000f) + 0.500000f), 0.000000f, 1.000000f);
    const float dsl_let_freq_3 DSL_MAYBE_UNUSED = (dsl_param_base_freq_0 + (dsl_let_pulse_2 * dsl_param_base_freq_0));
    const float dsl_let_envelope_4 DSL_MAYBE_UNUSED = ((dsl_let_pulse_2 * dsl_let_pulse_2) * 0.400000f);
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
    float (*eval_audio)(float time, float seed, float sample_rate, float *phasor_state);
    int phasor_count;
    int target_fps;
} dsl_shader_entry_t;

const dsl_shader_entry_t dsl_shader_registry[] = {
    { .name = "a440-test-tone", .folder = "/native/audio", .eval_pixel = a440_test_tone_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 1, .eval_audio = a440_test_tone_eval_audio, .phasor_count = 0, .target_fps = 0 },
    { .name = "aurora", .folder = "/native/ambient", .eval_pixel = aurora_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "aurora-ribbons-classic", .folder = "/native/ambient", .eval_pixel = aurora_ribbons_classic_eval_pixel, .has_frame_func = 1, .eval_frame = aurora_ribbons_classic_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "campfire", .folder = "/native/nature", .eval_pixel = campfire_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "chaos-nebula", .folder = "/native/energetic", .eval_pixel = chaos_nebula_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "dream-weaver", .folder = "/native/ambient", .eval_pixel = dream_weaver_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "electric-arcs", .folder = "/native/energetic", .eval_pixel = electric_arcs_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "forest-wind", .folder = "/native/nature", .eval_pixel = forest_wind_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 1, .eval_audio = forest_wind_eval_audio, .phasor_count = 0, .target_fps = 30 },
    { .name = "gradient", .folder = "/native/ambient", .eval_pixel = gradient_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "heartbeat-pulse", .folder = "/native/audio", .eval_pixel = heartbeat_pulse_eval_pixel, .has_frame_func = 1, .eval_frame = heartbeat_pulse_eval_frame, .has_audio_func = 1, .eval_audio = heartbeat_pulse_eval_audio, .phasor_count = 0, .target_fps = 0 },
    { .name = "infinite-lines", .folder = "/native/geometric", .eval_pixel = infinite_lines_eval_pixel, .has_frame_func = 1, .eval_frame = infinite_lines_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "lava-lamp", .folder = "/native/ambient", .eval_pixel = lava_lamp_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "ocean-waves", .folder = "/native/nature", .eval_pixel = ocean_waves_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "primal-storm", .folder = "/native/energetic", .eval_pixel = primal_storm_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "rain-matrix", .folder = "/native/energetic", .eval_pixel = rain_matrix_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "rain-ripple", .folder = "/native/nature", .eval_pixel = rain_ripple_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "soap-bubbles", .folder = "/native/ambient", .eval_pixel = soap_bubbles_eval_pixel, .has_frame_func = 1, .eval_frame = soap_bubbles_eval_frame, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 20 },
    { .name = "spiral-galaxy", .folder = "/native/cosmic", .eval_pixel = spiral_galaxy_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "starfield", .folder = "/native/cosmic", .eval_pixel = starfield_eval_pixel, .has_frame_func = 0, .eval_frame = (void(*)(float,float))0, .has_audio_func = 0, .eval_audio = (float(*)(float,float,float,float*))0, .phasor_count = 0, .target_fps = 0 },
    { .name = "tone-pulse", .folder = "/native/audio", .eval_pixel = tone_pulse_eval_pixel, .has_frame_func = 1, .eval_frame = tone_pulse_eval_frame, .has_audio_func = 1, .eval_audio = tone_pulse_eval_audio, .phasor_count = 0, .target_fps = 0 },
};

const int dsl_shader_registry_count = 20;

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
