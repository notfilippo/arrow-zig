//! Array storage and typed array view facade.
//!
//! `ArrayData` owns the Arrow layout pieces. Typed arrays such as `Int32Array`,
//! `BinaryArray`, and `ListArray` are small views over retained storage.

const array_data = @import("array_data.zig");
const array_view = @import("array_view.zig");

/// Reference counted array storage.
pub const ArrayData = array_data.ArrayData;

/// Error set for retained array slices.
pub const DataSliceError = array_data.DataSliceError;

/// Error set for array storage creation.
pub const InitError = array_data.InitError;

/// Error set for storage validation.
pub const ValidateError = array_data.ValidateError;

/// Sentinel for deferred null count calculation.
pub const unknown_null_count = array_data.unknown_null_count;

/// Compile time kind for fixed width array views.
pub const ArrayKind = array_view.ArrayKind;

/// Compile time kind for list array views.
pub const ListKind = array_view.ListKind;

/// Error set for non owning view slices.
pub const SliceError = array_view.SliceError;

/// Offset and length pair for list values.
pub const ValueRange = array_view.ValueRange;

/// Compile time kind for variable width binary views.
pub const VarBinaryKind = array_view.VarBinaryKind;

/// Error set for creating typed views from storage.
pub const ViewError = array_view.ViewError;

pub const BooleanArray = array_view.BooleanArray;
pub const Date32Array = array_view.Date32Array;
pub const Date64Array = array_view.Date64Array;
pub const Time32Array = array_view.Time32Array;
pub const Time64Array = array_view.Time64Array;
pub const TimestampArray = array_view.TimestampArray;
pub const DurationArray = array_view.DurationArray;
pub const BinaryArray = array_view.BinaryArray;
pub const Utf8Array = array_view.Utf8Array;
pub const LargeBinaryArray = array_view.LargeBinaryArray;
pub const LargeUtf8Array = array_view.LargeUtf8Array;
pub const ListArray = array_view.ListArray;
pub const LargeListArray = array_view.LargeListArray;

pub const dataTypeAcceptsZigType = array_view.dataTypeAcceptsZigType;
pub const FixedWidthView = array_view.FixedWidthView;
pub const ListView = array_view.ListView;
pub const VarBinaryView = array_view.VarBinaryView;

pub fn NumericArray(comptime T: type) type {
    return array_view.NumericArray(T);
}

pub fn typeIdFor(comptime T: type) @import("datatype.zig").TypeId {
    return array_view.typeIdFor(T);
}
