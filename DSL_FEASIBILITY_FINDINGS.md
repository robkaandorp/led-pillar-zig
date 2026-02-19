# DSL Feasibility Findings for SDF Effects

## Goal
Create a short, readable, extensible text format that can describe SDF-based effects, load them from the CLI, and eventually execute them on-device (ESP32) to avoid streaming every frame over TCP.

## Feasibility Verdict
**Feasible.** The current rendering architecture already has the right shape for a DSL runtime:
- Per-frame context with deterministic timing (`src\sdf_common.zig`: `FrameContext`)
- Reusable SDF/math helpers (`sdfCircle`, `sdfBox`, `smoothstep`, `remapLinear`, `Vec2`)
- Single-pass per-pixel renderer (`renderColorFrameSinglePass` in `src\effects.zig`)
- Existing blend path (`blendColor`) and output path (`blitColorFrame` -> TCP send)

The main missing piece is a parser + evaluator/interpreter layer between a text file and the existing render pipeline.

## Recommended v1 DSL Shape
Keep v1 small and strict:

- Top-level blocks: `effect`, `param`, `layer`, `emit`
- Statements: `let`, `blend`, `color`
- Expressions: scalar math, `vec2`, and a small builtin set
- Builtins: `sin`, `cos`, `abs`, `min`, `max`, `smoothstep`, `circle`, `box`, `wrapdx`, `hash01`, `hashSigned`, `hashCoords01`
- Inputs: `time`, `frame`, `x`, `y`, `width`, `height`

### Why this shape
- Short and readable for artists/engineers
- Maps directly to current code patterns
- Easy to extend by adding builtins and statement handlers
- Easy to constrain for deterministic performance

## Extensibility Model
Use a builtin registry in code:
- `name -> arity -> type rules -> evaluator function`
- Additions are additive (new primitive, new op, new statement)
- Version and capability flags in file header (example: `dsl_version = 1`)

This avoids rewriting parser logic every time a new primitive is added.

### Deterministic randomness helpers
Use hash-noise helpers instead of mutable RNG state:
- `hash01(n)`: deterministic float in `[0,1]`
- `hashSigned(n)`: deterministic float in `[-1,1]`
- `hashCoords01(x, y, seed)`: deterministic spatial noise (stable per coordinate)

These are deterministic across runs and suitable for both desktop and future ESP32 execution.

## CLI Integration (Proposed)
Add a new effect kind in `src\main.zig`, for example: `dsl-file`.

Proposed command:
```txt
zig build run -- <host> [port] [frame_rate_hz] dsl-file <path-to-effect.dsl>
```

Runtime flow:
1. Parse file once at startup
2. Build AST/IR (or bytecode)
3. Execute per-frame/per-pixel through the existing single-pass renderer
4. Reuse current display encode/send path

## ESP32 Migration Strategy (Recommended)
Recommended sequence:
1. **Desktop first:** parser + interpreter in this repo
2. **Then bytecode:** compile DSL to compact validated bytecode
3. **On ESP32:** execute bytecode VM with deterministic limits

Why bytecode over text parsing on ESP32:
- Lower memory pressure
- Faster startup and execution
- Safer validation before deploy
- Shared semantics with desktop runtime

## Risks and Guardrails
- Risk: unbounded expressions cause frame drops  
  - Guardrail: cap ops per pixel/layer count/primitive count
- Risk: seam artifacts on wrapped display  
  - Guardrail: provide `wrapdx` helper and seam tests
- Risk: cross-platform numeric drift  
  - Guardrail: deterministic math subset and golden-frame tests
- Risk: DSL complexity creep  
  - Guardrail: strict v1 scope and versioned feature gates

## DSL Examples

### 1) Aurora-style ribbons
```txt
effect aurora_v1
param speed = 0.28
param thickness = 3.8
param alpha_scale = 0.45

layer ribbon {
  let theta = (x / width) * 6.2831853
  let center = (height * 0.5) + sin(theta + time * speed) * 6.0
  let d = box(vec2(0.0, y - center), vec2(width, thickness))
  let a = (1.0 - smoothstep(0.0, 1.9, d)) * alpha_scale
  blend rgba(0.35, 0.95, 0.75, a)
}

emit
```

### 2) Campfire-style base glow + tongue
```txt
effect campfire_v1
param pulse = 0.9
param tongue_x = 14.0
param tongue_y = 28.0
param tongue_r = 2.3

layer embers {
  let d = box(vec2(wrapdx(x, width * 0.5, width), y - (height - 1.4)), vec2(2.0, 1.1))
  let a = (1.0 - smoothstep(-0.1, 1.25, d)) * 0.55
  blend rgba(0.95, 0.45, 0.08, a)
}

layer tongue {
  let sway = sin(time * 5.8 + y * 0.08) * (0.45 + 0.55 * smoothstep(0.6, 0.95, (sin(time * pulse) + 1.0) * 0.5))
  let d = circle(vec2(wrapdx(x, tongue_x + sway, width), y - tongue_y), tongue_r)
  let body = 1.0 - smoothstep(0.0, 1.45, d)
  blend rgba(1.0, 0.78, 0.25, body * 0.7)
}

emit
```

### 3) Rain streak + ripple ring
```txt
effect rain_ripple_v1
param lane_x = 8.0
param drop_y = mod(time * 16.0, height)
param ripple_y = height - 2.0
param ripple_r = mod(time * 4.5, 8.0)

layer drop {
  let lane_jitter = hashSigned(frame + 17) * 0.45
  let dx = wrapdx(x, lane_x + lane_jitter, width)
  let streak = box(vec2(dx, y - (drop_y - 1.2)), vec2(0.18, 1.2))
  let head = circle(vec2(dx, y - drop_y), 0.4)
  let a = (1.0 - smoothstep(0.0, 0.75, streak)) * 0.36 + (1.0 - smoothstep(0.0, 0.55, head)) * 0.48
  blend rgba(0.70, 0.84, 1.0, min(a, 0.9))
}

layer ripple {
  let local = vec2(wrapdx(x, lane_x, width), y - ripple_y)
  let ring = abs(circle(local, ripple_r)) - 0.2
  let a = (1.0 - smoothstep(0.0, 0.8, ring)) * 0.6
  blend rgba(0.35, 0.78, 1.0, a)
}

emit
```

## Suggested Implementation Phases
1. Define grammar + parser + validator (v1 subset)
2. Build AST/IR evaluator mapped to existing single-pass renderer
3. Add CLI `dsl-file` entrypoint in `main.zig`
4. Add simulator-based golden tests for seam behavior and stability
5. Introduce portable bytecode format for future ESP32 runtime
