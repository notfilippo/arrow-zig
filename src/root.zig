// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Public entry point for the Arrow Zig package.
//!
//! The package exposes columnar buffers, schemas, array storage, typed views,
//! record batches, builders, data types, bitmap helpers, config, and Arrow C
//! Data Interface import and export helpers.
//!
//! Build arrays with `builder`, then create typed views from `array.ArrayData`.
//!
//! ```zig
//! const arrow = @import("arrow");
//! const std = @import("std");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     const allocator = gpa.allocator();
//!
//!     var b = arrow.builder.NumericBuilder(i32).init(allocator);
//!     defer b.deinit();
//!     try b.append(10);
//!     try b.appendNull();
//!     try b.append(30);
//!
//!     const data = try b.finish();
//!     defer data.deinit();
//!
//!     const values = try arrow.array.NumericArray(i32).fromData(data);
//!     std.debug.print("{} {}\n", .{ values.value(0), values.value(2) });
//! }
//! ```

/// Array storage and typed array views.
pub const array = @import("array.zig");

/// Bitmap bit packing, counting, boolean operations, and builders.
pub const bitmap = @import("bitmap.zig");

/// Reference counted Arrow buffers.
pub const buffer = @import("buffer.zig");

/// Mutable builders for producing `ArrayData`.
pub const builder = @import("builder.zig");

/// Arrow C Data Interface import and export helpers.
pub const cdi = @import("cdi.zig");

/// Compile time package configuration.
pub const config = @import("config.zig");

/// Arrow data type metadata.
pub const datatype = @import("datatype.zig");

/// Offset buffer helpers for binary and list arrays.
pub const offsets = @import("offsets.zig");

/// Reference counted record batch schema and column storage.
pub const record_batch = @import("record_batch.zig");

/// Reference counted Arrow schemas.
pub const schema = @import("schema.zig");

/// Shared reference count abstraction.
pub const refcount = @import("refcount.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());

    _ = @import("array/base.zig");
    _ = @import("array/binary.zig");
    _ = @import("array/data.zig");
    _ = @import("array/decimal.zig");
    _ = @import("array/dictionary.zig");
    _ = @import("array/interval.zig");
    _ = @import("array/list.zig");
    _ = @import("array/map.zig");
    _ = @import("array/nested.zig");
    _ = @import("array/null.zig");
    _ = @import("array/primitive.zig");
    _ = @import("array/run_end.zig");
    _ = @import("array/union.zig");
    _ = @import("array/validate.zig");
    _ = @import("bitmap/bits.zig");
    _ = @import("bitmap/builder.zig");
    _ = @import("bitmap/ops.zig");
    _ = @import("buffer.zig");
    _ = @import("builder/binary.zig");
    _ = @import("builder/boolean.zig");
    _ = @import("builder/decimal.zig");
    _ = @import("builder/dictionary.zig");
    _ = @import("builder/interval.zig");
    _ = @import("builder/list.zig");
    _ = @import("builder/map.zig");
    _ = @import("builder/null.zig");
    _ = @import("builder/numeric.zig");
    _ = @import("builder/run_end.zig");
    _ = @import("builder/struct.zig");
    _ = @import("builder/union.zig");
    _ = @import("cdi.zig");
    _ = @import("cdi/alloc_test.zig");
    _ = @import("cdi/array_test.zig");
    _ = @import("cdi/metadata.zig");
    _ = @import("cdi/record_batch_test.zig");
    _ = @import("cdi/schema_test.zig");
    _ = @import("cdi/stream_test.zig");
    _ = @import("checked.zig");
    _ = @import("config.zig");
    _ = @import("datatype.zig");
    _ = @import("datatype_layout.zig");
    _ = @import("offsets.zig");
    _ = @import("record_batch.zig");
    _ = @import("refcount.zig");
    _ = @import("schema.zig");
}
