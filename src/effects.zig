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

pub const RunningDotConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
};

pub const InfiniteLineConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    rotation_period_seconds: u16 = 18,
    color_transition_seconds: u16 = 10,
    line_width_pixels: u16 = 1,
};

pub const InfiniteLinesConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    line_count: u16 = 4,
    rotation_period_seconds: u16 = 18,
    color_transition_seconds: u16 = 10,
    line_width_pixels: u16 = 1,
};

pub const StopFlag = std.atomic.Value(bool);

const RunningPixelState = struct {
    x: u16 = 0,
    y: u16 = 0,
    color: Color = .{ .r = 255 },
};

const InfiniteLineState = struct {
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    rotation_direction: f32 = 1.0,
    current_color: Color,
    target_color: Color,
    color_phase: f32 = 0.0,
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
    try runPixelHealthEffect(client, display, config, null);
}

pub fn runPixelHealthEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: PixelHealthTestConfig,
    stop_flag: ?*const StopFlag,
) !void {
    var pacer = try FramePacer.init(config.frame_rate_hz);
    try runPixelHealthPhases(client, display, config.frame_rate_hz, config.hold_seconds, &pacer, stop_flag);
    if (shouldStop(stop_flag)) return;
    try fillSolid(display, .{});
    try sendFrameWithPacing(client, display.payload(), &pacer);
}

pub fn runRunningDotEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: RunningDotConfig,
    stop_flag: ?*const StopFlag,
) !void {
    var pacer = try FramePacer.init(config.frame_rate_hz);
    try runRunningPixelLoop(client, display, &pacer, stop_flag);
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

pub fn runInfiniteLineEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: InfiniteLineConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.rotation_period_seconds == 0) return error.InvalidRotationPeriod;
    if (config.color_transition_seconds == 0) return error.InvalidColorTransitionPeriod;
    if (config.line_width_pixels == 0) return error.InvalidLineWidth;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const frame_rate_f = @as(f32, @floatFromInt(config.frame_rate_hz));
    const two_pi = std.math.pi * 2.0;

    var state = InfiniteLineState{
        .pivot_x = random.float(f32) * width_f,
        .pivot_y = random.float(f32) * height_f,
        .angle = random.float(f32) * two_pi,
        .current_color = randomBrightColor(random),
        .target_color = randomBrightColor(random),
    };

    const angular_step = two_pi / (frame_rate_f * @as(f32, @floatFromInt(config.rotation_period_seconds)));
    const color_step = 1.0 / (frame_rate_f * @as(f32, @floatFromInt(config.color_transition_seconds)));
    const line_half_width = @as(f32, @floatFromInt(config.line_width_pixels)) / 2.0;

    while (!shouldStop(stop_flag)) {
        const color = lerpColor(state.current_color, state.target_color, state.color_phase);
        try drawInfiniteWrappedLineFrame(display, state.pivot_x, state.pivot_y, state.angle, line_half_width, color);
        try sendFrameWithPacing(client, display.payload(), &pacer);

        state.angle += angular_step * state.rotation_direction;
        if (state.angle >= two_pi) state.angle -= two_pi;
        if (state.angle < 0.0) state.angle += two_pi;

        state.color_phase += color_step;
        if (state.color_phase >= 1.0) {
            state.current_color = state.target_color;
            state.target_color = randomBrightColor(random);
            state.color_phase -= 1.0;
        }
    }
}

pub fn runInfiniteLinesEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: InfiniteLinesConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.line_count == 0) return error.InvalidLineCount;
    if (config.rotation_period_seconds == 0) return error.InvalidRotationPeriod;
    if (config.color_transition_seconds == 0) return error.InvalidColorTransitionPeriod;
    if (config.line_width_pixels == 0) return error.InvalidLineWidth;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const frame_rate_f = @as(f32, @floatFromInt(config.frame_rate_hz));
    const two_pi = std.math.pi * 2.0;

    const line_count = @as(usize, config.line_count);
    const states = try std.heap.page_allocator.alloc(InfiniteLineState, line_count);
    defer std.heap.page_allocator.free(states);
    const initial_line_half_width = @as(f32, @floatFromInt(config.line_width_pixels)) / 2.0;
    const max_line_pixels = (@as(u32, display.width) * @as(u32, display.height)) / 2;

    for (states) |*state| {
        state.* = .{
            .pivot_x = random.float(f32) * width_f,
            .pivot_y = random.float(f32) * height_f,
            .angle = random.float(f32) * two_pi,
            .rotation_direction = if (random.boolean()) 1.0 else -1.0,
            .current_color = randomBrightColor(random),
            .target_color = randomBrightColor(random),
        };
        var retries: u16 = 0;
        while (retries < 128 and lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, state.angle, initial_line_half_width, max_line_pixels)) : (retries += 1) {
            state.angle = random.float(f32) * two_pi;
        }
    }

    const angular_step = two_pi / (frame_rate_f * @as(f32, @floatFromInt(config.rotation_period_seconds)));
    const color_step = 1.0 / (frame_rate_f * @as(f32, @floatFromInt(config.color_transition_seconds)));
    const line_half_width = @as(f32, @floatFromInt(config.line_width_pixels)) / 2.0;
    const max_line_pixels_frame = max_line_pixels;

    while (!shouldStop(stop_flag)) {
        display.clear(0);
        for (states) |*state| {
            if (lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, state.angle, line_half_width, max_line_pixels_frame)) {
                state.rotation_direction = -state.rotation_direction;
                advanceLineAngleWithCoverageLimit(display, state, angular_step, line_half_width, max_line_pixels_frame);
            }
            const color = lerpColor(state.current_color, state.target_color, state.color_phase);
            try drawInfiniteWrappedLineOnDisplay(display, state.pivot_x, state.pivot_y, state.angle, line_half_width, color);

            advanceLineAngleWithCoverageLimit(display, state, angular_step, line_half_width, max_line_pixels_frame);

            state.color_phase += color_step;
            if (state.color_phase >= 1.0) {
                state.current_color = state.target_color;
                state.target_color = randomBrightColor(random);
                state.color_phase -= 1.0;
            }
        }

        try sendFrameWithPacing(client, display.payload(), &pacer);
    }
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

fn drawInfiniteWrappedLineFrame(
    display: *display_logic.DisplayBuffer,
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    line_half_width: f32,
    color: Color,
) !void {
    display.clear(0);
    try drawInfiniteWrappedLineOnDisplay(display, pivot_x, pivot_y, angle, line_half_width, color);
}

fn drawInfiniteWrappedLineOnDisplay(
    display: *display_logic.DisplayBuffer,
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    line_half_width: f32,
    color: Color,
) !void {
    var encoded: [4]u8 = undefined;
    const pixel = encodeColor(display.pixel_format, color, &encoded);

    const direction_x = std.math.cos(angle);
    const direction_y = std.math.sin(angle);
    const normal_x = -direction_y;
    const normal_y = direction_x;
    const width_f = @as(f32, @floatFromInt(display.width));

    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const distance = wrappedLineDistance(px, py, pivot_x, pivot_y, normal_x, normal_y, width_f);
            if (distance <= line_half_width) {
                try display.setPixel(@as(i32, @intCast(x)), y, pixel);
            }
        }
    }
}

fn wrappedLineDistance(
    px: f32,
    py: f32,
    pivot_x: f32,
    pivot_y: f32,
    normal_x: f32,
    normal_y: f32,
    width: f32,
) f32 {
    const rel_x = px - pivot_x;
    const rel_y = py - pivot_y;
    const base_projection = (rel_x * normal_x) + (rel_y * normal_y);
    const wrap_projection_step = width * normal_x;

    if (@abs(wrap_projection_step) < 0.000001) return @abs(base_projection);

    const nearest_wrap_index = @as(i32, @intFromFloat(@round(-base_projection / wrap_projection_step)));

    var best = std.math.floatMax(f32);
    inline for ([_]i32{ -1, 0, 1 }) |neighbor_offset| {
        const wrap_index = nearest_wrap_index + neighbor_offset;
        const distance = @abs(base_projection + (@as(f32, @floatFromInt(wrap_index)) * wrap_projection_step));
        if (distance < best) best = distance;
    }
    return best;
}

fn lerpColor(from: Color, to: Color, t: f32) Color {
    const clamped_t = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpU8(from.r, to.r, clamped_t),
        .g = lerpU8(from.g, to.g, clamped_t),
        .b = lerpU8(from.b, to.b, clamped_t),
    };
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af = @as(f32, @floatFromInt(a));
    const bf = @as(f32, @floatFromInt(b));
    const value = af + ((bf - af) * t);
    const rounded = @as(i32, @intFromFloat(@round(value)));
    return @as(u8, @intCast(std.math.clamp(rounded, 0, 255)));
}

fn advanceLineAngleWithCoverageLimit(
    display: *const display_logic.DisplayBuffer,
    state: *InfiniteLineState,
    angular_step: f32,
    line_half_width: f32,
    max_line_pixels: u32,
) void {
    var direction = state.rotation_direction;
    var candidate = normalizeAngle(state.angle + (angular_step * direction));

    if (lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, candidate, line_half_width, max_line_pixels)) {
        direction = -direction;
        candidate = normalizeAngle(state.angle + (angular_step * direction));

        var retries: u16 = 0;
        while (retries < 360 and lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, candidate, line_half_width, max_line_pixels)) : (retries += 1) {
            candidate = normalizeAngle(candidate + (angular_step * direction));
        }

        if (lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, candidate, line_half_width, max_line_pixels)) return;
    }

    state.rotation_direction = direction;
    state.angle = candidate;
}

fn lineCoverageExceedsLimit(
    display: *const display_logic.DisplayBuffer,
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    line_half_width: f32,
    max_line_pixels: u32,
) bool {
    return countInfiniteWrappedLinePixels(display, pivot_x, pivot_y, angle, line_half_width) > max_line_pixels;
}

fn countInfiniteWrappedLinePixels(
    display: *const display_logic.DisplayBuffer,
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    line_half_width: f32,
) u32 {
    const direction_x = std.math.cos(angle);
    const direction_y = std.math.sin(angle);
    const normal_x = -direction_y;
    const normal_y = direction_x;
    const width_f = @as(f32, @floatFromInt(display.width));

    var lit_pixels: u32 = 0;
    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const distance = wrappedLineDistance(px, py, pivot_x, pivot_y, normal_x, normal_y, width_f);
            if (distance <= line_half_width) lit_pixels += 1;
        }
    }

    return lit_pixels;
}

fn normalizeAngle(angle: f32) f32 {
    const two_pi = std.math.pi * 2.0;
    var normalized = @mod(angle, two_pi);
    if (normalized < 0.0) normalized += two_pi;
    return normalized;
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

test "wrappedLineDistance uses horizontal wrap-around" {
    const distance = wrappedLineDistance(29.5, 10.5, 0.2, 10.5, 1.0, 0.0, 30.0);
    try std.testing.expect(distance < 1.0);
}

test "wrappedLineDistance handles wraps beyond adjacent copies" {
    const distance = wrappedLineDistance(0.0, 24.4898, 0.0, 0.0, 0.2, 0.98, 30.0);
    try std.testing.expect(distance < 0.1);
}

test "lerpColor blends channels" {
    const midpoint = lerpColor(.{ .r = 255, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 255 }, 0.5);
    try std.testing.expectEqual(@as(u8, 128), midpoint.r);
    try std.testing.expectEqual(@as(u8, 0), midpoint.g);
    try std.testing.expectEqual(@as(u8, 128), midpoint.b);
}

test "countInfiniteWrappedLinePixels can exceed half near horizontal" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 30,
        .height = 40,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    const lit = countInfiniteWrappedLinePixels(&display, 15.0, 20.0, 0.02, 0.5);
    try std.testing.expect(lit > 600);
}

test "advanceLineAngleWithCoverageLimit reverses to stay under half coverage" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 30,
        .height = 40,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    var state = InfiniteLineState{
        .pivot_x = 15.0,
        .pivot_y = 20.0,
        .angle = 0.07,
        .rotation_direction = -1.0,
        .current_color = .{ .r = 255 },
        .target_color = .{ .g = 255 },
    };
    const line_half_width: f32 = 0.5;
    const max_line_pixels: u32 = 600;

    advanceLineAngleWithCoverageLimit(&display, &state, 0.02, line_half_width, max_line_pixels);
    try std.testing.expectEqual(@as(f32, 1.0), state.rotation_direction);
    try std.testing.expect(!lineCoverageExceedsLimit(&display, state.pivot_x, state.pivot_y, state.angle, line_half_width, max_line_pixels));
}
