#include "fw_native_shader.h"
#include "generated/dsl_shader_generated.c"

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
