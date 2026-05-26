// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Fuzz targets for validation and C Data Interface import.

const std = @import("std");
const arrow = @import("arrow");

const cdi = arrow.cdi;
const ArrowArray = cdi.ArrowArray;
const DataType = arrow.datatype.DataType;

const max_len: usize = 16;
const max_buffer_bytes: usize = max_len * @sizeOf(u64);

const fuzz_types = [_]DataType{
    .null_,
    .bool,
    .int8,
    .int32,
    .int64,
    .uint32,
    .float32,
    .float64,
    .binary,
    .utf8,
    .large_binary,
    .{ .fixed_size_binary = .{ .byte_width = 4 } },
    .{ .decimal128 = .{ .precision = 10, .scale = 2 } },
};

const seed_corpus = [_][]const u8{
    &.{},
    &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 1, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 },
};

test "fuzz CDI import validation" {
    try std.testing.fuzz({}, fuzzImport, .{ .corpus = &seed_corpus });
}

fn fuzzImport(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;

    const ty_index = smith.indexWithHash(fuzz_types.len, 0x1aa7_3b91);
    const ty = fuzz_types[ty_index];

    const offset: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 3, 0x8b81_2f62)) {
        0 => -1,
        1 => 0,
        2 => @intCast(smith.valueRangeAtMostWithHash(u8, 1, max_len - 1, 0x4441_77f3)),
        else => @intCast(max_len),
    };
    const length: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 3, 0xd47d_e8a9)) {
        0 => -1,
        1 => 0,
        2 => @intCast(smith.valueRangeAtMostWithHash(u8, 1, max_len, 0xc2c1_18bb)),
        else => @intCast(max_len),
    };

    var buffer_storage = [_][max_buffer_bytes]u8{[_]u8{0} ** max_buffer_bytes} ** 4;
    for (&buffer_storage) |*buf| smith.bytesWithHash(buf, 0x6c5d_d2a1);

    // For binary/utf8/large_binary, the offsets buffer (index 1) must be monotonic
    // and bounded by the values buffer size. CDI provides no way to detect
    // out-of-bounds offsets without segfaulting in the validator, so we honor the
    // producer contract here and still let the fuzzer explore degenerate-but-legal
    // offset patterns.
    switch (ty) {
        .binary, .utf8 => writeMonotonicOffsets(i32, &buffer_storage[1], smith, 0x3d1f_7b04),
        .large_binary => writeMonotonicOffsets(i64, &buffer_storage[1], smith, 0x3d1f_7b05),
        else => {},
    }

    // Bias toward type-correct buffer counts: most primitives want 2 (validity + values),
    // binary/utf8 want 3 (validity + offsets + values). Other counts are reachable but
    // weighted lower so the fuzzer spends most iterations exploring deeper paths.
    const n_buffers: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 9, 0x4d96_0c12)) {
        0 => -1,
        1 => 0,
        2 => 1,
        3, 4, 5 => 2,
        6, 7, 8 => 3,
        else => 4,
    };
    var buffer_ptrs: [4]?*const anyopaque = undefined;
    for (&buffer_ptrs, 0..) |*slot, i| {
        slot.* = if (smith.boolWeightedWithHash(1, 3, 0x0435_a4b8 +% @as(u32, @intCast(i))))
            @ptrCast(&buffer_storage[i])
        else
            null;
    }

    const null_count: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 4, 0xf4e0_9c3d)) {
        0 => -2,
        1 => -1,
        2 => 0,
        3 => length,
        else => length + 1,
    };

    // None of the fuzzed types accept children. Heavy bias toward 0 so the import
    // gets past the child-count check and into deeper validation; keep some
    // non-zero cases so the InvalidChildCount path stays exercised.
    const n_children: i64 = switch (smith.valueRangeAtMostWithHash(u8, 0, 9, 0x71a4_82cc)) {
        0 => -1,
        1, 2, 3, 4, 5, 6, 7, 8 => 0,
        else => @intCast(smith.valueRangeAtMostWithHash(u8, 1, 3, 0x9f33_b507)),
    };
    const provide_children = smith.boolWeightedWithHash(1, 3, 0x2c1f_9d04);

    var child_storage = [_]ArrowArray{minimalArray(null)} ** 3;
    var child_ptrs = [_]*ArrowArray{ &child_storage[0], &child_storage[1], &child_storage[2] };

    var dictionary_storage = minimalArray(null);
    const provide_dictionary = smith.boolWeightedWithHash(3, 1, 0xb5bf_fa26);

    const provide_buffers = smith.boolWeightedWithHash(1, 9, 0x83ef_4a17);
    const release_already_null = smith.boolWeightedWithHash(20, 1, 0xa10c_92c6);

    var release_count: usize = 0;
    var arr = minimalArray(&release_count);
    arr.length = length;
    arr.offset = offset;
    arr.null_count = null_count;
    arr.n_buffers = n_buffers;
    arr.n_children = n_children;
    arr.buffers = if (provide_buffers) &buffer_ptrs else null;
    arr.children = if (provide_children) &child_ptrs else null;
    arr.dictionary = if (provide_dictionary) &dictionary_storage else null;
    if (release_already_null) arr.release = null;

    const result = cdi.importArray(allocator, ty, &arr);
    if (result) |imported| {
        defer imported.deinit();
        try imported.validateFull();
        try std.testing.expect(cdi.arrayIsReleased(&arr));
        try std.testing.expectEqual(@as(usize, 0), release_count);
    } else |_| {
        // On failure, the import must not have consumed the caller's release callback.
        // If we provided a release, it should still be live; if we passed a pre-released
        // array, the count stays 0 because there was nothing to release.
        if (release_already_null) {
            try std.testing.expect(cdi.arrayIsReleased(&arr));
            try std.testing.expectEqual(@as(usize, 0), release_count);
        } else {
            try std.testing.expect(!cdi.arrayIsReleased(&arr));
            try std.testing.expectEqual(@as(usize, 0), release_count);
            arr.release.?(&arr);
            try std.testing.expectEqual(@as(usize, 1), release_count);
        }
    }
}

fn writeMonotonicOffsets(comptime Offset: type, buf: *[max_buffer_bytes]u8, smith: *std.testing.Smith, hash: u32) void {
    const slot_count = max_buffer_bytes / @sizeOf(Offset);
    var current: Offset = 0;
    var i: usize = 0;
    while (i < slot_count) : (i += 1) {
        const delta = smith.valueRangeAtMostWithHash(u8, 0, 8, hash +% @as(u32, @intCast(i)));
        const new_value: Offset = @intCast(@min(@as(usize, @intCast(current)) + @as(usize, @intCast(delta)), max_buffer_bytes));
        std.mem.writeInt(Offset, buf[i * @sizeOf(Offset) ..][0..@sizeOf(Offset)], new_value, .little);
        current = new_value;
    }
}

fn minimalArray(release_count: ?*usize) ArrowArray {
    return .{
        .length = 0,
        .null_count = 0,
        .offset = 0,
        .n_buffers = 0,
        .n_children = 0,
        .buffers = null,
        .children = null,
        .dictionary = null,
        .release = if (release_count != null) countArrayRelease else null,
        .private_data = if (release_count) |rc| rc else null,
    };
}

fn countArrayRelease(arr: *ArrowArray) callconv(.c) void {
    const release_count: *usize = @ptrCast(@alignCast(arr.private_data.?));
    release_count.* += 1;
    arr.release = null;
}
