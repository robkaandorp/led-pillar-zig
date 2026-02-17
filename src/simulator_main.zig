const std = @import("std");
const led = @import("led_pillar_zig");

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next();
    const port = if (args.next()) |port_arg| try std.fmt.parseInt(u16, port_arg, 10) else led.tcp_client.default_port;
    try led.simulator.runServer(port, led.display_width, led.display_height);
}
