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
    bench.case("compute.compare.null.equal", compareNull),
    bench.case("compute.compare.decimal32.less_equal.valid", compareDecimal32Valid),
    bench.case("compute.compare.decimal64.less_equal.valid", compareDecimal64Valid),
    bench.case("compute.compare.decimal128.less_equal.valid", compareDecimal128Valid),
    bench.case("compute.compare.decimal256.less_equal.valid", compareDecimal256Valid),
    bench.case("compute.compare.month_interval.not_equal.valid", compareMonthIntervalValid),
    bench.case("compute.compare.day_time_interval.not_equal.valid", compareDayTimeIntervalValid),
    bench.case("compute.compare.month_day_nano_interval.not_equal.valid", compareMonthDayNanoIntervalValid),
    bench.case("compute.compare.dictionary.i32.less.valid", compareDictionaryI32Valid),
    bench.case("compute.compare.dictionary.utf8.equal.valid", compareDictionaryUtf8Valid),
    bench.case("compute.compare.dictionary.utf8.equal.plain", compareDictionaryUtf8Plain),
    bench.case("compute.compare.dictionary.utf8.equal.nulls", compareDictionaryUtf8Nulls),
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

fn compareNull(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = arrow.builder.NullBuilder.init(allocator);
    defer left_builder.deinit();
    try left_builder.appendNulls(opts.len);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.NullBuilder.init(allocator);
    defer right_builder.deinit();
    try right_builder.appendNulls(opts.len);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareEqual);
}

fn compareDecimal32Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = try arrow.builder.Decimal32Builder.init(allocator, 9, 2);
    defer left_builder.deinit();
    var right_builder = try arrow.builder.Decimal32Builder.init(allocator, 9, 2);
    defer right_builder.deinit();
    try fillDecimal(i32, &left_builder, opts.len, 19);
    try fillDecimal(i32, &right_builder, opts.len, 43);

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareLessEqual);
}

fn compareDecimal64Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = try arrow.builder.Decimal64Builder.init(allocator, 18, 2);
    defer left_builder.deinit();
    var right_builder = try arrow.builder.Decimal64Builder.init(allocator, 18, 2);
    defer right_builder.deinit();
    try fillDecimal(i64, &left_builder, opts.len, 19);
    try fillDecimal(i64, &right_builder, opts.len, 43);

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareLessEqual);
}

fn compareDecimal128Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = try arrow.builder.Decimal128Builder.init(allocator, 38, 2);
    defer left_builder.deinit();
    var right_builder = try arrow.builder.Decimal128Builder.init(allocator, 38, 2);
    defer right_builder.deinit();
    try fillDecimal(i128, &left_builder, opts.len, 19);
    try fillDecimal(i128, &right_builder, opts.len, 43);

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareLessEqual);
}

fn compareDecimal256Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = try arrow.builder.Decimal256Builder.init(allocator, 76, 2);
    defer left_builder.deinit();
    var right_builder = try arrow.builder.Decimal256Builder.init(allocator, 76, 2);
    defer right_builder.deinit();
    try fillDecimal(i256, &left_builder, opts.len, 19);
    try fillDecimal(i256, &right_builder, opts.len, 43);

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareLessEqual);
}

fn compareMonthIntervalValid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = arrow.builder.MonthIntervalBuilder.init(allocator);
    defer left_builder.deinit();
    var right_builder = arrow.builder.MonthIntervalBuilder.init(allocator);
    defer right_builder.deinit();
    try left_builder.reserve(opts.len);
    try right_builder.reserve(opts.len);
    for (0..opts.len) |i| {
        try left_builder.append(@intCast(i % 240));
        try right_builder.append(@intCast((i + 7) % 240));
    }

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareNotEqual);
}

fn compareDayTimeIntervalValid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = arrow.builder.DayTimeIntervalBuilder.init(allocator);
    defer left_builder.deinit();
    var right_builder = arrow.builder.DayTimeIntervalBuilder.init(allocator);
    defer right_builder.deinit();
    try left_builder.reserve(opts.len);
    try right_builder.reserve(opts.len);
    for (0..opts.len) |i| {
        try left_builder.append(dayTimeFor(i));
        try right_builder.append(dayTimeFor(i + 7));
    }

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareNotEqual);
}

fn compareMonthDayNanoIntervalValid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    var left_builder = arrow.builder.MonthDayNanoIntervalBuilder.init(allocator);
    defer left_builder.deinit();
    var right_builder = arrow.builder.MonthDayNanoIntervalBuilder.init(allocator);
    defer right_builder.deinit();
    try left_builder.reserve(opts.len);
    try right_builder.reserve(opts.len);
    for (0..opts.len) |i| {
        try left_builder.append(monthDayNanoFor(i));
        try right_builder.append(monthDayNanoFor(i + 7));
    }

    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareNotEqual);
}

fn compareDictionaryI32Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_dictionary = try i32Dictionary(allocator, &.{ 30, 10, 50, 20, 70, 40, 90, 60 });
    defer left_dictionary.deinit();
    const right_dictionary = try i32Dictionary(allocator, &.{ 20, 30, 10, 50, 40, 70, 60, 90 });
    defer right_dictionary.deinit();

    const left_indices = try allocator.alloc(i8, opts.len);
    defer allocator.free(left_indices);
    const right_indices = try allocator.alloc(i16, opts.len);
    defer allocator.free(right_indices);
    fillDictionaryIndices(i8, left_indices, 0);
    fillDictionaryIndices(i16, right_indices, 3);

    var left_builder = arrow.builder.DictionaryBuilder(i8).init(allocator, left_dictionary);
    defer left_builder.deinit();
    try left_builder.appendSlice(left_indices);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.DictionaryBuilder(i16).init(allocator, right_dictionary);
    defer right_builder.deinit();
    try right_builder.appendSlice(right_indices);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareLess);
}

fn compareDictionaryUtf8Valid(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_dictionary = try utf8Dictionary(allocator, &.{ 1, 0, 3, 2, 5, 4, 7, 6 }, false);
    defer left_dictionary.deinit();
    const right_dictionary = try utf8Dictionary(allocator, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, false);
    defer right_dictionary.deinit();

    const left_indices = try allocator.alloc(i8, opts.len);
    defer allocator.free(left_indices);
    const right_indices = try allocator.alloc(i16, opts.len);
    defer allocator.free(right_indices);
    fillDictionaryIndices(i8, left_indices, 0);
    for (right_indices, 0..) |*index, i| {
        const left_index = i % 8;
        index.* = @intCast(left_index ^ 1);
    }

    var left_builder = arrow.builder.DictionaryBuilder(i8).init(allocator, left_dictionary);
    defer left_builder.deinit();
    try left_builder.appendSlice(left_indices);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.DictionaryBuilder(i16).initOptions(allocator, right_dictionary, .{ .ordered = true });
    defer right_builder.deinit();
    try right_builder.appendSlice(right_indices);
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareEqual);
}

fn compareDictionaryUtf8Plain(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const dictionary = try utf8Dictionary(allocator, &.{ 1, 0, 3, 2, 5, 4, 7, 6 }, false);
    defer dictionary.deinit();

    const left_indices = try allocator.alloc(i8, opts.len);
    defer allocator.free(left_indices);
    fillDictionaryIndices(i8, left_indices, 0);

    var left_builder = arrow.builder.DictionaryBuilder(i8).init(allocator, dictionary);
    defer left_builder.deinit();
    try left_builder.appendSlice(left_indices);
    const left = try left_builder.finish();
    defer left.deinit();

    var right_builder = arrow.builder.Utf8Builder.init(allocator);
    defer right_builder.deinit();
    for (0..opts.len) |i| {
        try right_builder.append(wordFor((i % 8) ^ 1));
    }
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareEqual);
}

fn compareDictionaryUtf8Nulls(allocator: std.mem.Allocator, io: Io, opts: bench.Options) !bench.Result {
    const left_dictionary = try utf8Dictionary(allocator, &.{ 1, 0, 3, 2, 5, 4, 7, 6 }, true);
    defer left_dictionary.deinit();
    const right_dictionary = try utf8Dictionary(allocator, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, true);
    defer right_dictionary.deinit();

    var left_builder = arrow.builder.DictionaryBuilder(i8).init(allocator, left_dictionary);
    defer left_builder.deinit();
    var right_builder = arrow.builder.DictionaryBuilder(i8).init(allocator, right_dictionary);
    defer right_builder.deinit();
    for (0..opts.len) |i| {
        if (i % 17 == 0) {
            try left_builder.appendNull();
        } else {
            try left_builder.append(@intCast(i % 8));
        }
        try right_builder.append(@intCast((i + 1) % 8));
    }
    const left = try left_builder.finish();
    defer left.deinit();
    const right = try right_builder.finish();
    defer right.deinit();

    return runCompareBench(allocator, io, opts, left, right, compareEqual);
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

fn compareLessEqual(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.lessEqual(allocator, left, right);
}

fn compareLess(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.less(allocator, left, right);
}

fn compareEqual(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.equal(allocator, left, right);
}

fn compareNotEqual(
    allocator: std.mem.Allocator,
    left: *const arrow.array.ArrayData,
    right: *const arrow.array.ArrayData,
) !*arrow.array.ArrayData {
    return arrow.compute.compare.notEqual(allocator, left, right);
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

fn fillDecimal(comptime T: type, builder: anytype, len: usize, seed: u64) !void {
    var state = seed;
    try builder.reserve(len);
    for (0..len) |_| {
        state = state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        const magnitude: i64 = @intCast(state % 1_000_000);
        const value: T = @intCast(magnitude - 500_000);
        try builder.append(value);
    }
}

fn fillDictionaryIndices(comptime T: type, values: []T, shift: usize) void {
    for (values, 0..) |*value, i| {
        value.* = @intCast((i + shift) % 8);
    }
}

fn i32Dictionary(allocator: std.mem.Allocator, values: []const i32) !*arrow.array.ArrayData {
    var builder = arrow.builder.NumericBuilder(i32).init(allocator);
    defer builder.deinit();
    try builder.appendSlice(values);
    return builder.finish();
}

fn utf8Dictionary(allocator: std.mem.Allocator, order: []const usize, include_null: bool) !*arrow.array.ArrayData {
    var builder = arrow.builder.Utf8Builder.init(allocator);
    defer builder.deinit();
    for (order, 0..) |word_index, i| {
        if (include_null and i == 3) {
            try builder.appendNull();
        } else {
            try builder.append(wordFor(word_index));
        }
    }
    return builder.finish();
}

fn dayTimeFor(i: usize) arrow.array.DayTimeInterval {
    return .{
        .days = @intCast(i % 31),
        .milliseconds = @intCast((i * 997) % 86_400_000),
    };
}

fn monthDayNanoFor(i: usize) arrow.array.MonthDayNanoInterval {
    return .{
        .months = @intCast(i % 240),
        .days = @intCast((i / 3) % 31),
        .nanoseconds = @intCast((i * 1_000_003) % 1_000_000_000),
    };
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
