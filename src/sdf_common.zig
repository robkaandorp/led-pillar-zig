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

        return .{
            .r = ((s.r * s.a) + (d.r * d.a * (1.0 - s.a))) / out_a,
            .g = ((s.g * s.a) + (d.g * d.a * (1.0 - s.a))) / out_a,
            .b = ((s.b * s.a) + (d.b * d.a * (1.0 - s.a))) / out_a,
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
