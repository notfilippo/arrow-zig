// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const array = @import("../array.zig");
const bitmap = @import("../bitmap.zig");
const builder = @import("../builder.zig");
const buffer = @import("../buffer.zig");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");
const ArrayData = array.ArrayData;
const ArrowArray = cdi.ArrowArray;
const ArrowSchema = cdi.ArrowSchema;
const Buffer = buffer.Buffer;

const arrayIsReleased = cdi.arrayIsReleased;
const exportArray = cdi.exportArray;
const exportType = cdi.exportType;
const importArray = cdi.importArray;
const importArrayFromSchema = cdi.importArrayFromSchema;
const schemaIsReleased = cdi.schemaIsReleased;

test "exportArray keeps array data alive" {
    const allocator = std.testing.allocator;
    var b = builder.BinaryBuilder.init(allocator);
    defer b.deinit();
    try b.append("abc");
    try b.appendNull();

    const data = try b.finish();
    defer data.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, data, &exported);
    try std.testing.expectEqual(@as(usize, 2), data.refCount());
    try std.testing.expectEqual(@as(i64, 2), exported.length);
    try std.testing.expectEqual(@as(i64, 1), exported.null_count);
    try std.testing.expectEqual(@as(i64, 3), exported.n_buffers);
    try std.testing.expect(exported.buffers.?[1] != null);
    try std.testing.expect(exported.buffers.?[2] != null);

    exported.release.?(&exported);
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(@as(usize, 1), data.refCount());
}

test "exportArray exports nested list arrays" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 1, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 2, .little);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const list_item_field = try datatype.Field.create(allocator, "", &value_ty, true, &.{});
    defer list_item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = list_item_field } };
    const data = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, data, &exported);
    try std.testing.expectEqual(@as(usize, 2), data.refCount());
    try std.testing.expectEqual(@as(usize, 3), child.refCount());
    try std.testing.expectEqual(@as(i64, 1), exported.n_children);
    try std.testing.expect(exported.children != null);
    try std.testing.expectEqual(@as(i64, 2), exported.children.?[0].length);
    try std.testing.expect(exported.children.?[0].buffers.?[1] != null);

    exported.release.?(&exported);
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(@as(usize, 1), data.refCount());
    try std.testing.expectEqual(@as(usize, 2), child.refCount());
}

test "importArrayFromSchema imports exported array" {
    const allocator = std.testing.allocator;
    var b = builder.BinaryBuilder.init(allocator);
    defer b.deinit();
    try b.append("abc");
    try b.appendNull();
    try b.append("def");

    const source = try b.finish();
    defer source.deinit();

    var schema: ArrowSchema = undefined;
    try exportType(allocator, source.type, &schema);
    defer schema.release.?(&schema);

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArrayFromSchema(allocator, &schema, &exported);
    defer imported.deinit();
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expect(!schemaIsReleased(&schema));

    const view = try array.BinaryArray.fromData(imported);
    try std.testing.expectEqualStrings("abc", view.valueBytes(0));
    try std.testing.expect(view.isNull(1));
    try std.testing.expectEqualStrings("def", view.valueBytes(2));
}

test "importArray imports exported primitive array" {
    const allocator = std.testing.allocator;
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.append(10);
    try b.appendNull();
    try b.append(30);

    const source = try b.finish();
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const imported = try importArray(allocator, source.type, &exported);
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const view = try array.NumericArray(i32).fromData(imported);
    try std.testing.expectEqual(@as(usize, 3), view.len);
    try std.testing.expectEqual(@as(usize, 1), view.nullCount());
    try std.testing.expectEqual(@as(i32, 10), view.value(0));
    try std.testing.expect(view.isNull(1));
    try std.testing.expectEqual(@as(i32, 30), view.value(2));

    imported.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.refCount());
}

test "importArray imports exported list array" {
    const allocator = std.testing.allocator;
    var b = builder.ListBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();
    try b.values().appendSlice(&.{ 1, 2 });
    try b.append();
    try b.appendEmpty();
    try b.values().append(3);
    try b.append();

    const source = try b.finish();
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArray(allocator, source.type, &exported);
    defer imported.deinit();
    try imported.validate();

    const view = try array.ListArray.fromData(imported);
    try std.testing.expectEqual(@as(usize, 3), view.len);
    try std.testing.expectEqual(@as(usize, 2), view.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), view.valueRange(1).len);
    const child = try array.NumericArray(i32).fromData(view.childBaseData());
    try std.testing.expectEqual(@as(i32, 3), child.value(2));
}

test "importArray imports exported struct array" {
    const allocator = std.testing.allocator;
    var numbers = builder.NumericBuilder(i32).init(allocator);
    defer numbers.deinit();
    try numbers.appendSlice(&.{ 4, 5, 6 });
    const number_data = try numbers.finish();
    defer number_data.deinit();

    var flags = builder.BooleanBuilder.init(allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{ true, false, true });
    const flag_data = try flags.finish();
    defer flag_data.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field_struct = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field_struct.deinit();
    const flag_field_struct = try datatype.Field.create(allocator, "flag", &flag_ty, true, &.{});
    defer flag_field_struct.deinit();
    const struct_fields_arr = [_]*const datatype.Field{ number_field_struct, flag_field_struct };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields_arr } };
    const source = try ArrayData.initRetained(allocator, struct_ty, 3, 0, 0, &.{null}, &.{ number_data, flag_data }, null);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArray(allocator, source.type, &exported);
    defer imported.deinit();
    try imported.validate();

    const view = try array.StructArray.fromData(imported);
    try std.testing.expectEqual(@as(usize, 2), view.fieldCount());
    try std.testing.expectEqualStrings("number", view.fieldName(0).?);
    const imported_numbers = try array.NumericArray(i32).fromData(view.fieldBaseNamed("number").?);
    try std.testing.expectEqual(@as(i32, 5), imported_numbers.value(1));
}

test "importArray imports exported dictionary array" {
    const allocator = std.testing.allocator;
    const index_values = try Buffer.allocate(allocator, 3 * @sizeOf(i8));
    errdefer index_values.deinit();
    index_values.data[0] = 0;
    index_values.data[1] = 1;
    index_values.data[2] = 0;
    index_values.freeze();
    defer index_values.deinit();

    const dict_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer dict_values.deinit();
    std.mem.writeInt(i32, dict_values.data[0..4], 10, .little);
    std.mem.writeInt(i32, dict_values.data[4..8], 20, .little);
    dict_values.freeze();
    const dictionary = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, dict_values }, &.{}, null);
    defer dictionary.deinit();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &value_ty,
        .ordered = true,
    } };
    const source = try ArrayData.initRetained(allocator, dict_ty, 3, 0, 0, &.{ null, index_values }, &.{}, dictionary);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArray(allocator, source.type, &exported);
    defer imported.deinit();
    try imported.validate();

    try std.testing.expect(imported.type.dictionary.ordered);
    try std.testing.expect(imported.dictionary != null);
    try std.testing.expectEqual(@as(u8, 1), imported.buffers[1].?.dataSlice()[1]);
    const values = try array.NumericArray(i32).fromData(imported.dictionary.?);
    try std.testing.expectEqual(@as(i32, 20), values.value(1));
}

test "importArray imports exported dense union array" {
    const allocator = std.testing.allocator;
    const int_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer int_values.deinit();
    std.mem.writeInt(i32, int_values.data[0..4], 10, .little);
    std.mem.writeInt(i32, int_values.data[4..8], 30, .little);
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
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 0, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 1, .little);
    offsets.freeze();
    defer offsets.deinit();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const union_int_field = try datatype.Field.create(allocator, "i", &int_ty, true, &.{});
    defer union_int_field.deinit();
    const union_bool_field = try datatype.Field.create(allocator, "b", &bool_ty, true, &.{});
    defer union_bool_field.deinit();
    const union_fields_arr = [_]*const datatype.Field{ union_int_field, union_bool_field };
    const ids = [_]i8{ 7, 8 };
    const union_ty = datatype.DataType{ .dense_union = .{ .fields = &union_fields_arr, .type_ids = &ids } };
    const source = try ArrayData.initRetained(allocator, union_ty, 3, 0, 0, &.{ type_ids, offsets }, &.{ int_child, bool_child }, null);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArray(allocator, source.type, &exported);
    defer imported.deinit();
    try imported.validate();

    try std.testing.expectEqual(@as(u8, 8), imported.buffers[0].?.dataSlice()[1]);
    const imported_ints = try array.NumericArray(i32).fromData(imported.children[0]);
    try std.testing.expectEqual(@as(i32, 30), imported_ints.value(1));
}

test "importArray imports exported null array" {
    const allocator = std.testing.allocator;
    const source = try ArrayData.initOwned(allocator, .null_, 4, 0, 4, &.{}, &.{}, null);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);

    const imported = try importArray(allocator, source.type, &exported);
    defer imported.deinit();
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(.null_, imported.type);
    try std.testing.expectEqual(@as(usize, 4), imported.len);
    try std.testing.expectEqual(@as(usize, 4), imported.nullCount());
}

test "importArray normalizes unknown null count for null array" {
    const allocator = std.testing.allocator;
    var arr = minimalArray();
    arr.length = 3;
    arr.null_count = -1;

    const imported = try importArray(allocator, .null_, &arr);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 3), imported.null_count);
    try imported.validate();
}

test "importArray releases moved array once" {
    const allocator = std.testing.allocator;
    var release_count: usize = 0;
    var arr = minimalArray();
    arr.length = 1;
    arr.null_count = 1;
    arr.private_data = &release_count;
    arr.release = countArrayRelease;

    const imported = try importArray(allocator, .null_, &arr);
    try std.testing.expect(arrayIsReleased(&arr));
    try std.testing.expectEqual(@as(usize, 0), release_count);

    imported.deinit();
    try std.testing.expectEqual(@as(usize, 1), release_count);
}

test "importArray accepts empty fixed width array with offset and null values buffer" {
    const allocator = std.testing.allocator;
    var arr = minimalArray();
    arr.offset = 5;
    arr.n_buffers = 2;
    var buffers = [_]?*const anyopaque{ null, null };
    arr.buffers = &buffers;

    const imported = try importArray(allocator, .int32, &arr);
    defer imported.deinit();

    try std.testing.expect(arrayIsReleased(&arr));
    try std.testing.expectEqual(@as(usize, 0), imported.len);
    try std.testing.expectEqual(@as(usize, 5), imported.offset);
    try imported.validate();
}

test "importArray child keeps moved parent owner alive" {
    const allocator = std.testing.allocator;
    var b = builder.ListBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();
    try b.values().appendSlice(&.{ 1, 2 });
    try b.append();

    const source = try b.finish();
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const imported = try importArray(allocator, source.type, &exported);
    const child = imported.children[0].retain();

    imported.deinit();
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const child_view = try array.NumericArray(i32).fromData(child);
    try std.testing.expectEqual(@as(i32, 2), child_view.value(1));

    child.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.refCount());
}

test "importArray dictionary keeps moved parent owner alive" {
    const allocator = std.testing.allocator;
    const index_values = try Buffer.allocate(allocator, @sizeOf(i8));
    errdefer index_values.deinit();
    index_values.data[0] = 0;
    index_values.freeze();
    defer index_values.deinit();

    const dict_values = try Buffer.allocate(allocator, @sizeOf(i32));
    errdefer dict_values.deinit();
    std.mem.writeInt(i32, dict_values.data[0..4], 55, .little);
    dict_values.freeze();
    const dictionary = try ArrayData.initOwned(allocator, .int32, 1, 0, 0, &.{ null, dict_values }, &.{}, null);
    defer dictionary.deinit();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &value_ty,
    } };
    const source = try ArrayData.initRetained(allocator, dict_ty, 1, 0, 0, &.{ null, index_values }, &.{}, dictionary);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, source, &exported);
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const imported = try importArray(allocator, source.type, &exported);
    const imported_dictionary = imported.dictionary.?.retain();

    imported.deinit();
    try std.testing.expectEqual(@as(usize, 2), source.refCount());

    const dict_view = try array.NumericArray(i32).fromData(imported_dictionary);
    try std.testing.expectEqual(@as(i32, 55), dict_view.value(0));

    imported_dictionary.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.refCount());
}

fn noopArrayRelease(arr: *ArrowArray) callconv(.c) void {
    arr.release = null;
}

fn countArrayRelease(arr: *ArrowArray) callconv(.c) void {
    const release_count: *usize = @ptrCast(@alignCast(arr.private_data.?));
    release_count.* += 1;
    arr.release = null;
}

fn minimalArray() ArrowArray {
    return .{
        .length = 0,
        .null_count = 0,
        .offset = 0,
        .n_buffers = 0,
        .n_children = 0,
        .buffers = null,
        .children = null,
        .dictionary = null,
        .release = noopArrayRelease,
        .private_data = null,
    };
}

test "importArray rejects invalid top level metadata" {
    const allocator = std.testing.allocator;

    var released = minimalArray();
    released.release = null;
    try std.testing.expectError(error.ReleasedArray, importArray(allocator, .null_, &released));

    var negative_len = minimalArray();
    negative_len.length = -1;
    try std.testing.expectError(error.NegativeLength, importArray(allocator, .null_, &negative_len));

    var negative_offset = minimalArray();
    negative_offset.offset = -1;
    try std.testing.expectError(error.NegativeOffset, importArray(allocator, .null_, &negative_offset));

    var bad_null_count = minimalArray();
    bad_null_count.null_count = -2;
    try std.testing.expectError(error.InvalidNullCount, importArray(allocator, .null_, &bad_null_count));

    var too_many_nulls = minimalArray();
    too_many_nulls.length = 1;
    too_many_nulls.null_count = 2;
    try std.testing.expectError(error.NullCountOutOfBounds, importArray(allocator, .null_, &too_many_nulls));
}

test "importArray rejects invalid buffer and child layout" {
    const allocator = std.testing.allocator;

    var wrong_buffers = minimalArray();
    wrong_buffers.n_buffers = 1;
    var one_buffer = [_]?*const anyopaque{null};
    wrong_buffers.buffers = &one_buffer;
    try std.testing.expectError(error.InvalidBufferCount, importArray(allocator, .int32, &wrong_buffers));

    var missing_values = minimalArray();
    missing_values.length = 1;
    missing_values.n_buffers = 2;
    var missing_values_buffers = [_]?*const anyopaque{ null, null };
    missing_values.buffers = &missing_values_buffers;
    try std.testing.expectError(error.MissingValuesBuffer, importArray(allocator, .int32, &missing_values));

    const child_ty: datatype.DataType = .int32;
    const list_child_field = try datatype.Field.create(allocator, "", &child_ty, true, &.{});
    defer list_child_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = list_child_field } };
    var wrong_children = minimalArray();
    wrong_children.n_buffers = 2;
    var list_buffers = [_]?*const anyopaque{ null, null };
    wrong_children.buffers = &list_buffers;
    try std.testing.expectError(error.InvalidChildCount, importArray(allocator, list_ty, &wrong_children));
}

test "importArray rejects dictionary mismatches" {
    const allocator = std.testing.allocator;
    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &value_ty,
    } };

    var missing_dictionary = minimalArray();
    missing_dictionary.n_buffers = 2;
    var index_buffers = [_]?*const anyopaque{ null, null };
    missing_dictionary.buffers = &index_buffers;
    try std.testing.expectError(error.MissingDictionary, importArray(allocator, dict_ty, &missing_dictionary));

    var unexpected_dictionary = minimalArray();
    var dict = minimalArray();
    unexpected_dictionary.dictionary = &dict;
    try std.testing.expectError(error.UnexpectedDictionary, importArray(allocator, .null_, &unexpected_dictionary));
}

test "importArray accepts unaligned values buffer" {
    const allocator = std.testing.allocator;
    const mem = try allocator.alignedAlloc(u8, .fromByteUnits(buffer.arrow_alignment), buffer.arrow_alignment);
    defer allocator.free(mem);
    @memset(mem, 0);
    std.mem.writeInt(i32, mem[1..5], 42, .little);

    var arr = minimalArray();
    arr.length = 1;
    arr.n_buffers = 2;
    var buffers = [_]?*const anyopaque{
        null,
        @ptrCast(mem.ptr + 1),
    };
    arr.buffers = &buffers;

    const imported = try importArray(allocator, .int32, &arr);
    defer imported.deinit();

    const view = try array.NumericArray(i32).fromData(imported);
    try std.testing.expectEqual(@as(i32, 42), view.value(0));
}

test "importArray accepts unaligned validity buffer" {
    const allocator = std.testing.allocator;
    const validity_mem = try allocator.alignedAlloc(u8, .fromByteUnits(buffer.arrow_alignment), buffer.arrow_alignment);
    defer allocator.free(validity_mem);
    @memset(validity_mem, 0);

    const values_mem = try allocator.alignedAlloc(u8, .fromByteUnits(buffer.arrow_alignment), 66 * @sizeOf(i32));
    defer allocator.free(values_mem);
    @memset(values_mem, 0);

    const validity = validity_mem[1..10];
    bitmap.setBitsTo(validity, 0, 66, true);
    bitmap.clearBit(validity, 4);

    var arr = minimalArray();
    arr.length = 65;
    arr.offset = 1;
    arr.null_count = 1;
    arr.n_buffers = 2;
    var buffers = [_]?*const anyopaque{
        @ptrCast(validity.ptr),
        @ptrCast(values_mem.ptr),
    };
    arr.buffers = &buffers;

    const imported = try importArray(allocator, .int32, &arr);
    defer imported.deinit();

    const view = try array.NumericArray(i32).fromData(imported);
    try std.testing.expectEqual(@as(usize, 1), view.nullCount());
    try std.testing.expect(view.isNull(3));
}
