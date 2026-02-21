const std = @import("std");
const builtin = @import("builtin");
const led = @import("led_pillar_zig");

var shutdown_requested: led.effects.StopFlag = .init(false);

const EffectKind = enum {
    demo,
    health_test,
    running_dot,
    soap_bubbles,
    campfire,
    aurora_ribbons,
    rain_ripple,
    infinite_line,
    infinite_lines,
    dsl_file,
};

const RunConfig = struct {
    host: []const u8,
    port: u16 = led.tcp_client.default_port,
    frame_rate_hz: u16 = led.default_frame_rate_hz,
    effect: EffectKind = .demo,
    health_hold_seconds: u64 = 1,
    infinite_line_count: u16 = 4,
    infinite_rotation_period_seconds: u16 = 18,
    infinite_color_transition_seconds: u16 = 10,
    infinite_line_width_pixels: u16 = 1,
    dsl_file_path: ?[]const u8 = null,
};

pub fn main() !void {
    shutdown_requested.store(false, .seq_cst);

    if (builtin.os.tag == .windows) {
        try std.os.windows.SetConsoleCtrlHandler(windowsCtrlHandler, true);
        defer std.os.windows.SetConsoleCtrlHandler(windowsCtrlHandler, false) catch {};
    } else {
        var previous_sigint: std.posix.Sigaction = undefined;
        var previous_sigterm: std.posix.Sigaction = undefined;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = posixCtrlHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, &previous_sigint);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &previous_sigterm);
        defer {
            std.posix.sigaction(std.posix.SIG.TERM, &previous_sigterm, null);
            std.posix.sigaction(std.posix.SIG.INT, &previous_sigint, null);
        }
    }

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    const run_config = try parseRunConfig(&args);

    var client = try led.TcpClient.init(std.heap.page_allocator, .{
        .host = run_config.host,
        .port = run_config.port,
        .width = led.display_width,
        .height = led.display_height,
        .frame_rate_hz = run_config.frame_rate_hz,
        .pixel_format = .rgb,
    });
    defer client.deinit();

    var display = try led.DisplayBuffer.init(std.heap.page_allocator, .{
        .width = led.display_width,
        .height = led.display_height,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    try client.connect();
    defer client.disconnect();
    defer clearDisplayOnExit(&client, &display) catch |err| {
        std.debug.print("warning: failed to clear display on exit: {s}\n", .{@errorName(err)});
    };

    switch (run_config.effect) {
        .demo => try led.effects.runPixelHealthThenRunningPixel(&client, &display, .{
            .hold_seconds = run_config.health_hold_seconds,
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .health_test => try led.effects.runPixelHealthEffect(&client, &display, .{
            .hold_seconds = run_config.health_hold_seconds,
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .running_dot => try led.effects.runRunningDotEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .soap_bubbles => try led.effects.runSoapBubblesEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .campfire => try led.effects.runCampfireEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .aurora_ribbons => try led.effects.runAuroraRibbonsEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .rain_ripple => try led.effects.runRainRippleEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
        }, &shutdown_requested),
        .infinite_line => try led.effects.runInfiniteLineEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
            .rotation_period_seconds = run_config.infinite_rotation_period_seconds,
            .color_transition_seconds = run_config.infinite_color_transition_seconds,
            .line_width_pixels = run_config.infinite_line_width_pixels,
        }, &shutdown_requested),
        .infinite_lines => try led.effects.runInfiniteLinesEffect(&client, &display, .{
            .frame_rate_hz = run_config.frame_rate_hz,
            .line_count = run_config.infinite_line_count,
            .rotation_period_seconds = run_config.infinite_rotation_period_seconds,
            .color_transition_seconds = run_config.infinite_color_transition_seconds,
            .line_width_pixels = run_config.infinite_line_width_pixels,
        }, &shutdown_requested),
        .dsl_file => try runDslFileEffect(
            &client,
            &display,
            run_config.frame_rate_hz,
            run_config.dsl_file_path orelse return error.MissingDslPath,
            &shutdown_requested,
        ),
    }
}

fn clearDisplayOnExit(client: *led.TcpClient, display: *led.DisplayBuffer) !void {
    try led.effects.fillSolid(display, .{});
    try client.sendFrame(display.payload());
    try client.finishPendingFrame();
}

fn runDslFileEffect(
    client: *led.TcpClient,
    display: *led.DisplayBuffer,
    frame_rate_hz: u16,
    dsl_file_path: []const u8,
    stop_flag: *const led.effects.StopFlag,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), dsl_file_path, std.math.maxInt(usize));
    const program = try led.dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try led.dsl_runtime.Evaluator.init(std.heap.page_allocator, program);
    defer evaluator.deinit();
    try writeDslBytecodeReference(&evaluator, dsl_file_path);

    const pixel_count = @as(usize, @intCast(display.pixel_count));
    const frame = try std.heap.page_allocator.alloc(led.effects.Color, pixel_count);
    defer std.heap.page_allocator.free(frame);

    const frame_period_ns_i128 = @as(i128, @intCast(std.time.ns_per_s / @as(u64, frame_rate_hz)));
    const frame_rate_f = @as(f32, @floatFromInt(frame_rate_hz));
    var frame_number: u64 = 0;
    var next_send_ns = std.time.nanoTimestamp();

    while (!stop_flag.load(.seq_cst)) {
        const now = std.time.nanoTimestamp();
        if (now < next_send_ns) {
            std.Thread.sleep(@as(u64, @intCast(next_send_ns - now)));
        }

        try evaluator.renderFrame(display, frame, frame_number, frame_rate_f);
        try blitDslFrameToDisplay(display, frame);
        try client.sendFrame(display.payload());

        frame_number +%= 1;
        next_send_ns += frame_period_ns_i128;
    }
}

fn writeDslBytecodeReference(evaluator: *const led.dsl_runtime.Evaluator, dsl_file_path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const script_basename = std.fs.path.basename(dsl_file_path);
    const stem = std.fs.path.stem(script_basename);
    const bin_name = try std.fmt.allocPrint(allocator, "{s}.bin", .{stem});
    defer allocator.free(bin_name);
    const output_path = try std.fs.path.join(allocator, &[_][]const u8{ "bytecode", bin_name });
    defer allocator.free(output_path);

    try std.fs.cwd().makePath("bytecode");
    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;
    try evaluator.writeBytecodeBinary(writer);
    try writer.flush();
}

fn blitDslFrameToDisplay(display: *led.DisplayBuffer, frame: []const led.effects.Color) !void {
    const required = @as(usize, @intCast(display.pixel_count));
    if (frame.len < required) return error.InvalidFrameBufferLength;

    var encoded: [4]u8 = undefined;
    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const idx = (@as(usize, y) * @as(usize, display.width)) + @as(usize, x);
            const pixel = encodeFrameColor(display.pixel_format, frame[idx], &encoded);
            try display.setPixel(@as(i32, @intCast(x)), y, pixel);
        }
    }
}

fn encodeFrameColor(format: led.PixelFormat, color: led.effects.Color, output: *[4]u8) []const u8 {
    return switch (format) {
        .rgb => blk: {
            output[0] = color.r;
            output[1] = color.g;
            output[2] = color.b;
            break :blk output[0..3];
        },
        .rgbw => blk: {
            output[0] = color.r;
            output[1] = color.g;
            output[2] = color.b;
            output[3] = color.w;
            break :blk output[0..4];
        },
        .grb => blk: {
            output[0] = color.g;
            output[1] = color.r;
            output[2] = color.b;
            break :blk output[0..3];
        },
        .grbw => blk: {
            output[0] = color.g;
            output[1] = color.r;
            output[2] = color.b;
            output[3] = color.w;
            break :blk output[0..4];
        },
        .bgr => blk: {
            output[0] = color.b;
            output[1] = color.g;
            output[2] = color.r;
            break :blk output[0..3];
        },
    };
}

fn windowsCtrlHandler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    switch (ctrl_type) {
        std.os.windows.CTRL_C_EVENT,
        std.os.windows.CTRL_BREAK_EVENT,
        std.os.windows.CTRL_CLOSE_EVENT,
        std.os.windows.CTRL_LOGOFF_EVENT,
        std.os.windows.CTRL_SHUTDOWN_EVENT,
        => {
            shutdown_requested.store(true, .seq_cst);
            return std.os.windows.TRUE;
        },
        else => return std.os.windows.FALSE,
    }
}

fn posixCtrlHandler(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn parseRunConfig(args: anytype) !RunConfig {
    _ = args.next();
    const host = args.next() orelse return error.MissingHost;

    var run_config = RunConfig{
        .host = host,
    };

    var pending_effect_or_param = args.next();
    if (pending_effect_or_param) |value| {
        if (try parseMaybeU16(value)) |parsed_port| {
            run_config.port = parsed_port;
            pending_effect_or_param = args.next();
        }
    }

    if (pending_effect_or_param) |value| {
        if (try parseMaybeU16(value)) |parsed_fps| {
            run_config.frame_rate_hz = parsed_fps;
            pending_effect_or_param = args.next();
        }
    }

    if (pending_effect_or_param) |effect_arg| {
        run_config.effect = try parseEffectKind(effect_arg);
    }

    switch (run_config.effect) {
        .demo, .running_dot, .soap_bubbles, .campfire, .aurora_ribbons, .rain_ripple => {
            if (args.next() != null) return error.TooManyArguments;
        },
        .health_test => {
            if (args.next()) |hold_arg| {
                run_config.health_hold_seconds = try std.fmt.parseInt(u64, hold_arg, 10);
            }
            if (args.next() != null) return error.TooManyArguments;
        },
        .infinite_line => {
            if (args.next()) |rotation_arg| {
                run_config.infinite_rotation_period_seconds = try std.fmt.parseInt(u16, rotation_arg, 10);
            }
            if (args.next()) |color_arg| {
                run_config.infinite_color_transition_seconds = try std.fmt.parseInt(u16, color_arg, 10);
            }
            if (args.next()) |line_width_arg| {
                run_config.infinite_line_width_pixels = try std.fmt.parseInt(u16, line_width_arg, 10);
            }
            if (args.next() != null) return error.TooManyArguments;
        },
        .infinite_lines => {
            if (args.next()) |line_count_arg| {
                run_config.infinite_line_count = try std.fmt.parseInt(u16, line_count_arg, 10);
            }
            if (args.next()) |rotation_arg| {
                run_config.infinite_rotation_period_seconds = try std.fmt.parseInt(u16, rotation_arg, 10);
            }
            if (args.next()) |color_arg| {
                run_config.infinite_color_transition_seconds = try std.fmt.parseInt(u16, color_arg, 10);
            }
            if (args.next()) |line_width_arg| {
                run_config.infinite_line_width_pixels = try std.fmt.parseInt(u16, line_width_arg, 10);
            }
            if (args.next() != null) return error.TooManyArguments;
        },
        .dsl_file => {
            run_config.dsl_file_path = args.next() orelse return error.MissingDslPath;
            if (args.next() != null) return error.TooManyArguments;
        },
    }

    return run_config;
}

fn parseEffectKind(effect_arg: []const u8) !EffectKind {
    if (std.mem.eql(u8, effect_arg, "demo")) return .demo;
    if (std.mem.eql(u8, effect_arg, "health-test")) return .health_test;
    if (std.mem.eql(u8, effect_arg, "running-dot")) return .running_dot;
    if (std.mem.eql(u8, effect_arg, "soap-bubbles")) return .soap_bubbles;
    if (std.mem.eql(u8, effect_arg, "campfire")) return .campfire;
    if (std.mem.eql(u8, effect_arg, "aurora-ribbons")) return .aurora_ribbons;
    if (std.mem.eql(u8, effect_arg, "rain-ripple")) return .rain_ripple;
    if (std.mem.eql(u8, effect_arg, "infinite-line")) return .infinite_line;
    if (std.mem.eql(u8, effect_arg, "infinite-lines")) return .infinite_lines;
    if (std.mem.eql(u8, effect_arg, "dsl-file")) return .dsl_file;
    return error.UnknownEffect;
}

fn parseMaybeU16(arg: []const u8) !?u16 {
    return std.fmt.parseInt(u16, arg, 10) catch |err| switch (err) {
        error.InvalidCharacter => null,
        else => err,
    };
}

test "parseEffectKind accepts known effect names" {
    try std.testing.expectEqual(.demo, try parseEffectKind("demo"));
    try std.testing.expectEqual(.health_test, try parseEffectKind("health-test"));
    try std.testing.expectEqual(.running_dot, try parseEffectKind("running-dot"));
    try std.testing.expectEqual(.soap_bubbles, try parseEffectKind("soap-bubbles"));
    try std.testing.expectEqual(.campfire, try parseEffectKind("campfire"));
    try std.testing.expectEqual(.aurora_ribbons, try parseEffectKind("aurora-ribbons"));
    try std.testing.expectEqual(.rain_ripple, try parseEffectKind("rain-ripple"));
    try std.testing.expectEqual(.infinite_line, try parseEffectKind("infinite-line"));
    try std.testing.expectEqual(.infinite_lines, try parseEffectKind("infinite-lines"));
    try std.testing.expectEqual(.dsl_file, try parseEffectKind("dsl-file"));
}

test "parseMaybeU16 returns null for non-numeric strings" {
    try std.testing.expectEqual(@as(?u16, 123), try parseMaybeU16("123"));
    try std.testing.expectEqual(@as(?u16, null), try parseMaybeU16("running-dot"));
}

const TestArgs = struct {
    values: []const []const u8,
    index: usize = 0,

    fn next(self: *TestArgs) ?[]const u8 {
        if (self.index >= self.values.len) return null;
        const value = self.values[self.index];
        self.index += 1;
        return value;
    }
};

test "parseRunConfig parses dsl-file mode" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "127.0.0.1", "dsl-file", "examples\\dsl\\v1\\aurora.dsl" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.dsl_file, run_config.effect);
    try std.testing.expectEqualStrings("examples\\dsl\\v1\\aurora.dsl", run_config.dsl_file_path.?);
}

test "parseRunConfig dsl-file requires path" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "127.0.0.1", "dsl-file" },
    };
    try std.testing.expectError(error.MissingDslPath, parseRunConfig(&args));
}

test "parseRunConfig dsl-file rejects extra args" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "127.0.0.1", "dsl-file", "effect.dsl", "extra" },
    };
    try std.testing.expectError(error.TooManyArguments, parseRunConfig(&args));
}
