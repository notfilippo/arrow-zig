// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array builder facade.
//!
//! Builders collect mutable values and null state, then transfer immutable
//! `ArrayData` storage to the caller with `finish`.
//!
//! `finish()` returns a reference counted `*array.ArrayData`. Call `deinit()`
//! when done. Typed array views do not retain the storage.
//!
//! ```zig
//! var b = arrow.builder.Utf8Builder.init(allocator);
//! defer b.deinit();
//!
//! try b.append("alpha");
//! try b.appendNull();
//! try b.append("beta");
//!
//! const data = try b.finish();
//! defer data.deinit();
//!
//! const values = try arrow.array.Utf8Array.fromData(data);
//! std.debug.print("{s}\n", .{values.value(2)});
//! ```
//!
//! Numeric builders can also produce compatible logical Arrow types.
//!
//! ```zig
//! var dates = try arrow.builder.NumericBuilder(i32).initType(allocator, .date32);
//! defer dates.deinit();
//! ```

const numeric = @import("builder_numeric.zig");
const boolean = @import("builder_boolean.zig");
const binary = @import("builder_binary.zig");
const list = @import("builder_list.zig");
const base = @import("builder_base.zig");

pub const kMinBuilderCapacity = base.kMinBuilderCapacity;

pub const NumericBuilder = numeric.NumericBuilder;
pub const NumericBuilderError = numeric.NumericBuilderError;
pub const NumericBuilderInitError = numeric.NumericBuilderInitError;
pub const BooleanBuilder = boolean.BooleanBuilder;
pub const BooleanBuilderError = boolean.BooleanBuilderError;
pub const VarBinaryBuilder = binary.VarBinaryBuilder;
pub const BinaryBuilderError = binary.BinaryBuilderError;
pub const BinaryBuilder = binary.BinaryBuilder;
pub const Utf8Builder = binary.Utf8Builder;
pub const LargeBinaryBuilder = binary.LargeBinaryBuilder;
pub const LargeUtf8Builder = binary.LargeUtf8Builder;
pub const VarListBuilder = list.VarListBuilder;
pub const ListBuilderError = list.ListBuilderError;
pub const ListBuilder = list.ListBuilder;
pub const LargeListBuilder = list.LargeListBuilder;
pub const FixedSizeListBuilder = list.FixedSizeListBuilder;
