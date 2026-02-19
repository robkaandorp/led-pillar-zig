const std = @import("std");
const tcp_client = @import("tcp_client.zig");

const FrameHeader = struct {
    protocol_version: u8,
    pixel_format: tcp_client.PixelFormat,
    payload_len: usize,
};

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

const SimulatorStats = struct {
    timer: std.time.Timer,
    total_frames: u64 = 0,
    total_bytes: u64 = 0,
    window_frames: u64 = 0,
    window_bytes: u64 = 0,
    window_start_ns: u64 = 0,
    fps_x10: u64 = 0,
    bytes_per_sec: u64 = 0,

    fn init() !SimulatorStats {
        return .{ .timer = try std.time.Timer.start() };
    }

    fn recordFrame(self: *SimulatorStats, frame_bytes: usize) void {
        const bytes = @as(u64, @intCast(frame_bytes));
        self.total_frames += 1;
        self.total_bytes += bytes;
        self.window_frames += 1;
        self.window_bytes += bytes;

        const now = self.timer.read();
        const elapsed = now - self.window_start_ns;
        if (elapsed >= @as(u64, std.time.ns_per_s)) {
            self.fps_x10 = ratePerSecond(self.window_frames, elapsed, 10);
            self.bytes_per_sec = ratePerSecond(self.window_bytes, elapsed, 1);
            self.window_frames = 0;
            self.window_bytes = 0;
            self.window_start_ns = now;
        }
    }
};

pub fn runServer(port: u16, width: u16, height: u16) !void {
    if (width == 0 or height == 0) return error.InvalidDimensions;

    const expected_pixels = try std.math.mul(u32, @as(u32, width), @as(u32, height));
    const max_payload_len = try std.math.mul(usize, @as(usize, expected_pixels), 4);
    const payload_buffer = try std.heap.page_allocator.alloc(u8, max_payload_len);
    defer std.heap.page_allocator.free(payload_buffer);

    var address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Simulator listening on 0.0.0.0:{d}\n", .{port});
    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();
        std.debug.print("Client connected: {any}\n", .{connection.address});
        serveConnection(&connection.stream, width, height, expected_pixels, payload_buffer) catch |err| {
            if (err != error.EndOfStream) {
                std.debug.print("Connection closed with error: {any}\n", .{err});
            }
        };
    }
}

fn serveConnection(
    stream: *std.net.Stream,
    width: u16,
    height: u16,
    expected_pixels: u32,
    payload_buffer: []u8,
) !void {
    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&reader_buffer);
    var header_buf: [tcp_client.header_len]u8 = undefined;
    var first_frame = true;
    var stats = try SimulatorStats.init();

    while (true) {
        readExact(&reader, header_buf[0..]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const header = try parseHeader(header_buf[0..], expected_pixels);
        if (header.payload_len > payload_buffer.len) return error.FrameTooLarge;

        try readExact(&reader, payload_buffer[0..header.payload_len]);
        stats.recordFrame(tcp_client.header_len + header.payload_len);
        try renderFrame(width, height, header.pixel_format, payload_buffer[0..header.payload_len], &stats, first_frame);
        if (header.protocol_version == tcp_client.protocol_version) {
            try stream.writeAll(&[_]u8{tcp_client.ack_byte});
        }
        first_frame = false;
    }
}

fn readExact(reader: *std.net.Stream.Reader, buffer: []u8) !void {
    reader.interface().readSliceAll(buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.getError() orelse error.Unexpected,
        else => return err,
    };
}

fn parseHeader(header: []const u8, expected_pixels: u32) !FrameHeader {
    if (header.len != tcp_client.header_len) return error.InvalidHeaderLength;
    if (!std.mem.eql(u8, header[0..4], "LEDS")) return error.InvalidMagic;
    const protocol_version = header[4];
    switch (protocol_version) {
        0x01, tcp_client.protocol_version => {},
        else => return error.UnsupportedProtocolVersion,
    }

    const count: u32 = (@as(u32, header[5]) << 24) |
        (@as(u32, header[6]) << 16) |
        (@as(u32, header[7]) << 8) |
        @as(u32, header[8]);
    if (count != expected_pixels) return error.UnexpectedPixelCount;

    const pixel_format = try parsePixelFormat(header[9]);
    const payload_len = try std.math.mul(usize, @as(usize, count), pixel_format.bytesPerPixel());
    return .{
        .protocol_version = protocol_version,
        .pixel_format = pixel_format,
        .payload_len = payload_len,
    };
}

fn parsePixelFormat(value: u8) !tcp_client.PixelFormat {
    return switch (value) {
        0 => .rgb,
        1 => .rgbw,
        2 => .grb,
        3 => .grbw,
        4 => .bgr,
        else => error.UnsupportedPixelFormat,
    };
}

fn renderFrame(
    width: u16,
    height: u16,
    format: tcp_client.PixelFormat,
    payload: []const u8,
    stats: *const SimulatorStats,
    clear_screen: bool,
) !void {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (clear_screen) {
        try stdout.writeAll("\x1b[2J");
    }
    try stdout.writeAll("\x1b[H");

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const index = physicalPixelIndex(height, x, y);
            const offset = @as(usize, index) * format.bytesPerPixel();
            const rgb = decodePixel(format, payload[offset .. offset + format.bytesPerPixel()]);
            try stdout.print("\x1b[48;2;{d};{d};{d}m  ", .{ rgb.r, rgb.g, rgb.b });
        }
        try stdout.writeAll("\x1b[0m\n");
    }
    const fps_whole = stats.fps_x10 / 10;
    const fps_tenths = stats.fps_x10 % 10;
    try stdout.print(
        "\x1b[0mFPS: {d}.{d}  Bytes/s: {d}  Frames: {d}  Total bytes: {d}\x1b[K\n",
        .{ fps_whole, fps_tenths, stats.bytes_per_sec, stats.total_frames, stats.total_bytes },
    );
    try stdout.writeAll("\x1b[0m");
    try stdout.flush();
}

fn physicalPixelIndex(height: u16, x: u16, y: u16) u32 {
    const row = if ((x & 1) == 0) y else height - 1 - y;
    return @as(u32, x) * @as(u32, height) + @as(u32, row);
}

fn decodePixel(format: tcp_client.PixelFormat, pixel: []const u8) Rgb {
    return switch (format) {
        .rgb => .{ .r = pixel[0], .g = pixel[1], .b = pixel[2] },
        .grb => .{ .r = pixel[1], .g = pixel[0], .b = pixel[2] },
        .bgr => .{ .r = pixel[2], .g = pixel[1], .b = pixel[0] },
        .rgbw => .{
            .r = pixel[0] +| pixel[3],
            .g = pixel[1] +| pixel[3],
            .b = pixel[2] +| pixel[3],
        },
        .grbw => .{
            .r = pixel[1] +| pixel[3],
            .g = pixel[0] +| pixel[3],
            .b = pixel[2] +| pixel[3],
        },
    };
}

fn ratePerSecond(count: u64, elapsed_ns: u64, scale: u64) u64 {
    if (elapsed_ns == 0) return 0;
    return (count * scale * @as(u64, std.time.ns_per_s)) / elapsed_ns;
}

test "parseHeader validates and extracts payload details" {
    const expected_pixels: u32 = 1200;
    const header = [_]u8{ 'L', 'E', 'D', 'S', 1, 0, 0, 4, 176, 0 };
    const parsed = try parseHeader(header[0..], expected_pixels);
    try std.testing.expectEqual(@as(u8, 1), parsed.protocol_version);
    try std.testing.expectEqual(tcp_client.PixelFormat.rgb, parsed.pixel_format);
    try std.testing.expectEqual(@as(usize, 3600), parsed.payload_len);
}

test "parseHeader accepts protocol v2" {
    const header = [_]u8{ 'L', 'E', 'D', 'S', tcp_client.protocol_version, 0, 0, 4, 176, 0 };
    const parsed = try parseHeader(header[0..], 1200);
    try std.testing.expectEqual(tcp_client.protocol_version, parsed.protocol_version);
}

test "parseHeader rejects invalid magic" {
    const header = [_]u8{ 'B', 'A', 'D', '!', 1, 0, 0, 4, 176, 0 };
    try std.testing.expectError(error.InvalidMagic, parseHeader(header[0..], 1200));
}

test "physicalPixelIndex uses serpentine mapping" {
    try std.testing.expectEqual(@as(u32, 0), physicalPixelIndex(4, 0, 0));
    try std.testing.expectEqual(@as(u32, 7), physicalPixelIndex(4, 1, 0));
    try std.testing.expectEqual(@as(u32, 4), physicalPixelIndex(4, 1, 3));
}

test "decodePixel maps RGBW white into RGB channels" {
    const rgb = decodePixel(.rgbw, &[_]u8{ 10, 20, 30, 40 });
    try std.testing.expectEqual(@as(u8, 50), rgb.r);
    try std.testing.expectEqual(@as(u8, 60), rgb.g);
    try std.testing.expectEqual(@as(u8, 70), rgb.b);
}

test "ratePerSecond computes scaled values" {
    try std.testing.expectEqual(@as(u64, 400), ratePerSecond(40, @as(u64, std.time.ns_per_s), 10));
    try std.testing.expectEqual(@as(u64, 8000), ratePerSecond(8000, @as(u64, std.time.ns_per_s), 1));
}
