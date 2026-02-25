// Primal Storm -- raw elemental energy wrapping around the pillar.
//
// Rolling auroral glow, scrolling energy bands, hash-based lightning
// bolts, and rising ember particles.  Storm intensity modulates
// everything: quiet lulls give way to violent bursts.  Irrational
// frequencies guarantee the pattern never repeats.
effect primal_storm_v1

// time bases, offset by seed for unique starts
param t1 = time * 0.0732 + seed * 100.0
param t2 = time * 0.1414 + seed * 200.0
param t3 = time * 0.2236 + seed * 300.0

// storm intensity envelope
param storm = clamp(sin(time * 0.097 + seed * 60.0) + sin(time * 0.067 + seed * 80.0) + sin(time * 0.041 + seed * 40.0) - 1.4, 0.0, 1.0)

// movement speed scales with storm
param speed = 0.5 + 2.0 * storm

// slow colour epoch shifts the entire palette over minutes
param epoch = fract(time * 0.0051)

param scx = TAU / width
param scy = TAU / height

// ambient auroral glow along the vertical centre
layer glow {
    let cy = height * (0.5 + 0.1 * sin(t1 * 2.7))
    let dy = abs(y - cy) / height
    let g_val = smoothstep(0.45, 0.0, dy) * (0.03 + 0.18 * (1.0 - storm) + 0.3 * storm)

    let h = fract(epoch + dy * 0.3 + 0.1 * sin(t1 * 1.5))
    let r = g_val * (0.5 + 0.5 * sin(h * TAU))
    let g = g_val * (0.5 + 0.5 * sin(h * TAU + TAU / 3.0))
    let b = g_val * (0.5 + 0.5 * sin(h * TAU + TAU * 2.0 / 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0)
}

// horizontal energy bands scrolling upward
layer bands {
    let scroll = y * scy * 4.0 + time * speed
    let wave = sin(scroll) * cos(scroll * 0.7 + x * scx * 2.0 + t2 * 3.0)
    let mask = smoothstep(0.2, 0.9, wave) * (0.04 + 0.55 * storm)

    // electric cyan to magenta spectrum
    let mix_v = sin(t3 * 3.0 + y * scy) * 0.5 + 0.5
    let r = mask * (0.3 + 0.6 * mix_v)
    let g = mask * (0.6 - 0.3 * mix_v)
    let b = mask * 0.9
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), mask)
}

// lightning bolts (hash-based column strikes)
layer lightning {
    let col = floor(x * 0.5)
    let t_slice = floor(time * 4.0)
    let chance = hash01(col * 13.7 + t_slice * 71.3)
    let strike = smoothstep(0.93, 1.0, chance) * storm

    let bolt_y = hash01(col * 29.1 + t_slice * 53.7) * height
    let bolt_spread = smoothstep(0.35, 0.0, abs(y - bolt_y) / height)
    let bolt = strike * bolt_spread

    // hot white core with blue fringe
    let r = bolt * (0.7 + 0.3 * bolt_spread)
    let g = bolt * (0.8 + 0.2 * bolt_spread)
    let b = bolt
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), bolt)
}

// rising ember particles during storm
layer embers {
    let px = floor(x * 0.25)
    let stripe_seed = hash01(px * 37.1)
    let rise_speed = 0.5 + stripe_seed * 1.5
    let py = fract(stripe_seed * 10.0 - time * rise_speed * 0.05)
    let ember_y = py * height
    let dy = abs(y - ember_y) / height
    let ember = smoothstep(0.06, 0.0, dy) * storm * hash01(px * 53.0 + floor(time * 0.3) * 17.0)

    let r = ember * 1.0
    let g = ember * (0.4 + 0.3 * stripe_seed)
    let b = ember * 0.1
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), ember)
}

emit
