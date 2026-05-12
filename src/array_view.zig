// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Typed array view facade.
//!
//! Views validate the storage type once, then expose typed accessors without
//! taking ownership. Use `sliceOwned` or `cloneRetained` when a retained
//! `ArrayData` reference is needed.

const common = @import("array_view_common.zig");
const fixed = @import("array_fixed_view.zig");
const binary = @import("array_binary_view.zig");
const list = @import("array_list_view.zig");
const struct_view = @import("array_struct_view.zig");

pub const ArrayKind = common.ArrayKind;
pub const SliceError = common.SliceError;
pub const ViewError = common.ViewError;
pub const dataTypeAcceptsZigType = common.dataTypeAcceptsZigType;
pub const typeIdFor = common.typeIdFor;

pub const FixedWidthView = fixed.FixedWidthView;
pub const BooleanArray = fixed.BooleanArray;
pub const Date32Array = fixed.Date32Array;
pub const Date64Array = fixed.Date64Array;
pub const Time32Array = fixed.Time32Array;
pub const Time64Array = fixed.Time64Array;
pub const TimestampArray = fixed.TimestampArray;
pub const DurationArray = fixed.DurationArray;

pub const VarBinaryKind = binary.VarBinaryKind;
pub const VarBinaryView = binary.VarBinaryView;
pub const BinaryArray = binary.BinaryArray;
pub const Utf8Array = binary.Utf8Array;
pub const LargeBinaryArray = binary.LargeBinaryArray;
pub const LargeUtf8Array = binary.LargeUtf8Array;

pub const ListKind = list.ListKind;
pub const ValueRange = list.ValueRange;
pub const ListView = list.ListView;
pub const ListArray = list.ListArray;
pub const LargeListArray = list.LargeListArray;
pub const StructArray = struct_view.StructArray;

pub fn NumericArray(comptime T: type) type {
    return fixed.NumericArray(T);
}
