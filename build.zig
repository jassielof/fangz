const std = @import("std");

const git = @import("build/git.zig");
const metadata = @import("build/metadata.zig");
pub const injectMetadata = metadata.injectMetadata;

pub fn build(b: *std.Build) void {
    const mod_name = "fangz";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const carnaval = b.dependency("carnaval", .{}).module("carnaval");
    const trama = b.dependency("trama", .{}).module("trama");

    const mod = b.addModule(
        mod_name,
        .{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "carnaval",
                    .module = carnaval,
                },
                .{
                    .name = "trama",
                    .module = trama,
                },
            },
        },
    );

    // Provide default fangz_meta so the library compiles standalone (e.g. for fangz's own test suite). Consumers who call injectMeta() will overwrite this with their own values.
    const default_meta = b.addOptions();

    default_meta.addOption([]const u8, "name", mod_name);
    default_meta.addOption([]const u8, "version", metadata.manifestVersion(b) orelse "");
    default_meta.addOption([]const u8, "brief", metadata.manifestDescription(b) orelse "");
    default_meta.addOption([]const u8, "author_name", "");
    default_meta.addOption([]const u8, "author_email", "");
    default_meta.addOption([]const u8, "commit", "");
    default_meta.addOption([]const u8, "branch", "");
    default_meta.addOption([]const u8, "source_date", metadata.sourceDate(b));

    mod.addOptions("fangz_meta", default_meta);

    const docs_step = b.step("docs", "Generate the documentation");

    const mod_lib = b.addLibrary(.{
        .name = mod_name,
        .root_module = mod,
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = mod_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs.step);

    const test_step = b.step("test", "Run the test suite");

    const unit_tests = b.addTest(.{
        .name = "Unit",
        .root_module = mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = mod_name,
                .module = mod,
            }},
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    const lint_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{
            "src/",
        },
    });
    lint_step.dependOn(&fmt.step);
}
