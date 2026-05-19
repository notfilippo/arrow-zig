// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array storage and typed array facade.
//!
//! `ArrayData` owns the Arrow layout pieces. Typed arrays such as `Int32Array`,
//! `BinaryArray`, and `ListArray` are small structs over retained storage.

const array_data = @import("array/data.zig");
const base = @import("array/base.zig");
const prim = @import("array/primitive.zig");
const null_array = @import("array/null.zig");
const binary = @import("array/binary.zig");
const decimal = @import("array/decimal.zig");
const interval = @import("array/interval.zig");
const list = @import("array/list.zig");
const map_array = @import("array/map.zig");
const dictionary = @import("array/dictionary.zig");
const nested = @import("array/nested.zig");
const union_array = @import("array/union.zig");
const run_end = @import("array/run_end.zig");

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

/// Compile time kind for decimal arrays.
pub const DecimalKind = decimal.DecimalKind;

/// Compile time kind for interval arrays.
pub const IntervalKind = interval.IntervalKind;

/// Error set for creating typed arrays from storage.
pub const ViewError = base.ViewError;

pub const NullArray = null_array.NullArray;
pub const BooleanArray = prim.BooleanArray;
pub const Date32Array = prim.Date32Array;
pub const Date64Array = prim.Date64Array;
pub const Time32Array = prim.Time32Array;
pub const Time64Array = prim.Time64Array;
pub const TimestampArray = prim.TimestampArray;
pub const DurationArray = prim.DurationArray;
pub const DayTimeInterval = interval.DayTimeInterval;
pub const MonthDayNanoInterval = interval.MonthDayNanoInterval;
pub const MonthIntervalArray = interval.MonthIntervalArray;
pub const DayTimeIntervalArray = interval.DayTimeIntervalArray;
pub const MonthDayNanoIntervalArray = interval.MonthDayNanoIntervalArray;
pub const BinaryArray = binary.BinaryArray;
pub const Utf8Array = binary.Utf8Array;
pub const LargeBinaryArray = binary.LargeBinaryArray;
pub const LargeUtf8Array = binary.LargeUtf8Array;
pub const FixedSizeBinaryArray = binary.FixedSizeBinaryArray;
pub const Decimal128Array = decimal.Decimal128Array;
pub const Decimal256Array = decimal.Decimal256Array;
pub const ListArray = list.ListArray;
pub const LargeListArray = list.LargeListArray;
pub const FixedSizeListArray = list.FixedSizeListArray;
pub const MapArray = map_array.MapArray;
pub const StructArray = nested.StructArray;
pub const SparseUnionArray = union_array.SparseUnionArray;
pub const DenseUnionArray = union_array.DenseUnionArray;
pub const RunEndEncodedArray = run_end.RunEndEncodedArray;

pub const dataTypeAcceptsZigType = base.dataTypeAcceptsZigType;
pub const FixedWidthArray = prim.FixedWidthArray;
pub const DecimalArray = decimal.DecimalArray;
pub const IntervalArray = interval.IntervalArray;
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
