//! Boolean array builder.
//!
//! Values and validity are both stored as Arrow bitmaps, with null values
//! represented by false validity bits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;

pub const BooleanBuilderError = Allocator.Error || checked.Error || error{ValidityBufferTooSmall};

pub const BooleanBuilder = struct {
    pub const Error = BooleanBuilderError;

    allocator: Allocator,
    values: bitmap.BitmapBuilder,
    validity: bitmap.BitmapBuilder,
    len: usize,

    pub fn init(allocator: Allocator) BooleanBuilder {
        return .{
            .allocator = allocator,
            .values = bitmap.BitmapBuilder.init(),
            .validity = bitmap.BitmapBuilder.init(),
            .len = 0,
        };
    }

    pub fn deinit(self: *BooleanBuilder) void {
        self.values.deinit();
        self.validity.deinit();
        self.len = 0;
    }

    pub fn reserve(self: *BooleanBuilder, additional: usize) Error!void {
        if (additional == 0) return;
        try self.values.ensureCapacityForBits(self.allocator, additional);
        try self.validity.ensureCapacityForBits(self.allocator, additional);
    }

    pub fn append(self: *BooleanBuilder, v: bool) Error!void {
        try self.reserve(1);
        self.unsafeAppend(v);
    }

    pub fn appendNull(self: *BooleanBuilder) Error!void {
        try self.reserve(1);
        self.unsafeAppendNull();
    }

    pub fn appendNulls(self: *BooleanBuilder, n: usize) Error!void {
        if (n == 0) return;
        try self.reserve(n);
        self.values.unsafeAppendN(false, n);
        self.validity.unsafeAppendN(false, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn appendSlice(self: *BooleanBuilder, vs: []const bool) Error!void {
        if (vs.len == 0) return;
        try self.reserve(vs.len);
        for (vs) |v| self.values.unsafeAppend(v);
        self.validity.unsafeAppendN(true, vs.len);
        self.len = try checked.add(self.len, vs.len);
    }

    pub fn appendValues(self: *BooleanBuilder, vs: []const bool, valid_bytes: ?[]const u8) Error!void {
        if (vs.len == 0) return;
        if (valid_bytes == null) return self.appendSlice(vs);
        const vb = valid_bytes.?;
        if (vb.len < vs.len) return error.ValidityBufferTooSmall;
        try self.reserve(vs.len);
        for (vs, 0..) |v, i| {
            self.values.unsafeAppend(v);
            self.validity.unsafeAppend(vb[i] != 0);
        }
        self.len = try checked.add(self.len, vs.len);
    }

    pub fn appendValuesBitmap(self: *BooleanBuilder, vs: []const bool, validity: []const u8, validity_offset: usize) Error!void {
        if (vs.len == 0) return;
        const needed = try bitmap.byteLenChecked(try checked.add(validity_offset, vs.len));
        if (validity.len < needed) return error.ValidityBufferTooSmall;
        try self.reserve(vs.len);
        for (vs) |v| self.values.unsafeAppend(v);
        self.validity.unsafeAppendBits(validity, validity_offset, vs.len);
        self.len = try checked.add(self.len, vs.len);
    }

    pub fn length(self: BooleanBuilder) usize {
        return self.len;
    }

    /// Finish the builder and transfer the result to the caller.
    /// Caller owns the returned data and must call `deinit`.
    pub fn finish(self: *BooleanBuilder) Error!*ArrayData {
        const n = self.len;
        const null_count = self.validity.false_count;
        self.len = 0;

        const values_buf = try self.values.finish(self.allocator);
        errdefer values_buf.deinit();
        const validity_buf: ?*Buffer = try self.validity.finishNullable(self.allocator);
        errdefer if (validity_buf) |buf| buf.deinit();

        return ArrayData.initOwned(self.allocator, .bool, n, 0, null_count, &.{ validity_buf, values_buf }, &.{}, null);
    }

    fn unsafeAppend(self: *BooleanBuilder, v: bool) void {
        self.values.unsafeAppend(v);
        self.validity.unsafeAppend(true);
        self.len += 1;
    }

    fn unsafeAppendNull(self: *BooleanBuilder) void {
        self.values.unsafeAppend(false);
        self.validity.unsafeAppend(false);
        self.len += 1;
    }
};

test "BooleanBuilder basic append and nulls" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.append(true);
    try b.appendNull();
    try b.append(false);
    try b.append(true);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.null_count);
    try std.testing.expect(arr.value(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(!arr.value(2));
}

test "BooleanBuilder append values with validity bytes" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const vals = [_]bool{ true, false, true, false };
    const valid = [_]u8{ 1, 1, 0, 1 };
    try b.appendValues(&vals, &valid);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());
    try std.testing.expect(arr.value(0));
    try std.testing.expect(!arr.value(1));
    try std.testing.expect(arr.isNull(2));
    try std.testing.expect(!arr.value(3));
}

test "BooleanBuilder append values all valid" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.appendValues(&.{ true, false, true }, null);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expect(data.buffers[0] == null);
    try std.testing.expectEqual(@as(usize, 2), arr.trueCount());
}

test "BooleanBuilder append values with bitmaps" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const vals = [_]bool{ true, true, true, true };
    const validity = [_]u8{0b00000101};
    try b.appendValuesBitmap(&vals, &validity, 0);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(arr.isValid(2));
    try std.testing.expect(arr.isNull(3));
    try std.testing.expectEqual(@as(usize, 2), arr.trueCount());
}

test "BooleanBuilder rejects short validity inputs" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    try std.testing.expectError(error.ValidityBufferTooSmall, b.appendValues(&.{ true, false }, &.{1}));
    try std.testing.expectError(error.ValidityBufferTooSmall, b.appendValuesBitmap(&.{ true, false }, &.{}, 0));
}

test "BooleanBuilder append values with multi byte bitmap" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const n = 80;
    var vals: [n]bool = undefined;
    const validity_bytes = [_]u8{0b01010101} ** 10;
    for (&vals, 0..) |*v, i| v.* = i % 3 == 0;

    try b.appendValuesBitmap(&vals, &validity_bytes, 0);
    const data = try b.finish();
    defer data.deinit();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, n / 2), arr.nullCount());
    for (0..n) |i| {
        const expect_valid = i % 2 == 0;
        try std.testing.expectEqual(expect_valid, arr.isValid(i));
        if (expect_valid) try std.testing.expectEqual(i % 3 == 0, arr.value(i));
    }
}
