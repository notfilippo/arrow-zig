// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Binary and UTF8 builders.
//!
//! Builders append byte ranges into a values buffer and record offsets for each
//! slot. UTF8 builders validate input before appending.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array = @import("../array.zig");
const array_binary = @import("../array/binary.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("../buffer.zig").Buffer;
const common = @import("common.zig");

pub const BinaryBuilderError = Allocator.Error || checked.Error || error{ InvalidByteWidth, InvalidUtf8 };

pub fn VarBinaryBuilder(comptime kind: array_binary.VarBinaryKind) type {
    const Offset = switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = array_binary.VarBinaryArray(kind);
        pub const Error = BinaryBuilderError;

        allocator: Allocator,
        offsets: offset_data.Builder(Offset),
        values: ?*Buffer,
        slots: common.Slots,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .offsets = offset_data.Builder(Offset).init(),
                .values = null,
                .slots = common.Slots.init(),
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
            self.slots.deinit();
        }

        pub fn reserve(self: *Self, additional: usize, additional_bytes: usize) Error!void {
            if (additional == 0 and additional_bytes == 0) return;
            const new_len = try checked.add(self.slots.len, additional);
            const capped_len = @max(new_len, common.kMinBuilderCapacity);
            try self.offsets.reserveSlots(self.allocator, try checked.add(capped_len, 1));

            const values = try self.ensureValues();
            try values.reserve(try checked.add(values.size, additional_bytes));
            try self.slots.reserve(self.allocator, additional);
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            if (comptime kind == .utf8 or kind == .large_utf8) {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            }
            try self.appendUnchecked(bytes);
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) Error!void {
            try self.append(bytes);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.reserve(1, 0);
            const values = self.values.?;
            try self.offsets.append(self.allocator, values.size);
            self.slots.unsafeAppend(false);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n, 0);
            const values = self.values.?;
            try self.offsets.appendRepeat(self.allocator, n, values.size);
            try self.slots.unsafeAppendN(false, n);
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
            try self.slots.unsafeAppendN(true, n);
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        /// Finish the builder and transfer the result to the caller.
        /// Caller owns the returned data and must call `deinit`.
        pub fn finish(self: *Self) Error!*ArrayData {
            const offsets_buf = try self.offsets.finish(self.allocator);
            errdefer offsets_buf.deinit();
            const values_buf = try self.finishValues();
            errdefer values_buf.deinit();
            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            return ArrayData.initOwned(self.allocator, dataTypeForKind(kind), slots.len, 0, slots.null_count, &.{ slots.validity, offsets_buf, values_buf }, &.{}, null);
        }

        fn appendUnchecked(self: *Self, bytes: []const u8) Error!void {
            try self.reserve(1, bytes.len);
            const values = self.values.?;
            const end = try checked.add(values.size, bytes.len);
            try offset_data.ensureRange(Offset, end);
            @memcpy(values.data[values.size..end], bytes);
            values.size = end;

            try self.offsets.append(self.allocator, end);
            self.slots.unsafeAppend(true);
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

const BinaryViewKind = enum {
    binary_view,
    utf8_view,
};

fn BinaryViewBuilderType(comptime kind: BinaryViewKind) type {
    return struct {
        const Self = @This();
        pub const Array = switch (kind) {
            .binary_view => array.BinaryViewArray,
            .utf8_view => array.Utf8ViewArray,
        };
        pub const Error = BinaryBuilderError;

        allocator: Allocator,
        views: ?*Buffer,
        values: ?*Buffer,
        slots: common.Slots,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .views = null,
                .values = null,
                .slots = common.Slots.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }

        pub fn reset(self: *Self) void {
            if (self.views) |buf| buf.deinit();
            if (self.values) |buf| buf.deinit();
            self.views = null;
            self.values = null;
            self.slots.deinit();
        }

        pub fn reserve(self: *Self, additional: usize, additional_bytes: usize) Error!void {
            if (additional == 0 and additional_bytes == 0) return;
            const new_len = try checked.add(self.slots.len, additional);
            const capped_len = @max(new_len, common.kMinBuilderCapacity);
            const views = try self.ensureViews();
            try views.reserve(try checked.mul(capped_len, 16));
            if (additional_bytes > 0) {
                const values = try self.ensureValues();
                try values.reserve(try checked.add(values.size, additional_bytes));
            }
            try self.slots.reserve(self.allocator, additional);
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            if (comptime kind == .utf8_view) {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            }
            try self.appendUnchecked(bytes);
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) Error!void {
            try self.append(bytes);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.reserve(1, 0);
            writeInlineView(self.nextViewSlot(), "");
            self.slots.unsafeAppend(false);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n, 0);
            for (0..n) |_| {
                writeInlineView(self.nextViewSlot(), "");
                self.slots.unsafeAppend(false);
            }
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.appendBytes("");
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.reserve(n, 0);
            for (0..n) |_| {
                writeInlineView(self.nextViewSlot(), "");
                self.slots.unsafeAppend(true);
            }
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const views_buf = try self.finishViews();
            errdefer views_buf.deinit();
            const values_buf = self.finishValues();
            errdefer if (values_buf) |buf| buf.deinit();
            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            var buffers = [_]?*Buffer{ slots.validity, views_buf, values_buf };
            const buffer_count: usize = if (values_buf == null) 2 else 3;
            return ArrayData.initOwned(self.allocator, dataTypeForViewKind(kind), slots.len, 0, slots.null_count, buffers[0..buffer_count], &.{}, null);
        }

        fn appendUnchecked(self: *Self, bytes: []const u8) Error!void {
            try offset_data.ensureRange(i32, bytes.len);
            if (bytes.len <= 12) {
                try self.reserve(1, 0);
                writeInlineView(self.nextViewSlot(), bytes);
            } else {
                try self.reserve(1, bytes.len);
                const values = self.values.?;
                const offset = values.size;
                try offset_data.ensureRange(i32, offset);
                const end = try checked.add(values.size, bytes.len);
                @memcpy(values.data[values.size..end], bytes);
                values.size = end;
                writeExternalView(self.nextViewSlot(), bytes, 0, @intCast(offset));
            }
            self.slots.unsafeAppend(true);
        }

        fn nextViewSlot(self: *Self) []u8 {
            const views = self.views.?;
            const start = views.size;
            views.size += 16;
            return views.data[start..][0..16];
        }

        fn ensureViews(self: *Self) Error!*Buffer {
            if (self.views == null) self.views = try Buffer.allocate(self.allocator, 0);
            return self.views.?;
        }

        fn ensureValues(self: *Self) Error!*Buffer {
            if (self.values == null) self.values = try Buffer.allocate(self.allocator, 0);
            return self.values.?;
        }

        fn finishViews(self: *Self) Error!*Buffer {
            const views = if (self.views) |buf| blk: {
                self.views = null;
                break :blk buf;
            } else try Buffer.allocate(self.allocator, 0);
            views.freeze();
            return views;
        }

        fn finishValues(self: *Self) ?*Buffer {
            const values = self.values orelse return null;
            self.values = null;
            if (values.size == 0) {
                values.deinit();
                return null;
            }
            values.freeze();
            return values;
        }
    };
}

pub const BinaryViewBuilder = BinaryViewBuilderType(.binary_view);
pub const Utf8ViewBuilder = BinaryViewBuilderType(.utf8_view);

pub const FixedSizeBinaryBuilder = struct {
    pub const Array = array.FixedSizeBinaryArray;
    pub const Error = BinaryBuilderError;

    allocator: Allocator,
    byte_width: usize,
    values: ?*Buffer,
    slots: common.Slots,

    pub fn init(allocator: Allocator, byte_width: usize) FixedSizeBinaryBuilder {
        return .{
            .allocator = allocator,
            .byte_width = byte_width,
            .values = null,
            .slots = common.Slots.init(),
        };
    }

    pub fn deinit(self: *FixedSizeBinaryBuilder) void {
        self.reset();
    }

    pub fn reset(self: *FixedSizeBinaryBuilder) void {
        if (self.values) |buf| buf.deinit();
        self.values = null;
        self.slots.deinit();
    }

    pub fn reserve(self: *FixedSizeBinaryBuilder, additional: usize) Error!void {
        if (additional == 0) return;
        const values = try self.ensureValues();
        const byte_len = try checked.mul(additional, self.byte_width);
        try values.reserve(try checked.add(values.size, byte_len));
        try self.slots.reserve(self.allocator, additional);
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
        try self.slots.unsafeAppendN(false, n);
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
        try self.slots.unsafeAppendN(true, n);
    }

    pub fn length(self: FixedSizeBinaryBuilder) usize {
        return self.slots.length();
    }

    pub fn finish(self: *FixedSizeBinaryBuilder) Error!*ArrayData {
        const values_buf = try self.finishValues();
        errdefer values_buf.deinit();
        const slots = try self.slots.finish(self.allocator);
        errdefer if (slots.validity) |buf| buf.deinit();

        const ty = datatype.DataType{ .fixed_size_binary = .{ .byte_width = self.byte_width } };
        return ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{ slots.validity, values_buf }, &.{}, null);
    }

    fn appendUnchecked(self: *FixedSizeBinaryBuilder, bytes: []const u8) Error!void {
        try self.reserve(1);
        const values = self.values.?;
        const end = try checked.add(values.size, bytes.len);
        if (bytes.len != 0) @memcpy(values.data[values.size..end], bytes);
        values.size = end;
        self.slots.unsafeAppend(true);
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

fn dataTypeForKind(comptime kind: array_binary.VarBinaryKind) datatype.DataType {
    return switch (kind) {
        .binary => .binary,
        .utf8 => .utf8,
        .large_binary => .large_binary,
        .large_utf8 => .large_utf8,
    };
}

fn dataTypeForViewKind(comptime kind: BinaryViewKind) datatype.DataType {
    return switch (kind) {
        .binary_view => .binary_view,
        .utf8_view => .utf8_view,
    };
}

fn writeInlineView(dst: []u8, bytes: []const u8) void {
    std.mem.writeInt(i32, dst[0..4], @intCast(bytes.len), .little);
    @memset(dst[4..16], 0);
    if (bytes.len != 0) @memcpy(dst[4..][0..bytes.len], bytes);
}

fn writeExternalView(dst: []u8, bytes: []const u8, buffer_index: i32, offset: i32) void {
    std.mem.writeInt(i32, dst[0..4], @intCast(bytes.len), .little);
    @memcpy(dst[4..8], bytes[0..4]);
    std.mem.writeInt(i32, dst[8..12], buffer_index, .little);
    std.mem.writeInt(i32, dst[12..16], offset, .little);
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

test "BinaryViewBuilder builds inline and out of line values" {
    const allocator = std.testing.allocator;
    var b = BinaryViewBuilder.init(allocator);
    defer b.deinit();

    try b.append("tiny");
    try b.append("0123456789abcdef");
    try b.appendNull();
    try b.appendEmptyValue();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.BinaryViewArray.fromData(data);
    try std.testing.expectEqualStrings("tiny", arr.valueBytes(0));
    try std.testing.expectEqualStrings("0123456789abcdef", arr.value(1));
    try std.testing.expect(arr.view.isNull(2));
    try std.testing.expectEqualStrings("", arr.valueBytes(3));
}

test "Utf8ViewBuilder validates input" {
    const allocator = std.testing.allocator;
    var b = Utf8ViewBuilder.init(allocator);
    defer b.deinit();

    try b.append("hello");
    const invalid = [_]u8{0xc0};
    try std.testing.expectError(error.InvalidUtf8, b.append(&invalid));
    try std.testing.expectError(error.InvalidUtf8, b.appendBytes(&invalid));

    const data = try b.finish();
    defer data.deinit();
    const arr = try array.Utf8ViewArray.fromData(data);
    try std.testing.expectEqualStrings("hello", arr.value(0));
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
    try std.testing.expectError(error.InvalidUtf8, b.appendBytes(&invalid));

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
