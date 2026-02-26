const std = @import("std");
const builtin = @import("builtin");
const led = @import("led_pillar_zig");

var shutdown_requested: led.display_logic.StopFlag = .init(false);

const EffectKind = enum {
    dsl_compile,
    dsl_file,
    bytecode_upload,
    firmware_upload,
    native_shader_activate,
    stop,
};

const RunConfig = struct {
    host: []const u8,
    port: u16 = led.tcp_client.default_port,
    frame_rate_hz: u16 = led.default_frame_rate_hz,
    effect: EffectKind = .dsl_file,
    dsl_file_path: ?[]const u8 = null,
    bytecode_file_path: ?[]const u8 = null,
    firmware_file_path: ?[]const u8 = null,
};

const v3_protocol_version: u8 = 0x03;
const v3_cmd_upload_bytecode: u8 = 0x01;
const v3_cmd_activate_shader: u8 = 0x02;
const v3_cmd_query_default_hook: u8 = 0x05;
const v3_cmd_upload_firmware: u8 = 0x06;
const v3_cmd_activate_native_shader: u8 = 0x07;
const v3_cmd_stop_shader: u8 = 0x08;
const v3_response_flag: u8 = 0x80;

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
    if (run_config.effect == .bytecode_upload) {
        try runBytecodeUpload(
            run_config.host,
            run_config.port,
            run_config.bytecode_file_path orelse return error.MissingBytecodePath,
        );
        return;
    }
    if (run_config.effect == .dsl_compile) {
        try runDslCompileOnly(run_config.dsl_file_path orelse return error.MissingDslPath);
        return;
    }
    if (run_config.effect == .firmware_upload) {
        try runFirmwareUpload(
            run_config.host,
            run_config.port,
            run_config.firmware_file_path orelse return error.MissingFirmwarePath,
        );
        return;
    }
    if (run_config.effect == .native_shader_activate) {
        try runNativeShaderActivate(run_config.host, run_config.port);
        return;
    }
    if (run_config.effect == .stop) {
        try runShaderStop(run_config.host, run_config.port);
        return;
    }

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
        .dsl_file => try runDslFileEffect(
            &client,
            &display,
            run_config.frame_rate_hz,
            run_config.dsl_file_path orelse return error.MissingDslPath,
            &shutdown_requested,
        ),
        .dsl_compile => unreachable,
        .bytecode_upload => unreachable,
        .firmware_upload => unreachable,
        .native_shader_activate => unreachable,
        .stop => unreachable,
    }
}

fn runBytecodeUpload(host: []const u8, port: u16, bytecode_file_path: []const u8) !void {
    std.debug.print("Preparing bytecode upload...\n", .{});
    const input_is_dsl = std.mem.endsWith(u8, bytecode_file_path, ".dsl");
    var compiled_payload = std.ArrayList(u8).empty;
    defer compiled_payload.deinit(std.heap.page_allocator);

    var payload_len_usize: usize = 0;
    if (input_is_dsl) {
        std.debug.print("Input is DSL; compiling to bytecode first...\n", .{});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const source = try std.fs.cwd().readFileAlloc(arena.allocator(), bytecode_file_path, std.math.maxInt(usize));
        const program = try led.dsl_parser.parseAndValidate(arena.allocator(), source);
        var evaluator = try led.dsl_runtime.Evaluator.init(std.heap.page_allocator, program);
        defer evaluator.deinit();
        const payload_writer = compiled_payload.writer(std.heap.page_allocator);
        try evaluator.writeBytecodeBinary(payload_writer);
        payload_len_usize = compiled_payload.items.len;
        std.debug.print("DSL compile complete: {d} bytecode bytes.\n", .{payload_len_usize});
    } else {
        const bytecode_stat = try std.fs.cwd().statFile(bytecode_file_path);
        if (bytecode_stat.size == 0 or bytecode_stat.size > std.math.maxInt(u32)) return error.InvalidBytecodeSize;
        payload_len_usize = @intCast(bytecode_stat.size);
    }
    if (payload_len_usize == 0 or payload_len_usize > std.math.maxInt(u32)) return error.InvalidBytecodeSize;
    const payload_len: u32 = @intCast(payload_len_usize);

    std.debug.print("Bytecode file: {s}\n", .{bytecode_file_path});
    std.debug.print("Payload size: {d} bytes\n", .{payload_len});
    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });
    var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
    defer stream.close();
    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&reader_buffer);
    std.debug.print("Connected.\n", .{});

    std.debug.print("Sending v3 bytecode upload header (cmd=0x01)...\n", .{});
    try writeV3Header(&stream, v3_cmd_upload_bytecode, payload_len);

    var sent_total: usize = 0;
    if (input_is_dsl) {
        try stream.writeAll(compiled_payload.items);
        sent_total = compiled_payload.items.len;
    } else {
        var bytecode_file = try std.fs.cwd().openFile(bytecode_file_path, .{});
        defer bytecode_file.close();
        var send_buf: [16 * 1024]u8 = undefined;
        while (true) {
            const read_len = try bytecode_file.read(send_buf[0..]);
            if (read_len == 0) break;
            try stream.writeAll(send_buf[0..read_len]);
            sent_total += read_len;
        }
    }
    if (sent_total != payload_len_usize) return error.InvalidBytecodeSize;

    const upload_response = try readV3StatusResponse(&reader, v3_cmd_upload_bytecode);
    if (upload_response.status != 0) {
        std.debug.print("Bytecode upload failed: v3 status={d} ({s})\n", .{ upload_response.status, v3StatusName(upload_response.status) });
        return error.V3CommandFailed;
    }

    std.debug.print("Activating uploaded shader (cmd=0x02)...\n", .{});
    try writeV3Header(&stream, v3_cmd_activate_shader, 0);
    const activate_response = try readV3StatusResponse(&reader, v3_cmd_activate_shader);
    if (activate_response.status != 0) {
        std.debug.print("Shader activation failed: v3 status={d} ({s})\n", .{ activate_response.status, v3StatusName(activate_response.status) });
        return error.V3CommandFailed;
    }

    std.debug.print("Bytecode upload + activation completed successfully.\n", .{});
    try monitorShaderSlowFrames(&stream, &reader);
}

fn runFirmwareUpload(host: []const u8, port: u16, firmware_file_path: []const u8) !void {
    std.debug.print("Preparing firmware upload...\n", .{});
    var firmware_file = try std.fs.cwd().openFile(firmware_file_path, .{});
    defer firmware_file.close();
    const firmware_stat = try firmware_file.stat();
    if (firmware_stat.size == 0 or firmware_stat.size > std.math.maxInt(u32)) return error.InvalidFirmwareSize;
    const payload_len: u32 = @intCast(firmware_stat.size);
    const payload_len_usize: usize = @intCast(payload_len);

    std.debug.print("Firmware file: {s}\n", .{firmware_file_path});
    std.debug.print("Payload size: {d} bytes\n", .{payload_len});
    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });
    var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
    defer stream.close();
    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&reader_buffer);
    std.debug.print("Connected.\n", .{});

    std.debug.print("Sending v3 upload header (cmd=0x06)...\n", .{});
    try writeV3Header(&stream, v3_cmd_upload_firmware, payload_len);

    var upload_timer = try std.time.Timer.start();
    var send_buf: [16 * 1024]u8 = undefined;
    var sent_total: usize = 0;
    var next_progress_percent: usize = 10;
    std.debug.print("Streaming firmware payload...\n", .{});
    while (true) {
        const read_len = try firmware_file.read(send_buf[0..]);
        if (read_len == 0) break;
        try stream.writeAll(send_buf[0..read_len]);
        sent_total += read_len;
        if (payload_len_usize > 0) {
            const sent_percent = (sent_total * 100) / payload_len_usize;
            while (sent_percent >= next_progress_percent and next_progress_percent <= 100) : (next_progress_percent += 10) {
                std.debug.print("  {d}% ({d}/{d} bytes)\n", .{ next_progress_percent, sent_total, payload_len_usize });
            }
        }
    }
    if (sent_total != payload_len_usize) return error.InvalidFirmwareSize;
    const upload_elapsed_ns = upload_timer.read();
    if (upload_elapsed_ns > 0) {
        const bytes_per_sec = (@as(u64, @intCast(sent_total)) * std.time.ns_per_s) / upload_elapsed_ns;
        std.debug.print("Upload finished in {d} ms ({d} bytes/s).\n", .{ upload_elapsed_ns / std.time.ns_per_ms, bytes_per_sec });
    } else {
        std.debug.print("Upload finished.\n", .{});
    }

    std.debug.print("Waiting for v3 response...\n", .{});
    const response = try readV3StatusResponse(&reader, v3_cmd_upload_firmware);
    std.debug.print("Received v3 response header: payload_len={d}\n", .{response.payload_len});

    if (response.status != 0) {
        std.debug.print("Firmware upload failed: v3 status={d} ({s})\n", .{ response.status, v3StatusName(response.status) });
        if (response.status == 4) {
            std.debug.print(
                "Hint: device OTA partition table not ready; flash once over USB with CONFIG_PARTITION_TABLE_TWO_OTA enabled.\n",
                .{},
            );
        }
        return error.V3CommandFailed;
    }

    std.debug.print("Firmware upload accepted (status=OK); device should reboot into the new image.\n", .{});
}

fn runNativeShaderActivate(host: []const u8, port: u16) !void {
    std.debug.print("Activating built-in native C shader...\n", .{});
    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });
    var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
    defer stream.close();
    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&reader_buffer);
    std.debug.print("Connected.\n", .{});

    try writeV3Header(&stream, v3_cmd_activate_native_shader, 0);
    const response = try readV3StatusResponse(&reader, v3_cmd_activate_native_shader);
    if (response.status != 0) {
        std.debug.print(
            "Native shader activation failed: v3 status={d} ({s})\n",
            .{ response.status, v3StatusName(response.status) },
        );
        return error.V3CommandFailed;
    }
    std.debug.print("Native shader activation completed successfully.\n", .{});
    try monitorShaderSlowFrames(&stream, &reader);
}

fn runShaderStop(host: []const u8, port: u16) !void {
    std.debug.print("Stopping shader and clearing display...\n", .{});
    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });
    var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
    defer stream.close();
    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&reader_buffer);
    std.debug.print("Connected.\n", .{});

    try writeV3Header(&stream, v3_cmd_stop_shader, 0);
    const response = try readV3StatusResponse(&reader, v3_cmd_stop_shader);
    if (response.status != 0) {
        std.debug.print(
            "Shader stop failed: v3 status={d} ({s})\n",
            .{ response.status, v3StatusName(response.status) },
        );
        return error.V3CommandFailed;
    }
    std.debug.print("Shader stopped and display cleared.\n", .{});
}

fn clearDisplayOnExit(client: *led.TcpClient, display: *led.DisplayBuffer) !void {
    led.display_logic.fillSolid(display, .{});
    try client.sendFrame(display.payload());
    try client.finishPendingFrame();
}

fn runDslCompileOnly(dsl_file_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), dsl_file_path, std.math.maxInt(usize));
    const program = try led.dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try led.dsl_runtime.Evaluator.init(std.heap.page_allocator, program);
    defer evaluator.deinit();
    try writeDslBytecodeReference(&evaluator, dsl_file_path);
    try writeDslCReference(program, dsl_file_path);
    std.debug.print("DSL compile complete for {s}; wrote bytecode and emitted C reference.\n", .{dsl_file_path});
}

fn runDslFileEffect(
    client: *led.TcpClient,
    display: *led.DisplayBuffer,
    frame_rate_hz: u16,
    dsl_file_path: []const u8,
    stop_flag: *const led.display_logic.StopFlag,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), dsl_file_path, std.math.maxInt(usize));
    const program = try led.dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try led.dsl_runtime.Evaluator.init(std.heap.page_allocator, program);
    defer evaluator.deinit();
    try writeDslBytecodeReference(&evaluator, dsl_file_path);

    const pixel_count = @as(usize, @intCast(display.pixel_count));
    const frame = try std.heap.page_allocator.alloc(led.display_logic.Color, pixel_count);
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

fn writeDslCReference(program: led.dsl_parser.Program, dsl_file_path: []const u8) !void {
    _ = dsl_file_path;
    const allocator = std.heap.page_allocator;
    const output_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ "esp32_firmware", "main", "generated", "dsl_shader_generated.c" },
    );
    defer allocator.free(output_path);

    try std.fs.cwd().makePath("esp32_firmware/main/generated");
    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;
    try led.dsl_c_emitter.writeProgramC(allocator, writer, program);
    try writer.flush();
}

fn blitDslFrameToDisplay(display: *led.DisplayBuffer, frame: []const led.display_logic.Color) !void {
    const required = @as(usize, @intCast(display.pixel_count));
    if (frame.len < required) return error.InvalidFrameBufferLength;

    var encoded: [4]u8 = undefined;
    var y: u16 = 0;
    while (y < display.height) : (y += 1) {
        var x: u16 = 0;
        while (x < display.width) : (x += 1) {
            const idx = (@as(usize, y) * @as(usize, display.width)) + @as(usize, x);
            const pixel = led.display_logic.encodeColor(display.pixel_format, frame[idx], &encoded);
            try display.setPixel(@as(i32, @intCast(x)), y, pixel);
        }
    }
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
    const host_or_mode = args.next() orelse return error.MissingHost;

    if (std.mem.eql(u8, host_or_mode, "dsl-compile")) {
        const dsl_file_path = args.next() orelse return error.MissingDslPath;
        if (args.next() != null) return error.TooManyArguments;
        return .{
            .host = "127.0.0.1",
            .effect = .dsl_compile,
            .dsl_file_path = dsl_file_path,
        };
    }

    var run_config = RunConfig{
        .host = host_or_mode,
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
        .native_shader_activate, .stop => {
            if (args.next() != null) return error.TooManyArguments;
        },
        .dsl_compile => {
            run_config.dsl_file_path = args.next() orelse return error.MissingDslPath;
            if (args.next() != null) return error.TooManyArguments;
        },
        .dsl_file => {
            run_config.dsl_file_path = args.next() orelse return error.MissingDslPath;
            if (args.next() != null) return error.TooManyArguments;
        },
        .bytecode_upload => {
            run_config.bytecode_file_path = args.next() orelse return error.MissingBytecodePath;
            if (args.next() != null) return error.TooManyArguments;
        },
        .firmware_upload => {
            run_config.firmware_file_path = args.next() orelse return error.MissingFirmwarePath;
            if (args.next() != null) return error.TooManyArguments;
        },
    }

    return run_config;
}

fn parseEffectKind(effect_arg: []const u8) !EffectKind {
    if (std.mem.eql(u8, effect_arg, "dsl-compile")) return .dsl_compile;
    if (std.mem.eql(u8, effect_arg, "dsl-file")) return .dsl_file;
    if (std.mem.eql(u8, effect_arg, "bytecode-upload")) return .bytecode_upload;
    if (std.mem.eql(u8, effect_arg, "firmware-upload")) return .firmware_upload;
    if (std.mem.eql(u8, effect_arg, "native-shader-activate")) return .native_shader_activate;
    if (std.mem.eql(u8, effect_arg, "stop")) return .stop;
    return error.UnknownEffect;
}

fn readStreamExact(reader: *std.net.Stream.Reader, buffer: []u8) !void {
    reader.interface().readSliceAll(buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.getError() orelse error.Unexpected,
        else => return err,
    };
}

const V3StatusResponse = struct {
    status: u8,
    payload_len: u32,
};

const V3QueryStatus = struct {
    default_shader_persisted: bool,
    has_uploaded_program: bool,
    shader_active: bool,
    default_shader_faulted: bool,
    bytecode_blob_len: u32,
    slow_frame_count: u32 = 0,
    last_slow_frame_ms: u32 = 0,
    has_slow_frame_metrics: bool = false,
    frame_count: u32 = 0,
    has_frame_metrics: bool = false,
};

fn writeV3Header(stream: *std.net.Stream, cmd: u8, payload_len: u32) !void {
    var header: [led.tcp_client.header_len]u8 = undefined;
    header[0] = 'L';
    header[1] = 'E';
    header[2] = 'D';
    header[3] = 'S';
    header[4] = v3_protocol_version;
    header[5] = @as(u8, @intCast((payload_len >> 24) & 0xff));
    header[6] = @as(u8, @intCast((payload_len >> 16) & 0xff));
    header[7] = @as(u8, @intCast((payload_len >> 8) & 0xff));
    header[8] = @as(u8, @intCast(payload_len & 0xff));
    header[9] = cmd;
    try stream.writeAll(&header);
}

fn readV3StatusResponse(reader: *std.net.Stream.Reader, expected_cmd: u8) !V3StatusResponse {
    var response_header: [led.tcp_client.header_len]u8 = undefined;
    try readStreamExact(reader, response_header[0..]);
    if (!std.mem.eql(u8, response_header[0..4], "LEDS")) return error.InvalidV3Response;
    if (response_header[4] != v3_protocol_version) return error.InvalidV3Response;
    if (response_header[9] != (expected_cmd | v3_response_flag)) return error.InvalidV3Response;

    const response_payload_len = readBeU32(response_header[5..9]);
    if (response_payload_len < 1) return error.InvalidV3Response;

    var status_byte: [1]u8 = undefined;
    try readStreamExact(reader, status_byte[0..]);
    if (response_payload_len > 1) {
        try drainStream(reader, response_payload_len - 1);
    }
    return .{
        .status = status_byte[0],
        .payload_len = response_payload_len,
    };
}

fn queryV3Status(stream: *std.net.Stream, reader: *std.net.Stream.Reader) !V3QueryStatus {
    try writeV3Header(stream, v3_cmd_query_default_hook, 0);

    var response_header: [led.tcp_client.header_len]u8 = undefined;
    try readStreamExact(reader, response_header[0..]);
    if (!std.mem.eql(u8, response_header[0..4], "LEDS")) return error.InvalidV3Response;
    if (response_header[4] != v3_protocol_version) return error.InvalidV3Response;
    if (response_header[9] != (v3_cmd_query_default_hook | v3_response_flag)) return error.InvalidV3Response;

    const response_payload_len = readBeU32(response_header[5..9]);
    if (response_payload_len < 1) return error.InvalidV3Response;

    var status_byte: [1]u8 = undefined;
    try readStreamExact(reader, status_byte[0..]);

    const response_data_len = response_payload_len - 1;
    var payload: [20]u8 = undefined;
    if (response_data_len > payload.len) {
        try drainStream(reader, response_data_len);
        return error.InvalidV3Response;
    }
    if (response_data_len > 0) {
        try readStreamExact(reader, payload[0..response_data_len]);
    }

    if (status_byte[0] != 0) {
        return error.V3CommandFailed;
    }
    if (response_data_len < 8) {
        return error.InvalidV3Response;
    }

    var status = V3QueryStatus{
        .default_shader_persisted = payload[0] != 0,
        .has_uploaded_program = payload[1] != 0,
        .shader_active = payload[2] != 0,
        .default_shader_faulted = payload[3] != 0,
        .bytecode_blob_len = readBeU32(payload[4..8]),
    };
    if (response_data_len >= 16) {
        status.slow_frame_count = readBeU32(payload[8..12]);
        status.last_slow_frame_ms = readBeU32(payload[12..16]);
        status.has_slow_frame_metrics = true;
    }
    if (response_data_len >= 20) {
        status.frame_count = readBeU32(payload[16..20]);
        status.has_frame_metrics = true;
    }
    return status;
}

fn pollStdinForEnter(timeout_ms: i32) !bool {
    if (builtin.os.tag == .windows) {
        std.Thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
        return false;
    }

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&poll_fds, timeout_ms);
    if (ready <= 0) {
        return false;
    }
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn drainStdinInput() void {
    if (builtin.os.tag == .windows) return;
    var scratch: [64]u8 = undefined;
    _ = std.posix.read(std.posix.STDIN_FILENO, scratch[0..]) catch {};
}

fn windowsWaitForEnter(stop_requested: *std.atomic.Value(bool)) void {
    var stdin_file = std.fs.File.stdin();
    var one: [1]u8 = undefined;
    while (true) {
        const read_len = stdin_file.read(one[0..]) catch return;
        if (read_len == 0) return;
        if (one[0] == '\r' or one[0] == '\n') {
            stop_requested.store(true, .seq_cst);
            return;
        }
    }
}

fn monitorShaderSlowFrames(stream: *std.net.Stream, reader: *std.net.Stream.Reader) !void {
    var status = queryV3Status(stream, reader) catch |err| switch (err) {
        error.V3CommandFailed => {
            std.debug.print("Shader monitor query failed.\n", .{});
            return;
        },
        else => return err,
    };

    if (!status.has_slow_frame_metrics and !status.has_frame_metrics) {
        std.debug.print("Firmware does not expose shader telemetry yet; use `idf.py monitor` to see ESP logs.\n", .{});
        return;
    }

    std.debug.print("Monitoring shader telemetry (FPS + slow frames); press Enter to stop.\n", .{});
    var last_slow_frame_count = status.slow_frame_count;
    var last_frame_count = status.frame_count;
    var last_fps_time_ms = std.time.milliTimestamp();
    var windows_stop_requested = std.atomic.Value(bool).init(false);
    if (builtin.os.tag == .windows) {
        const stdin_thread = try std.Thread.spawn(.{}, windowsWaitForEnter, .{&windows_stop_requested});
        stdin_thread.detach();
    }

    while (true) {
        if (builtin.os.tag == .windows) {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            if (windows_stop_requested.load(.seq_cst)) {
                std.debug.print("Stopped shader monitor.\n", .{});
                return;
            }
        } else {
            if (try pollStdinForEnter(500)) {
                drainStdinInput();
                std.debug.print("Stopped shader monitor.\n", .{});
                return;
            }
        }

        status = queryV3Status(stream, reader) catch |err| switch (err) {
            error.V3CommandFailed => {
                std.debug.print("Shader monitor query failed.\n", .{});
                return;
            },
            else => return err,
        };

        if (status.slow_frame_count > last_slow_frame_count) {
            std.debug.print(
                "slow shader frame(s): +{d}, latest={d} ms\n",
                .{ status.slow_frame_count - last_slow_frame_count, status.last_slow_frame_ms },
            );
            last_slow_frame_count = status.slow_frame_count;
        }

        if (status.has_frame_metrics) {
            const now_ms = std.time.milliTimestamp();
            const elapsed_ms: u64 = @intCast(@max(now_ms - last_fps_time_ms, 0));
            if (elapsed_ms >= 1000) {
                const delta_frames = status.frame_count -% last_frame_count;
                const fps = (@as(f64, @floatFromInt(delta_frames)) * 1000.0) / @as(f64, @floatFromInt(elapsed_ms));
                std.debug.print("shader fps: {d:.1}\n", .{fps});
                last_frame_count = status.frame_count;
                last_fps_time_ms = now_ms;
            }
        }
    }
}

fn drainStream(reader: *std.net.Stream.Reader, len: u32) !void {
    var remaining = len;
    var scratch: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk_u32 = @min(remaining, @as(u32, scratch.len));
        const chunk: usize = @intCast(chunk_u32);
        try readStreamExact(reader, scratch[0..chunk]);
        remaining -= chunk_u32;
    }
}

fn readBeU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn v3StatusName(status: u8) []const u8 {
    return switch (status) {
        0 => "OK",
        1 => "INVALID_ARG",
        2 => "UNSUPPORTED_CMD",
        3 => "TOO_LARGE",
        4 => "NOT_READY",
        5 => "VM_ERROR",
        6 => "INTERNAL",
        else => "UNKNOWN",
    };
}

fn parseMaybeU16(arg: []const u8) !?u16 {
    return std.fmt.parseInt(u16, arg, 10) catch |err| switch (err) {
        error.InvalidCharacter => null,
        else => err,
    };
}

test "parseEffectKind accepts known effect names" {
    try std.testing.expectEqual(.dsl_compile, try parseEffectKind("dsl-compile"));
    try std.testing.expectEqual(.dsl_file, try parseEffectKind("dsl-file"));
    try std.testing.expectEqual(.bytecode_upload, try parseEffectKind("bytecode-upload"));
    try std.testing.expectEqual(.firmware_upload, try parseEffectKind("firmware-upload"));
    try std.testing.expectEqual(.native_shader_activate, try parseEffectKind("native-shader-activate"));
    try std.testing.expectEqual(.stop, try parseEffectKind("stop"));
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

test "parseRunConfig parses compile-only dsl mode without host" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "dsl-compile", "examples\\dsl\\v1\\aurora.dsl" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.dsl_compile, run_config.effect);
    try std.testing.expectEqualStrings("examples\\dsl\\v1\\aurora.dsl", run_config.dsl_file_path.?);
}

test "parseRunConfig compile-only dsl mode requires path" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "dsl-compile" },
    };
    try std.testing.expectError(error.MissingDslPath, parseRunConfig(&args));
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

test "parseRunConfig parses firmware-upload mode" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "firmware-upload", "esp32_firmware/build/led_pillar_firmware.bin" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.firmware_upload, run_config.effect);
    try std.testing.expectEqualStrings("esp32_firmware/build/led_pillar_firmware.bin", run_config.firmware_file_path.?);
}

test "parseRunConfig firmware-upload requires path" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "firmware-upload" },
    };
    try std.testing.expectError(error.MissingFirmwarePath, parseRunConfig(&args));
}

test "parseRunConfig parses bytecode-upload mode" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "bytecode-upload", "bytecode/soap-bubbles.bin" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.bytecode_upload, run_config.effect);
    try std.testing.expectEqualStrings("bytecode/soap-bubbles.bin", run_config.bytecode_file_path.?);
}

test "parseRunConfig bytecode-upload requires path" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "bytecode-upload" },
    };
    try std.testing.expectError(error.MissingBytecodePath, parseRunConfig(&args));
}

test "parseRunConfig parses native-shader-activate mode" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "native-shader-activate" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.native_shader_activate, run_config.effect);
}

test "parseRunConfig native-shader-activate rejects extra args" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "native-shader-activate", "extra" },
    };
    try std.testing.expectError(error.TooManyArguments, parseRunConfig(&args));
}

test "parseRunConfig parses stop mode" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "stop" },
    };
    const run_config = try parseRunConfig(&args);
    try std.testing.expectEqual(.stop, run_config.effect);
}

test "parseRunConfig stop rejects extra args" {
    var args = TestArgs{
        .values = &[_][]const u8{ "led-pillar-zig", "192.168.1.22", "stop", "extra" },
    };
    try std.testing.expectError(error.TooManyArguments, parseRunConfig(&args));
}
