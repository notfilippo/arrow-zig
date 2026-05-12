const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bits = @import("bitmap_bits.zig");
const Buffer = @import("buffer.zig").Buffer;

pub const BitmapBuilderError = Allocator.Error || checked.Error;

pub const BitmapBuilder = struct {
    pub const Error = BitmapBuilderError;

    buf: ?*Buffer,
    len: usize,
    false_count: usize,

    pub fn init() BitmapBuilder {
        return .{ .buf = null, .len = 0, .false_count = 0 };
    }

    pub fn deinit(self: *BitmapBuilder) void {
        if (self.buf) |b| b.deinit();
        self.buf = null;
        self.len = 0;
        self.false_count = 0;
    }

    pub fn append(self: *BitmapBuilder, allocator: Allocator, valid: bool) Error!void {
        const byte_idx = self.len >> 3;
        const byte_needed = byte_idx + 1;
        try self.ensureBuf(allocator, byte_needed);
        const buf = self.buf.?;
        if (byte_needed > buf.size) buf.size = byte_needed;
        if (valid) {
            bits.setBit(buf.data[0..byte_needed], self.len);
        } else {
            bits.clearBit(buf.data[0..byte_needed], self.len);
            self.false_count += 1;
        }
        self.len += 1;
    }

    pub fn appendN(self: *BitmapBuilder, allocator: Allocator, valid: bool, n: usize) Error!void {
        if (n == 0) return;
        const new_len = try checked.add(self.len, n);
        const byte_needed = try bits.byteLenChecked(new_len);
        try self.ensureBuf(allocator, byte_needed);
        const buf = self.buf.?;
        if (byte_needed > buf.size) buf.size = byte_needed;
        bits.setBitsTo(buf.data[0..byte_needed], self.len, n, valid);
        if (!valid) self.false_count += n;
        self.len = new_len;
    }

    pub fn finish(self: *BitmapBuilder, allocator: Allocator) Error!*Buffer {
        if (self.buf) |buf| {
            buf.size = try bits.byteLenChecked(self.len);
            buf.freeze();
            self.buf = null;
            self.len = 0;
            self.false_count = 0;
            return buf;
        }
        const b = try Buffer.allocate(allocator, 0);
        b.freeze();
        return b;
    }

    pub fn finishNullable(self: *BitmapBuilder, allocator: Allocator) Error!?*Buffer {
        if (self.false_count == 0) {
            if (self.buf) |b| b.deinit();
            self.buf = null;
            self.len = 0;
            self.false_count = 0;
            return null;
        }
        return try self.finish(allocator);
    }

    pub fn ensureCapacityForBits(self: *BitmapBuilder, allocator: Allocator, additional: usize) Error!void {
        if (additional == 0) return;
        const needed = try bits.byteLenChecked(try checked.add(self.len, additional));
        if (needed == 0) return;
        if (self.buf == null) self.buf = try Buffer.allocate(allocator, 0);
        try self.buf.?.reserve(needed);
    }

    pub fn unsafeAppend(self: *BitmapBuilder, valid: bool) void {
        const buf = self.buf.?;
        const byte_idx = self.len >> 3;
        const byte_needed = byte_idx + 1;
        if (byte_needed > buf.size) buf.size = byte_needed;
        if (valid) {
            bits.setBit(buf.data[0..byte_needed], self.len);
        } else {
            bits.clearBit(buf.data[0..byte_needed], self.len);
            self.false_count += 1;
        }
        self.len += 1;
    }

    pub fn unsafeAppendN(self: *BitmapBuilder, valid: bool, n: usize) void {
        if (n == 0) return;
        const buf = self.buf.?;
        const new_len = self.len + n;
        const byte_needed = bits.byteLen(new_len);
        if (byte_needed > buf.size) buf.size = byte_needed;
        bits.setBitsTo(buf.data[0..byte_needed], self.len, n, valid);
        if (!valid) self.false_count += n;
        self.len = new_len;
    }

    pub fn unsafeAppendBits(self: *BitmapBuilder, src: []const u8, src_off: usize, n: usize) void {
        if (n == 0) return;
        const buf = self.buf.?;
        const new_len = self.len + n;
        const byte_needed = bits.byteLen(new_len);
        if (byte_needed > buf.size) buf.size = byte_needed;
        bits.copyBits(buf.data[0..byte_needed], self.len, src, src_off, n);
        self.false_count += n - bits.countSetBits(src, src_off, n);
        self.len = new_len;
    }

    fn ensureBuf(self: *BitmapBuilder, allocator: Allocator, byte_needed: usize) Error!void {
        if (self.buf == null) self.buf = try Buffer.allocate(allocator, 0);
        try self.buf.?.reserve(byte_needed);
    }
};

test "BitmapBuilder appends and finishes" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();

    try b.append(allocator, true);
    try b.append(allocator, false);
    try b.append(allocator, true);
    try std.testing.expectEqual(@as(usize, 1), b.false_count);
    try std.testing.expectEqual(@as(usize, 3), b.len);
    const owned = try b.finish(allocator);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.size);
    try std.testing.expect(bits.getBit(owned.dataSlice(), 0));
    try std.testing.expect(!bits.getBit(owned.dataSlice(), 1));
    try std.testing.expect(bits.getBit(owned.dataSlice(), 2));
}

test "BitmapBuilder appendN crosses bytes" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();

    try b.appendN(allocator, true, 10);
    try b.appendN(allocator, false, 3);
    try std.testing.expectEqual(@as(usize, 3), b.false_count);
    try std.testing.expectEqual(@as(usize, 13), b.len);
    const owned = try b.finish(allocator);
    defer owned.deinit();
    for (0..10) |i| try std.testing.expect(bits.getBit(owned.dataSlice(), i));
    for (10..13) |i| try std.testing.expect(!bits.getBit(owned.dataSlice(), i));
}

test "BitmapBuilder nullable and empty finish" {
    const allocator = std.testing.allocator;
    var empty = BitmapBuilder.init();
    const owned = try empty.finish(allocator);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.size);
    try std.testing.expect(!owned.is_mutable);

    var all_valid = BitmapBuilder.init();
    defer all_valid.deinit();
    try all_valid.appendN(allocator, true, 8);
    const result = try all_valid.finishNullable(allocator);
    try std.testing.expect(result == null);
}

test "BitmapBuilder overflow and unsafe append" {
    const allocator = std.testing.allocator;
    var overflow = BitmapBuilder.init();
    defer overflow.deinit();
    overflow.len = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, overflow.appendN(allocator, true, 1));

    var b = BitmapBuilder.init();
    defer b.deinit();
    try b.ensureCapacityForBits(allocator, 4);
    b.unsafeAppend(true);
    b.unsafeAppend(false);
    b.unsafeAppend(true);
    b.unsafeAppend(false);
    try std.testing.expectEqual(@as(usize, 2), b.false_count);
    const owned = try b.finish(allocator);
    defer owned.deinit();
    try std.testing.expect(bits.getBit(owned.dataSlice(), 0));
    try std.testing.expect(!bits.getBit(owned.dataSlice(), 1));
}

test "BitmapBuilder unsafeAppendBits" {
    const allocator = std.testing.allocator;
    const src = [_]u8{ 0b10110101, 0b01001010 };
    var b = BitmapBuilder.init();
    defer b.deinit();

    try b.ensureCapacityForBits(allocator, 13);
    b.unsafeAppend(true);
    b.unsafeAppendBits(&src, 0, 12);
    try std.testing.expectEqual(@as(usize, 13), b.len);
    try std.testing.expectEqual(12 - bits.countSetBits(&src, 0, 12), b.false_count);

    const owned = try b.finish(allocator);
    defer owned.deinit();
    try std.testing.expect(bits.getBit(owned.dataSlice(), 0));
    for (0..12) |i| {
        try std.testing.expectEqual(bits.getBit(&src, i), bits.getBit(owned.dataSlice(), 1 + i));
    }
}
