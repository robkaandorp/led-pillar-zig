const std = @import("std");

pub const ValueType = enum {
    scalar,
    vec2,
    rgba,
};

pub const BuiltinId = enum {
    sin,
    cos,
    sqrt,
    ln,
    log,
    abs,
    floor,
    fract,
    min,
    max,
    clamp,
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
    if_stmt: IfStmt,
    for_range: ForRange,

    pub const LetDecl = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const IfStmt = struct {
        condition: *Expr,
        then_statements: []const Statement,
        else_statements: []const Statement,
    };

    pub const ForRange = struct {
        index_name: []const u8,
        start_inclusive: usize,
        end_exclusive: usize,
        statements: []const Statement,
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
    frame_statements: []const Statement,
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
    .{ .id = .sqrt, .name = "sqrt", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .ln, .name = "ln", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .log, .name = "log", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .abs, .name = "abs", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .floor, .name = "floor", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .fract, .name = "fract", .return_type = .scalar, .arg_types = &[_]ValueType{.scalar} },
    .{ .id = .min, .name = "min", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar } },
    .{ .id = .max, .name = "max", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar } },
    .{ .id = .clamp, .name = "clamp", .return_type = .scalar, .arg_types = &[_]ValueType{ .scalar, .scalar, .scalar } },
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
    "frame",
    "let",
    "if",
    "else",
    "for",
    "in",
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

const builtin_constant_names = [_][]const u8{
    "PI",
    "TAU",
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
    dotdot,
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
            '.' => {
                if (self.index + 1 < self.source.len and self.source[self.index + 1] == '.') {
                    self.index += 2;
                    return .{ .tag = .dotdot };
                }
                return error.InvalidToken;
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
            if (self.index + 1 < self.source.len and self.source[self.index] == '.' and std.ascii.isDigit(self.source[self.index + 1])) {
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
        var frame_statements: []const Statement = try self.allocator.alloc(Statement, 0);
        var has_frame_block = false;
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

            if (std.mem.eql(u8, keyword, "frame")) {
                try self.advance();
                if (has_frame_block) return error.DuplicateFrameBlock;
                has_frame_block = true;
                try self.expect(.l_brace);
                frame_statements = try self.parseStatementsUntil(.r_brace, false);
                try self.expect(.r_brace);
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
            .frame_statements = frame_statements,
            .layers = try layers.toOwnedSlice(self.allocator),
            .has_emit = has_emit,
        };
    }

    fn parseLayer(self: *Parser) !Layer {
        const name = try self.expectIdentifier();
        try self.expect(.l_brace);
        const statements = try self.parseStatementsUntil(.r_brace, true);

        try self.expect(.r_brace);
        return .{
            .name = name,
            .statements = statements,
        };
    }

    fn parseStatementsUntil(self: *Parser, end_tag: TokenTag, allow_blend: bool) anyerror![]const Statement {
        var statements = std.ArrayList(Statement).empty;
        while (self.current.tag != end_tag) {
            if (self.current.tag == .eof) return error.UnexpectedEof;
            try statements.append(self.allocator, try self.parseStatement(allow_blend));
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser, allow_blend: bool) anyerror!Statement {
        if (self.current.tag != .identifier) return error.UnknownLayerStatement;

        const keyword = self.current.lexeme;
        if (std.mem.eql(u8, keyword, "let")) {
            try self.advance();
            const let_name = try self.expectIdentifier();
            try self.expect(.equal);
            const value = try self.parseExpression();
            return .{
                .let_decl = .{
                    .name = let_name,
                    .value = value,
                },
            };
        }

        if (std.mem.eql(u8, keyword, "blend")) {
            if (!allow_blend) return error.InvalidFrameStatement;
            try self.advance();
            const value = try self.parseExpression();
            return .{ .blend = value };
        }

        if (std.mem.eql(u8, keyword, "if")) {
            try self.advance();
            const condition = try self.parseExpression();
            try self.expect(.l_brace);
            const then_statements = try self.parseStatementsUntil(.r_brace, allow_blend);
            try self.expect(.r_brace);

            var else_statements: []const Statement = try self.allocator.alloc(Statement, 0);
            if (self.current.tag == .identifier and std.mem.eql(u8, self.current.lexeme, "else")) {
                try self.advance();
                try self.expect(.l_brace);
                else_statements = try self.parseStatementsUntil(.r_brace, allow_blend);
                try self.expect(.r_brace);
            }

            return .{
                .if_stmt = .{
                    .condition = condition,
                    .then_statements = then_statements,
                    .else_statements = else_statements,
                },
            };
        }

        if (std.mem.eql(u8, keyword, "for")) {
            try self.advance();
            const index_name = try self.expectIdentifier();
            if (self.current.tag != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) {
                return error.ExpectedInKeyword;
            }
            try self.advance();
            const start_inclusive = try self.expectNonNegativeInteger();
            try self.expect(.dotdot);
            const end_exclusive = try self.expectNonNegativeInteger();
            try self.expect(.l_brace);
            const statements = try self.parseStatementsUntil(.r_brace, allow_blend);
            try self.expect(.r_brace);
            return .{
                .for_range = .{
                    .index_name = index_name,
                    .start_inclusive = start_inclusive,
                    .end_exclusive = end_exclusive,
                    .statements = statements,
                },
            };
        }

        return error.UnknownLayerStatement;
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

    fn expectNonNegativeInteger(self: *Parser) !usize {
        if (self.current.tag != .number) return error.ExpectedIntegerLiteral;
        const value = self.current.number;
        if (value < 0.0) return error.ExpectedIntegerLiteral;
        const floored = @floor(value);
        if (floored != value) return error.ExpectedIntegerLiteral;
        const result = @as(usize, @intFromFloat(floored));
        try self.advance();
        return result;
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
    var frame_types = std.StringHashMap(ValueType).init(allocator);
    defer frame_types.deinit();
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

    try validateStatements(allocator, program.frame_statements, false, &param_types, &frame_types, true);

    for (program.layers) |layer| {
        if (isReservedIdentifier(layer.name)) return error.ReservedIdentifier;
        if (layer_names.contains(layer.name)) return error.DuplicateLayerName;
        try layer_names.put(layer.name, {});

        var visible_let_types = try cloneTypeMap(allocator, &frame_types);
        defer visible_let_types.deinit();
        try validateStatements(allocator, layer.statements, true, &param_types, &visible_let_types, false);
    }
}

fn validateStatements(
    allocator: std.mem.Allocator,
    statements: []const Statement,
    allow_blend: bool,
    param_types: *const std.StringHashMap(ValueType),
    visible_let_types: *std.StringHashMap(ValueType),
    frame_mode: bool,
) !void {
    for (statements) |statement| {
        switch (statement) {
            .let_decl => |let_decl| {
                if (isReservedIdentifier(let_decl.name)) return error.ReservedIdentifier;
                if (param_types.contains(let_decl.name) or visible_let_types.contains(let_decl.name)) {
                    return error.DuplicateLetName;
                }
                if (frame_mode and exprUsesXYInput(let_decl.value)) return error.InvalidFrameExpressionInput;
                const let_type = try inferExprType(let_decl.value, param_types, visible_let_types);
                try visible_let_types.put(let_decl.name, let_type);
            },
            .blend => |blend_expr| {
                if (!allow_blend) return error.InvalidFrameStatement;
                const blend_type = try inferExprType(blend_expr, param_types, visible_let_types);
                if (blend_type != .rgba) return error.InvalidBlendType;
            },
            .if_stmt => |if_stmt| {
                if (frame_mode and exprUsesXYInput(if_stmt.condition)) return error.InvalidFrameExpressionInput;
                const condition_type = try inferExprType(if_stmt.condition, param_types, visible_let_types);
                if (condition_type != .scalar) return error.InvalidIfConditionType;

                var then_scope = try cloneTypeMap(allocator, visible_let_types);
                defer then_scope.deinit();
                try validateStatements(allocator, if_stmt.then_statements, allow_blend, param_types, &then_scope, frame_mode);

                var else_scope = try cloneTypeMap(allocator, visible_let_types);
                defer else_scope.deinit();
                try validateStatements(allocator, if_stmt.else_statements, allow_blend, param_types, &else_scope, frame_mode);
            },
            .for_range => |for_stmt| {
                if (for_stmt.end_exclusive <= for_stmt.start_inclusive) return error.InvalidForRange;
                if (isReservedIdentifier(for_stmt.index_name)) return error.ReservedIdentifier;
                if (param_types.contains(for_stmt.index_name) or visible_let_types.contains(for_stmt.index_name)) {
                    return error.DuplicateLetName;
                }

                var loop_scope = try cloneTypeMap(allocator, visible_let_types);
                defer loop_scope.deinit();
                try loop_scope.put(for_stmt.index_name, .scalar);
                try validateStatements(allocator, for_stmt.statements, allow_blend, param_types, &loop_scope, frame_mode);
            },
        }
    }
}

fn cloneTypeMap(allocator: std.mem.Allocator, source: *const std.StringHashMap(ValueType)) !std.StringHashMap(ValueType) {
    var out = std.StringHashMap(ValueType).init(allocator);
    var it = source.iterator();
    while (it.next()) |entry| {
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn exprUsesXYInput(expr: *const Expr) bool {
    switch (expr.*) {
        .number => return false,
        .identifier => |name| return std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y"),
        .unary => |unary_expr| return exprUsesXYInput(unary_expr.operand),
        .binary => |binary_expr| return exprUsesXYInput(binary_expr.left) or exprUsesXYInput(binary_expr.right),
        .call => |call_expr| {
            for (call_expr.args) |arg| {
                if (exprUsesXYInput(arg)) return true;
            }
            return false;
        },
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
    if (isBuiltinConstantName(name)) return .scalar;
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
    return isKeyword(name) or isBuiltinName(name) or isInputName(name) or isBuiltinConstantName(name);
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

fn isBuiltinConstantName(name: []const u8) bool {
    for (builtin_constant_names) |constant_name| {
        if (std.mem.eql(u8, constant_name, name)) return true;
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
        \\param radius = sqrt(9.0)
        \\param natural = ln(2.7182817)
        \\param decade = log(100.0)
        \\param turn = TAU
        \\
        \\layer ribbon {
        \\  let theta = (x / width) * TAU
        \\  let half_turn = PI
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
    try std.testing.expectEqual(@as(usize, 6), program.params.len);
    try std.testing.expectEqual(@as(usize, 0), program.frame_statements.len);
    try std.testing.expectEqual(@as(usize, 1), program.layers.len);
    try std.testing.expect(program.has_emit);
}

test "parseAndValidate accepts frame, for, and if blocks" {
    const source =
        \\effect bubbles
        \\frame {
        \\  let phase_base = time * 0.5
        \\}
        \\layer l {
        \\  for i in 0..3 {
        \\    let pulse = fract(phase_base + (i * 0.2))
        \\    if pulse {
        \\      blend rgba(0.2, 0.4, 0.8, pulse)
        \\    } else {
        \\      blend rgba(0.0, 0.0, 0.0, 0.0)
        \\    }
        \\  }
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseAndValidate(arena.allocator(), source);
    try std.testing.expectEqualStrings("bubbles", program.effect_name);
    try std.testing.expectEqual(@as(usize, 1), program.frame_statements.len);
    try std.testing.expectEqual(@as(usize, 1), program.layers.len);
}

test "parseAndValidate accepts bundled v1 DSL examples" {
    const example_paths = [_][]const u8{
        "examples\\dsl\\v1\\aurora.dsl",
        "examples\\dsl\\v1\\aurora-ribbons-classic.dsl",
        "examples\\dsl\\v1\\campfire.dsl",
        "examples\\dsl\\v1\\soap-bubbles.dsl",
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

test "parseAndValidate rejects invalid frame statements and xy usage" {
    const frame_blend_source =
        \\effect bad_frame_blend
        \\frame {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
        \\layer l {
        \\  blend rgba(0.0, 0.0, 0.0, 1.0)
        \\}
        \\emit
    ;

    const frame_xy_source =
        \\effect bad_frame_xy
        \\frame {
        \\  let bad = x / width
        \\}
        \\layer l {
        \\  blend rgba(0.0, 0.0, 0.0, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidFrameStatement, parseAndValidate(arena.allocator(), frame_blend_source));
    try std.testing.expectError(error.InvalidFrameExpressionInput, parseAndValidate(arena.allocator(), frame_xy_source));
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

test "parseAndValidate recognizes and reserves builtin constants" {
    const valid_source =
        \\effect constants
        \\param spin = TAU
        \\layer l {
        \\  let alpha = PI / spin
        \\  blend rgba(1.0, 1.0, 1.0, alpha)
        \\}
        \\emit
    ;

    const reserved_source =
        \\effect reserved_constant
        \\param PI = 1.0
        \\layer l {
        \\  blend rgba(1.0, 1.0, 1.0, 1.0)
        \\}
        \\emit
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try parseAndValidate(arena.allocator(), valid_source);
    try std.testing.expectError(error.ReservedIdentifier, parseAndValidate(arena.allocator(), reserved_source));
}
