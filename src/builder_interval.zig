// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Interval builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");
const datatype = @import("datatype.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;

pub const IntervalBuilderError = Allocator.Error || checked.Error || error{InvalidByteWidth};

fn byteWidthFor(comptime kind: array.IntervalKind) usize {
    return switch (kind) {
        .month_interval => 4,
        .day_time_interval => 8,
        .month_day_nano_interval => 16,
    };
}

fn valueTypeFor(comptime kind: array.IntervalKind) type {
    return switch (kind) {
        .month_interval => i32,
        .day_time_interval => array.DayTimeInterval,
        .month_day_nano_interval => array.MonthDayNanoInterval,
    };
}

pub fn IntervalBuilder(comptime kind: array.IntervalKind) type {
    const width = byteWidthFor(kind);
    const Value = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const Array = array.IntervalArray(kind);
        pub const Error = IntervalBuilderError;
        pub const ValueType = Value;

        allocator: Allocator,
        values: ?*Buffer,
        validity: bitmap.BitmapBuilder,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .values = null,
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        pub fn reset(self: *Self) void {
            if (self.values) |buf| buf.deinit();
            self.values = null;
            self.validity.deinit();
            self.len = 0;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const values = try self.ensureValues();
            const byte_len = try checked.mul(additional, width);
            try values.reserve(try checked.add(values.size, byte_len));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self, value: Value) Error!void {
            try self.reserve(1);
            const values = self.values.?;
            writeValue(kind, values.data[values.size..][0..width], value);
            values.size = try checked.add(values.size, width);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len != width) return error.InvalidByteWidth;
            try self.reserve(1);
            const values = self.values.?;
            @memcpy(values.data[values.size..][0..width], bytes);
            values.size = try checked.add(values.size, width);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.appendNulls(1);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.appendZeroes(n, false);
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.appendEmptyValues(1);
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.appendZeroes(n, true);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const n = self.len;
            const null_count = self.validity.false_count;
            self.len = 0;

            const values_buf = try self.finishValues();
            errdefer values_buf.deinit();
            const validity_buf = try self.validity.finishNullable(self.allocator);
            errdefer if (validity_buf) |buf| buf.deinit();

            return ArrayData.initOwned(self.allocator, dataTypeForKind(kind), n, 0, null_count, &.{ validity_buf, values_buf }, &.{}, null);
        }

        fn appendZeroes(self: *Self, n: usize, valid: bool) Error!void {
            try self.reserve(n);
            const values = self.values.?;
            const byte_len = try checked.mul(n, width);
            const end = try checked.add(values.size, byte_len);
            if (byte_len != 0) @memset(values.data[values.size..end], 0);
            values.size = end;
            self.validity.unsafeAppendN(valid, n);
            self.len = try checked.add(self.len, n);
        }

        fn ensureValues(self: *Self) Error!*Buffer {
            if (self.values == null) self.values = try Buffer.allocate(self.allocator, 0);
            return self.values.?;
        }

        fn finishValues(self: *Self) Error!*Buffer {
            const values = if (self.values) |buf| blk: {
                self.values = null;
                break :blk buf;
            } else try Buffer.allocate(self.allocator, 0);
            values.freeze();
            return values;
        }
    };
}

pub const MonthIntervalBuilder = IntervalBuilder(.month_interval);
pub const DayTimeIntervalBuilder = IntervalBuilder(.day_time_interval);
pub const MonthDayNanoIntervalBuilder = IntervalBuilder(.month_day_nano_interval);

fn dataTypeForKind(comptime kind: array.IntervalKind) datatype.DataType {
    return switch (kind) {
        .month_interval => .month_interval,
        .day_time_interval => .day_time_interval,
        .month_day_nano_interval => .month_day_nano_interval,
    };
}

fn writeValue(comptime kind: array.IntervalKind, dst: []u8, value: valueTypeFor(kind)) void {
    switch (kind) {
        .month_interval => std.mem.writeInt(i32, dst[0..4], value, .little),
        .day_time_interval => {
            std.mem.writeInt(i32, dst[0..4], value.days, .little);
            std.mem.writeInt(i32, dst[4..8], value.milliseconds, .little);
        },
        .month_day_nano_interval => {
            std.mem.writeInt(i32, dst[0..4], value.months, .little);
            std.mem.writeInt(i32, dst[4..8], value.days, .little);
            std.mem.writeInt(i64, dst[8..16], value.nanoseconds, .little);
        },
    }
}

test "MonthIntervalBuilder builds interval arrays" {
    const allocator = std.testing.allocator;
    var b = MonthIntervalBuilder.init(allocator);
    defer b.deinit();

    try b.append(12);
    try b.appendNull();
    try b.append(-3);
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.MonthIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(i32, 12), arr.value(0));
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqual(@as(i32, -3), arr.value(2));
}

test "DayTimeIntervalBuilder builds interval arrays" {
    const allocator = std.testing.allocator;
    var b = DayTimeIntervalBuilder.init(allocator);
    defer b.deinit();

    try b.append(.{ .days = 2, .milliseconds = 300 });
    try b.appendNull();
    try b.append(.{ .days = -4, .milliseconds = -500 });
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.DayTimeIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(i32, 2), arr.value(0).days);
    try std.testing.expectEqual(@as(i32, 300), arr.value(0).milliseconds);
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqual(@as(i32, -4), arr.value(2).days);
    try std.testing.expectEqual(@as(i32, -500), arr.value(2).milliseconds);
}

test "MonthDayNanoIntervalBuilder builds interval arrays" {
    const allocator = std.testing.allocator;
    var b = MonthDayNanoIntervalBuilder.init(allocator);
    defer b.deinit();

    try b.append(.{ .months = 3, .days = 4, .nanoseconds = 5000 });
    try b.appendEmptyValue();
    try b.append(.{ .months = -1, .days = -2, .nanoseconds = -7000 });
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.MonthDayNanoIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(i32, 3), arr.value(0).months);
    try std.testing.expectEqual(@as(i32, 4), arr.value(0).days);
    try std.testing.expectEqual(@as(i64, 5000), arr.value(0).nanoseconds);
    try std.testing.expectEqual(@as(i32, 0), arr.value(1).months);
    try std.testing.expectEqual(@as(i64, 0), arr.value(1).nanoseconds);
    try std.testing.expectEqual(@as(i32, -1), arr.value(2).months);
    try std.testing.expectEqual(@as(i32, -2), arr.value(2).days);
    try std.testing.expectEqual(@as(i64, -7000), arr.value(2).nanoseconds);
}

test "IntervalBuilder rejects wrong byte width" {
    const allocator = std.testing.allocator;
    var b = DayTimeIntervalBuilder.init(allocator);
    defer b.deinit();

    try std.testing.expectError(error.InvalidByteWidth, b.appendBytes(&.{ 1, 2, 3 }));
}
