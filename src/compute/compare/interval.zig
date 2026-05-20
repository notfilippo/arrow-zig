// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Interval comparison kernels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const builder = @import("../../builder.zig");
const common = @import("common.zig");
const ArrayData = common.ArrayData;
const Buffer = common.Buffer;
const Error = common.Error;
const Operation = common.Operation;

pub fn monthInterval(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return interval(array.MonthIntervalArray, u32, allocator, operation, left, right);
}

pub fn dayTimeInterval(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return interval(array.DayTimeIntervalArray, u64, allocator, operation, left, right);
}

pub fn monthDayNanoInterval(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return interval(array.MonthDayNanoIntervalArray, u128, allocator, operation, left, right);
}

fn interval(
    comptime View: type,
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    switch (operation) {
        .equal, .not_equal => {},
        else => return error.UnsupportedOperation,
    }
    if (left.len != right.len) return error.LengthMismatch;
    if (!left.type.equals(right.type)) return error.TypeMismatch;

    _ = try View.fromData(left);
    _ = try View.fromData(right);

    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    writeIntervalValues(T, values_buf.mutableSlice(), operation, left, right);
    return common.finishBooleanValues(allocator, left, right, values_buf);
}

fn writeIntervalValues(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    const left_values = common.fixedWidthValueSlice(T, left);
    const right_values = common.fixedWidthValueSlice(T, right);
    const want_equal = operation == .equal;

    var byte_i: usize = 0;
    var i: usize = 0;
    while (i + 8 <= left.len) : ({
        i += 8;
        byte_i += 1;
    }) {
        const left_vec: @Vector(8, T) = left_values[i..][0..8].*;
        const right_vec: @Vector(8, T) = right_values[i..][0..8].*;
        const matches = if (want_equal) left_vec == right_vec else left_vec != right_vec;
        out[byte_i] = common.packBoolVector8(matches);
    }

    if (i < left.len) {
        var byte: u8 = 0;
        var lane: usize = 0;
        while (i < left.len) : ({
            i += 1;
            lane += 1;
        }) {
            if ((left_values[i] == right_values[i]) == want_equal) {
                byte |= @as(u8, 1) << @intCast(lane);
            }
        }
        out[byte_i] = byte;
    }
}

test "interval comparison supports equality only" {
    const allocator = std.testing.allocator;

    var left_builder = builder.DayTimeIntervalBuilder.init(allocator);
    defer left_builder.deinit();
    try left_builder.append(.{ .days = 2, .milliseconds = 100 });
    try left_builder.appendNull();
    try left_builder.append(.{ .days = 3, .milliseconds = 0 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.DayTimeIntervalBuilder.init(allocator);
    defer right_builder.deinit();
    try right_builder.append(.{ .days = 2, .milliseconds = 100 });
    try right_builder.append(.{ .days = 2, .milliseconds = 100 });
    try right_builder.append(.{ .days = 4, .milliseconds = 0 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try dayTimeInterval(allocator, .not_equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(!values.value(0));
    try std.testing.expect(values.view.isNull(1));
    try std.testing.expect(values.value(2));
    try std.testing.expectError(error.UnsupportedOperation, dayTimeInterval(allocator, .less, left, right));
}
