#!/usr/bin/env python3
"""
Shader Performance Benchmark for LED Pillar ESP32 Firmware.

Connects to the ESP32 telnet console, runs each native shader for a
stabilization period, captures performance metrics via the `top` command,
and writes results to a markdown file.

Usage:
    python3 shader_benchmark.py [--host HOST] [--port PORT] [--settle SECS] [--output FILE]

Requirements: Python 3.10+ (no external dependencies).
"""

from __future__ import annotations

import argparse
import re
import socket
import struct
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Telnet helpers (minimal IAC handling, no telnetlib dependency)
# ---------------------------------------------------------------------------

IAC = 0xFF
WILL = 0xFB
WONT = 0xFC
DO = 0xFD
DONT = 0xFE
SB = 0xFA
SE = 0xF0


def _strip_iac(data: bytes) -> bytes:
    """Remove telnet IAC sequences from raw data."""
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == IAC:
            if i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (WILL, WONT, DO, DONT):
                    i += 3  # IAC + cmd + option
                    continue
                elif cmd == SB:
                    # Skip until IAC SE
                    j = i + 2
                    while j < len(data) - 1:
                        if data[j] == IAC and data[j + 1] == SE:
                            j += 2
                            break
                        j += 1
                    i = j
                    continue
                elif cmd == IAC:
                    out.append(IAC)
                    i += 2
                    continue
            i += 1
            continue
        out.append(b)
        i += 1
    return bytes(out)


def _recv_until_prompt(sock: socket.socket, timeout: float = 5.0) -> str:
    """Read from socket until we see the prompt 'led-pillar:...> '."""
    sock.settimeout(timeout)
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf.extend(chunk)
            text = _strip_iac(bytes(buf)).decode("utf-8", errors="replace")
            if re.search(r"led-pillar:[^>]*> $", text):
                return text
        except socket.timeout:
            break
    return _strip_iac(bytes(buf)).decode("utf-8", errors="replace")


def _send_cmd(sock: socket.socket, cmd: str) -> None:
    """Send a telnet command line."""
    sock.sendall((cmd + "\r\n").encode("utf-8"))


def _recv_raw(sock: socket.socket, timeout: float) -> str:
    """Read raw data for a given timeout period."""
    sock.settimeout(0.5)
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf.extend(chunk)
            # Early exit once we have a full top screen
            text = _strip_iac(bytes(buf)).decode("utf-8", errors="replace")
            if "Press any key" in text:
                break
        except socket.timeout:
            continue
    return _strip_iac(bytes(buf)).decode("utf-8", errors="replace")


# ---------------------------------------------------------------------------
# Metric parsing
# ---------------------------------------------------------------------------

@dataclass
class ShaderMetrics:
    name: str = ""
    status: str = ""
    fps: float = 0.0
    frames: int = 0
    slow_frames: int = 0
    audio: str = "none"
    display_ms: float = 0.0
    audio_ms: float = 0.0
    total_ms: float = 0.0
    budget_pct: float = 0.0
    target_ms: float = 0.0
    free_heap: int = 0


def _parse_top_output(text: str) -> ShaderMetrics | None:
    """Parse the last complete `top` screen from raw telnet output."""
    # Find last occurrence of "Shader:" to get the most recent refresh
    blocks = text.split("Shader:")
    if len(blocks) < 2:
        return None
    last_block = "Shader:" + blocks[-1]

    m = ShaderMetrics()
    for line in last_block.splitlines():
        line = line.strip()
        if line.startswith("Shader:"):
            m.name = line.split(":", 1)[1].strip()
        elif line.startswith("Status:"):
            m.status = line.split(":", 1)[1].strip()
        elif line.startswith("FPS:"):
            try:
                m.fps = float(line.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("Frames:"):
            try:
                m.frames = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("Slow frames:"):
            try:
                m.slow_frames = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("Audio:"):
            m.audio = line.split(":", 1)[1].strip()
        elif line.startswith("Render:"):
            # "12.3 ms display + 0.5 ms audio = 12.8 ms (51.2% of 25.0 ms)"
            rm = re.search(
                r"([\d.]+)\s*ms\s+display\s*\+\s*([\d.]+)\s*ms\s+audio\s*=\s*([\d.]+)\s*ms\s*\(([\d.]+)%\s+of\s+([\d.]+)\s*ms\)",
                line,
            )
            if rm:
                m.display_ms = float(rm.group(1))
                m.audio_ms = float(rm.group(2))
                m.total_ms = float(rm.group(3))
                m.budget_pct = float(rm.group(4))
                m.target_ms = float(rm.group(5))
        elif line.startswith("Free heap:"):
            try:
                m.free_heap = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
    return m if m.name else None


# ---------------------------------------------------------------------------
# Shader list (all native shaders in registry order)
# ---------------------------------------------------------------------------

SHADERS = [
    "a440-test-tone",
    "aurora",
    "aurora-ribbons-classic",
    "campfire",
    "chaos-nebula",
    "dream-weaver",
    "electric-arcs",
    "forest-wind",
    "gradient",
    "heartbeat-pulse",
    "infinite-lines",
    "lava-lamp",
    "ocean-waves",
    "primal-storm",
    "rain-matrix",
    "rain-ripple",
    "soap-bubbles",
    "spiral-galaxy",
    "starfield",
    "tone-pulse",
]


# ---------------------------------------------------------------------------
# Build info collection
# ---------------------------------------------------------------------------

@dataclass
class BuildInfo:
    timestamp: str = ""
    git_commit: str = ""
    git_dirty: bool = False
    idf_version: str = ""
    gcc_version: str = ""
    cmake_shader_flags: str = ""
    global_optimization: str = ""
    notes: str = ""


def _collect_build_info() -> BuildInfo:
    """Collect build metadata from the local repository."""
    import subprocess

    info = BuildInfo()
    info.timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    # Git commit
    try:
        info.git_commit = (
            subprocess.check_output(
                ["git", "rev-parse", "--short", "HEAD"], stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )
        status = subprocess.check_output(
            ["git", "status", "--porcelain"], stderr=subprocess.DEVNULL
        ).decode().strip()
        info.git_dirty = len(status) > 0
    except Exception:
        info.git_commit = "unknown"

    # IDF version
    try:
        result = subprocess.check_output(
            ["idf.py", "--version"], stderr=subprocess.STDOUT
        ).decode().strip()
        info.idf_version = result
    except Exception:
        info.idf_version = "unknown"

    # GCC version
    try:
        result = subprocess.check_output(
            ["xtensa-esp-elf-gcc", "--version"], stderr=subprocess.STDOUT
        ).decode().splitlines()[0].strip()
        info.gcc_version = result
    except Exception:
        info.gcc_version = "unknown"

    # CMake flags for shader files
    cmake_path = Path(__file__).parent.parent / "main" / "CMakeLists.txt"
    if cmake_path.exists():
        text = cmake_path.read_text()
        entries = re.findall(
            r"set_source_files_properties\((\S+)\s+PROPERTIES\s+COMPILE_OPTIONS\s+\"([^\"]+)\"",
            text,
        )
        if entries:
            info.cmake_shader_flags = "; ".join(
                f"{fname}: {flags}" for fname, flags in entries
            )
        else:
            info.cmake_shader_flags = "default"

    # Global optimization from sdkconfig
    sdkconfig_path = Path(__file__).parent.parent / "sdkconfig"
    if sdkconfig_path.exists():
        text = sdkconfig_path.read_text()
        if "CONFIG_COMPILER_OPTIMIZATION_PERF=y" in text:
            info.global_optimization = "-O2 (performance)"
        elif "CONFIG_COMPILER_OPTIMIZATION_SIZE=y" in text:
            info.global_optimization = "-Os (size)"
        elif "CONFIG_COMPILER_OPTIMIZATION_DEBUG=y" in text:
            info.global_optimization = "-Og (debug)"
        elif "CONFIG_COMPILER_OPTIMIZATION_NONE=y" in text:
            info.global_optimization = "-O0 (none)"
        else:
            info.global_optimization = "unknown"
    else:
        # Fall back to sdkconfig.defaults
        defaults_path = Path(__file__).parent.parent / "sdkconfig.defaults"
        if defaults_path.exists():
            text = defaults_path.read_text()
            if "CONFIG_COMPILER_OPTIMIZATION_PERF=y" in text:
                info.global_optimization = "-O2 (performance)"
            else:
                info.global_optimization = "-Og (debug, IDF default)"
        else:
            info.global_optimization = "unknown"

    return info


# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

def run_benchmark(
    host: str,
    port: int,
    settle_seconds: int,
    output_path: Path,
) -> None:
    """Connect to ESP32 telnet, benchmark all shaders, write markdown report."""

    print(f"Collecting build info...")
    build_info = _collect_build_info()

    print(f"Connecting to {host}:{port}...")
    sock = socket.create_connection((host, port), timeout=10)

    # Read welcome banner and initial prompt
    welcome = _recv_until_prompt(sock, timeout=5)
    print(f"Connected. Banner received.")

    results: list[ShaderMetrics] = []

    for i, shader_name in enumerate(SHADERS):
        label = f"[{i + 1}/{len(SHADERS)}]"
        print(f"{label} Running '{shader_name}'...", end="", flush=True)

        # Navigate to root and run shader
        _send_cmd(sock, f"cd /")
        _recv_until_prompt(sock, timeout=3)
        _send_cmd(sock, f"run {shader_name}")
        run_response = _recv_until_prompt(sock, timeout=5)

        if "Running:" not in run_response and "not found" in run_response.lower():
            print(f" SKIPPED (not found)")
            continue

        # Wait for EMA to stabilize
        print(f" settling {settle_seconds}s...", end="", flush=True)
        time.sleep(settle_seconds)

        # Enter top mode
        _send_cmd(sock, "top")
        # Wait up to 30s for top output (slow shaders hold mutex for a long time)
        top_output = _recv_raw(sock, timeout=30.0)

        # Exit top mode by sending a key
        sock.sendall(b"q")
        time.sleep(0.5)

        # Read any remaining output and prompt
        remaining = _recv_raw(sock, timeout=1.0)

        metrics = _parse_top_output(top_output)
        if metrics:
            results.append(metrics)
            budget_str = f"{metrics.budget_pct:.1f}%"
            print(
                f" {metrics.fps:.1f} FPS, "
                f"{metrics.display_ms:.1f}ms disp + {metrics.audio_ms:.1f}ms audio "
                f"= {metrics.total_ms:.1f}ms ({budget_str})"
            )
        else:
            print(f" FAILED to parse top output")
            # Still try to get back to prompt
            _recv_until_prompt(sock, timeout=3)

        # Stop shader
        _send_cmd(sock, "stop")
        _recv_until_prompt(sock, timeout=3)

        # Brief pause between shaders
        time.sleep(1)

    # Disconnect
    _send_cmd(sock, "exit")
    sock.close()

    # Write markdown report
    _write_report(output_path, build_info, results)
    print(f"\nReport written to: {output_path}")


def _write_report(
    path: Path,
    build: BuildInfo,
    results: list[ShaderMetrics],
) -> None:
    """Write benchmark results as a markdown file."""
    lines: list[str] = []
    lines.append("# Shader Performance Baseline")
    lines.append("")
    lines.append("Auto-generated by `esp32_firmware/scripts/shader_benchmark.py`.")
    lines.append("Re-run after important firmware changes to detect regressions.")
    lines.append("")

    # Build info
    lines.append("## Build Information")
    lines.append("")
    lines.append(f"| Field | Value |")
    lines.append(f"|-------|-------|")
    lines.append(f"| Date | {build.timestamp} |")
    commit = build.git_commit + (" (dirty)" if build.git_dirty else "")
    lines.append(f"| Git commit | `{commit}` |")
    lines.append(f"| ESP-IDF version | {build.idf_version} |")
    lines.append(f"| GCC version | {build.gcc_version} |")
    lines.append(f"| Shader compile flags | `{build.cmake_shader_flags}` |")
    lines.append(f"| Global optimization | {build.global_optimization} |")
    if build.notes:
        lines.append(f"| Notes | {build.notes} |")
    lines.append("")

    # Results table
    lines.append("## Results")
    lines.append("")
    lines.append(
        "| Shader | FPS | Display (ms) | Audio (ms) | Total (ms) | Budget % | Audio | Slow Frames | Heap |"
    )
    lines.append(
        "|--------|----:|-------------:|-----------:|-----------:|---------:|-------|------------:|-----:|"
    )
    for m in results:
        at_target = "✅" if m.budget_pct <= 100.0 else "⚠️"
        lines.append(
            f"| {m.name} | {m.fps:.1f} | {m.display_ms:.1f} | {m.audio_ms:.1f} "
            f"| {m.total_ms:.1f} | {at_target} {m.budget_pct:.1f}% "
            f"| {m.audio} | {m.slow_frames} | {m.free_heap} |"
        )
    lines.append("")

    # Summary
    at_target = [m for m in results if m.budget_pct <= 100.0]
    over_budget = [m for m in results if m.budget_pct > 100.0]
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- **Total shaders tested**: {len(results)}")
    lines.append(f"- **At or under budget**: {len(at_target)}")
    lines.append(f"- **Over budget**: {len(over_budget)}")
    if over_budget:
        lines.append(f"- **Over-budget shaders**: {', '.join(m.name for m in over_budget)}")
    lines.append("")

    path.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Benchmark all native shaders on the ESP32 LED Pillar."
    )
    parser.add_argument(
        "--host",
        default="led-pillar.local",
        help="ESP32 hostname or IP (default: led-pillar.local)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=23,
        help="Telnet port (default: 23)",
    )
    parser.add_argument(
        "--settle",
        type=int,
        default=15,
        help="Seconds to wait per shader for EMA stabilization (default: 15)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output markdown path (default: esp32_firmware/SHADER_PERFORMANCE.md)",
    )
    parser.add_argument(
        "--notes",
        type=str,
        default="",
        help="Optional notes to include in the report header",
    )
    args = parser.parse_args()

    if args.output:
        output_path = Path(args.output)
    else:
        output_path = Path(__file__).parent.parent / "SHADER_PERFORMANCE.md"

    run_benchmark(
        host=args.host,
        port=args.port,
        settle_seconds=args.settle,
        output_path=output_path,
    )


if __name__ == "__main__":
    main()
