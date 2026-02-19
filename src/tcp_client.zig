const std = @import("std");

pub const default_display_height: u16 = 40;
pub const default_display_width: u16 = 30;
pub const default_frame_rate_hz: u16 = 40;
pub const default_port: u16 = 7777;

pub const protocol_version: u8 = 0x02;
pub const ack_byte: u8 = 0x06;
pub const header_len: usize = 10;

pub const PixelFormat = enum(u8) {
    rgb = 0,
    rgbw = 1,
    grb = 2,
    grbw = 3,
    bgr = 4,

    pub fn bytesPerPixel(self: PixelFormat) usize {
        return switch (self) {
            .rgb, .grb, .bgr => 3,
            .rgbw, .grbw => 4,
        };
    }
};

pub const Config = struct {
    host: []const u8,
    port: u16 = default_port,
    width: u16 = default_display_width,
    height: u16 = default_display_height,
    frame_rate_hz: u16 = default_frame_rate_hz,
    pixel_format: PixelFormat = .rgb,
};

pub const TcpClient = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    port: u16,
    width: u16,
    height: u16,
    frame_rate_hz: u16,
    pixel_format: PixelFormat,
    pixel_count: u32,
    payload_len: usize,
    frame_buffer: []u8,
    stream: ?std.net.Stream = null,
    pending_ack: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) !TcpClient {
        if (config.width == 0 or config.height == 0) return error.InvalidDimensions;
        if (config.frame_rate_hz == 0) return error.InvalidFrameRate;

        const pixel_count = try std.math.mul(u32, @as(u32, config.width), @as(u32, config.height));
        const payload_len = try std.math.mul(usize, @as(usize, pixel_count), config.pixel_format.bytesPerPixel());
        const frame_len = header_len + payload_len;

        const host_copy = try allocator.dupe(u8, config.host);
        errdefer allocator.free(host_copy);

        const frame_buffer = try allocator.alloc(u8, frame_len);
        errdefer allocator.free(frame_buffer);

        var client = TcpClient{
            .allocator = allocator,
            .host = host_copy,
            .port = config.port,
            .width = config.width,
            .height = config.height,
            .frame_rate_hz = config.frame_rate_hz,
            .pixel_format = config.pixel_format,
            .pixel_count = pixel_count,
            .payload_len = payload_len,
            .frame_buffer = frame_buffer,
        };
        client.writeHeader();
        return client;
    }

    pub fn deinit(self: *TcpClient) void {
        self.disconnect();
        self.allocator.free(self.frame_buffer);
        self.allocator.free(self.host);
    }

    pub fn connect(self: *TcpClient) !void {
        if (self.stream != null) return;
        self.stream = try std.net.tcpConnectToHost(self.allocator, self.host, self.port);
        self.pending_ack = false;
    }

    pub fn disconnect(self: *TcpClient) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        self.pending_ack = false;
    }

    pub fn sendFrame(self: *TcpClient, pixels: []const u8) !void {
        if (pixels.len != self.payload_len) return error.InvalidFrameLength;
        const stream = self.stream orelse return error.NotConnected;
        try self.waitForPendingAck(stream);

        @memcpy(self.frame_buffer[header_len..], pixels);
        try stream.writeAll(self.frame_buffer);
        self.pending_ack = true;
    }

    pub fn finishPendingFrame(self: *TcpClient) !void {
        const stream = self.stream orelse return error.NotConnected;
        try self.waitForPendingAck(stream);
    }

    pub fn expectedPayloadLen(self: *const TcpClient) usize {
        return self.payload_len;
    }

    pub fn expectedPacketLen(self: *const TcpClient) usize {
        return self.frame_buffer.len;
    }

    fn writeHeader(self: *TcpClient) void {
        const header = self.frame_buffer[0..header_len];
        header[0] = 'L';
        header[1] = 'E';
        header[2] = 'D';
        header[3] = 'S';
        header[4] = protocol_version;
        header[5] = @as(u8, @intCast((self.pixel_count >> 24) & 0xff));
        header[6] = @as(u8, @intCast((self.pixel_count >> 16) & 0xff));
        header[7] = @as(u8, @intCast((self.pixel_count >> 8) & 0xff));
        header[8] = @as(u8, @intCast(self.pixel_count & 0xff));
        header[9] = @intFromEnum(self.pixel_format);
    }

    fn waitForPendingAck(self: *TcpClient, stream: std.net.Stream) !void {
        if (!self.pending_ack) return;
        var ack: [1]u8 = undefined;
        try readExact(stream, ack[0..]);
        self.pending_ack = false;
        if (ack[0] != ack_byte) return error.InvalidAck;
    }

    fn readExact(stream: std.net.Stream, buffer: []u8) !void {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const bytes_read = try stream.read(buffer[offset..]);
            if (bytes_read == 0) return error.EndOfStream;
            offset += bytes_read;
        }
    }
};

test "pixel format bytes per pixel" {
    try std.testing.expectEqual(@as(usize, 3), PixelFormat.rgb.bytesPerPixel());
    try std.testing.expectEqual(@as(usize, 4), PixelFormat.rgbw.bytesPerPixel());
}

test "client init builds packet header" {
    var client = try TcpClient.init(std.testing.allocator, .{ .host = "127.0.0.1" });
    defer client.deinit();

    const expected_pixels = @as(usize, default_display_width) * @as(usize, default_display_height);
    try std.testing.expectEqual(expected_pixels * 3, client.expectedPayloadLen());
    try std.testing.expectEqual(header_len + client.expectedPayloadLen(), client.expectedPacketLen());

    const header = client.frame_buffer[0..header_len];
    try std.testing.expectEqualSlices(u8, "LEDS", header[0..4]);
    try std.testing.expectEqual(protocol_version, header[4]);
    try std.testing.expectEqual(@as(u8, 0), header[5]);
    try std.testing.expectEqual(@as(u8, 0), header[6]);
    try std.testing.expectEqual(@as(u8, 4), header[7]);
    try std.testing.expectEqual(@as(u8, 176), header[8]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PixelFormat.rgb)), header[9]);
}

test "client init rejects invalid dimensions" {
    try std.testing.expectError(error.InvalidDimensions, TcpClient.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .width = 0,
    }));
}

test "client init rejects zero frame rate" {
    try std.testing.expectError(error.InvalidFrameRate, TcpClient.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .frame_rate_hz = 0,
    }));
}

test "sendFrame validates payload size" {
    var client = try TcpClient.init(std.testing.allocator, .{ .host = "127.0.0.1" });
    defer client.deinit();

    var short_frame: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidFrameLength, client.sendFrame(short_frame[0..]));
}

test "sendFrame requires active connection" {
    var client = try TcpClient.init(std.testing.allocator, .{ .host = "127.0.0.1" });
    defer client.deinit();

    const frame = try std.testing.allocator.alloc(u8, client.expectedPayloadLen());
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);

    try std.testing.expectError(error.NotConnected, client.sendFrame(frame));
}

test "disconnect clears pending ack state" {
    var client = try TcpClient.init(std.testing.allocator, .{ .host = "127.0.0.1" });
    defer client.deinit();

    client.pending_ack = true;
    client.disconnect();
    try std.testing.expect(!client.pending_ack);
}
