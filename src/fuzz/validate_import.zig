// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Fuzz targets for validation and C Data Interface import.

const std = @import("std");
const cdi = @import("../cdi.zig");

const ArrowArray = cdi.ArrowArray;

test "fuzz CDI int32 import validation" {
    try std.testing.fuzz({}, fuzzCdiInt32Import, .{
        .corpus = &.{
            &.{},
            &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
            &.{ 1, 0, 0, 0, 0, 0, 0, 0 },
        },
    });
}

fn fuzzCdiInt32Import(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;

    const offset: u8 = smith.valueRangeAtMostWithHash(u8, 0, 2, 0x8b81_2f62);
    const len: u8 = smith.valueRangeAtMostWithHash(u8, 0, 4 - offset, 0xd47d_e8a9);
    const total: usize = @as(usize, offset) + len;

    var validity = [_]u8{0} ** 1;
    smith.bytesWithHash(&validity, 0x6c5d_d2a1);

    var values = [_]u8{0} ** (4 * @sizeOf(i32));
    smith.bytesWithHash(&values, 0x1938_5f45);

    const null_count: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 4, 0xf4e0_9c3d)) {
        0 => -2,
        1 => -1,
        2 => 0,
        3 => @intCast(len),
        else => @intCast(@as(usize, len) + 1),
    };
    const n_buffers: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 3, 0x4d96_0c12)) {
        0 => -1,
        1 => 0,
        2 => 1,
        else => 2,
    };
    const has_validity = smith.boolWeightedWithHash(1, 3, 0x0435_a4b8);
    const has_values = smith.boolWeightedWithHash(1, 3, 0xb5bf_fa26);

    var release_count: usize = 0;
    var arr = minimalArray();
    arr.length = len;
    arr.offset = offset;
    arr.null_count = null_count;
    arr.n_buffers = n_buffers;
    arr.private_data = &release_count;
    arr.release = countArrayRelease;

    var buffers = [_]?*const anyopaque{
        if (has_validity and total > 0) @ptrCast(&validity) else null,
        if (has_values and total > 0) @ptrCast(&values) else null,
    };
    arr.buffers = &buffers;

    const result = cdi.importArray(allocator, .int32, &arr);
    if (result) |imported| {
        defer imported.deinit();
        try imported.validateFull();
        try std.testing.expect(cdi.arrayIsReleased(&arr));
        try std.testing.expectEqual(@as(usize, 0), release_count);
    } else |_| {
        try std.testing.expect(!cdi.arrayIsReleased(&arr));
        try std.testing.expectEqual(@as(usize, 0), release_count);
        arr.release.?(&arr);
        try std.testing.expectEqual(@as(usize, 1), release_count);
    }
}

fn minimalArray() ArrowArray {
    return .{
        .length = 0,
        .null_count = 0,
        .offset = 0,
        .n_buffers = 0,
        .n_children = 0,
        .buffers = null,
        .children = null,
        .dictionary = null,
        .release = countArrayRelease,
        .private_data = null,
    };
}

fn countArrayRelease(arr: *ArrowArray) callconv(.c) void {
    const release_count: *usize = @ptrCast(@alignCast(arr.private_data.?));
    release_count.* += 1;
    arr.release = null;
}
