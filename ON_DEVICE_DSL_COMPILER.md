# On-Device DSL Compiler (Parked)

> **Status**: Parked — this is a stretch goal for future consideration. See [ROADMAP.md](ROADMAP.md) for the active feature plan.

## Description

Run a DSL-to-bytecode compiler on the ESP32 itself, so users can paste a DSL script into the telnet session and have it compile and run without a PC.

## Difficulty: **Hard**

## What Needs to Be Done

1. **Port DSL parser to C**: The current parser is written in Zig (`src/dsl_parser.zig`, ~830 lines). It would need to be rewritten in C for the ESP32 firmware.
   - The parser is a hand-written recursive descent parser
   - Token scanning, AST construction, validation
   - ~2000-3000 lines of C estimated

2. **Port bytecode compiler to C**: The runtime/compiler (`src/dsl_runtime.zig`, ~1200 lines) compiles the AST to bytecode. Also needs C port.
   - Expression compilation, slot allocation, serialization
   - ~1500-2000 lines of C estimated

3. **Telnet integration**: Add a `compile` command or a multi-line input mode:
   - User pastes DSL source
   - End marker (e.g., blank line, `EOF`, or Ctrl+D)
   - Compile to bytecode in-memory
   - Activate the compiled shader

4. **Memory management**: The parser/compiler needs temporary allocations:
   - AST nodes, string storage, bytecode buffer
   - Estimate: 20-50 KB peak for a complex shader
   - Must use a scratch allocator and free after compilation

## Open Questions

- **Q1**: Is the effort of porting ~2000+ lines of Zig parser+compiler to C worthwhile?
  - *Alternative*: Instead of porting, we could have the phone send the DSL source to the ESP32, which forwards it to a PC for compilation, then receives the bytecode back. But this defeats the "no PC" goal.
  - *Alternative*: Write a minimal "DSL-lite" parser in C that supports a subset of the language.
  - *Assumption*: If implemented, do a faithful port of the full parser.
- **Q2**: Should compiled bytecode be persistable (saved to NVS like the default shader hook)?
  - *Assumption*: Yes, so you can set a telnet-compiled shader as the default.

## Verification Goals

1. ✅ Paste a simple DSL shader into telnet and it compiles and runs
2. ✅ Compilation errors are reported with line numbers
3. ✅ Complex shaders (multi-layer, for loops, if statements) compile correctly
4. ✅ Compiled bytecode matches the PC-compiled bytecode for the same source
5. ✅ Memory is fully reclaimed after compilation
6. ✅ Setting the compiled shader as default persists across reboots
