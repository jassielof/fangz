const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod_name = "fangz";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const carnaval_dep = b.dependency(
        "carnaval",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const carnaval_mod = carnaval_dep.module("carnaval");

    const libary_module = b.addModule(
        mod_name,
        .{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "carnaval",
                .module = carnaval_mod,
            }},
        },
    );

    // Provide default fangz_meta so the library compiles standalone (e.g. for fangz's own test suite). Consumers who call injectMeta() will overwrite this with their own values.
    const default_meta = b.addOptions();
    default_meta.addOption([]const u8, "name", mod_name);
    default_meta.addOption([]const u8, "version", extractVersion(b) orelse "");
    default_meta.addOption([]const u8, "commit", "");
    default_meta.addOption([]const u8, "branch", "");
    libary_module.addOptions("fangz_meta", default_meta);

    const docs_step = b.step("docs", "Generate the documentation");

    const documentation_library = b.addLibrary(.{
        .name = mod_name,
        .root_module = libary_module,
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = documentation_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs.step);

    const test_step = b.step("tests", "Run the test suite");

    const unit_tests = b.addTest(.{
        .name = "Unit Tests",
        .root_module = libary_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .name = "Integration Tests",
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

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}

/// Injects the consumer's binary name, manifest version, and current git commit/branch into the fangz library module as a `fangz_meta` options module, making them available as defaults inside `App.init`.
///
/// Call this from your `build.zig` after resolving the fangz dependency:
///
/// ```zig
/// const fangz_dep = b.dependency("fangz", .{ .target = target, .optimize = optimize });
/// const fangz_mod = fangz_dep.module("fangz");
/// // wire fangz_mod into your executable's imports as usual, then:
/// const fangz_build = @import("fangz"); // imports fangz's build.zig
/// fangz_build.injectMeta(b, exe, fangz_mod);
/// ```
///
/// Injected fields:
/// - `name`: `compile.name` (the executable name)
/// - `version`: extracted from the consumer's `build.zig.zon`
/// - `commit`: short git commit hash (`git rev-parse --short HEAD`)
/// - `branch`: current git branch (`git rev-parse --abbrev-ref HEAD`)
///
/// Git fields fall back to `""` when git is unavailable or the directory is not a repository. After injection, `App.init` uses these as fallback values when `.name`, `.version`, `.commit`, or `.branch` are omitted.
pub fn injectMeta(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    fangz_mod: *std.Build.Module,
) void {
    const options = b.addOptions();
    options.addOption([]const u8, "name", compile.name);
    options.addOption([]const u8, "version", extractVersion(b) orelse "");
    options.addOption([]const u8, "commit", extractGitCommit(b));
    options.addOption([]const u8, "branch", extractGitBranch(b));
    // Overwrite the default fangz_meta that fangz's own build() set up.
    fangz_mod.addOptions("fangz_meta", options);
}

fn extractVersion(b: *std.Build) ?[]const u8 {
    var io_impl: std.Io.Threaded = .init(b.allocator, .{});
    defer io_impl.deinit();

    const io = io_impl.io();
    const content = b.build_root.handle.readFileAlloc(
        io,
        "build.zig.zon",
        b.allocator,
        .unlimited,
    ) catch return null;
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const after = content[start + marker.len ..];
    const end = std.mem.findScalar(u8, after, '"') orelse return null;
    return b.dupe(after[0..end]);
}

fn extractGitCommit(b: *std.Build) []const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .cwd = .inherit,
    }) catch return "";
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) return "";
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return if (trimmed.len > 0) b.dupe(trimmed) else "";
}

fn extractGitBranch(b: *std.Build) []const u8 {
    const result = std.process.run(
        b.allocator,
        b.graph.io,
        .{
            .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
            .cwd = .inherit,
        },
    ) catch return "";
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) return "";
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "HEAD")) {
        return b.dupe(trimmed);
    }

    // Detached HEAD: read refs/heads (shared with the bare repo via the worktree).
    // In a bare clone zigit worktree, refs/heads/main is always present.
    const refs = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads" },
        .cwd = .inherit,
    },) catch return "";
    defer {
        b.allocator.free(refs.stdout);
        b.allocator.free(refs.stderr);
    }
    if (refs.term != .exited or refs.term.exited != 0) return "";
    const refs_trim = std.mem.trim(u8, refs.stdout, " \n\r\t");
    if (refs_trim.len > 0) {
        const newline = std.mem.findScalar(u8, refs_trim, '\n') orelse refs_trim.len;
        const first = std.mem.trim(u8, refs_trim[0..newline], " \r\t");
        if (first.len > 0) return b.dupe(first);
    }
    return "";
}
