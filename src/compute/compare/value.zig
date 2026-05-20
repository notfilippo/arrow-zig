// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Per-slot value comparison helpers.

const std = @import("std");
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const offsets = @import("../../offsets.zig");
const common = @import("common.zig");
const ArrayData = common.ArrayData;
const Error = common.Error;
const Operation = common.Operation;

pub fn compareSlots(
    operation: Operation,
    left: *const ArrayData,
    left_index: usize,
    right: *const ArrayData,
    right_index: usize,
) Error!bool {
    if (!left.type.equals(right.type)) return error.TypeMismatch;
    return switch (left.type.id()) {
        .bool => boolSlots(operation, left, left_index, right, right_index),
        .int8 => fixedWidth(i8, operation, left, left_index, right, right_index),
        .int16 => fixedWidth(i16, operation, left, left_index, right, right_index),
        .int32 => fixedWidth(i32, operation, left, left_index, right, right_index),
        .int64 => fixedWidth(i64, operation, left, left_index, right, right_index),
        .uint8 => fixedWidth(u8, operation, left, left_index, right, right_index),
        .uint16 => fixedWidth(u16, operation, left, left_index, right, right_index),
        .uint32 => fixedWidth(u32, operation, left, left_index, right, right_index),
        .uint64 => fixedWidth(u64, operation, left, left_index, right, right_index),
        .float16 => fixedWidth(f16, operation, left, left_index, right, right_index),
        .float32 => fixedWidth(f32, operation, left, left_index, right, right_index),
        .float64 => fixedWidth(f64, operation, left, left_index, right, right_index),
        .date32, .time32 => fixedWidth(i32, operation, left, left_index, right, right_index),
        .date64, .time64, .timestamp, .duration => fixedWidth(i64, operation, left, left_index, right, right_index),
        .decimal32 => fixedWidth(i32, operation, left, left_index, right, right_index),
        .decimal64 => fixedWidth(i64, operation, left, left_index, right, right_index),
        .decimal128 => fixedWidth(i128, operation, left, left_index, right, right_index),
        .decimal256 => fixedWidth(i256, operation, left, left_index, right, right_index),
        .binary => bytes(array.BinaryArray, operation, left, left_index, right, right_index),
        .utf8 => bytes(array.Utf8Array, operation, left, left_index, right, right_index),
        .large_binary => bytes(array.LargeBinaryArray, operation, left, left_index, right, right_index),
        .large_utf8 => bytes(array.LargeUtf8Array, operation, left, left_index, right, right_index),
        .binary_view => bytes(array.BinaryViewArray, operation, left, left_index, right, right_index),
        .utf8_view => bytes(array.Utf8ViewArray, operation, left, left_index, right, right_index),
        .fixed_size_binary => bytes(array.FixedSizeBinaryArray, operation, left, left_index, right, right_index),
        .month_interval => intervalBytes(4, operation, left, left_index, right, right_index),
        .day_time_interval => intervalBytes(8, operation, left, left_index, right, right_index),
        .month_day_nano_interval => intervalBytes(16, operation, left, left_index, right, right_index),
        else => error.UnsupportedOperation,
    };
}

fn boolAt(data: *const ArrayData, index: usize) bool {
    return bitmap.getBit(data.buffers[1].?.dataSlice(), data.offset + index);
}

fn fixedWidth(
    comptime T: type,
    operation: Operation,
    left: *const ArrayData,
    left_index: usize,
    right: *const ArrayData,
    right_index: usize,
) bool {
    return common.compareOrdered(
        operation,
        fixedWidthAt(T, left, left_index),
        fixedWidthAt(T, right, right_index),
    );
}

fn fixedWidthAt(comptime T: type, data: *const ArrayData, index: usize) T {
    const values = data.buffers[1].?;
    const slot = data.offset + index;
    if (comptime @typeInfo(T) == .int) return offsets.read(T, values, slot);

    const start = slot * @sizeOf(T);
    const raw = values.dataSlice()[start..][0..@sizeOf(T)];
    return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), raw, .little));
}

fn boolSlots(
    operation: Operation,
    left: *const ArrayData,
    left_index: usize,
    right: *const ArrayData,
    right_index: usize,
) Error!bool {
    const equal = boolAt(left, left_index) == boolAt(right, right_index);
    return switch (operation) {
        .equal => equal,
        .not_equal => !equal,
        else => error.UnsupportedOperation,
    };
}

fn bytes(
    comptime View: type,
    operation: Operation,
    left: *const ArrayData,
    left_index: usize,
    right: *const ArrayData,
    right_index: usize,
) Error!bool {
    const left_values = try View.fromData(left);
    const right_values = try View.fromData(right);
    return common.compareByteSlices(operation, left_values.valueBytes(left_index), right_values.valueBytes(right_index));
}

fn intervalBytes(
    comptime width: usize,
    operation: Operation,
    left: *const ArrayData,
    left_index: usize,
    right: *const ArrayData,
    right_index: usize,
) Error!bool {
    switch (operation) {
        .equal, .not_equal => {},
        else => return error.UnsupportedOperation,
    }

    const equal = std.mem.eql(
        u8,
        fixedBytes(width, left, left_index),
        fixedBytes(width, right, right_index),
    );
    return if (operation == .equal) equal else !equal;
}

fn fixedBytes(comptime width: usize, data: *const ArrayData, index: usize) []const u8 {
    const start = (data.offset + index) * width;
    return data.buffers[1].?.dataSlice()[start..][0..width];
}
