// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Null array builder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;

pub const NullBuilderError = Allocator.Error || checked.Error;

pub const NullBuilder = struct {
    pub const Array = array.NullArray;
    pub const Error = NullBuilderError;

    allocator: Allocator,
    len: usize,

    pub fn init(allocator: Allocator) NullBuilder {
        return .{
            .allocator = allocator,
            .len = 0,
        };
    }

    pub fn deinit(self: *NullBuilder) void {
        self.reset();
    }

    pub fn reset(self: *NullBuilder) void {
        self.len = 0;
    }

    pub fn reserve(self: *NullBuilder, additional: usize) Error!void {
        _ = try checked.add(self.len, additional);
    }

    pub fn appendNull(self: *NullBuilder) Error!void {
        try self.appendNulls(1);
    }

    pub fn appendNulls(self: *NullBuilder, n: usize) Error!void {
        if (n == 0) return;
        self.len = try checked.add(self.len, n);
    }

    pub fn appendEmptyValue(self: *NullBuilder) Error!void {
        try self.appendNull();
    }

    pub fn appendEmptyValues(self: *NullBuilder, n: usize) Error!void {
        try self.appendNulls(n);
    }

    pub fn length(self: NullBuilder) usize {
        return self.len;
    }

    pub fn finish(self: *NullBuilder) Error!*ArrayData {
        const n = self.len;
        self.len = 0;
        return ArrayData.initOwned(self.allocator, .null_, n, 0, n, &.{}, &.{}, null);
    }
};

test "NullBuilder builds null arrays and reuses state" {
    const allocator = std.testing.allocator;
    var b = NullBuilder.init(allocator);
    defer b.deinit();

    try b.appendNull();
    try b.appendNulls(2);
    try b.appendEmptyValue();
    try b.appendEmptyValues(1);
    try std.testing.expectEqual(@as(usize, 5), b.length());

    const data = try b.finish();
    defer data.deinit();
    try data.validate();
    const arr = try array.NullArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 5), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 5), arr.view.nullCount());
    try std.testing.expect(arr.view.isNull(4));
    try std.testing.expect(!arr.view.isValid(4));

    try std.testing.expectEqual(@as(usize, 0), b.length());
    try b.appendNulls(2);
    const reused = try b.finish();
    defer reused.deinit();
    try reused.validate();
    try std.testing.expectEqual(@as(usize, 2), reused.len);
    try std.testing.expectEqual(@as(?usize, 2), reused.null_count);
}

test "NullBuilder reserve checks overflow" {
    const allocator = std.testing.allocator;
    var b = NullBuilder{
        .allocator = allocator,
        .len = std.math.maxInt(usize),
    };

    try std.testing.expectError(error.Overflow, b.reserve(1));
    try std.testing.expectError(error.Overflow, b.appendNull());
}
