# SDF Findings (IQ Articles)

Concise notes from Inigo Quilez articles, focused on reusable guidance for this repository's LED effects work.

## Key concepts

### Time and frame animation
- Prefer **inverse-domain animation** (move sample space, not geometry), e.g. `p -= offset(t)` or `uv += time`.
- For repeated instances, add **per-cell/per-instance phase offsets** so motion is less synchronized.
- Use **integer tick timelines** for stable multi-rate behavior (logical clocks for updates, events, transitions).

### SDF composition
- Core booleans: union `min(a,b)`, intersection `max(a,b)`, subtraction `max(a,-b)`.
- Caveat: intersection/subtraction can be bounds for inexact fields; union interior can be wrong if distances are not exact.
- Prefer exact primitive distance functions when possible, then compose.
- For soft blends, use normalized smooth unions (CD-style smooth min family) where `k` controls blend thickness.

### Repetition and seam safety
- Use periodic repetition for tiled motifs.
- Check neighbor cells near boundaries to avoid visible seam artifacts.
- On wrap-around domains, treat seam-adjacent cells as immediate neighbors.

### Opacity and compositing
- Prefer **premultiplied alpha** and compositing form `c + (1-a)d`.
- Premultiplied alpha behaves correctly under filtering/interpolation; straight alpha can produce dark fringes.
- Use **front-to-back compositing** for layered SDF content.

## Mapping to this project (40x30 cylindrical LED matrix)

- Treat logical `x` as periodic with width `30` (cylindrical wrap-around); seam between `x=29` and `x=0` must be artifact-free.
- Keep effects in logical coordinate space; let display mapping handle serpentine physical ordering.
- Use frame-derived integer ticks from configured FPS (target 40 Hz, but configurable) for deterministic animation rates.
- For repeated motifs around the pillar, combine periodic wrapping + neighbor-cell checks + per-cell phase offsets.

## Practical guidance for future effects

1. Start with exact 2D SDF primitives and combine using `min/max` booleans.
2. Animate by transforming sample coordinates (`p`/`uv`) instead of deforming shape definitions directly.
3. For blends, pick smooth union `k` in pixel-scale terms and test seam behavior at wrap boundary.
4. When layering fields, use premultiplied-alpha front-to-back composition math.
5. Validate visually in simulator with explicit seam tests (objects crossing `x=29 -> 0`).
6. Prefer single-pass per-pixel frame rendering (visit each pixel once, evaluate all contributors per pixel) to avoid repeated full-frame scans.

## IQ article links

- Distance functions: https://iquilezles.org/articles/distfunctions/
- Distance functions 2D: https://iquilezles.org/articles/distfunctions2d/
- Smooth minimum (`smin`): https://iquilezles.org/articles/smin/
- SDF repetition: https://iquilezles.org/articles/sdfrepetition/
- Interior distance: https://iquilezles.org/articles/interiordistance/
- SDF xor: https://iquilezles.org/articles/sdfxor/
- Premultiplied alpha: https://iquilezles.org/articles/premultipliedalpha/
- Ticks/timelines: https://iquilezles.org/articles/ticks/
- Deform: https://iquilezles.org/articles/deform/
- Raymarching distance fields: https://iquilezles.org/articles/raymarchingdf/
