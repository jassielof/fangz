//! Application options and configuration.

/// Human-friendly name used by generated documentation. Defaults to the injected executable name.
display_name: ?[]const u8 = null,
/// Short subtitle rendered after the display name in generated documentation.
tagline: []const u8 = "",
// TODO: Add doc comments to description field
description: []const u8 = "",
/// Semver string. Defaults to the version from the consumer's `build.zig.zon` injected by `injectMeta`. Pass an explicit value to override, or pass `""` to suppress the `--version` flag entirely.
version: ?[]const u8 = null,
/// Author name used by generated documentation. Defaults to the Git author name injected by `injectMeta`.
author_name: ?[]const u8 = null,
/// Author email used by generated documentation. Defaults to the Git author email injected by `injectMeta`.
author_email: ?[]const u8 = null,
/// Source date used by generated documentation. Defaults to the injected Git commit date, falling back to the build date.
source_date: ?[]const u8 = null,
/// Short git commit hash. Defaults to the injected value from `injectMeta`.
/// Pass `""` to suppress from `--version` output.
commit: ?[]const u8 = null,
/// Git branch name. Defaults to the injected value from `injectMeta`.
/// Pass `""` to suppress from `--version` output.
branch: ?[]const u8 = null,
