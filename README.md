<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig. [Arrow Columnar Format spec](https://arrow.apache.org/docs/format/Columnar.html).

Requires Zig 0.16.0+.

## Build

```sh
zig build        # build library
zig build test   # run all tests
```

Pass `-Dsingle_threaded=true` to swap atomic reference-count operations for plain integer ops (no fences, no lock prefix). Useful for single-threaded pipelines where the overhead is unnecessary. Read `arrow.config.thread_mode` when code needs to inspect the selected mode.

## Quick example

```zig
const arrow = @import("arrow");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var b = arrow.Int32Builder.init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);

    const data = try b.finish();
    defer data.deinit();

    const arr = try arrow.Int32Array.fromData(data);
    std.debug.print("len={} null_count={}\n", .{ arr.len, arr.nullCount() });
    std.debug.print("arr[0]={} arr[2]={}\n", .{ arr.value(0), arr.value(2) });

    // Zero-copy non-owning slice.
    const s = arr.slice(0, 2);
    std.debug.print("s[1] is null: {}\n", .{s.isNull(1)});
}
```

For logical temporal types on numeric storage, initialize the builder with an explicit type:

```zig
var b = try arrow.NumericBuilder(i32).initType(allocator, .date32);
```

## Ownership

Builders own temporary buffers. `finish()` transfers a refcounted `ArrayData`
reference to the caller. Call `deinit()` when that reference is no longer
needed.

`ArrayData`, `Buffer`, and external owner handles are refcounted. `retain()`
adds one reference. `deinit()` drops one reference and frees storage when the
count reaches zero.

`ArrayData.initOwned()` consumes the supplied buffers, children, and dictionary
on success. On error, caller ownership is unchanged. `ArrayData.initRetained()`
retains each supplied object, so the caller keeps its existing references.

## Arrow C Data Interface

`arrow.cdi` exports schemas and arrays, and imports arrays when the caller
supplies the `datatype.DataType`.

`cdi.importArray(allocator, ty, &arr)` consumes the top level `ArrowArray` on
success. The input is marked released. The returned `ArrayData` keeps the moved
C array alive and calls its release callback when the final imported array,
child, dictionary, or buffer reference is dropped.

Imported CDI buffers are zero copy and immutable. The importer trusts producer
padding from the Arrow contract, checks 64 byte alignment for non null buffers,
and does not inspect padding bytes. Do not mutate imported CDI buffers.

## Layout guarantees

- **64-byte alignment.** All buffers are allocated with 64-byte alignment per the Arrow spec (SIMD-safe reads without masking).
- **Zeroed padding.** Internal buffer padding and newly reserved tail capacity are zeroed.
- **LSB-first bitmaps.** Validity and boolean values use LSB-first bit packing.
- **Deferred null count.** `null_count` may be `arrow.unknown_null_count` after a `slice()`. `nullCount()` computes on demand without mutating the view. Builders track the count eagerly during construction.
- **Views + owned storage.** Builders return ref-counted `ArrayData`. Typed arrays such as `Int32Array`, `Date32Array`, and `TimestampArray` are cheap non-owning views created with `fromData()`.
- **Zero-copy slicing.** `slice(off, len)` returns another non-owning view and clamps `len` to the available range. Use `sliceChecked()` for offset validation, or `sliceOwned()` / `cloneRetained()` when a slice needs its own retained owner.
- **External memory.** External allocations can be wrapped with `ExternalOwnerHandle`, `Buffer.wrap()`, and `Buffer.wrapConst()`. For buffers with logical size smaller than capacity, provide the padded byte range with zeroed padding.
