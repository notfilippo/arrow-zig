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

        view: common.NullableView,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 3 or data.buffers[2] == null) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.NullableView.init(data) };
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const offsets = self.view.base.data.buffers[1].?;
            const values = self.view.base.data.buffers[2].?;
            const range = offset_data.rangeAt(Offset, offsets, self.view.base.offset + i);
            return values.dataSlice()[range.offset..][0..range.len];
        }

        pub fn value(self: Self, i: usize) []const u8 {
            return self.valueBytes(i);
        }
    };
}

pub const BinaryArray = VarBinaryArray(.binary);
pub const Utf8Array = VarBinaryArray(.utf8);
pub const LargeBinaryArray = VarBinaryArray(.large_binary);
pub const LargeUtf8Array = VarBinaryArray(.large_utf8);

pub const FixedSizeBinaryArray = struct {
    view: common.NullableView,

    pub fn fromData(data: *const ArrayData) common.ViewError!FixedSizeBinaryArray {
        if (data.type.id() != .fixed_size_binary) return error.TypeMismatch;
        if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
        return .{ .view = common.NullableView.init(data) };
    }

    pub fn byteWidth(self: FixedSizeBinaryArray) usize {
        return self.view.base.data.type.fixed_size_binary.byte_width;
    }

    pub fn valueBytes(self: FixedSizeBinaryArray, i: usize) []const u8 {
        const width = self.byteWidth();
        const start = (self.view.base.offset + i) * width;
        return self.view.base.data.buffers[1].?.dataSlice()[start..][0..width];
    }

    pub fn value(self: FixedSizeBinaryArray, i: usize) []const u8 {
        return self.valueBytes(i);
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
    const sliced = @TypeOf(arr){ .view = arr.view.slice(1, 2) };
    try std.testing.expectEqualStrings("", sliced.valueBytes(0));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try BinaryArray.fromData(sliced_owned);
    try std.testing.expectEqualStrings("", sliced_owned_arr.valueBytes(0));

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try BinaryArray.fromData(sliced_clone);
    try std.testing.expectEqualStrings("", sliced_clone_arr.valueBytes(0));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(4, 1));
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
    const sliced = @TypeOf(arr){ .view = arr.view.slice(1, 2) };
    try std.testing.expectEqualStrings("def", sliced.valueBytes(0));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try FixedSizeBinaryArray.fromData(sliced_owned);
    try std.testing.expectEqualStrings("def", sliced_owned_arr.valueBytes(0));

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try FixedSizeBinaryArray.fromData(sliced_clone);
    try std.testing.expectEqualStrings("ghi", sliced_clone_arr.valueBytes(1));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(5, 1));
}
