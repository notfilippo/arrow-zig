// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Binary and UTF8 builders.
//!
//! Builders append byte ranges into a values buffer and record offsets for each
//! slot. UTF8 builders validate input before appending.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const bitmap = @import("../bitmap.zig");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array = @import("../array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("../buffer.zig").Buffer;
const builder_base = @import("base.zig");

pub const BinaryBuilderError = Allocator.Error || checked.Error || error{ InvalidByteWidth, InvalidUtf8 };

pub fn VarBinaryBuilder(comptime kind: array.VarBinaryKind) type {
    const Offset = switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = array.VarBinaryArray(kind);
        pub const Error = BinaryBuilderError;

        allocator: Allocator,
        offsets: offset_data.Builder(Offset),
        values: ?*Buffer,
        validity: bitmap.BitmapBuilder,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .offsets = offset_data.Builder(Offset).init(),
                .values = null,
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        /// Release all held memory and return to the post-`init` state.
        pub fn reset(self: *Self) void {
            self.offsets.deinit();
            if (self.values) |buf| buf.deinit();
            self.values = null;
            self.validity.deinit();
            self.len = 0;
        }

        pub fn reserve(self: *Self, additional: usize, additional_bytes: usize) Error!void {
            if (additional == 0 and additional_bytes == 0) return;
            const new_len = try checked.add(self.len, additional);
            const capped_len = @max(new_len, builder_base.kMinBuilderCapacity);
            try self.offsets.reserveSlots(self.allocator, try checked.add(capped_len, 1));

            const values = try self.ensureValues();
            try values.reserve(try checked.add(values.size, additional_bytes));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            if (comptime kind == .utf8 or kind == .large_utf8) {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            }
            try self.appendUnchecked(bytes);
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) Error!void {
            try self.appendUnchecked(bytes);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.reserve(1, 0);
            const values = self.values.?;
            try self.offsets.append(self.allocator, values.size);
            self.validity.unsafeAppend(false);
            self.len += 1;
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n, 0);
            const values = self.values.?;
            try self.offsets.appendRepeat(self.allocator, n, values.size);
            self.validity.unsafeAppendN(false, n);
            self.len = try checked.add(self.len, n);
        }

        /// Append a valid empty-bytes slot.
        pub fn appendEmptyValue(self: *Self) Error!void {
            return self.appendBytes("");
        }

        /// Append `n` valid empty-bytes slots.
        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n, 0);
            const values = self.values.?;
            try self.offsets.appendRepeat(self.allocator, n, values.size);
            self.validity.unsafeAppendN(true, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        /// Finish the builder and transfer the result to the caller.
        /// Caller owns the returned data and must call `deinit`.
        pub fn finish(self: *Self) Error!*ArrayData {
            const n = self.len;
            const null_count = self.validity.false_count;
            self.len = 0;

            const offsets_buf = try self.offsets.finish(self.allocator);
            errdefer offsets_buf.deinit();
            const values_buf = try self.finishValues();
            errdefer values_buf.deinit();
            const validity_buf = try self.validity.finishNullable(self.allocator);
            errdefer if (validity_buf) |buf| buf.deinit();

            return ArrayData.initOwned(self.allocator, dataTypeForKind(kind), n, 0, null_count, &.{ validity_buf, offsets_buf, values_buf }, &.{}, null);
        }

        fn appendUnchecked(self: *Self, bytes: []const u8) Error!void {
            try self.reserve(1, bytes.len);
            const values = self.values.?;
            const end = try checked.add(values.size, bytes.len);
            try offset_data.ensureRange(Offset, end);
            @memcpy(values.data[values.size..end], bytes);
            values.size = end;

            try self.offsets.append(self.allocator, end);
            self.validity.unsafeAppend(true);
            self.len += 1;
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

pub const BinaryBuilder = VarBinaryBuilder(.binary);
pub const Utf8Builder = VarBinaryBuilder(.utf8);
pub const LargeBinaryBuilder = VarBinaryBuilder(.large_binary);
pub const LargeUtf8Builder = VarBinaryBuilder(.large_utf8);

pub const FixedSizeBinaryBuilder = struct {
    pub const Array = array.FixedSizeBinaryArray;
    pub const Error = BinaryBuilderError;

    allocator: Allocator,
    byte_width: usize,
    values: ?*Buffer,
    validity: bitmap.BitmapBuilder,
    len: usize,

    pub fn init(allocator: Allocator, byte_width: usize) FixedSizeBinaryBuilder {
        return .{
            .allocator = allocator,
            .byte_width = byte_width,
            .values = null,
            .validity = bitmap.BitmapBuilder.init(),
            .len = 0,
        };
    }

    pub fn deinit(self: *FixedSizeBinaryBuilder) void {
        self.reset();
    }

    pub fn reset(self: *FixedSizeBinaryBuilder) void {
        if (self.values) |buf| buf.deinit();
        self.values = null;
        self.validity.deinit();
        self.len = 0;
    }

    pub fn reserve(self: *FixedSizeBinaryBuilder, additional: usize) Error!void {
        if (additional == 0) return;
        const values = try self.ensureValues();
        const byte_len = try checked.mul(additional, self.byte_width);
        try values.reserve(try checked.add(values.size, byte_len));
        try self.validity.ensureCapacityForBits(self.allocator, additional);
    }

    pub fn append(self: *FixedSizeBinaryBuilder, bytes: []const u8) Error!void {
        if (bytes.len != self.byte_width) return error.InvalidByteWidth;
        try self.appendUnchecked(bytes);
    }

    pub fn appendBytes(self: *FixedSizeBinaryBuilder, bytes: []const u8) Error!void {
        try self.append(bytes);
    }

    pub fn appendNull(self: *FixedSizeBinaryBuilder) Error!void {
        try self.appendNulls(1);
    }

    pub fn appendNulls(self: *FixedSizeBinaryBuilder, n: usize) Error!void {
        if (n == 0) return;
        try self.reserve(n);
        const values = self.values.?;
        const byte_len = try checked.mul(n, self.byte_width);
        const end = try checked.add(values.size, byte_len);
        if (byte_len != 0) @memset(values.data[values.size..end], 0);
        values.size = end;
        self.validity.unsafeAppendN(false, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn appendEmptyValue(self: *FixedSizeBinaryBuilder) Error!void {
        try self.appendEmptyValues(1);
    }

    pub fn appendEmptyValues(self: *FixedSizeBinaryBuilder, n: usize) Error!void {
        if (n == 0) return;
        try self.reserve(n);
        const values = self.values.?;
        const byte_len = try checked.mul(n, self.byte_width);
        const end = try checked.add(values.size, byte_len);
        if (byte_len != 0) @memset(values.data[values.size..end], 0);
        values.size = end;
        self.validity.unsafeAppendN(true, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn length(self: FixedSizeBinaryBuilder) usize {
        return self.len;
    }

    pub fn finish(self: *FixedSizeBinaryBuilder) Error!*ArrayData {
        const n = self.len;
        const null_count = self.validity.false_count;
        self.len = 0;

        const values_buf = try self.finishValues();
        errdefer values_buf.deinit();
        const validity_buf = try self.validity.finishNullable(self.allocator);
        errdefer if (validity_buf) |buf| buf.deinit();

        const ty = datatype.DataType{ .fixed_size_binary = .{ .byte_width = self.byte_width } };
        return ArrayData.initOwned(self.allocator, ty, n, 0, null_count, &.{ validity_buf, values_buf }, &.{}, null);
    }

    fn appendUnchecked(self: *FixedSizeBinaryBuilder, bytes: []const u8) Error!void {
        try self.reserve(1);
        const values = self.values.?;
        const end = try checked.add(values.size, bytes.len);
        if (bytes.len != 0) @memcpy(values.data[values.size..end], bytes);
        values.size = end;
        self.validity.unsafeAppend(true);
        self.len += 1;
    }

    fn ensureValues(self: *FixedSizeBinaryBuilder) Error!*Buffer {
        if (self.values == null) self.values = try Buffer.allocate(self.allocator, 0);
        return self.values.?;
    }

    fn finishValues(self: *FixedSizeBinaryBuilder) Error!*Buffer {
        const values = if (self.values) |buf| blk: {
            self.values = null;
            break :blk buf;
        } else try Buffer.allocate(self.allocator, 0);
        values.freeze();
        return values;
    }
};

fn dataTypeForKind(comptime kind: array.VarBinaryKind) datatype.DataType {
    return switch (kind) {
        .binary => .binary,
        .utf8 => .utf8,
        .large_binary => .large_binary,
        .large_utf8 => .large_utf8,
    };
}

test "BinaryBuilder basic nulls and slices" {
    const allocator = std.testing.allocator;
    var b = BinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("ab");
    try b.appendNull();
    try b.append("cde");
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.BinaryArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqualStrings("ab", arr.valueBytes(0));
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqualStrings("cde", arr.value(2));
}

test "BinaryBuilder all valid and reuse" {
    const allocator = std.testing.allocator;
    var b = BinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("a");
    try b.append("");
    try b.append("bc");
    const data1 = try b.finish();
    defer data1.deinit();
    const arr1 = try array.BinaryArray.fromData(data1);
    try std.testing.expect(data1.buffers[0] == null);
    try std.testing.expectEqualStrings("", arr1.valueBytes(1));
    const arr1_sliced = @TypeOf(arr1){ .view = arr1.view.slice(1, 99) };
    try std.testing.expectEqualStrings("bc", arr1_sliced.valueBytes(1));

    try b.append("two");
    try b.append("three");
    const data2 = try b.finish();
    defer data2.deinit();
    const arr2 = try array.BinaryArray.fromData(data2);
    try std.testing.expectEqualStrings("two", arr2.valueBytes(0));
    try std.testing.expectEqualStrings("three", arr2.valueBytes(1));
}

test "Utf8Builder validates input" {
    const allocator = std.testing.allocator;
    var b = Utf8Builder.init(allocator);
    defer b.deinit();

    try b.append("hello");
    const invalid = [_]u8{0xc0};
    try std.testing.expectError(error.InvalidUtf8, b.append(&invalid));

    const data = try b.finish();
    defer data.deinit();
    try data.validate();
    const arr = try array.Utf8Array.fromData(data);
    try std.testing.expectEqualStrings("hello", arr.value(0));
}

test "LargeBinaryBuilder uses large offsets" {
    const allocator = std.testing.allocator;
    var b = LargeBinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("alpha");
    try b.append("beta");
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.LargeBinaryArray.fromData(data);
    try std.testing.expectEqual(.large_binary, arr.view.base.data.type);
    try std.testing.expectEqualStrings("alpha", arr.valueBytes(0));
    try std.testing.expectEqualStrings("beta", arr.valueBytes(1));
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(i64)), data.buffers[1].?.size);
}

test "FixedSizeBinaryBuilder builds fixed width bytes" {
    const allocator = std.testing.allocator;
    var b = FixedSizeBinaryBuilder.init(allocator, 3);
    defer b.deinit();

    try b.append("abc");
    try b.appendNull();
    try b.append("ghi");
    try b.appendEmptyValue();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.FixedSizeBinaryArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqualStrings("abc", arr.valueBytes(0));
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqualStrings("ghi", arr.value(2));
    try std.testing.expectEqualStrings(&[_]u8{ 0, 0, 0 }, arr.valueBytes(3));
}

test "FixedSizeBinaryBuilder rejects wrong width and reuses state" {
    const allocator = std.testing.allocator;
    var b = FixedSizeBinaryBuilder.init(allocator, 2);
    defer b.deinit();

    try std.testing.expectError(error.InvalidByteWidth, b.append("a"));
    try b.append("ab");
    const data1 = try b.finish();
    defer data1.deinit();
    const arr1 = try array.FixedSizeBinaryArray.fromData(data1);
    try std.testing.expectEqualStrings("ab", arr1.valueBytes(0));

    try b.appendEmptyValues(2);
    const data2 = try b.finish();
    defer data2.deinit();
    try data2.validate();
    const arr2 = try array.FixedSizeBinaryArray.fromData(data2);
    try std.testing.expect(data2.buffers[0] == null);
    try std.testing.expectEqualStrings(&[_]u8{ 0, 0 }, arr2.valueBytes(1));
}
