// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const max_file_size = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const root = std.Io.Dir.cwd();
    const root_contents = try root.readFileAlloc(init.io, "src/root.zig", allocator, .limited(max_file_size));

    var src = try root.openDir(init.io, "src", .{ .iterate = true });
    defer src.close(init.io);

    var walker = try src.walk(allocator);
    defer walker.deinit();

    var failed = false;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (skipPath(entry.path)) continue;

        const contents = try entry.dir.readFileAlloc(init.io, entry.basename, allocator, .limited(max_file_size));
        if (!hasTestDecl(contents)) continue;
        if (rootImportsPath(root_contents, entry.path)) continue;

        std.debug.print("missing root test import: _ = @import(\"{s}\");\n", .{entry.path});
        failed = true;
    }

    if (failed) std.process.exit(1);
}

fn skipPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "root.zig") or
        std.mem.eql(u8, path, "cdi/nanoarrow_test.zig");
}

fn hasTestDecl(contents: []const u8) bool {
    return std.mem.startsWith(u8, contents, "test ") or
        std.mem.indexOf(u8, contents, "\ntest ") != null;
}

fn rootImportsPath(root_contents: []const u8, path: []const u8) bool {
    var buffer: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "@import(\"{s}\")", .{path}) catch return false;
    return std.mem.indexOf(u8, root_contents, needle) != null;
}

test "detects test declarations" {
    try std.testing.expect(hasTestDecl("test \"x\" {}\n"));
    try std.testing.expect(hasTestDecl("const x = 1;\ntest \"x\" {}\n"));
    try std.testing.expect(!hasTestDecl("const text = \"test x\";\n"));
}

test "matches root imports" {
    const root_contents =
        \\test {
        \\    _ = @import("array/common.zig");
        \\}
    ;

    try std.testing.expect(rootImportsPath(root_contents, "array/common.zig"));
    try std.testing.expect(!rootImportsPath(root_contents, "array_missing.zig"));
}
