// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Null array typed view.

const std = @import("std");
const datatype = @import("../datatype.zig");
const array_data = @import("data.zig");
const common = @import("common.zig");
const ArrayData = array_data.ArrayData;

pub const NullArray = struct {
    view: common.ValidityView(.all),

    pub fn fromData(data: *const ArrayData) common.ViewError!NullArray {
        if (data.type.id() != .null_) return error.TypeMismatch;
        if (data.buffers.len != 0 or data.children.len != 0 or data.dictionary != null) return error.InvalidBufferLayout;
        return .{ .view = common.ValidityView(.all).init(data) };
    }
};

test "NullArray slices and clones" {
    const allocator = std.testing.allocator;
    const data = try ArrayData.initOwned(allocator, .null_, 5, 0, 5, &.{}, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try NullArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 5), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 5), arr.view.nullCount());
    try std.testing.expect(!arr.view.isValid(0));
    try std.testing.expect(arr.view.isNull(0));

    const sliced = NullArray{ .view = .{ .base = arr.view.base.slice(2, 9) } };
    try std.testing.expectEqual(@as(usize, 2), sliced.view.base.offset);
    try std.testing.expectEqual(@as(usize, 3), sliced.view.base.len);
    try std.testing.expectEqual(@as(usize, 3), sliced.view.nullCount());

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try NullArray.fromData(sliced_owned);
    try std.testing.expectEqual(@as(usize, 2), sliced_owned_arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 2), sliced_owned_arr.view.nullCount());

    const clone = try sliced.view.base.cloneRetained();
    defer clone.deinit();
    const clone_arr = try NullArray.fromData(clone);
    try std.testing.expectEqual(@as(usize, 3), clone_arr.view.base.len);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.base.sliceChecked(6, 1));
}
