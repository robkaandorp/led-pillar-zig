const std = @import("std");
const tcp_client = @import("tcp_client.zig");

pub const Config = struct {
    width: u16 = tcp_client.default_display_width,
    height: u16 = tcp_client.default_display_height,
    pixel_format: tcp_client.PixelFormat = .rgb,
};

pub const DisplayBuffer = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    pixel_format: tcp_client.PixelFormat,
    bytes_per_pixel: usize,
    pixel_count: u32,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !DisplayBuffer {
        if (config.width == 0 or config.height == 0) return error.InvalidDimensions;

        const pixel_count = try std.math.mul(u32, @as(u32, config.width), @as(u32, config.height));
        const bytes_per_pixel = config.pixel_format.bytesPerPixel();
        const payload_len = try std.math.mul(usize, @as(usize, pixel_count), bytes_per_pixel);
        const buffer = try allocator.alloc(u8, payload_len);

        return .{
            .allocator = allocator,
            .width = config.width,
            .height = config.height,
            .pixel_format = config.pixel_format,
            .bytes_per_pixel = bytes_per_pixel,
            .pixel_count = pixel_count,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *DisplayBuffer) void {
        self.allocator.free(self.buffer);
    }

    pub fn clear(self: *DisplayBuffer, value: u8) void {
        @memset(self.buffer, value);
    }

    pub fn payload(self: *const DisplayBuffer) []const u8 {
        return self.buffer;
    }

    pub fn payloadMut(self: *DisplayBuffer) []u8 {
        return self.buffer;
    }

    pub fn physicalPixelIndex(self: *const DisplayBuffer, x: i32, y: u16) !u32 {
        if (y >= self.height) return error.YOutOfBounds;

        const column = self.wrapX(x);
        const row = if ((column & 1) == 0) y else self.height - 1 - y;
        const base = try std.math.mul(u32, @as(u32, column), @as(u32, self.height));
        return base + @as(u32, row);
    }

    pub fn pixelOffset(self: *const DisplayBuffer, x: i32, y: u16) !usize {
        const index = try self.physicalPixelIndex(x, y);
        return std.math.mul(usize, @as(usize, index), self.bytes_per_pixel);
    }

    pub fn setPixel(self: *DisplayBuffer, x: i32, y: u16, pixel: []const u8) !void {
        if (pixel.len != self.bytes_per_pixel) return error.InvalidPixelLength;

        const offset = try self.pixelOffset(x, y);
        @memcpy(self.buffer[offset .. offset + self.bytes_per_pixel], pixel);
    }

    pub fn wrapX(self: *const DisplayBuffer, x: i32) u16 {
        const width_i32 = @as(i32, @intCast(self.width));
        const wrapped = @mod(x, width_i32);
        return @as(u16, @intCast(wrapped));
    }
};

test "serpentine physicalPixelIndex maps even and odd columns" {
    var display = try DisplayBuffer.init(std.testing.allocator, .{
        .width = 3,
        .height = 4,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    try std.testing.expectEqual(@as(u32, 0), try display.physicalPixelIndex(0, 0));
    try std.testing.expectEqual(@as(u32, 3), try display.physicalPixelIndex(0, 3));
    try std.testing.expectEqual(@as(u32, 7), try display.physicalPixelIndex(1, 0));
    try std.testing.expectEqual(@as(u32, 4), try display.physicalPixelIndex(1, 3));
    try std.testing.expectEqual(@as(u32, 9), try display.physicalPixelIndex(2, 1));
}

test "horizontal wrap-around is applied to x" {
    var display = try DisplayBuffer.init(std.testing.allocator, .{
        .width = 3,
        .height = 2,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    try std.testing.expectEqual(@as(u32, 0), try display.physicalPixelIndex(3, 0));
    try std.testing.expectEqual(@as(u32, 4), try display.physicalPixelIndex(-1, 0));
}

test "setPixel writes data at serpentine offset" {
    var display = try DisplayBuffer.init(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixel_format = .rgb,
    });
    defer display.deinit();
    display.clear(0);

    const pixel = [_]u8{ 1, 2, 3 };
    try display.setPixel(1, 0, pixel[0..]);

    const offset = try display.pixelOffset(1, 0);
    try std.testing.expectEqual(@as(usize, 9), offset);
    try std.testing.expectEqualSlices(u8, pixel[0..], display.payload()[offset .. offset + 3]);
}

test "setPixel validates pixel length" {
    var display = try DisplayBuffer.init(std.testing.allocator, .{});
    defer display.deinit();

    var short_pixel: [2]u8 = .{ 1, 2 };
    try std.testing.expectError(error.InvalidPixelLength, display.setPixel(0, 0, short_pixel[0..]));
}

test "physicalPixelIndex rejects out-of-bounds y" {
    var display = try DisplayBuffer.init(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    try std.testing.expectError(error.YOutOfBounds, display.physicalPixelIndex(0, 2));
}

test "init rejects invalid dimensions" {
    try std.testing.expectError(error.InvalidDimensions, DisplayBuffer.init(std.testing.allocator, .{
        .width = 0,
    }));
}
