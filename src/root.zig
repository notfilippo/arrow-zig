// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Public entry point for the Arrow Zig package.
//!
//! The package exposes columnar buffers, array storage, typed views, builders,
//! data types, bitmap helpers, config, and Arrow C Data Interface export
//! helpers.

/// Array storage and typed array views.
pub const array = @import("array.zig");

/// Bitmap bit packing, counting, boolean operations, and builders.
pub const bitmap = @import("bitmap.zig");

/// Reference counted Arrow buffers.
pub const buffer = @import("buffer.zig");

/// Mutable builders for producing `ArrayData`.
pub const builder = @import("builder.zig");

/// Arrow C Data Interface export helpers.
pub const cdi = @import("cdi.zig");

/// Compile time package configuration.
pub const config = @import("config.zig");

/// Arrow data type metadata.
pub const datatype = @import("datatype.zig");

/// Offset buffer helpers for binary and list arrays.
pub const offsets = @import("offsets.zig");

/// Shared reference count abstraction.
pub const refcount = @import("refcount.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
