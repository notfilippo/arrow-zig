// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Element-wise comparison kernels.
//!
//! Kernels return a nullable Boolean array. A result slot is null when either
//! input slot is null.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../array.zig");
const builder = @import("../builder.zig");
const common = @import("compare/common.zig");
const numeric_kernels = @import("compare/numeric.zig");
const boolean_kernels = @import("compare/boolean.zig");
const binary_kernels = @import("compare/binary.zig");
const ArrayData = array.ArrayData;

pub const Operation = common.Operation;
pub const Error = common.Error;

pub fn compare(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (!left.type.equals(right.type)) return error.TypeMismatch;
    return switch (left.type.id()) {
        .bool => boolean_kernels.boolean(allocator, operation, left, right),
        .int8 => numeric_kernels.numeric(i8, allocator, operation, left, right),
        .int16 => numeric_kernels.numeric(i16, allocator, operation, left, right),
        .int32 => numeric_kernels.numeric(i32, allocator, operation, left, right),
        .int64 => numeric_kernels.numeric(i64, allocator, operation, left, right),
        .uint8 => numeric_kernels.numeric(u8, allocator, operation, left, right),
        .uint16 => numeric_kernels.numeric(u16, allocator, operation, left, right),
        .uint32 => numeric_kernels.numeric(u32, allocator, operation, left, right),
        .uint64 => numeric_kernels.numeric(u64, allocator, operation, left, right),
        .float16 => numeric_kernels.numeric(f16, allocator, operation, left, right),
        .float32 => numeric_kernels.numeric(f32, allocator, operation, left, right),
        .float64 => numeric_kernels.numeric(f64, allocator, operation, left, right),
        .date32 => numeric_kernels.fixedWidth(array.Date32Array, i32, allocator, operation, left, right),
        .date64 => numeric_kernels.fixedWidth(array.Date64Array, i64, allocator, operation, left, right),
        .time32 => numeric_kernels.fixedWidth(array.Time32Array, i32, allocator, operation, left, right),
        .time64 => numeric_kernels.fixedWidth(array.Time64Array, i64, allocator, operation, left, right),
        .timestamp => numeric_kernels.fixedWidth(array.TimestampArray, i64, allocator, operation, left, right),
        .duration => numeric_kernels.fixedWidth(array.DurationArray, i64, allocator, operation, left, right),
        .binary => binary_kernels.binary(allocator, operation, left, right),
        .utf8 => binary_kernels.utf8(allocator, operation, left, right),
        .large_binary => binary_kernels.largeBinary(allocator, operation, left, right),
        .large_utf8 => binary_kernels.largeUtf8(allocator, operation, left, right),
        .binary_view => binary_kernels.binaryView(allocator, operation, left, right),
        .utf8_view => binary_kernels.utf8View(allocator, operation, left, right),
        .fixed_size_binary => binary_kernels.fixedSizeBinary(allocator, operation, left, right),
        else => error.UnsupportedOperation,
    };
}

pub fn equal(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .equal, left, right);
}

pub fn notEqual(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .not_equal, left, right);
}

pub fn less(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .less, left, right);
}

pub fn lessEqual(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .less_equal, left, right);
}

pub fn greater(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .greater, left, right);
}

pub fn greaterEqual(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compare(allocator, .greater_equal, left, right);
}

test "comparison rejects mismatched inputs" {
    const allocator = std.testing.allocator;

    var left_builder = builder.NumericBuilder(i32).init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 1, 2 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.NumericBuilder(i32).init(allocator);
    defer right_builder.deinit();
    try right_builder.append(1);
    const right = try right_builder.finish();
    defer right.deinit();

    var other_type_builder = builder.NumericBuilder(i64).init(allocator);
    defer other_type_builder.deinit();
    try other_type_builder.appendSlice(&.{ 1, 2 });
    const other_type = try other_type_builder.finish();
    defer other_type.deinit();

    try std.testing.expectError(error.LengthMismatch, equal(allocator, left, right));
    try std.testing.expectError(error.TypeMismatch, equal(allocator, left, other_type));
}

test "comparison supports temporal physical values" {
    const allocator = std.testing.allocator;

    var left_builder = try builder.NumericBuilder(i32).initType(allocator, .date32);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 1, 2 });
    try left_builder.appendNull();
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = try builder.NumericBuilder(i32).initType(allocator, .date32);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 3, 0 });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try lessEqual(allocator, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(values.value(0));
    try std.testing.expect(values.value(1));
    try std.testing.expect(values.view.isNull(2));
}

test "comparison rejects mismatched temporal metadata" {
    const allocator = std.testing.allocator;

    var left_builder = try builder.NumericBuilder(i64).initType(allocator, .{ .timestamp = .{ .unit = .microsecond, .tz = "UTC" } });
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ 1, 2 });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = try builder.NumericBuilder(i64).initType(allocator, .{ .timestamp = .{ .unit = .nanosecond, .tz = "UTC" } });
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ 1, 2 });
    const right = try right_builder.finish();
    defer right.deinit();

    try std.testing.expectError(error.TypeMismatch, equal(allocator, left, right));
}

test "comparison rejects mismatched fixed size binary metadata" {
    const allocator = std.testing.allocator;

    var left_builder = builder.FixedSizeBinaryBuilder.init(allocator, 2);
    defer left_builder.deinit();
    try left_builder.append("ab");
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.FixedSizeBinaryBuilder.init(allocator, 3);
    defer right_builder.deinit();
    try right_builder.append("abc");
    const right = try right_builder.finish();
    defer right.deinit();

    try std.testing.expectError(error.TypeMismatch, equal(allocator, left, right));
}
