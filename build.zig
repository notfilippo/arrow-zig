// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const single_threaded = b.option(
        bool,
        "single_threaded",
        "Disable atomic buffer refcounts (single-threaded use only). Default: false.",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", single_threaded);

    const mod = b.addModule("arrow", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", build_options);

    const license_mod = b.createModule(.{
        .root_source_file = b.path("tools/check_license_headers.zig"),
        .target = b.graph.host,
    });
    const license_check = b.addExecutable(.{
        .name = "check_license_headers",
        .root_module = license_mod,
    });
    const license_tests = b.addTest(.{ .root_module = license_mod });
    const license_step = b.step("test-license", "Check license headers");
    license_step.dependOn(&b.addRunArtifact(license_tests).step);
    license_step.dependOn(&b.addRunArtifact(license_check).step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
