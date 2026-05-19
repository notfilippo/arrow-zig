// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! List, large list, and fixed size list array types.
//!
//! List values are represented by ranges into a single child array. Owned value
//! access returns retained child slices.

const std = @import("std");
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array_data = @import("data.zig");
const primitive = @import("primitive.zig");
const common = @import("common.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const ListKind = enum {
    list,
    large_list,
};

const ListViewKind = enum {
    list_view,
    large_list_view,
};

fn offsetTypeFor(comptime kind: ListKind) type {
    return switch (kind) {
        .list => i32,
        .large_list => i64,
    };
}

fn viewOffsetTypeFor(comptime kind: ListViewKind) type {
    return switch (kind) {
        .list_view => i32,
        .large_list_view => i64,
    };
}

fn dataTypeMatches(comptime kind: ListKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .list => ty.id() == .list,
        .large_list => ty.id() == .large_list,
    };
}

fn viewDataTypeMatches(comptime kind: ListViewKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .list_view => ty.id() == .list_view,
        .large_list_view => ty.id() == .large_list_view,
    };
}

pub const ValueRange = offset_data.ValueRange;

pub fn VarListArray(comptime kind: ListKind) type {
    const Offset = offsetTypeFor(kind);

    return struct {
        const Self = @This();

        view: common.ValidityView(.bitmap),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.children.len != 1) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.ValidityView(.bitmap).init(data) };
        }

        pub fn childBaseData(self: Self) *const ArrayData {
            return self.view.base.data.children[0];
        }

        pub fn valueRange(self: Self, i: usize) ValueRange {
            const offsets = self.view.base.data.buffers[1].?;
            return offset_data.rangeAt(Offset, offsets, self.view.base.offset + i);
        }

        pub fn valueOwned(self: Self, i: usize) array_data.DataSliceError!*ArrayData {
            const range = self.valueRange(i);
            return self.view.base.data.children[0].slice(range.offset, range.len);
        }
    };
}

pub const ListArray = VarListArray(.list);
pub const LargeListArray = VarListArray(.large_list);

fn VarListViewArray(comptime kind: ListViewKind) type {
    const Offset = viewOffsetTypeFor(kind);

    return struct {
        const Self = @This();

        view: common.ValidityView(.bitmap),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!viewDataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len != 3 or data.children.len != 1) return error.InvalidBufferLayout;
            if (data.len > 0 and (data.buffers[1] == null or data.buffers[2] == null)) return error.InvalidBufferLayout;
            return .{ .view = common.ValidityView(.bitmap).init(data) };
        }

        pub fn childBaseData(self: Self) *const ArrayData {
            return self.view.base.data.children[0];
        }

        pub fn valueRange(self: Self, i: usize) ValueRange {
            const slot = self.view.base.offset + i;
            const offsets = self.view.base.data.buffers[1].?;
            const sizes = self.view.base.data.buffers[2].?;
            return .{
                .offset = @intCast(offset_data.read(Offset, offsets, slot)),
                .len = @intCast(offset_data.read(Offset, sizes, slot)),
            };
        }

        pub fn valueOwned(self: Self, i: usize) array_data.DataSliceError!*ArrayData {
            const range = self.valueRange(i);
            return self.view.base.data.children[0].slice(range.offset, range.len);
        }
    };
}

pub const ListViewArray = VarListViewArray(.list_view);
pub const LargeListViewArray = VarListViewArray(.large_list_view);

pub const FixedSizeListArray = struct {
    view: common.ValidityView(.bitmap),

    pub fn fromData(data: *const ArrayData) common.ViewError!FixedSizeListArray {
        if (data.type.id() != .fixed_size_list) return error.TypeMismatch;
        if (data.buffers.len != 1 or data.children.len != 1) return error.InvalidBufferLayout;
        return .{ .view = common.ValidityView(.bitmap).init(data) };
    }

    pub fn childBaseData(self: FixedSizeListArray) *const ArrayData {
        return self.view.base.data.children[0];
    }

    pub fn listSize(self: FixedSizeListArray) usize {
        return self.view.base.data.type.fixed_size_list.len;
    }

    pub fn valueRange(self: FixedSizeListArray, i: usize) ValueRange {
        const slot = checked.add(self.view.base.offset, i) catch unreachable;
        return .{
            .offset = checked.mul(slot, self.listSize()) catch unreachable,
            .len = self.listSize(),
        };
    }

    pub fn valueOwned(self: FixedSizeListArray, i: usize) array_data.DataSliceError!*ArrayData {
        const range = self.valueRange(i);
        return self.view.base.data.children[0].slice(range.offset, range.len);
    }
};

test "ListArray value ranges and owned values" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.deinit();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer offsets.deinit();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 2);
    try offset_data.write(i32, offsets, 2, 2);
    try offset_data.write(i32, offsets, 3, 5);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const list_item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer list_item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = list_item_field } };
    const data = try ArrayData.initRetained(allocator, list_ty, 3, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.deinit();
    try data.validate();

    const arr = try ListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 0), arr.view.nullCount());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).len);

    const values = try arr.valueOwned(2);
    defer values.deinit();
    const values_arr = try primitive.NumericArray(i32).fromData(values);
    try std.testing.expectEqual(@as(usize, 3), values_arr.view.base.len);

    const view_slice = arr.view.slice(1, 2);
    const sliced_owned = try view_slice.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try ListArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(usize, 0), sliced_owned_arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 3), sliced_owned_arr.valueRange(1).len);

    const sliced_clone = try view_slice.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try ListArray.fromData(sliced_clone);
    try std.testing.expectEqual(@as(usize, 0), sliced_clone_arr.valueRange(0).len);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(4, 1));
}

test "LargeListArray uses large offsets" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.deinit();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i64));
    errdefer offsets.deinit();
    try offset_data.write(i64, offsets, 0, 0);
    try offset_data.write(i64, offsets, 1, 1);
    try offset_data.write(i64, offsets, 2, 2);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const large_list_item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer large_list_item_field.deinit();
    const list_ty = datatype.DataType{ .large_list = .{ .child = large_list_item_field } };
    const data = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.deinit();
    try data.validate();

    const arr = try LargeListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(1).len);
    try std.testing.expectEqual(.large_list, arr.view.base.data.type.id());
}

test "ListViewArray value ranges can be non monotonic" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.deinit();
    for (0..5) |i| try offset_data.write(i32, child_values, i, i + 1);
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    try offset_data.write(i32, offsets, 0, 2);
    try offset_data.write(i32, offsets, 1, 0);
    try offset_data.write(i32, offsets, 2, 4);
    offsets.freeze();
    defer offsets.deinit();

    const sizes = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer sizes.deinit();
    try offset_data.write(i32, sizes, 0, 2);
    try offset_data.write(i32, sizes, 1, 3);
    try offset_data.write(i32, sizes, 2, 1);
    sizes.freeze();
    defer sizes.deinit();

    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .list_view = .{ .child = item_field } };
    const data = try ArrayData.initRetained(allocator, list_ty, 3, 0, 0, &.{ null, offsets, sizes }, &.{child}, null);
    defer data.deinit();
    try data.validate();

    const arr = try ListViewArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 3), arr.valueRange(1).len);

    const values = try arr.valueOwned(0);
    defer values.deinit();
    const values_arr = try primitive.NumericArray(i32).fromData(values);
    try std.testing.expectEqual(@as(i32, 3), values_arr.value(0));
}

test "LargeListViewArray uses large offsets and sizes" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.deinit();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i64));
    errdefer offsets.deinit();
    try offset_data.write(i64, offsets, 0, 1);
    try offset_data.write(i64, offsets, 1, 0);
    offsets.freeze();
    defer offsets.deinit();

    const sizes = try Buffer.allocate(allocator, 2 * @sizeOf(i64));
    errdefer sizes.deinit();
    try offset_data.write(i64, sizes, 0, 1);
    try offset_data.write(i64, sizes, 1, 0);
    sizes.freeze();
    defer sizes.deinit();

    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .large_list_view = .{ .child = item_field } };
    const data = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets, sizes }, &.{child}, null);
    defer data.deinit();
    try data.validate();

    const arr = try LargeListViewArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(0).len);
    try std.testing.expectEqual(.large_list_view, arr.view.base.data.type.id());
}

test "FixedSizeListArray value ranges and owned values" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 6 * @sizeOf(i32));
    errdefer child_values.deinit();
    for (0..6) |i| try offset_data.write(i32, child_values, i, i + 1);
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 6, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.deinit();
    validity.data[0] = 0b00000101;
    validity.freeze();
    defer validity.deinit();

    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .fixed_size_list = .{ .child = item_field, .len = 2 } };
    const data = try ArrayData.initRetained(allocator, list_ty, 3, 0, 1, &.{validity}, &.{child}, null);
    defer data.deinit();
    try data.validate();

    const arr = try FixedSizeListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 2), arr.listSize());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(1).len);
    try std.testing.expect(arr.view.isNull(1));

    const values = try arr.valueOwned(2);
    defer values.deinit();
    const values_arr = try primitive.NumericArray(i32).fromData(values);
    try std.testing.expectEqual(@as(usize, 2), values_arr.view.base.len);
    try std.testing.expectEqual(@as(i32, 5), values_arr.value(0));
    try std.testing.expectEqual(@as(i32, 6), values_arr.value(1));

    const sliced = FixedSizeListArray{ .view = arr.view.slice(1, 2) };
    try std.testing.expectEqual(@as(usize, 2), sliced.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 4), sliced.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 1), sliced.view.nullCount());

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try FixedSizeListArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(usize, 2), sliced_owned_arr.valueRange(0).offset);

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try FixedSizeListArray.fromData(sliced_clone);
    try std.testing.expectEqual(@as(usize, 4), sliced_clone_arr.valueRange(1).offset);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(4, 1));
}
