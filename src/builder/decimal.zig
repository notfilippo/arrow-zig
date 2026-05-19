// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Decimal builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const array = @import("../array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("../buffer.zig").Buffer;
const common = @import("common.zig");

pub const DecimalBuilderError = Allocator.Error || checked.Error || datatype.ValidationError || error{InvalidByteWidth};

fn byteWidthFor(comptime kind: array.DecimalKind) usize {
    return switch (kind) {
        .decimal128 => 16,
        .decimal256 => 32,
    };
}

fn valueTypeFor(comptime kind: array.DecimalKind) type {
    return switch (kind) {
        .decimal128 => i128,
        .decimal256 => i256,
    };
}

pub fn DecimalBuilder(comptime kind: array.DecimalKind) type {
    const width = byteWidthFor(kind);
    const Value = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const Array = array.DecimalArray(kind);
        pub const Error = DecimalBuilderError;
        pub const ValueType = Value;

        allocator: Allocator,
        precision: u8,
        scale: i32,
        values: ?*Buffer,
        slots: common.Slots,

        pub fn init(allocator: Allocator, precision: u8, scale: i32) Error!Self {
            const ty = dataTypeForKind(kind, precision, scale);
            try ty.validate();
            return .{
                .allocator = allocator,
                .precision = precision,
                .scale = scale,
                .values = null,
                .slots = common.Slots.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        pub fn reset(self: *Self) void {
            if (self.values) |buf| buf.deinit();
            self.values = null;
            self.slots.deinit();
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const values = try self.ensureValues();
            const byte_len = try checked.mul(additional, width);
            try values.reserve(try checked.add(values.size, byte_len));
            try self.slots.reserve(self.allocator, additional);
        }

        pub fn append(self: *Self, value: Value) Error!void {
            try self.reserve(1);
            const values = self.values.?;
            writeValue(values.data[values.size..][0..width], value);
            values.size = try checked.add(values.size, width);
            self.slots.unsafeAppend(true);
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len != width) return error.InvalidByteWidth;
            try self.reserve(1);
            const values = self.values.?;
            @memcpy(values.data[values.size..][0..width], bytes);
            values.size = try checked.add(values.size, width);
            self.slots.unsafeAppend(true);
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
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const ty = dataTypeForKind(kind, self.precision, self.scale);
            try ty.validate();

            const values_buf = try self.finishValues();
            errdefer values_buf.deinit();
            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            return ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{ slots.validity, values_buf }, &.{}, null);
        }

        fn appendZeroes(self: *Self, n: usize, valid: bool) Error!void {
            try self.reserve(n);
            const values = self.values.?;
            const byte_len = try checked.mul(n, width);
            const end = try checked.add(values.size, byte_len);
            if (byte_len != 0) @memset(values.data[values.size..end], 0);
            values.size = end;
            try self.slots.unsafeAppendN(valid, n);
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

pub const Decimal128Builder = DecimalBuilder(.decimal128);
pub const Decimal256Builder = DecimalBuilder(.decimal256);

fn dataTypeForKind(comptime kind: array.DecimalKind, precision: u8, scale: i32) datatype.DataType {
    return switch (kind) {
        .decimal128 => .{ .decimal128 = .{ .precision = precision, .scale = scale } },
        .decimal256 => .{ .decimal256 = .{ .precision = precision, .scale = scale } },
    };
}

fn writeValue(dst: []u8, value: anytype) void {
    switch (@TypeOf(value)) {
        i128 => std.mem.writeInt(i128, dst[0..16], value, .little),
        i256 => std.mem.writeInt(i256, dst[0..32], value, .little),
        else => @compileError("unsupported decimal builder value type"),
    }
}

test "Decimal128Builder builds decimal arrays" {
    const allocator = std.testing.allocator;
    var b = try Decimal128Builder.init(allocator, 12, 2);
    defer b.deinit();

    try b.append(12345);
    try b.appendNull();
    try b.append(-67890);
    try b.appendEmptyValue();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.Decimal128Array.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(u8, 12), arr.precision());
    try std.testing.expectEqual(@as(i32, 2), arr.scale());
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(i128, 12345), arr.value(0));
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqual(@as(i128, -67890), arr.value(2));
    try std.testing.expectEqual(@as(i128, 0), arr.value(3));
}

test "Decimal256Builder builds decimal arrays" {
    const allocator = std.testing.allocator;
    var b = try Decimal256Builder.init(allocator, 40, -2);
    defer b.deinit();

    try b.append(12345);
    try b.appendNull();
    try b.append(-67890);
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.Decimal256Array.fromData(data);
    try std.testing.expectEqual(@as(u8, 40), arr.precision());
    try std.testing.expectEqual(@as(i32, -2), arr.scale());
    try std.testing.expectEqual(@as(i256, 12345), arr.value(0));
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqual(@as(i256, -67890), arr.value(2));
}

test "DecimalBuilder validates metadata and byte width" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDecimalPrecision, Decimal128Builder.init(allocator, 39, 0));

    var b = try Decimal256Builder.init(allocator, 76, 0);
    defer b.deinit();
    try std.testing.expectError(error.InvalidByteWidth, b.appendBytes(&.{ 1, 2, 3 }));
    try b.appendEmptyValues(2);
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
    const arr = try array.Decimal256Array.fromData(data);
    try std.testing.expectEqual(@as(usize, 2), arr.view.base.len);
}
