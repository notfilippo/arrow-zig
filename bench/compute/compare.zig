// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Compute comparison benchmarks.

const std = @import("std");
const Io = std.Io;
const arrow = @import("arrow");
const bench = @import("../harness.zig");

pub const benchmarks = .{
    bench.case("compute.compare.i32.less_equal.valid", compareI32Valid),
    bench.case("compute.compare.i32.less_equal.nulls", compareI32Nulls),
    bench.case("compute.compare.bool.not_equal.valid", compareBoolValid),
    bench.case("compute.compare.utf8.less.valid", compareUtf8Valid),
};

fn compareI32Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_values = try allocator.alloc(i32, opts.len);
    defer allocator.free(left_values);
    const right_values = try allocator.alloc(i32, opts.len);
    defer allocator.free(right_values);

    fillI32(left_values, 17);
    fillI32(right_values, 41);

    var left_builder = arrow.builder.NumericBuilder(i32).init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(left_values);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.NumericBuilder(i32).init(allocator);
    defer right_builder.deinit();
    try right_builder.appendSlice(right_values);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareI32LessEqual);
}

fn compareI32Nulls(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_values = try allocator.alloc(i32, opts.len);
    defer allocator.free(left_values);
    const right_values = try allocator.alloc(i32, opts.len);
    defer allocator.free(right_values);
    const left_valid = try allocator.alloc(u8, opts.len);
    defer allocator.free(left_valid);
    const right_valid = try allocator.alloc(u8, opts.len);
    defer allocator.free(right_valid);

    fillI32(left_values, 17);
    fillI32(right_values, 41);
    fillValidity(left_valid, 7);
    fillValidity(right_valid, 11);

    var left_builder = arrow.builder.NumericBuilder(i32).init(allocator);
    defer left_builder.deinit();
    try left_builder.appendValues(left_values, left_valid);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.NumericBuilder(i32).init(allocator);
    defer right_builder.deinit();
    try right_builder.appendValues(right_values, right_valid);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareI32LessEqual);
}

fn compareBoolValid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_values = try allocator.alloc(bool, opts.len);
    defer allocator.free(left_values);
    const right_values = try allocator.alloc(bool, opts.len);
    defer allocator.free(right_values);

    fillBool(left_values, 3);
    fillBool(right_values, 5);

    var left_builder = arrow.builder.BooleanBuilder.init(allocator);
    defer left_builder.deinit();
    try left_builder.appendSlice(left_values);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.BooleanBuilder.init(allocator);
    defer right_builder.deinit();
    try right_builder.appendSlice(right_values);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareBoolNotEqual);
}

fn compareUtf8Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = arrow.builder.Utf8Builder.init(allocator);
    defer left_builder.deinit();
    var right_builder = arrow.builder.Utf8Builder.init(allocator);
    defer right_builder.deinit();

    for (0..opts.len) |i| {
        try left_builder.append(wordFor(i + 1));
        try right_builder.append(wordFor(i + 3));
    }

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareUtf8Less);
}

fn runCompareBench(
    allocator: std.mem.Allocator,
    io: Io,
    opts: bench.Options,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
    comptime kernel: fn (std.mem.Allocator, *const arrow.array.ArrayData, *const arrow.array.ArrayData) anyerror!*arrow.array.ArrayData,
) !bench.Result {
    var checksum: usize = 0;

    {
        const result = try kernel(allocator, left, right);
        checksum +%= consumeBooleanResult(result);
        result.deinit();
    }

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u128 = 0;
    for (0..opts.iterations) |_| {
        const start = bench.benchTime(io);
        const result = try kernel(allocator, left, right);
        const elapsed = bench.benchTime(io) - start;
        checksum +%= consumeBooleanResult(result);
        result.deinit();

        const elapsed_ns: u64 = @intCast(elapsed);
        best_ns = @min(best_ns, elapsed_ns);
        total_ns += elapsed_ns;
    }
    std.mem.doNotOptimizeAway(checksum);

    return .{
        .checksum = checksum,
        .best_ns = best_ns,
        .avg_ns = @intCast(total_ns / opts.iterations),
    };
}

fn compareI32LessEqual(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.lessEqual(allocator, left, right);
}

fn compareBoolNotEqual(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.notEqual(allocator, left, right);
}

fn compareUtf8Less(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.less(allocator, left, right);
}

fn consumeBooleanResult(result_data: *const arrow.array.ArrayData) usize {
    const values = arrow.array.BooleanArray.fromData(result_data) catch unreachable;
    return values.trueCount() + result_data.nullCount();
}

pub fn fillI32(values: []i32, seed: u32) void {
    var state = seed;
    for (values) |*value| {
        state = state *% 1_664_525 +% 1_013_904_223;
        value.* = @bitCast(state);
    }
}

pub fn fillBool(values: []bool, stride: usize) void {
    for (values, 0..) |*value, i| {
        value.* = i % stride == 0;
    }
}

pub fn fillValidity(values: []u8, null_stride: usize) void {
    for (values, 0..) |*value, i| {
        value.* = if (i % null_stride == 0) 0 else 1;
    }
}

pub fn wordFor(i: usize) []const u8 {
    return switch (i % 8) {
        0 => "alpha",
        1 => "bravo",
        2 => "charlie",
        3 => "delta",
        4 => "echo",
        5 => "foxtrot",
        6 => "golf",
        else => "hotel",
    };
}
