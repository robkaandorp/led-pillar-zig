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
    }
}

fn clearDisplayOnExit(client: *led.TcpClient, display: *led.DisplayBuffer) !void {
    try led.effects.fillSolid(display, .{});
    try client.sendFrame(display.payload());
    try client.finishPendingFrame();
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
}

test "parseMaybeU16 returns null for non-numeric strings" {
    try std.testing.expectEqual(@as(?u16, 123), try parseMaybeU16("123"));
    try std.testing.expectEqual(@as(?u16, null), try parseMaybeU16("running-dot"));
}
