// Dream Weaver -- concentric wave sources orbit the pillar and
// their interference creates ever-shifting moire patterns.
//
// Three wave emitters circle at different speeds and heights.  A
// diagonal ripple adds depth.  Sparkle highlights emerge during
// high-energy phases.  Irrational frequencies plus orbital motion
// ensure the visual never settles into a repeating state.
effect dream_weaver_v1

// time bases
param t1 = time * 0.0809
param t2 = time * 0.1311
param t3 = time * 0.1918

// vitality envelope (quiet vs burst)
param vitality = clamp(sin(time * 0.083) + sin(time * 0.059) + sin(time * 0.037) - 1.3, 0.0, 1.0)

// slowly drifting base hue
param hue_base = fract(time * 0.0043)

// wave source orbits (3 sources)
// source 1
param src1_x = width * fract(t1 * 0.8)
param src1_y = height * (0.35 + 0.15 * sin(t2 * 3.0))
// source 2 -- opposite side of pillar
param src2_x = width * fract(t1 * 0.8 + 0.5)
param src2_y = height * (0.65 + 0.15 * cos(t3 * 2.0))
// source 3 -- slower, drifts vertically
param src3_x = width * fract(t2 * 0.5 + 0.25)
param src3_y = height * (0.5 + 0.25 * sin(t3 * 1.4))

// three-source wave interference field
layer waves {
    // distances via wrapdx for seamless pillar wrap
    let dx1 = wrapdx(x, src1_x, width)
    let dy1 = y - src1_y
    let d1 = sqrt(max(dx1 * dx1 + dy1 * dy1, 0.1))
    let w1 = sin(d1 * 0.8 - time * 2.0)

    let dx2 = wrapdx(x, src2_x, width)
    let dy2 = y - src2_y
    let d2 = sqrt(max(dx2 * dx2 + dy2 * dy2, 0.1))
    let w2 = sin(d2 * 0.6 - time * 1.5)

    let dx3 = wrapdx(x, src3_x, width)
    let dy3 = y - src3_y
    let d3 = sqrt(max(dx3 * dx3 + dy3 * dy3, 0.1))
    let w3 = sin(d3 * 0.5 - time * 1.1)

    let interference = (w1 + w2 + w3) * 0.333
    let bright = smoothstep(-0.3, 0.7, interference) * (0.04 + 0.2 * (1.0 - vitality) + 0.5 * vitality)

    // colour derived from hue_base shifted by interference value
    let h = fract(hue_base + interference * 0.25)
    let r = bright * (0.5 + 0.5 * sin(h * TAU))
    let g = bright * (0.5 + 0.5 * sin(h * TAU + TAU / 3.0))
    let b = bright * (0.5 + 0.5 * sin(h * TAU + TAU * 2.0 / 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0)
}

// slow diagonal ripples for depth illusion
layer ripples {
    let angle = t3 * 2.0
    let diag = x * cos(angle) + y * sin(angle)
    let ripple = sin(diag * 0.5 + time * 0.7) * 0.5 + 0.5
    let mask = ripple * (0.03 + 0.18 * vitality)

    let h = fract(hue_base + 0.5 + diag * 0.01)
    let r = mask * (0.5 + 0.5 * sin(h * TAU))
    let g = mask * (0.5 + 0.5 * sin(h * TAU + TAU / 3.0))
    let b = mask * (0.5 + 0.5 * sin(h * TAU + TAU * 2.0 / 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), mask)
}

// highlight sparkles during high vitality
layer sparkles {
    let gx = floor(x * 0.2)
    let gy = floor(y * 0.13)
    let cell_seed = gx * 19.7 + gy * 47.3 + floor(time * 0.8) * 31.1
    let h01 = hash01(cell_seed)
    let sparkle = smoothstep(0.9, 1.0, h01) * vitality

    let sh = fract(hash01(gx * 7.0 + gy * 13.0) + time * 0.02)
    let r = sparkle * (0.5 + 0.5 * sin(sh * TAU))
    let g = sparkle * (0.5 + 0.5 * sin(sh * TAU + TAU / 3.0))
    let b = sparkle * (0.5 + 0.5 * sin(sh * TAU + TAU * 2.0 / 3.0))
    blend rgba(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), sparkle)
}

emit
