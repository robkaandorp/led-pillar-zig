// Closest v1 DSL match for the built-in aurora-ribbons effect (default 4 layers).
effect aurora_ribbons_classic_v1

layer layer0 {
  let theta = (x / width) * 6.2831853
  let phase = 0.0
  let speed = 0.28
  let wave = 0.9
  let width_base = 4.2
  let layer_index = 0.0
  let alpha_scale = 0.16 + (layer_index * 0.05)

  let warp = sin((theta * 3.0) + (time * 0.12) + (phase * 0.5)) * (0.22 * wave)
  let flow = sin(theta + (time * speed) + phase + warp)
  let sweep = sin((theta * 2.0) - (time * (0.22 + (speed * 0.15))) + (phase * 0.7) + warp)
  let base = 0.5 + (0.34 * flow) + (0.08 * warp)
  let centerline = ((1.0 - base) * (height - 1.0)) + (sweep * 2.9)

  let breathing = sin((time * 0.35) + phase + (layer_index * 0.4))
  let thickness = width_base + (breathing * 0.9)
  let band_d = box(vec2(0.0, y - centerline), vec2(width, thickness))
  let band_alpha = (1.0 - smoothstep(0.0, 1.9, band_d)) * alpha_scale
  let hue_phase = (time * 0.2) + phase + theta
  blend rgba(
    0.18 + (0.22 * (0.5 + (0.5 * sin(hue_phase + 2.0)))),
    0.42 + (0.46 * (0.5 + (0.5 * sin(hue_phase)))),
    0.46 + (0.42 * (0.5 + (0.5 * sin(hue_phase + 4.0)))),
    band_alpha
  )

  let accent_center = centerline + (sin((theta * 4.0) + (time * 0.55) + phase) * 1.3)
  let accent_d = box(vec2(0.0, y - accent_center), vec2(width, max(0.4, thickness * 0.26)))
  let crest = smoothstep(0.55, 1.0, sin((theta * 2.0) + (time * 0.5) + phase))
  let accent_alpha = (1.0 - smoothstep(0.0, 0.95, accent_d)) * crest * 0.2
  blend rgba(0.88, 0.9, 0.95, accent_alpha)
}

layer layer1 {
  let theta = (x / width) * 6.2831853
  let phase = 1.5
  let speed = 0.34
  let wave = 1.2
  let width_base = 3.8
  let layer_index = 1.0
  let alpha_scale = 0.16 + (layer_index * 0.05)

  let warp = sin((theta * 3.0) + (time * 0.12) + (phase * 0.5)) * (0.22 * wave)
  let flow = sin(theta + (time * speed) + phase + warp)
  let sweep = sin((theta * 2.0) - (time * (0.22 + (speed * 0.15))) + (phase * 0.7) + warp)
  let base = 0.5 + (0.34 * flow) + (0.08 * warp)
  let centerline = ((1.0 - base) * (height - 1.0)) + (sweep * 2.9)

  let breathing = sin((time * 0.35) + phase + (layer_index * 0.4))
  let thickness = width_base + (breathing * 0.9)
  let band_d = box(vec2(0.0, y - centerline), vec2(width, thickness))
  let band_alpha = (1.0 - smoothstep(0.0, 1.9, band_d)) * alpha_scale
  let hue_phase = (time * 0.2) + phase + theta
  blend rgba(
    0.18 + (0.22 * (0.5 + (0.5 * sin(hue_phase + 2.0)))),
    0.42 + (0.46 * (0.5 + (0.5 * sin(hue_phase)))),
    0.46 + (0.42 * (0.5 + (0.5 * sin(hue_phase + 4.0)))),
    band_alpha
  )

  let accent_center = centerline + (sin((theta * 4.0) + (time * 0.55) + phase) * 1.3)
  let accent_d = box(vec2(0.0, y - accent_center), vec2(width, max(0.4, thickness * 0.26)))
  let crest = smoothstep(0.55, 1.0, sin((theta * 2.0) + (time * 0.5) + phase))
  let accent_alpha = (1.0 - smoothstep(0.0, 0.95, accent_d)) * crest * 0.2
  blend rgba(0.88, 0.9, 0.95, accent_alpha)
}

layer layer2 {
  let theta = (x / width) * 6.2831853
  let phase = 2.7
  let speed = 0.22
  let wave = 1.6
  let width_base = 3.2
  let layer_index = 2.0
  let alpha_scale = 0.16 + (layer_index * 0.05)

  let warp = sin((theta * 3.0) + (time * 0.12) + (phase * 0.5)) * (0.22 * wave)
  let flow = sin(theta + (time * speed) + phase + warp)
  let sweep = sin((theta * 2.0) - (time * (0.22 + (speed * 0.15))) + (phase * 0.7) + warp)
  let base = 0.5 + (0.34 * flow) + (0.08 * warp)
  let centerline = ((1.0 - base) * (height - 1.0)) + (sweep * 2.9)

  let breathing = sin((time * 0.35) + phase + (layer_index * 0.4))
  let thickness = width_base + (breathing * 0.9)
  let band_d = box(vec2(0.0, y - centerline), vec2(width, thickness))
  let band_alpha = (1.0 - smoothstep(0.0, 1.9, band_d)) * alpha_scale
  let hue_phase = (time * 0.2) + phase + theta
  blend rgba(
    0.18 + (0.22 * (0.5 + (0.5 * sin(hue_phase + 2.0)))),
    0.42 + (0.46 * (0.5 + (0.5 * sin(hue_phase)))),
    0.46 + (0.42 * (0.5 + (0.5 * sin(hue_phase + 4.0)))),
    band_alpha
  )

  let accent_center = centerline + (sin((theta * 4.0) + (time * 0.55) + phase) * 1.3)
  let accent_d = box(vec2(0.0, y - accent_center), vec2(width, max(0.4, thickness * 0.26)))
  let crest = smoothstep(0.55, 1.0, sin((theta * 2.0) + (time * 0.5) + phase))
  let accent_alpha = (1.0 - smoothstep(0.0, 0.95, accent_d)) * crest * 0.2
  blend rgba(0.88, 0.9, 0.95, accent_alpha)
}

layer layer3 {
  let theta = (x / width) * 6.2831853
  let phase = 4.0
  let speed = 0.3
  let wave = 1.05
  let width_base = 2.9
  let layer_index = 3.0
  let alpha_scale = 0.16 + (layer_index * 0.05)

  let warp = sin((theta * 3.0) + (time * 0.12) + (phase * 0.5)) * (0.22 * wave)
  let flow = sin(theta + (time * speed) + phase + warp)
  let sweep = sin((theta * 2.0) - (time * (0.22 + (speed * 0.15))) + (phase * 0.7) + warp)
  let base = 0.5 + (0.34 * flow) + (0.08 * warp)
  let centerline = ((1.0 - base) * (height - 1.0)) + (sweep * 2.9)

  let breathing = sin((time * 0.35) + phase + (layer_index * 0.4))
  let thickness = width_base + (breathing * 0.9)
  let band_d = box(vec2(0.0, y - centerline), vec2(width, thickness))
  let band_alpha = (1.0 - smoothstep(0.0, 1.9, band_d)) * alpha_scale
  let hue_phase = (time * 0.2) + phase + theta
  blend rgba(
    0.18 + (0.22 * (0.5 + (0.5 * sin(hue_phase + 2.0)))),
    0.42 + (0.46 * (0.5 + (0.5 * sin(hue_phase)))),
    0.46 + (0.42 * (0.5 + (0.5 * sin(hue_phase + 4.0)))),
    band_alpha
  )

  let accent_center = centerline + (sin((theta * 4.0) + (time * 0.55) + phase) * 1.3)
  let accent_d = box(vec2(0.0, y - accent_center), vec2(width, max(0.4, thickness * 0.26)))
  let crest = smoothstep(0.55, 1.0, sin((theta * 2.0) + (time * 0.5) + phase))
  let accent_alpha = (1.0 - smoothstep(0.0, 0.95, accent_d)) * crest * 0.2
  blend rgba(0.88, 0.9, 0.95, accent_alpha)
}

emit
