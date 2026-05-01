//! All logic related to Git operations, specially for extracting metadata from the repository and user configuration.

const std = @import("std");

/// Returns the short commit hash of HEAD (`git rev-parse --short HEAD`), or `""` when git is unavailable or the working directory is not a repository.
pub fn extractCommit(b: *std.Build) []const u8 {
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

/// Returns the current branch name (`git rev-parse --abbrev-ref HEAD`), or `""` when git is unavailable or the working directory is not a repository.
///
/// When the repository is in a detached-HEAD state the function falls back to the first entry returned by `git for-each-ref refs/heads`, which covers the common case of a bare-clone / worktree checkout where `refs/heads/<branch>` is always present.
pub fn extractBranch(b: *std.Build) []const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .cwd = .inherit,
    }) catch return "";

    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) return "";
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");

    if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "HEAD")) {
        return b.dupe(trimmed);
    }

    // Detached HEAD: read refs/heads (shared with the bare repo via the worktree). In a bare clone / git worktree, refs/heads/<branch> is always present.
    const refs = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads" },
        .cwd = .inherit,
    }) catch return "";

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

// TODO: Implement author (not commiter) extraction
/// Using `git show -s --format=%aN HEAD`
pub fn commitAuthor(b: *std.Build) ?[]const u8 {}
// TODO: Implement email extraction
/// Using `git show -s --format=%aE HEAD`
pub fn commitEmail(b: *std.Build) ?[]const u8 {}

pub fn commitDate(b: *std.Build) ?[]const u8 {
    if (!std.process.can_spawn) return null;

    const git = b.findProgram(&.{"git"}, &.{}) catch return null;
    var code: u8 = undefined;

    const output = b.runAllowFail(
        &.{
            git,
            "-C",
            b.build_root.path orelse ".",
            "show",
            "-s",
            "--format=%cs",
            "HEAD",
        },
        &code,
        .ignore,
    ) catch return null;

    if (code != 0) return null;

    const date = std.mem.trim(u8, output, " \t\r\n");

    if (date.len == 0) return null;

    return date;
}
