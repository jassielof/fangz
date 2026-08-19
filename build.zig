const std = @import("std");

const metadata = @import("build/metadata.zig");
pub const injectMetadata = metadata.injectMetadata;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const carnaval = b.dependency("carnaval", .{
        .target = target,
        .optimize = optimize,
    }).module("carnaval");
    const trama = b.dependency("trama", .{
        .target = target,
        .optimize = optimize,
    }).module("trama");

    const fangz_mod = b.addModule(
        "fangz",
        .{
            .root_source_file = b.path("lib/fangz/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = "carnaval",
                .module = carnaval,
            }, .{
                .name = "trama",
                .module = trama,
            } },
        },
    );

    // Provide default fangz_meta so the library compiles standalone (e.g. for Fangz's own test suite). Consumers who call injectMetadata() overwrite these values with their own metadata.
    const default_meta = b.addOptions();
    default_meta.addOption([]const u8, "name", "fangz");
    default_meta.addOption([]const u8, "version", metadata.manifestVersion(b) orelse "");
    default_meta.addOption([]const u8, "brief", metadata.manifestDescription(b) orelse "");
    default_meta.addOption([]const u8, "author_name", "");
    default_meta.addOption([]const u8, "author_email", "");
    default_meta.addOption([]const u8, "commit", "");
    default_meta.addOption([]const u8, "branch", "");
    default_meta.addOption([]const u8, "source_date", metadata.sourceDate(b));
    fangz_mod.addOptions("fangz_meta", default_meta);

    const docs_step = b.step("docs", "Generate the documentation");
    const fangz_lib = b.addLibrary(.{
        .name = "fangz",
        .root_module = fangz_mod,
    });
    const fangz_docs = b.addInstallDirectory(.{
        .source_dir = fangz_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "docs" },
        .install_subdir = "fangz",
    });
    docs_step.dependOn(&fangz_docs.step);

    const test_step = b.step("test", "Run the test suite");
    const fangz_lib_tests = b.addTest(.{
        .name = "Fangz",
        .root_module = fangz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(fangz_lib_tests).step);

    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "fangz",
            .module = fangz_mod,
        }},
    });

    const fixture_tests = b.addTest(.{
        .name = "Fixture",
        .root_module = fixture_mod,
    });
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);

    const ux_tests = b.addTest(.{
        .name = "UX",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ux.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = "fangz",
                .module = fangz_mod,
            }, .{
                .name = "fixture",
                .module = fixture_mod,
            } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ux_tests).step);

    const documentation_generation_tests = b.addTest(.{
        .name = "Documentation Generation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/docgen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = "fangz",
                .module = fangz_mod,
            }, .{
                .name = "fixture",
                .module = fixture_mod,
            } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(documentation_generation_tests).step);

    const shell_completion_tests = b.addTest(.{
        .name = "Shell Completion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/completion.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = "fangz",
                .module = fangz_mod,
            }, .{
                .name = "fixture",
                .module = fixture_mod,
            } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(shell_completion_tests).step);

    const check_step = b.step("check", "Run code quality checks");
    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{"lib/"},
    });
    check_step.dependOn(&fmt.step);
}
