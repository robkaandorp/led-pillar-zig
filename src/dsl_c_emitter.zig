const std = @import("std");
const dsl_parser = @import("dsl_parser.zig");

/// Counter for phasor() calls during audio emission. Reset before each audio block.
var phasor_emit_counter: usize = 0;

const Symbol = struct {
    c_name: []const u8,
    value_type: dsl_parser.ValueType,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*const Scope,
    symbols: std.StringHashMap(Symbol),

    fn init(allocator: std.mem.Allocator, parent: ?*const Scope) Scope {
        return .{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
        };
    }

    fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }

    fn put(self: *Scope, name: []const u8, symbol: Symbol) !void {
        try self.symbols.put(name, symbol);
    }

    fn get(self: *const Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |symbol| return symbol;
        if (self.parent) |parent| return parent.get(name);
        return null;
    }
};

/// Emit the common C preamble (types, inline helpers). Call once at the top of a combined file.
pub fn writePreambleC(writer: anytype) !void {
    try writer.print(
        \\#include <math.h>
        \\#include <stdint.h>
        \\
        \\/* DSL_NOINLINE: defined by the ESP32 build to control inlining of
        \\ * large helper functions (noise2, noise3, blend_over).
        \\ * On desktop/simulator builds this defaults to `inline`. */
        \\#ifndef DSL_NOINLINE
        \\#define DSL_NOINLINE inline
        \\#endif
        \\
        \\#ifndef DSL_MAYBE_UNUSED
        \\#if defined(__GNUC__)
        \\#define DSL_MAYBE_UNUSED __attribute__((unused))
        \\#else
        \\#define DSL_MAYBE_UNUSED
        \\#endif
        \\#endif
        \\
        \\typedef struct {{
        \\    float x;
        \\    float y;
        \\}} dsl_vec2_t;
        \\
        \\typedef struct {{
        \\    float r;
        \\    float g;
        \\    float b;
        \\    float a;
        \\}} dsl_color_t;
        \\
        \\static inline float dsl_clamp(float v, float lo, float hi) {{
        \\    if (v < lo) return lo;
        \\    if (v > hi) return hi;
        \\    return v;
        \\}}
        \\
        \\static inline float dsl_fract(float v) {{
        \\    return v - floorf(v);
        \\}}
        \\
        \\static inline float dsl_smoothstep(float edge0, float edge1, float x) {{
        \\    if (edge0 == edge1) {{
        \\        return (x < edge0) ? 0.0f : 1.0f;
        \\    }}
        \\    const float t = dsl_clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
        \\    return t * t * (3.0f - (2.0f * t));
        \\}}
        \\
        \\static inline float dsl_wrapdx(float px, float center_x, float width) {{
        \\    float dx = px - center_x;
        \\    if (width <= 0.0f) return dx;
        \\    if (dx > width * 0.5f) dx -= width;
        \\    if (dx < -width * 0.5f) dx += width;
        \\    return dx;
        \\}}
        \\
        \\static inline uint32_t dsl_hash_u32(uint32_t value) {{
        \\    uint32_t x = value;
        \\    x ^= x >> 16U;
        \\    x *= 0x7feb352dU;
        \\    x ^= x >> 15U;
        \\    x *= 0x846ca68bU;
        \\    x ^= x >> 16U;
        \\    return x;
        \\}}
        \\
        \\static inline float dsl_hash01(float value) {{
        \\    const uint32_t hashed = dsl_hash_u32((uint32_t)((int32_t)value)) & 0x00ffffffU;
        \\    return (float)hashed / 16777215.0f;
        \\}}
        \\
        \\static inline float dsl_hash_signed(float value) {{
        \\    return (dsl_hash01(value) * 2.0f) - 1.0f;
        \\}}
        \\
        \\static inline float dsl_hash_coords01(float x, float y, float seed) {{
        \\    uint32_t mixed = (uint32_t)((int32_t)x) * 0x9e3779b9U;
        \\    mixed ^= (uint32_t)((int32_t)y) * 0x85ebca6bU;
        \\    mixed ^= (uint32_t)((int32_t)seed);
        \\    return dsl_hash01((float)((int32_t)mixed));
        \\}}
        \\
        \\static inline float dsl_circle(dsl_vec2_t p, float radius) {{
        \\    return sqrtf((p.x * p.x) + (p.y * p.y)) - radius;
        \\}}
        \\
        \\static inline float dsl_box(dsl_vec2_t p, dsl_vec2_t b) {{
        \\    dsl_vec2_t q = {{ .x = fabsf(p.x) - b.x, .y = fabsf(p.y) - b.y }};
        \\    dsl_vec2_t outside = {{ .x = fmaxf(q.x, 0.0f), .y = fmaxf(q.y, 0.0f) }};
        \\    const float inside = fminf(fmaxf(q.x, q.y), 0.0f);
        \\    return sqrtf((outside.x * outside.x) + (outside.y * outside.y)) + inside;
        \\}}
        \\
        \\static inline dsl_color_t dsl_blend_over(dsl_color_t src, dsl_color_t dst) {{
        \\    const float src_a = dsl_clamp(src.a, 0.0f, 1.0f);
        \\    const float dst_a = dsl_clamp(dst.a, 0.0f, 1.0f);
        \\    const float out_a = src_a + (dst_a * (1.0f - src_a));
        \\    if (out_a <= 0.000001f) {{
        \\        return (dsl_color_t){{ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 0.0f }};
        \\    }}
        \\    const float inv_out_a = 1.0f / out_a;
        \\    const float one_minus_src_a = 1.0f - src_a;
        \\    return (dsl_color_t){{
        \\        .r = dsl_clamp(((src.r * src_a) + (dst.r * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        \\        .g = dsl_clamp(((src.g * src_a) + (dst.g * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        \\        .b = dsl_clamp(((src.b * src_a) + (dst.b * dst_a * one_minus_src_a)) * inv_out_a, 0.0f, 1.0f),
        \\        .a = out_a,
        \\    }};
        \\}}
        \\
        \\static const unsigned char dsl_perm[512] = {{
        \\    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
        \\    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
        \\    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
        \\    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
        \\    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
        \\    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
        \\    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
        \\    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
        \\    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
        \\    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
        \\    119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
        \\    129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
        \\    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
        \\    81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
        \\    184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
        \\    222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180,
        \\    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
        \\    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
        \\    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
        \\    57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
        \\    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
        \\    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
        \\    65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
        \\    200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
        \\    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
        \\    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
        \\    119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
        \\    129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
        \\    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
        \\    81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
        \\    184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
        \\    222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
        \\}};
        \\
        \\static inline float dsl_grad2(int hash, float x, float y) {{
        \\    const int h = hash & 7;
        \\    const float u = h < 4 ? x : y;
        \\    const float v = h < 4 ? y : x;
        \\    return ((h & 1) ? -u : u) + ((h & 2) ? -2.0f * v : 2.0f * v);
        \\}}
        \\
        \\static DSL_NOINLINE float dsl_noise2(float x, float y) {{
        \\    const float F2 = 0.3660254037844386f;
        \\    const float G2 = 0.21132486540518713f;
        \\    const float s = (x + y) * F2;
        \\    const int i = (int)floorf(x + s);
        \\    const int j = (int)floorf(y + s);
        \\    const float t = (float)(i + j) * G2;
        \\    const float x0 = x - ((float)i - t);
        \\    const float y0 = y - ((float)j - t);
        \\    int i1, j1;
        \\    if (x0 > y0) {{ i1 = 1; j1 = 0; }} else {{ i1 = 0; j1 = 1; }}
        \\    const float x1 = x0 - (float)i1 + G2;
        \\    const float y1 = y0 - (float)j1 + G2;
        \\    const float x2 = x0 - 1.0f + 2.0f * G2;
        \\    const float y2 = y0 - 1.0f + 2.0f * G2;
        \\    const int ii = i & 255;
        \\    const int jj = j & 255;
        \\    float n = 0.0f;
        \\    float t0 = 0.5f - x0*x0 - y0*y0;
        \\    if (t0 >= 0.0f) {{ t0 *= t0; n += t0 * t0 * dsl_grad2(dsl_perm[ii + dsl_perm[jj]], x0, y0); }}
        \\    float t1 = 0.5f - x1*x1 - y1*y1;
        \\    if (t1 >= 0.0f) {{ t1 *= t1; n += t1 * t1 * dsl_grad2(dsl_perm[ii + i1 + dsl_perm[jj + j1]], x1, y1); }}
        \\    float t2 = 0.5f - x2*x2 - y2*y2;
        \\    if (t2 >= 0.0f) {{ t2 *= t2; n += t2 * t2 * dsl_grad2(dsl_perm[ii + 1 + dsl_perm[jj + 1]], x2, y2); }}
        \\    return 70.0f * n;
        \\}}
        \\
        \\static inline float dsl_grad3(int hash, float x, float y, float z) {{
        \\    const int h = hash & 15;
        \\    const float u = h < 8 ? x : y;
        \\    const float v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
        \\    return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
        \\}}
        \\
        \\static DSL_NOINLINE float dsl_noise3(float x, float y, float z) {{
        \\    const float F3 = 1.0f / 3.0f;
        \\    const float G3 = 1.0f / 6.0f;
        \\    const float s = (x + y + z) * F3;
        \\    const int i = (int)floorf(x + s);
        \\    const int j = (int)floorf(y + s);
        \\    const int k = (int)floorf(z + s);
        \\    const float t = (float)(i + j + k) * G3;
        \\    const float x0 = x - ((float)i - t);
        \\    const float y0 = y - ((float)j - t);
        \\    const float z0 = z - ((float)k - t);
        \\    int i1, j1, k1, i2, j2, k2;
        \\    if (x0 >= y0) {{
        \\        if (y0 >= z0) {{ i1=1;j1=0;k1=0;i2=1;j2=1;k2=0; }}
        \\        else if (x0 >= z0) {{ i1=1;j1=0;k1=0;i2=1;j2=0;k2=1; }}
        \\        else {{ i1=0;j1=0;k1=1;i2=1;j2=0;k2=1; }}
        \\    }} else {{
        \\        if (y0 < z0) {{ i1=0;j1=0;k1=1;i2=0;j2=1;k2=1; }}
        \\        else if (x0 < z0) {{ i1=0;j1=1;k1=0;i2=0;j2=1;k2=1; }}
        \\        else {{ i1=0;j1=1;k1=0;i2=1;j2=1;k2=0; }}
        \\    }}
        \\    const float x1 = x0 - (float)i1 + G3;
        \\    const float y1 = y0 - (float)j1 + G3;
        \\    const float z1 = z0 - (float)k1 + G3;
        \\    const float x2 = x0 - (float)i2 + 2.0f*G3;
        \\    const float y2 = y0 - (float)j2 + 2.0f*G3;
        \\    const float z2 = z0 - (float)k2 + 2.0f*G3;
        \\    const float x3 = x0 - 1.0f + 3.0f*G3;
        \\    const float y3 = y0 - 1.0f + 3.0f*G3;
        \\    const float z3 = z0 - 1.0f + 3.0f*G3;
        \\    const int ii = i & 255;
        \\    const int jj = j & 255;
        \\    const int kk = k & 255;
        \\    float n = 0.0f;
        \\    float c0 = 0.6f - x0*x0 - y0*y0 - z0*z0;
        \\    if (c0 >= 0.0f) {{ c0 *= c0; n += c0*c0*dsl_grad3(dsl_perm[ii+dsl_perm[jj+dsl_perm[kk]]], x0, y0, z0); }}
        \\    float c1 = 0.6f - x1*x1 - y1*y1 - z1*z1;
        \\    if (c1 >= 0.0f) {{ c1 *= c1; n += c1*c1*dsl_grad3(dsl_perm[ii+i1+dsl_perm[jj+j1+dsl_perm[kk+k1]]], x1, y1, z1); }}
        \\    float c2 = 0.6f - x2*x2 - y2*y2 - z2*z2;
        \\    if (c2 >= 0.0f) {{ c2 *= c2; n += c2*c2*dsl_grad3(dsl_perm[ii+i2+dsl_perm[jj+j2+dsl_perm[kk+k2]]], x2, y2, z2); }}
        \\    float c3 = 0.6f - x3*x3 - y3*y3 - z3*z3;
        \\    if (c3 >= 0.0f) {{ c3 *= c3; n += c3*c3*dsl_grad3(dsl_perm[ii+1+dsl_perm[jj+1+dsl_perm[kk+1]]], x3, y3, z3); }}
        \\    return 32.0f * n;
        \\}}
        \\
        \\static inline float dsl_phasor_advance(float *state, float freq, float sample_rate) {{
        \\    *state += freq / sample_rate;
        \\    *state -= floorf(*state);
        \\    return *state;
        \\}}
        \\
        \\
    ,
        .{},
    );
}

/// Emit a standalone single-shader C file (preamble + shader functions). Backward compatible.
pub fn writeProgramC(allocator: std.mem.Allocator, writer: anytype, program: dsl_parser.Program) !void {
    try writePreambleC(writer);
    try writeShaderFunctions(allocator, writer, program, null);
}

/// Count the number of `phasor()` calls in a slice of statements (recursive).
pub fn countPhasorCalls(statements: []const dsl_parser.Statement) usize {
    var count: usize = 0;
    for (statements) |stmt| {
        switch (stmt) {
            .let_decl => |let_decl| count += countPhasorCallsInExpr(let_decl.value),
            .blend => |expr| count += countPhasorCallsInExpr(expr),
            .out => |expr| count += countPhasorCallsInExpr(expr),
            .if_stmt => |if_stmt| {
                count += countPhasorCallsInExpr(if_stmt.condition);
                count += countPhasorCalls(if_stmt.then_statements);
                count += countPhasorCalls(if_stmt.else_statements);
            },
            .for_range => |for_range| count += countPhasorCalls(for_range.statements),
        }
    }
    return count;
}

fn countPhasorCallsInExpr(expr: *const dsl_parser.Expr) usize {
    return switch (expr.*) {
        .number, .identifier => 0,
        .unary => |u| countPhasorCallsInExpr(u.operand),
        .binary => |b| countPhasorCallsInExpr(b.left) + countPhasorCallsInExpr(b.right),
        .call => |c| blk: {
            var n: usize = if (c.builtin == .phasor) @as(usize, 1) else @as(usize, 0);
            for (c.args) |arg| n += countPhasorCallsInExpr(arg);
            break :blk n;
        },
    };
}

/// Emit shader functions with a prefix. When prefix is non-null, functions are
/// marked `static` and named `{prefix}_eval_pixel` / `{prefix}_eval_frame`.
pub fn writeShaderFunctions(
    allocator: std.mem.Allocator,
    writer: anytype,
    program: dsl_parser.Program,
    prefix: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const is_prefixed = prefix != null;
    const static_kw: []const u8 = if (is_prefixed) "static " else "";

    // Emit eval_frame if the program has frame statements
    if (program.frame_statements.len > 0) {
        const frame_fn_name = if (prefix) |p|
            try std.fmt.allocPrint(temp_allocator, "{s}_eval_frame", .{p})
        else
            try std.fmt.allocPrint(temp_allocator, "dsl_shader_eval_frame", .{});

        try writer.print(
            \\/* Generated from effect: {s} */
            \\{s}void {s}(float time, float frame) {{
            \\
        , .{ program.effect_name, static_kw, frame_fn_name });

        var name_counter: usize = 0;
        var frame_scope = Scope.init(temp_allocator, null);
        defer frame_scope.deinit();
        try frame_scope.put("time", .{ .c_name = "time", .value_type = .scalar });
        try frame_scope.put("frame", .{ .c_name = "frame", .value_type = .scalar });

        for (program.params) |param| {
            const param_type = try inferExprType(param.value, &frame_scope);
            const c_name = try makeName(temp_allocator, "dsl_param", param.name, &name_counter);
            try writeIndent(writer, 1);
            try writer.print("const {s} {s} DSL_MAYBE_UNUSED = ", .{ cTypeName(param_type), c_name });
            try emitExpr(writer, param.value, &frame_scope);
            try writer.writeAll(";\n");
            try frame_scope.put(param.name, .{ .c_name = c_name, .value_type = param_type });
        }

        try emitStatements(writer, temp_allocator, &name_counter, &frame_scope, program.frame_statements, false, "__dsl_out", 1);
        try writer.writeAll("}\n\n");
    }

    // Emit eval_pixel
    const pixel_fn_name = if (prefix) |p|
        try std.fmt.allocPrint(temp_allocator, "{s}_eval_pixel", .{p})
    else
        try std.fmt.allocPrint(temp_allocator, "dsl_shader_eval_pixel", .{});

    try writer.print(
        \\/* Generated from effect: {s} */
        \\{s}void {s}(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color) {{
        \\
    , .{ program.effect_name, static_kw, pixel_fn_name });

    var name_counter: usize = 0;
    var root_scope = Scope.init(temp_allocator, null);
    defer root_scope.deinit();
    try root_scope.put("time", .{ .c_name = "time", .value_type = .scalar });
    try root_scope.put("frame", .{ .c_name = "frame", .value_type = .scalar });
    try root_scope.put("x", .{ .c_name = "x", .value_type = .scalar });
    try root_scope.put("y", .{ .c_name = "y", .value_type = .scalar });
    try root_scope.put("width", .{ .c_name = "width", .value_type = .scalar });
    try root_scope.put("height", .{ .c_name = "height", .value_type = .scalar });
    try root_scope.put("seed", .{ .c_name = "seed", .value_type = .scalar });

    for (program.params) |param| {
        const param_type = try inferExprType(param.value, &root_scope);
        const c_name = try makeName(temp_allocator, "dsl_param", param.name, &name_counter);
        try writeIndent(writer, 1);
        try writer.print("const {s} {s} DSL_MAYBE_UNUSED = ", .{ cTypeName(param_type), c_name });
        try emitExpr(writer, param.value, &root_scope);
        try writer.writeAll(";\n");
        try root_scope.put(param.name, .{ .c_name = c_name, .value_type = param_type });
    }

    try emitStatements(writer, temp_allocator, &name_counter, &root_scope, program.frame_statements, false, "__dsl_out", 1);

    try writeIndent(writer, 1);
    try writer.writeAll("dsl_color_t __dsl_out = (dsl_color_t){ .r = 0.0f, .g = 0.0f, .b = 0.0f, .a = 1.0f };\n");
    for (program.layers) |layer| {
        try writeIndent(writer, 1);
        try writer.print("/* layer {s} */\n", .{layer.name});
        var layer_scope = Scope.init(temp_allocator, &root_scope);
        defer layer_scope.deinit();
        try emitStatements(writer, temp_allocator, &name_counter, &layer_scope, layer.statements, true, "__dsl_out", 1);
    }
    try writeIndent(writer, 1);
    try writer.writeAll("*out_color = __dsl_out;\n");
    try writer.writeAll("}\n");

    // Emit eval_audio if the program has audio statements
    if (program.audio_statements.len > 0) {
        const audio_fn_name = if (prefix) |p|
            try std.fmt.allocPrint(temp_allocator, "{s}_eval_audio", .{p})
        else
            try std.fmt.allocPrint(temp_allocator, "dsl_shader_eval_audio", .{});

        try writer.print(
            \\
            \\/* Audio: generated from effect: {s} */
            \\{s}float {s}(float time, float seed, float sample_rate, float *phasor_state) {{
            \\
        , .{ program.effect_name, static_kw, audio_fn_name });

        phasor_emit_counter = 0;

        var audio_name_counter: usize = 0;
        var audio_scope = Scope.init(temp_allocator, null);
        defer audio_scope.deinit();
        try audio_scope.put("time", .{ .c_name = "time", .value_type = .scalar });
        try audio_scope.put("seed", .{ .c_name = "seed", .value_type = .scalar });

        for (program.params) |param| {
            const param_type = try inferExprType(param.value, &audio_scope);
            const c_name = try makeName(temp_allocator, "dsl_param", param.name, &audio_name_counter);
            try writeIndent(writer, 1);
            try writer.print("const {s} {s} DSL_MAYBE_UNUSED = ", .{ cTypeName(param_type), c_name });
            try emitExpr(writer, param.value, &audio_scope);
            try writer.writeAll(";\n");
            try audio_scope.put(param.name, .{ .c_name = c_name, .value_type = param_type });
        }

        try writeIndent(writer, 1);
        try writer.writeAll("float __dsl_audio_out = 0.0f;\n");
        try emitStatements(writer, temp_allocator, &audio_name_counter, &audio_scope, program.audio_statements, false, "__dsl_audio_out", 1);
        try writeIndent(writer, 1);
        try writer.writeAll("return __dsl_audio_out;\n");
        try writer.writeAll("}\n");
    }
}

fn emitStatements(
    writer: anytype,
    allocator: std.mem.Allocator,
    name_counter: *usize,
    scope: *Scope,
    statements: []const dsl_parser.Statement,
    allow_blend: bool,
    out_name: []const u8,
    indent: usize,
) anyerror!void {
    for (statements) |statement| {
        switch (statement) {
            .let_decl => |let_decl| {
                const expr_type = try inferExprType(let_decl.value, scope);
                const c_name = try makeName(allocator, "dsl_let", let_decl.name, name_counter);
                try writeIndent(writer, indent);
                try writer.print("const {s} {s} DSL_MAYBE_UNUSED = ", .{ cTypeName(expr_type), c_name });
                try emitExpr(writer, let_decl.value, scope);
                try writer.writeAll(";\n");
                try scope.put(let_decl.name, .{ .c_name = c_name, .value_type = expr_type });
            },
            .blend => |blend_expr| {
                if (!allow_blend) return error.InvalidFrameStatement;
                try writeIndent(writer, indent);
                try writer.print("{s} = dsl_blend_over(", .{out_name});
                try emitExpr(writer, blend_expr, scope);
                try writer.print(", {s});\n", .{out_name});
            },
            .out => |out_expr| {
                try writeIndent(writer, indent);
                try writer.print("{s} = ", .{out_name});
                try emitExpr(writer, out_expr, scope);
                try writer.writeAll(";\n");
            },
            .if_stmt => |if_stmt| {
                try writeIndent(writer, indent);
                try writer.writeAll("if (");
                try emitExpr(writer, if_stmt.condition, scope);
                try writer.writeAll(" > 0.0f) {\n");
                var then_scope = Scope.init(allocator, scope);
                defer then_scope.deinit();
                try emitStatements(
                    writer,
                    allocator,
                    name_counter,
                    &then_scope,
                    if_stmt.then_statements,
                    allow_blend,
                    out_name,
                    indent + 1,
                );
                try writeIndent(writer, indent);
                try writer.writeAll("} else {\n");
                var else_scope = Scope.init(allocator, scope);
                defer else_scope.deinit();
                try emitStatements(
                    writer,
                    allocator,
                    name_counter,
                    &else_scope,
                    if_stmt.else_statements,
                    allow_blend,
                    out_name,
                    indent + 1,
                );
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
            },
            .for_range => |for_stmt| {
                const iter_name = try makeName(allocator, "dsl_iter", for_stmt.index_name, name_counter);
                const index_name = try makeName(allocator, "dsl_index", for_stmt.index_name, name_counter);
                try writeIndent(writer, indent);
                try writer.print(
                    "for (int32_t {s} = {d}; {s} < {d}; {s}++) {{\n",
                    .{ iter_name, for_stmt.start_inclusive, iter_name, for_stmt.end_exclusive, iter_name },
                );
                var loop_scope = Scope.init(allocator, scope);
                defer loop_scope.deinit();
                try writeIndent(writer, indent + 1);
                try writer.print("const float {s} DSL_MAYBE_UNUSED = (float){s};\n", .{ index_name, iter_name });
                try loop_scope.put(for_stmt.index_name, .{ .c_name = index_name, .value_type = .scalar });
                try emitStatements(
                    writer,
                    allocator,
                    name_counter,
                    &loop_scope,
                    for_stmt.statements,
                    allow_blend,
                    out_name,
                    indent + 1,
                );
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
            },
        }
    }
}

fn emitExpr(writer: anytype, expr: *dsl_parser.Expr, scope: *const Scope) anyerror!void {
    switch (expr.*) {
        .number => |number| try writer.print("{d:.6}f", .{number}),
        .identifier => |name| {
            if (std.mem.eql(u8, name, "PI")) {
                try writer.writeAll("3.14159265358979323846f");
            } else if (std.mem.eql(u8, name, "TAU")) {
                try writer.writeAll("6.28318530717958647692f");
            } else if (scope.get(name)) |symbol| {
                try writer.writeAll(symbol.c_name);
            } else {
                return error.UnknownIdentifier;
            }
        },
        .unary => |unary_expr| {
            try writer.writeAll("(-(");
            try emitExpr(writer, unary_expr.operand, scope);
            try writer.writeAll("))");
        },
        .binary => |binary_expr| {
            if (binary_expr.op == .mod) {
                try writer.writeAll("fmodf(");
                try emitExpr(writer, binary_expr.left, scope);
                try writer.writeAll(", ");
                try emitExpr(writer, binary_expr.right, scope);
                try writer.writeAll(")");
            } else {
                try writer.writeAll("(");
                try emitExpr(writer, binary_expr.left, scope);
                switch (binary_expr.op) {
                    .add => try writer.writeAll(" + "),
                    .sub => try writer.writeAll(" - "),
                    .mul => try writer.writeAll(" * "),
                    .div => try writer.writeAll(" / "),
                    .mod => unreachable,
                }
                try emitExpr(writer, binary_expr.right, scope);
                try writer.writeAll(")");
            }
        },
        .call => |call_expr| {
            switch (call_expr.builtin) {
                .sin => try emitCall1(writer, scope, "sinf", call_expr.args[0]),
                .cos => try emitCall1(writer, scope, "cosf", call_expr.args[0]),
                .sqrt => try emitCall1(writer, scope, "sqrtf", call_expr.args[0]),
                .ln => try emitCall1(writer, scope, "logf", call_expr.args[0]),
                .log => try emitCall1(writer, scope, "log10f", call_expr.args[0]),
                .abs => try emitCall1(writer, scope, "fabsf", call_expr.args[0]),
                .floor => try emitCall1(writer, scope, "floorf", call_expr.args[0]),
                .fract => try emitCall1(writer, scope, "dsl_fract", call_expr.args[0]),
                .min => try emitCall2(writer, scope, "fminf", call_expr.args[0], call_expr.args[1]),
                .max => try emitCall2(writer, scope, "fmaxf", call_expr.args[0], call_expr.args[1]),
                .clamp => try emitCall3(writer, scope, "dsl_clamp", call_expr.args[0], call_expr.args[1], call_expr.args[2]),
                .smoothstep => try emitCall3(writer, scope, "dsl_smoothstep", call_expr.args[0], call_expr.args[1], call_expr.args[2]),
                .circle => try emitCall2(writer, scope, "dsl_circle", call_expr.args[0], call_expr.args[1]),
                .box => try emitCall2(writer, scope, "dsl_box", call_expr.args[0], call_expr.args[1]),
                .wrapdx => try emitCall3(writer, scope, "dsl_wrapdx", call_expr.args[0], call_expr.args[1], call_expr.args[2]),
                .hash01 => try emitCall1(writer, scope, "dsl_hash01", call_expr.args[0]),
                .hash_signed => try emitCall1(writer, scope, "dsl_hash_signed", call_expr.args[0]),
                .hash_coords01 => try emitCall3(
                    writer,
                    scope,
                    "dsl_hash_coords01",
                    call_expr.args[0],
                    call_expr.args[1],
                    call_expr.args[2],
                ),
                .pow => try emitCall2(writer, scope, "powf", call_expr.args[0], call_expr.args[1]),
                .noise => try emitCall2(writer, scope, "dsl_noise2", call_expr.args[0], call_expr.args[1]),
                .noise3 => try emitCall3(writer, scope, "dsl_noise3", call_expr.args[0], call_expr.args[1], call_expr.args[2]),
                .phasor => {
                    try writer.print("dsl_phasor_advance(&phasor_state[{d}], ", .{phasor_emit_counter});
                    try emitExpr(writer, call_expr.args[0], scope);
                    try writer.writeAll(", sample_rate)");
                    phasor_emit_counter += 1;
                },
                .vec2 => {
                    try writer.writeAll("(dsl_vec2_t){ .x = ");
                    try emitExpr(writer, call_expr.args[0], scope);
                    try writer.writeAll(", .y = ");
                    try emitExpr(writer, call_expr.args[1], scope);
                    try writer.writeAll(" }");
                },
                .rgba => {
                    try writer.writeAll("(dsl_color_t){ .r = ");
                    try emitExpr(writer, call_expr.args[0], scope);
                    try writer.writeAll(", .g = ");
                    try emitExpr(writer, call_expr.args[1], scope);
                    try writer.writeAll(", .b = ");
                    try emitExpr(writer, call_expr.args[2], scope);
                    try writer.writeAll(", .a = ");
                    try emitExpr(writer, call_expr.args[3], scope);
                    try writer.writeAll(" }");
                },
            }
        },
    }
}

fn emitCall1(writer: anytype, scope: *const Scope, name: []const u8, a0: *dsl_parser.Expr) anyerror!void {
    try writer.print("{s}(", .{name});
    try emitExpr(writer, a0, scope);
    try writer.writeAll(")");
}

fn emitCall2(writer: anytype, scope: *const Scope, name: []const u8, a0: *dsl_parser.Expr, a1: *dsl_parser.Expr) anyerror!void {
    try writer.print("{s}(", .{name});
    try emitExpr(writer, a0, scope);
    try writer.writeAll(", ");
    try emitExpr(writer, a1, scope);
    try writer.writeAll(")");
}

fn emitCall3(
    writer: anytype,
    scope: *const Scope,
    name: []const u8,
    a0: *dsl_parser.Expr,
    a1: *dsl_parser.Expr,
    a2: *dsl_parser.Expr,
) anyerror!void {
    try writer.print("{s}(", .{name});
    try emitExpr(writer, a0, scope);
    try writer.writeAll(", ");
    try emitExpr(writer, a1, scope);
    try writer.writeAll(", ");
    try emitExpr(writer, a2, scope);
    try writer.writeAll(")");
}

fn inferExprType(expr: *dsl_parser.Expr, scope: *const Scope) !dsl_parser.ValueType {
    return switch (expr.*) {
        .number => .scalar,
        .identifier => |name| blk: {
            if (std.mem.eql(u8, name, "PI") or std.mem.eql(u8, name, "TAU")) break :blk .scalar;
            if (scope.get(name)) |symbol| break :blk symbol.value_type;
            return error.UnknownIdentifier;
        },
        .unary => .scalar,
        .binary => .scalar,
        .call => |call_expr| builtinReturnType(call_expr.builtin),
    };
}

fn builtinReturnType(builtin: dsl_parser.BuiltinId) dsl_parser.ValueType {
    return switch (builtin) {
        .vec2 => .vec2,
        .rgba => .rgba,
        else => .scalar,
    };
}

fn makeName(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    base_name: []const u8,
    counter: *usize,
) ![]const u8 {
    const name = try std.fmt.allocPrint(allocator, "{s}_{s}_{d}", .{ prefix, base_name, counter.* });
    counter.* += 1;
    return name;
}

fn cTypeName(value_type: dsl_parser.ValueType) []const u8 {
    return switch (value_type) {
        .scalar => "float",
        .vec2 => "dsl_vec2_t",
        .rgba => "dsl_color_t",
    };
}

fn writeIndent(writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("    ");
    }
}

test "writeProgramC emits compilable-shaped C source" {
    const source =
        \\effect emit_test
        \\param speed = 0.5
        \\frame {
        \\  let t = time * speed
        \\}
        \\layer l {
        \\  let p = vec2(x, y)
        \\  let d = circle(p, 2.0)
        \\  let a = 1.0 - smoothstep(0.0, 1.0, d)
        \\  blend rgba(1.0, 0.0, 0.0, a)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writeProgramC(std.testing.allocator, writer, program);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "void dsl_shader_eval_pixel") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_blend_over") != null);
}

test "writeShaderFunctions emits prefixed static functions" {
    const source =
        \\effect emit_test
        \\param speed = 0.5
        \\frame {
        \\  let t = time * speed
        \\}
        \\layer l {
        \\  let p = vec2(x, y)
        \\  let d = circle(p, 2.0)
        \\  let a = 1.0 - smoothstep(0.0, 1.0, d)
        \\  blend rgba(1.0, 0.0, 0.0, a)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writeShaderFunctions(std.testing.allocator, writer, program, "my_shader");

    try std.testing.expect(std.mem.indexOf(u8, out.items, "static void my_shader_eval_pixel") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "static void my_shader_eval_frame") != null);
    // Should NOT contain the preamble types
    try std.testing.expect(std.mem.indexOf(u8, out.items, "typedef struct") == null);
}

test "writePreambleC emits type definitions" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writePreambleC(writer);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_vec2_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_color_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_blend_over") != null);
}

test "writePreambleC emits noise functions" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writePreambleC(writer);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_noise2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_noise3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_perm") != null);
}

test "writeProgramC emits pow, fmodf, and noise calls" {
    const source =
        \\effect emitter_test
        \\layer l {
        \\  let p = pow(2.0, 3.0)
        \\  let m = x % 2.0
        \\  let n = noise(x, y)
        \\  blend rgba(p, m, n, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writeProgramC(std.testing.allocator, writer, program);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "powf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fmodf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_noise2(") != null);
}

test "writeProgramC emits phasor_advance in audio block" {
    const source =
        \\effect phasor_test
        \\layer l {
        \\  blend rgba(1.0, 0.0, 0.0, 1.0)
        \\}
        \\audio {
        \\  let phase = phasor(440.0)
        \\  out sin(phase * 6.283185)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);
    try writeProgramC(std.testing.allocator, writer, program);

    // Verify the audio function has the new signature
    try std.testing.expect(std.mem.indexOf(u8, out.items, "float dsl_shader_eval_audio(float time, float seed, float sample_rate, float *phasor_state)") != null);
    // Verify phasor_advance call is emitted
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_phasor_advance(&phasor_state[0], ") != null);
    // Verify the helper function is in the preamble
    try std.testing.expect(std.mem.indexOf(u8, out.items, "dsl_phasor_advance(float *state, float freq, float sample_rate)") != null);
}

test "countPhasorCalls counts phasor calls in statements" {
    const source =
        \\effect phasor_count_test
        \\layer l {
        \\  blend rgba(1.0, 0.0, 0.0, 1.0)
        \\}
        \\audio {
        \\  let p1 = phasor(440.0)
        \\  let p2 = phasor(880.0)
        \\  out sin(p1 * 6.283185) + sin(p2 * 6.283185)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), countPhasorCalls(program.audio_statements));
    // Pixel layers should have 0 phasor calls
    for (program.layers) |layer| {
        try std.testing.expectEqual(@as(usize, 0), countPhasorCalls(layer.statements));
    }
}
