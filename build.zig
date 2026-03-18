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

    // Provide default fangz_meta so the library compiles standalone (e.g. for
    // fangz's own test suite). Consumers who call injectMeta() will overwrite
    // this with their own name + version.
    const default_meta = b.addOptions();
    default_meta.addOption([]const u8, "name", mod_name);
    default_meta.addOption([]const u8, "version", extractVersion(b) orelse "");
    libary_module.addOptions("fangz_meta", default_meta);

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

/// Injects the consumer's binary name and manifest version into the fangz
/// library module as a `fangz_meta` options module, making them available as
/// defaults inside `App.init`.
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
/// - `name`    is taken from `compile.name` (the executable name).
/// - `version` is extracted from the consumer's `build.zig.zon`.
///
/// After injection, `App.init` will use these as fallback values when `.name`
/// or `.version` are omitted from `App.Init`.
pub fn injectMeta(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    fangz_mod: *std.Build.Module,
) void {
    const options = b.addOptions();
    options.addOption([]const u8, "name", compile.name);
    options.addOption([]const u8, "version", extractVersion(b) orelse "");
    // Overwrite the default fangz_meta that fangz's own build() set up.
    fangz_mod.addOptions("fangz_meta", options);
}

fn extractVersion(b: *std.Build) ?[]const u8 {
    const content = b.build_root.handle.readFileAlloc(
        b.allocator,
        "build.zig.zon",
        64 * 1024,
    ) catch return null;
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const after = content[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    return b.dupe(after[0..end]);
}
