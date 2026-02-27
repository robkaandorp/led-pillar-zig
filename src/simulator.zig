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

const EmittedShaderColor = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const ShaderEvalPixelFn = *const fn (f32, f32, f32, f32, f32, f32, f32, *EmittedShaderColor) callconv(.c) void;
const ShaderEvalFrameFn = *const fn (f32, f32) callconv(.c) void;

const ShaderRegistryEntry = extern struct {
    name: [*:0]const u8,
    folder: [*:0]const u8,
    eval_pixel: ShaderEvalPixelFn,
    has_frame_func: c_int,
    eval_frame: ?ShaderEvalFrameFn,
};

extern const dsl_shader_registry_count: c_int;
extern fn dsl_shader_find(name: [*:0]const u8) ?*const ShaderRegistryEntry;
extern fn dsl_shader_get(index: c_int) ?*const ShaderRegistryEntry;

const ShaderSource = enum {
    none,
    bytecode,
    native,
};

const V3State = struct {
    lock: std.Thread.Mutex = .{},
    default_shader_persisted: bool = false,
    has_uploaded_program: bool = false,
    shader_active: bool = false,
    default_shader_faulted: bool = false,
    bytecode_blob_len: u32 = 0,
    shader_slow_frame_count: u32 = 0,
    shader_last_slow_frame_ms: u32 = 0,
    shader_frame_count: u32 = 0,
    shader_source: ShaderSource = .none,
    seed: f32 = 0.0,
    active_shader: ?*const ShaderRegistryEntry = null,
};

const ShaderRenderContext = struct {
    width: u16,
    height: u16,
    payload: []u8,
    state: *V3State,
    render_lock: *std.Thread.Mutex,
    stop_flag: *const std.atomic.Value(bool),
};

const v3_protocol_version: u8 = 0x03;
const v3_cmd_upload_bytecode: u8 = 0x01;
const v3_cmd_activate_shader: u8 = 0x02;
const v3_cmd_set_default_hook: u8 = 0x03;
const v3_cmd_clear_default_hook: u8 = 0x04;
const v3_cmd_query_default_hook: u8 = 0x05;
const v3_cmd_upload_firmware: u8 = 0x06;
const v3_cmd_activate_native_shader: u8 = 0x07;
const v3_cmd_stop_shader: u8 = 0x08;
const v3_response_flag: u8 = 0x80;

const v3_status_ok: u8 = 0;
const v3_status_invalid_arg: u8 = 1;
const v3_status_unsupported_cmd: u8 = 2;
const v3_status_too_large: u8 = 3;
const v3_status_not_ready: u8 = 4;
const v3_status_vm_error: u8 = 5;
const v3_status_internal: u8 = 6;

const v3_status_payload_len: usize = 20;
const v3_max_bytecode_blob: usize = 64 * 1024;
const shader_frame_interval_ns: u64 = 25 * std.time.ns_per_ms;

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

    // Log available shaders from the registry
    const count = @as(usize, @intCast(dsl_shader_registry_count));
    std.debug.print("Shader registry: {d} shaders available\n", .{count});
    for (0..count) |i| {
        if (dsl_shader_get(@intCast(i))) |entry| {
            std.debug.print("  [{d}] {s} (folder: {s})\n", .{ i, entry.name, entry.folder });
        }
    }

    const expected_pixels = try std.math.mul(u32, @as(u32, width), @as(u32, height));
    const frame_payload_len = try std.math.mul(usize, @as(usize, expected_pixels), 4);
    const max_payload_len = @max(frame_payload_len, v3_max_bytecode_blob);
    const payload_buffer = try std.heap.page_allocator.alloc(u8, max_payload_len);
    defer std.heap.page_allocator.free(payload_buffer);
    const shader_payload_len = try std.math.mul(usize, @as(usize, expected_pixels), 3);
    const shader_payload = try std.heap.page_allocator.alloc(u8, shader_payload_len);
    defer std.heap.page_allocator.free(shader_payload);

    var v3_state = V3State{};
    var render_lock: std.Thread.Mutex = .{};
    var shader_stop = std.atomic.Value(bool).init(false);
    var shader_ctx = ShaderRenderContext{
        .width = width,
        .height = height,
        .payload = shader_payload,
        .state = &v3_state,
        .render_lock = &render_lock,
        .stop_flag = &shader_stop,
    };
    var shader_thread = try std.Thread.spawn(.{}, shaderRenderLoop, .{&shader_ctx});
    defer {
        shader_stop.store(true, .seq_cst);
        shader_thread.join();
    }

    var address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Simulator listening on 0.0.0.0:{d}\n", .{port});
    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();
        std.debug.print("Client connected: {any}\n", .{connection.address});
        serveConnection(&connection.stream, width, height, expected_pixels, payload_buffer, &v3_state, &render_lock) catch |err| {
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
    v3_state: *V3State,
    render_lock: *std.Thread.Mutex,
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

        if (!std.mem.eql(u8, header_buf[0..4], "LEDS")) return error.InvalidMagic;
        const protocol_version = header_buf[4];
        if (protocol_version == v3_protocol_version) {
            const payload_len_u32 = readBeU32(header_buf[5..9]);
            const payload_len: usize = @intCast(payload_len_u32);
            const cmd = header_buf[9];

            if (payload_len > payload_buffer.len) {
                try drainExact(&reader, payload_len);
                try sendV3Response(stream, cmd, v3_status_too_large, &.{});
                continue;
            }
            if (payload_len > 0) {
                try readExact(&reader, payload_buffer[0..payload_len]);
            }
            try handleV3Message(stream, v3_state, cmd, payload_buffer[0..payload_len]);
            continue;
        }

        const header = try parseHeader(header_buf[0..], expected_pixels);
        if (header.payload_len > payload_buffer.len) return error.FrameTooLarge;

        try readExact(&reader, payload_buffer[0..header.payload_len]);
        stats.recordFrame(tcp_client.header_len + header.payload_len);
        {
            render_lock.lock();
            defer render_lock.unlock();
            try renderFrame(width, height, header.pixel_format, payload_buffer[0..header.payload_len], &stats, first_frame);
        }
        if (header.protocol_version == tcp_client.protocol_version) {
            try stream.writeAll(&[_]u8{tcp_client.ack_byte});
        }
        first_frame = false;
    }
}

fn handleV3Message(stream: *std.net.Stream, state: *V3State, cmd: u8, payload: []const u8) !void {
    var response_payload: [v3_status_payload_len]u8 = undefined;
    var response_len: usize = 0;
    const status = switch (cmd) {
        v3_cmd_upload_bytecode => handleV3Upload(state, payload),
        v3_cmd_activate_shader => if (payload.len == 0) handleV3Activate(state, .bytecode, null) else v3_status_invalid_arg,
        v3_cmd_set_default_hook => handleV3SetHook(state, payload),
        v3_cmd_clear_default_hook => handleV3ClearHook(state, payload),
        v3_cmd_query_default_hook => handleV3Query(state, payload, response_payload[0..], &response_len),
        v3_cmd_activate_native_shader => handleV3ActivateNative(state, payload),
        v3_cmd_stop_shader => handleV3Stop(state, payload),
        v3_cmd_upload_firmware => v3_status_unsupported_cmd,
        else => v3_status_unsupported_cmd,
    };

    try sendV3Response(stream, cmd, status, response_payload[0..response_len]);
}

fn handleV3Upload(state: *V3State, payload: []const u8) u8 {
    if (payload.len == 0) return v3_status_invalid_arg;
    if (payload.len > v3_max_bytecode_blob) return v3_status_too_large;

    state.lock.lock();
    defer state.lock.unlock();
    state.has_uploaded_program = true;
    state.bytecode_blob_len = @intCast(payload.len);
    state.shader_active = false;
    state.shader_source = .none;
    return v3_status_ok;
}

fn handleV3ActivateNative(state: *V3State, payload: []const u8) u8 {
    if (payload.len == 0) {
        // No name: activate first shader
        const first = dsl_shader_get(0) orelse return v3_status_not_ready;
        return handleV3Activate(state, .native, first);
    }
    // Payload contains a null-terminated shader name
    const name_end = std.mem.indexOfScalar(u8, payload, 0) orelse payload.len;
    if (name_end == 0) {
        const first = dsl_shader_get(0) orelse return v3_status_not_ready;
        return handleV3Activate(state, .native, first);
    }

    // Build null-terminated name on the stack
    if (name_end > 255) return v3_status_invalid_arg;
    var name_buf: [256]u8 = undefined;
    @memcpy(name_buf[0..name_end], payload[0..name_end]);
    name_buf[name_end] = 0;
    const name_z: [*:0]const u8 = @ptrCast(&name_buf);

    const entry = dsl_shader_find(name_z) orelse return v3_status_invalid_arg;
    return handleV3Activate(state, .native, entry);
}

fn handleV3Activate(state: *V3State, source: ShaderSource, shader: ?*const ShaderRegistryEntry) u8 {
    state.lock.lock();
    defer state.lock.unlock();
    if (source == .bytecode and !state.has_uploaded_program) return v3_status_not_ready;
    state.shader_active = true;
    state.shader_source = source;
    state.seed = generateSimulatorSeed();
    state.shader_slow_frame_count = 0;
    state.shader_last_slow_frame_ms = 0;
    state.shader_frame_count = 0;
    if (source == .native) {
        state.active_shader = shader;
    }
    return v3_status_ok;
}

fn generateSimulatorSeed() f32 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const raw = std.mem.readInt(u32, &buf, .little);
    return @as(f32, @floatFromInt(raw >> 8)) / 16777216.0;
}

fn handleV3SetHook(state: *V3State, payload: []const u8) u8 {
    if (payload.len != 0) return v3_status_invalid_arg;

    state.lock.lock();
    defer state.lock.unlock();
    if (!state.has_uploaded_program or state.bytecode_blob_len == 0) return v3_status_not_ready;
    state.default_shader_persisted = true;
    state.default_shader_faulted = false;
    return v3_status_ok;
}

fn handleV3ClearHook(state: *V3State, payload: []const u8) u8 {
    if (payload.len != 0) return v3_status_invalid_arg;

    state.lock.lock();
    defer state.lock.unlock();
    state.default_shader_persisted = false;
    state.default_shader_faulted = false;
    return v3_status_ok;
}

fn handleV3Stop(state: *V3State, payload: []const u8) u8 {
    if (payload.len != 0) return v3_status_invalid_arg;

    state.lock.lock();
    defer state.lock.unlock();
    state.shader_active = false;
    state.shader_source = .none;
    state.shader_slow_frame_count = 0;
    state.shader_last_slow_frame_ms = 0;
    state.shader_frame_count = 0;
    return v3_status_ok;
}

fn handleV3Query(state: *V3State, payload: []const u8, response_payload: []u8, out_len: *usize) u8 {
    if (payload.len != 0) return v3_status_invalid_arg;
    if (response_payload.len < v3_status_payload_len) return v3_status_internal;

    state.lock.lock();
    defer state.lock.unlock();
    response_payload[0] = @intFromBool(state.default_shader_persisted);
    response_payload[1] = @intFromBool(state.has_uploaded_program);
    response_payload[2] = @intFromBool(state.shader_active);
    response_payload[3] = @intFromBool(state.default_shader_faulted);
    writeBeU32(response_payload[4..8], state.bytecode_blob_len);
    writeBeU32(response_payload[8..12], state.shader_slow_frame_count);
    writeBeU32(response_payload[12..16], state.shader_last_slow_frame_ms);
    writeBeU32(response_payload[16..20], state.shader_frame_count);
    out_len.* = v3_status_payload_len;
    return v3_status_ok;
}

fn sendV3Response(stream: *std.net.Stream, cmd: u8, status: u8, payload: []const u8) !void {
    if (payload.len > std.math.maxInt(u32) - 1) return error.PayloadTooLarge;

    var header = [_]u8{ 'L', 'E', 'D', 'S', v3_protocol_version, 0, 0, 0, 0, cmd | v3_response_flag };
    writeBeU32(header[5..9], @as(u32, @intCast(payload.len + 1)));
    try stream.writeAll(&header);
    try stream.writeAll(&[_]u8{status});
    if (payload.len > 0) {
        try stream.writeAll(payload);
    }
}

fn shaderRenderLoop(context: *ShaderRenderContext) void {
    var stats = SimulatorStats.init() catch return;
    var timer = std.time.Timer.start() catch return;
    var frame_counter: u32 = 0;
    var was_rendering = false;
    var clear_screen = true;
    var next_deadline_ns: u64 = timer.read() + shader_frame_interval_ns;

    while (!context.stop_flag.load(.seq_cst)) {
        const frame_start_ns = timer.read();

        var should_render = false;
        var current_seed: f32 = 0.0;
        var current_shader: ?*const ShaderRegistryEntry = null;
        {
            context.state.lock.lock();
            defer context.state.lock.unlock();
            should_render = context.state.shader_active and context.state.shader_source != .none;
            if (!should_render) {
                frame_counter = 0;
                context.state.shader_frame_count = 0;
            } else {
                current_seed = context.state.seed;
                current_shader = context.state.active_shader;
            }
        }

        if (should_render) {
            if (!was_rendering) {
                clear_screen = true;
            }
            const eval_pixel: ?ShaderEvalPixelFn = if (current_shader) |s| s.eval_pixel else blk: {
                if (dsl_shader_get(0)) |first| break :blk first.eval_pixel;
                break :blk null;
            };
            if (eval_pixel) |pixel_fn| {
                const time_seconds: f32 = @floatCast(@as(f64, @floatFromInt(frame_start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
                renderEmittedShaderFrame(
                    context.width,
                    context.height,
                    time_seconds,
                    frame_counter,
                    current_seed,
                    context.payload,
                    pixel_fn,
                );
            }
            stats.recordFrame(tcp_client.header_len + context.payload.len);

            context.render_lock.lock();
            _ = renderFrame(
                context.width,
                context.height,
                .rgb,
                context.payload,
                &stats,
                clear_screen,
            ) catch {};
            context.render_lock.unlock();

            clear_screen = false;
            const frame_elapsed_ns = timer.read() - frame_start_ns;

            context.state.lock.lock();
            if (frame_elapsed_ns > 200 * std.time.ns_per_ms) {
                const slow_ms = frame_elapsed_ns / std.time.ns_per_ms;
                context.state.shader_last_slow_frame_ms = @intCast(@min(slow_ms, @as(u64, std.math.maxInt(u32))));
                context.state.shader_slow_frame_count +%= 1;
            }
            frame_counter +%= 1;
            context.state.shader_frame_count = frame_counter;
            context.state.lock.unlock();
            was_rendering = true;
        } else {
            if (was_rendering) {
                @memset(context.payload, 0);
                stats.recordFrame(tcp_client.header_len + context.payload.len);
                context.render_lock.lock();
                _ = renderFrame(
                    context.width,
                    context.height,
                    .rgb,
                    context.payload,
                    &stats,
                    true,
                ) catch {};
                context.render_lock.unlock();
                clear_screen = true;
            }
            was_rendering = false;
        }

        // Use absolute deadline timing to avoid Windows sleep granularity drift.
        // Relative timing (sleep(interval - elapsed)) loses time because Windows
        // sleep rounds up to ~15.6ms timer resolution, reducing FPS to ~30.
        // Absolute deadlines self-correct: overshoot in one frame shortens the
        // next sleep, maintaining the target FPS on average.
        const now_ns = timer.read();
        if (now_ns < next_deadline_ns) {
            std.Thread.sleep(next_deadline_ns - now_ns);
        } else {
            std.Thread.yield() catch {};
        }
        next_deadline_ns += shader_frame_interval_ns;
    }
}

fn renderEmittedShaderFrame(width: u16, height: u16, time_seconds: f32, frame_counter: u32, seed: f32, payload: []u8, eval_pixel: ShaderEvalPixelFn) void {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const required_len = pixel_count * 3;
    if (payload.len < required_len) return;

    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    const frame_f: f32 = @floatFromInt(frame_counter);
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            var color = EmittedShaderColor{ .r = 0, .g = 0, .b = 0, .a = 0 };
            eval_pixel(
                time_seconds,
                frame_f,
                @floatFromInt(x),
                @floatFromInt(y),
                width_f,
                height_f,
                seed,
                &color,
            );
            const offset = @as(usize, physicalPixelIndex(height, x, y)) * 3;
            payload[offset] = channelToU8(color.r);
            payload[offset + 1] = channelToU8(color.g);
            payload[offset + 2] = channelToU8(color.b);
        }
    }
}

fn channelToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const scaled = clamped * 255.0 + 0.5;
    const rounded: u32 = @intFromFloat(scaled);
    return @intCast(@min(rounded, @as(u32, 255)));
}

fn drainExact(reader: *std.net.Stream.Reader, len: usize) !void {
    var remaining = len;
    var scratch: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, scratch.len);
        try readExact(reader, scratch[0..chunk]);
        remaining -= chunk;
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

    const count = readBeU32(header[5..9]);
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

fn readBeU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn writeBeU32(bytes: []u8, value: u32) void {
    bytes[0] = @intCast((value >> 24) & 0xff);
    bytes[1] = @intCast((value >> 16) & 0xff);
    bytes[2] = @intCast((value >> 8) & 0xff);
    bytes[3] = @intCast(value & 0xff);
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

test "v3 upload requires non-empty payload" {
    var state = V3State{};
    try std.testing.expectEqual(v3_status_invalid_arg, handleV3Upload(&state, &.{}));
}

test "v3 bytecode activate requires upload first" {
    var state = V3State{};
    try std.testing.expectEqual(v3_status_not_ready, handleV3Activate(&state, .bytecode, null));
}

test "v3 stop deactivates shader state" {
    var state = V3State{
        .shader_active = true,
        .shader_source = .native,
        .shader_frame_count = 77,
    };
    try std.testing.expectEqual(v3_status_ok, handleV3Stop(&state, &.{}));
    try std.testing.expect(!state.shader_active);
    try std.testing.expectEqual(ShaderSource.none, state.shader_source);
    try std.testing.expectEqual(@as(u32, 0), state.shader_frame_count);
}

test "v3 query payload includes frame metrics fields" {
    var state = V3State{
        .default_shader_persisted = true,
        .has_uploaded_program = true,
        .shader_active = true,
        .bytecode_blob_len = 1234,
        .shader_slow_frame_count = 5,
        .shader_last_slow_frame_ms = 42,
        .shader_frame_count = 99,
    };
    var payload: [v3_status_payload_len]u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(v3_status_ok, handleV3Query(&state, &.{}, payload[0..], &out_len));
    try std.testing.expectEqual(v3_status_payload_len, out_len);
    try std.testing.expectEqual(@as(u8, 1), payload[0]);
    try std.testing.expectEqual(@as(u8, 1), payload[1]);
    try std.testing.expectEqual(@as(u8, 1), payload[2]);
    try std.testing.expectEqual(@as(u32, 1234), readBeU32(payload[4..8]));
    try std.testing.expectEqual(@as(u32, 5), readBeU32(payload[8..12]));
    try std.testing.expectEqual(@as(u32, 42), readBeU32(payload[12..16]));
    try std.testing.expectEqual(@as(u32, 99), readBeU32(payload[16..20]));
}
