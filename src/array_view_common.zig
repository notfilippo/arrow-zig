const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const checked = @import("checked.zig");

pub const ViewError = error{ TypeMismatch, InvalidBufferLayout };
pub const SliceError = error{OffsetOutOfBounds};

pub fn typeIdFor(comptime T: type) datatype.TypeId {
    return switch (T) {
        i8 => .int8,
        i16 => .int16,
        i32 => .int32,
        i64 => .int64,
        u8 => .uint8,
        u16 => .uint16,
        u32 => .uint32,
        u64 => .uint64,
        f16 => .float16,
        f32 => .float32,
        f64 => .float64,
        else => @compileError("unsupported Arrow numeric type: " ++ @typeName(T)),
    };
}

pub fn dataTypeAcceptsZigType(comptime T: type, ty: datatype.DataType) bool {
    return switch (T) {
        i8 => ty == .int8,
        i16 => ty == .int16,
        i32 => switch (ty) {
            .int32, .date32, .time32 => true,
            else => false,
        },
        i64 => switch (ty) {
            .int64, .date64, .time64, .timestamp, .duration => true,
            else => false,
        },
        u8 => ty == .uint8,
        u16 => ty == .uint16,
        u32 => ty == .uint32,
        u64 => ty == .uint64,
        f16 => ty == .float16,
        f32 => ty == .float32,
        f64 => ty == .float64,
        else => false,
    };
}

pub const ArrayKind = union(enum) {
    bool,
    numeric: type,
    date32,
    date64,
    time32,
    time64,
    timestamp,
    duration,
};

pub fn slotIsValid(data: anytype, offset: usize, i: usize) bool {
    const validity = data.buffers[0] orelse return true;
    return bitmap.getBit(validity.dataSlice(), offset + i);
}

pub fn viewNullCount(data: anytype, offset: usize, len: usize, hint: usize) usize {
    if (data.type.id() == .null_) return len;
    const validity = data.buffers[0];
    return bitmap.nullCountFor(
        if (validity) |v| v.dataSlice() else null,
        offset,
        len,
        hint,
    );
}

pub fn clampedLen(current_len: usize, off: usize, requested: usize) SliceError!usize {
    if (off > current_len) return error.OffsetOutOfBounds;
    return @min(requested, current_len - off);
}

pub fn dataRelativeOffset(data_offset: usize, view_offset: usize, off: usize) checked.Error!usize {
    return checked.add(try checked.sub(view_offset, data_offset), off);
}

test "typeIdFor" {
    const std = @import("std");
    try std.testing.expectEqual(datatype.TypeId.int32, typeIdFor(i32));
    try std.testing.expectEqual(datatype.TypeId.float64, typeIdFor(f64));
}
