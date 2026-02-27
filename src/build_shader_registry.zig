const std = @import("std");
const dsl_parser = @import("dsl_parser.zig");
const dsl_c_emitter = @import("dsl_c_emitter.zig");

const excluded_files = [_][]const u8{
    "math-benchmark.dsl",
    "blank.dsl",
    "blink.dsl",
};

const ShaderEntry = struct {
    prefix: []const u8,
    name: []const u8,
    filename: []const u8,
    folder: []const u8,
    has_frame: bool,
    has_audio: bool,
};

/// Derive a C-safe prefix from a DSL filename: "chaos-nebula.dsl" → "chaos_nebula"
fn derivePrefix(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(filename);
    const buf = try allocator.alloc(u8, stem.len);
    for (buf, stem) |*out, ch| {
        out.* = if (ch == '-') '_' else ch;
    }
    return buf;
}

/// Derive the "folder" from a relative subpath. Root-level files get "/native",
/// a file in "gradients/foo.dsl" gets "/native/gradients".
fn deriveFolder(allocator: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(rel_path);
    if (dir == null or dir.?.len == 0) {
        return try allocator.dupe(u8, "/native");
    }
    // Normalize separators to forward slash
    const d = dir.?;
    const buf = try std.fmt.allocPrint(allocator, "/native/{s}", .{d});
    for (buf) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return buf;
}

fn isExcluded(filename: []const u8) bool {
    for (&excluded_files) |ex| {
        if (std.mem.eql(u8, filename, ex)) return true;
    }
    return false;
}

/// Generate the combined shader registry C file and header from all DSL files in `dsl_dir_path`.
pub fn generate(allocator: std.mem.Allocator, dsl_dir_path: []const u8, output_dir_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    // Collect DSL files
    var entries = std.ArrayList(ShaderEntry).empty;
    try collectDslFiles(temp, dsl_dir_path, &entries, temp);

    // Sort for deterministic output
    std.mem.sort(ShaderEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ShaderEntry, b: ShaderEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Write registry .c file
    {
        const c_path = try std.fs.path.join(temp, &.{ output_dir_path, "dsl_shader_registry.c" });
        try std.fs.cwd().makePath(output_dir_path);
        var file = try std.fs.cwd().createFile(c_path, .{ .truncate = true });
        defer file.close();
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(&buf);
        const w = &writer.interface;

        // Preamble (types + helpers) once
        try dsl_c_emitter.writePreambleC(w);
        try w.writeAll("\n");

        // Emit each shader's functions
        for (entries.items) |entry| {
            const dsl_path = try std.fs.path.join(temp, &.{ dsl_dir_path, entry.filename });
            const source = try std.fs.cwd().readFileAlloc(temp, dsl_path, std.math.maxInt(usize));
            const program = try dsl_parser.parseAndValidate(temp, source);
            try dsl_c_emitter.writeShaderFunctions(temp, w, program, entry.prefix);
            try w.writeAll("\n");
        }

        // Registry array
        try w.writeAll(
            \\typedef struct {
            \\    const char *name;
            \\    const char *folder;
            \\    void (*eval_pixel)(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color);
            \\    int has_frame_func;
            \\    void (*eval_frame)(float time, float frame);
            \\    int has_audio_func;
            \\    float (*eval_audio)(float time, float seed);
            \\} dsl_shader_entry_t;
            \\
            \\
        );

        try w.print("const dsl_shader_entry_t dsl_shader_registry[] = {{\n", .{});
        for (entries.items) |entry| {
            try w.print("    {{ .name = \"{s}\", .folder = \"{s}\", .eval_pixel = {s}_eval_pixel", .{ entry.name, entry.folder, entry.prefix });
            if (entry.has_frame) {
                try w.print(", .has_frame_func = 1, .eval_frame = {s}_eval_frame", .{entry.prefix});
            } else {
                try w.writeAll(", .has_frame_func = 0, .eval_frame = (void(*)(float,float))0");
            }
            if (entry.has_audio) {
                try w.print(", .has_audio_func = 1, .eval_audio = {s}_eval_audio", .{entry.prefix});
            } else {
                try w.writeAll(", .has_audio_func = 0, .eval_audio = (float(*)(float,float))0");
            }
            try w.writeAll(" },\n");
        }
        try w.writeAll("};\n\n");
        try w.print("const int dsl_shader_registry_count = {d};\n\n", .{entries.items.len});

        // Lookup functions
        try w.writeAll(
            \\#include <string.h>
            \\
            \\const dsl_shader_entry_t *dsl_shader_find(const char *name) {
            \\    for (int i = 0; i < dsl_shader_registry_count; i++) {
            \\        if (strcmp(dsl_shader_registry[i].name, name) == 0) {
            \\            return &dsl_shader_registry[i];
            \\        }
            \\    }
            \\    return (const dsl_shader_entry_t *)0;
            \\}
            \\
            \\const dsl_shader_entry_t *dsl_shader_get(int index) {
            \\    if (index < 0 || index >= dsl_shader_registry_count) {
            \\        return (const dsl_shader_entry_t *)0;
            \\    }
            \\    return &dsl_shader_registry[index];
            \\}
            \\
        );

        try w.flush();
    }

    // Write header file
    {
        const h_path = try std.fs.path.join(temp, &.{ output_dir_path, "dsl_shader_registry.h" });
        var file = try std.fs.cwd().createFile(h_path, .{ .truncate = true });
        defer file.close();
        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        const w = &writer.interface;

        try w.writeAll(
            \\#ifndef DSL_SHADER_REGISTRY_H
            \\#define DSL_SHADER_REGISTRY_H
            \\
            \\typedef struct {
            \\    float r;
            \\    float g;
            \\    float b;
            \\    float a;
            \\} dsl_color_t;
            \\
            \\typedef struct {
            \\    const char *name;
            \\    const char *folder;
            \\    void (*eval_pixel)(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color);
            \\    int has_frame_func;
            \\    void (*eval_frame)(float time, float frame);
            \\    int has_audio_func;
            \\    float (*eval_audio)(float time, float seed);
            \\} dsl_shader_entry_t;
            \\
            \\extern const dsl_shader_entry_t dsl_shader_registry[];
            \\extern const int dsl_shader_registry_count;
            \\
            \\const dsl_shader_entry_t *dsl_shader_find(const char *name);
            \\const dsl_shader_entry_t *dsl_shader_get(int index);
            \\
            \\#endif /* DSL_SHADER_REGISTRY_H */
            \\
        );

        try w.flush();
    }
}

fn collectDslFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    entries: *std.ArrayList(ShaderEntry),
    list_alloc: std.mem.Allocator,
) !void {
    try collectDslFilesRecursive(allocator, base_dir, "", entries, list_alloc);
}

fn collectDslFilesRecursive(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    rel_dir: []const u8,
    entries: *std.ArrayList(ShaderEntry),
    list_alloc: std.mem.Allocator,
) !void {
    const full_dir = if (rel_dir.len > 0)
        try std.fs.path.join(allocator, &.{ base_dir, rel_dir })
    else
        try allocator.dupe(u8, base_dir);

    var dir = std.fs.cwd().openDir(full_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_rel = if (rel_dir.len > 0)
                try std.fs.path.join(allocator, &.{ rel_dir, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            try collectDslFilesRecursive(allocator, base_dir, sub_rel, entries, list_alloc);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".dsl")) {
            if (isExcluded(entry.name)) continue;

            const rel_path = if (rel_dir.len > 0)
                try std.fs.path.join(allocator, &.{ rel_dir, entry.name })
            else
                try allocator.dupe(u8, entry.name);

            const filename = try allocator.dupe(u8, entry.name);
            const prefix = try derivePrefix(allocator, filename);
            const folder = try deriveFolder(allocator, rel_path);
            const stem = std.fs.path.stem(filename);
            const name = try allocator.dupe(u8, stem);

            // Check if the shader has a frame block by parsing
            const full_path = try std.fs.path.join(allocator, &.{ base_dir, rel_path });
            const source = try std.fs.cwd().readFileAlloc(allocator, full_path, std.math.maxInt(usize));
            const program = try dsl_parser.parseAndValidate(allocator, source);

            try entries.append(list_alloc, .{
                .prefix = prefix,
                .name = name,
                .filename = rel_path,
                .folder = folder,
                .has_frame = program.frame_statements.len > 0,
                .has_audio = program.audio_statements.len > 0,
            });
        }
    }
}

test "derivePrefix converts hyphens to underscores and strips extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p1 = try derivePrefix(arena.allocator(), "chaos-nebula.dsl");
    try std.testing.expectEqualStrings("chaos_nebula", p1);

    const p2 = try derivePrefix(arena.allocator(), "gradient.dsl");
    try std.testing.expectEqualStrings("gradient", p2);
}

test "deriveFolder returns /native for root-level files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const f1 = try deriveFolder(arena.allocator(), "gradient.dsl");
    try std.testing.expectEqualStrings("/native", f1);
}

test "deriveFolder returns /native/subdir for subfolder files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const f1 = try deriveFolder(arena.allocator(), "gradients/warm.dsl");
    try std.testing.expectEqualStrings("/native/gradients", f1);
}

test "isExcluded filters utility shaders" {
    try std.testing.expect(isExcluded("blank.dsl"));
    try std.testing.expect(isExcluded("blink.dsl"));
    try std.testing.expect(isExcluded("math-benchmark.dsl"));
    try std.testing.expect(!isExcluded("aurora.dsl"));
}
