// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Null comparison kernels.

const Allocator = @import("std").mem.Allocator;
const builder = @import("../../builder.zig");
const common = @import("common.zig");
const ArrayData = common.ArrayData;
const Error = common.Error;
const Operation = common.Operation;

pub fn nulls(
    allocator: Allocator,
    operation: Operation,
    left: *const ArrayData,
    right: *const ArrayData,
) Error!*ArrayData {
    _ = operation;
    if (left.len != right.len) return error.LengthMismatch;
    if (!left.type.equals(right.type)) return error.TypeMismatch;

    var out = builder.BooleanBuilder.init(allocator);
    errdefer out.deinit();
    try out.appendNulls(left.len);
    return out.finish();
}
