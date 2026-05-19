// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Shared benchmark harness.

const std = @import("std");
const Io = std.Io;

const ns_per_s = std.time.ns_per_s;

pub const Options = struct {
    filter: ?[]const u8 = null,
    len: usize = 1 << 20,
    iterations: usize = 10,
    format: OutputFormat = .pretty,
};

const OutputFormat = enum {
    pretty,
    tsv,
};

pub const Result = struct {
    checksum: usize,
    best_ns: u64,
    avg_ns: u64,
};

pub const CaseFn = *const fn (std.mem.Allocator, Io, Options) anyerror!Result;

pub const Case = struct {
    name: []const u8,
    run: CaseFn,
};

pub fn case(name: []const u8, run: CaseFn) Case {
    return .{ .name = name, .run = run };
}

pub fn main(init: std.process.Init, comptime suites: anytype) !void {
    const allocator = init.gpa;
    const io = init.io;
    const opts = try parseOptions(init);

    printHeader(opts.format);

    var matched = false;
    inline for (suites) |suite| {
        inline for (suite) |bench_case| {
            const selected = if (opts.filter) |filter|
                std.mem.indexOf(u8, bench_case.name, filter) != null
            else
                true;
            if (selected) {
                matched = true;
                const result = try bench_case.run(allocator, io, opts);
                printResult(opts, bench_case.name, result);
            }
        }
    }

    if (!matched) {
        std.debug.print("no benchmark matched filter\n", .{});
        std.process.exit(1);
    }
}

pub fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn printHeader(format: OutputFormat) void {
    switch (format) {
        .pretty => std.debug.print(
            "{s:<45} {s:>10} {s:>5} {s:>12} {s:>12} {s:>13} {s:>10}\n",
            .{ "benchmark", "rows", "iters", "best", "avg", "throughput", "checksum" },
        ),
        .tsv => std.debug.print(
            "name\tlen\titerations\tbest_ns\tavg_ns\titems_per_s\tchecksum\n",
            .{},
        ),
    }
}

fn printResult(opts: Options, name: []const u8, result: Result) void {
    switch (opts.format) {
        .pretty => {
            const best = scaledDuration(result.best_ns);
            const avg = scaledDuration(result.avg_ns);
            const throughput = scaledThroughput(itemsPerSecond(opts.len, result.best_ns));
            std.debug.print(
                "{s:<45} {d:>10} {d:>5} {d:>8.2} {s:<3} {d:>8.2} {s:<3} {d:>8.2} {s:<4} {d:>10}\n",
                .{
                    name,
                    opts.len,
                    opts.iterations,
                    best.value,
                    best.unit,
                    avg.value,
                    avg.unit,
                    throughput.value,
                    throughput.unit,
                    result.checksum,
                },
            );
        },
        .tsv => std.debug.print(
            "{s}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            .{
                name,
                opts.len,
                opts.iterations,
                result.best_ns,
                result.avg_ns,
                itemsPerSecond(opts.len, result.best_ns),
                result.checksum,
            },
        ),
    }
}

const Scaled = struct {
    value: f64,
    unit: []const u8,
};

fn scaledDuration(ns: u64) Scaled {
    const value: f64 = @floatFromInt(ns);
    if (ns >= ns_per_s) {
        return .{ .value = value / ns_per_s, .unit = "s" };
    }
    if (ns >= std.time.ns_per_ms) {
        return .{ .value = value / std.time.ns_per_ms, .unit = "ms" };
    }
    if (ns >= std.time.ns_per_us) {
        return .{ .value = value / std.time.ns_per_us, .unit = "us" };
    }
    return .{ .value = value, .unit = "ns" };
}

fn scaledThroughput(items_per_s: u64) Scaled {
    const value: f64 = @floatFromInt(items_per_s);
    if (items_per_s >= 1_000_000_000) {
        return .{ .value = value / 1_000_000_000, .unit = "G/s" };
    }
    if (items_per_s >= 1_000_000) {
        return .{ .value = value / 1_000_000, .unit = "M/s" };
    }
    if (items_per_s >= 1_000) {
        return .{ .value = value / 1_000, .unit = "K/s" };
    }
    return .{ .value = value, .unit = "/s" };
}

fn parseOptions(init: std.process.Init) !Options {
    var opts = Options{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            opts.filter = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--len")) {
            opts.len = try parsePositive(usize, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            opts.iterations = try parsePositive(usize, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--format")) {
            opts.format = parseOutputFormat(args.next() orelse return error.MissingArgument) orelse
                return error.InvalidArgument;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn usage() void {
    std.debug.print(
        \\usage: zig build bench -- [options]
        \\
        \\options:
        \\  --filter NAME       run benchmarks containing NAME
        \\  --len N             logical values per input, default 1048576
        \\  --iterations N      measured iterations, default 10
        \\  --format FORMAT     pretty or tsv, default pretty
        \\  --help              show this help
        \\
    , .{});
}

fn parseOutputFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "pretty")) return .pretty;
    if (std.mem.eql(u8, value, "tsv")) return .tsv;
    return null;
}

fn parsePositive(comptime T: type, value: []const u8) !T {
    const parsed = try std.fmt.parseInt(T, value, 10);
    if (parsed == 0) return error.InvalidArgument;
    return parsed;
}

fn itemsPerSecond(len: usize, best_ns: u64) u64 {
    if (best_ns == 0) return 0;
    return @intCast((@as(u128, len) * ns_per_s) / best_ns);
}
