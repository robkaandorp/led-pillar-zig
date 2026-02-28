// Heartbeat Pulse — rhythmic visual pulse expanding from center
// with audio that mimics a heartbeat (double thump pattern).
effect heartbeat_pulse

param bpm = 72.0

frame {
  // Heartbeat has a double-beat pattern: lub-dub
  let beat_period = 60.0 / bpm
  let phase = fract(time / beat_period)

  // First beat (lub) at phase 0, second (dub) at phase 0.2
  let lub = pow(max(1.0 - phase * 8.0, 0.0), 3.0)
  let dub_phase = max(phase - 0.2, 0.0)
  let dub = pow(max(1.0 - dub_phase * 10.0, 0.0), 3.0)
  let beat = lub + dub * 0.7
}

layer pulse_ring {
  let cx = width * 0.5
  let cy = height * 0.5
  let dx = wrapdx(x, cx, width)
  let dy = y - cy
  let dist = sqrt(dx * dx + dy * dy)
  let max_r = height * 0.5

  // Ring expands outward on each beat
  let ring_pos = beat * max_r
  let ring_dist = abs(dist - ring_pos)
  let ring = smoothstep(2.5, 0.0, ring_dist) * beat

  // Deep red pulse
  let r = ring * 0.9
  let g = ring * 0.1
  let b = ring * 0.15
  blend rgba(clamp(r, 0.0, 1.0), g, b, ring)
}

layer core_glow {
  let cx = width * 0.5
  let cy = height * 0.5
  let dx = wrapdx(x, cx, width)
  let dy = y - cy
  let dist = sqrt(dx * dx + dy * dy)

  let glow = pow(max(1.0 - dist / 8.0, 0.0), 2.0) * (0.15 + 0.85 * beat)
  let r = glow * 1.0
  let g = glow * 0.2
  let b = glow * 0.25
  blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), glow)
}

emit

audio {
  let beat_period = 60.0 / bpm
  let phase = fract(time / beat_period)

  // Lub: low thump
  let lub_env = pow(max(1.0 - phase * 8.0, 0.0), 3.0)
  let lub = sin(time * 55.0 * TAU) * lub_env * 0.5

  // Dub: slightly higher, slightly softer
  let dub_phase = max(phase - 0.2, 0.0)
  let dub_env = pow(max(1.0 - dub_phase * 10.0, 0.0), 3.0)
  let dub = sin(time * 70.0 * TAU) * dub_env * 0.35

  out clamp(lub + dub, -1.0, 1.0)
}
