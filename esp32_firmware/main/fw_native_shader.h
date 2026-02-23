#pragma once

#include <stdint.h>

typedef struct {
    float r;
    float g;
    float b;
    float a;
} fw_native_shader_color_t;

void fw_native_shader_eval_pixel(
    float time_seconds,
    float frame_counter,
    float x,
    float y,
    float width,
    float height,
    fw_native_shader_color_t *out_color
);
