const std = @import("std");

pub const ValueType = enum {
    scalar,
    vec2,
    rgba,
};

pub const BuiltinId = enum {
    sin,
    cos,
    abs,
    min,
    max,
    smoothstep,
    circle,
    box,
    wrapdx,
    hash01,
    hash_signed,
    hash_coords01,
    vec2,
    rgba,
};

pub const Expr = union(enum) {
    number: f32,
    identifier: []const u8,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,

    pub const UnaryOp = enum {
        negate,
    };

    pub const BinaryOp = enum {
        add,
        sub,
        mul,
        div,
    };

    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const BinaryExpr = struct {
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    };

    pub const CallExpr = struct {
        builtin: BuiltinId,
        args: []const *Expr,
    };
};

pub const Statement = union(enum) {
    let_decl: LetDecl,
    blend: *Expr,

    pub const LetDecl = struct {
        name: []const u8,
        value: *Expr,
    };
};

pub const Param = struct {
    name: []const u8,
    value: *Expr,
};

pub const Layer = struct {
    name: []const u8,
    statements: []const Statement,
};

pub const Program = struct {
    effect_name: []const u8,
    params: []const Param,
    layers: []const Layer,
    has_emit: bool,
};

const BuiltinSpec = struct {
    id: BuiltinId,
    name: []const u8,
    return_type: ValueType,
    arg_types: []const ValueType,
};

const builtin_specs = [_]BuiltinSpec{
    .{ .id = .sin, .name = "sin", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .cos, .name = "cos", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .abs, .name = "abs", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .min, .name = "min", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar } },
    .{ .id = .max, .name = "max", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar } },
    .{ .id = .smoothstep, .name = "smoothstep", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar, .scalar } },
    .{ .id = .circle, .name = "circle", .return_type = .scalar, .arg_types = &[_]ValueType{ .vec2, .scalar } },
    .{ .id = .box, .name = "box", .return_type = .scalar, .arg_types = &[_]ValueType{ .vec2, .vec2 } },
    .{ .id = .wrapdx, .name = "wrapdx", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar, .scalar } },
    .{ .id = .hash01, .name = "hash01", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .hash_signed, .name = "hashSigned", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .hash_coords01, .name = "hashCoords01", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar, .scalar } },
    .{ .id = .vec2, .name = "vec2", .return_type = .vec2, .arg_types = &[_]ValueType{ .scalar, .scalar } },
    .{ .id = .rgba, .name = "rgba", .return_type = .rgba, .arg_types = &[_]ValueType{ .scalar, .scalar, .scalar, .scalar } },
};

const keyword_names = [_][]const u8{
    "effect",
    "param",
    "layer",
    "let",
    "blend",
    "emit",
};

const input_names = [_][]const u8{
    "time",
    "frame",
    "x",
    "y",
    "width",
    "height",
};

const max_call_args: usize = 8;

const TokenTag = enum {
    identifier,
    number,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    equal,
    plus,
    minus,
    star,
    slash,
    eof,
};

const Token = struct {
    tag: TokenTag,
    lexeme: []const u8 = "",
    number: f32 = 0.0,
};

const Lexer = struct {
    source: []const u8,
    index: usize = 0,

    fn nextToken(self: *Lexer) !Token {
        self.skipTrivia();
        if (self.index >= self.source.len) return .{ .tag = .eof };

        const ch = self.source[self.index];
        switch (ch) {
            '(' => {
                self.index += 1;
                return .{ .tag = .l_paren };
            },
            ')' => {
                self.index += 1;
                return .{ .tag = .r_paren };
            },
            '{' => {
                self.index += 1;
                return .{ .tag = .l_brace };
            },
            '}' => {
                self.index += 1;
                return .{ .tag = .r_brace };
            },
            ',' => {
                self.index += 1;
                return .{ .tag = .comma };
            },
            '=' => {
                self.index += 1;
                return .{ .tag = .equal };
            },
            '+' => {
                self.index += 1;
                return .{ .tag = .plus };
            },
            '-' => {
                self.index += 1;
                return .{ .tag = .minus };
            },
            '*' => {
                self.index += 1;
                return .{ .tag = .star };
            },
            '/' => {
                self.index += 1;
                return .{ .tag = .slash };
            },
            else => {},
        }

        if (isIdentifierStart(ch)) {
            const start = self.index;
            self.index += 1;
            while (self.index < self.source.len and isIdentifierContinue(self.source[self.index])) : (self.index += 1) {}
            return .{
                .tag = .identifier,
                .lexeme = self.source[start..self.index],
            };
        }

        if (std.ascii.isDigit(ch)) {
            const start = self.index;
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {}
            if (self.index < self.source.len and self.source[self.index] == '.') {
                self.index += 1;
                while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {}
            }
            const slice = self.source[start..self.index];
            return .{
                .tag = .number,
                .lexeme = slice,
                .number = try std.fmt.parseFloat(f32, slice),
            };
        }

        return error.InvalidToken;
    }

    fn skipTrivia(self: *Lexer) void {
        while (true) {
            while (self.index < self.source.len and std.ascii.isWhitespace(self.source[self.index])) : (self.index += 1) {}
            if (self.index + 1 < self.source.len and self.source[self.index] == '/' and self.source[self.index + 1] == '/') {
                self.index += 2;
                while (self.index < self.source.len and self.source[self.index] != '\n') : (self.index += 1) {}
                continue;
            }
            return;
        }
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,

    fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var lexer = Lexer{ .source = source };
        const first = try lexer.nextToken();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = first,
        };
    }

    fn parseProgram(self: *Parser) !Program {
        var effect_name: ?[]const u8 = null;
        var has_emit = false;
        var params = std.ArrayList(Param).empty;
        var layers = std.ArrayList(Layer).empty;

        while (self.current.tag != .eof) {
            if (self.current.tag != .identifier) return error.UnexpectedToken;
            const keyword = self.current.lexeme;

            if (std.mem.eql(u8, keyword, "effect")) {
                try self.advance();
                const name = try self.expectIdentifier();
                if (effect_name != null) return error.DuplicateEffect;
                effect_name = name;
                continue;
            }

            if (std.mem.eql(u8, keyword, "param")) {
                try self.advance();
                const name = try self.expectIdentifier();
                try self.expect(.equal);
                const value = try self.parseExpression();
                try params.append(self.allocator, .{
                    .name = name,
                    .value = value,
                });
                continue;
            }

            if (std.mem.eql(u8, keyword, "layer")) {
                try self.advance();
                const layer = try self.parseLayer();
                try layers.append(self.allocator, layer);
                continue;
            }

            if (std.mem.eql(u8, keyword, "emit")) {
                try self.advance();
                if (has_emit) return error.DuplicateEmit;
                has_emit = true;
                continue;
            }

            return error.UnknownTopLevelStatement;
        }

        const parsed_effect_name = effect_name orelse return error.MissingEffect;
        if (layers.items.len == 0) return error.MissingLayer;
        if (!has_emit) return error.MissingEmit;

        return .{
            .effect_name = parsed_effect_name,
            .params = try params.toOwnedSlice(self.allocator),
            .layers = try layers.toOwnedSlice(self.allocator),
            .has_emit = has_emit,
        };
    }

    fn parseLayer(self: *Parser) !Layer {
        const name = try self.expectIdentifier();
        try self.expect(.l_brace);

        var statements = std.ArrayList(Statement).empty;
        while (self.current.tag != .r_brace) {
            if (self.current.tag == .eof) return error.UnexpectedEof;
            if (self.current.tag != .identifier) return error.UnknownLayerStatement;

            const keyword = self.current.lexeme;
            if (std.mem.eql(u8, keyword, "let")) {
                try self.advance();
                const let_name = try self.expectIdentifier();
                try self.expect(.equal);
                const value = try self.parseExpression();
                try statements.append(self.allocator, .{
                    .let_decl = .{
                        .name = let_name,
                        .value = value,
                    },
                });
                continue;
            }

            if (std.mem.eql(u8, keyword, "blend")) {
                try self.advance();
                const value = try self.parseExpression();
                try statements.append(self.allocator, .{
                    .blend = value,
                });
                continue;
            }

            return error.UnknownLayerStatement;
        }

        try self.expect(.r_brace);
        return .{
            .name = name,
            .statements = try statements.toOwnedSlice(self.allocator),
        };
    }

    fn parseExpression(self: *Parser) anyerror!*Expr {
        return self.parseAdditive();
    }

    fn parseAdditive(self: *Parser) anyerror!*Expr {
        var expr = try self.parseMultiplicative();
        while (self.current.tag == .plus or self.current.tag == .minus) {
            const op: Expr.BinaryOp = if (self.current.tag == .plus) .add else .sub;
            try self.advance();
            const rhs = try self.parseMultiplicative();
            expr = try self.makeExpr(.{
                .binary = .{
                    .op = op,
                    .left = expr,
                    .right = rhs,
                },
            });
        }
        return expr;
    }

    fn parseMultiplicative(self: *Parser) anyerror!*Expr {
        var expr = try self.parseUnary();
        while (self.current.tag == .star or self.current.tag == .slash) {
            const op: Expr.BinaryOp = if (self.current.tag == .star) .mul else .div;
            try self.advance();
            const rhs = try self.parseUnary();
            expr = try self.makeExpr(.{
                .binary = .{
                    .op = op,
                    .left = expr,
                    .right = rhs,
                },
            });
        }
        return expr;
    }

    fn parseUnary(self: *Parser) anyerror!*Expr {
        if (self.current.tag == .minus) {
            try self.advance();
            const operand = try self.parseUnary();
            return self.makeExpr(.{
                .unary = .{
                    .op = .negate,
                    .operand = operand,
                },
            });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) anyerror!*Expr {
        switch (self.current.tag) {
            .number => {
                const value = self.current.number;
                try self.advance();
                return self.makeExpr(.{ .number = value });
            },
            .identifier => {
                const name = self.current.lexeme;
                try self.advance();

                if (try self.consume(.l_paren)) {
                    const builtin = builtinIdFromName(name) orelse return error.UnknownBuiltin;
                    var args = std.ArrayList(*Expr).empty;
                    if (self.current.tag != .r_paren) {
                        while (true) {
                            try args.append(self.allocator, try self.parseExpression());
                            if (try self.consume(.comma)) continue;
                            break;
                        }
                    }
                    try self.expect(.r_paren);
                    return self.makeExpr(.{
                        .call = .{
                            .builtin = builtin,
                            .args = try args.toOwnedSlice(self.allocator),
                        },
                    });
                }

                return self.makeExpr(.{
                    .identifier = name,
                });
            },
            .l_paren => {
                try self.advance();
                const inner = try self.parseExpression();
                try self.expect(.r_paren);
                return inner;
            },
            else => return error.ExpectedExpression,
        }
    }

    fn makeExpr(self: *Parser, expr: Expr) !*Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ptr;
    }

    fn expect(self: *Parser, tag: TokenTag) !void {
        if (self.current.tag != tag) return error.UnexpectedToken;
        try self.advance();
    }

    fn expectIdentifier(self: *Parser) ![]const u8 {
        if (self.current.tag != .identifier) return error.ExpectedIdentifier;
        const name = self.current.lexeme;
        try self.advance();
        return name;
    }

    fn consume(self: *Parser, tag: TokenTag) !bool {
        if (self.current.tag != tag) return false;
        try self.advance();
        return true;
    }

    fn advance(self: *Parser) !void {
        self.current = try self.lexer.nextToken();
    }
};

pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8) !Program {
    var parser = try Parser.init(allocator, source);
    var program = try parser.parseProgram();
    try validateProgram(allocator, &program);
    return program;
}

fn validateProgram(allocator: std.mem.Allocator, program: *const Program) !void {
    var param_names = std.StringHashMap(void).init(allocator);
    defer param_names.deinit();
    var param_types = std.StringHashMap(ValueType).init(allocator);
    defer param_types.deinit();
    var layer_names = std.StringHashMap(void).init(allocator);
    defer layer_names.deinit();

    for (program.params) |param| {
        if (isReservedIdentifier(param.name)) return error.ReservedIdentifier;
        if (param_names.contains(param.name)) return error.DuplicateParamName;
        const param_type = try inferExprType(param.value, &param_types, null);
        if (param_type != .scalar) return error.InvalidParamType;
        try param_names.put(param.name, {});
        try param_types.put(param.name, .scalar);
    }

    for (program.layers) |layer| {
        if (isReservedIdentifier(layer.name)) return error.ReservedIdentifier;
        if (layer_names.contains(layer.name)) return error.DuplicateLayerName;
        try layer_names.put(layer.name, {});

        var let_types = std.StringHashMap(ValueType).init(allocator);
        defer let_types.deinit();

        for (layer.statements) |statement| {
            switch (statement) {
                .let_decl => |let_decl| {
                    if (isReservedIdentifier(let_decl.name)) return error.ReservedIdentifier;
                    if (param_types.contains(let_decl.name) or let_types.contains(let_decl.name)) {
                        return error.DuplicateLetName;
                    }
                    const let_type = try inferExprType(let_decl.value, &param_types, &let_types);
                    try let_types.put(let_decl.name, let_type);
                },
                .blend => |blend_expr| {
                    const blend_type = try inferExprType(blend_expr, &param_types, &let_types);
                    if (blend_type != .rgba) return error.InvalidBlendType;
                },
            }
        }
    }
}

fn inferExprType(
    expr: *const Expr,
    param_types: *const std.StringHashMap(ValueType),
    let_types: ?*const std.StringHashMap(ValueType),
) !ValueType {
    switch (expr.*) {
        .number => return .scalar,
        .identifier => |name| return inferIdentifierType(name, param_types, let_types),
        .unary => |unary_expr| {
            const operand_type = try inferExprType(unary_expr.operand, param_types, let_types);
            if (operand_type != .scalar) return error.InvalidUnaryOperandType;
            return .scalar;
        },
        .binary => |binary_expr| {
            const lhs_type = try inferExprType(binary_expr.left, param_types, let_types);
            const rhs_type = try inferExprType(binary_expr.right, param_types, let_types);
            if (lhs_type != .scalar or rhs_type != .scalar) return error.InvalidBinaryOperandType;
            return .scalar;
        },
        .call => |call_expr| {
            if (call_expr.args.len > max_call_args) return error.InvalidBuiltinArity;
            var arg_types: [max_call_args]ValueType = undefined;
            for (call_expr.args, 0..) |arg, idx| {
                arg_types[idx] = try inferExprType(arg, param_types, let_types);
            }
            return resolveBuiltinCall(call_expr.builtin, arg_types[0..call_expr.args.len]);
        },
    }
}

fn inferIdentifierType(
    name: []const u8,
    param_types: *const std.StringHashMap(ValueType),
    let_types: ?*const std.StringHashMap(ValueType),
) !ValueType {
    if (let_types) |scope| {
        if (scope.get(name)) |typ| return typ;
    }
    if (param_types.get(name)) |typ| return typ;
    if (isInputName(name)) return .scalar;
    return error.UnknownIdentifier;
}

fn resolveBuiltinCall(builtin: BuiltinId, arg_types: []const ValueType) !ValueType {
    const spec = builtinSpecFromId(builtin);
    if (arg_types.len != spec.arg_types.len) return error.InvalidBuiltinArity;
    for (arg_types, spec.arg_types) |arg_type, expected_type| {
        if (arg_type != expected_type) return error.InvalidBuiltinArgumentType;
    }
    return spec.return_type;
}

fn isReservedIdentifier(name: []const u8) bool {
    return isKeyword(name) or isBuiltinName(name) or isInputName(name);
}

fn isKeyword(name: []const u8) bool {
    for (keyword_names) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return true;
    }
    return false;
}

fn isBuiltinName(name: []const u8) bool {
    return builtinIdFromName(name) != null;
}

fn builtinIdFromName(name: []const u8) ?BuiltinId {
    for (builtin_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.id;
    }
    return null;
}

fn builtinSpecFromId(builtin: BuiltinId) BuiltinSpec {
    for (builtin_specs) |spec| {
        if (spec.id == builtin) return spec;
    }
    unreachable;
}

fn isInputName(name: []const u8) bool {
    for (input_names) |input_name| {
        if (std.mem.eql(u8, input_name, name)) return true;
    }
    return false;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "parseAndValidate accepts valid v1 DSL" {
    const source =
        \\effect aurora_v1
        \\param speed = 0.28
        \\param phase = sin(time * speed)
        \\
        \\layer ribbon {
        \\  let theta = (x / width) * 6.2831853
        \\  let local = vec2(wrapdx(x, width * 0.5, width), y - (height * 0.5))
        \\  let d = circle(local, 3.0)
        \\  let a = (1.0 - smoothstep(0.0, 1.9, abs(d))) * max(hash01(frame), 0.2)
        \\  blend rgba(0.35, 0.95, 0.75, min(a, 1.0))
        \\}
        \\
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseAndValidate(arena.allocator(), source);
    try std.testing.expectEqualStrings("aurora_v1", program.effect_name);
    try std.testing.expectEqual(@as(usize, 2), program.params.len);
    try std.testing.expectEqual(@as(usize, 1), program.layers.len);
    try std.testing.expect(program.has_emit);
}

test "parseAndValidate accepts bundled v1 DSL examples" {
    const example_paths = [_][]const u8{
        "examples\\dsl\\v1\\aurora.dsl",
        "examples\\dsl\\v1\\campfire.dsl",
        "examples\\dsl\\v1\\rain-ripple.dsl",
    };

    for (example_paths) |example_path| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const source = try std.fs.cwd().readFileAlloc(arena.allocator(), example_path, std.math.maxInt(usize));
        _ = try parseAndValidate(arena.allocator(), source);
    }
}

test "parseAndValidate rejects unknown identifiers" {
    const source =
        \\effect bad_identifier
        \\layer l {
        \\  blend rgba(unknown_value, 0.0, 0.0, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnknownIdentifier, parseAndValidate(arena.allocator(), source));
}

test "parseAndValidate rejects invalid builtin arity" {
    const source =
        \\effect bad_arity
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, sin())
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBuiltinArity, parseAndValidate(arena.allocator(), source));
}

test "parseAndValidate requires layer and emit" {
    const missing_emit_source =
        \\effect no_emit
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
    ;

    const missing_layer_source =
        \\effect no_layer
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.MissingEmit, parseAndValidate(arena.allocator(), missing_emit_source));
    try std.testing.expectError(error.MissingLayer, parseAndValidate(arena.allocator(), missing_layer_source));
}

test "parseAndValidate rejects duplicate names" {
    const duplicate_param_source =
        \\effect dup_param
        \\param speed = 0.1
        \\param speed = 0.2
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
        \\emit
    ;

    const duplicate_layer_source =
        \\effect dup_layer
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
        \\emit
    ;

    const duplicate_let_source =
        \\effect dup_let
        \\param speed = 0.1
        \\layer l {
        \\  let speed = 0.2
        \\  blend rgba(1.0, 1.0, 1.0, speed)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.DuplicateParamName, parseAndValidate(arena.allocator(), duplicate_param_source));
    try std.testing.expectError(error.DuplicateLayerName, parseAndValidate(arena.allocator(), duplicate_layer_source));
    try std.testing.expectError(error.DuplicateLetName, parseAndValidate(arena.allocator(), duplicate_let_source));
}

test "parseAndValidate enforces blend expression type and known builtins" {
    const invalid_blend_type_source =
        \\effect blend_scalar
        \\layer l {
        \\  blend sin(time)
        \\}
        \\emit
    ;

    const unknown_builtin_source =
        \\effect unknown_builtin
        \\layer l {
        \\  let x1 = mystery(x)
        \\  blend rgba(1.0, 1.0, 1.0, x1)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBlendType, parseAndValidate(arena.allocator(), invalid_blend_type_source));
    try std.testing.expectError(error.UnknownBuiltin, parseAndValidate(arena.allocator(), unknown_builtin_source));
}
