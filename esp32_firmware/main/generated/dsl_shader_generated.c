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
void dsl_shader_eval_pixel(float time, float frame, float x, float y, float width, float height, dsl_color_t *out_color) {    const float dsl_param_speed_0 = 0.280000f;
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
