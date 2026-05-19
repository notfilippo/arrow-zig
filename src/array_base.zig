// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Base helpers for typed Arrow arrays.
//!
//! Type matching, null count lookup, and slice bound helpers shared by
//! primitive, binary, list, and struct arrays.

const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const checked = @import("checked.zig");
const array_data = @import("array_data.zig");
const ArrayData = array_data.ArrayData;

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

pub const FixedWidthKind = union(enum) {
    bool,
    numeric: type,
    date32,
    date64,
    time32,
    time64,
    timestamp,
    duration,
};

pub const View = struct {
    data: *const ArrayData,
    offset: usize,
    len: usize,

    pub fn init(data: *const ArrayData) View {
        return .{ .data = data, .offset = data.offset, .len = data.len };
    }

    pub fn dataType(self: View) datatype.DataType {
        return self.data.type;
    }

    pub fn baseData(self: View) *const ArrayData {
        return self.data;
    }

    pub fn slice(self: View, off: usize, length: usize) View {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: View, off: usize, length: usize) SliceError!View {
        const clamped = try clampedLen(self.len, off, length);
        return .{ .data = self.data, .offset = self.offset + off, .len = clamped };
    }

    pub fn sliceOwned(self: View, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
        const clamped = try clampedLen(self.len, off, length);
        const data_off = try dataRelativeOffset(self.data.offset, self.offset, off);
        return self.data.slice(data_off, clamped);
    }

    pub fn cloneRetained(self: View) array_data.DataSliceError!*ArrayData {
        return self.sliceOwned(0, self.len);
    }
};

pub const NullableView = struct {
    base: View,
    null_count: ?usize,

    pub fn init(data: *const ArrayData) NullableView {
        return .{
            .base = View.init(data),
            .null_count = data.null_count,
        };
    }

    pub fn isValid(self: NullableView, i: usize) bool {
        return slotIsValid(self.base.data, self.base.offset, i);
    }

    pub fn isNull(self: NullableView, i: usize) bool {
        return !self.isValid(i);
    }

    pub fn nullCount(self: NullableView) usize {
        return viewNullCount(self.base.data, self.base.offset, self.base.len, self.null_count);
    }

    pub fn slice(self: NullableView, off: usize, length: usize) NullableView {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: NullableView, off: usize, length: usize) SliceError!NullableView {
        const base = try self.base.sliceChecked(off, length);
        return .{
            .base = base,
            .null_count = array_data.slicedNullCount(self.null_count, self.base.len, off, base.len),
        };
    }
};

pub const NoNullView = struct {
    base: View,

    pub fn init(data: *const ArrayData) NoNullView {
        return .{ .base = View.init(data) };
    }

    pub fn isValid(self: NoNullView, i: usize) bool {
        _ = self;
        _ = i;
        return true;
    }

    pub fn isNull(self: NoNullView, i: usize) bool {
        _ = self;
        _ = i;
        return false;
    }

    pub fn nullCount(self: NoNullView) usize {
        _ = self;
        return 0;
    }
};

pub const AlwaysNullView = struct {
    base: View,

    pub fn init(data: *const ArrayData) AlwaysNullView {
        return .{ .base = View.init(data) };
    }

    pub fn isValid(self: AlwaysNullView, i: usize) bool {
        _ = self;
        _ = i;
        return false;
    }

    pub fn isNull(self: AlwaysNullView, i: usize) bool {
        _ = self;
        _ = i;
        return true;
    }

    pub fn nullCount(self: AlwaysNullView) usize {
        return self.base.len;
    }
};

pub fn slotIsValid(data: anytype, offset: usize, i: usize) bool {
    const validity = data.buffers[0] orelse return true;
    return bitmap.getBit(validity.dataSlice(), offset + i);
}

pub fn viewNullCount(data: anytype, offset: usize, len: usize, hint: ?usize) usize {
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
