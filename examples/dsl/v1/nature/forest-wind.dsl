// Forest Wind — green swaying trees and grass with noise-driven
// movement. Nature-inspired greens and browns with gentle audio
// of filtered wind noise.
effect forest_wind
fps 30

param sway_speed = 0.6
param sway_amount = 0.12

layer ground {
  let ny = y / height
  // Brown earth at the bottom, darkening upward
  let ground_mask = smoothstep(0.6, 0.9, ny)
  let r = ground_mask * 0.25
  let g = ground_mask * 0.15
  let b = ground_mask * 0.05
  blend rgba(r, g, b, ground_mask)
}

layer trees {
  let nx = x / width
  let ny = y / height

  // Wind displacement varies with height (more sway at top)
  let wind = noise(nx * 2.0 + time * sway_speed, time * 0.3) * sway_amount * (1.0 - ny)

  // Tree trunks from hash-placed columns
  for i in 0..5 {
    let tree_x = width * hash01(i * 31.0 + 7.0)
    let tree_w = 0.4 + hash01(i * 17.0 + 3.0) * 0.3
    let trunk_top = 0.3 + hash01(i * 23.0 + 11.0) * 0.3

    let dx = wrapdx(x, tree_x + wind * height, width)
    let trunk = smoothstep(tree_w, tree_w * 0.5, abs(dx)) * smoothstep(trunk_top, trunk_top + 0.1, ny)
    let r = trunk * 0.3
    let g = trunk * 0.18
    let b = trunk * 0.08
    blend rgba(r, g, b, trunk * 0.8)
  }
}

layer foliage {
  let nx = x / width
  let ny = y / height
  let wind = noise(nx * 3.0 + time * sway_speed * 1.2, ny * 2.0 + time * 0.2)

  // Canopy of leaves using noise for organic shapes
  let n1 = noise(nx * 5.0 + wind * 0.3, ny * 4.0 - time * 0.1) * 0.5 + 0.5
  let n2 = noise(nx * 8.0 - time * 0.15, ny * 6.0 + wind * 0.2) * 0.5 + 0.5

  // Foliage density increases toward the top
  let height_mask = smoothstep(0.7, 0.2, ny)
  let leaf = pow(n1 * n2, 1.5) * height_mask

  // Vary greens: darker deep, brighter surface
  let shade = noise3(nx * 4.0, ny * 3.0, time * 0.1) * 0.5 + 0.5
  let r = leaf * (0.08 + 0.1 * shade)
  let g = leaf * (0.35 + 0.35 * shade)
  let b = leaf * (0.05 + 0.08 * shade)
  blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), leaf * 0.75)
}

emit

audio {
  // Gentle wind: filtered noise
  let n = noise3(time * 80.0, seed * 10.0, time * 0.5)
  let low_mod = sin(time * 0.7) * 0.5 + 0.5
  let wind = n * (0.1 + 0.1 * low_mod)
  out clamp(wind, -1.0, 1.0)
}
