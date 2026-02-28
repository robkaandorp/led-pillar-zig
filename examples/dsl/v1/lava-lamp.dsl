// Lava Lamp — slow meditative blobs with warm colors.
// Large-scale noise drives blob formation and movement.
// Reds, oranges, and yellows with smooth transitions.
effect lava_lamp

param drift = 0.3
param blob_scale = 0.07

layer warm_bg {
  let ny = y / height
  let r = 0.12 + 0.08 * ny
  let g = 0.03 + 0.02 * ny
  blend rgba(r, g, 0.01, 1.0)
}

layer blobs {
  let nx = x * blob_scale
  let ny = y * blob_scale
  let t = time * drift

  // Two noise layers for organic blob shapes
  let n1 = noise(nx + t * 0.7, ny - t) * 0.5 + 0.5
  let n2 = noise(nx * 1.5 - t * 0.4, ny * 1.5 + t * 0.6) * 0.5 + 0.5
  let combined = (n1 + n2) * 0.5

  // Sharp blob edges via pow
  let blob = pow(smoothstep(0.35, 0.65, combined), 1.5)

  // Warm palette: shift from red to orange to yellow based on noise
  let hue_noise = noise(nx * 0.5 + t * 0.2, ny * 0.5) * 0.5 + 0.5
  let r = blob * (0.9 + 0.1 * hue_noise)
  let g = blob * (0.25 + 0.45 * hue_noise)
  let b = blob * 0.05 * hue_noise
  blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), blob * 0.85)
}

layer hot_spots {
  let nx = x * blob_scale * 1.3
  let ny = y * blob_scale * 1.3
  let t = time * drift * 0.8
  let n = noise(nx - t * 0.5, ny + t * 0.3)
  let hot = pow(max(n, 0.0), 4.0) * 0.6
  blend rgba(1.0 * hot, 0.9 * hot, 0.4 * hot, hot)
}

emit
