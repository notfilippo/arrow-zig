// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench_optimize",
        "Optimization mode for the benchmark executable. Default: ReleaseFast.",
    ) orelse .ReleaseFast;

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

    const arrow_options: ArrowOptions = .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    };
    const arrow_mod = addArrowModule(b, "arrow", arrow_options);

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

    const test_imports_mod = b.createModule(.{
        .root_source_file = b.path("tools/check_test_imports.zig"),
        .target = b.graph.host,
    });
    const test_imports_check = b.addExecutable(.{
        .name = "check_test_imports",
        .root_module = test_imports_mod,
    });
    const test_imports_tests = b.addTest(.{ .root_module = test_imports_mod });
    const test_imports_step = b.step("test-imports", "Check root test imports");
    test_imports_step.dependOn(&b.addRunArtifact(test_imports_tests).step);
    test_imports_step.dependOn(&b.addRunArtifact(test_imports_check).step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addRootTest(b, arrow_mod, "test"));

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(addBench(b, target, single_threaded, bench_optimize));

    const fuzz_step = b.step("fuzz", "Run fuzz target seed corpus checks");
    fuzz_step.dependOn(addRootTest(b, createArrowModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    }), "test_fuzz"));

    const ci_step = b.step("ci", "Run CI checks");
    ci_step.dependOn(license_step);
    ci_step.dependOn(test_imports_step);
    ci_step.dependOn(addDocsCheck(b, arrow_mod));
    ci_step.dependOn(addRootTest(b, createArrowModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    }), "test_default"));
    ci_step.dependOn(addRootTest(b, createArrowModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    }), "test_single_threaded"));

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
            test_step.dependOn(addNanoarrowTest(b, arrow_options, nanoarrow_dep, nanoarrow_config, arrow_mod, "test_nanoarrow"));
        }
        ci_step.dependOn(addNanoarrowTest(
            b,
            .{
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
            },
            nanoarrow_dep,
            nanoarrow_config,
            createArrowModule(b, .{
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
            }),
            "test_nanoarrow_default",
        ));
        ci_step.dependOn(addNanoarrowTest(
            b,
            .{
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
            },
            nanoarrow_dep,
            nanoarrow_config,
            createArrowModule(b, .{
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
            }),
            "test_nanoarrow_single_threaded",
        ));
    }
}

const ArrowOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    single_threaded: bool,
};

fn addArrowModule(b: *std.Build, name: []const u8, options: ArrowOptions) *std.Build.Module {
    const mod = b.addModule(name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
    });
    addBuildOptions(b, mod, options);
    return mod;
}

fn createArrowModule(b: *std.Build, options: ArrowOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = options.single_threaded,
    });
    addBuildOptions(b, mod, options);
    return mod;
}

fn addRootTest(
    b: *std.Build,
    arrow_mod: *std.Build.Module,
    name: []const u8,
) *std.Build.Step {
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = arrow_mod,
    })).step;
}

fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    single_threaded: bool,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("arrow", createArrowModule(b, .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    }));

    const bench_exe = b.addExecutable(.{
        .name = "arrow_bench",
        .root_module = bench_mod,
    });
    const run = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    return &run.step;
}

fn addDocsCheck(b: *std.Build, arrow_mod: *std.Build.Module) *std.Build.Step {
    const docs_lib = b.addLibrary(.{
        .name = "arrow_docs",
        .root_module = arrow_mod,
    });
    _ = docs_lib.getEmittedDocs();
    return &docs_lib.step;
}

fn addBuildOptions(b: *std.Build, mod: *std.Build.Module, options: ArrowOptions) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", options.single_threaded);
    mod.addOptions("build_options", build_options);
}

fn addNanoarrowTest(
    b: *std.Build,
    options: ArrowOptions,
    nanoarrow_dep: *std.Build.Dependency,
    nanoarrow_config: *std.Build.Step.ConfigHeader,
    arrow_mod: *std.Build.Module,
    name: []const u8,
) *std.Build.Step {
    const nanoarrow_mod = b.createModule(.{
        .root_source_file = b.path("src/cdi/nanoarrow_test.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    addBuildOptions(b, nanoarrow_mod, options);
    nanoarrow_mod.addImport("arrow", arrow_mod);
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
    nanoarrow_mod.addCSourceFile(.{ .file = b.path("src/cdi/nanoarrow_bridge.c") });
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = nanoarrow_mod,
    })).step;
}
