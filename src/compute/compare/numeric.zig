// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Numeric comparison kernels.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const builder = @import("../../builder.zig");
const common = @import("common.zig");
const ArrayData = common.ArrayData;
const Buffer = common.Buffer;
const Error = common.Error;
const Operation = common.Operation;

pub fn numeric(
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return fixedWidth(array.NumericArray(T), T, allocator, operation, left, right);
}

pub fn fixedWidth(
    comptime View: type,
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    if (!left.type.equals(right.type)) return error.TypeMismatch;

    const left_values = try View.fromData(left);
    const right_values = try View.fromData(right);
    if (canUseFixedWidthSimd(left, right)) {
        return fixedWidthSimd(T, allocator, operation, left, right);
    }

    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.reserve(left.len);
    for (0..left.len) |i| {
        if (left.isNull(i) or right.isNull(i)) {
            try out.appendNull();
        } else {
            try out.append(common.compareOrdered(operation, left_values.value(i), right_values.value(i)));
        }
    }
    return out.finish();
}

fn canUseFixedWidthSimd(left: *const ArrayData, right: *const ArrayData) bool {
    if (comptime builtin.cpu.arch.endian() != .little) return false;
    return left.buffers.len > 1 and left.buffers[1] != null and
        right.buffers.len > 1 and right.buffers[1] != null;
}

fn fixedWidthSimd(
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    writeNumericValuesSimd(T, values_buf.mutableSlice(), operation, left, right);
    return common.finishBooleanValues(allocator, left, right, values_buf);
}

fn writeNumericValuesSimd(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    const left_values = common.fixedWidthValueSlice(T, left);
    const right_values = common.fixedWidthValueSlice(T, right);

    const lanes = 8;
    var i: usize = 0;
    while (i + lanes <= left.len) : (i += lanes) {
        const left_vec: @Vector(lanes, T) = left_values[i..][0..lanes].*;
        const right_vec: @Vector(lanes, T) = right_values[i..][0..lanes].*;
        out[i / 8] = common.packBoolVector8(common.compareOrderedVector(T, lanes, operation, left_vec, right_vec));
    }

    if (i < left.len) {
        out[i / 8] = 0;
        while (i < left.len) : (i += 1) {
            bitmap.setBitTo(out, i, common.compareOrdered(operation, left_values[i], right_values[i]));
        }
    }
}

test "numeric comparison propagates nulls" {
    const allocator = std.testing.allocator;

    var left_builder = builder.NumericBuilder(i32).init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 1, 2 });
    try left_builder.appendNull();
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.NumericBuilder(i32).init(allocator);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 3, 0 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try numeric(i32, allocator, .less_equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(values.value(0));
    try std.testing.expect(values.value(1));
    try std.testing.expect(values.view.isNull(2));
}

test "numeric comparison handles all valid vector chunks and tail" {
    const allocator = std.testing.allocator;

    var left_builder = builder.NumericBuilder(i32).init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.NumericBuilder(i32).init(allocator);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 2, 3, 6, 7, 11, 12, 13, 17, 18 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try numeric(i32, allocator, .less_equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expectEqual(@as(usize, 0), result.nullCount());
    try std.testing.expectEqual(@as(?usize, 0), result.null_count);
    for ([_]bool{ true, true, false, true, false, true, true, false, true, true }, 0..) |expected, i| {
        try std.testing.expectEqual(expected, values.value(i));
    }

    const left_slice = try left.sliceChecked(1, 8);
    defer left_slice.deinit();
    const right_slice = try right.sliceChecked(1, 8);
    defer right_slice.deinit();
    const slice_result = try numeric(i32, allocator, .less_equal, left_slice, right_slice);
    defer slice_result.deinit();
    const slice_values = try array.BooleanArray.fromData(slice_result);
    for ([_]bool{ true, false, true, false, true, true, false, true }, 0..) |expected, i| {
        try std.testing.expectEqual(expected, slice_values.value(i));
    }
}
