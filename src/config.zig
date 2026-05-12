// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Compile time package configuration.
//!
//! Values here reflect build options selected by `build.zig`.

const build_options = @import("build_options");
const std = @import("std");

/// Runtime assumption selected at build time.
pub const ThreadMode = enum { threaded, single_threaded };

/// Enables single threaded optimizations when set to `.single_threaded`.
pub const thread_mode: ThreadMode = if (build_options.single_threaded) .single_threaded else .threaded;

test "thread mode follows build option" {
    const expected: ThreadMode = if (build_options.single_threaded) .single_threaded else .threaded;
    try std.testing.expectEqual(expected, thread_mode);
}
