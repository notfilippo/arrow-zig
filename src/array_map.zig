// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Map array typed view.

const std = @import("std");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array_data = @import("array_data.zig");
const primitive = @import("array_primitive.zig");
const common = @import("array_base.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const MapArray = struct {
    data: *const ArrayData,
    offset: usize,
    len: usize,
    null_count: ?usize,

    pub fn fromData(data: *const ArrayData) common.ViewError!MapArray {
        if (data.type.id() != .map) return error.TypeMismatch;
        if (data.buffers.len != 2 or data.children.len != 1) return error.InvalidBufferLayout;
        if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
        if (data.children[0].type.id() != .struct_ or data.children[0].children.len != 2) return error.InvalidBufferLayout;
        return .{
            .data = data,
            .offset = data.offset,
            .len = data.len,
            .null_count = data.null_count,
        };
    }

    pub fn dataType(self: MapArray) datatype.DataType {
        return self.data.type;
    }

    pub fn baseData(self: MapArray) *const ArrayData {
        return self.data;
    }

    pub fn entriesBaseData(self: MapArray) *const ArrayData {
        return self.data.children[0];
    }

    pub fn keysBaseData(self: MapArray) *const ArrayData {
        return self.entriesBaseData().children[0];
    }

    pub fn valuesBaseData(self: MapArray) *const ArrayData {
        return self.entriesBaseData().children[1];
    }

    pub fn keysSorted(self: MapArray) bool {
        return self.data.type.map.keys_sorted;
    }

    pub fn entryRange(self: MapArray, i: usize) offset_data.ValueRange {
        const offsets = self.data.buffers[1].?;
        return offset_data.rangeAt(i32, offsets, self.offset + i);
    }

    pub fn valueRange(self: MapArray, i: usize) offset_data.ValueRange {
        return self.entryRange(i);
    }

    pub fn entriesOwned(self: MapArray, i: usize) array_data.DataSliceError!*ArrayData {
        const range = self.entryRange(i);
        return self.entriesBaseData().slice(range.offset, range.len);
    }

    pub fn keysOwned(self: MapArray, i: usize) array_data.DataSliceError!*ArrayData {
        const range = self.entryRange(i);
        return self.keysBaseData().slice(range.offset, range.len);
    }

    pub fn valuesOwned(self: MapArray, i: usize) array_data.DataSliceError!*ArrayData {
        const range = self.entryRange(i);
        return self.valuesBaseData().slice(range.offset, range.len);
    }

    pub fn isValid(self: MapArray, i: usize) bool {
        return common.slotIsValid(self.data, self.offset, i);
    }

    pub fn isNull(self: MapArray, i: usize) bool {
        return !self.isValid(i);
    }

    pub fn nullCount(self: MapArray) usize {
        return common.viewNullCount(self.data, self.offset, self.len, self.null_count);
    }

    pub fn slice(self: MapArray, off: usize, length: usize) MapArray {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: MapArray, off: usize, length: usize) common.SliceError!MapArray {
        const clamped = try common.clampedLen(self.len, off, length);
        return .{
            .data = self.data,
            .offset = self.offset + off,
            .len = clamped,
            .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
        };
    }

    pub fn sliceOwned(self: MapArray, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
        const clamped = try common.clampedLen(self.len, off, length);
        const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
        return self.data.slice(data_off, clamped);
    }

    pub fn cloneRetained(self: MapArray) array_data.DataSliceError!*ArrayData {
        return self.sliceOwned(0, self.len);
    }
};

test "MapArray exposes entries keys and values" {
    const allocator = std.testing.allocator;

    const key_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer key_values.deinit();
    for (0..3) |i| try offset_data.write(i32, key_values, i, @as(i32, @intCast(i + 1)));
    key_values.freeze();
    const keys = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, key_values }, &.{}, null);
    defer keys.deinit();

    const item_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer item_values.deinit();
    for (0..3) |i| try offset_data.write(i32, item_values, i, @as(i32, @intCast((i + 1) * 10)));
    item_values.freeze();
    const values = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, item_values }, &.{}, null);
    defer values.deinit();

    const key_ty: datatype.DataType = .int32;
    const value_ty: datatype.DataType = .int32;
    const key_field = try datatype.Field.create(allocator, "key", &key_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try datatype.Field.create(allocator, "value", &value_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const datatype.Field{ key_field, value_field };
    const entry_ty = datatype.DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries = try ArrayData.initRetained(allocator, entry_ty, 3, 0, 0, &.{null}, &.{ keys, values }, null);
    defer entries.deinit();

    const offsets = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer offsets.deinit();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 2);
    try offset_data.write(i32, offsets, 2, 2);
    try offset_data.write(i32, offsets, 3, 3);
    offsets.freeze();
    defer offsets.deinit();

    const entries_field = try datatype.Field.create(allocator, "entries", &entries.type, false, &.{});
    defer entries_field.deinit();
    const map_ty = datatype.DataType{ .map = .{ .entries = entries_field, .keys_sorted = true } };
    const data = try ArrayData.initRetained(allocator, map_ty, 3, 0, 0, &.{ null, offsets }, &.{entries}, null);
    defer data.deinit();
    try data.validate();

    const arr = try MapArray.fromData(data);
    try std.testing.expect(arr.keysSorted());
    try std.testing.expectEqual(@as(usize, 2), arr.entryRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.entryRange(1).len);
    try std.testing.expectEqual(@as(usize, 2), arr.entryRange(2).offset);

    const second_keys = try arr.keysOwned(0);
    defer second_keys.deinit();
    const second_key_arr = try primitive.NumericArray(i32).fromData(second_keys);
    try std.testing.expectEqual(@as(usize, 2), second_key_arr.len);
    try std.testing.expectEqual(@as(i32, 2), second_key_arr.value(1));

    const sliced = arr.slice(1, 2);
    try std.testing.expectEqual(@as(usize, 1), sliced.offset);
    try std.testing.expectEqual(@as(usize, 0), sliced.entryRange(0).len);

    const owned = try sliced.sliceOwned(0, 1);
    defer owned.deinit();
    const owned_arr = try MapArray.fromData(owned);
    try std.testing.expectEqual(@as(usize, 0), owned_arr.entryRange(0).len);

    const clone = try sliced.cloneRetained();
    defer clone.deinit();
    const clone_arr = try MapArray.fromData(clone);
    try std.testing.expectEqual(@as(usize, 2), clone_arr.entryRange(1).offset);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}
