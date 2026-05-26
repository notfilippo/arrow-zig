<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig.

Requires Zig 0.16.0+.

Docs: <https://notfilippo.github.io/arrow-zig/>

## Getting Started

From a Zig project:

```sh
zig fetch --save=arrow git+https://github.com/notfilippo/arrow-zig.git
```

Then add the dependency module to the executable or library in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const arrow_dep = b.dependency("arrow", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("arrow", arrow_dep.module("arrow"));

    b.installArtifact(exe);
}
```

Pass `.single_threaded = true` to `b.dependency("arrow", .{ ... })` to
disable atomic buffer refcounts for single-threaded use.

## Example

```zig
const arrow = @import("arrow");
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var b = arrow.builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);

    const data = try b.finish();
    defer data.deinit();

    const values = try arrow.array.NumericArray(i32).fromData(data);
    std.debug.print("{}\n", .{values.value(2)});
}
```

## Contributing

Run the full local check before sending changes:

```sh
zig build ci
```

This runs license checks, generated docs, regular tests and nanoarrow interop tests.

Format and ABI details follow the [Arrow Columnar Format](https://arrow.apache.org/docs/format/Columnar.html)
and [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html).
