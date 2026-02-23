#pragma once

#include <stdint.h>
#include <stddef.h>

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

/**
 * Render a full frame into an RGB frame buffer.
 * Keeps the pixel loop in the same translation unit as the generated shader
 * so the compiler can fully inline dsl_shader_eval_pixel.
 *
 * @param time_seconds   Elapsed time since shader start.
 * @param frame_counter  Monotonically increasing frame index.
 * @param width          Grid width (columns).
 * @param height         Grid height (rows).
 * @param serpentine     Non-zero if odd columns are bottom-to-top.
 * @param frame_buffer   Output buffer (width*height*3 bytes, RGB).
 * @param buffer_len     Size of frame_buffer in bytes.
 * @return 0 on success, -1 on error.
 */
int fw_native_shader_render_frame(
    float time_seconds,
    float frame_counter,
    uint16_t width,
    uint16_t height,
    int serpentine,
    uint8_t *frame_buffer,
    size_t buffer_len
);
