// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Public entry point for the Arrow Zig package.
//!
//! The package exposes columnar buffers, array storage, typed views, record
//! batches, builders, data types, bitmap helpers, config, and Arrow C Data
//! Interface import and export helpers.
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

/// Record batch schema and column storage.
pub const record_batch = @import("record_batch.zig");

/// Shared reference count abstraction.
pub const refcount = @import("refcount.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
