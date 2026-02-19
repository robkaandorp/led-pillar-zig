# LED Pillar Art Installation

This repository is the software foundation for an interactive art installation built around a cylindrical LED display ("pillar").  
An ESP32 development board drives a 40 (height) x 30 (width) LED matrix, while a Bluetooth audio receiver plays an audio stream for synchronized sound effects.

## Display model

The LED matrix is physically wrapped around a tube/pole, so the right edge borders the left edge.  
Effects should treat the display as horizontally continuous to support seamless visuals that move around the pillar.

## Technical constraints

- Target display framerate is **40 Hz**, and it must remain configurable.
- TCP frame format should follow the protocol defined in: https://github.com/robkaandorp/tcp_led_stream
- Sender uses protocol version `0x02` and waits for per-frame ACK (`0x06`) before sending the next frame.
- Physical pixel layout is serpentine by column: first column top-to-bottom, next column bottom-to-top, alternating per column.

## Planned modules

1. **TCP display client library**  
   A client-side library that connects to the LED display over TCP and streams image frames (transport/protocol only).

2. **Display logic module**  
   Logic for mapping, composing, and presenting visuals correctly on a cylindrical (wrap-around) matrix, including serpentine column mapping.

3. **Image and sound generation module**  
   Effect generation for both visuals and audio-driven behavior used in the installation.

## Project status

- Current repository state: Zig project with runnable sender and simulator executables, reusable library module, TCP display client module, display logic module, and first visualization effect.
- Planned installation-specific modules are tracked in this checklist:
  - [x] Remove Zig starter example code and tests from the scaffold.
  - [x] Implement the TCP display client library for streaming frames to the ESPHome display component.
  - [x] Implement display logic for pillar wrap-around behavior on the 40x30 matrix.
  - [ ] Implement image and sound generation for installation effects.
    - [x] Add first display visualization sequence (1s red, 1s green, 1s blue, 1s white, then off).
    - [x] Add continuous running pixel that advances per row and picks a bright random color each full rundown.

## Related project

The ESPHome component that receives TCP frame streams for the display is implemented here:  
https://github.com/robkaandorp/tcp_led_stream

## Getting started

### Prerequisites

- Zig `0.15.2` or newer

### Commands

- Build executable: `zig build`
- Run sender with selectable effect: `zig build run -- <host> [port] [frame_rate_hz] [effect] [effect_args...]`
- Effects:
  - `demo` (default): pixel health test, then running dot
  - `health-test [hold_seconds]`
  - `running-dot`
  - `soap-bubbles`: drifting bubble-like particles
  - `campfire`: warm, flickering ember glow
  - `aurora-ribbons`: smooth flowing aurora bands
  - `rain-ripple`: raindrop ripples across the display
  - `infinite-line [rotation_period_seconds] [color_transition_seconds] [line_width_pixels]`
  - `infinite-lines [line_count] [rotation_period_seconds] [color_transition_seconds] [line_width_pixels]`
  - `dsl-file <path-to-effect.dsl>`
- On normal exit or `Ctrl+C`, the sender clears the LED display to black before disconnecting.
- Run console TCP display simulator: `zig build simulator -- [port]`
- The simulator renders the matrix and prints live stats (FPS, bytes/s, total frames, total bytes) below it.
- Run full tests: `zig build test`
- Run tests in the library module: `zig test src\root.zig`
- Run tests in the executable module: `zig test src\main.zig`
- Run a single test by name filter: `zig test src\root.zig --test-filter "<test name>"`
- DSL feasibility research and example syntax: `DSL_FEASIBILITY_FINDINGS.md`
- DSL v1 parser language spec: `DSL_V1_LANGUAGE.md`
- DSL v1 example files: `examples\dsl\v1\`

## Development principles

- Test code as much as possible, including standard and edge cases.
- Keep code clear, simple, and easy to read.
- Prefer less code when it improves clarity and maintainability.
- Keep allocations and deallocations to a minimum; prefer allocating most required memory during startup.
- For effect rendering, use the single-pass frame traversal abstraction (`renderColorFrameSinglePass` in `src\effects.zig`) so each logical pixel is visited once per frame.
