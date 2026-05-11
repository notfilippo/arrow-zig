const std = @import("std");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array_data = @import("array_data.zig");
const fixed_view = @import("array_fixed_view.zig");
const common = @import("array_view_common.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const ListKind = enum {
    list,
    large_list,
};

fn offsetTypeFor(comptime kind: ListKind) type {
    return switch (kind) {
        .list => i32,
        .large_list => i64,
    };
}

fn dataTypeMatches(comptime kind: ListKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .list => ty.id() == .list,
        .large_list => ty.id() == .large_list,
    };
}

pub const ValueRange = offset_data.ValueRange;

pub fn ListView(comptime kind: ListKind) type {
    const Offset = offsetTypeFor(kind);

    return struct {
        const Self = @This();

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.children.len != 1) return error.InvalidBufferLayout;
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

        pub fn childBaseData(self: Self) *const ArrayData {
            return self.data.children[0];
        }

        pub fn valueRange(self: Self, i: usize) ValueRange {
            const offsets = self.data.buffers[1].?;
            return offset_data.rangeAt(Offset, offsets, self.offset + i);
        }

        pub fn valueOwned(self: Self, i: usize) !*ArrayData {
            const range = self.valueRange(i);
            return self.data.children[0].slice(range.offset, range.len);
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
            const clamped = common.clampedLen(self.len, off, length) catch unreachable;
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
            };
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

        pub fn sliceOwned(self: Self, off: usize, length: usize) !*ArrayData {
            const clamped = try common.clampedLen(self.len, off, length);
            return self.data.slice(off, clamped);
        }

        pub fn cloneRetained(self: Self) !*ArrayData {
            return self.data.cloneRetained();
        }
    };
}

pub const ListArray = ListView(.list);
pub const LargeListArray = ListView(.large_list);

test "ListArray value ranges and owned values" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.release();

    const offsets = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer offsets.release();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 2);
    try offset_data.write(i32, offsets, 2, 2);
    try offset_data.write(i32, offsets, 3, 5);
    offsets.freeze();
    defer offsets.release();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const data = try ArrayData.initRetained(allocator, list_ty, 3, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.release();
    try data.validate();

    const arr = try ListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(usize, 0), arr.nullCount());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).len);

    const values = try arr.valueOwned(2);
    defer values.release();
    const values_arr = try fixed_view.NumericArray(i32).fromData(values);
    try std.testing.expectEqual(@as(usize, 3), values_arr.len);
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}

test "LargeListArray uses large offsets" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.release();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i64));
    errdefer offsets.release();
    try offset_data.write(i64, offsets, 0, 0);
    try offset_data.write(i64, offsets, 1, 1);
    try offset_data.write(i64, offsets, 2, 2);
    offsets.freeze();
    defer offsets.release();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .large_list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const data = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.release();
    try data.validate();

    const arr = try LargeListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(1).len);
    try std.testing.expectEqual(.large_list, arr.dataType().id());
}
