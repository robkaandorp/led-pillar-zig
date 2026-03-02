const std = @import("std");

pub const Float = f32;

pub const FrameContext = struct {
    frame_number: u64 = 0,
    frame_rate_hz: Float = 40.0,

    pub fn init(frame_number: u64, frame_rate_hz: Float) !FrameContext {
        if (frame_rate_hz <= 0.0) return error.InvalidFrameRate;
        return .{
            .frame_number = frame_number,
            .frame_rate_hz = frame_rate_hz,
        };
    }

    pub fn timeSeconds(self: FrameContext) Float {
        return @as(Float, @floatFromInt(self.frame_number)) / self.frame_rate_hz;
    }
};

pub const Vec2 = struct {
    x: Float,
    y: Float,

    pub fn init(x: Float, y: Float) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn splat(value: Float) Vec2 {
        return .{ .x = value, .y = value };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn abs(self: Vec2) Vec2 {
        return .{ .x = @abs(self.x), .y = @abs(self.y) };
    }

    pub fn max(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }

    pub fn dot(a: Vec2, b: Vec2) Float {
        return (a.x * b.x) + (a.y * b.y);
    }

    pub fn length(self: Vec2) Float {
        return std.math.sqrt(Vec2.dot(self, self));
    }
};

pub const ColorRgba = struct {
    r: Float = 0.0,
    g: Float = 0.0,
    b: Float = 0.0,
    a: Float = 1.0,

    pub fn fromRgb8(rgb: [3]u8) ColorRgba {
        return .{
            .r = @as(Float, @floatFromInt(rgb[0])) / 255.0,
            .g = @as(Float, @floatFromInt(rgb[1])) / 255.0,
            .b = @as(Float, @floatFromInt(rgb[2])) / 255.0,
            .a = 1.0,
        };
    }

    pub fn toRgb8(self: ColorRgba) [3]u8 {
        const clamped_color = self.clamped();
        return .{
            floatToU8(clamped_color.r),
            floatToU8(clamped_color.g),
            floatToU8(clamped_color.b),
        };
    }

    pub fn clamped(self: ColorRgba) ColorRgba {
        return .{
            .r = clamp01(self.r),
            .g = clamp01(self.g),
            .b = clamp01(self.b),
            .a = clamp01(self.a),
        };
    }

    pub fn blendOver(src: ColorRgba, dst: ColorRgba) ColorRgba {
        const s = src.clamped();
        const d = dst.clamped();
        const out_a = s.a + (d.a * (1.0 - s.a));

        if (out_a <= 0.000001) return .{ .a = 0.0 };

        const one_minus_sa = 1.0 - s.a;
        return .{
            .r = clamp01(((s.r * s.a) + (d.r * d.a * one_minus_sa)) / out_a),
            .g = clamp01(((s.g * s.a) + (d.g * d.a * one_minus_sa)) / out_a),
            .b = clamp01(((s.b * s.a) + (d.b * d.a * one_minus_sa)) / out_a),
            .a = out_a,
        };
    }

    pub fn blendOverRgb(src: ColorRgba, dst_rgb: [3]u8) [3]u8 {
        const blended = ColorRgba.blendOver(src, ColorRgba.fromRgb8(dst_rgb));
        return blended.toRgb8();
    }
};

pub fn clamp01(value: Float) Float {
    return std.math.clamp(value, 0.0, 1.0);
}

pub fn linearstep(edge0: Float, edge1: Float, x: Float) Float {
    if (edge0 == edge1) return if (x < edge0) 0.0 else 1.0;
    return clamp01((x - edge0) / (edge1 - edge0));
}

pub fn smoothstep(edge0: Float, edge1: Float, x: Float) Float {
    const t = linearstep(edge0, edge1, x);
    return t * t * (3.0 - (2.0 * t));
}

pub fn remapLinear(
    value: Float,
    in_min: Float,
    in_max: Float,
    out_min: Float,
    out_max: Float,
) Float {
    if (in_min == in_max) return out_min;
    const t = (value - in_min) / (in_max - in_min);
    return out_min + (t * (out_max - out_min));
}

pub fn hashU32(value: u32) u32 {
    var x = value;
    x ^= x >> 16;
    x *%= 0x7feb_352d;
    x ^= x >> 15;
    x *%= 0x846c_a68b;
    x ^= x >> 16;
    return x;
}

pub fn hash01(value: u32) Float {
    const hashed = hashU32(value) & 0x00ff_ffff;
    return @as(Float, @floatFromInt(hashed)) / 16_777_215.0;
}

pub fn hashSigned(value: u32) Float {
    return (hash01(value) * 2.0) - 1.0;
}

pub fn hashCoords01(x: i32, y: i32, seed: u32) Float {
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    const mixed = (ux *% 0x1f12_3bb5) ^ (uy *% 0x5f35_6495) ^ seed;
    return hash01(mixed);
}

pub fn sdfCircle(point: Vec2, radius: Float) Float {
    return point.length() - radius;
}

pub fn sdfBox(point: Vec2, half_size: Vec2) Float {
    const q = Vec2.sub(point.abs(), half_size);
    const outside = Vec2.max(q, Vec2.splat(0.0));
    const inside = @min(@max(q.x, q.y), 0.0);
    return outside.length() + inside;
}

// Simplex noise permutation table (duplicated to avoid wrapping)
const perm = [512]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

fn grad2(hash: i32, x: Float, y: Float) Float {
    const h: u3 = @truncate(@as(u32, @bitCast(hash)));
    const u = if (h < 4) x else y;
    const v = if (h < 4) y else x;
    return (if (h & 1 != 0) -u else u) + (if (h & 2 != 0) -2.0 * v else 2.0 * v);
}

pub fn noise2(xin: Float, yin: Float) Float {
    const F2: Float = 0.3660254037844386;
    const G2: Float = 0.21132486540518713;
    const s = (xin + yin) * F2;
    const i = @as(i32, @intFromFloat(@floor(xin + s)));
    const j = @as(i32, @intFromFloat(@floor(yin + s)));
    const t = @as(Float, @floatFromInt(i + j)) * G2;
    const x0 = xin - (@as(Float, @floatFromInt(i)) - t);
    const y0 = yin - (@as(Float, @floatFromInt(j)) - t);
    const si1: i32 = if (x0 > y0) 1 else 0;
    const sj1: i32 = if (x0 > y0) 0 else 1;
    const x1 = x0 - @as(Float, @floatFromInt(si1)) + G2;
    const y1 = y0 - @as(Float, @floatFromInt(sj1)) + G2;
    const x2 = x0 - 1.0 + 2.0 * G2;
    const y2 = y0 - 1.0 + 2.0 * G2;
    const ii: u8 = @truncate(@as(u32, @bitCast(i)));
    const jj: u8 = @truncate(@as(u32, @bitCast(j)));
    const sii1: u8 = @truncate(@as(u32, @bitCast(si1)));
    const sjj1: u8 = @truncate(@as(u32, @bitCast(sj1)));
    var n: Float = 0.0;
    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 >= 0.0) {
        t0 *= t0;
        n += t0 * t0 * grad2(@intCast(perm[ii +% perm[jj]]), x0, y0);
    }
    var t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 >= 0.0) {
        t1 *= t1;
        n += t1 * t1 * grad2(@intCast(perm[ii +% sii1 +% perm[jj +% sjj1]]), x1, y1);
    }
    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 >= 0.0) {
        t2 *= t2;
        n += t2 * t2 * grad2(@intCast(perm[ii +% 1 +% perm[jj +% 1]]), x2, y2);
    }
    return 70.0 * n;
}

fn grad3(hash: i32, x: Float, y: Float, z: Float) Float {
    const h: u4 = @truncate(@as(u32, @bitCast(hash)));
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if (h & 1 != 0) -u else u) + (if (h & 2 != 0) -v else v);
}

pub fn noise3(xin: Float, yin: Float, zin: Float) Float {
    const F3: Float = 1.0 / 3.0;
    const G3: Float = 1.0 / 6.0;
    const s = (xin + yin + zin) * F3;
    const i = @as(i32, @intFromFloat(@floor(xin + s)));
    const j = @as(i32, @intFromFloat(@floor(yin + s)));
    const k = @as(i32, @intFromFloat(@floor(zin + s)));
    const t = @as(Float, @floatFromInt(i + j + k)) * G3;
    const x0 = xin - (@as(Float, @floatFromInt(i)) - t);
    const y0 = yin - (@as(Float, @floatFromInt(j)) - t);
    const z0 = zin - (@as(Float, @floatFromInt(k)) - t);

    var si1: i32 = undefined;
    var sj1: i32 = undefined;
    var sk1: i32 = undefined;
    var si2: i32 = undefined;
    var sj2: i32 = undefined;
    var sk2: i32 = undefined;
    if (x0 >= y0) {
        if (y0 >= z0) {
            si1 = 1; sj1 = 0; sk1 = 0; si2 = 1; sj2 = 1; sk2 = 0;
        } else if (x0 >= z0) {
            si1 = 1; sj1 = 0; sk1 = 0; si2 = 1; sj2 = 0; sk2 = 1;
        } else {
            si1 = 0; sj1 = 0; sk1 = 1; si2 = 1; sj2 = 0; sk2 = 1;
        }
    } else {
        if (y0 < z0) {
            si1 = 0; sj1 = 0; sk1 = 1; si2 = 0; sj2 = 1; sk2 = 1;
        } else if (x0 < z0) {
            si1 = 0; sj1 = 1; sk1 = 0; si2 = 0; sj2 = 1; sk2 = 1;
        } else {
            si1 = 0; sj1 = 1; sk1 = 0; si2 = 1; sj2 = 1; sk2 = 0;
        }
    }

    const x1 = x0 - @as(Float, @floatFromInt(si1)) + G3;
    const y1 = y0 - @as(Float, @floatFromInt(sj1)) + G3;
    const z1 = z0 - @as(Float, @floatFromInt(sk1)) + G3;
    const x2 = x0 - @as(Float, @floatFromInt(si2)) + 2.0 * G3;
    const y2 = y0 - @as(Float, @floatFromInt(sj2)) + 2.0 * G3;
    const z2 = z0 - @as(Float, @floatFromInt(sk2)) + 2.0 * G3;
    const x3 = x0 - 1.0 + 3.0 * G3;
    const y3 = y0 - 1.0 + 3.0 * G3;
    const z3 = z0 - 1.0 + 3.0 * G3;

    const ii: u8 = @truncate(@as(u32, @bitCast(i)));
    const jj: u8 = @truncate(@as(u32, @bitCast(j)));
    const kk: u8 = @truncate(@as(u32, @bitCast(k)));
    const oii1: u8 = @truncate(@as(u32, @bitCast(si1)));
    const ojj1: u8 = @truncate(@as(u32, @bitCast(sj1)));
    const okk1: u8 = @truncate(@as(u32, @bitCast(sk1)));
    const oii2: u8 = @truncate(@as(u32, @bitCast(si2)));
    const ojj2: u8 = @truncate(@as(u32, @bitCast(sj2)));
    const okk2: u8 = @truncate(@as(u32, @bitCast(sk2)));

    var n: Float = 0.0;
    var c0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (c0 >= 0.0) {
        c0 *= c0;
        n += c0 * c0 * grad3(@intCast(perm[ii +% perm[jj +% perm[kk]]]), x0, y0, z0);
    }
    var c1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (c1 >= 0.0) {
        c1 *= c1;
        n += c1 * c1 * grad3(@intCast(perm[ii +% oii1 +% perm[jj +% ojj1 +% perm[kk +% okk1]]]), x1, y1, z1);
    }
    var c2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (c2 >= 0.0) {
        c2 *= c2;
        n += c2 * c2 * grad3(@intCast(perm[ii +% oii2 +% perm[jj +% ojj2 +% perm[kk +% okk2]]]), x2, y2, z2);
    }
    var c3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (c3 >= 0.0) {
        c3 *= c3;
        n += c3 * c3 * grad3(@intCast(perm[ii +% 1 +% perm[jj +% 1 +% perm[kk +% 1]]]), x3, y3, z3);
    }
    return 32.0 * n;
}

fn floatToU8(value: Float) u8 {
    const scaled = clamp01(value) * 255.0;
    return @as(u8, @intCast(@as(i32, @intFromFloat(@round(scaled)))));
}

test "FrameContext computes elapsed seconds from frame and frame rate" {
    const ctx = try FrameContext.init(80, 40.0);
    try std.testing.expectApproxEqAbs(@as(Float, 2.0), ctx.timeSeconds(), 0.0001);
}

test "FrameContext rejects invalid frame rate" {
    try std.testing.expectError(error.InvalidFrameRate, FrameContext.init(0, 0.0));
}

test "ColorRgba blends source over opaque framebuffer color" {
    const src = ColorRgba{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 0.5 };
    const out = ColorRgba.blendOverRgb(src, .{ 0, 0, 255 });
    try std.testing.expectEqual([3]u8{ 128, 0, 128 }, out);
}

test "sdfCircle and sdfBox return signed distance" {
    try std.testing.expectApproxEqAbs(@as(Float, 0.0), sdfCircle(Vec2.init(2.0, 0.0), 2.0), 0.0001);
    try std.testing.expect(sdfBox(Vec2.init(0.0, 0.0), Vec2.init(1.0, 1.0)) < 0.0);
    try std.testing.expect(sdfBox(Vec2.init(3.0, 0.0), Vec2.init(1.0, 1.0)) > 0.0);
}

test "linear and smooth helpers map values predictably" {
    try std.testing.expectApproxEqAbs(@as(Float, 0.5), linearstep(0.0, 10.0, 5.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(Float, 5.0), remapLinear(0.5, 0.0, 1.0, 0.0, 10.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(Float, 0.5), smoothstep(0.0, 1.0, 0.5), 0.0001);
}

test "hash helpers are deterministic and bounded" {
    const a = hash01(0x1234_5678);
    const b = hash01(0x1234_5678);
    try std.testing.expectApproxEqAbs(a, b, 0.0);
    try std.testing.expect(a >= 0.0 and a <= 1.0);

    const signed = hashSigned(0x1234_5678);
    try std.testing.expect(signed >= -1.0 and signed <= 1.0);
}

test "hashCoords01 is deterministic for coordinates and seed" {
    const a = hashCoords01(12, -5, 0x99aa_77cc);
    const b = hashCoords01(12, -5, 0x99aa_77cc);
    try std.testing.expectApproxEqAbs(a, b, 0.0);
    try std.testing.expect(a >= 0.0 and a <= 1.0);
}
