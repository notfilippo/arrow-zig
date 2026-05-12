// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Offset buffer helpers.
//!
//! Binary and list arrays use monotonic int32 or int64 offsets. This module
//! builds, reads, writes, and validates those buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const Buffer = @import("buffer.zig").Buffer;

pub const ValidationError = error{
    NegativeOffset,
    OffsetValueOutOfBounds,
    OffsetsNotMonotonic,
};

pub const ValueRange = struct {
    offset: usize,
    len: usize,
};

pub const BuilderError = Allocator.Error || checked.Error;

pub fn Builder(comptime Offset: type) type {
    return struct {
        const Self = @This();
        pub const Error = BuilderError;

        buffer: ?*Buffer,

        pub fn init() Self {
            return .{ .buffer = null };
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer) |buf| buf.deinit();
            self.buffer = null;
        }

        pub fn reserveSlots(self: *Self, allocator: Allocator, slots: usize) Error!void {
            if (slots == 0) return;
            const buf = try self.ensureStarted(allocator);
            try buf.reserve(try checked.mul(slots, @sizeOf(Offset)));
        }

        pub fn append(self: *Self, allocator: Allocator, value: usize) Error!void {
            const buf = try self.ensureStarted(allocator);
            const index = buf.size / @sizeOf(Offset);
            try self.reserveSlots(allocator, try checked.add(index, 1));
            try write(Offset, buf, index, value);
            buf.size = try checked.add(buf.size, @sizeOf(Offset));
        }

        pub fn appendRepeat(self: *Self, allocator: Allocator, n: usize, value: usize) Error!void {
            if (n == 0) return;
            const buf = try self.ensureStarted(allocator);
            const start = buf.size / @sizeOf(Offset);
            try self.reserveSlots(allocator, try checked.add(start, n));
            for (0..n) |i| try write(Offset, buf, start + i, value);
            buf.size = try checked.add(buf.size, try checked.mul(n, @sizeOf(Offset)));
        }

        pub fn finish(self: *Self, allocator: Allocator) Error!*Buffer {
            const buf = try self.ensureStarted(allocator);
            self.buffer = null;
            buf.freeze();
            return buf;
        }

        fn ensureStarted(self: *Self, allocator: Allocator) Error!*Buffer {
            if (self.buffer == null) {
                const buf = try Buffer.allocate(allocator, @sizeOf(Offset));
                write(Offset, buf, 0, 0) catch unreachable;
                self.buffer = buf;
            }
            return self.buffer.?;
        }
    };
}

pub fn read(comptime Offset: type, buffer: *const Buffer, index: usize) Offset {
    const start = index * @sizeOf(Offset);
    const bytes = buffer.dataSlice()[start..][0..@sizeOf(Offset)];
    return std.mem.readInt(Offset, bytes, .little);
}

pub fn write(comptime Offset: type, buffer: *Buffer, index: usize, value: usize) checked.Error!void {
    try ensureRange(Offset, value);
    const start = index * @sizeOf(Offset);
    std.mem.writeInt(Offset, buffer.data[start..][0..@sizeOf(Offset)], @intCast(value), .little);
}

pub fn rangeAt(comptime Offset: type, buffer: *const Buffer, index: usize) ValueRange {
    const start: usize = @intCast(read(Offset, buffer, index));
    const end: usize = @intCast(read(Offset, buffer, index + 1));
    return .{ .offset = start, .len = end - start };
}

pub fn validateMonotonic(
    comptime Offset: type,
    buffer: *const Buffer,
    start_index: usize,
    len: usize,
    limit: usize,
) ValidationError!void {
    if (len == 0) return;
    var previous = try toUsize(read(Offset, buffer, start_index));
    if (previous > limit) return error.OffsetValueOutOfBounds;
    for (1..len + 1) |i| {
        const current = try toUsize(read(Offset, buffer, start_index + i));
        if (current < previous) return error.OffsetsNotMonotonic;
        if (current > limit) return error.OffsetValueOutOfBounds;
        previous = current;
    }
}

pub fn ensureRange(comptime Offset: type, value: usize) checked.Error!void {
    if (value > maxValue(Offset)) return error.Overflow;
}

fn maxValue(comptime Offset: type) usize {
    const max = std.math.maxInt(Offset);
    if (@bitSizeOf(usize) < @bitSizeOf(Offset)) return std.math.maxInt(usize);
    return @intCast(max);
}

pub fn toUsize(value: anytype) ValidationError!usize {
    if (value < 0) return error.NegativeOffset;
    return @intCast(value);
}

test "offset builder writes repeated offsets" {
    const allocator = std.testing.allocator;
    var builder = Builder(i32).init();
    defer builder.deinit();

    try builder.append(allocator, 2);
    try builder.appendRepeat(allocator, 2, 5);
    const buffer = try builder.finish(allocator);
    defer buffer.deinit();

    try std.testing.expectEqual(@as(i32, 0), read(i32, buffer, 0));
    try std.testing.expectEqual(@as(i32, 2), read(i32, buffer, 1));
    try std.testing.expectEqual(@as(i32, 5), read(i32, buffer, 2));
    try std.testing.expectEqual(@as(i32, 5), read(i32, buffer, 3));
}

test "validateMonotonic rejects bad offsets" {
    const allocator = std.testing.allocator;
    const buffer = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    defer buffer.deinit();
    try write(i32, buffer, 0, 0);
    try write(i32, buffer, 1, 4);
    try write(i32, buffer, 2, 3);

    try std.testing.expectError(error.OffsetsNotMonotonic, validateMonotonic(i32, buffer, 0, 2, 4));
}
