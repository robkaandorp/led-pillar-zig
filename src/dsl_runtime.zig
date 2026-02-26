const std = @import("std");
const display_logic = @import("display_logic.zig");
const dsl_parser = @import("dsl_parser.zig");
const sdf_common = @import("sdf_common.zig");

pub const PixelInputs = struct {
    time: f32,
    frame: f32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    seed: f32,
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
    seed,
};

const ResolvedSlot = union(enum) {
    input: InputSlot,
    param: usize,
    frame_let: usize,
    let_slot: usize,
};

const BytecodeInstruction = union(enum) {
    push_literal: RuntimeValue,
    push_slot: ResolvedSlot,
    negate,
    add,
    sub,
    mul,
    div,
    call_builtin: BuiltinCall,

    const BuiltinCall = struct {
        builtin: dsl_parser.BuiltinId,
        arg_count: u8,
    };
};

const CompiledExpr = struct {
    instructions: []const BytecodeInstruction,
    max_stack_depth: usize,
};

const CompiledStatement = union(enum) {
    let_decl: LetDecl,
    blend: *const CompiledExpr,
    if_stmt: IfStmt,
    for_stmt: ForStmt,

    const LetDecl = struct {
        slot: usize,
        expr: *const CompiledExpr,
    };

    const IfStmt = struct {
        condition: *const CompiledExpr,
        then_statements: []const CompiledStatement,
        else_statements: []const CompiledStatement,
    };

    const ForStmt = struct {
        index_slot: usize,
        start_inclusive: usize,
        end_exclusive: usize,
        statements: []const CompiledStatement,
    };
};

const CompiledFrame = struct {
    statements: []const CompiledStatement,
    let_count: usize,
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
    frame: CompiledFrame,
    layers: []const CompiledLayer,
};

const BytecodeFormatVersion: u16 = 3;
const BytecodeInstructionOpcode = enum(u8) {
    push_literal = 1,
    push_slot = 2,
    negate = 3,
    add = 4,
    sub = 5,
    mul = 6,
    div = 7,
    call_builtin = 8,
};

const BytecodeRuntimeValueTag = enum(u8) {
    scalar = 1,
    vec2 = 2,
    rgba = 3,
};

const BytecodeSlotTag = enum(u8) {
    input = 1,
    param = 2,
    frame_let = 3,
    let_slot = 4,
};

const BytecodeStatementOpcode = enum(u8) {
    let_decl = 1,
    blend = 2,
    if_stmt = 3,
    for_stmt = 4,
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    compiled: CompiledProgram,
    compile_arena: std.heap.ArenaAllocator,
    param_values: []f32,
    frame_values: []RuntimeValue,
    let_values: []RuntimeValue,
    expr_stack: []RuntimeValue,
    has_dynamic_params: bool,
    seed: f32,

    pub fn init(allocator: std.mem.Allocator, program: dsl_parser.Program) !Evaluator {
        var compile_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer compile_arena.deinit();

        const compiled = try compileProgram(compile_arena.allocator(), program);

        const param_values = try allocator.alloc(f32, compiled.params.len);
        errdefer allocator.free(param_values);

        const frame_values = try allocator.alloc(RuntimeValue, compiled.frame.let_count);
        errdefer allocator.free(frame_values);

        var max_let_count: usize = compiled.frame.let_count;
        for (compiled.layers) |layer| {
            max_let_count = @max(max_let_count, layer.let_count);
        }

        const let_values = try allocator.alloc(RuntimeValue, max_let_count);
        errdefer allocator.free(let_values);
        const expr_stack = try allocator.alloc(RuntimeValue, requiredExprStackSize(compiled));
        errdefer allocator.free(expr_stack);

        var has_dynamic_params = false;
        for (compiled.params) |param| {
            has_dynamic_params = has_dynamic_params or param.depends_on_xy;
        }

        return .{
            .allocator = allocator,
            .compiled = compiled,
            .compile_arena = compile_arena,
            .param_values = param_values,
            .frame_values = frame_values,
            .let_values = let_values,
            .expr_stack = expr_stack,
            .has_dynamic_params = has_dynamic_params,
            .seed = generateSeed(),
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.allocator.free(self.param_values);
        self.allocator.free(self.frame_values);
        self.allocator.free(self.let_values);
        self.allocator.free(self.expr_stack);
        self.compile_arena.deinit();
    }

    pub fn writeBytecodeBinary(self: *const Evaluator, writer: anytype) !void {
        try writer.writeAll("DSLB");
        try writeU16(writer, BytecodeFormatVersion);
        try writeU16(writer, 0);
        try serializeCompiledProgram(writer, self.compiled);
    }

    pub fn evaluatePixel(self: *Evaluator, inputs: PixelInputs) !sdf_common.ColorRgba {
        self.evaluateParams(inputs, .all);
        self.evaluateFrame(inputs);
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
            self.executeStatements(layer.statements, inputs, false, &out);
        }

        return out;
    }

    fn evaluateFrame(self: *Evaluator, inputs: PixelInputs) void {
        var dummy = sdf_common.ColorRgba{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
        self.executeStatements(self.compiled.frame.statements, inputs, true, &dummy);
    }

    fn executeStatements(
        self: *Evaluator,
        statements: []const CompiledStatement,
        inputs: PixelInputs,
        frame_mode: bool,
        out: *sdf_common.ColorRgba,
    ) void {
        for (statements) |statement| {
            switch (statement) {
                .let_decl => |let_decl| {
                    const value = self.evalExpr(let_decl.expr, inputs);
                    if (frame_mode) {
                        self.frame_values[let_decl.slot] = value;
                        self.let_values[let_decl.slot] = value;
                    } else {
                        self.let_values[let_decl.slot] = value;
                    }
                },
                .blend => |blend_expr| {
                    if (frame_mode) unreachable;
                    const src = asRgba(self.evalExpr(blend_expr, inputs));
                    out.* = sdf_common.ColorRgba.blendOver(src, out.*);
                },
                .if_stmt => |if_stmt| {
                    const condition = asScalar(self.evalExpr(if_stmt.condition, inputs));
                    if (condition > 0.0) {
                        self.executeStatements(if_stmt.then_statements, inputs, frame_mode, out);
                    } else {
                        self.executeStatements(if_stmt.else_statements, inputs, frame_mode, out);
                    }
                },
                .for_stmt => |for_stmt| {
                    var i = for_stmt.start_inclusive;
                    while (i < for_stmt.end_exclusive) : (i += 1) {
                        const index_value = RuntimeValue{ .scalar = @as(f32, @floatFromInt(i)) };
                        if (frame_mode) {
                            self.frame_values[for_stmt.index_slot] = index_value;
                            self.let_values[for_stmt.index_slot] = index_value;
                        } else {
                            self.let_values[for_stmt.index_slot] = index_value;
                        }
                        self.executeStatements(for_stmt.statements, inputs, frame_mode, out);
                    }
                },
            }
        }
    }

    pub fn renderFrame(
        self: *Evaluator,
        display: *const display_logic.DisplayBuffer,
        frame: []display_logic.Color,
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
            .seed = self.seed,
        };
        self.evaluateParams(frame_inputs, .frame_static);
        self.evaluateFrame(frame_inputs);

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
                    .seed = self.seed,
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

    fn evalExpr(self: *Evaluator, expr: *const CompiledExpr, inputs: PixelInputs) RuntimeValue {
        var stack_len: usize = 0;
        for (expr.instructions) |instruction| {
            switch (instruction) {
                .push_literal => |literal| {
                    self.expr_stack[stack_len] = literal;
                    stack_len += 1;
                },
                .push_slot => |slot| {
                    self.expr_stack[stack_len] = self.loadSlot(slot, inputs);
                    stack_len += 1;
                },
                .negate => {
                    self.expr_stack[stack_len - 1] = .{ .scalar = -asScalar(self.expr_stack[stack_len - 1]) };
                },
                .add => {
                    const rhs = asScalar(self.expr_stack[stack_len - 1]);
                    const lhs = asScalar(self.expr_stack[stack_len - 2]);
                    stack_len -= 1;
                    self.expr_stack[stack_len - 1] = .{ .scalar = lhs + rhs };
                },
                .sub => {
                    const rhs = asScalar(self.expr_stack[stack_len - 1]);
                    const lhs = asScalar(self.expr_stack[stack_len - 2]);
                    stack_len -= 1;
                    self.expr_stack[stack_len - 1] = .{ .scalar = lhs - rhs };
                },
                .mul => {
                    const rhs = asScalar(self.expr_stack[stack_len - 1]);
                    const lhs = asScalar(self.expr_stack[stack_len - 2]);
                    stack_len -= 1;
                    self.expr_stack[stack_len - 1] = .{ .scalar = lhs * rhs };
                },
                .div => {
                    const rhs = asScalar(self.expr_stack[stack_len - 1]);
                    const lhs = asScalar(self.expr_stack[stack_len - 2]);
                    stack_len -= 1;
                    self.expr_stack[stack_len - 1] = .{ .scalar = lhs / rhs };
                },
                .call_builtin => |call| {
                    const arg_count = @as(usize, call.arg_count);
                    const arg_start = stack_len - arg_count;
                    const value = evalBuiltin(call.builtin, self.expr_stack[arg_start..stack_len]);
                    stack_len = arg_start;
                    self.expr_stack[stack_len] = value;
                    stack_len += 1;
                },
            }
        }
        return self.expr_stack[0];
    }

    fn loadSlot(self: *const Evaluator, slot: ResolvedSlot, inputs: PixelInputs) RuntimeValue {
        return switch (slot) {
            .param => |idx| .{ .scalar = self.param_values[idx] },
            .frame_let => |idx| self.frame_values[idx],
            .let_slot => |idx| self.let_values[idx],
            .input => |input| switch (input) {
                .time => .{ .scalar = inputs.time },
                .frame => .{ .scalar = inputs.frame },
                .x => .{ .scalar = inputs.x },
                .y => .{ .scalar = inputs.y },
                .width => .{ .scalar = inputs.width },
                .height => .{ .scalar = inputs.height },
                .seed => .{ .scalar = inputs.seed },
            },
        };
    }
};

fn compileProgram(allocator: std.mem.Allocator, program: dsl_parser.Program) !CompiledProgram {
    var param_lookup = std.StringHashMap(usize).init(allocator);
    defer param_lookup.deinit();
    var builtin_constants = std.StringHashMap(f32).init(allocator);
    defer builtin_constants.deinit();
    try populateBuiltinConstants(&builtin_constants);

    const params = try allocator.alloc(CompiledParam, program.params.len);
    for (program.params, 0..) |param, idx| {
        const compiled_expr = try compileExpr(allocator, param.value, &param_lookup, null, null, &builtin_constants);
        params[idx] = .{
            .expr = compiled_expr,
            .depends_on_xy = compiledExprDependsOnXY(compiled_expr, params[0..idx]),
        };
        try param_lookup.put(param.name, idx);
    }

    var frame_lookup = std.StringHashMap(usize).init(allocator);
    defer frame_lookup.deinit();
    const frame = try compileFrame(allocator, program.frame_statements, &param_lookup, &frame_lookup, &builtin_constants);

    const layers = try allocator.alloc(CompiledLayer, program.layers.len);
    for (program.layers, 0..) |layer, idx| {
        layers[idx] = try compileLayer(allocator, layer, &param_lookup, &frame_lookup, &builtin_constants);
    }

    return .{
        .params = params,
        .frame = frame,
        .layers = layers,
    };
}

fn compileFrame(
    allocator: std.mem.Allocator,
    frame_statements: []const dsl_parser.Statement,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: *std.StringHashMap(usize),
    const_lookup: *const std.StringHashMap(f32),
) !CompiledFrame {
    var let_slot: usize = 0;
    const statements = try compileStatements(
        allocator,
        frame_statements,
        param_lookup,
        null,
        frame_lookup,
        const_lookup,
        false,
        &let_slot,
    );
    return .{
        .statements = statements,
        .let_count = let_slot,
    };
}

fn compileLayer(
    allocator: std.mem.Allocator,
    layer: dsl_parser.Layer,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: *const std.StringHashMap(usize),
    const_lookup: *const std.StringHashMap(f32),
) !CompiledLayer {
    var let_lookup = std.StringHashMap(usize).init(allocator);
    defer let_lookup.deinit();
    var let_slot: usize = 0;
    const statements = try compileStatements(
        allocator,
        layer.statements,
        param_lookup,
        frame_lookup,
        &let_lookup,
        const_lookup,
        true,
        &let_slot,
    );

    return .{
        .statements = statements,
        .let_count = let_slot,
    };
}

fn compileStatements(
    allocator: std.mem.Allocator,
    statements: []const dsl_parser.Statement,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: ?*const std.StringHashMap(usize),
    let_lookup: *std.StringHashMap(usize),
    const_lookup: ?*const std.StringHashMap(f32),
    allow_blend: bool,
    let_slot: *usize,
) ![]const CompiledStatement {
    var compiled = std.ArrayList(CompiledStatement).empty;

    for (statements) |statement| {
        switch (statement) {
            .let_decl => |let_decl| {
                const compiled_expr = try compileExpr(allocator, let_decl.value, param_lookup, frame_lookup, let_lookup, const_lookup);
                try compiled.append(allocator, .{
                    .let_decl = .{
                        .slot = let_slot.*,
                        .expr = compiled_expr,
                    },
                });
                try let_lookup.put(let_decl.name, let_slot.*);
                let_slot.* += 1;
            },
            .blend => |blend_expr| {
                if (!allow_blend) return error.InvalidFrameStatement;
                const compiled_expr = try compileExpr(allocator, blend_expr, param_lookup, frame_lookup, let_lookup, const_lookup);
                try compiled.append(allocator, .{ .blend = compiled_expr });
            },
            .if_stmt => |if_stmt| {
                const condition = try compileExpr(allocator, if_stmt.condition, param_lookup, frame_lookup, let_lookup, const_lookup);

                var then_lookup = try cloneUsizeMap(allocator, let_lookup);
                defer then_lookup.deinit();
                var then_slot = let_slot.*;
                const then_statements = try compileStatements(
                    allocator,
                    if_stmt.then_statements,
                    param_lookup,
                    frame_lookup,
                    &then_lookup,
                    const_lookup,
                    allow_blend,
                    &then_slot,
                );

                var else_lookup = try cloneUsizeMap(allocator, let_lookup);
                defer else_lookup.deinit();
                var else_slot = let_slot.*;
                const else_statements = try compileStatements(
                    allocator,
                    if_stmt.else_statements,
                    param_lookup,
                    frame_lookup,
                    &else_lookup,
                    const_lookup,
                    allow_blend,
                    &else_slot,
                );

                let_slot.* = @max(then_slot, else_slot);
                try compiled.append(allocator, .{
                    .if_stmt = .{
                        .condition = condition,
                        .then_statements = then_statements,
                        .else_statements = else_statements,
                    },
                });
            },
            .for_range => |for_stmt| {
                const index_slot = let_slot.*;
                var iter_lookup = try cloneUsizeMap(allocator, let_lookup);
                defer iter_lookup.deinit();
                try iter_lookup.put(for_stmt.index_name, index_slot);
                var body_slot = index_slot + 1;
                const iter_statements = try compileStatements(
                    allocator,
                    for_stmt.statements,
                    param_lookup,
                    frame_lookup,
                    &iter_lookup,
                    const_lookup,
                    allow_blend,
                    &body_slot,
                );
                let_slot.* = @max(let_slot.*, body_slot);
                try compiled.append(allocator, .{ .for_stmt = .{
                    .index_slot = index_slot,
                    .start_inclusive = for_stmt.start_inclusive,
                    .end_exclusive = for_stmt.end_exclusive,
                    .statements = iter_statements,
                } });
            },
        }
    }

    return compiled.toOwnedSlice(allocator);
}

fn compileExpr(
    allocator: std.mem.Allocator,
    expr: *const dsl_parser.Expr,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: ?*const std.StringHashMap(usize),
    let_lookup: ?*const std.StringHashMap(usize),
    const_lookup: ?*const std.StringHashMap(f32),
) !*const CompiledExpr {
    var instructions = std.ArrayList(BytecodeInstruction).empty;
    try emitExprBytecode(&instructions, allocator, expr, param_lookup, frame_lookup, let_lookup, const_lookup);

    const owned = try instructions.toOwnedSlice(allocator);
    const ptr = try allocator.create(CompiledExpr);
    ptr.* = .{
        .instructions = owned,
        .max_stack_depth = computeExprMaxStackDepth(owned),
    };
    return ptr;
}

fn emitExprBytecode(
    instructions: *std.ArrayList(BytecodeInstruction),
    allocator: std.mem.Allocator,
    expr: *const dsl_parser.Expr,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: ?*const std.StringHashMap(usize),
    let_lookup: ?*const std.StringHashMap(usize),
    const_lookup: ?*const std.StringHashMap(f32),
) !void {
    switch (expr.*) {
        .number => |number| {
            try instructions.append(allocator, .{ .push_literal = .{ .scalar = number } });
        },
        .identifier => |name| {
            if (const_lookup) |lookup| {
                if (lookup.get(name)) |value| {
                    try instructions.append(allocator, .{ .push_literal = .{ .scalar = value } });
                    return;
                }
            }
            const slot = try resolveSlot(name, param_lookup, frame_lookup, let_lookup);
            try instructions.append(allocator, .{ .push_slot = slot });
        },
        .unary => |unary_expr| {
            try emitExprBytecode(instructions, allocator, unary_expr.operand, param_lookup, frame_lookup, let_lookup, const_lookup);
            switch (unary_expr.op) {
                .negate => try instructions.append(allocator, .negate),
            }
        },
        .binary => |binary_expr| {
            try emitExprBytecode(instructions, allocator, binary_expr.left, param_lookup, frame_lookup, let_lookup, const_lookup);
            try emitExprBytecode(instructions, allocator, binary_expr.right, param_lookup, frame_lookup, let_lookup, const_lookup);
            const op: BytecodeInstruction = switch (binary_expr.op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
            };
            try instructions.append(allocator, op);
        },
        .call => |call_expr| {
            for (call_expr.args) |arg| {
                try emitExprBytecode(instructions, allocator, arg, param_lookup, frame_lookup, let_lookup, const_lookup);
            }
            try instructions.append(allocator, .{ .call_builtin = .{
                .builtin = call_expr.builtin,
                .arg_count = @as(u8, @intCast(call_expr.args.len)),
            } });
        },
    }
}

fn computeExprMaxStackDepth(instructions: []const BytecodeInstruction) usize {
    var depth: usize = 0;
    var max_depth: usize = 1;
    for (instructions) |instruction| {
        switch (instruction) {
            .push_literal, .push_slot => depth += 1,
            .negate => {},
            .add, .sub, .mul, .div => depth -= 1,
            .call_builtin => |call| {
                depth = depth - @as(usize, call.arg_count) + 1;
            },
        }
        max_depth = @max(max_depth, depth);
    }
    return max_depth;
}

fn resolveSlot(
    name: []const u8,
    param_lookup: *const std.StringHashMap(usize),
    frame_lookup: ?*const std.StringHashMap(usize),
    let_lookup: ?*const std.StringHashMap(usize),
) !ResolvedSlot {
    if (let_lookup) |lookup| {
        if (lookup.get(name)) |idx| return .{ .let_slot = idx };
    }
    if (frame_lookup) |lookup| {
        if (lookup.get(name)) |idx| return .{ .frame_let = idx };
    }
    if (param_lookup.get(name)) |idx| return .{ .param = idx };
    if (inputSlotFromName(name)) |input| return .{ .input = input };
    return error.UnknownIdentifier;
}

fn cloneUsizeMap(allocator: std.mem.Allocator, source: *const std.StringHashMap(usize)) !std.StringHashMap(usize) {
    var out = std.StringHashMap(usize).init(allocator);
    var it = source.iterator();
    while (it.next()) |entry| {
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn populateBuiltinConstants(lookup: *std.StringHashMap(f32)) !void {
    try lookup.put("PI", @as(f32, std.math.pi));
    try lookup.put("TAU", @as(f32, 2.0 * std.math.pi));
}

fn inputSlotFromName(name: []const u8) ?InputSlot {
    if (std.mem.eql(u8, name, "time")) return .time;
    if (std.mem.eql(u8, name, "frame")) return .frame;
    if (std.mem.eql(u8, name, "x")) return .x;
    if (std.mem.eql(u8, name, "y")) return .y;
    if (std.mem.eql(u8, name, "width")) return .width;
    if (std.mem.eql(u8, name, "height")) return .height;
    if (std.mem.eql(u8, name, "seed")) return .seed;
    return null;
}

/// Generate a random seed in [0, 1) for per-activation randomness.
fn generateSeed() f32 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const raw = std.mem.readInt(u32, &buf, .little);
    return @as(f32, @floatFromInt(raw >> 8)) / 16777216.0; // 2^24
}

fn compiledExprDependsOnXY(expr: *const CompiledExpr, prior_params: []const CompiledParam) bool {
    for (expr.instructions) |instruction| {
        switch (instruction) {
            .push_slot => |slot| switch (slot) {
                .param => |idx| if (prior_params[idx].depends_on_xy) return true,
                .input => |input| if (input == .x or input == .y) return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn requiredExprStackSize(compiled: CompiledProgram) usize {
    var max_stack: usize = 1;
    for (compiled.params) |param| {
        max_stack = @max(max_stack, param.expr.max_stack_depth);
    }
    max_stack = @max(max_stack, maxExprStackInStatements(compiled.frame.statements));
    for (compiled.layers) |layer| {
        max_stack = @max(max_stack, maxExprStackInStatements(layer.statements));
    }
    return max_stack;
}

fn maxExprStackInStatements(statements: []const CompiledStatement) usize {
    var max_stack: usize = 1;
    for (statements) |statement| {
        switch (statement) {
            .let_decl => |let_decl| {
                max_stack = @max(max_stack, let_decl.expr.max_stack_depth);
            },
            .blend => |blend_expr| {
                max_stack = @max(max_stack, blend_expr.max_stack_depth);
            },
            .if_stmt => |if_stmt| {
                max_stack = @max(max_stack, if_stmt.condition.max_stack_depth);
                max_stack = @max(max_stack, maxExprStackInStatements(if_stmt.then_statements));
                max_stack = @max(max_stack, maxExprStackInStatements(if_stmt.else_statements));
            },
            .for_stmt => |for_stmt| {
                max_stack = @max(max_stack, maxExprStackInStatements(for_stmt.statements));
            },
        }
    }
    return max_stack;
}

fn serializeCompiledProgram(writer: anytype, compiled: CompiledProgram) !void {
    try writeU32(writer, try asU32(compiled.params.len));
    for (compiled.params) |param| {
        try writeU8(writer, if (param.depends_on_xy) 1 else 0);
        try serializeCompiledExpr(writer, param.expr);
    }

    try serializeCompiledStatements(writer, compiled.frame.statements);
    try writeU32(writer, try asU32(compiled.layers.len));
    for (compiled.layers) |layer| {
        try serializeCompiledStatements(writer, layer.statements);
    }
}

fn serializeCompiledStatements(writer: anytype, statements: []const CompiledStatement) !void {
    try writeU32(writer, try asU32(statements.len));
    for (statements) |statement| {
        switch (statement) {
            .let_decl => |let_decl| {
                try writeU8(writer, @intFromEnum(BytecodeStatementOpcode.let_decl));
                try writeU32(writer, try asU32(let_decl.slot));
                try serializeCompiledExpr(writer, let_decl.expr);
            },
            .blend => |blend_expr| {
                try writeU8(writer, @intFromEnum(BytecodeStatementOpcode.blend));
                try serializeCompiledExpr(writer, blend_expr);
            },
            .if_stmt => |if_stmt| {
                try writeU8(writer, @intFromEnum(BytecodeStatementOpcode.if_stmt));
                try serializeCompiledExpr(writer, if_stmt.condition);
                try serializeCompiledStatements(writer, if_stmt.then_statements);
                try serializeCompiledStatements(writer, if_stmt.else_statements);
            },
            .for_stmt => |for_stmt| {
                try writeU8(writer, @intFromEnum(BytecodeStatementOpcode.for_stmt));
                try writeU32(writer, try asU32(for_stmt.index_slot));
                try writeU32(writer, try asU32(for_stmt.start_inclusive));
                try writeU32(writer, try asU32(for_stmt.end_exclusive));
                try serializeCompiledStatements(writer, for_stmt.statements);
            },
        }
    }
}

fn serializeCompiledExpr(writer: anytype, expr: *const CompiledExpr) !void {
    try writeU32(writer, try asU32(expr.max_stack_depth));
    try writeU32(writer, try asU32(expr.instructions.len));
    for (expr.instructions) |instruction| {
        switch (instruction) {
            .push_literal => |literal| {
                try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.push_literal));
                try serializeRuntimeValue(writer, literal);
            },
            .push_slot => |slot| {
                try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.push_slot));
                try serializeResolvedSlot(writer, slot);
            },
            .negate => try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.negate)),
            .add => try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.add)),
            .sub => try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.sub)),
            .mul => try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.mul)),
            .div => try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.div)),
            .call_builtin => |call| {
                try writeU8(writer, @intFromEnum(BytecodeInstructionOpcode.call_builtin));
                try writeU8(writer, @as(u8, @intCast(@intFromEnum(call.builtin))));
                try writeU8(writer, call.arg_count);
            },
        }
    }
}

fn serializeRuntimeValue(writer: anytype, value: RuntimeValue) !void {
    switch (value) {
        .scalar => |scalar| {
            try writeU8(writer, @intFromEnum(BytecodeRuntimeValueTag.scalar));
            try writeF32(writer, scalar);
        },
        .vec2 => |vec| {
            try writeU8(writer, @intFromEnum(BytecodeRuntimeValueTag.vec2));
            try writeF32(writer, vec.x);
            try writeF32(writer, vec.y);
        },
        .rgba => |rgba| {
            try writeU8(writer, @intFromEnum(BytecodeRuntimeValueTag.rgba));
            try writeF32(writer, rgba.r);
            try writeF32(writer, rgba.g);
            try writeF32(writer, rgba.b);
            try writeF32(writer, rgba.a);
        },
    }
}

fn serializeResolvedSlot(writer: anytype, slot: ResolvedSlot) !void {
    switch (slot) {
        .input => |input| {
            try writeU8(writer, @intFromEnum(BytecodeSlotTag.input));
            try writeU8(writer, @as(u8, @intCast(@intFromEnum(input))));
        },
        .param => |idx| {
            try writeU8(writer, @intFromEnum(BytecodeSlotTag.param));
            try writeU32(writer, try asU32(idx));
        },
        .frame_let => |idx| {
            try writeU8(writer, @intFromEnum(BytecodeSlotTag.frame_let));
            try writeU32(writer, try asU32(idx));
        },
        .let_slot => |idx| {
            try writeU8(writer, @intFromEnum(BytecodeSlotTag.let_slot));
            try writeU32(writer, try asU32(idx));
        },
    }
}

fn asU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.BytecodeValueOutOfRange;
}

fn writeU8(writer: anytype, value: u8) !void {
    var buf = [1]u8{value};
    try writer.writeAll(&buf);
}

fn writeU16(writer: anytype, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeU32(writer: anytype, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeF32(writer: anytype, value: f32) !void {
    try writeU32(writer, @bitCast(value));
}

fn evalBuiltin(builtin: dsl_parser.BuiltinId, args: []const RuntimeValue) RuntimeValue {
    return switch (builtin) {
        .sin => .{ .scalar = std.math.sin(asScalar(args[0])) },
        .cos => .{ .scalar = std.math.cos(asScalar(args[0])) },
        .sqrt => .{ .scalar = @sqrt(asScalar(args[0])) },
        .ln => .{ .scalar = @log(asScalar(args[0])) },
        .log => .{ .scalar = std.math.log10(asScalar(args[0])) },
        .abs => .{ .scalar = @abs(asScalar(args[0])) },
        .floor => .{ .scalar = @floor(asScalar(args[0])) },
        .fract => blk: {
            const value = asScalar(args[0]);
            break :blk .{ .scalar = value - @floor(value) };
        },
        .min => .{ .scalar = @min(asScalar(args[0]), asScalar(args[1])) },
        .max => .{ .scalar = @max(asScalar(args[0]), asScalar(args[1])) },
        .clamp => .{ .scalar = std.math.clamp(asScalar(args[0]), asScalar(args[1]), asScalar(args[2])) },
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

test "Evaluator writes bytecode binary blob" {
    const source =
        \\effect bytecode_blob
        \\param speed = 0.5
        \\layer l {
        \\  let alpha = (sin(time * TAU * speed) * 0.5) + 0.5
        \\  blend rgba(alpha, 0.0, 0.0, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try Evaluator.init(std.testing.allocator, program);
    defer evaluator.deinit();

    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(std.testing.allocator);
    const blob_writer = blob.writer(std.testing.allocator);
    try evaluator.writeBytecodeBinary(blob_writer);

    try std.testing.expect(blob.items.len > 8);
    try std.testing.expectEqualStrings("DSLB", blob.items[0..4]);
    try std.testing.expectEqual(@as(u8, BytecodeFormatVersion), blob.items[4]);
    try std.testing.expectEqual(@as(u8, 0), blob.items[5]);
}

test "Evaluator writes bytecode files for bundled v1 DSL examples" {
    const examples_dir_path = "examples" ++ std.fs.path.sep_str ++ "dsl" ++ std.fs.path.sep_str ++ "v1";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.fs.cwd().makePath("bytecode");

    var examples_dir = try std.fs.cwd().openDir(examples_dir_path, .{ .iterate = true });
    defer examples_dir.close();

    var it = examples_dir.iterate();
    var compiled_count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dsl")) continue;

        const source_path = try std.fs.path.join(allocator, &[_][]const u8{ examples_dir_path, entry.name });
        const source = try std.fs.cwd().readFileAlloc(allocator, source_path, std.math.maxInt(usize));
        const program = try dsl_parser.parseAndValidate(allocator, source);
        var evaluator = try Evaluator.init(std.testing.allocator, program);
        defer evaluator.deinit();

        const stem = std.fs.path.stem(entry.name);
        const output_name = try std.fmt.allocPrint(allocator, "{s}.bin", .{stem});
        const output_path = try std.fs.path.join(allocator, &[_][]const u8{ "bytecode", output_name });

        var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
        defer file.close();
        var file_buffer: [16 * 1024]u8 = undefined;
        var file_writer = file.writer(&file_buffer);
        const writer = &file_writer.interface;
        try evaluator.writeBytecodeBinary(writer);
        try writer.flush();
        compiled_count += 1;
    }

    try std.testing.expect(compiled_count > 0);
}

test "bytecode preserves for loops without unrolling" {
    const source =
        \\effect compact_loops
        \\layer l {
        \\  for i in 0..128 {
        \\    let alpha = fract(i * 0.125)
        \\    blend rgba(alpha, 0.0, 0.0, 0.02)
        \\  }
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try dsl_parser.parseAndValidate(arena.allocator(), source);
    var evaluator = try Evaluator.init(std.testing.allocator, program);
    defer evaluator.deinit();

    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(std.testing.allocator);
    const blob_writer = blob.writer(std.testing.allocator);
    try evaluator.writeBytecodeBinary(blob_writer);

    try std.testing.expect(blob.items.len < 4096);
}

test "Evaluator evaluates v1 builtin expressions" {
    const inputs = PixelInputs{
        .time = 0.0,
        .frame = 12.0,
        .x = 0.2,
        .y = 2.0,
        .width = 30.0,
        .height = 40.0,
        .seed = 0.42,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try evalScalarExpression("sin(0.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try evalScalarExpression("cos(0.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try evalScalarExpression("PI / PI", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try evalScalarExpression("TAU / (PI * 2.0)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("sqrt(0.25)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try evalScalarExpression("ln(2.7182817)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("log(100.0) * 0.25", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), try evalScalarExpression("abs(-0.25)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try evalScalarExpression("floor(0.75)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), try evalScalarExpression("fract(2.75)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), try evalScalarExpression("min(0.2, 0.4)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), try evalScalarExpression("max(0.2, 0.4)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), try evalScalarExpression("clamp(0.3, 0.1, 0.5)", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try evalScalarExpression("clamp(0.8, 0.1, 0.5)", inputs), 0.0001);
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

test "Evaluator resolves seed input" {
    const inputs = PixelInputs{
        .time = 0.0,
        .frame = 0.0,
        .x = 0.0,
        .y = 0.0,
        .width = 30.0,
        .height = 40.0,
        .seed = 0.42,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), try evalScalarExpression("seed", inputs), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.84), try evalScalarExpression("seed * 2.0", inputs), 0.0001);
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
        .seed = 0.42,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), color.r, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), color.g, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), color.b, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.a, 0.0001);
}

test "Evaluator supports frame block, for-range, and if statements" {
    const source =
        \\effect control_flow
        \\frame {
        \\  let base = time * 0.1
        \\}
        \\layer l {
        \\  for i in 0..3 {
        \\    let a = fract(base + (i * 0.5))
        \\    if a {
        \\      blend rgba(a, 0.0, 0.0, 0.5)
        \\    }
        \\  }
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
        .seed = 0.42,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), color.r, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), color.g, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), color.b, 0.0001);
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

    var frame_storage = [_]display_logic.Color{.{}} ** 4;
    try evaluator.renderFrame(&display, frame_storage[0..], 0, 40.0);

    try std.testing.expectEqual(display_logic.Color{ .r = 64, .g = 64, .b = 0, .w = 0 }, frame_storage[0]);
    try std.testing.expectEqual(display_logic.Color{ .r = 191, .g = 64, .b = 0, .w = 0 }, frame_storage[1]);
    try std.testing.expectEqual(display_logic.Color{ .r = 64, .g = 191, .b = 0, .w = 0 }, frame_storage[2]);
    try std.testing.expectEqual(display_logic.Color{ .r = 191, .g = 191, .b = 0, .w = 0 }, frame_storage[3]);
}
