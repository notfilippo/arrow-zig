// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Variable width binary and UTF8 array views.
//!
//! Values are read from Arrow offset and value buffers. Slices keep the same
//! backing storage and adjust the logical view range.

const std = @import("std");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array_data = @import("array_data.zig");
const common = @import("array_base.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const VarBinaryKind = enum {
    binary,
    utf8,
    large_binary,
    large_utf8,
};

fn offsetTypeFor(comptime kind: VarBinaryKind) type {
    return switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };
}

fn dataTypeMatches(comptime kind: VarBinaryKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .binary => ty == .binary,
        .utf8 => ty == .utf8,
        .large_binary => ty == .large_binary,
        .large_utf8 => ty == .large_utf8,
    };
}

pub fn VarBinaryArray(comptime kind: VarBinaryKind) type {
    const Offset = offsetTypeFor(kind);

    return struct {
        const Self = @This();

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: ?usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 3 or data.buffers[2] == null) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{
                .data = data,
                .offset = data.offset,
                .len = data.len,
                .null_count = data.null_count,
            };
        }

        pub fn dataType(self: Self) datatype.DataType {
            return self.data.type;
        }

        pub fn baseData(self: Self) *const ArrayData {
            return self.data;
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const offsets = self.data.buffers[1].?;
            const values = self.data.buffers[2].?;
            const range = offset_data.rangeAt(Offset, offsets, self.offset + i);
            return values.dataSlice()[range.offset..][0..range.len];
        }

        pub fn value(self: Self, i: usize) []const u8 {
            return self.valueBytes(i);
        }

        pub fn isValid(self: Self, i: usize) bool {
            return common.slotIsValid(self.data, self.offset, i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            return common.viewNullCount(self.data, self.offset, self.len, self.null_count);
        }

        pub fn slice(self: Self, off: usize, length: usize) Self {
            return self.sliceChecked(off, length) catch unreachable;
        }

        pub fn sliceChecked(self: Self, off: usize, length: usize) common.SliceError!Self {
            const clamped = try common.clampedLen(self.len, off, length);
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        pub fn sliceOwned(self: Self, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
            const clamped = try common.clampedLen(self.len, off, length);
            const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
            return self.data.slice(data_off, clamped);
        }

        pub fn cloneRetained(self: Self) array_data.DataSliceError!*ArrayData {
            return self.sliceOwned(0, self.len);
        }
    };
}

pub const BinaryArray = VarBinaryArray(.binary);
pub const Utf8Array = VarBinaryArray(.utf8);
pub const LargeBinaryArray = VarBinaryArray(.large_binary);
pub const LargeUtf8Array = VarBinaryArray(.large_utf8);

pub const FixedSizeBinaryArray = struct {
    data: *const ArrayData,
    offset: usize,
    len: usize,
    null_count: ?usize,

    pub fn fromData(data: *const ArrayData) common.ViewError!FixedSizeBinaryArray {
        if (data.type.id() != .fixed_size_binary) return error.TypeMismatch;
        if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
        return .{
            .data = data,
            .offset = data.offset,
            .len = data.len,
            .null_count = data.null_count,
        };
    }

    pub fn dataType(self: FixedSizeBinaryArray) datatype.DataType {
        return self.data.type;
    }

    pub fn baseData(self: FixedSizeBinaryArray) *const ArrayData {
        return self.data;
    }

    pub fn byteWidth(self: FixedSizeBinaryArray) usize {
        return self.data.type.fixed_size_binary.byte_width;
    }

    pub fn valueBytes(self: FixedSizeBinaryArray, i: usize) []const u8 {
        const width = self.byteWidth();
        const start = (self.offset + i) * width;
        return self.data.buffers[1].?.dataSlice()[start..][0..width];
    }

    pub fn value(self: FixedSizeBinaryArray, i: usize) []const u8 {
        return self.valueBytes(i);
    }

    pub fn isValid(self: FixedSizeBinaryArray, i: usize) bool {
        return common.slotIsValid(self.data, self.offset, i);
    }

    pub fn isNull(self: FixedSizeBinaryArray, i: usize) bool {
        return !self.isValid(i);
    }

    pub fn nullCount(self: FixedSizeBinaryArray) usize {
        return common.viewNullCount(self.data, self.offset, self.len, self.null_count);
    }

    pub fn slice(self: FixedSizeBinaryArray, off: usize, length: usize) FixedSizeBinaryArray {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: FixedSizeBinaryArray, off: usize, length: usize) common.SliceError!FixedSizeBinaryArray {
        const clamped = try common.clampedLen(self.len, off, length);
        return .{
            .data = self.data,
            .offset = self.offset + off,
            .len = clamped,
            .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
        };
    }

    pub fn sliceOwned(self: FixedSizeBinaryArray, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
        const clamped = try common.clampedLen(self.len, off, length);
        const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
        return self.data.slice(data_off, clamped);
    }

    pub fn cloneRetained(self: FixedSizeBinaryArray) array_data.DataSliceError!*ArrayData {
        return self.sliceOwned(0, self.len);
    }
};

test "BinaryArray reads ranges and slices" {
    const allocator = std.testing.allocator;
    const offsets = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer offsets.deinit();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 2);
    try offset_data.write(i32, offsets, 2, 2);
    try offset_data.write(i32, offsets, 3, 5);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.deinit();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .binary, 3, 0, 0, &.{ null, offsets, values }, &.{}, null);
    defer data.deinit();
    const arr = try BinaryArray.fromData(data);

    try std.testing.expectEqualStrings("ab", arr.valueBytes(0));
    try std.testing.expectEqualStrings("", arr.value(1));
    try std.testing.expectEqualStrings("cde", arr.value(2));
    try std.testing.expectEqualStrings("", arr.slice(1, 2).valueBytes(0));

    const sliced_owned = try arr.slice(1, 2).sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try BinaryArray.fromData(sliced_owned);
    try std.testing.expectEqualStrings("", sliced_owned_arr.valueBytes(0));

    const sliced_clone = try arr.slice(1, 2).cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try BinaryArray.fromData(sliced_clone);
    try std.testing.expectEqualStrings("", sliced_clone_arr.valueBytes(0));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}

test "FixedSizeBinaryArray reads slots and slices" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 4 * 3);
    errdefer values.deinit();
    @memcpy(values.data[0..12], "abcdefghijkl");
    values.freeze();

    const ty = datatype.DataType{ .fixed_size_binary = .{ .byte_width = 3 } };
    const data = try ArrayData.initOwned(allocator, ty, 4, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try FixedSizeBinaryArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.byteWidth());
    try std.testing.expectEqualStrings("abc", arr.valueBytes(0));
    try std.testing.expectEqualStrings("jkl", arr.value(3));
    try std.testing.expectEqualStrings("def", arr.slice(1, 2).valueBytes(0));

    const sliced_owned = try arr.slice(1, 2).sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try FixedSizeBinaryArray.fromData(sliced_owned);
    try std.testing.expectEqualStrings("def", sliced_owned_arr.valueBytes(0));

    const sliced_clone = try arr.slice(1, 2).cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try FixedSizeBinaryArray.fromData(sliced_clone);
    try std.testing.expectEqualStrings("ghi", sliced_clone_arr.valueBytes(1));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(5, 1));
}
