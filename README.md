<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig. [Arrow Columnar Format spec](https://arrow.apache.org/docs/format/Columnar.html).

Requires Zig 0.16.0+.

## Build

```sh
zig build
zig build test
zig build test -Dnanoarrow=true
zig build ci
```

`zig build ci` runs license checks, docs, regular tests, single threaded tests,
and nanoarrow interop tests in both thread modes.

Pass `-Dsingle_threaded=true` to use plain refcount ops instead of atomics.

## Examples

Build and read an `int32` array:

```zig
const arrow = @import("arrow");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var b = arrow.builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);

    const data = try b.finish();
    defer data.deinit();

    const arr = try arrow.array.NumericArray(i32).fromData(data);
    std.debug.print("{} {}\n", .{ arr.value(0), arr.value(2) });

    const s = arr.slice(0, 2);
    std.debug.print("slice nulls: {}\n", .{s.nullCount()});
}
```

Build UTF8 strings:

```zig
var b = arrow.builder.Utf8Builder.init(allocator);
defer b.deinit();

try b.append("alpha");
try b.appendNull();
try b.append("beta");

const data = try b.finish();
defer data.deinit();

const arr = try arrow.array.Utf8Array.fromData(data);
std.debug.print("{s}\n", .{arr.value(2)});
```

Use a logical type over numeric storage:

```zig
var b = try arrow.builder.NumericBuilder(i32).initType(allocator, .date32);
defer b.deinit();
```

Round trip through the Arrow C Data Interface:

```zig
var out: arrow.cdi.ArrowArray = undefined;
try arrow.cdi.exportArray(allocator, data, &out);
errdefer if (out.release) |release| release(&out);

const imported = try arrow.cdi.importArray(allocator, data.type, &out);
defer imported.deinit();
```

## Notes

- `finish()` returns a refcounted `*arrow.array.ArrayData`. Call `deinit()`.
- Typed arrays are cheap views over `ArrayData`; they do not retain it.
- `slice()` returns another view. Use `sliceOwned()` when the slice needs its own retained data.
- Arrow Zig allocations are 64 byte aligned and padded.
- Imported C Data Interface buffers are zero copy, immutable, and keep source alignment.
- `cdi.importArray()` consumes the top level `ArrowArray` on success.
