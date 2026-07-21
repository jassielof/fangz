const std = @import("std");

const git = @import("build/git.zig");
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

    // Provide default fangz_meta so the library compiles standalone (e.g. for fangz's own test suite). Consumers who call injectMeta() will overwrite this with their own values.
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

    const run_fangz_lib_tests = b.addRunArtifact(fangz_lib_tests);
    test_step.dependOn(&run_fangz_lib_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "fangz",
                .module = fangz_mod,
            }},
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    const check_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{"lib/"},
    });
    check_step.dependOn(&fmt.step);
}
