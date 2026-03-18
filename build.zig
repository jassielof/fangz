const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod_name = "fangz";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const carnaval_dep = b.dependency("carnaval", .{
        .target = target,
        .optimize = optimize,
    });
    const carnaval_mod = carnaval_dep.module("carnaval");

    const libary_module = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "carnaval",
            .module = carnaval_mod,
        }},
    });

    const documentation_library = b.addLibrary(.{
        .name = mod_name,
        .root_module = libary_module,
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = documentation_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate the documentation");
    docs_step.dependOn(&docs.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = mod_name,
                .module = libary_module,
            }},
        }),
    });

    const test_step = b.step("tests", "Run the test suite");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
