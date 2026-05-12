// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Bitmap boolean operations.
//!
//! Operations support arbitrary bit offsets and lengths so sliced arrays can be
//! processed without first aligning or copying their bitmaps.

const std = @import("std");
const bits = @import("bitmap_bits.zig");

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
        const lhs_bit: u8 = if (bits.getBit(lhs, lhs_off + i)) 1 else 0;
        const rhs_bit: u8 = if (bits.getBit(rhs, rhs_off + i)) 1 else 0;
        bits.setBitTo(dst, dst_off + i, (applyBinaryOp(op, lhs_bit, rhs_bit) & 1) != 0);
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
        bits.writeWord64(
            dst,
            dst_off + done,
            applyBinaryOp(
                op,
                bits.readWord64(lhs, lhs_off + done),
                bits.readWord64(rhs, rhs_off + done),
            ),
        );
    }
    binaryBitsScalar(op, dst, dst_off + done, lhs, lhs_off + done, rhs, rhs_off + done, len - done);
}

pub fn andBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.@"and", dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

pub fn orBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.@"or", dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

pub fn xorBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.xor, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

pub fn andNotBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.and_not, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

pub fn orNotBits(dst: []u8, dst_off: usize, lhs: []const u8, lhs_off: usize, rhs: []const u8, rhs_off: usize, len: usize) void {
    binaryBits(.or_not, dst, dst_off, lhs, lhs_off, rhs, rhs_off, len);
}

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
            bits.readWord64(values, value_off + done) & bits.readWord64(valid, valid_off + done),
        ));
    }
    for (0..len - done) |i| {
        if (bits.getBit(values, value_off + done + i) and bits.getBit(valid, valid_off + done + i)) count += 1;
    }
    return count;
}

test "binary bit ops basic" {
    const lhs = [_]u8{0b11001100};
    const rhs = [_]u8{0b10101010};
    var dst = [_]u8{0};

    andBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b10001000), dst[0]);
    orBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b11101110), dst[0]);
    xorBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b01100110), dst[0]);
    andNotBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b01000100), dst[0]);
    orNotBits(&dst, 0, &lhs, 0, &rhs, 0, 8);
    try std.testing.expectEqual(@as(u8, 0b11011101), dst[0]);
}

test "binary bit ops unaligned multiword" {
    const n_bytes = 40;
    var lhs: [n_bytes]u8 = undefined;
    var rhs: [n_bytes]u8 = undefined;
    var fast: [n_bytes]u8 = undefined;
    var slow: [n_bytes]u8 = undefined;

    for (&lhs, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 7));
    for (&rhs, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));

    inline for (.{ BinaryOp.@"and", .@"or", .xor, .and_not, .or_not }) |op| {
        @memset(&fast, 0x5A);
        @memset(&slow, 0x5A);
        binaryBits(op, &fast, 3, &lhs, 5, &rhs, 11, 211);
        binaryBitsScalar(op, &slow, 3, &lhs, 5, &rhs, 11, 211);
        try std.testing.expectEqualSlices(u8, &slow, &fast);
    }
}

test "binary bit ops preserve offsets" {
    const lhs = [_]u8{0b11000000};
    const rhs = [_]u8{0b00001010};
    var dst = [_]u8{0xFF};
    andBits(&dst, 0, &lhs, 6, &rhs, 0, 2);
    try std.testing.expect(!bits.getBit(&dst, 0));
    try std.testing.expect(bits.getBit(&dst, 1));
}

test "countAndSetBits aligned and unaligned" {
    const values = [_]u8{0b10110101};
    const valid = [_]u8{0b00111111};
    try std.testing.expectEqual(@as(usize, 4), countAndSetBits(&values, 0, &valid, 0, 8));

    const n_bytes = 40;
    var values_buf: [n_bytes]u8 = undefined;
    var valid_buf: [n_bytes]u8 = undefined;
    for (&values_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 131 +% 17));
    for (&valid_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 97 +% 53));

    const value_off = 5;
    const valid_off = 11;
    const len = 211;
    const fast = countAndSetBits(&values_buf, value_off, &valid_buf, valid_off, len);
    var slow: usize = 0;
    for (0..len) |i| {
        if (bits.getBit(&values_buf, value_off + i) and bits.getBit(&valid_buf, valid_off + i)) slow += 1;
    }
    try std.testing.expectEqual(slow, fast);
}
