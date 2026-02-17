# Copilot Instructions

## Build, run, and test commands
- Build/install executable: `zig build`
- Run pixel health + running pixel effect: `zig build run -- <host> [port] [frame_rate_hz]`
- Run console TCP simulator: `zig build simulator -- [port]`
- Run full test suite (both library + executable module tests): `zig build test`
- Run tests in the library module: `zig test src\root.zig`
- Run tests in the executable module: `zig test src\main.zig`
- Run a single test by name filter: `zig test src\root.zig --test-filter "<test name>"`
- Lint: no repository-specific lint step is defined in `build.zig`.

## High-level architecture
- `build.zig` defines one reusable module named `led_pillar_zig` rooted at `src/root.zig`.
- `build.zig` also defines the CLI executable rooted at `src/main.zig`; that executable imports the reusable module via `@import("led_pillar_zig")`.
- `build.zig` defines a second executable `led_pillar_simulator` rooted at `src/simulator_main.zig` for local TCP display simulation.
- `src/root.zig` re-exports shared configuration/constants, TCP client types (`src/tcp_client.zig`), display mapping/buffer types (`src/display_logic.zig`), effect routines (`src/effects.zig`), and simulator logic (`src/simulator.zig`).
- `zig build test` is a top-level build step that runs two separate test binaries in parallel:
  - tests in the library module (`src/root.zig` via `mod`)
  - tests in the executable root module (`src/main.zig`)
- `build.zig.zon` pins package metadata (including `minimum_zig_version = "0.15.2"`) and currently packages only `build.zig`, `build.zig.zon`, and `src`.

## Project-specific constraints
- Display model is cylindrical: treat the 40 (height) x 30 (width) matrix as horizontally wrap-around (right edge neighbors left edge).
- Physical pixel order is serpentine by column (top-to-bottom on one column, bottom-to-top on the next).
- Target framerate is 40 Hz, but implementations must keep framerate configurable.
- TCP frame protocol compatibility must match: https://github.com/robkaandorp/tcp_led_stream
- Minimize runtime allocations/deallocations; prefer allocating required buffers during startup.
- Prioritize tests for both standard behavior and edge cases.

## Key repository conventions
- Keep reusable/exported logic in `src/root.zig`; keep CLI entrypoint behavior in `src/main.zig`.
- Keep TCP stream framing logic inside `src/tcp_client.zig` and expose it through `src/root.zig`.
- Keep serpentine/wrap-around coordinate mapping in the display logic module, not in `tcp_client`.
- `src/display_logic.zig` should own logical `(x,y)` to physical LED buffer mapping and produce payload bytes for `tcp_client`.
- `src/effects.zig` should own visual sequence generation (currently pixel health sequence then a continuous running pixel).
- `src/main.zig` should handle shutdown cleanup by sending an all-black frame on exit (including Ctrl+C on Windows).
- `src/simulator.zig` acts as a protocol-compatible local TCP receiver and console renderer for display testing without hardware.
- When adding public library functionality, expose it from `src/root.zig` so consumers importing `led_pillar_zig` can access it.
- Keep tests colocated as Zig `test` blocks in the corresponding source files; this repository expects tests in both `root.zig` and `main.zig`.
- Preserve module wiring names used in `build.zig` (`led_pillar_zig`) unless intentionally refactoring all import sites.
