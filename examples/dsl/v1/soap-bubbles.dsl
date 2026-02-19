// v1 DSL approximation of the built-in soap-bubbles effect.
// Updated to better match the native look:
// - More bubbles (14 lanes)
// - Upward-only motion using fract() cycles
// - Burst window near top with expanding pop rings

effect soap_bubbles_v1
layer bubble_0 {
  let id = 0.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_1 {
  let id = 1.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_2 {
  let id = 2.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_3 {
  let id = 3.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_4 {
  let id = 4.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_5 {
  let id = 5.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_6 {
  let id = 6.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_7 {
  let id = 7.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_8 {
  let id = 8.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_9 {
  let id = 9.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_10 {
  let id = 10.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_11 {
  let id = 11.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_12 {
  let id = 12.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
layer bubble_13 {
  let id = 13.0
  let phase01 = hash01((id * 13.0) + 5.0)
  let phase = phase01 * 6.2831853
  let depth_phase = hash01((id * 17.0) + 3.0) * 6.2831853
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

  let depth = sin((time * 0.75) + depth_phase)
  let front_factor = smoothstep(0.0, 0.35, depth)
  let depth_alpha = 0.62 + (0.38 * front_factor)
  let body_alpha = min(((shell_alpha * 0.46) + core_alpha + hi_alpha) * (1.0 - (0.92 * pop_t)) * depth_alpha, 0.86)
  let tint = 0.5 + (0.5 * sin((time * 0.8) + phase))
  blend rgba(min(0.66 + (0.2 * tint), 1.0), min(0.82 + (0.12 * tint), 1.0), 1.0, body_alpha)

  let ring_radius = body_radius + ((radius + 0.8) * pop_t)
  let ring_width = 0.12 + ((1.0 - pop_t) * 0.18)
  let ring_d = abs(circle(local, ring_radius)) - ring_width
  let ring_alpha = (1.0 - smoothstep(0.0, 0.65, ring_d)) * pop_gate * 0.9 * depth_alpha
  blend rgba(0.58, 0.88, 1.0, ring_alpha)
}
emit