# DSL v1 Language Spec

This document defines the currently implemented DSL parser syntax in `src\dsl_parser.zig`.

## Scope

- Covers parser + static validation rules.
- Covers expression typing and supported builtins.
- Covers practical CLI usage for validating DSL files in this repository.
- ESP32 execution/runtime details are out of scope for v1.

## File structure

A valid DSL program must include:

1. One `effect` declaration
2. Zero or more `param` declarations
3. One or more `layer` blocks
4. One `emit` statement

Top-level statement order is flexible, but all required parts must exist exactly once where required.

## Grammar (v1)

```ebnf
program        = top_level* EOF ;
top_level      = effect_decl | param_decl | frame_decl | layer_decl | emit_stmt ;

effect_decl    = "effect" IDENT ;
param_decl     = "param" IDENT "=" expr ;
frame_decl     = "frame" "{" stmt* "}" ;
layer_decl     = "layer" IDENT "{" layer_stmt* "}" ;
emit_stmt      = "emit" ;

stmt           = let_decl | if_stmt | for_stmt ;
layer_stmt     = stmt | blend_stmt ;
let_decl       = "let" IDENT "=" expr ;
if_stmt        = "if" expr "{" layer_stmt* "}" [ "else" "{" layer_stmt* "}" ] ;
for_stmt       = "for" IDENT "in" INTEGER ".." INTEGER "{" layer_stmt* "}" ;
blend_stmt     = "blend" expr ;

expr           = additive ;
additive       = multiplicative (("+" | "-") multiplicative)* ;
multiplicative = unary (("*" | "/") unary)* ;
unary          = "-" unary | primary ;
primary        = NUMBER | IDENT | call | "(" expr ")" ;
call           = IDENT "(" [expr ("," expr)*] ")" ;
```

## Tokens and identifiers

- Numbers: decimal numeric literals (for example `1`, `0.5`, `42.0`)
- Identifiers: `[A-Za-z_][A-Za-z0-9_]*`
- Comments: `//` to end of line
- Whitespace/newlines are ignored between tokens

## Params

`param` creates a named scalar expression at top level:

`param <name> = <expr>`

How params are used in v1:
- Params are shared scalar values that can be referenced from `frame` and `layer` blocks.
- Params are useful for tuning values (`speed`, `radius`, `intensity`) in one place.
- Param expressions can use builtin functions, builtin constants, and input identifiers (`time`, `frame`, `width`, `height`, and also `x`/`y`).
- A param can reference earlier params, but not later params.
- At runtime, params are evaluated before layer blending; params that depend on `x`/`y` are evaluated per pixel, others are evaluated once per frame.

Example:

```dsl
effect pulse
param speed = 0.7
param phase = sin(time * speed)

layer l {
  let alpha = (phase * 0.5) + 0.5
  blend rgba(1.0, 0.2, 0.2, alpha)
}
emit
```

## Builtin functions and types

Types:
- `scalar`: floating-point number (`f32`)
- `vec2`: 2D vector (`x`, `y`)
- `rgba`: color (`r`, `g`, `b`, `a`)

Builtins:

| Builtin | Signature | Returns | What it does |
|---|---|---|---|
| `sin` | `sin(scalar)` | `scalar` | Sine of angle/radian input. |
| `cos` | `cos(scalar)` | `scalar` | Cosine of angle/radian input. |
| `sqrt` | `sqrt(scalar)` | `scalar` | Square root. |
| `ln` | `ln(scalar)` | `scalar` | Natural logarithm (base `e`). |
| `log` | `log(scalar)` | `scalar` | Base-10 logarithm. |
| `abs` | `abs(scalar)` | `scalar` | Absolute value. |
| `floor` | `floor(scalar)` | `scalar` | Largest integer not greater than input. |
| `fract` | `fract(scalar)` | `scalar` | Fractional part (`x - floor(x)`). |
| `min` | `min(scalar, scalar)` | `scalar` | Smaller of two values. |
| `max` | `max(scalar, scalar)` | `scalar` | Larger of two values. |
| `clamp` | `clamp(scalar, scalar, scalar)` | `scalar` | Constrains value into `[min, max]`. |
| `smoothstep` | `smoothstep(scalar, scalar, scalar)` | `scalar` | Smooth transition from 0 to 1 between edges. |
| `circle` | `circle(vec2, scalar)` | `scalar` | Signed distance to a circle (negative inside). |
| `box` | `box(vec2, vec2)` | `scalar` | Signed distance to an axis-aligned box (negative inside). |
| `wrapdx` | `wrapdx(scalar, scalar, scalar)` | `scalar` | Shortest wrapped X-distance on pillar width. |
| `hash01` | `hash01(scalar)` | `scalar` | Deterministic pseudo-random value in `[0, 1]` from one seed. |
| `hashSigned` | `hashSigned(scalar)` | `scalar` | Deterministic pseudo-random value in `[-1, 1]` from one seed. |
| `hashCoords01` | `hashCoords01(scalar, scalar, scalar)` | `scalar` | Deterministic pseudo-random value in `[0, 1]` from `x`, `y`, and seed. |
| `vec2` | `vec2(scalar, scalar)` | `vec2` | Constructs a 2D vector. |
| `rgba` | `rgba(scalar, scalar, scalar, scalar)` | `rgba` | Constructs an RGBA color. |

Builtin constants:

| Constant | Type | Value | What it does |
|---|---|---|---|
| `PI` | `scalar` | `3.1415927` | Circle half-turn constant. Useful for trig and angle math. |
| `TAU` | `scalar` | `6.2831855` (`2 * PI`) | Full-turn constant. Useful for normalized 0..1 angle mapping. |

Available input identifiers:
- `time`: elapsed seconds since effect start
- `frame`: current frame number as scalar
- `x`, `y`: current pixel coordinates
- `width`, `height`: display dimensions

## Quick examples

1) **Pulse alpha with params + trig**

```dsl
param speed = 1.0
param angle = (time * speed) * TAU
param pulse = (sin(angle) * 0.5) + 0.5
```

2) **Normalize and clamp a horizontal gradient**

```dsl
let u = clamp(x / width, 0.0, 1.0)
blend rgba(u, 0.0, 1.0 - u, 1.0)
```

3) **Simple circular mask around display center**

```dsl
let p = vec2(wrapdx(x, width * 0.5, width), y - (height * 0.5))
let d = circle(p, 6.0)
let a = 1.0 - smoothstep(0.0, 1.5, abs(d))
blend rgba(0.2, 0.8, 1.0, a)
```

## Semantics (v1 parser model)

- `param` expressions must type-check to `scalar`.
- `frame` block is optional and runs once per frame before pixel shading.
- `let` binds a typed expression in the current scope.
- `for` uses an integer range and the loop index is a scalar identifier.
- `if` condition must type-check to `scalar` (`> 0` is treated as true at runtime).
- `blend` expression must type-check to `rgba`.
- Arithmetic operators (`+`, `-`, `*`, `/`) are scalar-only.
- Unary `-` is scalar-only.
- Function calls must match known builtin name, arity, and argument types exactly.
- `for` loops are compiled as loop statements and executed at runtime (not unrolled into per-iteration copies).

## Runtime bytecode model (host, current)

The Zig runtime now compiles DSL expressions to a stack-based bytecode form before evaluation.

- Expression instructions currently cover:
  - literal/slot loads (`param`, `frame let`, `layer let`, input slots)
  - scalar arithmetic ops (`negate`, `add`, `sub`, `mul`, `div`)
  - builtin calls (`sin`, `cos`, `sqrt`, `ln`, `log`, SDF/hash/color/vector builtins)
- Statements (`let`, `if`, `for`, `blend`) are still represented structurally, but each embedded expression is bytecode.
- This is the first step toward offloading shader execution to ESP32.

Transport note:
- The current ESPHome `tcp_led_stream` component in `esphome_devices` accepts full pixel-frame payloads (`LEDS` header + RGB/RGBW bytes, protocol v1/v2).
- Bytecode upload/execution on device will require an additional protocol layer on top of (or alongside) the current frame stream transport.

## Validation rules

The parser/validator rejects:

- Missing required top-level constructs: `effect`, `layer`, `emit`
- Duplicate `effect`, `frame`, or `emit`
- Unknown top-level or layer statements
- Duplicate names:
  - duplicate `param`
  - duplicate `layer`
  - duplicate `let` (including conflicts with params)
- Invalid `for` range (`end <= start`)
- Reserved identifiers for `param`, `layer`, `let`, loop index names:
  - keywords (`effect`, `param`, `frame`, `layer`, `let`, `if`, `else`, `for`, `in`, `blend`, `emit`)
  - builtin names
  - builtin constant names (`PI`, `TAU`)
  - input names (`time`, `frame`, `x`, `y`, `width`, `height`)
- Unknown identifiers
- Unknown builtin names
- Invalid builtin arity or argument types
- Invalid expression typing for `param`, `if` condition, or `blend`
- `frame` expressions that use `x` or `y`
- `blend` usage inside `frame` block

## CLI usage in this repository

Run a DSL effect file directly:

`zig build run -- <host> [port] [frame_rate_hz] dsl-file <path-to-effect.dsl>`

When running in `dsl-file` mode, the runtime writes the compiled reference bytecode to:

`bytecode/<dsl-script-name>.bin`

Examples:

- `zig build run -- 127.0.0.1 dsl-file examples\dsl\v1\aurora.dsl`
- `zig build run -- 127.0.0.1 7777 40 dsl-file examples\dsl\v1\rain-ripple.dsl`

Validation-oriented commands:

- Run all tests (includes parser/runtime tests):  
  `zig build test`
- Run parser tests directly:  
  `zig test src\dsl_parser.zig`
- Run runtime tests directly:  
  `zig test src\dsl_runtime.zig`

## Example files

Parser-compatible v1 examples:

- `examples\dsl\v1\aurora.dsl`
- `examples\dsl\v1\campfire.dsl`
- `examples\dsl\v1\soap-bubbles.dsl`
- `examples\dsl\v1\rain-ripple.dsl`
