// Electric Arcs — animated lightning tendrils on a dark background.
// Uses noise3 with time for animated electric paths, pow() for sharp
// falloff, and % for repeating arc patterns. White/blue on dark.
effect electric_arcs

param arc_speed = 1.5
param intensity = 0.8

layer dark_base {
  let ny = y / height
  let bg = 0.02 + 0.01 * ny
  blend rgba(0.0, 0.0, bg, 1.0)
}

layer arcs {
  let nx = x / width
  let ny = y / height

  // Three arc tendrils at different horizontal positions using %
  for i in 0..3 {
    let offset = i * 0.333
    let ax = fract(nx + offset)

    // Noise-based displacement creates the jagged arc path
    let n = noise3(ax * 4.0, ny * 6.0, time * arc_speed + i * 2.7)
    let displaced_x = ax + n * 0.15

    // Distance from center of arc tendril
    let dx = abs(displaced_x - 0.5)
    let arc_val = pow(max(1.0 - dx * 8.0, 0.0), 6.0) * intensity

    // Flickering along the arc
    let flicker = noise3(ax * 10.0, ny * 10.0, time * 3.0 + i * 5.0)
    let arc_bright = arc_val * (0.6 + 0.4 * (flicker * 0.5 + 0.5))

    // Hot white core with blue glow
    let r = arc_bright * 0.8
    let g = arc_bright * 0.85
    let b = arc_bright
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), arc_bright)
  }
}

layer glow_pulse {
  let nx = x / width
  let ny = y / height
  let pulse = pow(sin(time * 3.0) * 0.5 + 0.5, 3.0) * 0.15
  let n = noise(nx * 3.0 + time * 0.5, ny * 3.0)
  let glow = pulse * (n * 0.5 + 0.5)
  blend rgba(0.2 * glow, 0.3 * glow, glow, glow)
}

emit
