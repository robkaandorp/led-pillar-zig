// Spiral Galaxy — rotating spiral arms on the cylindrical display.
// Coordinate math creates spiral arms that rotate slowly with
// stars scattered along the arms. Purple/blue/white palette.
effect spiral_galaxy

param rotation_speed = 0.15
param arm_count = 2.0
param arm_tightness = 3.0

layer nebula_bg {
  let nx = x / width
  let ny = y / height
  let n = noise(nx * 3.0, ny * 3.0) * 0.5 + 0.5
  let bg = n * 0.06
  blend rgba(bg * 0.3, bg * 0.1, bg * 0.5, 1.0)
}

layer spiral_arms {
  let cx = width * 0.5
  let cy = height * 0.5
  let dx = wrapdx(x, cx, width) / width
  let dy = (y - cy) / height

  // Approximate angle from center using noise-perturbed coordinates
  let dist = sqrt(dx * dx + dy * dy)
  let angle = dx * 6.0 + dy * 6.0

  // Spiral formula: angle + distance * tightness creates arms
  let spiral = sin((angle + dist * arm_tightness * TAU - time * rotation_speed) * arm_count)
  let arm = pow(spiral * 0.5 + 0.5, 3.0)

  // Fade with distance from center
  let radial = smoothstep(0.5, 0.05, dist)
  let brightness = arm * radial * 0.7

  // Purple-blue palette
  let r = brightness * 0.6
  let g = brightness * 0.4
  let b = brightness
  blend rgba(r, g, b, brightness)
}

layer arm_stars {
  let cell_x = floor(x * 0.4)
  let cell_y = floor(y * 0.3)
  let star_seed = cell_x * 47.31 + cell_y * 29.17
  let presence = hash01(star_seed)
  let twinkle = sin(time * 1.5 + hash01(star_seed + 3.0) * TAU) * 0.5 + 0.5

  // Stars appear more along spiral arms
  let cx = width * 0.5
  let cy = height * 0.5
  let dx = wrapdx(x, cx, width) / width
  let dy = (y - cy) / height
  let dist = sqrt(dx * dx + dy * dy)
  let angle = dx * 6.0 + dy * 6.0
  let spiral = sin((angle + dist * arm_tightness * TAU - time * rotation_speed) * arm_count)
  let arm_proximity = pow(spiral * 0.5 + 0.5, 2.0)

  let threshold = 0.97 - 0.05 * arm_proximity
  let bright = smoothstep(threshold, 1.0, presence) * (0.5 + 0.5 * twinkle)
  let r = bright * 0.9
  let g = bright * 0.85
  let b = bright
  blend rgba(r, g, b, bright)
}

emit
