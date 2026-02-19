const std = @import("std");
const display_logic = @import("display_logic.zig");
const dsl_parser = @import("dsl_parser.zig");
const effects = @import("effects.zig");
const sdf_common = @import("sdf_common.zig");

pub const PixelInputs = struct {
    time: f32,
    frame: f32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

const RuntimeValue = union(enum) {
    scalar: f32,
    vec2: sdf_common.Vec2,
    rgba: sdf_common.ColorRgba,
};

const LetBinding = struct {
    name: []const u8,
    value: RuntimeValue,
};

const Scope = struct {
    inputs: PixelInputs,
    param_count: usize,
    let_count: usize = 0,
};

const max_builtin_args: usize = 8;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    program: dsl_parser.Program,
    param_values: []f32,
    param_depends_on_xy: []bool,
    has_dynamic_params: bool,
    let_bindings: []LetBinding,

    pub fn init(allocator: std.mem.Allocator, program: dsl_parser.Program) !Evaluator {
        var max_let_count: usize = 0;
        for (program.layers) |layer| {
            var let_count: usize = 0;
            for (layer.statements) |statement| {
                if (statement == .let_decl) let_count += 1;
            }
            max_let_count = @max(max_let_count, let_count);
        }

        var evaluator = Evaluator{
            .allocator = allocator,
            .program = program,
            .param_values = try allocator.alloc(f32, program.params.len),
            .param_depends_on_xy = try allocator.alloc(bool, program.params.len),
            .has_dynamic_params = false,
            .let_bindings = try allocator.alloc(LetBinding, max_let_count),
        };

        evaluator.buildParamDependencyFlags();
        return evaluator;
    }

    pub fn deinit(self: *Evaluator) void {
        self.allocator.free(self.param_values);
        self.allocator.free(self.param_depends_on_xy);
        self.allocator.free(self.let_bindings);
    }

    pub fn evaluatePixel(self: *Evaluator, inputs: PixelInputs) !sdf_common.ColorRgba {
        try self.evaluateParams(inputs, .all);
        return self.evaluatePixelLayers(inputs);
    }

    fn evaluatePixelLayers(self: *Evaluator, inputs: PixelInputs) !sdf_common.ColorRgba {
        var out = sdf_common.ColorRgba{
            .r = 0.0,
            .g = 0.0,
            .b = 0.0,
            .a = 1.0,
        };

        for (self.program.layers) |layer| {
            var scope = Scope{
                .inputs = inputs,
                .param_count = self.param_values.len,
            };

            for (layer.statements) |statement| {
                switch (statement) {
                    .let_decl => |let_decl| {
                        if (scope.let_count >= self.let_bindings.len) return error.TooManyLayerBindings;
                        self.let_bindings[scope.let_count] = .{
                            .name = let_decl.name,
                            .value = try self.evalExpr(let_decl.value, &scope),
                        };
                        scope.let_count += 1;
                    },
                    .blend => |blend_expr| {
                        const src = try expectRgba(try self.evalExpr(blend_expr, &scope));
                        out = sdf_common.ColorRgba.blendOver(src, out);
                    },
                }
            }
        }

        return out;
    }

    pub fn renderFrame(
        self: *Evaluator,
        display: *const display_logic.DisplayBuffer,
        frame: []effects.Color,
        frame_number: u64,
        frame_rate_hz: f32,
    ) !void {
        const required = @as(usize, @intCast(display.pixel_count));
        if (frame.len < required) return error.InvalidFrameBufferLength;

        const frame_ctx = try sdf_common.FrameContext.init(frame_number, frame_rate_hz);
        const width_f = @as(f32, @floatFromInt(display.width));
        const height_f = @as(f32, @floatFromInt(display.height));
        const frame_f = @as(f32, @floatFromInt(frame_number));
        const time_s = frame_ctx.timeSeconds();
        const frame_inputs = PixelInputs{
            .time = time_s,
            .frame = frame_f,
            .x = 0.0,
            .y = 0.0,
            .width = width_f,
            .height = height_f,
        };
        try self.evaluateParams(frame_inputs, .frame_static);

        var y: u16 = 0;
        while (y < display.height) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var x: u16 = 0;
            while (x < display.width) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const logical_index = (@as(usize, y) * @as(usize, display.width)) + @as(usize, x);
                const pixel_inputs = PixelInputs{
                    .time = time_s,
                    .frame = frame_f,
                    .x = px,
                    .y = py,
                    .width = width_f,
                    .height = height_f,
                };
                if (self.has_dynamic_params) {
                    try self.evaluateParams(pixel_inputs, .pixel_dynamic);
                }
                const rgba = try self.evaluatePixelLayers(pixel_inputs);
                const rgb = rgba.toRgb8();
                frame[logical_index] = .{
                    .r = rgb[0],
                    .g = rgb[1],
                    .b = rgb[2],
                };
            }
        }
    }

    const ParamEvalMode = enum {
        all,
        frame_static,
        pixel_dynamic,
    };

    fn evaluateParams(self: *Evaluator, inputs: PixelInputs, mode: ParamEvalMode) !void {
        var scope = Scope{
            .inputs = inputs,
            .param_count = 0,
        };

        for (self.program.params, 0..) |param, idx| {
            const depends_on_xy = self.param_depends_on_xy[idx];
            switch (mode) {
                .all => {},
                .frame_static => if (depends_on_xy) continue,
                .pixel_dynamic => if (!depends_on_xy) continue,
            }
            scope.param_count = idx;
            self.param_values[idx] = try expectScalar(try self.evalExpr(param.value, &scope));
        }
    }

    fn buildParamDependencyFlags(self: *Evaluator) void {
        self.has_dynamic_params = false;
        for (self.program.params, 0..) |param, idx| {
            const depends = self.exprDependsOnXY(param.value, idx);
            self.param_depends_on_xy[idx] = depends;
            self.has_dynamic_params = self.has_dynamic_params or depends;
        }
    }

    fn exprDependsOnXY(self: *const Evaluator, expr: *const dsl_parser.Expr, param_limit: usize) bool {
        switch (expr.*) {
            .number => return false,
            .identifier => |name| {
                if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y")) return true;
                var idx: usize = 0;
                while (idx < param_limit) : (idx += 1) {
                    if (std.mem.eql(u8, self.program.params[idx].name, name)) {
                        return self.param_depends_on_xy[idx];
                    }
                }
                return false;
            },
            .unary => |unary_expr| return self.exprDependsOnXY(unary_expr.operand, param_limit),
            .binary => |binary_expr| {
                return self.exprDependsOnXY(binary_expr.left, param_limit) or
                    self.exprDependsOnXY(binary_expr.right, param_limit);
            },
            .call => |call_expr| {
                for (call_expr.args) |arg| {
                    if (self.exprDependsOnXY(arg, param_limit)) return true;
                }
                return false;
            },
        }
    }

    fn evalExpr(self: *Evaluator, expr: *const dsl_parser.Expr, scope: *Scope) !RuntimeValue {
        switch (expr.*) {
            .number => |number| return .{ .scalar = number },
            .identifier => |name| return self.resolveIdentifier(name, scope),
            .unary => |unary_expr| {
                const operand = try expectScalar(try self.evalExpr(unary_expr.operand, scope));
                return switch (unary_expr.op) {
                    .negate => .{ .scalar = -operand },
                };
            },
            .binary => |binary_expr| {
                const lhs = try expectScalar(try self.evalExpr(binary_expr.left, scope));
                const rhs = try expectScalar(try self.evalExpr(binary_expr.right, scope));
                return switch (binary_expr.op) {
                    .add => .{ .scalar = lhs + rhs },
                    .sub => .{ .scalar = lhs - rhs },
                    .mul => .{ .scalar = lhs * rhs },
                    .div => .{ .scalar = lhs / rhs },
                };
            },
            .call => |call_expr| {
                if (call_expr.args.len > max_builtin_args) return error.InvalidBuiltinArity;
                var arg_values: [max_builtin_args]RuntimeValue = undefined;
                for (call_expr.args, 0..) |arg, idx| {
                    arg_values[idx] = try self.evalExpr(arg, scope);
                }
                return evalBuiltin(call_expr.builtin, arg_values[0..call_expr.args.len]);
            },
        }
    }

    fn resolveIdentifier(self: *const Evaluator, name: []const u8, scope: *const Scope) !RuntimeValue {
        var let_idx = scope.let_count;
        while (let_idx > 0) {
            let_idx -= 1;
            const binding = self.let_bindings[let_idx];
            if (std.mem.eql(u8, binding.name, name)) return binding.value;
        }

        for (self.program.params[0..scope.param_count], 0..) |param, idx| {
            if (std.mem.eql(u8, param.name, name)) return .{ .scalar = self.param_values[idx] };
        }

        if (std.mem.eql(u8, name, "time")) return .{ .scalar = scope.inputs.time };
        if (std.mem.eql(u8, name, "frame")) return .{ .scalar = scope.inputs.frame };
        if (std.mem.eql(u8, name, "x")) return .{ .scalar = scope.inputs.x };
        if (std.mem.eql(u8, name, "y")) return .{ .scalar = scope.inputs.y };
        if (std.mem.eql(u8, name, "width")) return .{ .scalar = scope.inputs.width };
        if (std.mem.eql(u8, name, "height")) return .{ .scalar = scope.inputs.height };

        return error.UnknownIdentifier;
    }
};

fn evalBuiltin(builtin: dsl_parser.BuiltinId, args: []const RuntimeValue) !RuntimeValue {
    return switch (builtin) {
        .sin => blk: {
            try expectArity(args, 1);
            break :blk .{ .scalar = std.math.sin(try expectScalar(args[0])) };
        },
        .cos => blk: {
            try expectArity(args, 1);
            break :blk .{ .scalar = std.math.cos(try expectScalar(args[0])) };
        },
        .abs => blk: {
            try expectArity(args, 1);
            break :blk .{ .scalar = @abs(try expectScalar(args[0])) };
        },
        .min => blk: {
            try expectArity(args, 2);
            break :blk .{ .scalar = @min(try expectScalar(args[0]), try expectScalar(args[1])) };
        },
        .max => blk: {
            try expectArity(args, 2);
            break :blk .{ .scalar = @max(try expectScalar(args[0]), try expectScalar(args[1])) };
        },
        .smoothstep => blk: {
            try expectArity(args, 3);
            break :blk .{ .scalar = sdf_common.smoothstep(
                try expectScalar(args[0]),
                try expectScalar(args[1]),
                try expectScalar(args[2]),
            ) };
        },
        .circle => blk: {
            try expectArity(args, 2);
            break :blk .{ .scalar = sdf_common.sdfCircle(try expectVec2(args[0]), try expectScalar(args[1])) };
        },
        .box => blk: {
            try expectArity(args, 2);
            break :blk .{ .scalar = sdf_common.sdfBox(try expectVec2(args[0]), try expectVec2(args[1])) };
        },
        .wrapdx => blk: {
            try expectArity(args, 3);
            break :blk .{ .scalar = wrappedDeltaX(
                try expectScalar(args[0]),
                try expectScalar(args[1]),
                try expectScalar(args[2]),
            ) };
        },
        .hash01 => blk: {
            try expectArity(args, 1);
            break :blk .{ .scalar = sdf_common.hash01(scalarToU32(try expectScalar(args[0]))) };
        },
        .hash_signed => blk: {
            try expectArity(args, 1);
            break :blk .{ .scalar = sdf_common.hashSigned(scalarToU32(try expectScalar(args[0]))) };
        },
        .hash_coords01 => blk: {
            try expectArity(args, 3);
            break :blk .{ .scalar = sdf_common.hashCoords01(
                scalarToI32(try expectScalar(args[0])),
                scalarToI32(try expectScalar(args[1])),
                scalarToU32(try expectScalar(args[2])),
            ) };
        },
        .vec2 => blk: {
            try expectArity(args, 2);
            break :blk .{ .vec2 = .{
                .x = try expectScalar(args[0]),
                .y = try expectScalar(args[1]),
            } };
        },
        .rgba => blk: {
            try expectArity(args, 4);
            break :blk .{ .rgba = .{
                .r = try expectScalar(args[0]),
                .g = try expectScalar(args[1]),
                .b = try expectScalar(args[2]),
                .a = try expectScalar(args[3]),
            } };
        },
    };
}

fn expectArity(args: []const RuntimeValue, expected: usize) !void {
    if (args.len != expected) return error.InvalidBuiltinArity;
}

fn expectScalar(value: RuntimeValue) !f32 {
    return switch (value) {
        .scalar => |scalar| scalar,
        else => error.InvalidValueType,
    };
}

fn expectVec2(value: RuntimeValue) !sdf_common.Vec2 {
    return switch (value) {
        .vec2 => |vec| vec,
        else => error.InvalidValueType,
    };
}

fn expectRgba(value: RuntimeValue) !sdf_common.ColorRgba {
    return switch (value) {
        .rgba => |rgba| rgba,
        else => error.InvalidValueType,
    };
}

fn wrappedDeltaX(px: f32, center_x: f32, width: f32) f32 {
    var dx = px - center_x;
    const half_width = width * 0.5;
    if (dx > half_width) dx -= width;
    if (dx < -half_width) dx += width;
    return dx;
}

fn scalarToI32(value: f32) i32 {
    const min_i32 = @as(f32, @floatFromInt(std.math.minInt(i32)));
    const max_i32 = @as(f32, @floatFromInt(std.math.maxInt(i32)));
    const clamped = std.math.clamp(value, min_i32, max_i32);
    return @as(i32, @intFromFloat(clamped));
}

fn scalarToU32(value: f32) u32 {
    const signed = scalarToI32(value);
    return @bitCast(signed);
}

fn evalScalarExpression(expression: []const u8, inputs: PixelInputs) !f32 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fmt.allocPrint(
        arena.allocator(),
        \\effect builtin_eval
        \\layer l {{
        \\  blend rgba({s}, 0.0, 0.0, 1.0)
        \\}}
        \\emit
    ,
        .{expression},
    );

    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try Evaluator.init(std.testing.allocator, program);
    defer evaluator.deinit();
    const color = try evaluator.evaluatePixel(inputs);
    return color.r;
}

test "Evaluator evaluates v1 builtin expressions" {
    const inputs = PixelInputs{
        .time = 0.0,
        .frame = 12.0,
        .x = 0.2,
        .y = 2.0,
        .width = 30.0,
        .height = 40.0,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try evalScalarExpression("sin(0.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try evalScalarExpression("cos(0.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), try evalScalarExpression("abs(-0.25)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), try evalScalarExpression("min(0.2, 0.4)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), try evalScalarExpression("max(0.2, 0.4)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("smoothstep(0.0, 1.0, 0.5)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("circle(vec2(2.0, 0.0), 1.0) * 0.5", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("box(vec2(2.0, 0.0), vec2(1.0, 1.0)) * 0.5", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), try evalScalarExpression("wrapdx(0.2, 29.6, width)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(sdf_common.hash01(scalarToU32(12.0)), try evalScalarExpression("hash01(12.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(
        (sdf_common.hashSigned(scalarToU32(12.0)) + 1.0) * 0.5,
        try evalScalarExpression("(hashSigned(12.0) + 1.0) * 0.5", inputs),
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        sdf_common.hashCoords01(1, 2, 3),
        try evalScalarExpression("hashCoords01(1.0, 2.0, 3.0)", inputs),
        0.0001,
    );
}

test "Evaluator blends layers in order" {
    const source =
        \\effect layered
        \\param alpha = 0.5
        \\layer red {
        \\  let c = rgba(1.0, 0.0, 0.0, alpha)
        \\  blend c
        \\}
        \\layer blue {
        \\  let c = rgba(0.0, 0.0, 1.0, alpha)
        \\  blend c
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try Evaluator.init(std.testing.allocator, program);
    defer evaluator.deinit();

    const color = try evaluator.evaluatePixel(.{
        .time = 0.0,
        .frame = 0.0,
        .x = 0.5,
        .y = 0.5,
        .width = 30.0,
        .height = 40.0,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), color.r, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), color.g, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), color.b, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.a, 0.0001);
}

test "renderFrame evaluates params and layers per pixel" {
    const source =
        \\effect gradient
        \\param shade = x / width
        \\layer base {
        \\  blend rgba(shade, y / height, 0.0, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try Evaluator.init(std.testing.allocator, program);
    defer evaluator.deinit();

    var display = try display_logic.DisplayBuffer.init(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixel_format = .rgb,
    });
    defer display.deinit();

    var frame_storage = [_]effects.Color{.{}} ** 4;
    try evaluator.renderFrame(&display, frame_storage[0..], 0, 40.0);

    try std.testing.expectEqual(effects.Color{ .r = 64, .g = 64, .b = 0, .w = 0 }, frame_storage[0]);
    try std.testing.expectEqual(effects.Color{ .r = 191, .g = 64, .b = 0, .w = 0 }, frame_storage[1]);
    try std.testing.expectEqual(effects.Color{ .r = 64, .g = 191, .b = 0, .w = 0 }, frame_storage[2]);
    try std.testing.expectEqual(effects.Color{ .r = 191, .g = 191, .b = 0, .w = 0 }, frame_storage[3]);
}
