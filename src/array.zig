// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array storage and typed array facade.
//!
//! `ArrayData` owns the Arrow layout pieces. Typed arrays such as `Int32Array`,
//! `BinaryArray`, and `ListArray` are small structs over retained storage.

const array_data = @import("array_data.zig");
const base = @import("array_base.zig");
const prim = @import("array_primitive.zig");
const binary = @import("array_binary.zig");
const list = @import("array_list.zig");
const dictionary = @import("array_dictionary.zig");
const nested = @import("array_nested.zig");

/// Reference counted array storage.
pub const ArrayData = array_data.ArrayData;

/// Error set for retained array slices.
pub const DataSliceError = array_data.DataSliceError;

/// Error set for array storage creation.
pub const InitError = array_data.InitError;

/// Error set for storage validation.
pub const ValidateError = array_data.ValidateError;

/// Compile time kind for fixed width arrays.
pub const FixedWidthKind = base.FixedWidthKind;

/// Compile time kind for list arrays.
pub const ListKind = list.ListKind;

/// Error set for non owning array slices.
pub const SliceError = base.SliceError;

/// Offset and length pair for list values.
pub const ValueRange = list.ValueRange;

/// Compile time kind for variable width binary arrays.
pub const VarBinaryKind = binary.VarBinaryKind;

/// Error set for creating typed arrays from storage.
pub const ViewError = base.ViewError;

pub const BooleanArray = prim.BooleanArray;
pub const Date32Array = prim.Date32Array;
pub const Date64Array = prim.Date64Array;
pub const Time32Array = prim.Time32Array;
pub const Time64Array = prim.Time64Array;
pub const TimestampArray = prim.TimestampArray;
pub const DurationArray = prim.DurationArray;
pub const BinaryArray = binary.BinaryArray;
pub const Utf8Array = binary.Utf8Array;
pub const LargeBinaryArray = binary.LargeBinaryArray;
pub const LargeUtf8Array = binary.LargeUtf8Array;
pub const ListArray = list.ListArray;
pub const LargeListArray = list.LargeListArray;
pub const FixedSizeListArray = list.FixedSizeListArray;
pub const StructArray = nested.StructArray;

pub const dataTypeAcceptsZigType = base.dataTypeAcceptsZigType;
pub const FixedWidthArray = prim.FixedWidthArray;
pub const VarListArray = list.VarListArray;
pub const VarBinaryArray = binary.VarBinaryArray;

pub fn DictionaryArray(comptime Index: type) type {
    return dictionary.DictionaryArray(Index);
}

pub fn NumericArray(comptime T: type) type {
    return prim.NumericArray(T);
}

pub fn typeIdFor(comptime T: type) @import("datatype.zig").TypeId {
    return base.typeIdFor(T);
}
