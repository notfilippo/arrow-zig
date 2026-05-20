// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Shared helpers for comparison kernels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../../array.zig");
const bitmap = @import("../../bitmap.zig");
const buffer = @import("../../buffer.zig");
const builder = @import("../../builder.zig");
const array_common = @import("../../array/common.zig");

pub const ArrayData = array.ArrayData;
pub const Buffer = buffer.Buffer;

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

const ValidityResult = struct {
    buffer: ?*Buffer,
    null_count: ?usize,
};

pub fn finishBooleanValues(
    allocator: Allocator,
    left: *const ArrayData,
    right: *const ArrayData,
    values_buf: *Buffer,
) Error!*ArrayData {
    values_buf.freeze();

    const validity = try resultValidity(allocator, left, right);
    errdefer if (validity.buffer) |buf| buf.deinit();

    return ArrayData.initOwned(
        allocator,
        .bool,
        left.len,
        0,
        validity.null_count,
        &.{ validity.buffer, values_buf },
        &.{},
        null,
    );
}

fn resultValidity(allocator: Allocator, left: *const ArrayData, right: *const ArrayData) Error!ValidityResult {
    const left_null_count = left.nullCount();
    const right_null_count = right.nullCount();
    if (left_null_count == 0 and right_null_count == 0) {
        return .{ .buffer = null, .null_count = 0 };
    }

    const validity_buf = try Buffer.allocate(allocator, try bitmap.byteLenChecked(left.len));
    errdefer validity_buf.deinit();
    const out = validity_buf.mutableSlice();

    if (left_null_count == 0) {
        bitmap.copyBits(out, 0, right.buffers[0].?.dataSlice(), right.offset, left.len);
    } else if (right_null_count == 0) {
        bitmap.copyBits(out, 0, left.buffers[0].?.dataSlice(), left.offset, left.len);
    } else {
        bitmap.andBits(
            out,
            0,
            left.buffers[0].?.dataSlice(),
            left.offset,
            right.buffers[0].?.dataSlice(),
            right.offset,
            left.len,
        );
    }

    const null_count = left.len - bitmap.countSetBits(out, 0, left.len);
    if (null_count == 0) {
        validity_buf.deinit();
        return .{ .buffer = null, .null_count = 0 };
    }

    validity_buf.freeze();
    return .{ .buffer = validity_buf, .null_count = null_count };
}

pub fn compareOrdered(operation: Operation, left: anytype, right: @TypeOf(left)) bool {
    return switch (operation) {
        .equal => left == right,
        .not_equal => left != right,
        .less => left < right,
        .less_equal => left <= right,
        .greater => left > right,
        .greater_equal => left >= right,
    };
}

pub fn compareOrderedVector(
    comptime T: type,
    comptime lanes: usize,
    operation: Operation,
    left: @Vector(lanes, T),
    right: @Vector(lanes, T),
) @Vector(lanes, bool) {
    return switch (operation) {
        .equal => left == right,
        .not_equal => left != right,
        .less => left < right,
        .less_equal => left <= right,
        .greater => left > right,
        .greater_equal => left >= right,
    };
}

pub fn fixedWidthValueBytes(comptime T: type, data: *const ArrayData) []const u8 {
    const values = data.buffers[1].?.dataSlice();
    const start = data.offset * @sizeOf(T);
    const end = start + data.len * @sizeOf(T);
    return values[start..end];
}

pub fn fixedWidthValueSlice(comptime T: type, data: *const ArrayData) []align(1) const T {
    return std.mem.bytesAsSlice(T, fixedWidthValueBytes(T, data));
}

pub fn packBoolVector8(matches: @Vector(8, bool)) u8 {
    return @bitCast(@select(
        u1,
        matches,
        @as(@Vector(8, u1), @splat(1)),
        @as(@Vector(8, u1), @splat(0)),
    ));
}

pub fn writeOrderedValuesScalar(
    comptime T: type,
    out: []u8,
    operation: Operation,
    left_values: []align(1) const T,
    right_values: []align(1) const T,
) void {
    var byte_i: usize = 0;
    var i: usize = 0;
    while (i + 8 <= left_values.len) : ({
        i += 8;
        byte_i += 1;
    }) {
        var byte: u8 = 0;
        inline for (0..8) |lane| {
            if (compareOrdered(operation, left_values[i + lane], right_values[i + lane])) {
                byte |= @as(u8, 1) << lane;
            }
        }
        out[byte_i] = byte;
    }

    if (i < left_values.len) {
        var byte: u8 = 0;
        var lane: usize = 0;
        while (i < left_values.len) : ({
            i += 1;
            lane += 1;
        }) {
            if (compareOrdered(operation, left_values[i], right_values[i])) {
                byte |= @as(u8, 1) << @intCast(lane);
            }
        }
        out[byte_i] = byte;
    }
}

pub fn compareByteSlices(operation: Operation, left: []const u8, right: []const u8) bool {
    return switch (operation) {
        .equal => std.mem.eql(u8, left, right),
        .not_equal => !std.mem.eql(u8, left, right),
        .less, .less_equal, .greater, .greater_equal => compareOrder(operation, std.mem.order(u8, left, right)),
    };
}

pub fn compareOrder(operation: Operation, order: std.math.Order) bool {
    return switch (operation) {
        .equal => order == .eq,
        .not_equal => order != .eq,
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
    };
}
