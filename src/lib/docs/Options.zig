//! Options for AsciiDoc documentation generation.

/// Output directory.
output_dir: []const u8 = "docs",
/// Output file name.
single_file_name: []const u8 = "cli.adoc",
/// Optional custom Trama template path.
template_path: ?[]const u8 = null,
/// When true, hidden commands are included.
include_hidden: bool = false,
/// When true, existing files are overwritten.
overwrite: bool = true,
/// When true, emits a redundant command index (AsciiDoc ToC is preferred).
include_command_index: bool = false,
/// AsciiDoc `toc` placement (e.g. `auto`, `left`).
toc: []const u8 = "auto",
