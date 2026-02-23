# Copilot Instructions

## Build, run, and test commands
- Build/install executable: `zig build`
- Run pixel health + running pixel effect: `zig build run -- <host> [port] [frame_rate_hz]`
- Run console TCP simulator: `zig build simulator -- [port]`
- Run full test suite (both library + executable module tests): `zig build test`
- Run tests in the library module only: `zig build test-root`
- Run tests in the executable module only: `zig build test-main`
- Run a single test by name filter: `zig build test-root -- --test-filter "<test name>"`
- Verbose test output: `zig build test --summary all`
- Lint: no repository-specific lint step is defined in `build.zig`.
- Note: `zig test src\main.zig` does NOT work because main.zig depends on the `led_pillar_zig` module wired via `build.zig`. Always use `zig build test-main` instead.

## High-level architecture
- `build.zig` defines one reusable module named `led_pillar_zig` rooted at `src/root.zig`.
- `build.zig` also defines the CLI executable rooted at `src/main.zig`; that executable imports the reusable module via `@import("led_pillar_zig")`.
- `build.zig` defines a second executable `led_pillar_simulator` rooted at `src/simulator_main.zig` for local TCP display simulation.
- `src/root.zig` re-exports shared configuration/constants, TCP client types (`src/tcp_client.zig`), display mapping/buffer types (`src/display_logic.zig`), effect routines (`src/effects.zig`), and simulator logic (`src/simulator.zig`).
- `zig build test` is a top-level build step that runs two separate test binaries in parallel:
  - tests in the library module (`src/root.zig` via `mod`)
  - tests in the executable root module (`src/main.zig`)
- `build.zig.zon` pins package metadata (including `minimum_zig_version = "0.15.2"`) and currently packages only `build.zig`, `build.zig.zon`, and `src`.

## Target platforms
- The project (CLI, simulator, and all unit tests) must build and run correctly on **Windows**, **Linux**, and **macOS**.
- The project must also build and run on **Raspberry Pi 3 and newer** (aarch64 Linux). Zig supports cross-compilation; use `-Dtarget=aarch64-linux` when building for Raspberry Pi from another host.
- All code paths, including stdin handling, signal handling, TCP I/O, sleep/timing, and console rendering, must work on every supported platform. Use `builtin.os.tag` for compile-time platform branching.
- Use forward slashes (`/`) in source-level file paths passed to `build.zig` (e.g. `b.path("esp32_firmware/main/generated/dsl_shader_generated.c")`). Zig's build system normalizes these to the native separator. Do NOT use backslashes in `build.zig` paths.
- ESP32 firmware (`esp32_firmware/`) is a separate ESP-IDF project targeting Xtensa only; it is not subject to the above cross-platform requirement.

## Cross-platform patterns and known pitfalls
- **stdin Enter detection on Windows**: `std.posix.poll` is not available on Windows. The project uses a platform split: on POSIX, `poll()` on `STDIN_FILENO` with a timeout; on Windows, a detached thread (`windowsWaitForEnter`) that blocks on `std.fs.File.stdin().read()` and signals via `std.atomic.Value(bool)`. The main loop polls that atomic with `Thread.sleep(500ms)`. Always guard with `if (builtin.os.tag == .windows)`.
- **Ctrl+C / signal handling on Windows**: Use `SetConsoleCtrlHandler` (via `std.os.windows`) to catch CTRL_C_EVENT etc. On POSIX, use `sigaction` or Zig's signal support.
- **Sleep/timer granularity on Windows**: `std.Thread.sleep()` on Windows has ~15.6 ms resolution. Never use relative per-frame timing (`sleep(interval - elapsed)`) in render/animation loops; always use **absolute deadline timing** (`next_deadline_ns += interval`) so that sleep overshoot in one frame self-corrects in the next. This is critical for hitting 40 FPS.
- **Math library linking**: On non-Windows platforms, the simulator must explicitly link `libm` (`simulator_exe.linkSystemLibrary("m")`). On Windows, math functions are provided by the C runtime linked via `linkLibC()`. Guard with `if (target.result.os.tag != .windows)`.
- **Console output**: The simulator renders ANSI escape sequences for console display. Windows Terminal and modern `cmd.exe` (Windows 10+) support ANSI; no special enable step is currently needed because Zig's std.io handles this, but be aware of this if targeting older Windows.
- **Stream reader buffering**: Always create ONE persistent `std.net.Stream.Reader` per TCP connection and pass it through all read functions. Creating a new buffered reader per read call loses already-buffered bytes and causes protocol desync (manifests as `ReadFile` parameter errors on Windows, unexpected EOF on POSIX).

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
