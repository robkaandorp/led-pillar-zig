// Rain Matrix — digital rain effect in the style of falling code.
// Columns of green characters fall at different speeds using hash
// for column-specific timing and % for repeating patterns.
effect rain_matrix

param fall_speed = 6.0
param trail_len = 8.0

layer dark_bg {
  blend rgba(0.0, 0.02, 0.0, 1.0)
}

layer rain_drops {
  for i in 0..6 {
    // Each pass creates rain at a different column subset
    let col_id = floor(x) + i * 7.0
    let col_seed = hash01(col_id * 17.31 + i * 53.0)

    // Column-specific speed and phase
    let speed = fall_speed * (0.5 + col_seed)
    let phase = hash01(col_id * 41.7 + i * 29.0)

    // Current drop position using % for repeating pattern
    let cycle = fract(time * speed / (height + trail_len) + phase)
    let drop_y = cycle * (height + trail_len) - trail_len * 0.5

    // Distance from the drop head
    let dy = drop_y - y

    // Trail: bright at the head, fading behind
    let head_bright = smoothstep(1.5, 0.0, abs(dy))
    let trail = smoothstep(trail_len, 0.0, dy) * smoothstep(-1.0, 0.5, dy)

    // Character-like granularity
    let char_cell = floor(y)
    let char_hash = hash01(char_cell * 13.7 + col_id * 7.3 + floor(time * 4.0))
    let char_flicker = 0.7 + 0.3 * char_hash

    let brightness = max(head_bright, trail * 0.4) * char_flicker

    // Bright white head, green trail
    let is_head = smoothstep(1.0, 0.0, abs(dy))
    let r = brightness * is_head * 0.7
    let g = brightness
    let b = brightness * is_head * 0.5
    blend rgba(r, clamp(g, 0.0, 1.0), b, brightness)
  }
}

emit
