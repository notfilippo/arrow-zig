const array_data = @import("array_data.zig");
const array_view = @import("array_view.zig");

pub const ArrayData = array_data.ArrayData;
pub const DataSliceError = array_data.DataSliceError;
pub const InitError = array_data.InitError;
pub const ValidateError = array_data.ValidateError;
pub const unknown_null_count = array_data.unknown_null_count;

pub const ArrayKind = array_view.ArrayKind;
pub const ListKind = array_view.ListKind;
pub const OwnedSliceError = array_view.OwnedSliceError;
pub const SliceError = array_view.SliceError;
pub const ViewSliceError = array_view.SliceError;
pub const ValueRange = array_view.ValueRange;
pub const VarBinaryKind = array_view.VarBinaryKind;
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
