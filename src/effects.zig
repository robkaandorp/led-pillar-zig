const std = @import("std");
const display_logic = @import("display_logic.zig");
const tcp_client = @import("tcp_client.zig");

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    w: u8 = 0,
};

pub const PixelHealthTestConfig = struct {
    hold_seconds: u64 = 1,
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
};

pub const StopFlag = std.atomic.Value(bool);

const RunningPixelState = struct {
    x: u16 = 0,
    y: u16 = 0,
    color: Color = .{ .r = 255 },
};

const FramePacer = struct {
    timer: std.time.Timer,
    next_send_ns: u64 = 0,
    frame_delay_ns: u64,

    fn init(frame_rate_hz: u16) !FramePacer {
        if (frame_rate_hz == 0) return error.InvalidFrameRate;
        return .{
            .timer = try std.time.Timer.start(),
            .frame_delay_ns = @as(u64, std.time.ns_per_s) / @as(u64, frame_rate_hz),
        };
    }

    fn waitBeforeSend(self: *FramePacer) void {
        const now = self.timer.read();
        if (now < self.next_send_ns) std.Thread.sleep(self.next_send_ns - now);
    }

    fn markSent(self: *FramePacer) void {
        self.next_send_ns = self.timer.read() +| self.frame_delay_ns;
    }
};

const pixel_health_phases = [_]Color{
    .{ .r = 255 }, // red
    .{ .g = 255 }, // green
    .{ .b = 255 }, // blue
    .{ .r = 255, .g = 255, .b = 255, .w = 255 }, // white
};

pub fn runPixelHealthSequence(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: PixelHealthTestConfig,
) !void {
    var pacer = try FramePacer.init(config.frame_rate_hz);
    try runPixelHealthPhases(client, display, config.frame_rate_hz, config.hold_seconds, &pacer);
    try fillSolid(display, .{});
    try sendFrameWithPacing(client, display.payload(), &pacer);
}

pub fn runPixelHealthThenRunningPixel(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: PixelHealthTestConfig,
    stop_flag: ?*const StopFlag,
) !void {
    var pacer = try FramePacer.init(config.frame_rate_hz);
    try runPixelHealthPhases(client, display, config.frame_rate_hz, config.hold_seconds, &pacer, stop_flag);
    if (shouldStop(stop_flag)) return;
    try runRunningPixelLoop(client, display, &pacer, stop_flag);
}

fn runPixelHealthPhases(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    frame_rate_hz: u16,
    hold_seconds: u64,
    pacer: *FramePacer,
    stop_flag: ?*const StopFlag,
) !void {
    const frames_per_phase = try phaseFrameCount(frame_rate_hz, hold_seconds);
    for (pixel_health_phases) |phase| {
        if (shouldStop(stop_flag)) return;
        try fillSolid(display, phase);
        try sendRepeated(client, display.payload(), frames_per_phase, pacer, stop_flag);
    }
}

pub fn fillSolid(display: *display_logic.DisplayBuffer, color: Color) !void {
    var encoded: [4]u8 = undefined;
    const pixel = encodeColor(display.pixel_format, color, &encoded);

    var offset: usize = 0;
    while (offset < display.buffer.len) : (offset += display.bytes_per_pixel) {
        @memcpy(display.buffer[offset .. offset + display.bytes_per_pixel], pixel);
    }
}

fn sendRepeated(
    client: *tcp_client.TcpClient,
    payload: []const u8,
    frame_count: u64,
    pacer: *FramePacer,
    stop_flag: ?*const StopFlag,
) !void {
    if (frame_count == 0) return;
    var frame_index: u64 = 0;
    while (frame_index < frame_count) : (frame_index += 1) {
        if (shouldStop(stop_flag)) return;
        try sendFrameWithPacing(client, payload, pacer);
    }
}

fn phaseFrameCount(frame_rate_hz: u16, hold_seconds: u64) !u64 {
    if (frame_rate_hz == 0) return error.InvalidFrameRate;
    return std.math.mul(u64, hold_seconds, frame_rate_hz);
}

fn sendFrameWithPacing(client: *tcp_client.TcpClient, payload: []const u8, pacer: *FramePacer) !void {
    pacer.waitBeforeSend();
    try client.sendFrame(payload);
    pacer.markSent();
}

fn runRunningPixelLoop(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    pacer: *FramePacer,
    stop_flag: ?*const StopFlag,
) !void {
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    var state = RunningPixelState{
        .x = 0,
        .y = 0,
        .color = randomBrightColor(random),
    };

    while (!shouldStop(stop_flag)) {
        try drawRunningPixelFrame(display, state);
        try sendFrameWithPacing(client, display.payload(), pacer);

        if (advanceRunner(&state, display.width, display.height)) {
            state.color = randomBrightColor(random);
        }
    }
}

fn shouldStop(stop_flag: ?*const StopFlag) bool {
    const flag = stop_flag orelse return false;
    return flag.load(.seq_cst);
}

fn drawRunningPixelFrame(display: *display_logic.DisplayBuffer, state: RunningPixelState) !void {
    display.clear(0);
    var encoded: [4]u8 = undefined;
    const pixel = encodeColor(display.pixel_format, state.color, &encoded);
    try display.setPixel(@as(i32, @intCast(state.x)), state.y, pixel);
}

fn advanceRunner(state: *RunningPixelState, width: u16, height: u16) bool {
    state.x +%= 1;
    if (state.x < width) return false;

    state.x = 0;
    state.y +%= 1;
    if (state.y < height) return false;

    state.y = 0;
    return true;
}

fn randomBrightColor(random: std.Random) Color {
    var color = Color{
        .r = random.int(u8),
        .g = random.int(u8),
        .b = random.int(u8),
    };
    if (color.r < 128 and color.g < 128 and color.b < 128) {
        color.r |= 0x80;
    }
    return color;
}

fn encodeColor(format: tcp_client.PixelFormat, color: Color, output: *[4]u8) []const u8 {
    return switch (format) {
        .rgb => blk: {
            output[0] = color.r;
            output[1] = color.g;
            output[2] = color.b;
            break :blk output[0..3];
        },
        .grb => blk: {
            output[0] = color.g;
            output[1] = color.r;
            output[2] = color.b;
            break :blk output[0..3];
        },
        .bgr => blk: {
            output[0] = color.b;
            output[1] = color.g;
            output[2] = color.r;
            break :blk output[0..3];
        },
        .rgbw => blk: {
            if (color.w != 0) {
                output[0] = 0;
                output[1] = 0;
                output[2] = 0;
                output[3] = color.w;
            } else {
                output[0] = color.r;
                output[1] = color.g;
                output[2] = color.b;
                output[3] = 0;
            }
            break :blk output[0..4];
        },
        .grbw => blk: {
            if (color.w != 0) {
                output[0] = 0;
                output[1] = 0;
                output[2] = 0;
                output[3] = color.w;
            } else {
                output[0] = color.g;
                output[1] = color.r;
                output[2] = color.b;
                output[3] = 0;
            }
            break :blk output[0..4];
        },
    };
}

test "fillSolid encodes RGB pixel order correctly" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 2,
        .height = 1,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    try fillSolid(&display, .{ .r = 5, .g = 6, .b = 7 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 5, 6, 7 }, display.payload());
}

test "fillSolid encodes GRB pixel order correctly" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 2,
        .height = 1,
        .pixel_format = .grb,
    });
    defer display.deinit();

    try fillSolid(&display, .{ .r = 5, .g = 6, .b = 7 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 6, 5, 7, 6, 5, 7 }, display.payload());
}

test "fillSolid uses white channel for RGBW white phase" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 1,
        .height = 1,
        .pixel_format = .rgbw,
    });
    defer display.deinit();

    try fillSolid(&display, .{ .w = 255 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, display.payload());
}

test "phaseFrameCount validates frame rate" {
    try std.testing.expectError(error.InvalidFrameRate, phaseFrameCount(0, 1));
    try std.testing.expectEqual(@as(u64, 40), try phaseFrameCount(40, 1));
}

test "advanceRunner wraps rows and signals full rundown completion" {
    var state = RunningPixelState{ .x = 0, .y = 0 };
    try std.testing.expect(!advanceRunner(&state, 3, 2));
    try std.testing.expectEqual(@as(u16, 1), state.x);
    try std.testing.expectEqual(@as(u16, 0), state.y);

    _ = advanceRunner(&state, 3, 2);
    try std.testing.expectEqual(@as(u16, 2), state.x);
    try std.testing.expectEqual(@as(u16, 0), state.y);

    _ = advanceRunner(&state, 3, 2);
    try std.testing.expectEqual(@as(u16, 0), state.x);
    try std.testing.expectEqual(@as(u16, 1), state.y);

    _ = advanceRunner(&state, 3, 2);
    _ = advanceRunner(&state, 3, 2);
    try std.testing.expect(advanceRunner(&state, 3, 2));
    try std.testing.expectEqual(@as(u16, 0), state.x);
    try std.testing.expectEqual(@as(u16, 0), state.y);
}

test "randomBrightColor always has at least one bright RGB channel" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const random = prng.random();
    var i: u32 = 0;
    while (i < 2048) : (i += 1) {
        const c = randomBrightColor(random);
        try std.testing.expect(c.r >= 128 or c.g >= 128 or c.b >= 128);
    }
}
