// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Dictionary comparison kernels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const buffer = @import("../../buffer.zig");
const builder = @import("../../builder.zig");
const datatype = @import("../../datatype.zig");
const offsets = @import("../../offsets.zig");
const common = @import("common.zig");
const ArrayData = common.ArrayData;
const Buffer = buffer.Buffer;
const Error = common.Error;
const Operation = common.Operation;

pub fn dictionary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    if (!valueTypesEqual(left.type, right.type)) return error.TypeMismatch;
    if (left.type.id() != .dictionary and right.type.id() != .dictionary) return error.TypeMismatch;
    if (left.type.id() == .dictionary and left.dictionary == null) return error.InvalidBufferLayout;
    if (right.type.id() == .dictionary and right.dictionary == null) return error.InvalidBufferLayout;

    return switch (left.type) {
        .dictionary => |meta| switch (meta.index_type.id()) {
            .int8 => dictionaryWithLeftIndex(i8, allocator, operation, left, right),
            .int16 => dictionaryWithLeftIndex(i16, allocator, operation, left, right),
            .int32 => dictionaryWithLeftIndex(i32, allocator, operation, left, right),
            .int64 => dictionaryWithLeftIndex(i64, allocator, operation, left, right),
            .uint8 => dictionaryWithLeftIndex(u8, allocator, operation, left, right),
            .uint16 => dictionaryWithLeftIndex(u16, allocator, operation, left, right),
            .uint32 => dictionaryWithLeftIndex(u32, allocator, operation, left, right),
            .uint64 => dictionaryWithLeftIndex(u64, allocator, operation, left, right),
            else => error.TypeMismatch,
        },
        else => dictionaryWithLeftIndex(null, allocator, operation, left, right),
    };
}

fn valueTypesEqual(left: datatype.DataType, right: datatype.DataType) bool {
    return switch (left) {
        .dictionary => |left_meta| switch (right) {
            .dictionary => |right_meta| left_meta.value_type.equals(right_meta.value_type.*),
            else => left_meta.value_type.equals(right),
        },
        else => switch (right) {
            .dictionary => |right_meta| left.equals(right_meta.value_type.*),
            else => left.equals(right),
        },
    };
}

fn dictionaryWithLeftIndex(
    comptime LeftIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return switch (right.type) {
        .dictionary => |meta| switch (meta.index_type.id()) {
            .int8 => dictionaryWithIndices(LeftIndex, i8, allocator, operation, left, right),
            .int16 => dictionaryWithIndices(LeftIndex, i16, allocator, operation, left, right),
            .int32 => dictionaryWithIndices(LeftIndex, i32, allocator, operation, left, right),
            .int64 => dictionaryWithIndices(LeftIndex, i64, allocator, operation, left, right),
            .uint8 => dictionaryWithIndices(LeftIndex, u8, allocator, operation, left, right),
            .uint16 => dictionaryWithIndices(LeftIndex, u16, allocator, operation, left, right),
            .uint32 => dictionaryWithIndices(LeftIndex, u32, allocator, operation, left, right),
            .uint64 => dictionaryWithIndices(LeftIndex, u64, allocator, operation, left, right),
            else => error.TypeMismatch,
        },
        else => dictionaryWithIndices(LeftIndex, null, allocator, operation, left, right),
    };
}

fn dictionaryWithIndices(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (LeftIndex != null and (left.buffers.len < 2 or left.buffers[1] == null)) return error.InvalidBufferLayout;
    if (RightIndex != null and (right.buffers.len < 2 or right.buffers[1] == null)) return error.InvalidBufferLayout;

    const left_values = valueData(LeftIndex, left);
    const right_values = valueData(RightIndex, right);
    if (!left_values.type.equals(right_values.type)) return error.TypeMismatch;

    return switch (left_values.type.id()) {
        .bool => dictionaryBool(LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .int8 => dictionaryFixedWidth(LeftIndex, RightIndex, i8, allocator, operation, left, right, left_values, right_values),
        .int16 => dictionaryFixedWidth(LeftIndex, RightIndex, i16, allocator, operation, left, right, left_values, right_values),
        .int32 => dictionaryFixedWidth(LeftIndex, RightIndex, i32, allocator, operation, left, right, left_values, right_values),
        .int64 => dictionaryFixedWidth(LeftIndex, RightIndex, i64, allocator, operation, left, right, left_values, right_values),
        .uint8 => dictionaryFixedWidth(LeftIndex, RightIndex, u8, allocator, operation, left, right, left_values, right_values),
        .uint16 => dictionaryFixedWidth(LeftIndex, RightIndex, u16, allocator, operation, left, right, left_values, right_values),
        .uint32 => dictionaryFixedWidth(LeftIndex, RightIndex, u32, allocator, operation, left, right, left_values, right_values),
        .uint64 => dictionaryFixedWidth(LeftIndex, RightIndex, u64, allocator, operation, left, right, left_values, right_values),
        .float16 => dictionaryFixedWidth(LeftIndex, RightIndex, f16, allocator, operation, left, right, left_values, right_values),
        .float32 => dictionaryFixedWidth(LeftIndex, RightIndex, f32, allocator, operation, left, right, left_values, right_values),
        .float64 => dictionaryFixedWidth(LeftIndex, RightIndex, f64, allocator, operation, left, right, left_values, right_values),
        .date32, .time32, .decimal32 => dictionaryFixedWidth(LeftIndex, RightIndex, i32, allocator, operation, left, right, left_values, right_values),
        .date64, .time64, .timestamp, .duration, .decimal64 => dictionaryFixedWidth(LeftIndex, RightIndex, i64, allocator, operation, left, right, left_values, right_values),
        .decimal128 => dictionaryFixedWidth(LeftIndex, RightIndex, i128, allocator, operation, left, right, left_values, right_values),
        .decimal256 => dictionaryFixedWidth(LeftIndex, RightIndex, i256, allocator, operation, left, right, left_values, right_values),
        .binary => dictionaryBytes(array.BinaryArray, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .utf8 => dictionaryBytes(array.Utf8Array, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .large_binary => dictionaryBytes(array.LargeBinaryArray, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .large_utf8 => dictionaryBytes(array.LargeUtf8Array, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .binary_view => dictionaryBytes(array.BinaryViewArray, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .utf8_view => dictionaryBytes(array.Utf8ViewArray, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .fixed_size_binary => dictionaryBytes(array.FixedSizeBinaryArray, LeftIndex, RightIndex, allocator, operation, left, right, left_values, right_values),
        .month_interval => dictionaryFixedBytes(LeftIndex, RightIndex, 4, allocator, operation, left, right, left_values, right_values),
        .day_time_interval => dictionaryFixedBytes(LeftIndex, RightIndex, 8, allocator, operation, left, right, left_values, right_values),
        .month_day_nano_interval => dictionaryFixedBytes(LeftIndex, RightIndex, 16, allocator, operation, left, right, left_values, right_values),
        else => error.UnsupportedOperation,
    };
}

fn dictionaryBool(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    left_values: *const ArrayData,
    right_values: *const ArrayData,
) Error!*ArrayData {
    switch (operation) {
        .equal, .not_equal => {},
        else => return error.UnsupportedOperation,
    }

    const context = .{ .left = left_values, .right = right_values };
    return dictionaryRows(LeftIndex, RightIndex, allocator, operation, left, right, context, compareBool);
}

fn dictionaryFixedWidth(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    left_values: *const ArrayData,
    right_values: *const ArrayData,
) Error!*ArrayData {
    const context = .{ .left = left_values, .right = right_values };
    return dictionaryRows(LeftIndex, RightIndex, allocator, operation, left, right, context, compareFixedWidth(T));
}

fn dictionaryBytes(
    comptime View: type,
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    left_values: *const ArrayData,
    right_values: *const ArrayData,
) Error!*ArrayData {
    const context = .{
        .left = left_values,
        .right = right_values,
        .left_view = try View.fromData(left_values),
        .right_view = try View.fromData(right_values),
    };
    return dictionaryRows(LeftIndex, RightIndex, allocator, operation, left, right, context, compareBytes);
}

fn dictionaryFixedBytes(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    comptime width: usize,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    left_values: *const ArrayData,
    right_values: *const ArrayData,
) Error!*ArrayData {
    switch (operation) {
        .equal, .not_equal => {},
        else => return error.UnsupportedOperation,
    }

    const context = .{ .left = left_values, .right = right_values };
    return dictionaryRows(LeftIndex, RightIndex, allocator, operation, left, right, context, compareFixedBytes(width));
}

fn dictionaryRows(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    context: anytype,
    comptime compare: anytype,
) Error!*ArrayData {
    if (!left.mayHaveLogicalNulls() and !right.mayHaveLogicalNulls()) {
        return dictionaryRowsNoNulls(LeftIndex, RightIndex, allocator, operation, left, right, context, compare);
    }

    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    const values_out = values_buf.mutableSlice();
    @memset(values_out, 0);

    const validity_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer validity_buf.deinit();
    const validity_out = validity_buf.mutableSlice();
    @memset(validity_out, 0);

    var null_count: usize = 0;
    for (0..left.len) |i| {
        const left_index = resolveValidValueIndex(LeftIndex, left, context.left, i) orelse {
            null_count += 1;
            continue;
        };
        const right_index = resolveValidValueIndex(RightIndex, right, context.right, i) orelse {
            null_count += 1;
            continue;
        };

        bitmap.setBit(validity_out, i);
        if (try compare(operation, context, left_index, right_index)) bitmap.setBit(values_out, i);
    }

    values_buf.freeze();
    validity_buf.freeze();

    return ArrayData.initOwned(
        allocator,
        .bool,
        left.len,
        0,
        null_count,
        &.{ validity_buf, values_buf },
        &.{},
        null,
    );
}

fn dictionaryRowsNoNulls(
    comptime LeftIndex: ?type,
    comptime RightIndex: ?type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    context: anytype,
    comptime compare: anytype,
) Error!*ArrayData {
    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    const values_out = values_buf.mutableSlice();
    @memset(values_out, 0);

    for (0..left.len) |i| {
        const left_index = valueIndexUnchecked(LeftIndex, left, i);
        const right_index = valueIndexUnchecked(RightIndex, right, i);
        if (try compare(operation, context, left_index, right_index)) bitmap.setBit(values_out, i);
    }
    values_buf.freeze();

    return ArrayData.initOwned(
        allocator,
        .bool,
        left.len,
        0,
        0,
        &.{ null, values_buf },
        &.{},
        null,
    );
}

fn CompareFixedWidth(comptime T: type) type {
    return struct {
        fn compare(operation: Operation, context: anytype, left_index: usize, right_index: usize) Error!bool {
            return common.compareOrdered(
                operation,
                fixedWidthAt(T, context.left, left_index),
                fixedWidthAt(T, context.right, right_index),
            );
        }
    };
}

fn compareFixedWidth(comptime T: type) fn (Operation, anytype, usize, usize) Error!bool {
    return CompareFixedWidth(T).compare;
}

fn CompareFixedBytes(comptime width: usize) type {
    return struct {
        fn compare(operation: Operation, context: anytype, left_index: usize, right_index: usize) Error!bool {
            const equal = std.mem.eql(
                u8,
                fixedBytes(width, context.left, left_index),
                fixedBytes(width, context.right, right_index),
            );
            return if (operation == .equal) equal else !equal;
        }
    };
}

fn compareFixedBytes(comptime width: usize) fn (Operation, anytype, usize, usize) Error!bool {
    return CompareFixedBytes(width).compare;
}

fn compareBool(operation: Operation, context: anytype, left_index: usize, right_index: usize) Error!bool {
    const equal = boolAt(context.left, left_index) == boolAt(context.right, right_index);
    return if (operation == .equal) equal else !equal;
}

fn compareBytes(operation: Operation, context: anytype, left_index: usize, right_index: usize) Error!bool {
    return common.compareByteSlices(
        operation,
        context.left_view.valueBytes(left_index),
        context.right_view.valueBytes(right_index),
    );
}

fn valueData(comptime Index: ?type, data: *const ArrayData) *const ArrayData {
    if (comptime Index != null) return data.dictionary.?;
    return data;
}

fn resolveValidValueIndex(
    comptime Index: ?type,
    data: *const ArrayData,
    values: *const ArrayData,
    slot: usize,
) ?usize {
    if (comptime Index) |T| {
        if (slotIsNull(data, slot)) return null;
        const value_index = indexAsUsize(indexAt(T, data, slot));
        if (slotIsNull(values, value_index)) return null;
        return value_index;
    }

    if (slotIsNull(data, slot)) return null;
    return slot;
}

fn valueIndexUnchecked(comptime Index: ?type, data: *const ArrayData, slot: usize) usize {
    if (comptime Index) |T| return indexAsUsize(indexAt(T, data, slot));
    return slot;
}

fn slotIsNull(data: *const ArrayData, slot: usize) bool {
    if (data.type.id() == .null_) return true;
    const validity = if (data.buffers.len > 0) data.buffers[0] else null;
    const bits = validity orelse return false;
    return !bitmap.getBit(bits.dataSlice(), data.offset + slot);
}

fn indexAt(comptime Index: type, data: *const ArrayData, index: usize) Index {
    return offsets.read(Index, data.buffers[1].?, data.offset + index);
}

fn indexAsUsize(index: anytype) usize {
    const T = @TypeOf(index);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed and index < 0) unreachable;
    return @intCast(index);
}

fn boolAt(data: *const ArrayData, index: usize) bool {
    return bitmap.getBit(data.buffers[1].?.dataSlice(), data.offset + index);
}

fn fixedWidthAt(comptime T: type, data: *const ArrayData, index: usize) T {
    const values = data.buffers[1].?;
    const slot = data.offset + index;
    if (comptime @typeInfo(T) == .int) return offsets.read(T, values, slot);

    const start = slot * @sizeOf(T);
    const raw = values.dataSlice()[start..][0..@sizeOf(T)];
    return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), raw, .little));
}

fn fixedBytes(comptime width: usize, data: *const ArrayData, index: usize) []const u8 {
    const start = (data.offset + index) * width;
    return data.buffers[1].?.dataSlice()[start..][0..width];
}

test "dictionary comparison uses decoded values" {
    const allocator = std.testing.allocator;

    var left_values_builder = builder.Utf8Builder.init(allocator);
    defer left_values_builder.deinit();
    try left_values_builder.append("b");
    try left_values_builder.append("a");
    try left_values_builder.appendNull();
    const left_values = try left_values_builder.finish();
    defer left_values.deinit();

    var right_values_builder = builder.Utf8Builder.init(allocator);
    defer right_values_builder.deinit();
    try right_values_builder.append("a");
    try right_values_builder.append("b");
    try right_values_builder.append("z");
    const right_values = try right_values_builder.finish();
    defer right_values.deinit();

    var left_builder = builder.DictionaryBuilder(i8).init(allocator, left_values);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 0, 1, 2 });
    try left_builder.appendNull();
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.DictionaryBuilder(i8).init(allocator, right_values);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 0, 2, 1 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try dictionary(allocator, .equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(values.value(0));
    try std.testing.expect(values.value(1));
    try std.testing.expect(values.view.isNull(2));
    try std.testing.expect(values.view.isNull(3));
}

test "dictionary comparison ignores index width and ordered metadata" {
    const allocator = std.testing.allocator;

    var values_builder = builder.Utf8Builder.init(allocator);
    defer values_builder.deinit();
    try values_builder.append("a");
    try values_builder.append("b");
    const values_data = try values_builder.finish();
    defer values_data.deinit();

    var left_builder = builder.DictionaryBuilder(i8).init(allocator, values_data);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 0, 1 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.DictionaryBuilder(i16).initOptions(allocator, values_data, .{ .ordered = true });
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 0, 1 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try dictionary(allocator, .equal, left, right);
    defer result.deinit();
    const bools = try array.BooleanArray.fromData(result);

    try std.testing.expect(bools.value(0));
    try std.testing.expect(bools.value(1));
}

test "dictionary comparison orders decoded numeric values" {
    const allocator = std.testing.allocator;

    var left_values_builder = builder.NumericBuilder(i32).init(allocator);
    defer left_values_builder.deinit();
    try left_values_builder.appendSlice(&.{ 20, 10 });
    const left_values = try left_values_builder.finish();
    defer left_values.deinit();

    var right_values_builder = builder.NumericBuilder(i32).init(allocator);
    defer right_values_builder.deinit();
    try right_values_builder.appendSlice(&.{ 10, 20 });
    const right_values = try right_values_builder.finish();
    defer right_values.deinit();

    var left_builder = builder.DictionaryBuilder(i8).init(allocator, left_values);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 0, 1 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.DictionaryBuilder(i8).init(allocator, right_values);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 1 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try dictionary(allocator, .less, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(!values.value(0));
    try std.testing.expect(values.value(1));
}
