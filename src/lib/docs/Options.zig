//! Options for AsciiDoc documentation generation.

/// Output directory.
output_dir: []const u8 = "zig-out/docs",
// TODO: Rename to output_file_name
/// Output file name.
single_file_name: []const u8 = "cli.adoc",
// TODO: Path to the directory? or the file name?
/// Optional custom Trama template path.
template_path: ?[]const u8 = null,
/// When true, hidden commands are included.
include_hidden: bool = false,
// TODO: Check if an error is emitted when the output file already exists and overwrite is false.
/// Whether to overwrite an existing output file, otherwise an error is emitted.
overwrite: bool = true,
// TODO: Remove, only the AsciiDoc ToC should be used.
/// When true, emits a redundant command index (AsciiDoc ToC is preferred).
include_command_index: bool = false,
/// AsciiDoc's table of contents placement. See <https://docs.asciidoctor.org/asciidoc/latest/toc/position/>.
toc_position: []const u8 = "auto",
