// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Sparse and dense union array typed views.

const std = @import("std");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array_data = @import("data.zig");
const common = @import("base.zig");
const ArrayData = array_data.ArrayData;
const Buffer = @import("../buffer.zig").Buffer;

pub const SparseUnionArray = struct {
    view: common.ValidityView(.none),

    pub fn fromData(data: *const ArrayData) common.ViewError!SparseUnionArray {
        if (data.type.id() != .sparse_union) return error.TypeMismatch;
        if (data.buffers.len != 1 or data.buffers[0] == null) return error.InvalidBufferLayout;
        if (data.children.len != data.type.sparse_union.fields.len) return error.InvalidBufferLayout;
        return .{ .view = common.ValidityView(.none).init(data) };
    }

    pub fn typeId(self: SparseUnionArray, i: usize) i8 {
        return readTypeId(self.view.base.data.buffers[0].?, self.view.base.offset + i);
    }

    pub fn childIndex(self: SparseUnionArray, i: usize) ?usize {
        return childIndexFor(self.view.base.data.type.sparse_union, self.typeId(i));
    }

    pub fn childBaseData(self: SparseUnionArray, index: usize) ?*const ArrayData {
        if (index >= self.view.base.data.children.len) return null;
        return self.view.base.data.children[index];
    }

    pub fn valueOwned(self: SparseUnionArray, i: usize) array_data.DataSliceError!?*ArrayData {
        const child_index = self.childIndex(i) orelse return null;
        return self.view.base.data.children[child_index].slice(self.view.base.offset + i, 1);
    }
};

pub const DenseUnionArray = struct {
    view: common.ValidityView(.none),

    pub fn fromData(data: *const ArrayData) common.ViewError!DenseUnionArray {
        if (data.type.id() != .dense_union) return error.TypeMismatch;
        if (data.buffers.len != 2 or data.buffers[0] == null or data.buffers[1] == null) return error.InvalidBufferLayout;
        if (data.children.len != data.type.dense_union.fields.len) return error.InvalidBufferLayout;
        return .{ .view = common.ValidityView(.none).init(data) };
    }

    pub fn typeId(self: DenseUnionArray, i: usize) i8 {
        return readTypeId(self.view.base.data.buffers[0].?, self.view.base.offset + i);
    }

    pub fn childIndex(self: DenseUnionArray, i: usize) ?usize {
        return childIndexFor(self.view.base.data.type.dense_union, self.typeId(i));
    }

    pub fn childBaseData(self: DenseUnionArray, index: usize) ?*const ArrayData {
        if (index >= self.view.base.data.children.len) return null;
        return self.view.base.data.children[index];
    }

    pub fn valueOffset(self: DenseUnionArray, i: usize) usize {
        const raw = offset_data.read(i32, self.view.base.data.buffers[1].?, self.view.base.offset + i);
        return offset_data.toUsize(raw) catch unreachable;
    }

    pub fn valueOwned(self: DenseUnionArray, i: usize) array_data.DataSliceError!?*ArrayData {
        const child_index = self.childIndex(i) orelse return null;
        return self.view.base.data.children[child_index].slice(self.valueOffset(i), 1);
    }
};

fn readTypeId(buffer: *const Buffer, index: usize) i8 {
    return offset_data.read(i8, buffer, index);
}

fn childIndexFor(meta: datatype.UnionMeta, code: i8) ?usize {
    if (code < 0) return null;
    for (meta.type_ids, 0..) |id, i| {
        if (id == code) return i;
    }
    return null;
}

test "DenseUnionArray exposes offsets and values" {
    const allocator = std.testing.allocator;
    const array = @import("../array.zig");

    const int_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer int_values.deinit();
    try offset_data.write(i32, int_values, 0, 10);
    try offset_data.write(i32, int_values, 1, 30);
    int_values.freeze();
    const int_child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, int_values }, &.{}, null);
    defer int_child.deinit();

    const bool_values = try Buffer.allocate(allocator, 1);
    errdefer bool_values.deinit();
    bool_values.data[0] = 1;
    bool_values.freeze();
    const bool_child = try ArrayData.initOwned(allocator, .bool, 1, 0, 0, &.{ null, bool_values }, &.{}, null);
    defer bool_child.deinit();

    const type_ids = try Buffer.allocate(allocator, 3);
    errdefer type_ids.deinit();
    type_ids.data[0] = 7;
    type_ids.data[1] = 8;
    type_ids.data[2] = 7;
    type_ids.freeze();
    defer type_ids.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 0);
    try offset_data.write(i32, offsets, 2, 1);
    offsets.freeze();
    defer offsets.deinit();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const int_field = try datatype.Field.create(allocator, "i", &int_ty, true, &.{});
    defer int_field.deinit();
    const bool_field = try datatype.Field.create(allocator, "b", &bool_ty, true, &.{});
    defer bool_field.deinit();
    const fields = [_]*const datatype.Field{ int_field, bool_field };
    const ids = [_]i8{ 7, 8 };
    const ty = datatype.DataType{ .dense_union = .{ .fields = &fields, .type_ids = &ids } };
    const data = try ArrayData.initRetained(allocator, ty, 3, 0, 0, &.{ type_ids, offsets }, &.{ int_child, bool_child }, null);
    defer data.deinit();
    try data.validate();

    const arr = try DenseUnionArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(i8, 8), arr.typeId(1));
    try std.testing.expectEqual(@as(?usize, 1), arr.childIndex(1));
    try std.testing.expectEqual(@as(usize, 1), arr.valueOffset(2));
    try std.testing.expectEqual(@as(usize, 0), arr.view.nullCount());
    try std.testing.expect(arr.childBaseData(0) != null);

    const value = (try arr.valueOwned(2)).?;
    defer value.deinit();
    const value_arr = try array.NumericArray(i32).fromData(value);
    try std.testing.expectEqual(@as(i32, 30), value_arr.value(0));

    const sliced = DenseUnionArray{ .view = .{ .base = arr.view.base.slice(1, 2) } };
    try std.testing.expectEqual(@as(i8, 8), sliced.typeId(0));
    try std.testing.expectEqual(@as(usize, 1), sliced.valueOffset(1));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try DenseUnionArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(i8, 7), sliced_owned_arr.typeId(1));

    const clone = try sliced.view.base.cloneRetained();
    defer clone.deinit();
    const clone_arr = try DenseUnionArray.fromData(clone);
    try std.testing.expectEqual(@as(i8, 8), clone_arr.typeId(0));
}

test "SparseUnionArray uses parent row offsets" {
    const allocator = std.testing.allocator;
    const array = @import("../array.zig");
    const builder = @import("../builder.zig");

    var ints = builder.NumericBuilder(i32).init(allocator);
    defer ints.deinit();
    try ints.appendSlice(&.{ 10, 0, 30 });
    const int_child = try ints.finish();
    defer int_child.deinit();

    var bools = builder.BooleanBuilder.init(allocator);
    defer bools.deinit();
    try bools.appendSlice(&.{ false, true, false });
    const bool_child = try bools.finish();
    defer bool_child.deinit();

    const type_ids = try Buffer.allocate(allocator, 3);
    errdefer type_ids.deinit();
    type_ids.data[0] = 7;
    type_ids.data[1] = 8;
    type_ids.data[2] = 7;
    type_ids.freeze();
    defer type_ids.deinit();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const int_field = try datatype.Field.create(allocator, "i", &int_ty, true, &.{});
    defer int_field.deinit();
    const bool_field = try datatype.Field.create(allocator, "b", &bool_ty, true, &.{});
    defer bool_field.deinit();
    const fields = [_]*const datatype.Field{ int_field, bool_field };
    const ids = [_]i8{ 7, 8 };
    const ty = datatype.DataType{ .sparse_union = .{ .fields = &fields, .type_ids = &ids } };
    const data = try ArrayData.initRetained(allocator, ty, 3, 0, 0, &.{type_ids}, &.{ int_child, bool_child }, null);
    defer data.deinit();
    try data.validate();

    const arr = try SparseUnionArray.fromData(data);
    try std.testing.expectEqual(@as(i8, 8), arr.typeId(1));
    try std.testing.expectEqual(@as(?usize, 0), arr.childIndex(2));
    try std.testing.expectEqual(@as(usize, 0), arr.view.nullCount());
    try std.testing.expect(arr.childBaseData(1) != null);

    const int_value = (try arr.valueOwned(2)).?;
    defer int_value.deinit();
    const int_arr = try array.NumericArray(i32).fromData(int_value);
    try std.testing.expectEqual(@as(i32, 30), int_arr.value(0));

    const bool_value = (try arr.valueOwned(1)).?;
    defer bool_value.deinit();
    const bool_arr = try array.BooleanArray.fromData(bool_value);
    try std.testing.expect(bool_arr.value(0));

    const sliced = SparseUnionArray{ .view = .{ .base = arr.view.base.slice(1, 2) } };
    try std.testing.expectEqual(@as(i8, 8), sliced.typeId(0));
    try std.testing.expectEqual(@as(i8, 7), sliced.typeId(1));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try SparseUnionArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(i8, 7), sliced_owned_arr.typeId(1));

    const clone = try sliced.view.base.cloneRetained();
    defer clone.deinit();
    const clone_arr = try SparseUnionArray.fromData(clone);
    try std.testing.expectEqual(@as(i8, 8), clone_arr.typeId(0));
}
