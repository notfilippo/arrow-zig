// Bit-level helpers and BitmapBuilder. Mirrors arrow/util/bit_util.h and
// arrow/util/bitmap_ops.h. All bitmaps use LSB-first packing per Arrow spec.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const Buffer = @import("buffer.zig").Buffer;

// Lookup tables for bit operations.
const bitmask = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };
const flipped_bitmask = [8]u8{ 254, 253, 251, 247, 239, 223, 191, 127 };
// preceding_bitmask[i] = (1<<i)-1 = bits 0..i-1 (i bits set)
const preceding_bitmask = [8]u8{ 0, 1, 3, 7, 15, 31, 63, 127 };
// trailing_bitmask[i] = ~((1<<i)-1) = bits i..7
const trailing_bitmask = [8]u8{ 255, 254, 252, 248, 240, 224, 192, 128 };

pub const unknown_null_count: usize = std.math.maxInt(usize);

/// Bytes needed to store n bits, rounded up.
pub inline fn byteLen(n: usize) usize {
    return byteLenChecked(n) catch unreachable;
}

pub fn byteLenChecked(n: usize) checked.Error!usize {
    return checked.bytesForBits(n);
}

pub inline fn getBit(bits: []const u8, i: usize) bool {
    return (bits[i >> 3] >> @intCast(i & 7)) & 1 == 1;
}

pub inline fn setBit(bits: []u8, i: usize) void {
    bits[i >> 3] |= bitmask[i & 7];
}

pub inline fn clearBit(bits: []u8, i: usize) void {
    bits[i >> 3] &= flipped_bitmask[i & 7];
}

pub inline fn setBitTo(bits: []u8, i: usize, value: bool) void {
    if (value) setBit(bits, i) else clearBit(bits, i);
}

inline fn toggleBit(bits: []u8, i: usize) void {
    bits[i >> 3] ^= bitmask[i & 7];
}

/// Set or clear bits [start, start+n) to `value`. LSB-first; no bounds check.
/// Uses byte-level fill for the aligned middle section.
pub fn setBitsTo(bits: []u8, start: usize, n: usize, value: bool) void {
    if (n == 0) return;
    const end = start + n;
    const fill: u8 = if (value) 0xFF else 0x00;
    const first_byte = start / 8;
    const last_byte = (end - 1) / 8;

    if (first_byte == last_byte) {
        const lo = start % 8;
        const mask = if (end % 8 == 0)
            trailing_bitmask[lo]
        else
            trailing_bitmask[lo] & preceding_bitmask[end % 8];
        if (value) bits[first_byte] |= mask else bits[first_byte] &= ~mask;
        return;
    }

    // first byte: bits [start%8 .. 7]
    if (start % 8 != 0) {
        const m = trailing_bitmask[start % 8];
        if (value) bits[first_byte] |= m else bits[first_byte] &= ~m;
    } else {
        bits[first_byte] = fill;
    }

    // full middle bytes
    if (first_byte + 1 < last_byte)
        @memset(bits[first_byte + 1 .. last_byte], fill);

    // last byte: bits [0 .. (end-1)%8]
    if (end % 8 != 0) {
        const m = preceding_bitmask[end % 8];
        if (value) bits[last_byte] |= m else bits[last_byte] &= ~m;
    } else {
        bits[last_byte] = fill;
    }
}

/// Count set bits in bits[bit_offset .. bit_offset+bit_len). LSB-first.
pub fn countSetBits(bits: []const u8, bit_offset: usize, bit_len: usize) usize {
    if (bit_len == 0) return 0;

    var count: usize = 0;
    var done: usize = 0;
    while (done + 64 <= bit_len) : (done += 64) {
        count += @as(usize, @popCount(readWord64(bits, bit_offset + done)));
    }
    count += countSetBitsScalar(bits, bit_offset + done, bit_len - done);
    return count;
}

inline fn readWord64(bits: []const u8, bit_pos: usize) u64 {
    const byte_idx = bit_pos / 8;
    const shift_bits = bit_pos & 7;
    const lo = std.mem.readInt(u64, bits[byte_idx..][0..8], .little);
    if (shift_bits == 0) return lo;
    const shift: u6 = @intCast(shift_bits);
    const rshift: u6 = @intCast(64 - shift_bits);
    return (lo >> shift) | (@as(u64, bits[byte_idx + 8]) << rshift);
}

inline fn writeWord64(bits: []u8, bit_pos: usize, word: u64) void {
    const byte_idx = bit_pos / 8;
    const shift_bits = bit_pos & 7;
    if (shift_bits == 0) {
        std.mem.writeInt(u64, bits[byte_idx..][0..8], word, .little);
        return;
    }

    const shift: u6 = @intCast(shift_bits);
    const rshift: u6 = @intCast(64 - shift_bits);
    const keep_low = bits[byte_idx] & preceding_bitmask[shift_bits];
    std.mem.writeInt(u64, bits[byte_idx..][0..8], word << shift, .little);
    bits[byte_idx] |= keep_low;

    const high_mask = preceding_bitmask[shift_bits];
    const high_byte: u8 = @truncate(word >> rshift);
    bits[byte_idx + 8] = (bits[byte_idx + 8] & ~high_mask) | (high_byte & high_mask);
}

fn copyBitsScalar(dst: []u8, dst_off: usize, src: []const u8, src_off: usize, len: usize) void {
    for (0..len) |i| setBitTo(dst, dst_off + i, getBit(src, src_off + i));
}

fn countSetBitsScalar(bits: []const u8, bit_offset: usize, bit_len: usize) usize {
    var count: usize = 0;
    for (0..bit_len) |i| {
        if (getBit(bits, bit_offset + i)) count += 1;
    }
    return count;
}

/// Copy len bits from src[src_off..] to dst[dst_off..]. LSB-first; no bounds check.
pub fn copyBits(dst: []u8, dst_off: usize, src: []const u8, src_off: usize, len: usize) void {
    if (len == 0) return;

    if (((dst_off | src_off | len) & 7) == 0) {
        @memcpy(dst[dst_off / 8 ..][0 .. len / 8], src[src_off / 8 ..][0 .. len / 8]);
        return;
    }

    var done: usize = 0;
    while (done + 64 <= len) : (done += 64) {
        writeWord64(dst, dst_off + done, readWord64(src, src_off + done));
    }
    copyBitsScalar(dst, dst_off + done, src, src_off + done, len - done);
}

/// Invert bits[bit_offset .. bit_offset+bit_len) in place. LSB-first; no bounds check.
pub fn invertBits(bits: []u8, bit_offset: usize, bit_len: usize) void {
    if (bit_len == 0) return;

    var done: usize = 0;
    while (done + 64 <= bit_len) : (done += 64) {
        const pos = bit_offset + done;
        writeWord64(bits, pos, ~readWord64(bits, pos));
    }
    for (0..bit_len - done) |i| toggleBit(bits, bit_offset + done + i);
}

const BinaryOp = enum { @"and", @"or", xor, and_not, or_not };

inline fn applyBinaryOp(comptime op: BinaryOp, lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    return switch (op) {
        .@"and" => lhs & rhs,
        .@"or" => lhs | rhs,
        .xor => lhs ^ rhs,
        .and_not => lhs & ~rhs,
        .or_not => lhs | ~rhs,
    };
}

fn binaryBitsScalar(
    comptime op: BinaryOp,
    dst: []u8,
    dst_off: usize,
    lhs: []const u8,
    lhs_off: usize,
    rhs: []const u8,
    rhs_off: usize,
    len: usize,
) void {
    for (0..len) |i| {
        const lhs_bit: u8 = if (getBit(lhs, lhs_off + i)) 1 else 0;
        const rhs_bit: u8 = if (getBit(rhs, rhs_off + i)) 1 else 0;
        setBitTo(dst, dst_off + i, (applyBinaryOp(op, lhs_bit, rhs_bit) & 1) != 0);
    }
}

fn binaryBits(
    comptime op: BinaryOp,
    dst: []u8,
    dst_off: usize,
    lhs: []const u8,
    lhs_off: usize,
    rhs: []const u8,
    rhs_off: usize,
    len: usize,
) void {
    if (len == 0) return;

    var done: usize = 0;
    while (done + 64 <= len) : (done += 64) {
        writeWord64(
            dst,
            dst_off + done,
            applyBinaryOp(
                op,
                readWord64(lhs, lhs_off + done),
                readWord64(rhs, rhs_off + done),
            ),
        );
    }
    binaryBitsScalar(op, dst, dst_off + done, lhs, lhs_off + done, rhs, rhs_off + done, len - done);
}

/// dst range equals lhs AND rhs. LSB first. No bounds check.
pub fn andBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.@"and", dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

/// dst range equals lhs OR rhs. LSB first. No bounds check.
pub fn orBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.@"or", dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

/// dst range equals lhs XOR rhs. LSB first. No bounds check.
pub fn xorBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.xor, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

/// dst range equals lhs AND NOT rhs. LSB first. No bounds check.
pub fn andNotBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.and_not, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

/// dst range equals lhs OR NOT rhs. LSB first. No bounds check.
pub fn orNotBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.or_not, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

/// Count bits set in both input ranges. LSB first.
pub fn countAndSetBits(
    values: []const u8,
    value_off: usize,
    valid: []const u8,
    valid_off: usize,
    len: usize,
) usize {
    if (len == 0) return 0;

    var count: usize = 0;
    var done: usize = 0;
    while (done + 64 <= len) : (done += 64) {
        count += @as(usize, @popCount(
            readWord64(values, value_off + done) & readWord64(valid, valid_off + done),
        ));
    }
    for (0..len - done) |i| {
        if (getBit(values, value_off + done + i) and getBit(valid, valid_off + done + i)) count += 1;
    }
    return count;
}

/// Compute null count from validity bitmap, or return hint when it is already known.
/// Pass unknown_null_count as hint to force computation.
pub fn nullCountFor(validity_bytes: ?[]const u8, offset: usize, len: usize, hint: usize) usize {
    if (hint != unknown_null_count) return hint;
    const bytes = validity_bytes orelse return 0;
    return len - countSetBits(bytes, offset, len);
}

/// Bit-level buffer builder backed by a reference-counted Buffer.
/// Tracks the false-bit count so `finishNullable` can skip allocating a validity
/// bitmap entirely when all appended bits are true.
pub const BitmapBuilder = struct {
    buf: ?*Buffer,
    len: usize,
    false_count: usize,

    pub fn init() BitmapBuilder {
        return .{ .buf = null, .len = 0, .false_count = 0 };
    }

    pub fn deinit(self: *BitmapBuilder) void {
        if (self.buf) |b| b.release();
        self.buf = null;
    }

    /// Append one bit, allocating if needed.
    pub fn append(self: *BitmapBuilder, allocator: Allocator, valid: bool) !void {
        const byte_idx = self.len >> 3;
        const byte_needed = byte_idx + 1;
        try self.ensureBuf(allocator, byte_needed);
        const buf = self.buf.?;
        if (byte_needed > buf.size) buf.size = byte_needed;
        if (valid) {
            setBit(buf.data[0..byte_needed], self.len);
        } else {
            clearBit(buf.data[0..byte_needed], self.len);
            self.false_count += 1;
        }
        self.len += 1;
    }

    /// Append n identical bits, allocating if needed.
    pub fn appendN(self: *BitmapBuilder, allocator: Allocator, valid: bool, n: usize) !void {
        if (n == 0) return;
        const new_len = try checked.add(self.len, n);
        const byte_needed = try byteLenChecked(new_len);
        try self.ensureBuf(allocator, byte_needed);
        const buf = self.buf.?;
        if (byte_needed > buf.size) buf.size = byte_needed;
        setBitsTo(buf.data[0..byte_needed], self.len, n, valid);
        if (!valid) self.false_count += n;
        self.len = new_len;
    }

    /// Freeze and return the backing Buffer (refcount=1). Resets the builder.
    /// If nothing was appended, returns a zero-size frozen buffer.
    pub fn finish(self: *BitmapBuilder, allocator: Allocator) !*Buffer {
        if (self.buf) |buf| {
            buf.size = try byteLenChecked(self.len);
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

    /// Like finish, but returns null when false_count == 0 (no nulls, no bitmap needed).
    /// Avoids the allocate-then-release pattern for the all-valid case.
    pub fn finishNullable(self: *BitmapBuilder, allocator: Allocator) !?*Buffer {
        if (self.false_count == 0) {
            if (self.buf) |b| b.release();
            self.buf = null;
            self.len = 0;
            return null;
        }
        return try self.finish(allocator);
    }

    /// Ensure capacity for `additional` more bits without advancing len.
    /// Must be called before unsafeAppend / unsafeAppendN.
    pub fn ensureCapacityForBits(self: *BitmapBuilder, allocator: Allocator, additional: usize) !void {
        if (additional == 0) return;
        const needed = try byteLenChecked(try checked.add(self.len, additional));
        if (needed == 0) return;
        if (self.buf == null) self.buf = try Buffer.allocate(allocator, 0);
        try self.buf.?.reserve(needed);
    }

    /// Append one bit without allocating. Caller must have called ensureCapacityForBits first.
    pub fn unsafeAppend(self: *BitmapBuilder, valid: bool) void {
        const buf = self.buf.?;
        const byte_idx = self.len >> 3;
        const byte_needed = byte_idx + 1;
        if (byte_needed > buf.size) buf.size = byte_needed;
        if (valid) {
            setBit(buf.data[0..byte_needed], self.len);
        } else {
            clearBit(buf.data[0..byte_needed], self.len);
            self.false_count += 1;
        }
        self.len += 1;
    }

    /// Append n bits without allocating. Caller must have called ensureCapacityForBits first.
    pub fn unsafeAppendN(self: *BitmapBuilder, valid: bool, n: usize) void {
        if (n == 0) return;
        const buf = self.buf.?;
        const new_len = self.len + n;
        const byte_needed = byteLen(new_len);
        if (byte_needed > buf.size) buf.size = byte_needed;
        setBitsTo(buf.data[0..byte_needed], self.len, n, valid);
        if (!valid) self.false_count += n;
        self.len = new_len;
    }

    /// Bulk-copy n bits from src[src_off..] without allocating.
    /// Caller must have called ensureCapacityForBits first.
    pub fn unsafeAppendBits(self: *BitmapBuilder, src: []const u8, src_off: usize, n: usize) void {
        if (n == 0) return;
        const buf = self.buf.?;
        const new_len = self.len + n;
        const byte_needed = byteLen(new_len);
        if (byte_needed > buf.size) buf.size = byte_needed;
        copyBits(buf.data[0..byte_needed], self.len, src, src_off, n);
        self.false_count += n - countSetBits(src, src_off, n);
        self.len = new_len;
    }

    fn ensureBuf(self: *BitmapBuilder, allocator: Allocator, byte_needed: usize) !void {
        if (self.buf == null) {
            self.buf = try Buffer.allocate(allocator, 0);
        }
        try self.buf.?.reserve(byte_needed);
    }
};

test "getBit / setBit / clearBit" {
    var buf = [_]u8{0} ** 4;
    setBit(&buf, 0);
    setBit(&buf, 7);
    setBit(&buf, 8);
    setBit(&buf, 23);
    try std.testing.expect(getBit(&buf, 0));
    try std.testing.expect(getBit(&buf, 7));
    try std.testing.expect(getBit(&buf, 8));
    try std.testing.expect(getBit(&buf, 23));
    try std.testing.expect(!getBit(&buf, 1));
    try std.testing.expect(!getBit(&buf, 9));
    clearBit(&buf, 7);
    try std.testing.expect(!getBit(&buf, 7));
}

test "setBitsTo single byte" {
    var buf = [_]u8{0} ** 2;
    setBitsTo(&buf, 2, 4, true); // bits 2..5
    try std.testing.expectEqual(@as(u8, 0b00111100), buf[0]);
    setBitsTo(&buf, 2, 4, false);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "setBitsTo crosses byte boundary" {
    var buf = [_]u8{0} ** 3;
    setBitsTo(&buf, 6, 6, true); // bits 6..11
    try std.testing.expectEqual(@as(u8, 0b11000000), buf[0]); // bits 6,7
    try std.testing.expectEqual(@as(u8, 0b00001111), buf[1]); // bits 8..11
}

test "setBitsTo full byte aligned" {
    var buf = [_]u8{0} ** 2;
    setBitsTo(&buf, 0, 16, true);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[1]);
    setBitsTo(&buf, 0, 16, false);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
}

test "countSetBits offset-zero" {
    var buf = [_]u8{0} ** 9; // 72 bits
    setBitsTo(&buf, 0, 72, true);
    try std.testing.expectEqual(@as(usize, 72), countSetBits(&buf, 0, 72));
    setBitsTo(&buf, 0, 72, false);
    try std.testing.expectEqual(@as(usize, 0), countSetBits(&buf, 0, 72));
    setBitsTo(&buf, 3, 5, true); // bits 3..7
    try std.testing.expectEqual(@as(usize, 5), countSetBits(&buf, 0, 72));
}

test "countSetBits with offset" {
    var buf = [_]u8{0} ** 3;
    setBitsTo(&buf, 0, 24, true);
    // All set: count in [4, 12) should be 8.
    try std.testing.expectEqual(@as(usize, 8), countSetBits(&buf, 4, 8));
    // Cross-byte range [6, 14): 2 bits in byte0 + 8 in byte1 + 0 in byte2 partial... wait
    // bits 6,7 in byte0, bits 8-13 in byte1 = 8 bits total
    try std.testing.expectEqual(@as(usize, 8), countSetBits(&buf, 6, 8));

    // Only bits 8..15 set, count [7, 11) = bits 8,9,10 (3 bits)
    @memset(&buf, 0);
    setBitsTo(&buf, 8, 8, true);
    try std.testing.expectEqual(@as(usize, 3), countSetBits(&buf, 7, 4));
}

test "countSetBits single byte range" {
    var buf = [_]u8{0b10110000};
    // bits 4,5,7 are set
    try std.testing.expectEqual(@as(usize, 2), countSetBits(&buf, 4, 3)); // bits 4,5,6 -> 2 set
    try std.testing.expectEqual(@as(usize, 3), countSetBits(&buf, 4, 4)); // bits 4,5,6,7 -> 3 set
}

test "countSetBits empty" {
    var buf = [_]u8{0xFF} ** 4;
    try std.testing.expectEqual(@as(usize, 0), countSetBits(&buf, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), countSetBits(&buf, 7, 0));
}

test "countSetBits unaligned multiword" {
    const allocator = std.testing.allocator;
    const n_bytes = 40;
    const buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(buf);

    for (buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 43 +% 19));

    const offset = 5;
    const len = 231;
    var slow: usize = 0;
    for (0..len) |i| {
        if (getBit(buf, offset + i)) slow += 1;
    }
    try std.testing.expectEqual(slow, countSetBits(buf, offset, len));
}

test "BitmapBuilder basic" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();
    try b.append(allocator, true);
    try b.append(allocator, false);
    try b.append(allocator, true);
    try std.testing.expectEqual(@as(usize, 1), b.false_count);
    try std.testing.expectEqual(@as(usize, 3), b.len);
    const owned = try b.finish(allocator);
    defer owned.release();
    try std.testing.expectEqual(@as(usize, 1), owned.size);
    try std.testing.expect(getBit(owned.dataSlice(), 0));
    try std.testing.expect(!getBit(owned.dataSlice(), 1));
    try std.testing.expect(getBit(owned.dataSlice(), 2));
}

test "BitmapBuilder appendN crosses byte boundary" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();
    try b.appendN(allocator, true, 10);
    try b.appendN(allocator, false, 3);
    try std.testing.expectEqual(@as(usize, 3), b.false_count);
    try std.testing.expectEqual(@as(usize, 13), b.len);
    try std.testing.expectEqual(@as(usize, 2), byteLen(13));
    const owned = try b.finish(allocator);
    defer owned.release();
    for (0..10) |i| try std.testing.expect(getBit(owned.dataSlice(), i));
    for (10..13) |i| try std.testing.expect(!getBit(owned.dataSlice(), i));
}

test "BitmapBuilder finish when empty" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    const owned = try b.finish(allocator);
    defer owned.release();
    try std.testing.expectEqual(@as(usize, 0), owned.size);
    try std.testing.expect(!owned.is_mutable);
}

test "BitmapBuilder finishNullable no-null returns null" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();
    try b.appendN(allocator, true, 8);
    const result = try b.finishNullable(allocator);
    try std.testing.expect(result == null);
}

test "BitmapBuilder appendN overflow" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();
    b.len = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, b.appendN(allocator, true, 1));
}

test "BitmapBuilder unsafeAppend" {
    const allocator = std.testing.allocator;
    var b = BitmapBuilder.init();
    defer b.deinit();
    try b.ensureCapacityForBits(allocator, 4);
    b.unsafeAppend(true);
    b.unsafeAppend(false);
    b.unsafeAppend(true);
    b.unsafeAppend(false);
    try std.testing.expectEqual(@as(usize, 2), b.false_count);
    const owned = try b.finish(allocator);
    defer owned.release();
    try std.testing.expect(getBit(owned.dataSlice(), 0));
    try std.testing.expect(!getBit(owned.dataSlice(), 1));
    try std.testing.expect(getBit(owned.dataSlice(), 2));
    try std.testing.expect(!getBit(owned.dataSlice(), 3));
}

test "copyBits byte-aligned" {
    var src = [_]u8{0b10110101};
    var dst = [_]u8{0} ** 1;
    copyBits(&dst, 0, &src, 0, 8);
    try std.testing.expectEqual(src[0], dst[0]);
}

test "copyBits with offset" {
    var src = [_]u8{ 0b11110000, 0b00001111 };
    var dst = [_]u8{0} ** 2;
    // copy bits 4..12 of src into bits 2..10 of dst
    copyBits(&dst, 2, &src, 4, 8);
    for (0..8) |i| {
        try std.testing.expectEqual(getBit(&src, 4 + i), getBit(&dst, 2 + i));
    }
}

test "copyBits length zero" {
    var src = [_]u8{0xFF};
    var dst = [_]u8{0};
    copyBits(&dst, 0, &src, 0, 0);
    try std.testing.expectEqual(@as(u8, 0), dst[0]);
}

test "invertBits byte-aligned" {
    var buf = [_]u8{ 0b10110101, 0b00001111 };
    invertBits(&buf, 0, 16);
    try std.testing.expectEqual(@as(u8, 0b01001010), buf[0]);
    try std.testing.expectEqual(@as(u8, 0b11110000), buf[1]);
}

test "invertBits partial range" {
    var buf = [_]u8{0b00001111};
    // invert bits 2..6 (4 bits)
    invertBits(&buf, 2, 4);
    // bits 2,3 were 1 -> 0; bits 4,5 were 1 -> 0; bits 0,1,6,7 unchanged
    // original: 0b00001111 = bits 0,1,2,3 set
    // invert [2,6): bits 2,3 flip (1->0), bits 4,5 flip (0->1)
    // result bits: 0=1,1=1,2=0,3=0,4=1,5=1,6=0,7=0 = 0b00110011
    try std.testing.expectEqual(@as(u8, 0b00110011), buf[0]);
}

test "invertBits single byte range" {
    var buf = [_]u8{0b11111111};
    invertBits(&buf, 0, 8);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "andBits basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};
    andBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b10001000), dst[0]);
}

test "orBits basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};
    orBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b11101110), dst[0]);
}

test "xorBits basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};
    xorBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b01100110), dst[0]);
}

test "andNotBits basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};
    andNotBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b01000100), dst[0]);
}

test "orNotBits basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};
    orNotBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b11011101), dst[0]);
}

test "andBits with offsets" {
    // lhs bits [4..8) = 0b1100 (bits 4,5 set); rhs bits [0..4) = 0b1010 (bits 1,3 set)
    const lhs = [_]u8{0b11000000}; // bits 6,7 set (= bits 6,7 in lhs)
    const rhs = [_]u8{0b00001010}; // bits 1,3 set
    var dst = [_]u8{0xFF};
    // and lhs[6..8) with rhs[0..2): lhs has bits 6,7; rhs has bit 1 (not 0)
    andBits(&dst, 0, &lhs, 6, &rhs, 0, 2);
    // lhs[6]=1 & rhs[0]=0 = 0; lhs[7]=1 & rhs[1]=1 = 1
    try std.testing.expect(!getBit(&dst, 0));
    try std.testing.expect(getBit(&dst, 1));
}

test "countAndSetBits" {
    const values = [_]u8{0b10110101}; // bits 0,2,4,5,7 set
    const valid = [_]u8{0b00111111}; // bits 0..5 valid
    // set AND valid: bits 0,2,4,5 => 4
    try std.testing.expectEqual(@as(usize, 4), countAndSetBits(&values, 0, &valid, 0, 8));
}

test "countAndSetBits with valid_off" {
    const values = [_]u8{0b11111111};
    const valid = [_]u8{ 0b00000000, 0b00001111 }; // bits 8..11 valid
    // count values[0..4] set AND valid[8..12]: 4 bits
    try std.testing.expectEqual(@as(usize, 4), countAndSetBits(&values, 0, &valid, 8, 4));
}

test "countAndSetBits with value_off" {
    const values = [_]u8{ 0b00000000, 0b00001111 };
    const valid = [_]u8{0b11111111};
    try std.testing.expectEqual(@as(usize, 4), countAndSetBits(&values, 8, &valid, 0, 4));
}

test "copyBits word-aligned multi-word" {
    // 100 bytes = 800 bits; verify fast path matches scalar reference.
    const allocator = std.testing.allocator;
    const n_bytes = 100;
    const src_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(src_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (src_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 73 +% 17));
    @memset(dst_fast, 0);
    @memset(dst_slow, 0);

    copyBits(dst_fast, 0, src_buf, 0, n_bytes * 8);
    for (0..n_bytes * 8) |i| {
        if (getBit(src_buf, i)) setBit(dst_slow, i) else clearBit(dst_slow, i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "copyBits aligned with head and tail partial" {
    // src_off=3, dst_off=3 -- same mod-8, crosses multiple bytes.
    const src = [_]u8{ 0b11111000, 0b11111111, 0b00000111 }; // bits 3..20 set
    var dst = [_]u8{0} ** 3;
    copyBits(&dst, 3, &src, 3, 13); // copy bits 3..15
    for (0..13) |i| {
        try std.testing.expectEqual(getBit(&src, 3 + i), getBit(&dst, 3 + i));
    }
    // Bits outside [3,16) in dst must be untouched (zeroes).
    try std.testing.expectEqual(@as(u8, 0), dst[0] & 0b00000111);
}

test "copyBits unaligned multiword" {
    const allocator = std.testing.allocator;
    const n_bytes = 40;
    const src = try allocator.alloc(u8, n_bytes);
    defer allocator.free(src);
    const fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(fast);
    const slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(slow);

    for (src, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 73 +% 17));
    @memset(fast, 0xA5);
    @memset(slow, 0xA5);

    const dst_off = 3;
    const src_off = 5;
    const len = 211;
    copyBits(fast, dst_off, src, src_off, len);
    copyBitsScalar(slow, dst_off, src, src_off, len);
    try std.testing.expectEqualSlices(u8, slow, fast);
}

test "invertBits unaligned multiword" {
    const allocator = std.testing.allocator;
    const n_bytes = 40;
    const fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(fast);
    const slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(slow);

    for (fast, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 31 +% 7));
    @memcpy(slow, fast);

    const offset = 5;
    const len = 211;
    invertBits(fast, offset, len);
    for (0..len) |i| toggleBit(slow, offset + i);
    try std.testing.expectEqualSlices(u8, slow, fast);
}

test "andBits word-aligned multi-word" {
    const allocator = std.testing.allocator;
    const n_bytes = 64;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0xFF);
    @memset(dst_slow, 0xFF);

    andBits(dst_fast, 0, lhs_buf, 0, rhs_buf, 0, n_bytes * 8);
    for (0..n_bytes * 8) |i| {
        const bit = getBit(lhs_buf, i) and getBit(rhs_buf, i);
        if (bit) setBit(dst_slow, i) else clearBit(dst_slow, i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "orBits word-aligned multi-word" {
    const allocator = std.testing.allocator;
    const n_bytes = 64;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0);
    @memset(dst_slow, 0);

    orBits(dst_fast, 0, lhs_buf, 0, rhs_buf, 0, n_bytes * 8);
    for (0..n_bytes * 8) |i| {
        const bit = getBit(lhs_buf, i) or getBit(rhs_buf, i);
        if (bit) setBit(dst_slow, i) else clearBit(dst_slow, i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "xorBits word-aligned multi-word" {
    const allocator = std.testing.allocator;
    const n_bytes = 64;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0);
    @memset(dst_slow, 0);

    xorBits(dst_fast, 0, lhs_buf, 0, rhs_buf, 0, n_bytes * 8);
    for (0..n_bytes * 8) |i| {
        const bit = getBit(lhs_buf, i) != getBit(rhs_buf, i);
        if (bit) setBit(dst_slow, i) else clearBit(dst_slow, i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "countAndSetBits valid_off=0 multi-word" {
    const allocator = std.testing.allocator;
    const n_bytes = 64;
    const values_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(values_buf);
    const valid_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(valid_buf);

    for (values_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131));
    for (valid_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));

    const fast = countAndSetBits(values_buf, 0, valid_buf, 0, n_bytes * 8);
    var slow: usize = 0;
    for (0..n_bytes * 8) |i| {
        if (getBit(values_buf, i) and getBit(valid_buf, i)) slow += 1;
    }
    try std.testing.expectEqual(slow, fast);
}

test "countAndSetBits unaligned multiword" {
    const allocator = std.testing.allocator;
    const n_bytes = 40;
    const values_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(values_buf);
    const valid_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(valid_buf);

    for (values_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 17));
    for (valid_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));

    const value_off = 5;
    const valid_off = 11;
    const len = 211;
    const fast = countAndSetBits(values_buf, value_off, valid_buf, valid_off, len);
    var slow: usize = 0;
    for (0..len) |i| {
        if (getBit(values_buf, value_off + i) and getBit(valid_buf, valid_off + i)) slow += 1;
    }
    try std.testing.expectEqual(slow, fast);
}

test "andBits unaligned offsets multi-byte" {
    const allocator = std.testing.allocator;
    const n_bytes = 8;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 7));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0xFF);
    @memset(dst_slow, 0xFF);

    andBits(dst_fast, 1, lhs_buf, 3, rhs_buf, 5, 40);
    for (0..40) |i| {
        const bit = getBit(lhs_buf, 3 + i) and getBit(rhs_buf, 5 + i);
        if (bit) setBit(dst_slow, 1 + i) else clearBit(dst_slow, 1 + i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "orBits unaligned offsets multi-byte" {
    const allocator = std.testing.allocator;
    const n_bytes = 8;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 7));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0);
    @memset(dst_slow, 0);

    orBits(dst_fast, 1, lhs_buf, 3, rhs_buf, 5, 40);
    for (0..40) |i| {
        const bit = getBit(lhs_buf, 3 + i) or getBit(rhs_buf, 5 + i);
        if (bit) setBit(dst_slow, 1 + i) else clearBit(dst_slow, 1 + i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "xorBits unaligned offsets multi-byte" {
    const allocator = std.testing.allocator;
    const n_bytes = 8;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 7));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));
    @memset(dst_fast, 0);
    @memset(dst_slow, 0);

    xorBits(dst_fast, 1, lhs_buf, 3, rhs_buf, 5, 40);
    for (0..40) |i| {
        const bit = getBit(lhs_buf, 3 + i) != getBit(rhs_buf, 5 + i);
        if (bit) setBit(dst_slow, 1 + i) else clearBit(dst_slow, 1 + i);
    }
    try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
}

test "binary ops unaligned multiword" {
    const allocator = std.testing.allocator;
    const n_bytes = 40;
    const lhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(lhs_buf);
    const rhs_buf = try allocator.alloc(u8, n_bytes);
    defer allocator.free(rhs_buf);
    const dst_fast = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_fast);
    const dst_slow = try allocator.alloc(u8, n_bytes);
    defer allocator.free(dst_slow);

    for (lhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 7));
    for (rhs_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));

    inline for (.{ BinaryOp.@"and", .@"or", .xor, .and_not, .or_not }) |op| {
        @memset(dst_fast, 0x5A);
        @memset(dst_slow, 0x5A);
        binaryBits(op, dst_fast, 3, lhs_buf, 5, rhs_buf, 11, 211);
        binaryBitsScalar(op, dst_slow, 3, lhs_buf, 5, rhs_buf, 11, 211);
        try std.testing.expectEqualSlices(u8, dst_slow, dst_fast);
    }
}

test "BitmapBuilder unsafeAppendBits basic" {
    const allocator = std.testing.allocator;
    const src = [_]u8{ 0b10110101, 0b01001010 }; // 16 bits
    var b = BitmapBuilder.init();
    defer b.deinit();
    // Append 1 true bit so dst_off is not zero (exercises the offset path).
    try b.ensureCapacityForBits(allocator, 1 + 12);
    b.unsafeAppend(true);
    // Append 12 bits from src starting at bit 0.
    b.unsafeAppendBits(&src, 0, 12);
    try std.testing.expectEqual(@as(usize, 13), b.len);
    // bit 0 of b: the initial true bit.
    // bits 1..12: src[0..11].
    const expected_true = 1 + countSetBits(&src, 0, 12);
    try std.testing.expectEqual(12 - countSetBits(&src, 0, 12), b.false_count);
    const owned = try b.finish(allocator);
    defer owned.release();
    try std.testing.expect(getBit(owned.dataSlice(), 0));
    for (0..12) |i| {
        try std.testing.expectEqual(getBit(&src, i), getBit(owned.dataSlice(), 1 + i));
    }
    _ = expected_true;
}
