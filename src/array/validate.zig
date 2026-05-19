// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow array storage validation.
//!
//! Validation checks buffer counts, byte sizes, null count consistency, child
//! layout, dictionary indices, and union offsets against the declared
//! `DataType`.

const std = @import("std");
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const bitmap = @import("../bitmap.zig");
const offset_data = @import("../offsets.zig");
const Buffer = @import("../buffer.zig").Buffer;

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
    ChildLengthMismatch,
    ChildOffsetMismatch,
    DictionaryIndexOutOfBounds,
    DictionaryTypeMismatch,
    InvalidDictionaryIndexType,
    NegativeViewLength,
    InvalidRunEndValue,
    RunEndNotIncreasing,
    RunEndOutOfBounds,
    ViewBufferIndexOutOfBounds,
    ViewBufferTooSmall,
    ViewOffsetOutOfBounds,
    NonNullableNulls,
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
    try expectBufferCount(data, layout.buffers.len, layout.variadic_buffers);
    try validateNulls(data, total, layout.null_layout);
    try validateChildCount(data, ty.childCount());
    if (layout.has_dictionary) {
        if (data.dictionary == null) return error.MissingDictionary;
    } else if (data.dictionary != null) {
        return error.UnexpectedDictionary;
    }

    switch (ty) {
        .bool, .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64, .float16, .float32, .float64, .date32, .date64, .time32, .time64, .timestamp, .duration, .month_interval, .day_time_interval, .month_day_nano_interval, .decimal32, .decimal64, .decimal128, .decimal256, .fixed_size_binary => {
            try validateFixedWidth(data, total, ty);
        },
        .binary, .utf8 => try validateBinaryLike(data, total, i32),
        .large_binary, .large_utf8 => try validateBinaryLike(data, total, i64),
        .binary_view, .utf8_view => try validateBinaryViewLike(data, total),
        .list => |meta| try validateListLike(data, total, meta.child, i32),
        .large_list => |meta| try validateListLike(data, total, meta.child, i64),
        .list_view => |meta| try validateListViewLike(data, total, meta.child, i32),
        .large_list_view => |meta| try validateListViewLike(data, total, meta.child, i64),
        .fixed_size_list => |meta| try validateFixedSizeList(data, total, meta),
        .map => |meta| try validateListLike(data, total, meta.entries, i32),
        .struct_ => |meta| try validateStruct(data, total, meta),
        .sparse_union => |meta| try validateUnion(data, total, meta, false),
        .dense_union => |meta| try validateUnion(data, total, meta, true),
        .run_end_encoded => |meta| try validateRunEndEncoded(data, total, meta),
        .dictionary => |meta| try validateDictionary(data, total, meta),
        .null_ => {},
    }
}

fn validateChildCount(data: anytype, expected: usize) Error!void {
    if (data.children.len == expected) return;
    if (expected == 0) return error.UnexpectedChild;
    return error.InvalidChildCount;
}

fn expectBufferCount(data: anytype, expected: usize, variadic: bool) Error!void {
    if (variadic) {
        if (data.buffers.len < expected) return error.InvalidBufferCount;
    } else if (data.buffers.len != expected) {
        return error.InvalidBufferCount;
    }
}

fn validateNulls(data: anytype, total: usize, layout: datatype.NullLayout) (Error || checked.Error)!void {
    switch (layout) {
        .always_null => {
            if (data.null_count) |nc| if (nc != data.len) return error.NullCountMismatch;
        },
        .none => {
            if (data.null_count) |nc| if (nc != 0) return error.NullCountWithoutValidity;
        },
        .bitmap => {
            if (data.null_count) |nc| if (nc > data.len) return error.NullCountOutOfBounds;

            if (data.buffers[0]) |validity_buf| {
                const needed = if (data.len == 0) 0 else try bitmap.byteLenChecked(total);
                if (validity_buf.size < needed) return error.ValidityBufferTooSmall;
                if (data.null_count) |nc| {
                    const actual = data.len - bitmap.countSetBits(validity_buf.dataSlice(), data.offset, data.len);
                    if (actual != nc) return error.NullCountMismatch;
                }
            } else {
                if (data.null_count) |nc| if (nc != 0) return error.NullCountWithoutValidity;
            }
        },
    }
}

fn validateFixedWidth(data: anytype, total: usize, ty: datatype.DataType) (Error || checked.Error)!void {
    const value_needed: usize = if (data.len == 0)
        0
    else switch (ty) {
        .bool => try bitmap.byteLenChecked(total),
        .fixed_size_binary => |meta| try checked.mul(total, meta.byte_width),
        else => try checked.mul(total, @as(usize, ty.bitWidth()) / 8),
    };

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

fn validateBinaryViewLike(data: anytype, total: usize) (Error || checked.Error)!void {
    const views = data.buffers[1] orelse {
        if (data.len == 0) return;
        return error.MissingValuesBuffer;
    };
    const needed = if (data.len == 0) 0 else try checked.mul(total, 16);
    if (views.size < needed) return error.ValuesBufferTooSmall;

    const validity = if (data.buffers[0]) |buf| buf.dataSlice() else null;
    for (0..data.len) |i| {
        const slot = data.offset + i;
        if (validity) |bits| {
            if (!bitmap.getBit(bits, slot)) continue;
        }
        try validateBinaryView(data, views, slot);
    }
}

fn validateBinaryView(data: anytype, views: *const Buffer, slot: usize) (Error || checked.Error)!void {
    const view_start = try checked.mul(slot, 16);
    const len = readViewI32(views, view_start);
    if (len < 0) return error.NegativeViewLength;
    if (len <= 12) return;

    const buffer_index = readViewI32(views, view_start + 8);
    if (buffer_index < 0) return error.ViewBufferIndexOutOfBounds;
    const data_index = try checked.add(2, @as(usize, @intCast(buffer_index)));
    if (data_index >= data.buffers.len) return error.ViewBufferIndexOutOfBounds;

    const buf = data.buffers[data_index] orelse return error.MissingValuesBuffer;
    const view_offset = readViewI32(views, view_start + 12);
    if (view_offset < 0) return error.ViewOffsetOutOfBounds;
    const start: usize = @intCast(view_offset);
    const end = try checked.add(start, @as(usize, @intCast(len)));
    if (end > buf.size) return error.ViewBufferTooSmall;
}

fn readViewI32(views: *const Buffer, byte_offset: usize) i32 {
    return std.mem.readInt(i32, views.dataSlice()[byte_offset..][0..4], .little);
}

fn validateListLike(data: anytype, total: usize, child_field: *const datatype.Field, comptime Offset: type) (Error || checked.Error || datatype.ValidationError)!void {
    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, child_field.type.*)) return error.ChildTypeMismatch;
    try child.validate();
    try validateNullable(child_field, child);

    const offsets = try validateOffsetsBuffer(data, total, Offset);
    if (offsets) |offset_buf| try validateOffsets(data, offset_buf, child.len, Offset);
}

fn validateListViewLike(data: anytype, total: usize, child_field: *const datatype.Field, comptime Offset: type) (Error || checked.Error || datatype.ValidationError)!void {
    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, child_field.type.*)) return error.ChildTypeMismatch;
    try child.validate();
    try validateNullable(child_field, child);

    const offsets = try validateViewOffsetBuffer(data, total, Offset, 1);
    const sizes = try validateViewOffsetBuffer(data, total, Offset, 2);
    if (offsets == null or sizes == null) return;

    const validity = if (data.buffers[0]) |buf| buf.dataSlice() else null;
    for (0..data.len) |i| {
        const slot = data.offset + i;
        if (validity) |bits| {
            if (!bitmap.getBit(bits, slot)) continue;
        }
        const start = try offset_data.toUsize(offset_data.read(Offset, offsets.?, slot));
        const len = offset_data.toUsize(offset_data.read(Offset, sizes.?, slot)) catch |err| switch (err) {
            error.NegativeOffset => return error.NegativeViewLength,
            else => |e| return e,
        };
        const end = try checked.add(start, len);
        if (end > child.len) return error.OffsetValueOutOfBounds;
    }
}

fn validateFixedSizeList(data: anytype, total: usize, meta: datatype.FixedSizeListMeta) (Error || checked.Error || datatype.ValidationError)!void {
    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, meta.child.type.*)) return error.ChildTypeMismatch;
    try child.validate();
    try validateNullable(meta.child, child);

    const needed = try checked.mul(total, meta.len);
    if (child.len < needed) return error.ChildLengthTooSmall;
}

fn validateStruct(data: anytype, total: usize, meta: datatype.StructMeta) (Error || checked.Error || datatype.ValidationError)!void {
    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        try validateNullable(field, child);
        if (child.len < total) return error.ChildLengthTooSmall;
    }
}

fn validateUnion(data: anytype, total: usize, meta: datatype.UnionMeta, comptime dense: bool) (Error || checked.Error || datatype.ValidationError)!void {
    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        if (!dense and child.len < total) return error.ChildLengthTooSmall;
    }

    const type_ids = data.buffers[0] orelse return error.MissingTypeIdsBuffer;
    const needed_type_ids = try checked.add(data.offset, data.len);
    if (type_ids.size < needed_type_ids) return error.TypeIdsBufferTooSmall;

    const offsets: ?*Buffer = if (dense) blk: {
        const buf = data.buffers[1] orelse return error.MissingUnionOffsetsBuffer;
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
    try validateDictionaryIndices(data, meta.index_type.*, dict.len);
}

fn validateRunEndEncoded(data: anytype, total: usize, meta: datatype.RunEndEncodedMeta) (Error || checked.Error || datatype.ValidationError)!void {
    const run_ends = data.children[0];
    const values = data.children[1];

    try run_ends.validate();
    try values.validate();
    if (!datatype.DataType.equals(run_ends.type, meta.run_ends.type.*)) return error.ChildTypeMismatch;
    if (!datatype.DataType.equals(values.type, meta.values.type.*)) return error.ChildTypeMismatch;
    try validateNullable(meta.run_ends, run_ends);
    try validateNullable(meta.values, values);
    if (run_ends.len != values.len) return error.ChildLengthMismatch;
    if (run_ends.offset != values.offset) return error.ChildOffsetMismatch;
    if (data.len == 0) return;
    if (run_ends.len == 0) return error.RunEndOutOfBounds;

    switch (run_ends.type) {
        .int16 => try validateRunEnds(i16, run_ends, data.offset, total),
        .int32 => try validateRunEnds(i32, run_ends, data.offset, total),
        .int64 => try validateRunEnds(i64, run_ends, data.offset, total),
        else => return error.InvalidRunEndType,
    }
}

fn validateRunEnds(comptime T: type, run_ends: anytype, logical_offset: usize, logical_total: usize) Error!void {
    const values = run_ends.buffers[1] orelse return error.MissingValuesBuffer;
    var previous: usize = 0;
    var covers_offset = false;
    for (0..run_ends.len) |i| {
        const current = try runEndToUsize(offset_data.read(T, values, run_ends.offset + i));
        if (current == 0) return error.InvalidRunEndValue;
        if (current <= previous) return error.RunEndNotIncreasing;
        if (current > logical_offset) covers_offset = true;
        previous = current;
    }
    if (!covers_offset or previous < logical_total) return error.RunEndOutOfBounds;
}

fn runEndToUsize(value: anytype) Error!usize {
    if (value < 0) return error.InvalidRunEndValue;
    if (@as(u128, @intCast(value)) > @as(u128, std.math.maxInt(usize))) return error.InvalidRunEndValue;
    return @intCast(value);
}

fn validateDictionaryIndices(data: anytype, index_ty: datatype.DataType, dict_len: usize) Error!void {
    if (data.len == 0) return;
    const values = data.buffers[1] orelse return error.MissingValuesBuffer;
    const validity = if (data.buffers[0]) |buf| buf.dataSlice() else null;
    switch (index_ty) {
        .int8 => try validateDictionaryIndexValues(i8, data, values, validity, dict_len),
        .int16 => try validateDictionaryIndexValues(i16, data, values, validity, dict_len),
        .int32 => try validateDictionaryIndexValues(i32, data, values, validity, dict_len),
        .int64 => try validateDictionaryIndexValues(i64, data, values, validity, dict_len),
        .uint8 => try validateDictionaryIndexValues(u8, data, values, validity, dict_len),
        .uint16 => try validateDictionaryIndexValues(u16, data, values, validity, dict_len),
        .uint32 => try validateDictionaryIndexValues(u32, data, values, validity, dict_len),
        .uint64 => try validateDictionaryIndexValues(u64, data, values, validity, dict_len),
        else => return error.InvalidDictionaryIndexType,
    }
}

fn validateDictionaryIndexValues(
    comptime T: type,
    data: anytype,
    values: *const Buffer,
    validity: ?[]const u8,
    dict_len: usize,
) Error!void {
    for (0..data.len) |i| {
        const slot = data.offset + i;
        if (validity) |bits| {
            if (!bitmap.getBit(bits, slot)) continue;
        }
        if (!dictionaryIndexInBounds(offset_data.read(T, values, slot), dict_len)) return error.DictionaryIndexOutOfBounds;
    }
}

fn dictionaryIndexInBounds(value: anytype, dict_len: usize) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed and value < 0) return false;
    return @as(u128, @intCast(value)) < @as(u128, dict_len);
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

fn validateViewOffsetBuffer(data: anytype, total: usize, comptime Offset: type, index: usize) (Error || checked.Error)!?*Buffer {
    const buf = data.buffers[index] orelse {
        if (data.len == 0) return null;
        return error.MissingOffsetsBuffer;
    };

    const needed = if (data.len == 0) 0 else try checked.mul(total, @sizeOf(Offset));
    if (buf.size < needed) return error.OffsetsBufferTooSmall;
    return buf;
}

fn validateOffsets(data: anytype, offsets: *const Buffer, limit: usize, comptime Offset: type) Error!void {
    try offset_data.validateMonotonic(Offset, offsets, data.offset, data.len, limit);
}

fn validateNullable(field: *const datatype.Field, child: anytype) Error!void {
    if (field.nullable) return;
    if (child.nullCount() != 0) return error.NonNullableNulls;
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
    return @import("data.zig").ArrayData;
}

test "validate fixed width storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const values = try Buffer.allocate(allocator, 7 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();
    const data = try ArrayData.initOwned(allocator, .int32, 5, 2, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const small = try Buffer.allocate(allocator, 6 * @sizeOf(i32));
    errdefer small.deinit();
    small.freeze();
    const short_data = try ArrayData.initOwned(allocator, .int32, 5, 2, 0, &.{ null, small }, &.{}, null);
    defer short_data.deinit();
    try std.testing.expectError(error.ValuesBufferTooSmall, short_data.validate());

    const bool_values = try Buffer.allocate(allocator, bitmap.byteLen(8));
    errdefer bool_values.deinit();
    bool_values.freeze();
    const bool_data = try ArrayData.initOwned(allocator, .bool, 8, 0, 0, &.{ null, bool_values }, &.{}, null);
    defer bool_data.deinit();
    try bool_data.validate();

    const empty = try ArrayData.initOwned(allocator, .int32, 0, 10, 0, &.{ null, null }, &.{}, null);
    defer empty.deinit();
    try empty.validate();
}

test "validate null count rules" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.deinit();
    validity.data[0] = 0b00000101;
    validity.freeze();

    const values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();

    const mismatch = try ArrayData.initOwned(allocator, .int32, 3, 0, 2, &.{ validity, values }, &.{}, null);
    defer mismatch.deinit();
    try std.testing.expectError(error.NullCountMismatch, mismatch.validate());

    const values_without_validity = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values_without_validity.deinit();
    values_without_validity.freeze();
    const missing_validity = try ArrayData.initOwned(allocator, .int32, 3, 0, 1, &.{ null, values_without_validity }, &.{}, null);
    defer missing_validity.deinit();
    try std.testing.expectError(error.NullCountWithoutValidity, missing_validity.validate());

    const values_for_bounds = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values_for_bounds.deinit();
    values_for_bounds.freeze();
    const out_of_bounds = try ArrayData.initOwned(allocator, .int32, 3, 0, 4, &.{ null, values_for_bounds }, &.{}, null);
    defer out_of_bounds.deinit();
    try std.testing.expectError(error.NullCountOutOfBounds, out_of_bounds.validate());
}

test "validate fixed width rejects child and dictionary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.deinit();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const parent_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer parent_values.deinit();
    parent_values.freeze();
    const parent = try ArrayData.initRetained(allocator, .int32, 4, 0, 0, &.{ null, parent_values }, &.{child}, null);
    defer parent.deinit();
    try std.testing.expectError(error.UnexpectedChild, parent.validate());

    const index_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer index_values.deinit();
    index_values.freeze();
    const with_dictionary = try ArrayData.initRetained(allocator, .int32, 4, 0, 0, &.{ null, index_values }, &.{}, child);
    defer with_dictionary.deinit();
    try std.testing.expectError(error.UnexpectedDictionary, with_dictionary.validate());
}

test "validate null and binary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const null_data = try ArrayData.initOwned(allocator, .null_, 3, 0, 3, &.{}, &.{}, null);
    defer null_data.deinit();
    try null_data.validate();
    try std.testing.expectEqual(@as(usize, 3), null_data.nullCount());
    null_data.null_count = 0;
    try std.testing.expectError(error.NullCountMismatch, null_data.validate());

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.deinit();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    const binary = try ArrayData.initOwned(allocator, .binary, 2, 0, 0, &.{ null, offsets, values }, &.{}, null);
    defer binary.deinit();
    try binary.validate();

    const fixed_values = try Buffer.allocate(allocator, 2 * 3);
    errdefer fixed_values.deinit();
    fixed_values.freeze();
    const fixed_ty = datatype.DataType{ .fixed_size_binary = .{ .byte_width = 3 } };
    const fixed = try ArrayData.initOwned(allocator, fixed_ty, 2, 0, 0, &.{ null, fixed_values }, &.{}, null);
    defer fixed.deinit();
    try fixed.validate();

    const decimal_values = try Buffer.allocate(allocator, 2 * 16);
    errdefer decimal_values.deinit();
    decimal_values.freeze();
    const decimal_ty = datatype.DataType{ .decimal128 = .{ .precision = 12, .scale = 2 } };
    const decimal = try ArrayData.initOwned(allocator, decimal_ty, 2, 0, 0, &.{ null, decimal_values }, &.{}, null);
    defer decimal.deinit();
    try decimal.validate();

    const decimal32_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer decimal32_values.deinit();
    decimal32_values.freeze();
    const decimal32_ty = datatype.DataType{ .decimal32 = .{ .precision = 9, .scale = 2 } };
    const decimal32 = try ArrayData.initOwned(allocator, decimal32_ty, 2, 0, 0, &.{ null, decimal32_values }, &.{}, null);
    defer decimal32.deinit();
    try decimal32.validate();

    const decimal64_values = try Buffer.allocate(allocator, 2 * @sizeOf(i64));
    errdefer decimal64_values.deinit();
    decimal64_values.freeze();
    const decimal64_ty = datatype.DataType{ .decimal64 = .{ .precision = 18, .scale = 2 } };
    const decimal64 = try ArrayData.initOwned(allocator, decimal64_ty, 2, 0, 0, &.{ null, decimal64_values }, &.{}, null);
    defer decimal64.deinit();
    try decimal64.validate();

    const short_fixed_values = try Buffer.allocate(allocator, 5);
    errdefer short_fixed_values.deinit();
    short_fixed_values.freeze();
    const short_fixed = try ArrayData.initOwned(allocator, fixed_ty, 2, 0, 0, &.{ null, short_fixed_values }, &.{}, null);
    defer short_fixed.deinit();
    try std.testing.expectError(error.ValuesBufferTooSmall, short_fixed.validate());

    const short_offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer short_offsets.deinit();
    short_offsets.freeze();
    const invalid = try ArrayData.initOwned(allocator, .binary, 2, 0, 0, &.{ null, short_offsets, values.retain() }, &.{}, null);
    defer invalid.deinit();
    try std.testing.expectError(error.OffsetsBufferTooSmall, invalid.validate());
}

test "validate list and struct storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.deinit();
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = item_field } };
    const list = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer list.deinit();
    try list.validate();

    const key_field = try datatype.Field.create(allocator, "key", &value_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try datatype.Field.create(allocator, "value", &value_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const datatype.Field{ key_field, value_field };
    const entry_ty = datatype.DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries = try ArrayData.initRetained(allocator, entry_ty, 5, 0, 0, &.{null}, &.{ child, child }, null);
    defer entries.deinit();
    const entries_field = try datatype.Field.create(allocator, "entries", &entry_ty, false, &.{});
    defer entries_field.deinit();
    const map_ty = datatype.DataType{ .map = .{ .entries = entries_field } };
    const map = try ArrayData.initRetained(allocator, map_ty, 2, 0, 0, &.{ null, offsets }, &.{entries}, null);
    defer map.deinit();
    try map.validate();

    const child_validity = try Buffer.allocate(allocator, 1);
    errdefer child_validity.deinit();
    child_validity.data[0] = 0b00000001;
    child_validity.freeze();
    defer child_validity.deinit();
    const child_with_null = try ArrayData.initRetained(allocator, .int32, 2, 0, 1, &.{ child_validity, child_values }, &.{}, null);
    defer child_with_null.deinit();

    const req_item_field = try datatype.Field.create(allocator, "item", &value_ty, false, &.{});
    defer req_item_field.deinit();
    const required_list_ty = datatype.DataType{ .list = .{ .child = req_item_field } };
    const required_list = try ArrayData.initRetained(allocator, required_list_ty, 1, 0, 0, &.{ null, offsets }, &.{child_with_null}, null);
    defer required_list.deinit();
    try std.testing.expectError(error.NonNullableNulls, required_list.validate());

    const bad_entries = try ArrayData.initRetained(allocator, entry_ty, 2, 0, 0, &.{null}, &.{ child_with_null, child }, null);
    defer bad_entries.deinit();
    const bad_map = try ArrayData.initRetained(allocator, map_ty, 1, 0, 0, &.{ null, offsets }, &.{bad_entries}, null);
    defer bad_map.deinit();
    try std.testing.expectError(error.NonNullableNulls, bad_map.validate());

    const a_field = try datatype.Field.create(allocator, "a", &value_ty, true, &.{});
    defer a_field.deinit();
    const fields_ptrs = [_]*const datatype.Field{a_field};
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields_ptrs } };
    const struct_data = try ArrayData.initRetained(allocator, struct_ty, 3, 0, 0, &.{null}, &.{child}, null);
    defer struct_data.deinit();
    try struct_data.validate();

    const req_a_field = try datatype.Field.create(allocator, "a", &value_ty, false, &.{});
    defer req_a_field.deinit();
    const req_fields_ptrs = [_]*const datatype.Field{req_a_field};
    const required_struct_ty = datatype.DataType{ .struct_ = .{ .fields = &req_fields_ptrs } };
    const required_struct = try ArrayData.initRetained(allocator, required_struct_ty, 2, 0, 0, &.{null}, &.{child_with_null}, null);
    defer required_struct.deinit();
    try std.testing.expectError(error.NonNullableNulls, required_struct.validate());

    const invalid_struct = try ArrayData.initRetained(allocator, struct_ty, 6, 0, 0, &.{null}, &.{child}, null);
    defer invalid_struct.deinit();
    try std.testing.expectError(error.ChildLengthTooSmall, invalid_struct.validate());
}

test "validate run end encoded storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");

    const run_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer run_values.deinit();
    writeTestInt(i32, run_values, 0, 2);
    writeTestInt(i32, run_values, 1, 5);
    writeTestInt(i32, run_values, 2, 7);
    run_values.freeze();
    const run_ends = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, run_values }, &.{}, null);
    errdefer run_ends.deinit();

    var value_builder = builder.NumericBuilder(i32).init(allocator);
    defer value_builder.deinit();
    try value_builder.appendSlice(&.{ 10, 20, 30 });
    const values = try value_builder.finish();
    errdefer values.deinit();

    const run_end_ty: datatype.DataType = .int32;
    const value_ty: datatype.DataType = .int32;
    const run_ends_field = try datatype.Field.create(allocator, "run_ends", &run_end_ty, false, &.{});
    defer run_ends_field.deinit();
    const values_field = try datatype.Field.create(allocator, "values", &value_ty, true, &.{});
    defer values_field.deinit();
    const ty = datatype.DataType{ .run_end_encoded = .{
        .run_ends = run_ends_field,
        .values = values_field,
    } };
    const data = try ArrayData.initOwned(allocator, ty, 7, 0, 0, &.{}, &.{ run_ends, values }, null);
    defer data.deinit();
    try data.validate();

    const bad_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer bad_values.deinit();
    writeTestInt(i32, bad_values, 0, 2);
    writeTestInt(i32, bad_values, 1, 2);
    writeTestInt(i32, bad_values, 2, 7);
    bad_values.freeze();
    const bad_run_ends = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, bad_values }, &.{}, null);
    errdefer bad_run_ends.deinit();
    const retained_values = data.children[1].retain();
    errdefer retained_values.deinit();
    const bad_data = try ArrayData.initOwned(allocator, ty, 7, 0, 0, &.{}, &.{ bad_run_ends, retained_values }, null);
    defer bad_data.deinit();
    try std.testing.expectError(error.RunEndNotIncreasing, bad_data.validate());
}

test "validate dictionary storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const index_values = try Buffer.allocate(allocator, 3 * @sizeOf(i8));
    errdefer index_values.deinit();
    writeTestInt(i8, index_values, 0, 0);
    writeTestInt(i8, index_values, 1, 1);
    writeTestInt(i8, index_values, 2, 3);
    index_values.freeze();
    defer index_values.deinit();

    const dict_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer dict_values.deinit();
    dict_values.freeze();
    const dict = try ArrayData.initOwned(allocator, .int32, 4, 0, 0, &.{ null, dict_values }, &.{}, null);
    defer dict.deinit();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{ .index_type = &index_ty, .value_type = &value_ty } };
    const data = try ArrayData.initRetained(allocator, dict_ty, 3, 0, 0, &.{ null, index_values }, &.{}, dict);
    defer data.deinit();
    try data.validate();

    const missing = try ArrayData.initOwned(allocator, dict_ty, 3, 0, 0, &.{ null, index_values.retain() }, &.{}, null);
    defer missing.deinit();
    try std.testing.expectError(error.MissingDictionary, missing.validate());

    const bad_index_values = try Buffer.allocate(allocator, @sizeOf(i8));
    errdefer bad_index_values.deinit();
    writeTestInt(i8, bad_index_values, 0, 4);
    bad_index_values.freeze();
    defer bad_index_values.deinit();
    const bad_index = try ArrayData.initRetained(allocator, dict_ty, 1, 0, 0, &.{ null, bad_index_values }, &.{}, dict);
    defer bad_index.deinit();
    try std.testing.expectError(error.DictionaryIndexOutOfBounds, bad_index.validate());

    const empty = try ArrayData.initRetained(allocator, dict_ty, 0, 0, 0, &.{ null, null }, &.{}, dict);
    defer empty.deinit();
    try empty.validate();
}

test "validate dense union storage" {
    const ArrayData = testArrayData();
    const allocator = std.testing.allocator;

    const int_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer int_values.deinit();
    int_values.freeze();
    const int_child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, int_values }, &.{}, null);
    defer int_child.deinit();

    const bool_values = try Buffer.allocate(allocator, bitmap.byteLen(1));
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
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 0);
    writeTestInt(i32, offsets, 2, 1);
    offsets.freeze();
    defer offsets.deinit();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const int_field = try datatype.Field.create(allocator, "i", &int_ty, true, &.{});
    defer int_field.deinit();
    const bool_field = try datatype.Field.create(allocator, "b", &bool_ty, true, &.{});
    defer bool_field.deinit();
    const union_fields = [_]*const datatype.Field{ int_field, bool_field };
    const ids = [_]i8{ 7, 8 };
    const union_ty = datatype.DataType{ .dense_union = .{ .fields = &union_fields, .type_ids = &ids } };
    const data = try ArrayData.initRetained(allocator, union_ty, 3, 0, 0, &.{ type_ids, offsets }, &.{ int_child, bool_child }, null);
    defer data.deinit();
    try data.validate();

    const bad_offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer bad_offsets.deinit();
    writeTestInt(i32, bad_offsets, 0, 0);
    writeTestInt(i32, bad_offsets, 1, 1);
    writeTestInt(i32, bad_offsets, 2, 1);
    bad_offsets.freeze();
    defer bad_offsets.deinit();
    const invalid = try ArrayData.initRetained(allocator, union_ty, 3, 0, 0, &.{ type_ids, bad_offsets }, &.{ int_child, bool_child }, null);
    defer invalid.deinit();
    try std.testing.expectError(error.UnionOffsetOutOfBounds, invalid.validate());
}
