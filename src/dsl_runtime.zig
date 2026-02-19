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

const InputSlot = enum {
    time,
    frame,
    x,
    y,
    width,
    height,
};

const ResolvedSlot = union(enum) {
    input: InputSlot,
    param: usize,
    let_slot: usize,
};

const CompiledExpr = union(enum) {
    literal: RuntimeValue,
    slot: ResolvedSlot,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,

    const UnaryExpr = struct {
        op: dsl_parser.Expr.UnaryOp,
        operand: *const CompiledExpr,
    };

    const BinaryExpr = struct {
        op: dsl_parser.Expr.BinaryOp,
        left: *const CompiledExpr,
        right: *const CompiledExpr,
    };

    const CallExpr = struct {
        builtin: dsl_parser.BuiltinId,
        args: []const *const CompiledExpr,
    };
};

const CompiledStatement = union(enum) {
    let_decl: LetDecl,
    blend: *const CompiledExpr,

    const LetDecl = struct {
        slot: usize,
        expr: *const CompiledExpr,
    };
};

const CompiledLayer = struct {
    statements: []const CompiledStatement,
    let_count: usize,
};

const CompiledParam = struct {
    expr: *const CompiledExpr,
    depends_on_xy: bool,
};

const CompiledProgram = struct {
    params: []const CompiledParam,
    layers: []const CompiledLayer,
};

const max_builtin_args: usize = 8;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    compiled: CompiledProgram,
    compile_arena: std.heap.ArenaAllocator,
    param_values: []f32,
    let_values: []RuntimeValue,
    has_dynamic_params: bool,

    pub fn init(allocator: std.mem.Allocator, program: dsl_parser.Program) !Evaluator {
        var compile_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer compile_arena.deinit();

        const compiled = try compileProgram(compile_arena.allocator(), program);

        const param_values = try allocator.alloc(f32, compiled.params.len);
        errdefer allocator.free(param_values);

        var max_let_count: usize = 0;
        for (compiled.layers) |layer| {
            max_let_count = @max(max_let_count, layer.let_count);
        }

        const let_values = try allocator.alloc(RuntimeValue, max_let_count);
        errdefer allocator.free(let_values);

        var has_dynamic_params = false;
        for (compiled.params) |param| {
            has_dynamic_params = has_dynamic_params or param.depends_on_xy;
        }

        return .{
            .allocator = allocator,
            .compiled = compiled,
            .compile_arena = compile_arena,
            .param_values = param_values,
            .let_values = let_values,
            .has_dynamic_params = has_dynamic_params,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.allocator.free(self.param_values);
        self.allocator.free(self.let_values);
        self.compile_arena.deinit();
    }

    pub fn evaluatePixel(self: *Evaluator, inputs: PixelInputs) !sdf_common.ColorRgba {
        self.evaluateParams(inputs, .all);
        return self.evaluatePixelLayers(inputs);
    }

    fn evaluatePixelLayers(self: *Evaluator, inputs: PixelInputs) sdf_common.ColorRgba {
        var out = sdf_common.ColorRgba{
            .r = 0.0,
            .g = 0.0,
            .b = 0.0,
            .a = 1.0,
        };

        for (self.compiled.layers) |layer| {
            for (layer.statements) |statement| {
                switch (statement) {
                    .let_decl => |let_decl| {
                        self.let_values[let_decl.slot] = self.evalExpr(let_decl.expr, inputs);
                    },
                    .blend => |blend_expr| {
                        const src = asRgba(self.evalExpr(blend_expr, inputs));
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
        self.evaluateParams(frame_inputs, .frame_static);

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
                    self.evaluateParams(pixel_inputs, .pixel_dynamic);
                }

                const rgba = self.evaluatePixelLayers(pixel_inputs);
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

    fn evaluateParams(self: *Evaluator, inputs: PixelInputs, mode: ParamEvalMode) void {
        for (self.compiled.params, 0..) |param, idx| {
            switch (mode) {
                .all => {},
                .frame_static => if (param.depends_on_xy) continue,
                .pixel_dynamic => if (!param.depends_on_xy) continue,
            }
            self.param_values[idx] = asScalar(self.evalExpr(param.expr, inputs));
        }
    }

    fn evalExpr(self: *const Evaluator, expr: *const CompiledExpr, inputs: PixelInputs) RuntimeValue {
        return switch (expr.*) {
            .literal => |literal| literal,
            .slot => |slot| self.loadSlot(slot, inputs),
            .unary => |unary_expr| blk: {
                const operand = asScalar(self.evalExpr(unary_expr.operand, inputs));
                break :blk switch (unary_expr.op) {
                    .negate => .{ .scalar = -operand },
                };
            },
            .binary => |binary_expr| blk: {
                const lhs = asScalar(self.evalExpr(binary_expr.left, inputs));
                const rhs = asScalar(self.evalExpr(binary_expr.right, inputs));
                break :blk switch (binary_expr.op) {
                    .add => .{ .scalar = lhs + rhs },
                    .sub => .{ .scalar = lhs - rhs },
                    .mul => .{ .scalar = lhs * rhs },
                    .div => .{ .scalar = lhs / rhs },
                };
            },
            .call => |call_expr| blk: {
                var arg_values: [max_builtin_args]RuntimeValue = undefined;
                for (call_expr.args, 0..) |arg, idx| {
                    arg_values[idx] = self.evalExpr(arg, inputs);
                }
                break :blk evalBuiltin(call_expr.builtin, arg_values[0..call_expr.args.len]);
            },
        };
    }

    fn loadSlot(self: *const Evaluator, slot: ResolvedSlot, inputs: PixelInputs) RuntimeValue {
        return switch (slot) {
            .param => |idx| .{ .scalar = self.param_values[idx] },
            .let_slot => |idx| self.let_values[idx],
            .input => |input| switch (input) {
                .time => .{ .scalar = inputs.time },
                .frame => .{ .scalar = inputs.frame },
                .x => .{ .scalar = inputs.x },
                .y => .{ .scalar = inputs.y },
                .width => .{ .scalar = inputs.width },
                .height => .{ .scalar = inputs.height },
            },
        };
    }
};

fn compileProgram(allocator: std.mem.Allocator, program: dsl_parser.Program) !CompiledProgram {
    var param_lookup = std.StringHashMap(usize).init(allocator);
    defer param_lookup.deinit();

    const params = try allocator.alloc(CompiledParam, program.params.len);
    for (program.params, 0..) |param, idx| {
        const compiled_expr = try compileExpr(allocator, param.value, &param_lookup, null);
        params[idx] = .{
            .expr = compiled_expr,
            .depends_on_xy = compiledExprDependsOnXY(compiled_expr, params[0..idx]),
        };
        try param_lookup.put(param.name, idx);
    }

    const layers = try allocator.alloc(CompiledLayer, program.layers.len);
    for (program.layers, 0..) |layer, idx| {
        layers[idx] = try compileLayer(allocator, layer, &param_lookup);
    }

    return .{
        .params = params,
        .layers = layers,
    };
}

fn compileLayer(
    allocator: std.mem.Allocator,
    layer: dsl_parser.Layer,
    param_lookup: *const std.StringHashMap(usize),
) !CompiledLayer {
    var let_lookup = std.StringHashMap(usize).init(allocator);
    defer let_lookup.deinit();

    const statements = try allocator.alloc(CompiledStatement, layer.statements.len);
    var let_slot: usize = 0;

    for (layer.statements, 0..) |statement, idx| {
        switch (statement) {
            .let_decl => |let_decl| {
                const compiled_expr = try compileExpr(allocator, let_decl.value, param_lookup, &let_lookup);
                statements[idx] = .{
                    .let_decl = .{
                        .slot = let_slot,
                        .expr = compiled_expr,
                    },
                };
                try let_lookup.put(let_decl.name, let_slot);
                let_slot += 1;
            },
            .blend => |blend_expr| {
                const compiled_expr = try compileExpr(allocator, blend_expr, param_lookup, &let_lookup);
                statements[idx] = .{ .blend = compiled_expr };
            },
        }
    }

    return .{
        .statements = statements,
        .let_count = let_slot,
    };
}

fn compileExpr(
    allocator: std.mem.Allocator,
    expr: *const dsl_parser.Expr,
    param_lookup: *const std.StringHashMap(usize),
    let_lookup: ?*const std.StringHashMap(usize),
) !*const CompiledExpr {
    return switch (expr.*) {
        .number => |number| makeExpr(allocator, .{ .literal = .{ .scalar = number } }),
        .identifier => |name| blk: {
            const slot = try resolveSlot(name, param_lookup, let_lookup);
            break :blk makeExpr(allocator, .{ .slot = slot });
        },
        .unary => |unary_expr| blk: {
            const operand = try compileExpr(allocator, unary_expr.operand, param_lookup, let_lookup);
            if (operand.* == .literal) {
                const folded = switch (unary_expr.op) {
                    .negate => RuntimeValue{ .scalar = -asScalar(operand.literal) },
                };
                break :blk makeExpr(allocator, .{ .literal = folded });
            }
            break :blk makeExpr(allocator, .{ .unary = .{
                .op = unary_expr.op,
                .operand = operand,
            } });
        },
        .binary => |binary_expr| blk: {
            const left = try compileExpr(allocator, binary_expr.left, param_lookup, let_lookup);
            const right = try compileExpr(allocator, binary_expr.right, param_lookup, let_lookup);

            if (left.* == .literal and right.* == .literal) {
                const lhs = asScalar(left.literal);
                const rhs = asScalar(right.literal);
                const folded = switch (binary_expr.op) {
                    .add => lhs + rhs,
                    .sub => lhs - rhs,
                    .mul => lhs * rhs,
                    .div => lhs / rhs,
                };
                break :blk makeExpr(allocator, .{ .literal = .{ .scalar = folded } });
            }

            break :blk makeExpr(allocator, .{ .binary = .{
                .op = binary_expr.op,
                .left = left,
                .right = right,
            } });
        },
        .call => |call_expr| blk: {
            const compiled_args = try allocator.alloc(*const CompiledExpr, call_expr.args.len);
            var all_literal = true;
            for (call_expr.args, 0..) |arg, idx| {
                compiled_args[idx] = try compileExpr(allocator, arg, param_lookup, let_lookup);
                all_literal = all_literal and (compiled_args[idx].* == .literal);
            }

            if (all_literal) {
                var literal_args: [max_builtin_args]RuntimeValue = undefined;
                for (compiled_args, 0..) |arg, idx| {
                    literal_args[idx] = arg.literal;
                }
                const folded = evalBuiltin(call_expr.builtin, literal_args[0..compiled_args.len]);
                break :blk makeExpr(allocator, .{ .literal = folded });
            }

            break :blk makeExpr(allocator, .{ .call = .{
                .builtin = call_expr.builtin,
                .args = compiled_args,
            } });
        },
    };
}

fn makeExpr(allocator: std.mem.Allocator, expr: CompiledExpr) !*const CompiledExpr {
    const ptr = try allocator.create(CompiledExpr);
    ptr.* = expr;
    return ptr;
}

fn resolveSlot(
    name: []const u8,
    param_lookup: *const std.StringHashMap(usize),
    let_lookup: ?*const std.StringHashMap(usize),
) !ResolvedSlot {
    if (let_lookup) |lookup| {
        if (lookup.get(name)) |idx| return .{ .let_slot = idx };
    }
    if (param_lookup.get(name)) |idx| return .{ .param = idx };
    if (inputSlotFromName(name)) |input| return .{ .input = input };
    return error.UnknownIdentifier;
}

fn inputSlotFromName(name: []const u8) ?InputSlot {
    if (std.mem.eql(u8, name, "time")) return .time;
    if (std.mem.eql(u8, name, "frame")) return .frame;
    if (std.mem.eql(u8, name, "x")) return .x;
    if (std.mem.eql(u8, name, "y")) return .y;
    if (std.mem.eql(u8, name, "width")) return .width;
    if (std.mem.eql(u8, name, "height")) return .height;
    return null;
}

fn compiledExprDependsOnXY(expr: *const CompiledExpr, prior_params: []const CompiledParam) bool {
    return switch (expr.*) {
        .literal => false,
        .slot => |slot| switch (slot) {
            .param => |idx| prior_params[idx].depends_on_xy,
            .let_slot => false,
            .input => |input| input == .x or input == .y,
        },
        .unary => |unary_expr| compiledExprDependsOnXY(unary_expr.operand, prior_params),
        .binary => |binary_expr| {
            return compiledExprDependsOnXY(binary_expr.left, prior_params) or
                compiledExprDependsOnXY(binary_expr.right, prior_params);
        },
        .call => |call_expr| {
            for (call_expr.args) |arg| {
                if (compiledExprDependsOnXY(arg, prior_params)) return true;
            }
            return false;
        },
    };
}

fn evalBuiltin(builtin: dsl_parser.BuiltinId, args: []const RuntimeValue) RuntimeValue {
    return switch (builtin) {
        .sin => .{ .scalar = std.math.sin(asScalar(args[0])) },
        .cos => .{ .scalar = std.math.cos(asScalar(args[0])) },
        .abs => .{ .scalar = @abs(asScalar(args[0])) },
        .min => .{ .scalar = @min(asScalar(args[0]), asScalar(args[1])) },
        .max => .{ .scalar = @max(asScalar(args[0]), asScalar(args[1])) },
        .smoothstep => .{ .scalar = sdf_common.smoothstep(asScalar(args[0]), asScalar(args[1]), asScalar(args[2])) },
        .circle => .{ .scalar = sdf_common.sdfCircle(asVec2(args[0]), asScalar(args[1])) },
        .box => .{ .scalar = sdf_common.sdfBox(asVec2(args[0]), asVec2(args[1])) },
        .wrapdx => .{ .scalar = wrappedDeltaX(asScalar(args[0]), asScalar(args[1]), asScalar(args[2])) },
        .hash01 => .{ .scalar = sdf_common.hash01(scalarToU32(asScalar(args[0]))) },
        .hash_signed => .{ .scalar = sdf_common.hashSigned(scalarToU32(asScalar(args[0]))) },
        .hash_coords01 => .{ .scalar = sdf_common.hashCoords01(
            scalarToI32(asScalar(args[0])),
            scalarToI32(asScalar(args[1])),
            scalarToU32(asScalar(args[2])),
        ) },
        .vec2 => .{ .vec2 = .{ .x = asScalar(args[0]), .y = asScalar(args[1]) } },
        .rgba => .{ .rgba = .{
            .r = asScalar(args[0]),
            .g = asScalar(args[1]),
            .b = asScalar(args[2]),
            .a = asScalar(args[3]),
        } },
    };
}

fn asScalar(value: RuntimeValue) f32 {
    return switch (value) {
        .scalar => |scalar| scalar,
        else => unreachable,
    };
}

fn asVec2(value: RuntimeValue) sdf_common.Vec2 {
    return switch (value) {
        .vec2 => |vec| vec,
        else => unreachable,
    };
}

fn asRgba(value: RuntimeValue) sdf_common.ColorRgba {
    return switch (value) {
        .rgba => |rgba| rgba,
        else => unreachable,
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
