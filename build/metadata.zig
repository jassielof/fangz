const std = @import("std");

const git = @import("git.zig");

const PartialManifest = struct {
    version: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
};

pub fn sourceDate(b: *std.Build) []const u8 {
    return git.commitDate(b) orelse buildDate(b);
}

// TODO: Rename to default docs template, otherwise sounds too generic
// TODO: There's no need 
pub fn defaultTemplatePath(b: *std.Build, fangz_mod: ?*std.Build.Module) []const u8 {
    if (fangz_mod) |mod| {
        if (mod.root_source_file) |root_source_file| {
            const template = root_source_file.dirname().path(b, "templates/default.adoc");
            return template.getPath2(b, null);
        }
    }

    return b.pathFromRoot("src/lib/templates/default.adoc");
}

pub fn buildDate(b: *std.Build) []const u8 {
    const now = std.Io.Timestamp.now(b.graph.io, .real);
    const seconds: usize = @intCast(now.toSeconds());

    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = seconds,
    };

    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return b.fmt("{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

pub fn manifestVersion(b: *std.Build) ?[]const u8 {
    const content = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .unlimited,
    ) catch return null;
    defer b.allocator.free(content);

    const source = b.allocator.dupeZ(u8, content) catch return null;
    defer b.allocator.free(source);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(b.allocator);

    const manifest = std.zon.parse.fromSliceAlloc(
        PartialManifest,
        b.allocator,
        source,
        &diag,
        .{
            .ignore_unknown_fields = true,
            .free_on_error = true,
        },
    ) catch return null;
    defer std.zon.parse.free(b.allocator, manifest);

    return if (manifest.version.len > 0) b.dupe(manifest.version) else null;
}

fn compileVersion(b: *std.Build, compile: *std.Build.Step.Compile) ?[]const u8 {
    const version = compile.version orelse return null;
    return b.fmt("{f}", .{version});
}

/// Injects the consumer's binary name, manifest version, and current git metadata into the fangz library module as a `fangz_meta` options module, making them available as defaults inside `App.init`.
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
///
/// - `name`: `compile.name` (the executable name from `b.addExecutable`, used as the CLI command name)
/// - `version`: `compile.version` from `b.addExecutable` when present, otherwise the consumer's `build.zig.zon` version
/// - `author_name`: git author name for `HEAD`
/// - `author_email`: git author email for `HEAD`
/// - `commit`: short git commit hash (`git rev-parse --short HEAD`)
/// - `branch`: current git branch (`git rev-parse --abbrev-ref HEAD`)
/// - `source_date`: git commit date, falling back to the build date
///
/// Git fields fall back to `""` when git is unavailable or the directory is not a repository. After injection, `App.init` uses these as fallback values when corresponding fields are omitted.
pub fn injectMetadata(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    fangz_mod: *std.Build.Module,
) void {
    const options = b.addOptions();

    options.addOption([]const u8, "name", compile.name);
    options.addOption([]const u8, "version", compileVersion(b, compile) orelse manifestVersion(b) orelse "");
    options.addOption([]const u8, "author_name", git.commitAuthor(b) orelse "");
    options.addOption([]const u8, "author_email", git.commitEmail(b) orelse "");
    options.addOption([]const u8, "commit", git.extractCommit(b));
    options.addOption([]const u8, "branch", git.extractBranch(b));
    options.addOption([]const u8, "source_date", sourceDate(b));
    options.addOption([]const u8, "default_template_path", defaultTemplatePath(b, fangz_mod));

    // Overwrite the default fangz_meta that fangz's own build() set up.
    fangz_mod.addOptions("fangz_meta", options);
}
