// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Binary and UTF8 comparison kernels.

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

pub fn binary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareVariableBytes(array.BinaryArray, i32, allocator, operation, left, right);
}

pub fn utf8(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareVariableBytes(array.Utf8Array, i32, allocator, operation, left, right);
}

pub fn largeBinary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareVariableBytes(array.LargeBinaryArray, i64, allocator, operation, left, right);
}

pub fn largeUtf8(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareVariableBytes(array.LargeUtf8Array, i64, allocator, operation, left, right);
}

pub fn binaryView(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.BinaryViewArray, allocator, operation, left, right);
}

pub fn utf8View(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.Utf8ViewArray, allocator, operation, left, right);
}

pub fn fixedSizeBinary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.FixedSizeBinaryArray, allocator, operation, left, right);
}

fn compareBytes(
    comptime View: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    const left_values = try View.fromData(left);
    const right_values = try View.fromData(right);

    return compareBytesViews(View, allocator, operation, left, right, left_values, right_values);
}

fn compareBytesViews(
    comptime View: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
    left_values: View,
    right_values: View,
) Error!*ArrayData {
    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.reserve(left.len);
    for (0..left.len) |i| {
        if (left.isNull(i) or right.isNull(i)) {
            try out.appendNull();
        } else {
            try out.append(compareByteSlices(operation, left_values.valueBytes(i), right_values.valueBytes(i)));
        }
    }
    return out.finish();
}

fn compareVariableBytes(
    comptime View: type,
    comptime Offset: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    const left_values = try View.fromData(left);
    const right_values = try View.fromData(right);
    if (canUseVariableBytesFastPath(left, right)) {
        return variableBytesFastPath(Offset, allocator, operation, left, right);
    }

    return compareBytesViews(View, allocator, operation, left, right, left_values, right_values);
}

fn canUseVariableBytesFastPath(left: *const ArrayData, right: *const ArrayData) bool {
    if (comptime builtin.cpu.arch.endian() != .little) return false;
    return left.buffers.len > 2 and left.buffers[1] != null and left.buffers[2] != null and
        right.buffers.len > 2 and right.buffers[1] != null and right.buffers[2] != null;
}

fn variableBytesFastPath(
    comptime Offset: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    writeVariableBytesValues(Offset, values_buf.mutableSlice(), operation, left, right);
    return common.finishBooleanValues(allocator, left, right, values_buf);
}

fn writeVariableBytesValues(
    comptime Offset: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    const left_offsets = offsetValueSlice(Offset, left);
    const right_offsets = offsetValueSlice(Offset, right);
    const left_values = left.buffers[2].?.dataSlice();
    const right_values = right.buffers[2].?.dataSlice();

    var i: usize = 0;
    while (i < left.len) {
        const byte_start = i;
        const byte_end = @min(i + 8, left.len);
        var byte: u8 = 0;
        while (i < byte_end) : (i += 1) {
            const bit: u3 = @intCast(i - byte_start);
            if (compareByteSlices(
                operation,
                variableBytesAt(Offset, left_offsets, left_values, left.offset + i),
                variableBytesAt(Offset, right_offsets, right_values, right.offset + i),
            )) byte |= @as(u8, 1) << bit;
        }
        out[byte_start / 8] = byte;
    }
}

fn offsetValueSlice(comptime Offset: type, data: *const ArrayData) []align(1) const Offset {
    return std.mem.bytesAsSlice(Offset, data.buffers[1].?.dataSlice());
}

fn variableBytesAt(
    comptime Offset: type,
    offsets: []align(1) const Offset,
    values: []const u8,
    slot: usize,
) []const u8 {
    const start: usize = @intCast(offsets[slot]);
    const end: usize = @intCast(offsets[slot + 1]);
    return values[start..][0 .. end - start];
}

fn compareByteSlices(operation: Operation, left: []const u8, right: []const u8) bool {
    return switch (operation) {
        .equal => std.mem.eql(u8, left, right),
        .not_equal => !std.mem.eql(u8, left, right),
        .less, .less_equal, .greater, .greater_equal => compareOrder(operation, std.mem.order(u8, left, right)),
    };
}

fn compareOrder(operation: Operation, order: std.math.Order) bool {
    return switch (operation) {
        .equal => order == .eq,
        .not_equal => order != .eq,
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
    };
}

test "utf8 comparison is lexicographic" {
    const allocator = std.testing.allocator;

    var left_builder = builder.Utf8Builder.init(allocator);
    defer left_builder.deinit();
    try left_builder.append("alpha");
    try left_builder.append("delta");
    try left_builder.appendNull();
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.Utf8Builder.init(allocator);
    defer right_builder.deinit();
    try right_builder.append("beta");
    try right_builder.append("delta");
    try right_builder.append("omega");
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try utf8(allocator, .less, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(values.value(0));
    try std.testing.expect(!values.value(1));
    try std.testing.expect(values.view.isNull(2));
}

test "utf8 comparison handles slices in variable width fast path" {
    const allocator = std.testing.allocator;

    var left_builder = builder.Utf8Builder.init(allocator);
    defer left_builder.deinit();
    try left_builder.append("zero");
    try left_builder.append("alpha");
    try left_builder.append("delta");
    try left_builder.append("omega");
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.Utf8Builder.init(allocator);
    defer right_builder.deinit();
    try right_builder.append("zero");
    try right_builder.append("beta");
    try right_builder.append("delta");
    try right_builder.append("zulu");
    const right = try right_builder.finish();
    defer right.deinit();

    const left_slice = try left.slice(1, 3);
    defer left_slice.deinit();
    const right_slice = try right.slice(1, 3);
    defer right_slice.deinit();

    const result = try utf8(allocator, .less_equal, left_slice, right_slice);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expectEqual(@as(usize, 0), result.nullCount());
    try std.testing.expect(values.value(0));
    try std.testing.expect(values.value(1));
    try std.testing.expect(values.value(2));
}
