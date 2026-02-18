# SDF Effect Ideas (Using `src\sdf_common.zig`)

## 1) Soap bubbles (translucent floating spheres with splat end)

### Concept summary
- Multiple bubble layers with different radii drift upward and sideways at different speeds.
- Bubbles can cross in front of and behind each other using alpha layering.
- Each bubble ends with a short "splat/pop ring" event before respawning.

### Motion/lifecycle over time or frames
- Spawn: bubble gets random-ish lane, radius, and rise speed from deterministic per-instance seeds.
- Drift: upward motion with gentle horizontal wobble (`sin` + per-bubble phase).
- Front/back pass: render order can be tied to pseudo-depth phase so bubbles overtake each other.
- End: at lifetime end, scale bubble down quickly while expanding a thin ring "splat" for 2-4 frames.

### SDF building blocks and composition approach
- Bubble body: `sdfCircle(local_p, radius)`.
- Shell look: combine two circles (outer + inner) by subtracting/thresholding distance bands.
- Splat: circle ring via `abs(d_circle) - ring_width` style mask.
- Optional highlight: tiny offset circle unioned onto shell edge.

### Color and alpha/translucency approach
- Base color: cool whites/cyans with low-mid alpha.
- Alpha: strongest on shell edge, weaker in center for glassy look.
- Composite each bubble front-to-back with `ColorRgba.blendOver`.
- Splat ring: brief high-alpha edge, quickly fading to transparent.

### Repetition and pillar wrap-around behavior
- Treat x as periodic (`0..width-1` wrapping); compute shortest wrapped x-distance per bubble center.
- Keep bubbles continuous when crossing seam (`x=29 -> x=0`) so no jump.
- Repeat spawn lanes around circumference, but phase-offset each lane to avoid synchronization.

---

## 2) Campfire (flickering flames rising red/yellow to translucent blue)

### Concept summary
- A grounded flame base produces upward tongues of flickering fire.
- Lower region is denser red/orange/yellow; upper tips cool toward translucent blue.
- Flame shape is turbulent but coherent, with occasional stronger flick bursts.

### Motion/lifecycle over time or frames
- Base heartbeat: intensity pulses at a slow rhythm.
- Rising tongues: vertical drift of noise-modulated flame lobes.
- Flicker: high-frequency small shape jitter layered over low-frequency body motion.
- Burst moments: periodic stronger upward elongation, then return to baseline.

### SDF building blocks and composition approach
- Main body: stacked/overlapping circles blended with `min`/smooth-min style transitions.
- Flame tongues: elongated blobs from transformed local coordinates.
- Base ember region: soft box (`sdfBox`) near bottom blended into flame body.
- Cutouts/noise warping: animate sample coordinates (inverse-domain motion) before SDF evaluation.

### Color and alpha/translucency approach
- Vertical gradient: red/orange at bottom -> yellow mid -> translucent blue near top.
- Alpha decays with height and distance from flame core.
- Use premultiplied-style thinking when layering lobes to avoid muddy color mixing.
- Brief white-hot highlights at the brightest lower-core peaks.

### Repetition and pillar wrap-around behavior
- If campfire occupies full circumference, tile several flame clusters around x with phase offsets.
- Seam safety: evaluate neighbor wrapped clusters near seam to avoid visible cutoff.
- If localized campfire window is desired, fade edges smoothly before wrap boundary.

---

## 3) Aurora ribbons (slow layered light curtains)

### Concept summary
- Broad translucent ribbons flow upward/diagonally like aurora curtains.
- Multiple ribbon layers cross and blend with soft edges and depth-like overlap.
- Motion is calm and continuous, ideal as a low-energy ambient mode.

### Motion/lifecycle over time or frames
- Each ribbon band drifts with different vertical speed and horizontal phase.
- Gentle width breathing over long periods (expand/contract cycles).
- Occasional lateral wave sweeps pass around the pillar.
- No hard reset; layers loop seamlessly via periodic phase.

### SDF building blocks and composition approach
- Ribbon core: distance to animated centerline approximated with transformed coordinates.
- Thickness control: distance band masks using `smoothstep`.
- Layer composition: smooth unions for merged curtains, max/min operations for overlaps.
- Add narrow accent bands by offsetting centerline and using thinner distance bands.

### Color and alpha/translucency approach
- Palette: green/cyan/magenta variants with low to medium alpha.
- Core band brighter; edges feathered by smooth alpha falloff.
- Blend layers front-to-back with `ColorRgba.blendOver` for luminous stacking.
- Occasional desaturated white accents at wave crests.

### Repetition and pillar wrap-around behavior
- Ribbons should be parameterized in wrapped x-space to flow continuously across seam.
- Use periodic phase functions on x to guarantee loop closure.
- For layered bands, offset each layer frequency/phase to prevent seam-aligned artifacts.

---

## 4) Rain + ripple rings (vertical streaks with impact pulses)

### Concept summary
- Thin rain streaks fall from top while occasional impacts generate expanding circular ripples.
- Ripples briefly illuminate nearby drops, creating depth and interaction.
- Effect alternates between light drizzle and denser rain bursts.

### Motion/lifecycle over time or frames
- Drop phase: streak heads descend at varied speeds with short tails.
- Impact phase: when head reaches lower band, spawn ripple ring that expands/fades.
- Burst control: timeline windows increase active drop count, then relax.
- Loop by respawning drops at top with per-lane phase offsets.

### SDF building blocks and composition approach
- Streaks: thin boxes (`sdfBox`) in local drop space, stretched vertically.
- Ripple: circle ring SDF (`abs(sdfCircle(...)) - thickness`) centered at impact point.
- Optional puddle glow: soft circle under impact, blended with ripple.
- Compose rain + ripple via additive alpha layering with clamp.

### Color and alpha/translucency approach
- Drops: cool blue-white, medium alpha at head, lower alpha in tail.
- Ripples: cyan-blue ring with high initial alpha then exponential fade.
- Dark background preserved by keeping total alpha capped and sparse in space.
- Blend with `ColorRgba.blendOver` to keep overlap readable.

### Repetition and pillar wrap-around behavior
- Rain lanes distributed around circumference and wrapped in x.
- Impact ripples must compute wrapped x-distance so rings cross seam correctly.
- Use lane phase offsets so seam columns are not synchronized with center columns.

---

## Additional short prompts (future exploration)
1. Lava lamp blobs with smooth-min merges and slow buoyant swap cycles.
2. Neon tunnel rings moving upward with depth-fade and occasional spin.
3. Jellyfish bells pulsing upward with trailing tentacle lines.
4. Electric arc forks with branching SDF strokes and decay glow.
5. Snow globe flurries with swirl zones and random settling bursts.
6. Plasma checker waves using repeating warped cells and hue cycling.
7. Smoke plumes from bottom vents using soft unioned puff circles.
8. Meteor streaks wrapping around pillar with burn trails and fade.
9. Orbiting satellites with beacon blinks and occlusion-style alpha.
10. Helix DNA strands with paired nodes and rotating crossover rhythm.

## Short implementation notes (`src\sdf_common.zig`)
- Use `FrameContext` (`frame_number`, `frame_rate_hz`, `timeSeconds()`) to keep all timing frame-rate aware and deterministic.
- Build coordinates with `Vec2.init`, then apply reusable transforms via `Vec2.add`, `Vec2.sub`, `Vec2.abs`, and `Vec2.length`-based logic.
- Start primitive masks from `sdfCircle` and `sdfBox`, then shape softness with `linearstep`/`smoothstep`.
- Normalize scalar ranges with `remapLinear` for mapping distance/timeline values into alpha/intensity.
- Represent layered fragments as `ColorRgba` and combine with `ColorRgba.blendOver` / `blendOverRgb`; clamp final output via existing helpers.
- Keep seam-safe behavior by evaluating wrapped x distances before feeding positions into SDF helpers.
