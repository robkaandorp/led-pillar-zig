#pragma once

#include <stdint.h>
#include <stddef.h>

#include "generated/dsl_shader_registry.h"

/**
 * Render a full frame into an RGB frame buffer using the given shader entry.
 * Keeps the pixel loop in the same translation unit as the generated shaders
 * so the compiler can fully inline eval_pixel via __attribute__((flatten)).
 *
 * @param shader         Shader entry from the registry (must not be NULL).
 * @param time_seconds   Elapsed time since shader start.
 * @param frame_counter  Monotonically increasing frame index.
 * @param width          Grid width (columns).
 * @param height         Grid height (rows).
 * @param seed           Per-activation random seed in [0, 1).
 * @param serpentine     Non-zero if odd columns are bottom-to-top.
 * @param frame_buffer   Output buffer (width*height*3 bytes, RGB).
 * @param buffer_len     Size of frame_buffer in bytes.
 * @return 0 on success, -1 on error.
 */
int fw_native_shader_render_frame(
    const dsl_shader_entry_t *shader,
    float time_seconds,
    float frame_counter,
    uint16_t width,
    uint16_t height,
    float seed,
    int serpentine,
    uint8_t *frame_buffer,
    size_t buffer_len
);

/**
 * Run microbenchmarks for each math function used by DSL shaders.
 * Logs per-function timing via ESP_LOGI.  Call once at shader activation.
 */
void fw_native_shader_run_benchmarks(void);
