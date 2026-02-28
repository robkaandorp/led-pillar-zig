// Starfield — deep space with twinkling stars at multiple depth layers.
// Hash functions place stars at pseudo-random positions with varying
// brightness that flickers over time. Dark blue background.
effect starfield

layer background {
  let ny = y / height
  let grad = ny * 0.06
  blend rgba(0.01, 0.01, 0.04 + grad, 1.0)
}

layer far_stars {
  let cell_x = floor(x * 0.5)
  let cell_y = floor(y * 0.5)
  let star_seed = cell_x * 31.17 + cell_y * 57.93
  let presence = hash01(star_seed)
  let flicker = hash01(star_seed + floor(time * 0.8) * 11.3)
  let bright = smoothstep(0.92, 1.0, presence) * (0.3 + 0.7 * flicker)
  let tint = hash01(star_seed + 7.0)
  let r = bright * (0.7 + 0.3 * tint)
  let g = bright * (0.7 + 0.3 * (1.0 - tint))
  let b = bright
  blend rgba(r, g, b, bright)
}

layer mid_stars {
  let cell_x = floor(x * 0.33)
  let cell_y = floor(y * 0.33)
  let star_seed = cell_x * 43.71 + cell_y * 23.17
  let presence = hash01(star_seed)
  let twinkle = sin(time * 2.5 + hash01(star_seed + 3.0) * TAU) * 0.5 + 0.5
  let bright = smoothstep(0.95, 1.0, presence) * (0.5 + 0.5 * twinkle)
  let warm = hash01(star_seed + 13.0)
  let r = bright * (0.8 + 0.2 * warm)
  let g = bright * (0.85 + 0.15 * warm)
  let b = bright * (1.0 - 0.2 * warm)
  blend rgba(r, g, b, bright)
}

layer bright_stars {
  let cell_x = floor(x * 0.2)
  let cell_y = floor(y * 0.2)
  let star_seed = cell_x * 71.31 + cell_y * 37.91
  let presence = hash01(star_seed)
  let twinkle = pow(sin(time * 1.8 + hash01(star_seed + 5.0) * TAU) * 0.5 + 0.5, 2.0)
  let bright = smoothstep(0.97, 1.0, presence) * (0.6 + 0.4 * twinkle)
  let r = bright
  let g = bright
  let b = bright
  blend rgba(r, g, b, bright)
}

emit
