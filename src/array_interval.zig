// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Interval array typed views.

const std = @import("std");
const datatype = @import("datatype.zig");
const array_data = @import("array_data.zig");
const common = @import("array_base.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const DayTimeInterval = extern struct {
    days: i32,
    milliseconds: i32,
};

pub const MonthDayNanoInterval = extern struct {
    months: i32,
    days: i32,
    nanoseconds: i64,
};

pub const IntervalKind = enum {
    month_interval,
    day_time_interval,
    month_day_nano_interval,
};

fn byteWidthFor(comptime kind: IntervalKind) usize {
    return switch (kind) {
        .month_interval => 4,
        .day_time_interval => 8,
        .month_day_nano_interval => 16,
    };
}

fn valueTypeFor(comptime kind: IntervalKind) type {
    return switch (kind) {
        .month_interval => i32,
        .day_time_interval => DayTimeInterval,
        .month_day_nano_interval => MonthDayNanoInterval,
    };
}

fn dataTypeMatches(comptime kind: IntervalKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .month_interval => ty == .month_interval,
        .day_time_interval => ty == .day_time_interval,
        .month_day_nano_interval => ty == .month_day_nano_interval,
    };
}

pub fn IntervalArray(comptime kind: IntervalKind) type {
    const width = byteWidthFor(kind);
    const Value = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const ValueType = Value;

        view: common.ValidityView(.bitmap),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.ValidityView(.bitmap).init(data) };
        }

        pub fn byteWidth(self: Self) usize {
            _ = self;
            return width;
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const start = (self.view.base.offset + i) * width;
            return self.view.base.data.buffers[1].?.dataSlice()[start..][0..width];
        }

        pub fn value(self: Self, i: usize) Value {
            return readValue(kind, self.valueBytes(i));
        }
    };
}

pub const MonthIntervalArray = IntervalArray(.month_interval);
pub const DayTimeIntervalArray = IntervalArray(.day_time_interval);
pub const MonthDayNanoIntervalArray = IntervalArray(.month_day_nano_interval);

fn readValue(comptime kind: IntervalKind, bytes: []const u8) valueTypeFor(kind) {
    return switch (kind) {
        .month_interval => std.mem.readInt(i32, bytes[0..4], .little),
        .day_time_interval => .{
            .days = std.mem.readInt(i32, bytes[0..4], .little),
            .milliseconds = std.mem.readInt(i32, bytes[4..8], .little),
        },
        .month_day_nano_interval => .{
            .months = std.mem.readInt(i32, bytes[0..4], .little),
            .days = std.mem.readInt(i32, bytes[4..8], .little),
            .nanoseconds = std.mem.readInt(i64, bytes[8..16], .little),
        },
    };
}

test "MonthIntervalArray reads values and slices" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 3 * 4);
    errdefer values.deinit();
    std.mem.writeInt(i32, values.data[0..4], 1, .little);
    std.mem.writeInt(i32, values.data[4..8], 24, .little);
    std.mem.writeInt(i32, values.data[8..12], -3, .little);
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .month_interval, 3, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try MonthIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.byteWidth());
    try std.testing.expectEqual(@as(i32, 1), arr.value(0));
    try std.testing.expectEqual(@as(i32, 24), arr.value(1));
    const sliced = MonthIntervalArray{ .view = arr.view.slice(2, 1) };
    try std.testing.expectEqual(@as(i32, -3), sliced.value(0));

    const owned = try arr.view.slice(1, 2).base.sliceOwned(0, 1);
    defer owned.deinit();
    const owned_arr = try MonthIntervalArray.fromData(owned);
    try std.testing.expectEqual(@as(i32, 24), owned_arr.value(0));
}

test "DayTimeIntervalArray reads values" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 2 * 8);
    errdefer values.deinit();
    std.mem.writeInt(i32, values.data[0..4], 2, .little);
    std.mem.writeInt(i32, values.data[4..8], 300, .little);
    std.mem.writeInt(i32, values.data[8..12], -4, .little);
    std.mem.writeInt(i32, values.data[12..16], -500, .little);
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .day_time_interval, 2, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try DayTimeIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(i32, 2), arr.value(0).days);
    try std.testing.expectEqual(@as(i32, 300), arr.value(0).milliseconds);
    try std.testing.expectEqual(@as(i32, -4), arr.value(1).days);
    try std.testing.expectEqual(@as(i32, -500), arr.value(1).milliseconds);
}

test "MonthDayNanoIntervalArray reads values" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 2 * 16);
    var values_owned = false;
    errdefer if (!values_owned) values.deinit();
    std.mem.writeInt(i32, values.data[0..4], 3, .little);
    std.mem.writeInt(i32, values.data[4..8], 4, .little);
    std.mem.writeInt(i64, values.data[8..16], 5000, .little);
    std.mem.writeInt(i32, values.data[16..20], -1, .little);
    std.mem.writeInt(i32, values.data[20..24], -2, .little);
    std.mem.writeInt(i64, values.data[24..32], -7000, .little);
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .month_day_nano_interval, 2, 0, 0, &.{ null, values }, &.{}, null);
    values_owned = true;
    defer data.deinit();
    try data.validate();

    const arr = try MonthDayNanoIntervalArray.fromData(data);
    try std.testing.expectEqual(@as(i32, 3), arr.value(0).months);
    try std.testing.expectEqual(@as(i32, 4), arr.value(0).days);
    try std.testing.expectEqual(@as(i64, 5000), arr.value(0).nanoseconds);
    try std.testing.expectEqual(@as(i32, -1), arr.value(1).months);
    try std.testing.expectEqual(@as(i32, -2), arr.value(1).days);
    try std.testing.expectEqual(@as(i64, -7000), arr.value(1).nanoseconds);
    try std.testing.expectEqual(@as(u8, 0x88), arr.valueBytes(0)[8]);
}
