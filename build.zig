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

    const e2e_step = b.step("e2e", "Build the end-to-end sample application");

    const e2e_app = b.addExecutable(.{
        .name = "fangz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "fangz",
                .module = fangz_mod,
            }},
        }),
    });
    const install_e2e_app = b.addInstallArtifact(e2e_app, .{});

    e2e_step.dependOn(&install_e2e_app.step);
    const run_e2e = b.addRunArtifact(e2e_app);
    e2e_step.dependOn(&run_e2e.step);

    if (b.args) |args| run_e2e.addArgs(args);

    const e2e_completions_step = b.step("e2e-completions", "Generate completions for the end-to-end sample application");
    const completion_shells: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{ "nu", "pwsh" },
        else => &.{ "bash", "zsh", "fish", "nu", "pwsh" },
    };

    for (completion_shells) |shell| {
        const generate_completion = b.addRunArtifact(e2e_app);
        generate_completion.addArgs(&.{ "completion", shell });
        const completion = generate_completion.captureStdOut(.{
            .basename = b.fmt("fangz.{s}", .{completionExtension(shell)}),
        });
        const install_completion = b.addInstallFile(
            completion,
            b.fmt("completions/fangz.{s}", .{completionExtension(shell)}),
        );
        e2e_completions_step.dependOn(&install_completion.step);
    }

    const e2e_docs_step = b.step("e2e-docs", "Generate docs for the end-to-end sample application");
    const generate_e2e_docs = b.addRunArtifact(e2e_app);
    generate_e2e_docs.addArgs(&.{ "docs" });
    e2e_docs_step.dependOn(&generate_e2e_docs.step);

    const check_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{ "e2e/", "lib/" },
    });
    check_step.dependOn(&fmt.step);
}

fn completionExtension(shell: []const u8) []const u8 {
    return if (std.mem.eql(u8, shell, "pwsh")) "ps1" else shell;
}
