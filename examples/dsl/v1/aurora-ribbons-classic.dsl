// Refactored classic aurora-ribbons profile using frame + for constructs.
// Keeps the original 4-layer parameter set while reducing duplicated code.
effect aurora_ribbons_classic_v1

frame {
  let t_warp = time * 0.12
  let t_hue = time * 0.2
  let t_breathe = time * 0.35
  let t_crest = time * 0.5
  let t_accent = time * 0.55
}

layer ribbons {
  let theta = (x / width) * TAU

  for i in 0..4 {
    let layer_index = i

    // One-hot selectors for the 4 classic layer presets.
    let w0 = clamp(1.0 - abs(layer_index - 0.0), 0.0, 1.0)
    let w1 = clamp(1.0 - abs(layer_index - 1.0), 0.0, 1.0)
    let w2 = clamp(1.0 - abs(layer_index - 2.0), 0.0, 1.0)
    let w3 = clamp(1.0 - abs(layer_index - 3.0), 0.0, 1.0)

    let phase = (0.0 * w0) + (1.5 * w1) + (2.7 * w2) + (4.0 * w3)
    let speed = (0.28 * w0) + (0.34 * w1) + (0.22 * w2) + (0.3 * w3)
    let wave = (0.9 * w0) + (1.2 * w1) + (1.6 * w2) + (1.05 * w3)
    let width_base = (4.2 * w0) + (3.8 * w1) + (3.2 * w2) + (2.9 * w3)
    let alpha_scale = 0.16 + (layer_index * 0.05)

    let warp = sin((theta * 3.0) + t_warp + (phase * 0.5)) * (0.22 * wave)
    let flow = sin(theta + (time * speed) + phase + warp)
    let sweep = sin((theta * 2.0) - (time * (0.22 + (speed * 0.15))) + (phase * 0.7) + warp)
    let base = 0.5 + (0.34 * flow) + (0.08 * warp)
    let centerline = ((1.0 - base) * (height - 1.0)) + (sweep * 2.9)

    let breathing = sin(t_breathe + phase + (layer_index * 0.4))
    let thickness = width_base + (breathing * 0.9)
    let band_d = box(vec2(0.0, y - centerline), vec2(width, thickness))
    let band_alpha = (1.0 - smoothstep(0.0, 1.9, band_d)) * alpha_scale
    let hue_phase = t_hue + phase + theta
    blend rgba(
      0.18 + (0.22 * (0.5 + (0.5 * sin(hue_phase + 2.0)))),
      0.42 + (0.46 * (0.5 + (0.5 * sin(hue_phase)))),
      0.46 + (0.42 * (0.5 + (0.5 * sin(hue_phase + 4.0)))),
      band_alpha
    )

    let accent_center = centerline + (sin((theta * 4.0) + t_accent + phase) * 1.3)
    let accent_d = box(vec2(0.0, y - accent_center), vec2(width, max(0.4, thickness * 0.26)))
    let crest = smoothstep(0.55, 1.0, sin((theta * 2.0) + t_crest + phase))
    let accent_alpha = (1.0 - smoothstep(0.0, 0.95, accent_d)) * crest * 0.2
    blend rgba(0.88, 0.9, 0.95, accent_alpha)
  }
}

emit
