// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = Options.parse(b);

    const arrow_mod = b.addModule("arrow", options.moduleCreateOptions(b, "src/root.zig"));
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "single_threaded", options.single_threaded);
    arrow_mod.addOptions("build_options", build_opts);

    const license_step = addTool(b, "test-license", "Check license headers", "tools/check_license_headers.zig");
    const test_imports_step = addTool(b, "test-imports", "Check root test imports", "tools/check_test_imports.zig");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addTestRun(b, arrow_mod, "test"));

    addBench(b, options, arrow_mod);
    addFuzz(b, options, arrow_mod);

    const ci_step = b.step("ci", "Run CI checks");
    ci_step.dependOn(license_step);
    ci_step.dependOn(test_imports_step);
    ci_step.dependOn(addDocs(b, arrow_mod));
    ci_step.dependOn(test_step);

    addNanoarrow(b, options, arrow_mod, ci_step);
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    single_threaded: bool,

    fn parse(b: *std.Build) Options {
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

    fn moduleCreateOptions(self: @This(), b: *std.Build, root_source_file: []const u8) std.Build.Module.CreateOptions {
        return .{
            .root_source_file = b.path(root_source_file),
            .target = self.target,
            .optimize = self.optimize,
            .single_threaded = self.single_threaded,
        };
    }
};

fn addTestRun(b: *std.Build, root_module: *std.Build.Module, name: []const u8) *std.Build.Step {
    return &b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = root_module,
    })).step;
}

fn addTool(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
) *std.Build.Step {
    const exe = b.addExecutable(.{
        .name = std.fs.path.stem(root_source_file),
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = b.graph.host,
        }),
    });
    const step = b.step(name, description);
    step.dependOn(&b.addRunArtifact(exe).step);
    return step;
}

fn addBench(b: *std.Build, options: Options, arrow_mod: *std.Build.Module) void {
    const step = b.step("bench", "Run benchmarks");
    if (options.optimize != .ReleaseFast) {
        step.dependOn(&b.addFail("zig build bench requires --release=fast").step);
        return;
    }
    const bench_exe = b.addExecutable(.{
        .name = "arrow_bench",
        .root_module = childModule(b, options, "bench/main.zig", arrow_mod),
    });
    const run = b.addRunArtifact(bench_exe);
    run.stdio = .inherit;
    if (b.args) |args| {
        run.addArgs(args);
    }
    step.dependOn(&run.step);
}

fn addFuzz(b: *std.Build, options: Options, arrow_mod: *std.Build.Module) void {
    const step = b.step("fuzz", "Run fuzz target seed corpus checks");
    if (options.optimize != .ReleaseSafe) {
        step.dependOn(&b.addFail("zig build fuzz requires --release=safe").step);
        return;
    }
    step.dependOn(addTestRun(b, childModule(b, options, "fuzz/main.zig", arrow_mod), "test_fuzz"));
}

fn childModule(b: *std.Build, options: Options, root: []const u8, arrow_mod: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(options.moduleCreateOptions(b, root));
    mod.addImport("arrow", arrow_mod);
    return mod;
}

// Force documentation generation to catch public API doc build failures.
fn addDocs(b: *std.Build, arrow_mod: *std.Build.Module) *std.Build.Step {
    const docs_lib = b.addLibrary(.{
        .name = "arrow_docs",
        .root_module = arrow_mod,
    });
    _ = docs_lib.getEmittedDocs();
    return &docs_lib.step;
}

fn addNanoarrow(
    b: *std.Build,
    options: Options,
    arrow_mod: *std.Build.Module,
    ci_step: *std.Build.Step,
) void {
    const dep = b.lazyDependency("nanoarrow", .{}) orelse return;
    const config = b.addConfigHeader(.{
        .style = .{ .cmake = dep.path("src/nanoarrow/nanoarrow_config.h.in") },
        .include_path = "nanoarrow/nanoarrow_config.h",
    }, .{
        .NANOARROW_VERSION_MAJOR = 0,
        .NANOARROW_VERSION_MINOR = 8,
        .NANOARROW_VERSION_PATCH = 0,
        .NANOARROW_VERSION = "0.8.0",
        .NANOARROW_NAMESPACE_DEFINE = "",
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/cdi/nanoarrow_test.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    mod.addImport("arrow", arrow_mod);
    mod.addConfigHeader(config);
    mod.addIncludePath(dep.path("src"));
    mod.addCSourceFiles(.{
        .root = dep.path("src/nanoarrow/common"),
        .files = &.{ "array.c", "schema.c", "utils.c" },
    });
    mod.addCSourceFile(.{ .file = b.path("src/cdi/nanoarrow_bridge.c") });
    ci_step.dependOn(addTestRun(b, mod, "test_nanoarrow"));
}
