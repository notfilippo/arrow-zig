// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Decimal comparison kernels.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const builder = @import("../../builder.zig");
const common = @import("common.zig");
const numeric_kernels = @import("numeric.zig");
const ArrayData = common.ArrayData;
const Buffer = common.Buffer;
const Error = common.Error;
const Operation = common.Operation;

pub fn decimal32(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return numeric_kernels.fixedWidth(array.Decimal32Array, i32, allocator, operation, left, right);
}

pub fn decimal64(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return numeric_kernels.fixedWidth(array.Decimal64Array, i64, allocator, operation, left, right);
}

pub fn decimal128(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return decimal(array.Decimal128Array, i128, allocator, operation, left, right);
}

pub fn decimal256(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return numeric_kernels.fixedWidth(array.Decimal256Array, i256, allocator, operation, left, right);
}

fn decimal(
    comptime View: type,
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    if (!left.type.equals(right.type)) return error.TypeMismatch;

    _ = try View.fromData(left);
    _ = try View.fromData(right);

    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();
    writeDecimalValues(T, values_buf.mutableSlice(), operation, left, right);
    return common.finishBooleanValues(allocator, left, right, values_buf);
}

fn writeDecimalValues(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        writeDecimalValuesNative(T, out, operation, left, right);
    } else {
        writeDecimalValuesEndian(T, out, operation, left, right);
    }
}

fn writeDecimalValuesNative(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    common.writeOrderedValuesScalar(
        T,
        out,
        operation,
        common.fixedWidthValueSlice(T, left),
        common.fixedWidthValueSlice(T, right),
    );
}

fn writeDecimalValuesEndian(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) void {
    const left_values = common.fixedWidthValueBytes(T, left);
    const right_values = common.fixedWidthValueBytes(T, right);

    var byte_i: usize = 0;
    var i: usize = 0;
    while (i + 8 <= left.len) : ({
        i += 8;
        byte_i += 1;
    }) {
        var byte: u8 = 0;
        inline for (0..8) |lane| {
            const start = (i + lane) * @sizeOf(T);
            const l = std.mem.readInt(T, left_values[start..][0..@sizeOf(T)], .little);
            const r = std.mem.readInt(T, right_values[start..][0..@sizeOf(T)], .little);
            if (common.compareOrdered(operation, l, r)) {
                byte |= @as(u8, 1) << lane;
            }
        }
        out[byte_i] = byte;
    }

    if (i < left.len) {
        var byte: u8 = 0;
        var lane: usize = 0;
        while (i < left.len) : ({
            i += 1;
            lane += 1;
        }) {
            const start = i * @sizeOf(T);
            const l = std.mem.readInt(T, left_values[start..][0..@sizeOf(T)], .little);
            const r = std.mem.readInt(T, right_values[start..][0..@sizeOf(T)], .little);
            if (common.compareOrdered(operation, l, r)) {
                byte |= @as(u8, 1) << @intCast(lane);
            }
        }
        out[byte_i] = byte;
    }
}

test "decimal comparison preserves metadata matching" {
    const allocator = std.testing.allocator;

    var left_builder = try builder.Decimal128Builder.init(allocator, 12, 2);
    defer left_builder.deinit();
    try left_builder.append(1234);
    try left_builder.appendNull();
    try left_builder.append(-20);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = try builder.Decimal128Builder.init(allocator, 12, 2);
    defer right_builder.deinit();
    try right_builder.append(1234);
    try right_builder.append(10);
    try right_builder.append(-30);
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try decimal128(allocator, .greater_equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(values.value(0));
    try std.testing.expect(values.view.isNull(1));
    try std.testing.expect(values.value(2));
}
