// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Dictionary array typed views.

const std = @import("std");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array_data = @import("data.zig");
const common = @import("common.zig");
const ArrayData = array_data.ArrayData;

pub fn DictionaryArray(comptime Index: type) type {
    ensureInteger(Index);

    return struct {
        const Self = @This();
        pub const IndexType = Index;

        view: common.ValidityView(.bitmap),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (data.type.id() != .dictionary) return error.TypeMismatch;
            if (data.type.dictionary.index_type.id() != common.typeIdFor(Index)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.dictionary == null) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.ValidityView(.bitmap).init(data) };
        }

        pub fn dictionaryBaseData(self: Self) *const ArrayData {
            return self.view.base.data.dictionary.?;
        }

        pub fn indexValue(self: Self, i: usize) Index {
            const values = self.view.base.data.buffers[1].?;
            return offset_data.read(Index, values, self.view.base.offset + i);
        }

        pub fn valueIndex(self: Self, i: usize) usize {
            return indexAsUsize(self.indexValue(i));
        }

        pub fn valueOwned(self: Self, i: usize) array_data.DataSliceError!?*ArrayData {
            if (self.view.isNull(i)) return null;
            return self.dictionaryBaseData().slice(self.valueIndex(i), 1);
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
    const Buffer = @import("../buffer.zig").Buffer;
    const builder = @import("../builder.zig");
    const array = @import("../array.zig");

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
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(i8, 1), arr.indexValue(1));
    try std.testing.expectEqual(@as(usize, 1), arr.valueIndex(1));
    try std.testing.expect(arr.view.isNull(2));

    const owned_value = (try arr.valueOwned(1)).?;
    defer owned_value.deinit();
    const value_arr = try array.NumericArray(i32).fromData(owned_value);
    try std.testing.expectEqual(@as(i32, 20), value_arr.value(0));
    try std.testing.expect((try arr.valueOwned(2)) == null);

    const sliced = DictionaryArray(i8){ .view = arr.view.slice(1, 2) };
    try std.testing.expectEqual(@as(i8, 1), sliced.indexValue(0));
    try std.testing.expectEqual(@as(usize, 1), sliced.view.nullCount());

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try DictionaryArray(i8).fromData(sliced_owned);
    try std.testing.expectEqual(@as(i8, 1), sliced_owned_arr.indexValue(0));

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try DictionaryArray(i8).fromData(sliced_clone);
    try std.testing.expectEqual(@as(i8, 0), sliced_clone_arr.indexValue(1));

    try std.testing.expectError(error.TypeMismatch, DictionaryArray(i16).fromData(data));
}
