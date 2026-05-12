// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const copyright = "Copyright 2026 Filippo Rossi";
const spdx = "SPDX-License-Identifier: Apache-2.0";

const HeaderStyle = enum {
    skip,
    slash,
    hash,
    markdown,
    unknown,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const files = getTrackedFiles(allocator, init.io) catch |err| {
        std.debug.print("git ls-files failed: {}\n", .{err});
        std.process.exit(1);
    };

    var missing = false;
    var paths = std.mem.splitScalar(u8, files, 0);
    while (paths.next()) |file| {
        if (file.len == 0) {
            continue;
        }

        const style = headerStyle(file);
        if (style == .skip) {
            continue;
        }

        const contents = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            file,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) {
                continue;
            }
            std.debug.print("cannot read {s}: {}\n", .{ file, err });
            missing = true;
            continue;
        };

        if (style == .unknown) {
            std.debug.print("unsupported file type: {s}\n", .{file});
            missing = true;
            continue;
        }

        if (!hasHeader(contents, style)) {
            std.debug.print("missing license header: {s}\n", .{file});
            missing = true;
        }
    }

    if (missing) {
        std.process.exit(1);
    }
}

fn getTrackedFiles(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-files", "-z" },
    });
    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return result.stdout;
            }
        },
        else => {},
    }

    std.debug.print("{s}", .{result.stderr});
    return error.GitLsFilesFailed;
}

fn headerStyle(file: []const u8) HeaderStyle {
    if (std.mem.eql(u8, file, "LICENSE")) {
        return .skip;
    }
    if (std.mem.endsWith(u8, file, ".zig") or std.mem.endsWith(u8, file, ".zon")) {
        return .slash;
    }
    if (std.mem.endsWith(u8, file, ".yml") or
        std.mem.endsWith(u8, file, ".yaml") or
        std.mem.endsWith(u8, file, ".sh") or
        std.mem.eql(u8, file, ".gitignore"))
    {
        return .hash;
    }
    if (std.mem.endsWith(u8, file, ".md")) {
        return .markdown;
    }
    return .unknown;
}

fn hasHeader(contents: []const u8, style: HeaderStyle) bool {
    return switch (style) {
        .slash => lineEquals(contents, 1, "// " ++ copyright) and
            lineEquals(contents, 2, "// " ++ spdx),
        .hash => if (hasShebang(contents))
            lineEquals(contents, 2, "# " ++ copyright) and
                lineEquals(contents, 3, "# " ++ spdx)
        else
            lineEquals(contents, 1, "# " ++ copyright) and
                lineEquals(contents, 2, "# " ++ spdx),
        .markdown => lineEquals(contents, 1, "<!--") and
            lineEquals(contents, 2, copyright) and
            lineEquals(contents, 3, spdx) and
            lineEquals(contents, 4, "-->"),
        else => false,
    };
}

fn hasShebang(contents: []const u8) bool {
    return std.mem.startsWith(u8, contents, "#!");
}

fn lineEquals(contents: []const u8, line_number: usize, expected: []const u8) bool {
    const line = lineAt(contents, line_number) orelse return false;
    return std.mem.eql(u8, line, expected);
}

fn lineAt(contents: []const u8, line_number: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var current: usize = 1;
    while (lines.next()) |line| : (current += 1) {
        if (current == line_number) {
            return std.mem.trimEnd(u8, line, "\r");
        }
    }
    return null;
}

test "header style detection" {
    try std.testing.expectEqual(HeaderStyle.skip, headerStyle("LICENSE"));
    try std.testing.expectEqual(HeaderStyle.slash, headerStyle("src/root.zig"));
    try std.testing.expectEqual(HeaderStyle.slash, headerStyle("build.zig.zon"));
    try std.testing.expectEqual(HeaderStyle.hash, headerStyle(".github/workflows/ci.yml"));
    try std.testing.expectEqual(HeaderStyle.hash, headerStyle(".gitignore"));
    try std.testing.expectEqual(HeaderStyle.markdown, headerStyle("README.md"));
    try std.testing.expectEqual(HeaderStyle.unknown, headerStyle("image.png"));
}

test "header checks" {
    try std.testing.expect(hasHeader(
        "// Copyright 2026 Filippo Rossi\n// SPDX-License-Identifier: Apache-2.0\n\n",
        .slash,
    ));
    try std.testing.expect(hasHeader(
        "# Copyright 2026 Filippo Rossi\n# SPDX-License-Identifier: Apache-2.0\n\n",
        .hash,
    ));
    try std.testing.expect(hasHeader(
        "#!/bin/sh\n# Copyright 2026 Filippo Rossi\n# SPDX-License-Identifier: Apache-2.0\n\n",
        .hash,
    ));
    try std.testing.expect(hasHeader(
        "<!--\nCopyright 2026 Filippo Rossi\nSPDX-License-Identifier: Apache-2.0\n-->\n\n",
        .markdown,
    ));
    try std.testing.expect(!hasHeader(
        "#!/bin/sh\n# SPDX-License-Identifier: Apache-2.0\n",
        .hash,
    ));
}
