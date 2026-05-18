// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Numeric and logical temporal builders.
//!
//! Numeric builders store fixed width values and validity bits. `initType`
//! allows logical Arrow types such as date, time, timestamp, and duration when
//! they match the Zig storage type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");
const datatype = @import("datatype.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;
const builder_base = @import("builder_base.zig");

pub const NumericBuilderInitError = datatype.ValidationError || error{TypeMismatch};
pub const NumericBuilderError = Allocator.Error || checked.Error || error{ValidityBufferTooSmall};

pub fn NumericBuilder(comptime T: type) type {
    _ = array.typeIdFor(T);

    return struct {
        const Self = @This();
        pub const Array = array.NumericArray(T);
        pub const Error = NumericBuilderError;
        pub const InitTypeError = NumericBuilderInitError;

        allocator: Allocator,
        ty: datatype.DataType,
        values: ?*Buffer,
        validity: bitmap.BitmapBuilder,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            const id = comptime array.typeIdFor(T);
            return .{
                .allocator = allocator,
                .ty = @unionInit(datatype.DataType, @tagName(id), {}),
                .values = null,
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
            };
        }

        pub fn initType(allocator: Allocator, ty: datatype.DataType) InitTypeError!Self {
            try ty.validate();
            if (!array.dataTypeAcceptsZigType(T, ty)) return error.TypeMismatch;
            var self = init(allocator);
            self.ty = ty;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        /// Release all held memory and return to the post-`init` state.
        pub fn reset(self: *Self) void {
            if (self.values) |v| v.deinit();
            self.values = null;
            self.validity.deinit();
            self.len = 0;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const buf = try self.ensureValues();
            const new_len = try checked.add(self.len, additional);
            const capped_len = @max(new_len, builder_base.kMinBuilderCapacity);
            try buf.reserve(try checked.mul(capped_len, @sizeOf(T)));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self, v: T) Error!void {
            try self.reserve(1);
            self.unsafeAppend(v);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.reserve(1);
            self.unsafeAppendNull();
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n);
            const buf = self.values.?;
            const byte_len = try checked.mul(n, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            @memset(buf.data[buf.size..end], 0);
            buf.size = end;
            self.validity.unsafeAppendN(false, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn appendSlice(self: *Self, vs: []const T) Error!void {
            if (vs.len == 0) return;
            try self.reserve(vs.len);
            const buf = self.values.?;
            const byte_len = try checked.mul(vs.len, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            const dst: [*]T = @ptrCast(@alignCast(buf.data + buf.size));
            @memcpy(dst[0..vs.len], vs);
            buf.size = end;
            self.validity.unsafeAppendN(true, vs.len);
            self.len = try checked.add(self.len, vs.len);
        }

        /// Append a valid zero-valued slot without allocating a temporary slice.
        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.reserve(1);
            self.unsafeAppendEmptyValue();
        }

        /// Append `n` valid zero-valued slots.
        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n);
            const buf = self.values.?;
            const byte_len = try checked.mul(n, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            @memset(buf.data[buf.size..end], 0);
            buf.size = end;
            self.validity.unsafeAppendN(true, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        /// Finish the builder and transfer the result to the caller.
        /// Caller owns the returned data and must call `deinit`.
        pub fn finish(self: *Self) Error!*ArrayData {
            const null_count = self.validity.false_count;
            const values_buf: *Buffer = blk: {
                if (self.values) |v| {
                    v.freeze();
                    self.values = null;
                    break :blk v;
                }
                const b = try Buffer.allocate(self.allocator, 0);
                b.freeze();
                break :blk b;
            };
            errdefer values_buf.deinit();

            const n = self.len;
            self.len = 0;
            const validity_buf: ?*Buffer = try self.validity.finishNullable(self.allocator);
            errdefer if (validity_buf) |buf| buf.deinit();

            return ArrayData.initOwned(self.allocator, self.ty, n, 0, null_count, &.{ validity_buf, values_buf }, &.{}, null);
        }

        pub fn unsafeAppend(self: *Self, v: T) void {
            const buf = self.values.?;
            const ptr: *T = @ptrCast(@alignCast(buf.data + buf.size));
            ptr.* = v;
            buf.size += @sizeOf(T);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        pub fn unsafeAppendNull(self: *Self) void {
            const buf = self.values.?;
            const ptr: *T = @ptrCast(@alignCast(buf.data + buf.size));
            ptr.* = std.mem.zeroes(T);
            buf.size += @sizeOf(T);
            self.validity.unsafeAppend(false);
            self.len += 1;
        }

        pub fn unsafeAppendEmptyValue(self: *Self) void {
            const buf = self.values.?;
            const ptr: *T = @ptrCast(@alignCast(buf.data + buf.size));
            ptr.* = std.mem.zeroes(T);
            buf.size += @sizeOf(T);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        pub fn appendValues(self: *Self, vs: []const T, valid_bytes: ?[]const u8) Error!void {
            const M = builder_base.AppendValuesMixin(Self, T, writeValues);
            return M.appendValues(self, vs, valid_bytes);
        }

        pub fn appendValuesBitmap(self: *Self, vs: []const T, validity: []const u8, validity_offset: usize) Error!void {
            const M = builder_base.AppendValuesMixin(Self, T, writeValues);
            return M.appendValuesBitmap(self, vs, validity, validity_offset);
        }

        fn writeValues(self: *Self, vs: []const T) void {
            const buf = self.values.?;
            const dst: [*]T = @ptrCast(@alignCast(buf.data + buf.size));
            @memcpy(dst[0..vs.len], vs);
            buf.size += vs.len * @sizeOf(T);
        }

        fn ensureValues(self: *Self) Error!*Buffer {
            if (self.values == null) self.values = try Buffer.allocate(self.allocator, 0);
            return self.values.?;
        }
    };
}

test "NumericBuilder basic append and reuse" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);
    try std.testing.expectEqual(@as(usize, 3), b.length());
    const data1 = try b.finish();
    defer data1.deinit();
    const arr1 = try array.NumericArray(i32).fromData(data1);
    try std.testing.expectEqual(@as(i32, 10), arr1.value(0));
    try std.testing.expect(arr1.isNull(1));
    try std.testing.expectEqual(@as(i32, 30), arr1.value(2));

    try b.append(40);
    const data2 = try b.finish();
    defer data2.deinit();
    const arr2 = try array.NumericArray(i32).fromData(data2);
    try std.testing.expectEqual(@as(i32, 40), arr2.value(0));
}

test "NumericBuilder append slices nulls and all valid" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(u8).init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ 1, 2, 3 });
    try b.appendNulls(2);
    try b.appendSlice(&.{6});
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(u8).fromData(data);

    try std.testing.expectEqual(@as(usize, 6), arr.len);
    try std.testing.expectEqual(@as(usize, 2), arr.null_count);
    try std.testing.expect(arr.isNull(3));
    try std.testing.expectEqual(@as(u8, 6), arr.value(5));

    var all_valid = NumericBuilder(f64).init(allocator);
    defer all_valid.deinit();
    try all_valid.appendSlice(&.{ 1.0, 2.0, 3.0 });
    const all_valid_data = try all_valid.finish();
    defer all_valid_data.deinit();
    try std.testing.expect(all_valid_data.buffers[0] == null);
}

test "NumericBuilder reserve and logical type" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i64).init(allocator);
    defer b.deinit();
    try b.reserve(100);
    try std.testing.expect(b.values != null);
    try std.testing.expect(b.values.?.capacity >= 100 * @sizeOf(i64));

    b.len = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, b.reserve(1));

    var date_builder = try NumericBuilder(i32).initType(allocator, .date32);
    defer date_builder.deinit();
    try std.testing.expectEqual(.date32, date_builder.ty);
    try std.testing.expectError(error.InvalidTimeUnit, NumericBuilder(i32).initType(allocator, .{ .time32 = .microsecond }));
    try std.testing.expectError(error.TypeMismatch, NumericBuilder(i32).initType(allocator, .date64));
}

test "NumericBuilder append values with validity bytes" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const vals = [_]i32{ 10, 20, 30, 40 };
    const valid = [_]u8{ 1, 0, 1, 0 };
    try b.appendValues(&vals, &valid);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 2), arr.nullCount());
    try std.testing.expectEqual(@as(i32, 10), arr.value(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expectEqual(@as(i32, 30), arr.value(2));
    try std.testing.expect(arr.isNull(3));
}

test "NumericBuilder append values with bitmap" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const vals = [_]i32{ 10, 20, 30, 40 };
    const validity = [_]u8{0b01010000};
    try b.appendValuesBitmap(&vals, &validity, 4);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(arr.isValid(2));
    try std.testing.expect(arr.isNull(3));
}

test "NumericBuilder rejects short validity inputs" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try std.testing.expectError(error.ValidityBufferTooSmall, b.appendValues(&.{ 1, 2 }, &.{1}));
    try std.testing.expectError(error.ValidityBufferTooSmall, b.appendValuesBitmap(&.{ 1, 2 }, &.{}, 0));
}

test "NumericBuilder append values with multi byte bitmap" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const n = 80;
    var vals: [n]i32 = undefined;
    const validity_bytes = [_]u8{0b01010101} ** 10;
    for (&vals, 0..) |*v, i| v.* = @intCast(i);

    try b.appendValuesBitmap(&vals, &validity_bytes, 0);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, n / 2), arr.nullCount());
    for (0..n) |i| {
        const expect_valid = i % 2 == 0;
        try std.testing.expectEqual(expect_valid, arr.isValid(i));
        if (expect_valid) try std.testing.expectEqual(@as(i32, @intCast(i)), arr.value(i));
    }
}

test "NumericBuilder reset reuses builder" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ 1, 2, 3 });
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.len);
    try std.testing.expect(b.values == null);

    try b.append(99);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(i32).fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqual(@as(i32, 99), arr.value(0));
}

test "NumericBuilder appendEmptyValue and appendEmptyValues" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.appendEmptyValue();
    try b.append(7);
    try b.appendEmptyValues(2);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 0), arr.nullCount());
    try std.testing.expectEqual(@as(i32, 0), arr.value(0));
    try std.testing.expectEqual(@as(i32, 7), arr.value(1));
    try std.testing.expectEqual(@as(i32, 0), arr.value(2));
    try std.testing.expectEqual(@as(i32, 0), arr.value(3));
}

test "NumericBuilder kMinBuilderCapacity floor" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.reserve(1);
    try std.testing.expect(b.values.?.capacity >= builder_base.kMinBuilderCapacity * @sizeOf(i32));
}
