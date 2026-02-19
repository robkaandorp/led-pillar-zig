effect rain_ripple_v1
param lane_x = 8.0
param drop_y = (height * 0.5) + (sin(time * 1.7) * (height * 0.45))
param ripple_y = height - 2.0
param ripple_r = 1.2 + ((sin(time * 4.5) + 1.0) * 3.5)

layer drop {
  let lane_jitter = hashSigned(frame + 17.0) * 0.45
  let dx = wrapdx(x, lane_x + lane_jitter, width)
  let streak = box(vec2(dx, y - (drop_y - 1.2)), vec2(0.18, 1.2))
  let head = circle(vec2(dx, y - drop_y), 0.4)
  let a = ((1.0 - smoothstep(0.0, 0.75, streak)) * 0.36) + ((1.0 - smoothstep(0.0, 0.55, head)) * 0.48)
  blend rgba(0.70, 0.84, 1.0, min(a, 0.9))
}

layer ripple {
  let local = vec2(wrapdx(x, lane_x, width), y - ripple_y)
  let ring = abs(circle(local, ripple_r)) - 0.2
  let a = (1.0 - smoothstep(0.0, 0.8, ring)) * 0.6
  blend rgba(0.35, 0.78, 1.0, a)
}

emit
