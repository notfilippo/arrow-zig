// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Bit level primitives for Arrow bitmaps.
//!
//! Helpers here read, write, copy, invert, and count packed bits using Arrow
//! least significant bit first ordering.

const std = @import("std");
const checked = @import("checked.zig");

const bitmask = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };
const flipped_bitmask = [8]u8{ 254, 253, 251, 247, 239, 223, 191, 127 };
const preceding_bitmask = [8]u8{ 0, 1, 3, 7, 15, 31, 63, 127 };
const trailing_bitmask = [8]u8{ 255, 254, 252, 248, 240, 224, 192, 128 };

pub const unknown_null_count: usize = std.math.maxInt(usize);

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

pub inline fn toggleBit(bits: []u8, i: usize) void {
    bits[i >> 3] ^= bitmask[i & 7];
}

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

    if (start % 8 != 0) {
        const m = trailing_bitmask[start % 8];
        if (value) bits[first_byte] |= m else bits[first_byte] &= ~m;
    } else {
        bits[first_byte] = fill;
    }

    if (first_byte + 1 < last_byte)
        @memset(bits[first_byte + 1 .. last_byte], fill);

    if (end % 8 != 0) {
        const m = preceding_bitmask[end % 8];
        if (value) bits[last_byte] |= m else bits[last_byte] &= ~m;
    } else {
        bits[last_byte] = fill;
    }
}

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

pub inline fn readWord64(bits: []const u8, bit_pos: usize) u64 {
    const byte_idx = bit_pos / 8;
    const shift_bits = bit_pos & 7;
    const lo = std.mem.readInt(u64, bits[byte_idx..][0..8], .little);
    if (shift_bits == 0) return lo;
    const shift: u6 = @intCast(shift_bits);
    const rshift: u6 = @intCast(64 - shift_bits);
    return (lo >> shift) | (@as(u64, bits[byte_idx + 8]) << rshift);
}

pub inline fn writeWord64(bits: []u8, bit_pos: usize, word: u64) void {
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

pub fn copyBitsScalar(dst: []u8, dst_off: usize, src: []const u8, src_off: usize, len: usize) void {
    for (0..len) |i| setBitTo(dst, dst_off + i, getBit(src, src_off + i));
}

fn countSetBitsScalar(bits: []const u8, bit_offset: usize, bit_len: usize) usize {
    var count: usize = 0;
    for (0..bit_len) |i| {
        if (getBit(bits, bit_offset + i)) count += 1;
    }
    return count;
}

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

pub fn invertBits(bits: []u8, bit_offset: usize, bit_len: usize) void {
    if (bit_len == 0) return;

    var done: usize = 0;
    while (done + 64 <= bit_len) : (done += 64) {
        const pos = bit_offset + done;
        writeWord64(bits, pos, ~readWord64(bits, pos));
    }
    for (0..bit_len - done) |i| toggleBit(bits, bit_offset + done + i);
}

pub fn nullCountFor(validity_bytes: ?[]const u8, offset: usize, len: usize, hint: usize) usize {
    if (hint != unknown_null_count) return hint;
    const bytes = validity_bytes orelse return 0;
    return len - countSetBits(bytes, offset, len);
}

test "bit access and ranges" {
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
    clearBit(&buf, 7);
    try std.testing.expect(!getBit(&buf, 7));

    setBitsTo(&buf, 2, 4, true);
    try std.testing.expectEqual(@as(u8, 0b00111101), buf[0]);
    setBitsTo(&buf, 2, 4, false);
    try std.testing.expectEqual(@as(u8, 0b00000001), buf[0]);
}

test "setBitsTo boundaries" {
    var buf = [_]u8{0} ** 3;
    setBitsTo(&buf, 6, 6, true);
    try std.testing.expectEqual(@as(u8, 0b11000000), buf[0]);
    try std.testing.expectEqual(@as(u8, 0b00001111), buf[1]);

    setBitsTo(&buf, 0, 16, true);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[1]);
    setBitsTo(&buf, 0, 16, false);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
}

test "countSetBits aligned and unaligned" {
    var buf = [_]u8{0} ** 40;
    setBitsTo(&buf, 0, 72, true);
    try std.testing.expectEqual(@as(usize, 72), countSetBits(&buf, 0, 72));
    setBitsTo(&buf, 0, 72, false);
    setBitsTo(&buf, 3, 5, true);
    try std.testing.expectEqual(@as(usize, 5), countSetBits(&buf, 0, 72));

    for (&buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 43 +% 19));
    const offset = 5;
    const len = 231;
    var slow: usize = 0;
    for (0..len) |i| {
        if (getBit(&buf, offset + i)) slow += 1;
    }
    try std.testing.expectEqual(slow, countSetBits(&buf, offset, len));
}

test "copyBits paths" {
    var src = [_]u8{ 0b11110000, 0b00001111, 0b10101010 };
    var dst = [_]u8{0} ** 3;
    copyBits(&dst, 0, &src, 0, 8);
    try std.testing.expectEqual(src[0], dst[0]);

    @memset(&dst, 0);
    copyBits(&dst, 2, &src, 4, 13);
    for (0..13) |i| {
        try std.testing.expectEqual(getBit(&src, 4 + i), getBit(&dst, 2 + i));
    }
}

test "copyBits and invertBits unaligned multiword" {
    const n_bytes = 40;
    var src: [n_bytes]u8 = undefined;
    var fast: [n_bytes]u8 = undefined;
    var slow: [n_bytes]u8 = undefined;

    for (&src, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 73 +% 17));
    @memset(&fast, 0xA5);
    @memset(&slow, 0xA5);
    copyBits(&fast, 3, &src, 5, 211);
    copyBitsScalar(&slow, 3, &src, 5, 211);
    try std.testing.expectEqualSlices(u8, &slow, &fast);

    for (&fast, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 31 +% 7));
    @memcpy(&slow, &fast);
    invertBits(&fast, 5, 211);
    for (0..211) |i| toggleBit(&slow, 5 + i);
    try std.testing.expectEqualSlices(u8, &slow, &fast);
}

test "invertBits single and partial ranges" {
    var byte = [_]u8{0b00001111};
    invertBits(&byte, 2, 4);
    try std.testing.expectEqual(@as(u8, 0b00110011), byte[0]);

    var aligned = [_]u8{ 0b10110101, 0b00001111 };
    invertBits(&aligned, 0, 16);
    try std.testing.expectEqual(@as(u8, 0b01001010), aligned[0]);
    try std.testing.expectEqual(@as(u8, 0b11110000), aligned[1]);
}
