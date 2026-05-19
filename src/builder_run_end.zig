// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Run end encoded builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;

pub fn RunEndEncodedBuilderError(comptime ValueBuilder: type) type {
    return Allocator.Error || checked.Error || datatype.ValidationError || ValueBuilder.Error || error{
        InvalidRunEndValue,
        RunEndNotIncreasing,
        UnclosedRunValue,
    };
}

pub fn RunEndEncodedBuilder(comptime RunEnd: type, comptime ValueBuilder: type) type {
    ensureRunEnd(RunEnd);

    return struct {
        const Self = @This();
        pub const Array = array.RunEndEncodedArray(RunEnd);
        pub const Values = ValueBuilder;
        pub const Error = RunEndEncodedBuilderError(ValueBuilder);

        allocator: Allocator,
        run_ends: IntBuffer(RunEnd),
        values_builder: ValueBuilder,
        run_count: usize,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .run_ends = IntBuffer(RunEnd).init(),
                .values_builder = ValueBuilder.init(allocator),
                .run_count = 0,
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.run_ends.deinit();
            self.values_builder.deinit();
            self.run_count = 0;
            self.len = 0;
        }

        pub fn reset(self: *Self) void {
            if (comptime !@hasDecl(ValueBuilder, "reset")) {
                @compileError("RunEndEncodedBuilder.reset requires ValueBuilder.reset");
            }
            self.run_ends.deinit();
            self.values_builder.reset();
            self.run_count = 0;
            self.len = 0;
        }

        pub fn values(self: *Self) *ValueBuilder {
            return &self.values_builder;
        }

        pub fn reserveRuns(self: *Self, additional: usize) Error!void {
            try self.run_ends.reserve(self.allocator, additional);
        }

        pub fn appendRun(self: *Self, run_end: RunEnd) Error!void {
            const end = try runEndAsUsize(run_end);
            if (end <= self.len) return error.RunEndNotIncreasing;
            if (self.values_builder.length() != self.run_count + 1) return error.UnclosedRunValue;
            try self.run_ends.append(self.allocator, end);
            self.run_count = try checked.add(self.run_count, 1);
            self.len = end;
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn physicalLength(self: Self) usize {
            return self.run_count;
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            if (self.values_builder.length() != self.run_count) return error.UnclosedRunValue;

            const n = self.len;
            var consumed = false;
            errdefer if (consumed) {
                self.len = 0;
                self.run_count = 0;
            };

            const run_ends_buf = try self.run_ends.finish(self.allocator);
            consumed = true;
            errdefer run_ends_buf.deinit();

            const run_ends_data = try ArrayData.initOwned(self.allocator, runEndType(RunEnd), self.run_count, 0, 0, &.{ null, run_ends_buf }, &.{}, null);
            errdefer run_ends_data.deinit();

            const values_data = try self.values_builder.finish();
            errdefer values_data.deinit();

            const run_ends_field = try datatype.Field.create(self.allocator, "run_ends", &run_ends_data.type, false, &.{});
            errdefer run_ends_field.deinit();
            const values_field = try datatype.Field.create(self.allocator, "values", &values_data.type, true, &.{});
            errdefer values_field.deinit();

            const ty = datatype.DataType{ .run_end_encoded = .{
                .run_ends = run_ends_field,
                .values = values_field,
            } };
            const data = try ArrayData.initOwned(self.allocator, ty, n, 0, 0, &.{}, &.{ run_ends_data, values_data }, null);
            run_ends_field.deinit();
            values_field.deinit();
            self.len = 0;
            self.run_count = 0;
            return data;
        }
    };
}

fn IntBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: ?*Buffer,
        len: usize,

        fn init() Self {
            return .{ .buffer = null, .len = 0 };
        }

        fn deinit(self: *Self) void {
            if (self.buffer) |buf| buf.deinit();
            self.buffer = null;
            self.len = 0;
        }

        fn reserve(self: *Self, allocator: Allocator, additional: usize) (Allocator.Error || checked.Error)!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.len, additional);
            const buf = try self.ensureBuffer(allocator);
            try buf.reserve(try checked.mul(new_len, @sizeOf(T)));
        }

        fn append(self: *Self, allocator: Allocator, value: usize) (Allocator.Error || checked.Error)!void {
            try self.reserve(allocator, 1);
            const buf = self.buffer.?;
            try offset_data.write(T, buf, self.len, value);
            self.len = try checked.add(self.len, 1);
            buf.size = try checked.mul(self.len, @sizeOf(T));
        }

        fn finish(self: *Self, allocator: Allocator) (Allocator.Error || checked.Error)!*Buffer {
            const buf = if (self.buffer) |b| blk: {
                self.buffer = null;
                break :blk b;
            } else try Buffer.allocate(allocator, 0);
            self.len = 0;
            buf.freeze();
            return buf;
        }

        fn ensureBuffer(self: *Self, allocator: Allocator) (Allocator.Error || checked.Error)!*Buffer {
            if (self.buffer == null) self.buffer = try Buffer.allocate(allocator, 0);
            return self.buffer.?;
        }
    };
}

fn runEndType(comptime RunEnd: type) datatype.DataType {
    return switch (RunEnd) {
        i16 => .int16,
        i32 => .int32,
        i64 => .int64,
        else => unreachable,
    };
}

fn ensureRunEnd(comptime T: type) void {
    switch (T) {
        i16, i32, i64 => {},
        else => @compileError("run end type must be i16, i32, or i64"),
    }
}

fn runEndAsUsize(value: anytype) error{InvalidRunEndValue}!usize {
    if (value <= 0) return error.InvalidRunEndValue;
    return @intCast(value);
}

test "RunEndEncodedBuilder builds run encoded arrays" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");

    var b = RunEndEncodedBuilder(i32, builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try b.values().append(10);
    try std.testing.expectError(error.InvalidRunEndValue, b.appendRun(-1));
    try b.appendRun(2);
    try b.values().append(20);
    try b.appendRun(5);
    try b.values().appendNull();
    try b.appendRun(7);

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.RunEndEncodedArray(i32).fromData(data);
    try std.testing.expectEqual(@as(usize, 7), arr.len);
    try std.testing.expectEqual(@as(usize, 3), arr.runCount());
    try std.testing.expectEqual(@as(i32, 2), arr.runEnd(0));
    try std.testing.expectEqual(@as(i32, 5), arr.runEnd(1));
    try std.testing.expect(arr.isNull(5));
    try std.testing.expectEqual(@as(usize, 2), arr.nullCount());
}

test "RunEndEncodedBuilder rejects incomplete and non increasing runs" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");

    var b = RunEndEncodedBuilder(i16, builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try std.testing.expectError(error.UnclosedRunValue, b.appendRun(2));
    try b.values().append(10);
    try b.appendRun(2);
    try b.values().append(20);
    try std.testing.expectError(error.RunEndNotIncreasing, b.appendRun(2));
}
