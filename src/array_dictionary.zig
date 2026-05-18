// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Dictionary array typed views.

const std = @import("std");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array_data = @import("array_data.zig");
const common = @import("array_base.zig");
const ArrayData = array_data.ArrayData;

pub fn DictionaryArray(comptime Index: type) type {
    ensureInteger(Index);

    return struct {
        const Self = @This();
        pub const IndexType = Index;

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: ?usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (data.type.id() != .dictionary) return error.TypeMismatch;
            if (data.type.dictionary.index_type.id() != common.typeIdFor(Index)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.dictionary == null) return error.InvalidBufferLayout;
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

        pub fn dictionaryBaseData(self: Self) *const ArrayData {
            return self.data.dictionary.?;
        }

        pub fn indexValue(self: Self, i: usize) Index {
            const values = self.data.buffers[1].?;
            return offset_data.read(Index, values, self.offset + i);
        }

        pub fn valueIndex(self: Self, i: usize) usize {
            return indexAsUsize(self.indexValue(i));
        }

        pub fn valueOwned(self: Self, i: usize) array_data.DataSliceError!?*ArrayData {
            if (self.isNull(i)) return null;
            return self.dictionaryBaseData().slice(self.valueIndex(i), 1);
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

fn ensureInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => _ = common.typeIdFor(T),
        else => @compileError("unsupported Arrow dictionary index type: " ++ @typeName(T)),
    }
}

fn indexAsUsize(value: anytype) usize {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed and value < 0) unreachable;
    return @intCast(value);
}

test "DictionaryArray exposes indices and dictionary values" {
    const allocator = std.testing.allocator;
    const Buffer = @import("buffer.zig").Buffer;
    const builder = @import("builder.zig");
    const array = @import("array.zig");

    var dict_builder = builder.NumericBuilder(i32).init(allocator);
    defer dict_builder.deinit();
    try dict_builder.appendSlice(&.{ 10, 20 });
    const dictionary = try dict_builder.finish();
    defer dictionary.deinit();

    const index_values = try Buffer.allocate(allocator, 4 * @sizeOf(i8));
    errdefer index_values.deinit();
    index_values.data[0] = 0;
    index_values.data[1] = 1;
    index_values.data[2] = 0;
    index_values.data[3] = 1;
    index_values.freeze();
    defer index_values.deinit();

    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.deinit();
    validity.data[0] = 0b00001011;
    validity.freeze();
    defer validity.deinit();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{ .index_type = &index_ty, .value_type = &value_ty } };
    const data = try ArrayData.initRetained(allocator, dict_ty, 4, 0, 1, &.{ validity, index_values }, &.{}, dictionary);
    defer data.deinit();
    try data.validate();

    const arr = try DictionaryArray(i8).fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());
    try std.testing.expectEqual(@as(i8, 1), arr.indexValue(1));
    try std.testing.expectEqual(@as(usize, 1), arr.valueIndex(1));
    try std.testing.expect(arr.isNull(2));

    const owned_value = (try arr.valueOwned(1)).?;
    defer owned_value.deinit();
    const value_arr = try array.NumericArray(i32).fromData(owned_value);
    try std.testing.expectEqual(@as(i32, 20), value_arr.value(0));
    try std.testing.expect((try arr.valueOwned(2)) == null);

    const sliced = arr.slice(1, 2);
    try std.testing.expectEqual(@as(i8, 1), sliced.indexValue(0));
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());

    const sliced_owned = try sliced.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try DictionaryArray(i8).fromData(sliced_owned);
    try std.testing.expectEqual(@as(i8, 1), sliced_owned_arr.indexValue(0));

    const sliced_clone = try sliced.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try DictionaryArray(i8).fromData(sliced_clone);
    try std.testing.expectEqual(@as(i8, 0), sliced_clone_arr.indexValue(1));

    try std.testing.expectError(error.TypeMismatch, DictionaryArray(i16).fromData(data));
}
