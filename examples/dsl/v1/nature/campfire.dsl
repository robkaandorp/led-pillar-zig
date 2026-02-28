effect campfire_v1
param pulse = 0.9
param tongue_x = 14.0
param tongue_y = 28.0
param tongue_r = 2.3

layer embers {
  let d = box(vec2(wrapdx(x, width * 0.5, width), y - (height - 1.4)), vec2(2.0, 1.1))
  let a = (1.0 - smoothstep(-0.1, 1.25, d)) * 0.55
  blend rgba(0.95, 0.45, 0.08, a)
}

layer tongue {
  let sway = sin((time * 5.8) + (y * 0.08)) * (0.45 + (0.55 * smoothstep(0.6, 0.95, (sin(time * pulse) + 1.0) * 0.5)))
  let d = circle(vec2(wrapdx(x, tongue_x + sway, width), y - tongue_y), tongue_r)
  let body = 1.0 - smoothstep(0.0, 1.45, d)
  blend rgba(1.0, 0.78, 0.25, body * 0.7)
}

emit
