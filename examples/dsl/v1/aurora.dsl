effect aurora_v1
param speed = 0.28
param thickness = 3.8
param alpha_scale = 0.45

layer ribbon {
  let theta = (x / width) * TAU
  let center = (height * 0.5) + (sin(theta + (time * speed)) * 6.0)
  let d = box(vec2(0.0, y - center), vec2(width, thickness))
  let a = (1.0 - smoothstep(0.0, 1.9, d)) * alpha_scale
  blend rgba(0.35, 0.95, 0.75, min(a, 1.0))
}

emit
