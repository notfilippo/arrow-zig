<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig.

Requires Zig 0.16.0+.

Docs: https://notfilippo.github.io/arrow-zig/

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

## C++ Parity Matrix

<table>
<thead><tr><th>Area</th><th>Status</th><th>Notes</th></tr></thead>
<tbody>
<tr><td>Data types</td><td>Complete</td><td>Core C++ type metadata, including dictionary, extension, union, run-end encoded, views, decimals, intervals</td></tr>
<tr><td>Array storage</td><td>Strong</td><td><code>ArrayData</code>, slicing, ref counts, quick <code>validate</code>, full <code>validateFull</code>, logical null counts</td></tr>
<tr><td>Typed arrays</td><td>Strong</td><td>Thin views over storage for all implemented layouts, no generic dynamic <code>Array</code> facade</td></tr>
<tr><td>Builders</td><td>Good</td><td>Primitive, binary, nested, dictionary with existing dictionaries, no generic <code>MakeBuilder</code></td></tr>
<tr><td>Schema and batches</td><td>Good</td><td>Schemas, fields, record batches, struct batch conversion</td></tr>
<tr><td>C Data Interface</td><td>Strong</td><td>Schema, array, record batch, and stream import/export</td></tr>
<tr><td>Compute, IPC, files</td><td>Missing</td><td>No compute kernels, IPC, Parquet, dataset, table, or chunked array layer yet</td></tr>
</tbody>
</table>

## Contributing

Run the full local check before sending changes:

```sh
zig build ci
```

This runs license checks, generated docs, regular tests, single threaded tests,
and nanoarrow interop tests in both thread modes.

Format and ABI details follow the [Arrow Columnar Format](https://arrow.apache.org/docs/format/Columnar.html)
and [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html).
