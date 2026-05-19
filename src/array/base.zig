// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Base helpers for typed Arrow arrays.
//!
//! Type matching, null count lookup, and slice bound helpers shared by
//! primitive, binary, list, and struct arrays.

const datatype = @import("../datatype.zig");
const bitmap = @import("../bitmap.zig");
const checked = @import("../checked.zig");
const array_data = @import("data.zig");
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

pub fn ValidityView(comptime nulls: enum { bitmap, none, all }) type {
    return struct {
        const Self = @This();

        base: View,
        null_count: if (nulls == .bitmap) ?usize else void = if (nulls == .bitmap) null else {},

        pub fn init(data: *const ArrayData) Self {
            return .{
                .base = View.init(data),
                .null_count = if (nulls == .bitmap) data.null_count else {},
            };
        }

        pub fn isValid(self: Self, i: usize) bool {
            return switch (nulls) {
                .bitmap => slotIsValid(self.base.data, self.base.offset, i),
                .none => true,
                .all => false,
            };
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            return switch (nulls) {
                .bitmap => viewNullCount(self.base.data, self.base.offset, self.base.len, self.null_count),
                .none => 0,
                .all => self.base.len,
            };
        }

        pub fn slice(self: Self, off: usize, length: usize) Self {
            return self.sliceChecked(off, length) catch unreachable;
        }

        pub fn sliceChecked(self: Self, off: usize, length: usize) SliceError!Self {
            const base = try self.base.sliceChecked(off, length);
            return .{
                .base = base,
                .null_count = if (nulls == .bitmap)
                    array_data.slicedNullCount(self.null_count, self.base.len, off, base.len)
                else {},
            };
        }
    };
}

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
