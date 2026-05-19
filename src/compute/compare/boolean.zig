// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Boolean comparison kernels.

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
    if (canUseBooleanBitmapFastPath(left, right)) {
        return booleanBitmapFastPath(allocator, operation, left, right);
    }

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

fn canUseBooleanBitmapFastPath(left: *const ArrayData, right: *const ArrayData) bool {
    return left.buffers.len > 1 and left.buffers[1] != null and
        right.buffers.len > 1 and right.buffers[1] != null;
}

fn booleanBitmapFastPath(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    const values_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer values_buf.deinit();

    const out = values_buf.mutableSlice();
    bitmap.xorBits(
        out,
        0,
        left.buffers[1].?.dataSlice(),
        left.offset,
        right.buffers[1].?.dataSlice(),
        right.offset,
        left.len,
    );
    if (operation == .equal) bitmap.invertBits(out, 0, left.len);
    return common.finishBooleanValues(allocator, left, right, values_buf);
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

test "boolean comparison propagates nulls with bitmap fast path" {
    const allocator = std.testing.allocator;

    var left_builder = builder.BooleanBuilder.init(allocator);
    defer left_builder.deinit();
    try left_builder.append(true);
    try left_builder.appendNull();
    try left_builder.append(false);
    try left_builder.append(true);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = builder.BooleanBuilder.init(allocator);
    defer right_builder.deinit();
    try right_builder.append(false);
    try right_builder.append(true);
    try right_builder.append(false);
    try right_builder.appendNull();
    const right = try right_builder.finish();
    defer right.deinit();

    const result = try boolean(allocator, .equal, left, right);
    defer result.deinit();
    const values = try array.BooleanArray.fromData(result);

    try std.testing.expectEqual(@as(usize, 2), result.nullCount());
    try std.testing.expect(!values.value(0));
    try std.testing.expect(values.view.isNull(1));
    try std.testing.expect(values.value(2));
    try std.testing.expect(values.view.isNull(3));
}
