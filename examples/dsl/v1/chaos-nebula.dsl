// Chaos Nebula -- shifting gas clouds with twinkling sparks.
//
// Uses mutually irrational frequency ratios so the combined pattern
// never exactly repeats.  A compound-sine energy envelope drives
// quiet phases (dim, slow nebula drift) and burst phases (vivid
// flowing gas + sparks).  The pillar wrap is exploited via wrapdx.
effect chaos_nebula_v1

// time bases with mutually irrational ratios
param t_slow = time * 0.0618
param t_med  = time * 0.1732
param t_fast = time * 0.2896

// energy envelope (quiet vs burst)
// Three incommensurable frequencies produce an aperiodic intensity.
// energy is near 0 most of the time (quiet), occasionally peaks to 1.
param energy = clamp(sin(time * 0.11) + sin(time * 0.077) + sin(time * 0.053) - 1.5, 0.0, 1.0)

// gentle minimum brightness so the display is never completely dark
param base = 0.025 + 0.015 * sin(time * 0.029)

// spatial helpers
param cx  = width * 0.5
param cy  = height * 0.5
param scx = TAU / width
param scy = TAU / height

// deep nebula background, always visible, breathes slowly
layer nebula {
    let dx = wrapdx(x, cx + sin(t_slow * 3.7) * width * 0.25, width)
    let dy = y - cy + cos(t_slow * 2.3) * height * 0.15
    let field1 = sin(dx * scx * 2.0 + t_slow * 4.0) * cos(dy * scy * 1.5 + t_slow * 3.0)
    let field2 = cos(dx * scx * 1.3 - t_med * 2.5) * sin(dy * scy * 2.2 + t_med * 1.8)
    let glow = smoothstep(-0.2, 0.6, field1 + field2 * 0.5) * (base + 0.15 + 0.35 * energy)

    // warm-cool nebula palette drifts over time
    let r = glow * (0.55 + 0.45 * sin(t_slow * 1.9))
    let g = glow * (0.25 + 0.35 * sin(t_slow * 2.7 + 2.0))
    let b = glow * (0.45 + 0.45 * cos(t_slow * 1.4 + 1.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0)
}

// flowing gas streams, grow brighter with energy
layer streams {
    let drift = t_med * 5.0 + y * scy * 3.0
    let wx = wrapdx(x, width * (0.3 + 0.2 * sin(t_fast * 1.6)), width)
    let stream = sin(wx * scx * 3.5 + drift) * cos(wx * scx * 1.8 - t_fast * 3.0)
    let mask = smoothstep(0.25, 0.85, stream) * (0.08 + 0.7 * energy)

    let r = mask * (0.2 + 0.5 * sin(t_fast * 2.3 + 1.0))
    let g = mask * (0.5 + 0.4 * cos(t_med * 3.1))
    let b = mask * (0.7 + 0.3 * sin(t_slow * 5.0 + 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), mask)
}

// bright sparks, appear mostly during bursts
layer sparks {
    let cell_x = floor(x * 0.2)
    let cell_y = floor(y * 0.15)
    let seed = cell_x * 17.31 + cell_y * 43.17 + floor(time * 1.5) * 7.13
    let brightness = hash01(seed)
    let spark = smoothstep(0.88, 1.0, brightness) * (0.15 + 0.85 * energy)

    // hue rotates slowly, every spark gets its own color family
    let hue = fract(hash01(cell_x * 13.0 + cell_y * 29.0) + time * 0.03)
    let r = spark * (0.5 + 0.5 * sin(hue * TAU))
    let g = spark * (0.5 + 0.5 * sin(hue * TAU + TAU / 3.0))
    let b = spark * (0.5 + 0.5 * sin(hue * TAU + TAU * 2.0 / 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), spark)
}

emit
