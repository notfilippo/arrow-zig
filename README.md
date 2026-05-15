<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig.

Requires Zig 0.16.0+.

Docs: https://notfilippo.github.io/arrow-zig/

## Example

```zig
const arrow = @import("arrow");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

This runs license checks, generated docs, regular tests, single threaded tests,
and nanoarrow interop tests in both thread modes.

Format and ABI details follow the [Arrow Columnar Format](https://arrow.apache.org/docs/format/Columnar.html)
and [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html).
