// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array storage and typed array facade.
//!
//! `ArrayData` owns the Arrow layout pieces. Typed arrays such as
//! `NumericArray(i32)`, `BinaryArray`, and `ListArray` are small structs over
//! retained storage.

const array_data = @import("array/data.zig");
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

/// Offset and length pair for list values.
pub const ValueRange = list.ValueRange;

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
pub const BinaryViewArray = binary.BinaryViewArray;
pub const Utf8ViewArray = binary.Utf8ViewArray;
pub const FixedSizeBinaryArray = binary.FixedSizeBinaryArray;
pub const Decimal32Array = decimal.Decimal32Array;
pub const Decimal64Array = decimal.Decimal64Array;
pub const Decimal128Array = decimal.Decimal128Array;
pub const Decimal256Array = decimal.Decimal256Array;
pub const ListArray = list.ListArray;
pub const LargeListArray = list.LargeListArray;
pub const ListViewArray = list.ListViewArray;
pub const LargeListViewArray = list.LargeListViewArray;
pub const FixedSizeListArray = list.FixedSizeListArray;
pub const MapArray = map_array.MapArray;
pub const StructArray = nested.StructArray;
pub const SparseUnionArray = union_array.SparseUnionArray;
pub const DenseUnionArray = union_array.DenseUnionArray;
pub const RunEndEncodedArray = run_end.RunEndEncodedArray;

pub fn DictionaryArray(comptime Index: type) type {
    return dictionary.DictionaryArray(Index);
}

pub fn NumericArray(comptime T: type) type {
    return prim.NumericArray(T);
}
