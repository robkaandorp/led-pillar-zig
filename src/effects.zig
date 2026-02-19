const std = @import("std");
const display_logic = @import("display_logic.zig");
const tcp_client = @import("tcp_client.zig");
const sdf_common = @import("sdf_common.zig");

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

pub const SoapBubblesConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    bubble_count: u8 = 14,
};

pub const CampfireConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    tongue_count: u8 = 12,
};

pub const AuroraRibbonsConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    layer_count: u8 = 4,
};

pub const RainRippleConfig = struct {
    frame_rate_hz: u16 = tcp_client.default_frame_rate_hz,
    drop_count: u8 = 36,
    ripple_count: u8 = 16,
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

const SoapBubble = struct {
    active: bool = false,
    lane_x: f32 = 0.0,
    y: f32 = 0.0,
    radius: f32 = 2.0,
    rise_speed: f32 = 8.0,
    wobble_amp: f32 = 0.8,
    wobble_freq: f32 = 1.0,
    phase: f32 = 0.0,
    depth_phase: f32 = 0.0,
    age: u16 = 0,
    life_frames: u16 = 80,
    popping: bool = false,
    pop_age: u8 = 0,
    pop_duration: u8 = 3,
};

const CampfireTongue = struct {
    active: bool = false,
    lane_x: f32 = 0.0,
    y: f32 = 0.0,
    radius: f32 = 2.2,
    rise_speed: f32 = 12.0,
    drift_phase: f32 = 0.0,
    flicker_phase: f32 = 0.0,
    age: u16 = 0,
    life_frames: u16 = 60,
};

const AuroraLayer = struct {
    phase: f32,
    width: f32,
    speed: f32,
    wave: f32,
};

const RainDrop = struct {
    active: bool = false,
    lane_x: f32 = 0.0,
    y: f32 = 0.0,
    speed: f32 = 16.0,
    tail: f32 = 3.0,
    phase: f32 = 0.0,
};

const RainRipple = struct {
    active: bool = false,
    x: f32 = 0.0,
    y: f32 = 0.0,
    radius: f32 = 0.0,
    speed: f32 = 6.0,
    thickness: f32 = 0.2,
    age: u16 = 0,
    life_frames: u16 = 18,
};

const SoapBubblesPixelContext = struct {
    bubbles: []const SoapBubble,
    frame_ctx: sdf_common.FrameContext,
};

const CampfirePixelContext = struct {
    tongues: []const CampfireTongue,
    frame_ctx: sdf_common.FrameContext,
};

const AuroraRibbonsPixelContext = struct {
    layer_count: usize,
    frame_ctx: sdf_common.FrameContext,
};

const RainRipplePixelContext = struct {
    drops: []const RainDrop,
    ripples: []const RainRipple,
    frame_ctx: sdf_common.FrameContext,
};

const InfiniteLineDrawState = struct {
    pivot_x: f32,
    pivot_y: f32,
    angle: f32,
    color: Color,
};

const InfiniteLinesPixelContext = struct {
    lines: []const InfiniteLineDrawState,
    line_half_width: f32,
};

const max_effect_pixels: usize = @as(usize, tcp_client.default_display_width) * @as(usize, tcp_client.default_display_height);
const max_soap_bubbles: usize = 24;
const max_campfire_tongues: usize = 20;
const max_aurora_layers: usize = 6;
const max_rain_drops: usize = 64;
const max_rain_ripples: usize = 24;

const aurora_layers = [_]AuroraLayer{
    .{ .phase = 0.0, .width = 4.2, .speed = 0.28, .wave = 0.9 },
    .{ .phase = 1.5, .width = 3.8, .speed = 0.34, .wave = 1.2 },
    .{ .phase = 2.7, .width = 3.2, .speed = 0.22, .wave = 1.6 },
    .{ .phase = 4.0, .width = 2.9, .speed = 0.3, .wave = 1.05 },
    .{ .phase = 5.1, .width = 2.5, .speed = 0.26, .wave = 1.45 },
    .{ .phase = 6.0, .width = 2.1, .speed = 0.19, .wave = 1.8 },
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
        if (self.next_send_ns == 0) {
            self.next_send_ns = self.frame_delay_ns;
            return;
        }
        self.next_send_ns +|= self.frame_delay_ns;
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
    const draw_states = try std.heap.page_allocator.alloc(InfiniteLineDrawState, line_count);
    defer std.heap.page_allocator.free(draw_states);
    const initial_line_half_width = @as(f32, @floatFromInt(config.line_width_pixels)) / 2.0;
    const max_line_pixels = (@as(u32, display.width) * @as(u32, display.height)) / 2;
    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, display);

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
        for (states, 0..) |*state, idx| {
            if (lineCoverageExceedsLimit(display, state.pivot_x, state.pivot_y, state.angle, line_half_width, max_line_pixels_frame)) {
                state.rotation_direction = -state.rotation_direction;
                advanceLineAngleWithCoverageLimit(display, state, angular_step, line_half_width, max_line_pixels_frame);
            }
            draw_states[idx] = .{
                .pivot_x = state.pivot_x,
                .pivot_y = state.pivot_y,
                .angle = state.angle,
                .color = lerpColor(state.current_color, state.target_color, state.color_phase),
            };

            advanceLineAngleWithCoverageLimit(display, state, angular_step, line_half_width, max_line_pixels_frame);

            state.color_phase += color_step;
            if (state.color_phase >= 1.0) {
                state.current_color = state.target_color;
                state.target_color = randomBrightColor(random);
                state.color_phase -= 1.0;
            }
        }

        renderColorFrameSinglePass(display, frame, InfiniteLinesPixelContext{
            .lines = draw_states,
            .line_half_width = line_half_width,
        }, shadeInfiniteLinesPixel);
        try blitColorFrame(display, frame);
        try sendFrameWithPacing(client, display.payload(), &pacer);
    }
}

pub fn runSoapBubblesEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: SoapBubblesConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.bubble_count == 0 or config.bubble_count > max_soap_bubbles) return error.InvalidBubbleCount;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    var bubbles: [max_soap_bubbles]SoapBubble = undefined;
    for (&bubbles) |*bubble| bubble.* = .{};
    const bubble_count = @as(usize, config.bubble_count);
    for (bubbles[0..bubble_count], 0..) |*bubble, idx| {
        spawnSoapBubble(bubble, idx, display, random, true);
    }

    var frame_number: u64 = 0;
    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, display);

    while (!shouldStop(stop_flag)) {
        const ctx = try sdf_common.FrameContext.init(frame_number, @as(f32, @floatFromInt(config.frame_rate_hz)));
        updateSoapBubbles(bubbles[0..bubble_count], display, ctx, random);
        renderSoapBubblesFrame(display, frame, bubbles[0..bubble_count], ctx);
        try blitColorFrame(display, frame);
        try sendFrameWithPacing(client, display.payload(), &pacer);
        frame_number +%= 1;
    }
}

pub fn runCampfireEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: CampfireConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.tongue_count == 0 or config.tongue_count > max_campfire_tongues) return error.InvalidTongueCount;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    var tongues: [max_campfire_tongues]CampfireTongue = undefined;
    for (&tongues) |*tongue| tongue.* = .{};
    const tongue_count = @as(usize, config.tongue_count);
    for (tongues[0..tongue_count], 0..) |*tongue, idx| {
        spawnCampfireTongue(tongue, idx, display, random, true);
    }

    var frame_number: u64 = 0;
    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, display);

    while (!shouldStop(stop_flag)) {
        const ctx = try sdf_common.FrameContext.init(frame_number, @as(f32, @floatFromInt(config.frame_rate_hz)));
        updateCampfireTongues(tongues[0..tongue_count], display, ctx, random);
        renderCampfireFrame(display, frame, tongues[0..tongue_count], ctx);
        try blitColorFrame(display, frame);
        try sendFrameWithPacing(client, display.payload(), &pacer);
        frame_number +%= 1;
    }
}

pub fn runAuroraRibbonsEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: AuroraRibbonsConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.layer_count == 0 or config.layer_count > max_aurora_layers) return error.InvalidLayerCount;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var frame_number: u64 = 0;
    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, display);

    while (!shouldStop(stop_flag)) {
        const ctx = try sdf_common.FrameContext.init(frame_number, @as(f32, @floatFromInt(config.frame_rate_hz)));
        renderAuroraRibbonsFrame(display, frame, @as(usize, config.layer_count), ctx);
        try blitColorFrame(display, frame);
        try sendFrameWithPacing(client, display.payload(), &pacer);
        frame_number +%= 1;
    }
}

pub fn runRainRippleEffect(
    client: *tcp_client.TcpClient,
    display: *display_logic.DisplayBuffer,
    config: RainRippleConfig,
    stop_flag: ?*const StopFlag,
) !void {
    if (config.drop_count == 0 or config.drop_count > max_rain_drops) return error.InvalidDropCount;
    if (config.ripple_count == 0 or config.ripple_count > max_rain_ripples) return error.InvalidRippleCount;

    var pacer = try FramePacer.init(config.frame_rate_hz);
    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = prng.random();

    var drops: [max_rain_drops]RainDrop = undefined;
    var ripples: [max_rain_ripples]RainRipple = undefined;
    for (&drops) |*drop| drop.* = .{};
    for (&ripples) |*ripple| ripple.* = .{};

    const drop_count = @as(usize, config.drop_count);
    const ripple_count = @as(usize, config.ripple_count);
    for (drops[0..drop_count], 0..) |*drop, idx| {
        spawnRainDrop(drop, idx, drop_count, display, random, true);
    }

    var frame_number: u64 = 0;
    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, display);

    while (!shouldStop(stop_flag)) {
        const ctx = try sdf_common.FrameContext.init(frame_number, @as(f32, @floatFromInt(config.frame_rate_hz)));
        updateRainSystem(drops[0..drop_count], ripples[0..ripple_count], display, ctx, random);
        renderRainRippleFrame(display, frame, drops[0..drop_count], ripples[0..ripple_count], ctx);
        try blitColorFrame(display, frame);
        try sendFrameWithPacing(client, display.payload(), &pacer);
        frame_number +%= 1;
    }
}

fn effectFrameSlice(frame_storage: *[max_effect_pixels]Color, display: *const display_logic.DisplayBuffer) ![]Color {
    const required = @as(usize, @intCast(display.pixel_count));
    if (required > frame_storage.len) return error.DisplayTooLargeForEffectFrame;
    return frame_storage[0..required];
}

fn logicalPixelIndex(display: *const display_logic.DisplayBuffer, x: u16, y: u16) usize {
    return (@as(usize, y) * @as(usize, display.width)) + @as(usize, x);
}

fn clearColorFrame(frame: []Color, color: Color) void {
    for (frame) |*pixel| pixel.* = color;
}

fn renderColorFrameSinglePass(
    display: *const display_logic.DisplayBuffer,
    frame: []Color,
    context: anytype,
    comptime shadePixelFn: fn (*const display_logic.DisplayBuffer, u16, u16, f32, f32, *Color, @TypeOf(context)) void,
) void {
    clearColorFrame(frame, .{});

    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const logical_index = logicalPixelIndex(display, x, y);
            shadePixelFn(display, x, y, px, py, &frame[logical_index], context);
        }
    }
}

fn colorToRgba(color: Color) sdf_common.ColorRgba {
    return .{
        .r = @as(f32, @floatFromInt(color.r)) / 255.0,
        .g = @as(f32, @floatFromInt(color.g)) / 255.0,
        .b = @as(f32, @floatFromInt(color.b)) / 255.0,
        .a = 1.0,
    };
}

fn blendColor(pixel: *Color, src: sdf_common.ColorRgba) void {
    if (src.a <= 0.0001) return;
    const blended = sdf_common.ColorRgba.blendOver(src, colorToRgba(pixel.*));
    const rgb = blended.toRgb8();
    pixel.* = .{
        .r = rgb[0],
        .g = rgb[1],
        .b = rgb[2],
    };
}

fn blendFramePixel(frame: []Color, pixel_index: usize, src: sdf_common.ColorRgba) void {
    blendColor(&frame[pixel_index], src);
}

fn blitColorFrame(display: *display_logic.DisplayBuffer, frame: []const Color) !void {
    var encoded: [4]u8 = undefined;
    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const logical_index = logicalPixelIndex(display, x, y);
            const pixel = encodeColor(display.pixel_format, frame[logical_index], &encoded);
            try display.setPixel(@as(i32, @intCast(x)), y, pixel);
        }
    }
}

fn wrapFloat(value: f32, period: f32) f32 {
    var wrapped = @mod(value, period);
    if (wrapped < 0.0) wrapped += period;
    return wrapped;
}

fn wrappedDeltaX(px: f32, center_x: f32, width: f32) f32 {
    var dx = px - center_x;
    if (dx > width * 0.5) dx -= width;
    if (dx < -width * 0.5) dx += width;
    return dx;
}

fn spawnSoapBubble(
    bubble: *SoapBubble,
    idx: usize,
    display: *const display_logic.DisplayBuffer,
    random: std.Random,
    visible_now: bool,
) void {
    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const lane_count: f32 = 7.0;
    const lane = @as(f32, @floatFromInt(idx % 7));
    const lane_width = width_f / lane_count;
    const lane_jitter = (random.float(f32) - 0.5) * lane_width * 0.65;

    bubble.* = .{
        .active = true,
        .lane_x = wrapFloat(((lane + 0.5) * lane_width) + lane_jitter, width_f),
        .y = if (visible_now) random.float(f32) * height_f else height_f + (random.float(f32) * 5.0),
        .radius = 1.4 + (random.float(f32) * 2.4),
        .rise_speed = 5.0 + (random.float(f32) * 9.0),
        .wobble_amp = 0.2 + (random.float(f32) * 1.5),
        .wobble_freq = 0.45 + (random.float(f32) * 1.45),
        .phase = random.float(f32) * (std.math.pi * 2.0),
        .depth_phase = random.float(f32) * (std.math.pi * 2.0),
        .life_frames = 70 + @as(u16, random.int(u8)),
        .pop_duration = 2 + (random.int(u8) % 3),
    };
}

fn updateSoapBubbles(
    bubbles: []SoapBubble,
    display: *const display_logic.DisplayBuffer,
    ctx: sdf_common.FrameContext,
    random: std.Random,
) void {
    const dt = 1.0 / ctx.frame_rate_hz;
    for (bubbles, 0..) |*bubble, idx| {
        if (!bubble.active) {
            spawnSoapBubble(bubble, idx, display, random, false);
            continue;
        }

        if (bubble.popping) {
            bubble.pop_age +%= 1;
            if (bubble.pop_age >= bubble.pop_duration) {
                spawnSoapBubble(bubble, idx, display, random, false);
            }
            continue;
        }

        bubble.age +%= 1;
        bubble.y -= bubble.rise_speed * dt;
        if (bubble.age >= bubble.life_frames or bubble.y < (-bubble.radius * 1.2)) {
            bubble.popping = true;
            bubble.pop_age = 0;
        }
    }
}

fn renderSoapBubblesFrame(
    display: *const display_logic.DisplayBuffer,
    frame: []Color,
    bubbles: []const SoapBubble,
    ctx: sdf_common.FrameContext,
) void {
    renderColorFrameSinglePass(display, frame, SoapBubblesPixelContext{
        .bubbles = bubbles,
        .frame_ctx = ctx,
    }, shadeSoapBubblesPixel);
}

fn shadeSoapBubblesPixel(
    display: *const display_logic.DisplayBuffer,
    x: u16,
    y: u16,
    px: f32,
    py: f32,
    pixel: *Color,
    render_ctx: SoapBubblesPixelContext,
) void {
    _ = x;
    _ = y;
    const t = render_ctx.frame_ctx.timeSeconds();
    const width_f = @as(f32, @floatFromInt(display.width));
    inline for ([_]bool{ false, true }) |front_pass| {
        for (render_ctx.bubbles) |bubble| {
            if (!bubble.active) continue;
            const depth = std.math.sin((t * 0.75) + bubble.depth_phase);
            const is_front = depth >= 0.0;
            if (is_front != front_pass) continue;
            renderSoapBubblePixel(pixel, px, py, width_f, bubble, render_ctx.frame_ctx);
        }
    }
}

fn renderSoapBubblePixel(
    pixel: *Color,
    px: f32,
    py: f32,
    width_f: f32,
    bubble: SoapBubble,
    ctx: sdf_common.FrameContext,
) void {
    const t = ctx.timeSeconds();
    const center_x = wrapFloat(bubble.lane_x + (std.math.sin((t * bubble.wobble_freq) + bubble.phase) * bubble.wobble_amp), width_f);
    const center_y = bubble.y + (std.math.sin((t * 0.7) + (bubble.phase * 0.5)) * 0.3);
    const pop_t = if (bubble.popping and bubble.pop_duration > 0)
        @as(f32, @floatFromInt(bubble.pop_age)) / @as(f32, @floatFromInt(bubble.pop_duration))
    else
        0.0;
    const body_scale = if (bubble.popping) 1.0 - (0.55 * std.math.clamp(pop_t, 0.0, 1.0)) else 1.0;
    const body_radius = bubble.radius * body_scale;

    const local = sdf_common.Vec2.init(wrappedDeltaX(px, center_x, width_f), py - center_y);
    const d_circle = sdf_common.sdfCircle(local, body_radius);
    const shell_alpha = 1.0 - sdf_common.smoothstep(0.05, 0.85, @abs(d_circle));
    const center_alpha = (1.0 - sdf_common.smoothstep(-body_radius, 0.0, d_circle)) * 0.12;
    const highlight = sdf_common.Vec2.sub(local, sdf_common.Vec2.init(-body_radius * 0.4, body_radius * 0.34));
    const highlight_d = sdf_common.sdfCircle(highlight, body_radius * 0.23);
    const highlight_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.55, highlight_d)) * 0.26;

    var body_alpha = std.math.clamp((shell_alpha * 0.46) + center_alpha + highlight_alpha, 0.0, 0.86);
    if (bubble.popping) body_alpha *= 1.0 - std.math.clamp(pop_t, 0.0, 1.0);

    if (body_alpha > 0.0001) {
        const tint = 0.5 + (0.5 * std.math.sin((t * 0.8) + bubble.phase));
        blendColor(pixel, .{
            .r = std.math.clamp(0.66 + (0.2 * tint), 0.0, 1.0),
            .g = std.math.clamp(0.82 + (0.12 * tint), 0.0, 1.0),
            .b = 1.0,
            .a = body_alpha,
        });
    }

    if (bubble.popping) {
        const ring_radius = body_radius + ((bubble.radius + 0.8) * std.math.clamp(pop_t, 0.0, 1.0));
        const ring_width = 0.12 + ((1.0 - std.math.clamp(pop_t, 0.0, 1.0)) * 0.18);
        const ring_d = @abs(sdf_common.sdfCircle(local, ring_radius)) - ring_width;
        const ring_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.65, ring_d)) * (1.0 - std.math.clamp(pop_t, 0.0, 1.0)) * 0.85;
        if (ring_alpha > 0.0001) {
            blendColor(pixel, .{
                .r = 0.58,
                .g = 0.88,
                .b = 1.0,
                .a = ring_alpha,
            });
        }
    }
}

fn spawnCampfireTongue(
    tongue: *CampfireTongue,
    idx: usize,
    display: *const display_logic.DisplayBuffer,
    random: std.Random,
    visible_now: bool,
) void {
    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const cluster_count: f32 = 6.0;
    const lane = @as(f32, @floatFromInt(idx % 6));
    const lane_width = width_f / cluster_count;
    const jitter = (random.float(f32) - 0.5) * lane_width * 0.7;

    tongue.* = .{
        .active = true,
        .lane_x = wrapFloat(((lane + 0.5) * lane_width) + jitter, width_f),
        .y = if (visible_now) height_f - (random.float(f32) * 4.0) else height_f + (random.float(f32) * 3.0),
        .radius = 1.7 + (random.float(f32) * 1.9),
        .rise_speed = 8.0 + (random.float(f32) * 12.0),
        .drift_phase = random.float(f32) * (std.math.pi * 2.0),
        .flicker_phase = random.float(f32) * (std.math.pi * 2.0),
        .life_frames = 34 + @as(u16, random.int(u8) % 72),
    };
}

fn updateCampfireTongues(
    tongues: []CampfireTongue,
    display: *const display_logic.DisplayBuffer,
    ctx: sdf_common.FrameContext,
    random: std.Random,
) void {
    const dt = 1.0 / ctx.frame_rate_hz;
    const burst_drive = (std.math.sin(ctx.timeSeconds() * 0.9) + 1.0) * 0.5;
    const burst = sdf_common.smoothstep(0.55, 0.95, burst_drive);

    for (tongues, 0..) |*tongue, idx| {
        if (!tongue.active) {
            spawnCampfireTongue(tongue, idx, display, random, false);
            continue;
        }

        tongue.age +%= 1;
        tongue.y -= tongue.rise_speed * dt * (1.0 + (burst * 0.75));
        if (tongue.age >= tongue.life_frames or tongue.y < (-tongue.radius * 2.0)) {
            spawnCampfireTongue(tongue, idx, display, random, false);
        }
    }
}

fn renderCampfireFrame(
    display: *const display_logic.DisplayBuffer,
    frame: []Color,
    tongues: []const CampfireTongue,
    ctx: sdf_common.FrameContext,
) void {
    renderColorFrameSinglePass(display, frame, CampfirePixelContext{
        .tongues = tongues,
        .frame_ctx = ctx,
    }, shadeCampfirePixel);
}

fn shadeCampfirePixel(
    display: *const display_logic.DisplayBuffer,
    x: u16,
    y: u16,
    px: f32,
    py: f32,
    pixel: *Color,
    render_ctx: CampfirePixelContext,
) void {
    _ = y;
    const t = render_ctx.frame_ctx.timeSeconds();
    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const cluster_count: usize = 6;
    const cluster_width = width_f / @as(f32, @floatFromInt(cluster_count));
    const h_norm = py / @max(1.0, height_f - 1.0);
    const density = sdf_common.smoothstep(0.0, 1.0, h_norm);
    const burst_drive = (std.math.sin((t * 0.9) + 0.6) + 1.0) * 0.5;
    const burst = sdf_common.smoothstep(0.6, 0.95, burst_drive);

    var best_d = std.math.floatMax(f32);
    var cluster_idx: usize = 0;
    while (cluster_idx < cluster_count) : (cluster_idx += 1) {
        const cluster_phase = @as(f32, @floatFromInt(cluster_idx));
        const center_x = ((cluster_phase + 0.5) * cluster_width) + (std.math.sin((t * 0.65) + cluster_phase) * 0.55);
        const local = sdf_common.Vec2.init(wrappedDeltaX(px, center_x, width_f), py - (height_f - 1.4));
        const box_d = sdf_common.sdfBox(local, sdf_common.Vec2.init(1.6, 1.0));
        if (box_d < best_d) best_d = box_d;
    }

    const alpha = (1.0 - sdf_common.smoothstep(-0.1, 1.25, best_d)) * 0.58;
    if (alpha > 0.0001) {
        const color = campfireGradient(h_norm, 0.65);
        blendColor(pixel, .{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = alpha,
        });
    }

    for (render_ctx.tongues) |tongue| {
        if (!tongue.active) continue;
        renderCampfireTonguePixel(pixel, x, px, py, width_f, h_norm, density, t, burst, tongue);
    }
}

fn renderCampfireTonguePixel(
    pixel: *Color,
    x: u16,
    px: f32,
    py: f32,
    width_f: f32,
    h_norm: f32,
    density: f32,
    t: f32,
    burst: f32,
    tongue: CampfireTongue,
) void {
    const sway = std.math.sin((t * 5.8) + tongue.drift_phase + (py * 0.08)) * (0.45 + (0.55 * burst));
    const local = sdf_common.Vec2.init(wrappedDeltaX(px, tongue.lane_x + sway, width_f), py - tongue.y);
    const stretched = sdf_common.Vec2.init(local.x * 1.25, local.y * 0.52);
    const d_main = sdf_common.sdfCircle(stretched, tongue.radius);
    const tip = sdf_common.Vec2.sub(stretched, sdf_common.Vec2.init(0.0, tongue.radius * 0.85));
    const d_tip = sdf_common.sdfCircle(tip, tongue.radius * 0.74);
    const d = @min(d_main, d_tip);
    const body = 1.0 - sdf_common.smoothstep(0.0, 1.45, d);
    if (body <= 0.0001) return;

    const flicker = 0.55 + (0.45 * std.math.sin((t * 23.0) + tongue.flicker_phase + (@as(f32, @floatFromInt(x)) * 0.11)));
    const alpha = body * (0.18 + (density * 0.72)) * flicker;
    const color = campfireGradient(h_norm, density * (0.6 + (0.4 * flicker)));
    blendColor(pixel, .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = std.math.clamp(alpha, 0.0, 0.98),
    });

    const hot = body * density * sdf_common.smoothstep(0.72, 1.0, flicker) * 0.27;
    if (hot > 0.0001) {
        blendColor(pixel, .{
            .r = 1.0,
            .g = 0.95,
            .b = 0.82,
            .a = hot,
        });
    }
}

fn campfireGradient(height_norm: f32, heat: f32) sdf_common.ColorRgba {
    const h = sdf_common.clamp01(height_norm);
    const clamped_heat = sdf_common.clamp01(heat);

    if (h >= 0.62) {
        const t = sdf_common.remapLinear(h, 0.62, 1.0, 0.0, 1.0);
        return .{
            .r = std.math.clamp(0.78 + (0.22 * t) + (0.1 * clamped_heat), 0.0, 1.0),
            .g = std.math.clamp(0.18 + (0.64 * t), 0.0, 1.0),
            .b = std.math.clamp(0.02 + (0.08 * t), 0.0, 1.0),
            .a = 1.0,
        };
    }
    if (h >= 0.28) {
        const t = sdf_common.remapLinear(h, 0.28, 0.62, 0.0, 1.0);
        return .{
            .r = std.math.clamp(0.55 + (0.4 * t) + (0.08 * clamped_heat), 0.0, 1.0),
            .g = std.math.clamp(0.32 + (0.52 * t), 0.0, 1.0),
            .b = std.math.clamp(0.06 + (0.18 * t), 0.0, 1.0),
            .a = 1.0,
        };
    }
    const t = sdf_common.remapLinear(h, 0.0, 0.28, 0.0, 1.0);
    return .{
        .r = std.math.clamp(0.1 + (0.2 * (1.0 - t)) + (0.05 * clamped_heat), 0.0, 1.0),
        .g = std.math.clamp(0.18 + (0.3 * (1.0 - t)), 0.0, 1.0),
        .b = std.math.clamp(0.42 + (0.43 * (1.0 - t)), 0.0, 1.0),
        .a = 1.0,
    };
}

fn renderAuroraRibbonsFrame(
    display: *const display_logic.DisplayBuffer,
    frame: []Color,
    layer_count: usize,
    ctx: sdf_common.FrameContext,
) void {
    renderColorFrameSinglePass(display, frame, AuroraRibbonsPixelContext{
        .layer_count = layer_count,
        .frame_ctx = ctx,
    }, shadeAuroraRibbonsPixel);
}

fn shadeAuroraRibbonsPixel(
    display: *const display_logic.DisplayBuffer,
    x: u16,
    y: u16,
    px: f32,
    py: f32,
    pixel: *Color,
    render_ctx: AuroraRibbonsPixelContext,
) void {
    _ = x;
    _ = y;
    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const two_pi = std.math.pi * 2.0;
    const t = render_ctx.frame_ctx.timeSeconds();
    const theta = (px / width_f) * two_pi;

    var layer_idx: usize = 0;
    while (layer_idx < render_ctx.layer_count) : (layer_idx += 1) {
        const layer = aurora_layers[layer_idx];
        const alpha_scale = 0.16 + (@as(f32, @floatFromInt(layer_idx)) * 0.05);
        const centerline = auroraLayerCenterline(theta, render_ctx.frame_ctx, layer, height_f);
        const breathing = std.math.sin((t * 0.35) + layer.phase + (@as(f32, @floatFromInt(layer_idx)) * 0.4));
        const thickness = layer.width + (breathing * 0.9);
        const band_local = sdf_common.Vec2.init(0.0, py - centerline);
        const band_d = sdf_common.sdfBox(band_local, sdf_common.Vec2.init(width_f, thickness));
        const band_alpha = (1.0 - sdf_common.smoothstep(0.0, 1.9, band_d)) * alpha_scale;
        if (band_alpha > 0.0001) {
            const hue_phase = (t * 0.2) + layer.phase + theta;
            blendColor(pixel, .{
                .r = 0.18 + (0.22 * (0.5 + (0.5 * std.math.sin(hue_phase + 2.0)))),
                .g = 0.42 + (0.46 * (0.5 + (0.5 * std.math.sin(hue_phase)))),
                .b = 0.46 + (0.42 * (0.5 + (0.5 * std.math.sin(hue_phase + 4.0)))),
                .a = band_alpha,
            });
        }

        const accent_center = centerline + (std.math.sin((theta * 4.0) + (t * 0.55) + layer.phase) * 1.3);
        const accent_d = sdf_common.sdfBox(
            sdf_common.Vec2.init(0.0, py - accent_center),
            sdf_common.Vec2.init(width_f, @max(0.4, thickness * 0.26)),
        );
        const crest = sdf_common.smoothstep(0.55, 1.0, std.math.sin((theta * 2.0) + (t * 0.5) + layer.phase));
        const accent_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.95, accent_d)) * crest * 0.2;
        if (accent_alpha > 0.0001) {
            blendColor(pixel, .{
                .r = 0.88,
                .g = 0.9,
                .b = 0.95,
                .a = accent_alpha,
            });
        }
    }
}

fn auroraLayerCenterline(theta: f32, ctx: sdf_common.FrameContext, layer: AuroraLayer, height: f32) f32 {
    const t = ctx.timeSeconds();
    const warp = std.math.sin((theta * 3.0) + (t * 0.12) + (layer.phase * 0.5)) * (0.22 * layer.wave);
    const flow = std.math.sin(theta + (t * layer.speed) + layer.phase + warp);
    const sweep = std.math.sin((theta * 2.0) - (t * (0.22 + (layer.speed * 0.15))) + (layer.phase * 0.7) + warp);
    const base = 0.5 + (0.34 * flow) + (0.08 * warp);
    return ((1.0 - base) * (height - 1.0)) + (sweep * 2.9);
}

fn spawnRainDrop(
    drop: *RainDrop,
    idx: usize,
    drop_count: usize,
    display: *const display_logic.DisplayBuffer,
    random: std.Random,
    visible_now: bool,
) void {
    const width_f = @as(f32, @floatFromInt(display.width));
    const height_f = @as(f32, @floatFromInt(display.height));
    const lanes = @as(f32, @floatFromInt(drop_count));
    const lane_width = width_f / @max(1.0, lanes);
    const lane = @as(f32, @floatFromInt(idx)) + 0.5;
    const jitter = (random.float(f32) - 0.5) * lane_width * 0.6;

    drop.* = .{
        .active = true,
        .lane_x = wrapFloat((lane * lane_width) + jitter, width_f),
        .y = if (visible_now) random.float(f32) * height_f else -(random.float(f32) * height_f),
        .speed = 10.0 + (random.float(f32) * 22.0),
        .tail = 1.8 + (random.float(f32) * 3.8),
        .phase = random.float(f32) * (std.math.pi * 2.0),
    };
}

fn spawnRainRipple(ripples: []RainRipple, x: f32, y: f32, random: std.Random) void {
    var selected_idx: ?usize = null;
    var oldest_idx: usize = 0;
    var oldest_age: u16 = 0;

    for (ripples, 0..) |ripple, idx| {
        if (!ripple.active) {
            selected_idx = idx;
            break;
        }
        if (ripple.age >= oldest_age) {
            oldest_age = ripple.age;
            oldest_idx = idx;
        }
    }

    const target = selected_idx orelse oldest_idx;
    ripples[target] = .{
        .active = true,
        .x = x,
        .y = y,
        .radius = 0.2,
        .speed = 4.8 + (random.float(f32) * 3.6),
        .thickness = 0.18 + (random.float(f32) * 0.24),
        .age = 0,
        .life_frames = 14 + @as(u16, random.int(u8) % 18),
    };
}

fn updateRainSystem(
    drops: []RainDrop,
    ripples: []RainRipple,
    display: *const display_logic.DisplayBuffer,
    ctx: sdf_common.FrameContext,
    random: std.Random,
) void {
    const dt = 1.0 / ctx.frame_rate_hz;
    const height_f = @as(f32, @floatFromInt(display.height));
    const impact_y = height_f - 2.0;
    const burst_mix = (std.math.sin(ctx.timeSeconds() * 0.45) + 1.0) * 0.5;
    const drizzle_target = @as(f32, @floatFromInt(drops.len)) * 0.45;
    const burst_target = @as(f32, @floatFromInt(drops.len)) * 0.95;
    const active_drop_count = std.math.clamp(
        @as(usize, @intFromFloat(@floor(sdf_common.remapLinear(burst_mix, 0.0, 1.0, drizzle_target, burst_target)))),
        @as(usize, 1),
        drops.len,
    );

    for (drops, 0..) |*drop, idx| {
        if (!drop.active) {
            spawnRainDrop(drop, idx, drops.len, display, random, false);
        }
        if (idx >= active_drop_count) {
            drop.y = -drop.tail - @as(f32, @floatFromInt(idx % 5));
            continue;
        }

        drop.y += drop.speed * dt * (0.65 + (burst_mix * 0.9));
        if (drop.y >= impact_y) {
            spawnRainRipple(ripples, drop.lane_x, impact_y, random);
            spawnRainDrop(drop, idx, drops.len, display, random, false);
            continue;
        }

        if (drop.y - drop.tail > height_f + 1.0) {
            spawnRainDrop(drop, idx, drops.len, display, random, false);
        }
    }

    for (ripples) |*ripple| {
        if (!ripple.active) continue;
        ripple.age +%= 1;
        ripple.radius += ripple.speed * dt;
        if (ripple.age >= ripple.life_frames) ripple.active = false;
    }
}

fn renderRainRippleFrame(
    display: *const display_logic.DisplayBuffer,
    frame: []Color,
    drops: []const RainDrop,
    ripples: []const RainRipple,
    ctx: sdf_common.FrameContext,
) void {
    renderColorFrameSinglePass(display, frame, RainRipplePixelContext{
        .drops = drops,
        .ripples = ripples,
        .frame_ctx = ctx,
    }, shadeRainRipplePixel);
}

fn shadeRainRipplePixel(
    display: *const display_logic.DisplayBuffer,
    x: u16,
    y: u16,
    px: f32,
    py: f32,
    pixel: *Color,
    render_ctx: RainRipplePixelContext,
) void {
    _ = x;
    const width_f = @as(f32, @floatFromInt(display.width));
    const t = render_ctx.frame_ctx.timeSeconds();
    for (render_ctx.drops) |drop| {
        if (!drop.active) continue;
        renderRainDropPixel(pixel, y, px, py, width_f, drop, render_ctx.ripples, t);
    }
    for (render_ctx.ripples) |ripple| {
        if (!ripple.active) continue;
        renderRainRipplePixel(pixel, px, py, width_f, ripple);
    }
}

fn renderRainDropPixel(
    pixel: *Color,
    y: u16,
    px: f32,
    py: f32,
    width_f: f32,
    drop: RainDrop,
    ripples: []const RainRipple,
    t: f32,
) void {
    const dx = wrappedDeltaX(px, drop.lane_x, width_f);
    const streak_center = drop.y - (drop.tail * 0.5);
    const streak_box = sdf_common.sdfBox(
        sdf_common.Vec2.init(dx, py - streak_center),
        sdf_common.Vec2.init(0.18, drop.tail * 0.5),
    );
    const streak_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.75, streak_box)) * 0.36;
    const head_circle = sdf_common.sdfCircle(sdf_common.Vec2.init(dx, py - drop.y), 0.4);
    const head_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.55, head_circle)) * 0.48;

    var ripple_boost: f32 = 0.0;
    for (ripples) |ripple| {
        if (!ripple.active or ripple.life_frames == 0) continue;
        const local = sdf_common.Vec2.init(wrappedDeltaX(px, ripple.x, width_f), py - ripple.y);
        const dist = local.length();
        const proximity = 1.0 - sdf_common.smoothstep(ripple.radius + 0.2, ripple.radius + 2.0, dist);
        const fade = 1.0 - (@as(f32, @floatFromInt(ripple.age)) / @as(f32, @floatFromInt(ripple.life_frames)));
        ripple_boost = @max(ripple_boost, proximity * fade);
    }

    const twinkle = 0.75 + (0.25 * std.math.sin((t * 13.0) + drop.phase + (@as(f32, @floatFromInt(y)) * 0.22)));
    const alpha = (streak_alpha + head_alpha) * twinkle * (1.0 + (0.9 * ripple_boost));
    if (alpha <= 0.0001) return;

    blendColor(pixel, .{
        .r = std.math.clamp(0.62 + (0.2 * ripple_boost), 0.0, 1.0),
        .g = std.math.clamp(0.76 + (0.18 * ripple_boost), 0.0, 1.0),
        .b = 1.0,
        .a = std.math.clamp(alpha, 0.0, 0.9),
    });
}

fn renderRainRipplePixel(
    pixel: *Color,
    px: f32,
    py: f32,
    width_f: f32,
    ripple: RainRipple,
) void {
    if (ripple.life_frames == 0) return;
    const fade = 1.0 - (@as(f32, @floatFromInt(ripple.age)) / @as(f32, @floatFromInt(ripple.life_frames)));
    const clamped_fade = sdf_common.clamp01(fade);

    const local = sdf_common.Vec2.init(wrappedDeltaX(px, ripple.x, width_f), py - ripple.y);
    const ring_d = @abs(sdf_common.sdfCircle(local, ripple.radius)) - ripple.thickness;
    const ring_alpha = (1.0 - sdf_common.smoothstep(0.0, 0.8, ring_d)) * clamped_fade * 0.68;
    if (ring_alpha > 0.0001) {
        blendColor(pixel, .{
            .r = 0.35,
            .g = 0.78,
            .b = 1.0,
            .a = ring_alpha,
        });
    }

    const glow_d = sdf_common.sdfCircle(local, (ripple.radius * 0.35) + 0.75);
    const glow_alpha = (1.0 - sdf_common.smoothstep(0.0, 2.4, glow_d)) * clamped_fade * 0.12;
    if (glow_alpha > 0.0001) {
        blendColor(pixel, .{
            .r = 0.18,
            .g = 0.4,
            .b = 0.7,
            .a = glow_alpha,
        });
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

fn shadeInfiniteLinesPixel(
    display: *const display_logic.DisplayBuffer,
    x: u16,
    y: u16,
    px: f32,
    py: f32,
    pixel: *Color,
    render_ctx: InfiniteLinesPixelContext,
) void {
    _ = x;
    _ = y;
    const width_f = @as(f32, @floatFromInt(display.width));
    for (render_ctx.lines) |line| {
        const direction_x = std.math.cos(line.angle);
        const direction_y = std.math.sin(line.angle);
        const normal_x = -direction_y;
        const normal_y = direction_x;
        const distance = wrappedLineDistance(px, py, line.pivot_x, line.pivot_y, normal_x, normal_y, width_f);
        if (distance <= render_ctx.line_half_width) {
            pixel.* = line.color;
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

test "frame pacer markSent keeps cadence when frame completion is late" {
    var pacer = try FramePacer.init(40);
    const delay = pacer.frame_delay_ns;
    try std.testing.expectEqual(@as(u64, 0), pacer.next_send_ns);

    pacer.markSent();
    try std.testing.expectEqual(delay, pacer.next_send_ns);

    pacer.markSent();
    try std.testing.expectEqual(delay * 2, pacer.next_send_ns);
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

test "wrappedDeltaX returns shortest seam-safe x distance" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), wrappedDeltaX(0.2, 29.6, 30.0), 0.0001);
}

test "soap bubble lifecycle reaches pop then respawns" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 30,
        .height = 40,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    const bubble = SoapBubble{
        .active = true,
        .lane_x = 3.0,
        .y = 1.0,
        .radius = 1.0,
        .rise_speed = 0.0,
        .age = 1,
        .life_frames = 1,
        .pop_duration = 2,
    };
    var bubbles = [_]SoapBubble{bubble};
    var prng = std.Random.DefaultPrng.init(0x1234_0000);
    const random = prng.random();

    const ctx0 = try sdf_common.FrameContext.init(0, 40.0);
    updateSoapBubbles(bubbles[0..], &display, ctx0, random);
    try std.testing.expect(bubbles[0].popping);

    const ctx1 = try sdf_common.FrameContext.init(1, 40.0);
    updateSoapBubbles(bubbles[0..], &display, ctx1, random);
    try std.testing.expect(bubbles[0].popping);

    const ctx2 = try sdf_common.FrameContext.init(2, 40.0);
    updateSoapBubbles(bubbles[0..], &display, ctx2, random);
    try std.testing.expect(!bubbles[0].popping);
    try std.testing.expect(bubbles[0].y > @as(f32, @floatFromInt(display.height)));
}

test "campfire gradient cools toward blue at top" {
    const bottom = campfireGradient(0.95, 1.0);
    const top = campfireGradient(0.05, 0.2);
    try std.testing.expect(bottom.r > top.r);
    try std.testing.expect(top.b > bottom.b);
}

test "aurora centerline is periodic at seam" {
    const ctx = try sdf_common.FrameContext.init(12, 40.0);
    const seam_a = auroraLayerCenterline(0.0, ctx, aurora_layers[1], 40.0);
    const seam_b = auroraLayerCenterline(std.math.pi * 2.0, ctx, aurora_layers[1], 40.0);
    try std.testing.expectApproxEqAbs(seam_a, seam_b, 0.0001);
}

test "rain drop impact spawns ripple" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 30,
        .height = 40,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    var drops = [_]RainDrop{
        .{
            .active = true,
            .lane_x = 10.0,
            .y = 39.0,
            .speed = 0.0,
            .tail = 2.0,
            .phase = 0.0,
        },
    };
    var ripples = [_]RainRipple{.{}};
    var prng = std.Random.DefaultPrng.init(0x5555_1234);
    const random = prng.random();
    const ctx = try sdf_common.FrameContext.init(0, 40.0);

    updateRainSystem(drops[0..], ripples[0..], &display, ctx, random);
    try std.testing.expect(ripples[0].active);
}

test "aurora frame renderer produces lit pixels" {
    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 30,
        .height = 40,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    var frame_storage: [max_effect_pixels]Color = undefined;
    const frame = try effectFrameSlice(&frame_storage, &display);
    const ctx = try sdf_common.FrameContext.init(0, 40.0);
    renderAuroraRibbonsFrame(&display, frame, 4, ctx);

    var lit = false;
    for (frame) |pixel| {
        if (pixel.r != 0 or pixel.g != 0 or pixel.b != 0) {
            lit = true;
            break;
        }
    }
    try std.testing.expect(lit);
}
