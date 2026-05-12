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
        "Also run nanoarrow interop tests in the test step. CI always runs them.",
    ) orelse false;

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
    test_step.dependOn(addRootTest(b, target, single_threaded, "test"));

    const ci_step = b.step("ci", "Run CI checks");
    ci_step.dependOn(license_step);
    ci_step.dependOn(addDocsCheck(b, target));
    ci_step.dependOn(addRootTest(b, target, false, "test_default"));
    ci_step.dependOn(addRootTest(b, target, true, "test_single_threaded"));

    if (b.lazyDependency("nanoarrow", .{})) |nanoarrow_dep| {
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

        if (test_nanoarrow) {
            test_step.dependOn(addNanoarrowTest(b, target, nanoarrow_dep, nanoarrow_config, single_threaded, "test_nanoarrow"));
        }
        ci_step.dependOn(addNanoarrowTest(b, target, nanoarrow_dep, nanoarrow_config, false, "test_nanoarrow_default"));
        ci_step.dependOn(addNanoarrowTest(b, target, nanoarrow_dep, nanoarrow_config, true, "test_nanoarrow_single_threaded"));
    }
}

fn addArrowModule(b: *std.Build, target: std.Build.ResolvedTarget, single_threaded: bool) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    addBuildOptions(b, mod, single_threaded);
    return mod;
}

fn addRootTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    single_threaded: bool,
    name: []const u8,
) *std.Build.Step {
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = addArrowModule(b, target, single_threaded),
    })).step;
}

fn addDocsCheck(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const docs_lib = b.addLibrary(.{
        .name = "arrow_docs",
        .root_module = addArrowModule(b, target, false),
    });
    _ = docs_lib.getEmittedDocs();
    return &docs_lib.step;
}

fn addBuildOptions(b: *std.Build, mod: *std.Build.Module, single_threaded: bool) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", single_threaded);
    mod.addOptions("build_options", build_options);
}

fn addNanoarrowTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    nanoarrow_dep: *std.Build.Dependency,
    nanoarrow_config: *std.Build.Step.ConfigHeader,
    single_threaded: bool,
    name: []const u8,
) *std.Build.Step {
    const nanoarrow_mod = b.createModule(.{
        .root_source_file = b.path("src/cdi_nanoarrow_test.zig"),
        .target = target,
        .link_libc = true,
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
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = nanoarrow_mod,
    })).step;
}
