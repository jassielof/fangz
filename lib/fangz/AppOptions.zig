//! Application options and configuration.

/// Selects where an author field's value comes from.
pub const AuthorSource = union(enum) {
    /// Use this literal value, bypassing Git-based injection.
    custom: []const u8,
    /// Suppress the field entirely (renders as an empty string).
    none,
    /// Use the value injected by `injectMeta` from `HEAD`'s Git author (the default).
    git,
};

/// Human-friendly name used by generated documentation. Defaults to the injected executable name.
display_name: ?[]const u8 = null,
/// Short subtitle rendered after the display name in generated documentation.
tagline: []const u8 = "",
/// Short help for the root command. Defaults to the injected manifest summary when empty (see `injectMetadata`).
brief: []const u8 = "",
/// Long help prose for the root command (`--help` only).
description: []const u8 = "",
/// Semver string. Defaults to the version from the consumer's `build.zig.zon` injected by `injectMeta`. Pass an explicit value to override, or pass `""` to suppress the `--version` flag entirely.
version: ?[]const u8 = null,
/// Author name used by generated documentation.
///
/// `.git` (the default) uses the Git author name for `HEAD` injected by `injectMeta`, falling back to an empty string when there is no Git author. Pass `.{ .custom = "..." }` to override, or `.none` to suppress the field entirely.
author_name: AuthorSource = .git,
/// Author email used by generated documentation. Same resolution rules as `author_name`.
author_email: AuthorSource = .git,
/// Source date used by generated documentation. Defaults to the injected Git commit date, falling back to the build date.
source_date: ?[]const u8 = null,
/// Short git commit hash. Defaults to the injected value from `injectMeta`.
/// Pass `""` to suppress from `--version` output.
commit: ?[]const u8 = null,
/// Git branch name. Defaults to the injected value from `injectMeta`.
/// Pass `""` to suppress from `--version` output.
branch: ?[]const u8 = null,
