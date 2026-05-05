const std = @import("std");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const offset_data = @import("offsets.zig");
const Buffer = @import("buffer.zig").Buffer;

pub const Error = error{
    InvalidBufferCount,
    InvalidChildCount,
    MissingValuesBuffer,
    MissingOffsetsBuffer,
    MissingDictionary,
    MissingTypeIdsBuffer,
    MissingUnionOffsetsBuffer,
    ValuesBufferTooSmall,
    ValidityBufferTooSmall,
    OffsetsBufferTooSmall,
    TypeIdsBufferTooSmall,
    UnionOffsetsBufferTooSmall,
    NullCountMismatch,
    NullCountWithoutValidity,
    NullCountOutOfBounds,
    NegativeOffset,
    OffsetValueOutOfBounds,
    OffsetsNotMonotonic,
    UnionTypeIdOutOfBounds,
    UnionOffsetOutOfBounds,
    UnionOffsetNotMonotonic,
    ChildTypeMismatch,
    ChildLengthTooSmall,
    DictionaryTypeMismatch,
    InvalidDictionaryIndexType,
    UnexpectedChild,
    UnexpectedDictionary,
};

pub fn validate(data: anytype) (Error || checked.Error || datatype.ValidationError)!void {
    try data.type.validate();
    const total = try checked.add(data.offset, data.len);
    try validateData(data, data.type, total);
}

fn validateData(data: anytype, ty: datatype.DataType, total: usize) (Error || checked.Error || datatype.ValidationError)!void {
    const layout = ty.layout();
    try expectBufferCount(data, layout.buffers.len);
    try validateNulls(data, total, layout.null_layout);
    try validateChildCount(data, ty.childCount());
    if (layout.has_dictionary) {
        if (data.dictionary == null) return error.MissingDictionary;
    } else if (data.dictionary != null) {
        return error.UnexpectedDictionary;
    }

    switch (ty) {
        .bool, .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64, .float16, .float32, .float64, .date32, .date64, .time32, .time64, .timestamp, .duration => {
            try validateFixedWidth(data, total, ty);
        },
        .binary, .utf8 => try validateBinaryLike(data, total, i32),
        .large_binary, .large_utf8 => try validateBinaryLike(data, total, i64),
        .list => |meta| try validateListLike(data, total, meta.child, i32),
        .large_list => |meta| try validateListLike(data, total, meta.child, i64),
        .fixed_size_list => |meta| try validateFixedSizeList(data, total, meta),
        .struct_ => |meta| try validateStruct(data, total, meta),
        .sparse_union => |meta| try validateUnion(data, total, meta, false),
        .dense_union => |meta| try validateUnion(data, total, meta, true),
        .dictionary => |meta| try validateDictionary(data, total, meta),
        .null_ => {},
    }
}

fn validateChildCount(data: anytype, expected: usize) Error!void {
    if (data.children.len == expected) return;
    if (expected == 0) return error.UnexpectedChild;
    return error.InvalidChildCount;
}

fn expectBufferCount(data: anytype, expected: usize) Error!void {
    if (data.buffers.len != expected) return error.InvalidBufferCount;
}

fn validateNulls(data: anytype, total: usize, layout: datatype.NullLayout) (Error || checked.Error)!void {
    switch (layout) {
        .always_null => {
            if (data.null_count != data.len) return error.NullCountMismatch;
        },
        .none => {
            if (data.null_count != 0 and data.null_count != bitmap.unknown_null_count)
                return error.NullCountWithoutValidity;
        },
        .bitmap => {
            if (data.null_count != bitmap.unknown_null_count and data.null_count > data.len)
                return error.NullCountOutOfBounds;

            if (data.buffers[0]) |validity_buf| {
                const needed = if (data.len == 0) 0 else try bitmap.byteLenChecked(total);
                if (validity_buf.size < needed) return error.ValidityBufferTooSmall;
                if (data.null_count != bitmap.unknown_null_count) {
                    const actual = data.len - bitmap.countSetBits(validity_buf.dataSlice(), data.offset, data.len);
                    if (actual != data.null_count) return error.NullCountMismatch;
                }
            } else if (data.null_count != 0 and data.null_count != bitmap.unknown_null_count) {
                return error.NullCountWithoutValidity;
            }
        },
    }
}

fn validateFixedWidth(data: anytype, total: usize, ty: datatype.DataType) (Error || checked.Error)!void {
    const value_needed: usize = if (data.len == 0)
        0
    else if (ty.id() == .bool)
        try bitmap.byteLenChecked(total)
    else
        try checked.mul(total, @as(usize, ty.bitWidth()) / 8);

    if (data.buffers[1]) |values_buf| {
        if (values_buf.size < value_needed) return error.ValuesBufferTooSmall;
    } else if (data.len > 0) {
        return error.MissingValuesBuffer;
    }
}

fn validateBinaryLike(data: anytype, total: usize, comptime Offset: type) (Error || checked.Error)!void {
    const values = data.buffers[2] orelse return error.MissingValuesBuffer;
    const offsets = try validateOffsetsBuffer(data, total, Offset);
    if (offsets) |offset_buf| try validateOffsets(data, offset_buf, values.size, Offset);
}

fn validateListLike(data: anytype, total: usize, child_field: datatype.Field, comptime Offset: type) (Error || checked.Error || datatype.ValidationError)!void {
    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, child_field.type.*)) return error.ChildTypeMismatch;
    try child.validate();

    const offsets = try validateOffsetsBuffer(data, total, Offset);
    if (offsets) |offset_buf| try validateOffsets(data, offset_buf, child.len, Offset);
}

fn validateFixedSizeList(data: anytype, total: usize, meta: datatype.FixedSizeListMeta) (Error || checked.Error || datatype.ValidationError)!void {
    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, meta.child.type.*)) return error.ChildTypeMismatch;
    try child.validate();

    const needed = try checked.mul(total, meta.len);
    if (child.len < needed) return error.ChildLengthTooSmall;
}

fn validateStruct(data: anytype, total: usize, meta: datatype.StructMeta) (Error || checked.Error || datatype.ValidationError)!void {
    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        if (child.len < total) return error.ChildLengthTooSmall;
    }
}

fn validateUnion(data: anytype, total: usize, meta: datatype.UnionMeta, comptime dense: bool) (Error || checked.Error || datatype.ValidationError)!void {
    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        if (!dense and child.len < total) return error.ChildLengthTooSmall;
    }

    const type_ids = data.buffers[1] orelse return error.MissingTypeIdsBuffer;
    const needed_type_ids = try checked.add(data.offset, data.len);
    if (type_ids.size < needed_type_ids) return error.TypeIdsBufferTooSmall;

    const offsets: ?*Buffer = if (dense) blk: {
        const buf = data.buffers[2] orelse return error.MissingUnionOffsetsBuffer;
        const needed = try checked.mul(needed_type_ids, @sizeOf(i32));
        if (buf.size < needed) return error.UnionOffsetsBufferTooSmall;
        break :blk buf;
    } else null;

    var last_offsets = [_]usize{0} ** 128;
    for (0..data.len) |i| {
        const code = offset_data.read(i8, type_ids, data.offset + i);
        const child_index = childIndexFor(meta, code) orelse return error.UnionTypeIdOutOfBounds;
        if (offsets) |offset_buf| {
            const off = try offset_data.toUsize(offset_data.read(i32, offset_buf, data.offset + i));
            if (off >= data.children[child_index].len) return error.UnionOffsetOutOfBounds;
            const code_index: usize = @intCast(code);
            if (off < last_offsets[code_index]) return error.UnionOffsetNotMonotonic;
            last_offsets[code_index] = off;
        }
    }
}

fn validateDictionary(data: anytype, total: usize, meta: datatype.DictionaryMeta) (Error || checked.Error || datatype.ValidationError)!void {
    if (!meta.index_type.isInteger()) return error.InvalidDictionaryIndexType;
    try validateFixedWidth(data, total, meta.index_type.*);

    const dict = data.dictionary.?;
    try dict.validate();
    if (!datatype.DataType.equals(dict.type, meta.value_type.*)) return error.DictionaryTypeMismatch;
}

fn validateOffsetsBuffer(data: anytype, total: usize, comptime Offset: type) (Error || checked.Error)!?*Buffer {
    const offsets = data.buffers[1] orelse {
        if (data.len == 0) return null;
        return error.MissingOffsetsBuffer;
    };

    const required_offsets = if (data.len > 0 or offsets.size > 0) try checked.add(total, 1) else 0;
    const needed = try checked.mul(required_offsets, @sizeOf(Offset));
    if (offsets.size < needed) return error.OffsetsBufferTooSmall;
    return offsets;
}

fn validateOffsets(data: anytype, offsets: *const Buffer, limit: usize, comptime Offset: type) Error!void {
    try offset_data.validateMonotonic(Offset, offsets, data.offset, data.len, limit);
}

fn childIndexFor(meta: datatype.UnionMeta, code: i8) ?usize {
    if (code < 0) return null;
    for (meta.type_ids, 0..) |id, i| {
        if (id == code) return i;
    }
    return null;
}

fn writeTestInt(comptime T: type, buffer: *Buffer, index: usize, value: T) void {
    offset_data.write(T, buffer, index, @intCast(value)) catch unreachable;
}

fn testArrayData() type {
    return @import("array_data.zig").ArrayData;
}

test "validate fixed width storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const values = try Buffer.allocate(allocator, 7 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    const data = try ArrayData.init(allocator, .int32, 5, 2, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try data.validate();

    const small = try Buffer.allocate(allocator, 6 * @sizeOf(i32));
    errdefer small.release();
    small.freeze();
    const short_data = try ArrayData.init(allocator, .int32, 5, 2, 0, &.{ null, small }, &.{}, null, false);
    defer short_data.release();
    try std.testing.expectError(error.ValuesBufferTooSmall, short_data.validate());

    const bool_values = try Buffer.allocate(allocator, bitmap.byteLen(8));
    errdefer bool_values.release();
    bool_values.freeze();
    const bool_data = try ArrayData.init(allocator, .bool, 8, 0, 0, &.{ null, bool_values }, &.{}, null, false);
    defer bool_data.release();
    try bool_data.validate();

    const empty = try ArrayData.init(allocator, .int32, 0, 10, 0, &.{ null, null }, &.{}, null, false);
    defer empty.release();
    try empty.validate();
}

test "validate null count rules" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.release();
    validity.data[0] = 0b00000101;
    validity.freeze();

    const values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const mismatch = try ArrayData.init(allocator, .int32, 3, 0, 2, &.{ validity, values }, &.{}, null, false);
    defer mismatch.release();
    try std.testing.expectError(error.NullCountMismatch, mismatch.validate());

    const values_without_validity = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values_without_validity.release();
    values_without_validity.freeze();
    const missing_validity = try ArrayData.init(allocator, .int32, 3, 0, 1, &.{ null, values_without_validity }, &.{}, null, false);
    defer missing_validity.release();
    try std.testing.expectError(error.NullCountWithoutValidity, missing_validity.validate());

    const values_for_bounds = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values_for_bounds.release();
    values_for_bounds.freeze();
    const out_of_bounds = try ArrayData.init(allocator, .int32, 3, 0, 4, &.{ null, values_for_bounds }, &.{}, null, false);
    defer out_of_bounds.release();
    try std.testing.expectError(error.NullCountOutOfBounds, out_of_bounds.validate());
}

test "validate fixed width rejects child and dictionary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    const parent_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer parent_values.release();
    parent_values.freeze();
    const parent = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, parent_values }, &.{child}, null, true);
    defer parent.release();
    try std.testing.expectError(error.UnexpectedChild, parent.validate());

    const index_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer index_values.release();
    index_values.freeze();
    const with_dictionary = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, index_values }, &.{}, child, true);
    defer with_dictionary.release();
    try std.testing.expectError(error.UnexpectedDictionary, with_dictionary.validate());
}

test "validate null and binary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const null_data = try ArrayData.init(allocator, .null_, 3, 0, 3, &.{null}, &.{}, null, false);
    defer null_data.release();
    try null_data.validate();
    try std.testing.expectEqual(@as(usize, 3), null_data.nullCount());
    null_data.null_count = 0;
    try std.testing.expectError(error.NullCountMismatch, null_data.validate());

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.release();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    const binary = try ArrayData.init(allocator, .binary, 2, 0, 0, &.{ null, offsets, values }, &.{}, null, false);
    defer binary.release();
    try binary.validate();

    const short_offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer short_offsets.release();
    short_offsets.freeze();
    const invalid = try ArrayData.init(allocator, .binary, 2, 0, 0, &.{ null, short_offsets, values.retain() }, &.{}, null, false);
    defer invalid.release();
    try std.testing.expectError(error.OffsetsBufferTooSmall, invalid.validate());
}

test "validate list and struct storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();
    defer offsets.release();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const list = try ArrayData.init(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null, true);
    defer list.release();
    try list.validate();

    const fields = [_]datatype.Field{.{ .name = "a", .type = &value_ty }};
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const struct_data = try ArrayData.init(allocator, struct_ty, 3, 0, 0, &.{null}, &.{child}, null, true);
    defer struct_data.release();
    try struct_data.validate();

    const invalid_struct = try ArrayData.init(allocator, struct_ty, 6, 0, 0, &.{null}, &.{child}, null, true);
    defer invalid_struct.release();
    try std.testing.expectError(error.ChildLengthTooSmall, invalid_struct.validate());
}

test "validate dictionary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const index_values = try Buffer.allocate(allocator, 3 * @sizeOf(i8));
    errdefer index_values.release();
    index_values.freeze();
    defer index_values.release();

    const dict_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer dict_values.release();
    dict_values.freeze();
    const dict = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, dict_values }, &.{}, null, false);
    defer dict.release();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{ .index_type = &index_ty, .value_type = &value_ty } };
    const data = try ArrayData.init(allocator, dict_ty, 3, 0, 0, &.{ null, index_values }, &.{}, dict, true);
    defer data.release();
    try data.validate();

    const missing = try ArrayData.init(allocator, dict_ty, 3, 0, 0, &.{ null, index_values.retain() }, &.{}, null, false);
    defer missing.release();
    try std.testing.expectError(error.MissingDictionary, missing.validate());
}

test "validate dense union storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const int_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer int_values.release();
    int_values.freeze();
    const int_child = try ArrayData.init(allocator, .int32, 2, 0, 0, &.{ null, int_values }, &.{}, null, false);
    defer int_child.release();

    const bool_values = try Buffer.allocate(allocator, bitmap.byteLen(1));
    errdefer bool_values.release();
    bool_values.data[0] = 1;
    bool_values.freeze();
    const bool_child = try ArrayData.init(allocator, .bool, 1, 0, 0, &.{ null, bool_values }, &.{}, null, false);
    defer bool_child.release();

    const type_ids = try Buffer.allocate(allocator, 3);
    errdefer type_ids.release();
    type_ids.data[0] = 7;
    type_ids.data[1] = 8;
    type_ids.data[2] = 7;
    type_ids.freeze();
    defer type_ids.release();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 0);
    writeTestInt(i32, offsets, 2, 1);
    offsets.freeze();
    defer offsets.release();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const fields = [_]datatype.Field{
        .{ .name = "i", .type = &int_ty },
        .{ .name = "b", .type = &bool_ty },
    };
    const ids = [_]i8{ 7, 8 };
    const union_ty = datatype.DataType{ .dense_union = .{ .fields = &fields, .type_ids = &ids } };
    const data = try ArrayData.init(allocator, union_ty, 3, 0, 0, &.{ null, type_ids, offsets }, &.{ int_child, bool_child }, null, true);
    defer data.release();
    try data.validate();

    const bad_offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer bad_offsets.release();
    writeTestInt(i32, bad_offsets, 0, 0);
    writeTestInt(i32, bad_offsets, 1, 1);
    writeTestInt(i32, bad_offsets, 2, 1);
    bad_offsets.freeze();
    defer bad_offsets.release();
    const invalid = try ArrayData.init(allocator, union_ty, 3, 0, 0, &.{ null, type_ids, bad_offsets }, &.{ int_child, bool_child }, null, true);
    defer invalid.release();
    try std.testing.expectError(error.UnionOffsetOutOfBounds, invalid.validate());
}
