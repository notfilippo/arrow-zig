// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Reference count abstraction.
//!
//! Uses atomic counters by default, and plain counters when
//! `config.thread_mode` is `.single_threaded`.

const std = @import("std");
const config = @import("config.zig");

/// Shared refcount abstraction used by buffers, external owner handles, and
/// array storage. The interface intentionally mirrors the atomic API subset the
/// library needs: `init`, `fetchAdd`, `fetchSub`, and `load`.
pub const RefCount = if (config.thread_mode == .threaded) std.atomic.Value(usize) else NonAtomicValue(usize);

fn NonAtomicValue(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: T,

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }

        pub inline fn fetchAdd(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old + v;
            return old;
        }

        pub inline fn fetchSub(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old - v;
            return old;
        }

        pub inline fn load(self: *const Self, _: std.builtin.AtomicOrder) T {
            return self.raw;
        }
    };
}

test "RefCount basic operations" {
    var rc = RefCount.init(1);
    try std.testing.expectEqual(@as(usize, 1), rc.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), rc.fetchAdd(2, .monotonic));
    try std.testing.expectEqual(@as(usize, 3), rc.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), rc.fetchSub(1, .monotonic));
    try std.testing.expectEqual(@as(usize, 2), rc.load(.monotonic));
}
