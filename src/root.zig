// Public API surface for arrow-zig. Re-exports types and convenience aliases.
//
// Atomicity is a build-time choice. Pass `-Dsingle_threaded=true` to remove
// atomic operations on Buffer refcounts. Default is atomic, so shared Buffer
// ownership is thread-safe. Underlying memory must not be mutated concurrently;
// the freeze-on-finish flow in builders enforces this.
const refcount = @import("refcount.zig");

pub const Threading = refcount.Threading;
pub const threading = refcount.threading;

pub const buffer = @import("buffer.zig");
pub const datatype = @import("datatype.zig");
pub const bitmap = @import("bitmap.zig");
pub const ref_count = refcount;
pub const cdi = @import("cdi.zig");

const arr = @import("array.zig");
const bld = @import("builder.zig");

pub const Buffer = buffer.Buffer;
pub const ExternalOwnerHandle = buffer.ExternalOwnerHandle;
pub const ExternalReleaseFn = buffer.ExternalReleaseFn;
pub const ArrayData = arr.ArrayData;
pub const unknown_null_count = arr.unknown_null_count;
pub const TypeId = datatype.TypeId;
pub const DataType = datatype.DataType;
pub const Field = datatype.Field;
pub const ListMeta = datatype.ListMeta;
pub const FixedSizeListMeta = datatype.FixedSizeListMeta;
pub const StructMeta = datatype.StructMeta;
pub const UnionMeta = datatype.UnionMeta;
pub const DictionaryMeta = datatype.DictionaryMeta;
pub const TimeUnit = datatype.TimeUnit;
pub const TimestampMeta = datatype.TimestampMeta;
pub const ViewError = arr.ViewError;
pub const SliceError = arr.SliceError;
pub const ValidateError = arr.ValidateError;
pub const ArrayKind = arr.ArrayKind;
pub const VarBinaryKind = arr.VarBinaryKind;
pub const ListKind = arr.ListKind;
pub const ValueRange = arr.ValueRange;
pub const typeIdFor = arr.typeIdFor;
pub const dataTypeAcceptsZigType = arr.dataTypeAcceptsZigType;

pub const NumericArray = arr.NumericArray;
pub const BooleanArray = arr.BooleanArray;
pub const Date32Array = arr.Date32Array;
pub const Date64Array = arr.Date64Array;
pub const Time32Array = arr.Time32Array;
pub const Time64Array = arr.Time64Array;
pub const TimestampArray = arr.TimestampArray;
pub const DurationArray = arr.DurationArray;
pub const BinaryArray = arr.BinaryArray;
pub const Utf8Array = arr.Utf8Array;
pub const LargeBinaryArray = arr.LargeBinaryArray;
pub const LargeUtf8Array = arr.LargeUtf8Array;
pub const ListArray = arr.ListArray;
pub const LargeListArray = arr.LargeListArray;

pub const NumericBuilder = bld.NumericBuilder;
pub const BooleanBuilder = bld.BooleanBuilder;
pub const VarBinaryBuilder = bld.VarBinaryBuilder;
pub const BinaryBuilder = bld.BinaryBuilder;
pub const Utf8Builder = bld.Utf8Builder;
pub const LargeBinaryBuilder = bld.LargeBinaryBuilder;
pub const LargeUtf8Builder = bld.LargeUtf8Builder;

pub const ArrowSchema = cdi.ArrowSchema;
pub const ArrowArray = cdi.ArrowArray;
pub const exportType = cdi.exportType;
pub const exportArray = cdi.exportArray;

// Convenience type aliases.
pub const Int8Array = NumericArray(i8);
pub const Int16Array = NumericArray(i16);
pub const Int32Array = NumericArray(i32);
pub const Int64Array = NumericArray(i64);
pub const UInt8Array = NumericArray(u8);
pub const UInt16Array = NumericArray(u16);
pub const UInt32Array = NumericArray(u32);
pub const UInt64Array = NumericArray(u64);
pub const Float16Array = NumericArray(f16);
pub const Float32Array = NumericArray(f32);
pub const Float64Array = NumericArray(f64);

pub const Int8Builder = NumericBuilder(i8);
pub const Int16Builder = NumericBuilder(i16);
pub const Int32Builder = NumericBuilder(i32);
pub const Int64Builder = NumericBuilder(i64);
pub const UInt8Builder = NumericBuilder(u8);
pub const UInt16Builder = NumericBuilder(u16);
pub const UInt32Builder = NumericBuilder(u32);
pub const UInt64Builder = NumericBuilder(u64);
pub const Float16Builder = NumericBuilder(f16);
pub const Float32Builder = NumericBuilder(f32);
pub const Float64Builder = NumericBuilder(f64);

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
