// Infinite Lines — multiple rotating lines wrapping around the cylindrical display.
// Each line has its own pivot, rotation speed, and smoothly transitioning color.
// Uses seed for unique randomized starting positions on each run.
effect infinite_lines

param line_half_width = 0.7
param rotation_speed = 0.35
param color_speed = 0.1

frame {
  let t = time * rotation_speed
  let tc = time * color_speed
}

layer lines {
  let theta = (x / width) * TAU

  for i in 0..4 {
    // Pseudo-random per-line offsets derived from seed and line index
    let phase = seed * TAU + i * 1.7
    let pivot_frac_y = fract(seed * (3.17 + i * 2.31))
    let pivot_y = pivot_frac_y * height
    let dir_sign = floor(fract(seed * (7.13 + i * 1.93)) + 0.5) * 2.0 - 1.0

    // Line angle rotates over time; each line has a unique speed offset
    let speed_var = 0.7 + fract(seed * (5.41 + i * 3.07)) * 0.6
    let angle = phase + t * dir_sign * speed_var

    // Line normal from angle
    let nx = -sin(angle)
    let ny = cos(angle)

    // Pivot x is embedded in the wrap-aware distance calculation via theta
    let pivot_theta = fract(seed * (1.73 + i * 4.19)) * TAU
    let pivot_x_norm = pivot_theta / TAU * width

    // Signed distance from pixel to the infinite line with horizontal wrapping
    let rel_x = x - pivot_x_norm
    let rel_y = y - pivot_y
    let base_proj = rel_x * nx + rel_y * ny
    let wrap_step = width * nx

    // Check wrapping: find the nearest wrap copy
    let d_center = abs(base_proj)
    let d_left = abs(base_proj - wrap_step)
    let d_right = abs(base_proj + wrap_step)
    let d = min(d_center, min(d_left, d_right))

    // Smooth line with soft falloff
    let line_alpha = 1.0 - smoothstep(line_half_width * 0.3, line_half_width, d)

    // Color transitions: each line cycles through hues independently
    let hue_phase = tc * (0.8 + i * 0.3) + seed * (2.0 + i * 1.5)
    let r = 0.5 + 0.5 * sin(hue_phase)
    let g = 0.5 + 0.5 * sin(hue_phase + 2.094)
    let b = 0.5 + 0.5 * sin(hue_phase + 4.189)

    // Boost saturation: ensure at least one channel is bright
    let max_ch = max(r, max(g, b))
    let boost = clamp(0.85 / max(max_ch, 0.01), 1.0, 2.0)
    let rb = clamp(r * boost, 0.0, 1.0)
    let gb = clamp(g * boost, 0.0, 1.0)
    let bb = clamp(b * boost, 0.0, 1.0)

    blend rgba(rb, gb, bb, line_alpha)
  }
}

emit
