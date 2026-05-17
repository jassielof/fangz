name: []const u8,
/// Human-friendly display name used by generated documentation.
display_name: []const u8 = "",
/// Short tagline rendered after the display name in generated documentation.
tagline: []const u8 = "",
/// One-line summary shown in `-h` and `--help` output.
description: []const u8 = "",
/// Extended description shown only in `--help` output.
long_description: []const u8 = "",
/// Root-level examples for generated docs / long help (see `CliExample`).
examples: ?[]const CliExample = null,
/// When set, `Usage` / synopsis lines use this text verbatim (may include `\\n`) instead of deriving from positionals and subcommands.
/// Borrowed — not freed by `Command` unless you replace it via `setUsageOverrideFormat` (heap-owned override).
usage_override: ?[]const u8 = null,
version: ?[]const u8 = null,
/// Author name used by generated documentation.
author_name: []const u8 = "",
/// Author email used by generated documentation.
author_email: []const u8 = "",
/// Git branch name used by generated documentation.
git_branch: []const u8 = "",
/// Git commit hash used by generated documentation.
git_commit: []const u8 = "",
/// Source date used by generated documentation.
source_date: []const u8 = "",
group_id: ?[]const u8 = null,

const CliExample = @import("../Command.zig").CliExample;
