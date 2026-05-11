const std = @import("std");

pub const Error = error{Overflow};

pub fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b);
}

pub fn sub(a: usize, b: usize) Error!usize {
    return std.math.sub(usize, a, b);
}

pub fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b);
}

pub fn addMul(base: usize, count: usize, unit: usize) Error!usize {
    return add(base, try mul(count, unit));
}

pub fn ceilDiv(n: usize, d: usize) Error!usize {
    std.debug.assert(d != 0);
    const q = @divFloor(n, d);
    const r = n % d;
    return if (r == 0) q else try add(q, 1);
}

pub fn bytesForBits(bit_len: usize) Error!usize {
    return ceilDiv(bit_len, 8);
}

pub fn roundUpToPowerOfTwo(n: usize, alignment: usize) Error!usize {
    std.debug.assert(alignment != 0);
    std.debug.assert((alignment & (alignment - 1)) == 0);
    const adjusted = try add(n, alignment - 1);
    return adjusted & ~@as(usize, alignment - 1);
}

test "checked helpers" {
    try std.testing.expectEqual(@as(usize, 11), try add(5, 6));
    try std.testing.expectEqual(@as(usize, 5), try sub(11, 6));
    try std.testing.expectEqual(@as(usize, 40), try mul(5, 8));
    try std.testing.expectEqual(@as(usize, 21), try addMul(5, 4, 4));
    try std.testing.expectEqual(@as(usize, 2), try bytesForBits(13));
    try std.testing.expectEqual(@as(usize, 64), try roundUpToPowerOfTwo(1, 64));
    try std.testing.expectError(error.Overflow, add(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.Overflow, sub(0, 1));
}
