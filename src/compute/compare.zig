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
const array_common = @import("../array/common.zig");
const ArrayData = array.ArrayData;

pub const Operation = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const Error = builder.BooleanBuilder.Error || array_common.ViewError || error{
    LengthMismatch,
    UnsupportedOperation,
};

pub fn numeric(
    comptime T: type,
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (left.len != right.len) return error.LengthMismatch;
    const left_values = try array.NumericArray(T).fromData(left);
    const right_values = try array.NumericArray(T).fromData(right);

    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.reserve(left.len);
    for (0..left.len) |i| {
        if (left.isNull(i) or right.isNull(i)) {
            try out.appendNull();
        } else {
            try out.append(compareOrdered(operation, left_values.value(i), right_values.value(i)));
        }
    }
    return out.finish();
}

pub fn boolean(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    if (operation != .equal and operation != .not_equal) return error.UnsupportedOperation;
    if (left.len != right.len) return error.LengthMismatch;
    const left_values = try array.BooleanArray.fromData(left);
    const right_values = try array.BooleanArray.fromData(right);

    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.reserve(left.len);
    for (0..left.len) |i| {
        if (left.isNull(i) or right.isNull(i)) {
            try out.appendNull();
        } else {
            const equal = left_values.value(i) == right_values.value(i);
            try out.append(if (operation == .equal) equal else !equal);
        }
    }
    return out.finish();
}

pub fn binary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.BinaryArray, allocator, operation, left, right);
}

pub fn utf8(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.Utf8Array, allocator, operation, left, right);
}

pub fn largeBinary(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.LargeBinaryArray, allocator, operation, left, right);
}

pub fn largeUtf8(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    return compareBytes(array.LargeUtf8Array, allocator, operation, left, right);
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

    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.reserve(left.len);
    for (0..left.len) |i| {
        if (left.isNull(i) or right.isNull(i)) {
            try out.appendNull();
        } else {
            const order = std.mem.order(u8, left_values.valueBytes(i), right_values.valueBytes(i));
            try out.append(compareOrder(operation, order));
        }
    }
    return out.finish();
}

fn compareOrdered(operation: Operation, left: anytype, right: @TypeOf(left)) bool {
    return switch (operation) {
        .equal => left == right,
        .not_equal => left != right,
        .less => left < right,
        .less_equal => left <= right,
        .greater => left > right,
        .greater_equal => left >= right,
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

test "boolean comparison supports equality" {
    const allocator = std.testing.allocator;

    var left_builder = builder.BooleanBuilder.init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(&.{ true, false });
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.BooleanBuilder.init(allocator);
    defer right_builder.deinit();
    try right_builder.appendSlice(&.{ true, true });
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try boolean(allocator, .not_equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expect(!values.value(0));
    try std.testing.expect(values.value(1));
    try std.testing.expectError(error.UnsupportedOperation, boolean(allocator, .less, left, right));
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

    try std.testing.expectError(error.LengthMismatch, numeric(i32, allocator, .equal, left, right));
    try std.testing.expectError(error.TypeMismatch, numeric(i64, allocator, .equal, left, left));
}
