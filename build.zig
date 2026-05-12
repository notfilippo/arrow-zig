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
    const test_nanoarrow = b.option(
        bool,
        "nanoarrow",
        "Run optional nanoarrow interop tests. Default: false.",
    ) orelse false;

    const mod = b.addModule("arrow", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    addBuildOptions(b, mod, single_threaded);

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

    const ci_default_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    addBuildOptions(b, ci_default_mod, false);

    const ci_single_threaded_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    addBuildOptions(b, ci_single_threaded_mod, true);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    const ci_step = b.step("ci", "Run CI checks");
    ci_step.dependOn(license_step);
    ci_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test_default",
        .root_module = ci_default_mod,
    })).step);
    ci_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test_single_threaded",
        .root_module = ci_single_threaded_mod,
    })).step);

    if (test_nanoarrow) {
        if (b.lazyDependency("nanoarrow", .{})) |nanoarrow_dep| {
            const nanoarrow_mod = b.createModule(.{
                .root_source_file = b.path("src/cdi_nanoarrow_test.zig"),
                .target = target,
                .link_libc = true,
            });
            const nanoarrow_config = b.addConfigHeader(.{
                .style = .{ .cmake = nanoarrow_dep.path("src/nanoarrow/nanoarrow_config.h.in") },
                .include_path = "nanoarrow/nanoarrow_config.h",
            }, .{
                .NANOARROW_VERSION_MAJOR = 0,
                .NANOARROW_VERSION_MINOR = 8,
                .NANOARROW_VERSION_PATCH = 0,
                .NANOARROW_VERSION = "0.8.0",
                .NANOARROW_NAMESPACE_DEFINE = "",
            });
            addBuildOptions(b, nanoarrow_mod, single_threaded);
            nanoarrow_mod.addConfigHeader(nanoarrow_config);
            nanoarrow_mod.addIncludePath(nanoarrow_dep.path("src"));
            nanoarrow_mod.addCSourceFiles(.{
                .root = nanoarrow_dep.path("src/nanoarrow/common"),
                .files = &.{
                    "array.c",
                    "schema.c",
                    "utils.c",
                },
            });
            nanoarrow_mod.addCSourceFile(.{ .file = b.path("src/cdi_nanoarrow_bridge.c") });
            const run_nanoarrow_tests = &b.addRunArtifact(b.addTest(.{
                .name = "test_nanoarrow",
                .root_module = nanoarrow_mod,
            })).step;
            test_step.dependOn(run_nanoarrow_tests);
            ci_step.dependOn(run_nanoarrow_tests);
        }
    }
}

fn addBuildOptions(b: *std.Build, mod: *std.Build.Module, single_threaded: bool) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", single_threaded);
    mod.addOptions("build_options", build_options);
}
