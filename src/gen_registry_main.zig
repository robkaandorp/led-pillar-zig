const std = @import("std");
const led = @import("led_pillar_zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var args = try std.process.argsWithAllocator(arena.allocator());
    _ = args.next(); // skip argv[0]
    const dsl_dir = args.next() orelse return error.MissingDslDir;
    const output_dir = args.next() orelse return error.MissingOutputDir;
    try led.build_shader_registry.generate(std.heap.page_allocator, dsl_dir, output_dir);
}
