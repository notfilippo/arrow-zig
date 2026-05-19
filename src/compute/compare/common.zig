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
