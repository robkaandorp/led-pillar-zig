// Continuous A440 sine-wave test tone with a clearly visible status glow.
effect a440_test_tone

layer background {
    let pulse = sin(time * 0.25 * TAU) * 0.5 + 0.5
    let intensity = 0.18 + pulse * 0.22
    blend rgba(intensity, intensity * 0.35, intensity * 0.05, 1.0)
}

layer status_glow {
    let cy = height * 0.5
    let dist = abs(y - cy)
    let band = smoothstep(10.0, 0.0, dist)
    let intensity = band * 0.85
    blend rgba(intensity, intensity * 0.75, intensity * 0.10, intensity)
}

emit

audio {
    let attack = clamp(time / 0.20, 0.0, 1.0)
    out sin(time * 440.0 * TAU) * 0.35 * attack
}
