// v1 DSL soap-bubbles using frame + for/if control flow.
// This keeps bubbles moving upward with burst windows near the top.
effect soap_bubbles_v1

frame {
  let two_pi = PI * 2.0
  let depth_time = time * 0.75
  let tint_time = time * 0.8
}

layer bubbles {
  for i in 0..14 {
    let id = i
    let phase01 = hash01((id * 13.0) + 5.0)
    let phase = phase01 * two_pi
    let depth_phase = hash01((id * 17.0) + 3.0) * two_pi
    let lane_x = width * hash01((id * 31.0) + 1.0)
    let radius = 1.4 + (hash01((id * 41.0) + 2.0) * 2.4)
    let rise_speed = 5.0 + (hash01((id * 53.0) + 7.0) * 9.0)
    let wobble_amp = 0.2 + (hash01((id * 67.0) + 9.0) * 1.5)
    let wobble_freq = 0.45 + (hash01((id * 79.0) + 4.0) * 1.45)

    let travel = height + (radius * 2.2)
    let cycle = fract((time * (rise_speed / travel)) + phase01)
    let center_x = lane_x + (sin((time * wobble_freq) + phase) * wobble_amp)
    let center_y = (height + radius) - (cycle * travel)
    let local = vec2(wrapdx(x, center_x, width), y - center_y)

    let pop_t = clamp((cycle - 0.9) / 0.1, 0.0, 1.0)
    let pop_gate = smoothstep(0.0, 0.15, pop_t) * (1.0 - smoothstep(0.75, 1.0, pop_t))
    let body_radius = radius * (1.0 - (0.55 * pop_t))

    let d = circle(local, body_radius)
    let shell_alpha = 1.0 - smoothstep(0.05, 0.85, abs(d))
    let core_alpha = (1.0 - smoothstep(-body_radius, 0.0, d)) * 0.12
    let hi_d = circle(vec2(wrapdx(x, center_x, width) + (body_radius * 0.4), (y - center_y) - (body_radius * 0.34)), body_radius * 0.23)
    let hi_alpha = (1.0 - smoothstep(0.0, 0.55, hi_d)) * 0.26

    let depth = sin(depth_time + depth_phase)
    let front_factor = smoothstep(0.0, 0.35, depth)
    let depth_alpha = 0.62 + (0.38 * front_factor)
    let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
    if body_alpha {
      let tint = 0.5 + (0.5 * sin(tint_time + phase))
      blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)
    }

    if pop_gate {
      let ring_radius = body_radius + ((radius + 0.8) * pop_t)
      let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
      let ring_d = abs(circle(local, ring_radius)) - ring_width
      let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
      blend rgba(0.58, 0.88, 1.0, ring_alpha)
    }
  }
}

emit
