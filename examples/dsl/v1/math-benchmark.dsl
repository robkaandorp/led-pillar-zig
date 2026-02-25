// Math benchmark shader: exercises every DSL math function heavily.
// Purpose: measure per-function cost on ESP32 to identify optimization targets.
// Each layer focuses on a different set of math functions.
effect math_benchmark_v1

frame {
  let t = time * 0.3
  let t2 = time * 0.15
}

// Layer 1: sin, cos (trig functions) — ~9 sin + 9 cos per pixel
layer trig_stress {
  let nx = x / width
  let ny = y / height
  let s1 = sin(nx * 6.28 + t)
  let s2 = sin(ny * 6.28 + t + 1.0)
  let s3 = sin((nx + ny) * 6.28 + t * 1.3)
  let c1 = cos(nx * 6.28 - t)
  let c2 = cos(ny * 6.28 - t + 2.0)
  let c3 = cos((nx - ny) * 6.28 + t * 0.7)
  let s4 = sin(s1 * 3.14 + t2)
  let s5 = sin(s2 * 3.14 + t2 + 1.5)
  let s6 = sin(c1 * 3.14 + t2 + 3.0)
  let c4 = cos(c2 * 3.14 + t2)
  let c5 = cos(s3 * 3.14 + t2 + 1.5)
  let c6 = cos(c3 * 3.14 + t2 + 3.0)
  let r = 0.5 + 0.25 * s4 + 0.25 * c4
  let g = 0.5 + 0.25 * s5 + 0.25 * c5
  let b = 0.5 + 0.25 * s6 + 0.25 * c6
  blend rgba(r, g, b, 0.5)
}

// Layer 2: sqrt, abs, floor, fract — called multiple times per pixel
layer algebraic_stress {
  let nx = x / width
  let ny = y / height
  let d = sqrt(nx * nx + ny * ny)
  let d2 = sqrt((1.0 - nx) * (1.0 - nx) + ny * ny)
  let d3 = sqrt(nx * nx + (1.0 - ny) * (1.0 - ny))
  let a1 = abs(nx - 0.5)
  let a2 = abs(ny - 0.5)
  let a3 = abs(d - 0.5)
  let f1 = floor(nx * 10.0)
  let f2 = floor(ny * 10.0)
  let f3 = floor(d * 8.0)
  let fr1 = fract(nx * 10.0 + t)
  let fr2 = fract(ny * 10.0 + t)
  let fr3 = fract(d * 8.0 + t)
  let r = fr1 * a1 * 2.0
  let g = fr2 * a2 * 2.0
  let b = fr3 * a3 * 2.0
  blend rgba(r, g, b, 0.4)
}

// Layer 3: ln, log — called multiple times per pixel
layer log_stress {
  let nx = x / width
  let ny = y / height
  let safe_nx = max(nx, 0.001)
  let safe_ny = max(ny, 0.001)
  let l1 = ln(safe_nx + 1.0)
  let l2 = ln(safe_ny + 1.0)
  let l3 = ln(safe_nx + safe_ny + 1.0)
  let l4 = log(safe_nx * 9.0 + 1.0)
  let l5 = log(safe_ny * 9.0 + 1.0)
  let l6 = log((safe_nx + safe_ny) * 4.5 + 1.0)
  let r = clamp(l1 + l4, 0.0, 1.0)
  let g = clamp(l2 + l5, 0.0, 1.0)
  let b = clamp(l3 + l6, 0.0, 1.0)
  blend rgba(r * 0.5, g * 0.5, b * 0.5, 0.4)
}

// Layer 4: min, max, clamp, smoothstep — called many times per pixel
layer minmax_smooth_stress {
  let nx = x / width
  let ny = y / height
  let m1 = min(nx, ny)
  let m2 = min(1.0 - nx, 1.0 - ny)
  let m3 = max(nx, ny)
  let m4 = max(1.0 - nx, 1.0 - ny)
  let c1 = clamp(sin(nx * 6.28 + t), 0.0, 1.0)
  let c2 = clamp(sin(ny * 6.28 + t), 0.0, 1.0)
  let c3 = clamp(nx + ny - 0.5, 0.0, 1.0)
  let s1 = smoothstep(0.0, 1.0, nx)
  let s2 = smoothstep(0.0, 1.0, ny)
  let s3 = smoothstep(0.2, 0.8, sin(t + nx * 3.14))
  let s4 = smoothstep(0.3, 0.7, cos(t + ny * 3.14))
  let r = m1 * s1 + m3 * c1
  let g = m2 * s2 + m4 * c2
  let b = s3 * s4 * c3
  blend rgba(r, g, b, 0.4)
}

// Layer 5: SDF (circle, box) + wrapdx — called multiple times per pixel
layer sdf_stress {
  let nx = x / width
  let ny = y / height
  let cx = width * 0.5
  let cy = height * 0.5
  let dx1 = wrapdx(x, cx, width)
  let dx2 = wrapdx(x, cx + sin(t) * 5.0, width)
  let dx3 = wrapdx(x, cx - cos(t) * 5.0, width)
  let c1 = circle(vec2(dx1, y - cy), 8.0)
  let c2 = circle(vec2(dx2, y - cy + 5.0), 6.0)
  let c3 = circle(vec2(dx3, y - cy - 5.0), 4.0)
  let b1 = box(vec2(dx1, y - cy), vec2(6.0, 10.0))
  let b2 = box(vec2(dx2, y - cy + 3.0), vec2(4.0, 8.0))
  let b3 = box(vec2(dx3, y - cy - 3.0), vec2(3.0, 6.0))
  let r = 1.0 - smoothstep(0.0, 2.0, abs(c1))
  let g = 1.0 - smoothstep(0.0, 2.0, abs(c2))
  let b = 1.0 - smoothstep(0.0, 2.0, abs(c3))
  blend rgba(r, g, b, 0.5)
  let r2 = 1.0 - smoothstep(0.0, 1.5, abs(b1))
  let g2 = 1.0 - smoothstep(0.0, 1.5, abs(b2))
  let b2a = 1.0 - smoothstep(0.0, 1.5, abs(b3))
  blend rgba(r2 * 0.5, g2 * 0.5, b2a * 0.5, 0.3)
}

// Layer 6: hash functions — called multiple times per pixel
layer hash_stress {
  let nx = x / width
  let ny = y / height
  let h1 = hash01(floor(x * 3.0) + floor(y * 3.0) * 100.0 + floor(t))
  let h2 = hash01(floor(x * 5.0) + floor(y * 5.0) * 100.0 + floor(t * 2.0))
  let h3 = hash01(floor(x * 7.0) + floor(y * 7.0) * 100.0 + floor(t * 3.0))
  let hs1 = hashSigned(floor(x + t) * 17.0 + y)
  let hs2 = hashSigned(floor(y + t) * 23.0 + x)
  let hc1 = hashCoords01(x, y, floor(t) * 7.0)
  let hc2 = hashCoords01(x + 1.0, y + 1.0, floor(t) * 11.0)
  let hc3 = hashCoords01(x * 2.0, y * 2.0, floor(t) * 13.0)
  let r = h1 * 0.3 + hc1 * 0.3
  let g = h2 * 0.3 + hc2 * 0.3
  let b = h3 * 0.3 + hc3 * 0.3
  blend rgba(r, g, b, 0.15)
}

emit
