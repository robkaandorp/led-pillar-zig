// Tone Pulse: A pulsing visual with synchronized audio tone.
// The brightness pulses at 2 Hz and the audio produces a sine wave
// whose frequency follows the visual intensity.

effect tone_pulse

param base_freq = 220.0
param pulse_rate = 2.0

frame {
    let pulse = clamp(sin(time * pulse_rate * 6.283185) * 0.5 + 0.5, 0.0, 1.0)
    let brightness = pulse * pulse
}

layer glow {
    let hue = fract(time * 0.05 + seed)
    let r = clamp(sin(hue * 6.283185) * 0.5 + 0.5, 0.0, 1.0)
    let g = clamp(sin(hue * 6.283185 + 2.094) * 0.5 + 0.5, 0.0, 1.0)
    let b = clamp(sin(hue * 6.283185 + 4.189) * 0.5 + 0.5, 0.0, 1.0)
    let dist = abs(y / height - 0.5) * 2.0
    let mask = clamp(1.0 - dist, 0.0, 1.0)
    let intensity = brightness * mask
    blend rgba(r * intensity, g * intensity, b * intensity, intensity)
}

emit

audio {
    let pulse = clamp(sin(time * pulse_rate * 6.283185) * 0.5 + 0.5, 0.0, 1.0)
    let freq = base_freq + pulse * base_freq
    let envelope = pulse * pulse * 0.4
    out sin(time * freq * 6.283185) * envelope
}
