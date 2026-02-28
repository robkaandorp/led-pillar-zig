// Ocean Waves — layered noise-driven water on a cylindrical display.
// Multiple noise octaves at different scales and speeds create
// organic wave undulation with a blue-green color palette.
effect ocean_waves

param speed = 0.4
param scale1 = 0.15
param scale2 = 0.08
param scale3 = 0.22

layer deep_water {
  let nx = x * scale1
  let ny = y * scale1
  let n = noise(nx + time * speed * 0.6, ny + time * speed * 0.3)
  let val = n * 0.5 + 0.5
  let dark = val * 0.35
  blend rgba(0.0, dark * 0.6, dark, 1.0)
}

layer mid_waves {
  let nx = x * scale2
  let ny = y * scale2
  let n = noise(nx + time * speed, ny - time * speed * 0.5)
  let val = n * 0.5 + 0.5
  let bright = pow(val, 1.5) * 0.55
  let a = smoothstep(0.15, 0.5, bright)
  blend rgba(0.05, bright * 0.8, bright, a)
}

layer surface_foam {
  let nx = x * scale3
  let ny = y * scale3
  let n = noise(nx - time * speed * 1.2, ny + time * speed * 0.7)
  let foam = pow(n * 0.5 + 0.5, 3.0)
  let crest = smoothstep(0.3, 0.6, foam)
  blend rgba(0.7 * crest, 0.95 * crest, 1.0 * crest, crest * 0.7)
}

emit
