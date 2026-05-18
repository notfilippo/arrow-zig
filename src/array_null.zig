// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Null array typed view.

const std = @import("std");
const datatype = @import("datatype.zig");
const array_data = @import("array_data.zig");
const common = @import("array_base.zig");
const ArrayData = array_data.ArrayData;

pub const NullArray = struct {
    data: *const ArrayData,
    offset: usize,
    len: usize,

    pub fn fromData(data: *const ArrayData) common.ViewError!NullArray {
        if (data.type.id() != .null_) return error.TypeMismatch;
        if (data.buffers.len != 0 or data.children.len != 0 or data.dictionary != null) return error.InvalidBufferLayout;
        return .{ .data = data, .offset = data.offset, .len = data.len };
    }

    pub fn dataType(self: NullArray) datatype.DataType {
        return self.data.type;
    }

    pub fn baseData(self: NullArray) *const ArrayData {
        return self.data;
    }

    pub fn isValid(self: NullArray, i: usize) bool {
        _ = self;
        _ = i;
        return false;
    }

    pub fn isNull(self: NullArray, i: usize) bool {
        _ = self;
        _ = i;
        return true;
    }

    pub fn nullCount(self: NullArray) usize {
        return self.len;
    }

    pub fn slice(self: NullArray, off: usize, length: usize) NullArray {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: NullArray, off: usize, length: usize) common.SliceError!NullArray {
        const clamped = try common.clampedLen(self.len, off, length);
        return .{ .data = self.data, .offset = self.offset + off, .len = clamped };
    }

    pub fn sliceOwned(self: NullArray, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
        const clamped = try common.clampedLen(self.len, off, length);
        const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
        return self.data.slice(data_off, clamped);
    }

    pub fn cloneRetained(self: NullArray) array_data.DataSliceError!*ArrayData {
        return self.sliceOwned(0, self.len);
    }
};

test "NullArray slices and clones" {
    const allocator = std.testing.allocator;
    const data = try ArrayData.initOwned(allocator, .null_, 5, 0, 5, &.{}, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try NullArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 5), arr.len);
    try std.testing.expectEqual(@as(usize, 5), arr.nullCount());
    try std.testing.expect(!arr.isValid(0));
    try std.testing.expect(arr.isNull(0));

    const sliced = arr.slice(2, 9);
    try std.testing.expectEqual(@as(usize, 2), sliced.offset);
    try std.testing.expectEqual(@as(usize, 3), sliced.len);
    try std.testing.expectEqual(@as(usize, 3), sliced.nullCount());

    const sliced_owned = try sliced.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try NullArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(usize, 2), sliced_owned_arr.len);
    try std.testing.expectEqual(@as(usize, 2), sliced_owned_arr.nullCount());

    const clone = try sliced.cloneRetained();
    defer clone.deinit();
    const clone_arr = try NullArray.fromData(clone);
    try std.testing.expectEqual(@as(usize, 3), clone_arr.len);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(6, 1));
}
