// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = Config.parse(b);
    const arrow_mod = registerArrowModule(b, "arrow", options);

    const license_step = addHostToolCheck(
        b,
        "test-license",
        "Check license headers",
        "tools/check_license_headers.zig",
        "check_license_headers",
    );
    const test_imports_step = addHostToolCheck(
        b,
        "test-imports",
        "Check root test imports",
        "tools/check_test_imports.zig",
        "check_test_imports",
    );

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addTestRun(b, arrow_mod, "test"));

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(addBenchmarkRun(b, options));

    addFuzzStep(b, options);

    const ci_step = b.step("ci", "Run CI checks");
    ci_step.dependOn(license_step);
    ci_step.dependOn(test_imports_step);
    ci_step.dependOn(addDocsCheck(b, arrow_mod));
    ci_step.dependOn(addTestRun(b, createArrowModule(b, options.withThreading(false)), "test_default"));
    ci_step.dependOn(addTestRun(b, createArrowModule(b, options.withThreading(true)), "test_single_threaded"));

    addNanoarrowSteps(b, options, ci_step);
}

const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    single_threaded: bool,

    fn parse(b: *std.Build) @This() {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .single_threaded = b.option(
                bool,
                "single_threaded",
                "Disable atomic buffer refcounts (single-threaded use only). Default: false.",
            ) orelse false,
        };
    }

    fn withThreading(self: @This(), single_threaded: bool) @This() {
        var next = self;
        next.single_threaded = single_threaded;
        return next;
    }

    fn asOptions(self: @This(), b: *std.Build, root_source_file: []const u8) std.Build.Module.CreateOptions {
        return .{
            .root_source_file = b.path(root_source_file),
            .target = self.target,
            .optimize = self.optimize,
            .single_threaded = self.single_threaded,
        };
    }
};

// Public package module exposed to dependents as `arrow`.
fn registerArrowModule(b: *std.Build, name: []const u8, config: Config) *std.Build.Module {
    const mod = b.addModule(name, config.asOptions(b, "src/root.zig"));
    addBuildOptions(b, mod, config);
    return mod;
}

// Private arrow module instance for tests/tools that need different options.
fn createArrowModule(b: *std.Build, config: Config) *std.Build.Module {
    const mod = b.createModule(config.asOptions(b, "src/root.zig"));
    addBuildOptions(b, mod, config);
    return mod;
}

// Build and run a Zig test artifact rooted at an already configured module.
fn addTestRun(b: *std.Build, root_module: *std.Build.Module, name: []const u8) *std.Build.Step {
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = root_module,
    })).step;
}

// Run a repository maintenance tool both as tests and as an executable.
fn addHostToolCheck(
    b: *std.Build,
    step_name: []const u8,
    step_description: []const u8,
    root_source_file: []const u8,
    executable_name: []const u8,
) *std.Build.Step {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = b.graph.host,
    });
    const check = b.addExecutable(.{
        .name = executable_name,
        .root_module = mod,
    });
    const tests = b.addTest(.{ .root_module = mod });
    const step = b.step(step_name, step_description);
    step.dependOn(&b.addRunArtifact(tests).step);
    step.dependOn(&b.addRunArtifact(check).step);
    return step;
}

// Benchmark binaries default to ReleaseFast independent of the main optimize mode.
fn addBenchmarkRun(b: *std.Build, config: Config) *std.Build.Step {
    const bench_mod = b.createModule(config.asOptions(b, "bench/main.zig"));
    bench_mod.addImport("arrow", createArrowModule(b, config));

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

// Top-level fuzz step; keep the optimize-mode guard close to the public command.
fn addFuzzStep(b: *std.Build, config: Config) void {
    const step = b.step("fuzz", "Run fuzz target seed corpus checks");
    if (config.optimize != .ReleaseSafe) {
        step.dependOn(&b.addFail("zig build fuzz requires --release=safe").step);
        return;
    }

    step.dependOn(addFuzzRun(b, config));
}

// The fuzz artifact is outside src/ so normal `zig build test` never imports it.
fn addFuzzRun(b: *std.Build, config: Config) *std.Build.Step {
    const fuzz_mod = b.createModule(config.asOptions(b, "fuzz/main.zig"));
    fuzz_mod.addImport("arrow", createArrowModule(b, config));
    return addTestRun(b, fuzz_mod, "test_fuzz");
}

// Force documentation generation to catch public API doc build failures.
fn addDocsCheck(b: *std.Build, arrow_mod: *std.Build.Module) *std.Build.Step {
    const docs_lib = b.addLibrary(.{
        .name = "arrow_docs",
        .root_module = arrow_mod,
    });
    _ = docs_lib.getEmittedDocs();
    return &docs_lib.step;
}

// Every module compiling library code gets the same package build options.
fn addBuildOptions(b: *std.Build, mod: *std.Build.Module, config: Config) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "single_threaded", config.single_threaded);
    mod.addOptions("build_options", build_options);
}

// Optional local test dependency; CI always exercises it when available.
fn addNanoarrowSteps(
    b: *std.Build,
    options: Config,
    ci_step: *std.Build.Step,
) void {
    const nanoarrow_dep = b.lazyDependency("nanoarrow", .{}) orelse return;
    const nanoarrow_config = addNanoarrowConfig(b, nanoarrow_dep);

    inline for (.{
        .{ false, "test_nanoarrow_default" },
        .{ true, "test_nanoarrow_single_threaded" },
    }) |case| {
        const config = options.withThreading(case[0]);
        ci_step.dependOn(addNanoarrowInteropTest(
            b,
            config,
            nanoarrow_dep,
            nanoarrow_config,
            createArrowModule(b, config),
            case[1],
        ));
    }
}

// Generate the config header nanoarrow's C sources expect.
fn addNanoarrowConfig(
    b: *std.Build,
    nanoarrow_dep: *std.Build.Dependency,
) *std.Build.Step.ConfigHeader {
    return b.addConfigHeader(.{
        .style = .{ .cmake = nanoarrow_dep.path("src/nanoarrow/nanoarrow_config.h.in") },
        .include_path = "nanoarrow/nanoarrow_config.h",
    }, .{
        .NANOARROW_VERSION_MAJOR = 0,
        .NANOARROW_VERSION_MINOR = 8,
        .NANOARROW_VERSION_PATCH = 0,
        .NANOARROW_VERSION = "0.8.0",
        .NANOARROW_NAMESPACE_DEFINE = "",
    });
}

// Compile the C bridge and run the Zig interop tests against nanoarrow.
fn addNanoarrowInteropTest(
    b: *std.Build,
    config: Config,
    nanoarrow_dep: *std.Build.Dependency,
    nanoarrow_config: *std.Build.Step.ConfigHeader,
    arrow_mod: *std.Build.Module,
    name: []const u8,
) *std.Build.Step {
    const nanoarrow_mod = b.createModule(.{
        .root_source_file = b.path("src/cdi/nanoarrow_test.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    addBuildOptions(b, nanoarrow_mod, config);
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
