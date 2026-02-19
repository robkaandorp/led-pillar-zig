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
top_level      = effect_decl | param_decl | layer_decl | emit_stmt ;

effect_decl    = "effect" IDENT ;
param_decl     = "param" IDENT "=" expr ;
layer_decl     = "layer" IDENT "{" layer_stmt* "}" ;
emit_stmt      = "emit" ;

layer_stmt     = let_decl | blend_stmt ;
let_decl       = "let" IDENT "=" expr ;
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

## Builtin functions and types

Types:
- `scalar`
- `vec2`
- `rgba`

Builtins:

| Builtin | Signature | Returns |
|---|---|---|
| `sin` | `sin(scalar)` | `scalar` |
| `cos` | `cos(scalar)` | `scalar` |
| `abs` | `abs(scalar)` | `scalar` |
| `floor` | `floor(scalar)` | `scalar` |
| `fract` | `fract(scalar)` | `scalar` |
| `min` | `min(scalar, scalar)` | `scalar` |
| `max` | `max(scalar, scalar)` | `scalar` |
| `clamp` | `clamp(scalar, scalar, scalar)` | `scalar` |
| `smoothstep` | `smoothstep(scalar, scalar, scalar)` | `scalar` |
| `circle` | `circle(vec2, scalar)` | `scalar` |
| `box` | `box(vec2, vec2)` | `scalar` |
| `wrapdx` | `wrapdx(scalar, scalar, scalar)` | `scalar` |
| `hash01` | `hash01(scalar)` | `scalar` |
| `hashSigned` | `hashSigned(scalar)` | `scalar` |
| `hashCoords01` | `hashCoords01(scalar, scalar, scalar)` | `scalar` |
| `vec2` | `vec2(scalar, scalar)` | `vec2` |
| `rgba` | `rgba(scalar, scalar, scalar, scalar)` | `rgba` |

Available input identifiers:
- `time`, `frame`, `x`, `y`, `width`, `height`

## Semantics (v1 parser model)

- `param` expressions must type-check to `scalar`.
- `let` binds a typed expression within the current layer scope.
- `blend` expression must type-check to `rgba`.
- Arithmetic operators (`+`, `-`, `*`, `/`) are scalar-only.
- Unary `-` is scalar-only.
- Function calls must match known builtin name, arity, and argument types exactly.

## Validation rules

The parser/validator rejects:

- Missing required top-level constructs: `effect`, `layer`, `emit`
- Duplicate `effect` or `emit`
- Unknown top-level or layer statements
- Duplicate names:
  - duplicate `param`
  - duplicate `layer`
  - duplicate `let` (including conflicts with params)
- Reserved identifiers for `param`, `layer`, `let` names:
  - keywords (`effect`, `param`, `layer`, `let`, `blend`, `emit`)
  - builtin names
  - input names (`time`, `frame`, `x`, `y`, `width`, `height`)
- Unknown identifiers
- Unknown builtin names
- Invalid builtin arity or argument types
- Invalid expression typing for `param` or `blend`

## CLI usage in this repository

Run a DSL effect file directly:

`zig build run -- <host> [port] [frame_rate_hz] dsl-file <path-to-effect.dsl>`

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
