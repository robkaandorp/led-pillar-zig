const std = @import("std");
const builtin = @import("builtin");
const led = @import("led_pillar_zig");

var shutdown_requested: led.effects.StopFlag = .init(false);

pub fn main() !void {
    shutdown_requested.store(false, .seq_cst);
    var restore_posix_handlers = false;
    var previous_sigint: std.posix.Sigaction = undefined;
    var previous_sigterm: std.posix.Sigaction = undefined;

    defer if (restore_posix_handlers) {
        std.posix.sigaction(std.posix.SIG.TERM, &previous_sigterm, null);
        std.posix.sigaction(std.posix.SIG.INT, &previous_sigint, null);
    };

    if (builtin.os.tag == .windows) {
        try std.os.windows.SetConsoleCtrlHandler(windowsCtrlHandler, true);
        defer std.os.windows.SetConsoleCtrlHandler(windowsCtrlHandler, false) catch {};
    } else {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = posixCtrlHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, &previous_sigint);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &previous_sigterm);
        restore_posix_handlers = true;
    }

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next();
    const host = args.next() orelse return error.MissingHost;
    const port = if (args.next()) |port_arg| try std.fmt.parseInt(u16, port_arg, 10) else led.tcp_client.default_port;
    const frame_rate_hz = if (args.next()) |fps_arg| try std.fmt.parseInt(u16, fps_arg, 10) else led.default_frame_rate_hz;

    var client = try led.TcpClient.init(std.heap.page_allocator, .{
        .host = host,
        .port = port,
        .width = led.display_width,
        .height = led.display_height,
        .frame_rate_hz = frame_rate_hz,
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

    try led.effects.runPixelHealthThenRunningPixel(&client, &display, .{
        .hold_seconds = 1,
        .frame_rate_hz = frame_rate_hz,
    }, &shutdown_requested);
}

fn clearDisplayOnExit(client: *led.TcpClient, display: *led.DisplayBuffer) !void {
    try led.effects.fillSolid(display, .{});
    try client.sendFrame(display.payload());
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
