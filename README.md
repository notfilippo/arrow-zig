<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# arrow-zig

Apache Arrow columnar format in Zig.

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

## Example

```zig
const arrow = @import("arrow");

var b = arrow.builder.NumericBuilder(i32).init(allocator);
defer b.deinit();

try b.append(10);
try b.appendNull();
try b.append(30);

const data = try b.finish();
defer data.deinit();

const values = try arrow.array.NumericArray(i32).fromData(data);
```

## Docs

Public API docs live in Zig doc comments.

```sh
zig build-lib -femit-docs -fno-emit-bin src/root.zig
```

Format and ABI details follow the [Arrow Columnar Format](https://arrow.apache.org/docs/format/Columnar.html)
and [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html).
