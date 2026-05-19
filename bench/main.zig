// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Benchmark entry point.

const bench = @import("harness.zig");
const compute_compare = @import("compute/compare.zig");

pub fn main(init: @import("std").process.Init) !void {
    try bench.main(init, .{
        compute_compare.benchmarks,
    });
}
