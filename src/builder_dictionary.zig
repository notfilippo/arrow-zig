// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Dictionary builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datatype = @import("datatype.zig");
const array = @import("array.zig");
const numeric = @import("builder_numeric.zig");
const ArrayData = array.ArrayData;

pub const DictionaryOptions = struct {
    ordered: bool = false,
};

pub fn DictionaryBuilderError(comptime Index: type) type {
    return numeric.NumericBuilder(Index).Error || error{IndexOutOfBounds};
}

pub fn DictionaryBuilder(comptime Index: type) type {
    ensureInteger(Index);
    const IndexBuilder = numeric.NumericBuilder(Index);

    return struct {
        const Self = @This();
        pub const Array = array.DictionaryArray(Index);
        pub const Error = DictionaryBuilderError(Index);

        allocator: Allocator,
        indices: IndexBuilder,
        dictionary: *ArrayData,
        ordered: bool,

        pub fn init(allocator: Allocator, dictionary: *ArrayData) Self {
            return initOptions(allocator, dictionary, .{});
        }

        pub fn initOptions(allocator: Allocator, dictionary: *ArrayData, options: DictionaryOptions) Self {
            return .{
                .allocator = allocator,
                .indices = IndexBuilder.init(allocator),
                .dictionary = dictionary.retain(),
                .ordered = options.ordered,
            };
        }

        pub fn deinit(self: *Self) void {
            self.indices.deinit();
            self.dictionary.deinit();
        }

        pub fn reset(self: *Self) void {
            self.indices.reset();
        }

        pub fn append(self: *Self, index: Index) Error!void {
            if (!indexInBounds(index, self.dictionary.len)) return error.IndexOutOfBounds;
            try self.indices.append(index);
        }

        pub fn appendSlice(self: *Self, indices: []const Index) Error!void {
            for (indices) |index| {
                if (!indexInBounds(index, self.dictionary.len)) return error.IndexOutOfBounds;
            }
            try self.indices.appendSlice(indices);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.indices.appendNull();
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            try self.indices.appendNulls(n);
        }

        pub fn length(self: Self) usize {
            return self.indices.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const index_data = try self.indices.finish();
            defer index_data.deinit();

            const index_ty = indexDataType(Index);
            const value_ty = self.dictionary.type;
            const dict_ty = datatype.DataType{ .dictionary = .{
                .index_type = &index_ty,
                .value_type = &value_ty,
                .ordered = self.ordered,
            } };

            return ArrayData.initRetained(
                self.allocator,
                dict_ty,
                index_data.len,
                index_data.offset,
                index_data.null_count,
                index_data.buffers,
                &.{},
                self.dictionary,
            );
        }
    };
}

fn ensureInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => _ = array.typeIdFor(T),
        else => @compileError("unsupported Arrow dictionary index type: " ++ @typeName(T)),
    }
}

fn indexDataType(comptime Index: type) datatype.DataType {
    const id = comptime array.typeIdFor(Index);
    return @unionInit(datatype.DataType, @tagName(id), {});
}

fn indexInBounds(value: anytype, len: usize) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed and value < 0) return false;
    return @as(u128, @intCast(value)) < @as(u128, len);
}

test "DictionaryBuilder builds dictionary arrays" {
    const allocator = std.testing.allocator;

    var dict_builder = @import("builder.zig").Utf8Builder.init(allocator);
    defer dict_builder.deinit();
    try dict_builder.append("alpha");
    try dict_builder.append("beta");
    const dictionary = try dict_builder.finish();
    defer dictionary.deinit();

    var b = DictionaryBuilder(i8).initOptions(allocator, dictionary, .{ .ordered = true });
    defer b.deinit();
    try b.append(0);
    try b.append(1);
    try b.appendNull();
    try b.appendSlice(&.{ 1, 0 });

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.DictionaryArray(i8).fromData(data);
    try std.testing.expect(arr.view.base.data.type.dictionary.ordered);
    try std.testing.expectEqual(@as(usize, 5), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(i8, 1), arr.indexValue(1));
    try std.testing.expectEqual(@as(i8, 0), arr.indexValue(4));
    try std.testing.expect(arr.view.isNull(2));
    try std.testing.expectEqual(datatype.TypeId.utf8, arr.dictionaryBaseData().type.id());
}

test "DictionaryBuilder rejects out of bounds indices" {
    const allocator = std.testing.allocator;

    var dict_builder = @import("builder.zig").NumericBuilder(i32).init(allocator);
    defer dict_builder.deinit();
    try dict_builder.append(10);
    const dictionary = try dict_builder.finish();
    defer dictionary.deinit();

    var b = DictionaryBuilder(i8).init(allocator, dictionary);
    defer b.deinit();

    try std.testing.expectError(error.IndexOutOfBounds, b.append(1));
    try std.testing.expectError(error.IndexOutOfBounds, b.append(-1));
    try std.testing.expectError(error.IndexOutOfBounds, b.appendSlice(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(usize, 0), b.length());

    try b.append(0);
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
}
