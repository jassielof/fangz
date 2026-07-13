//! Options for AsciiDoc documentation generation.

pub const TocPosition = enum {
    auto,
    macro,
    preamble,
    left,
    right,

    /// Value written after `:toc:` in generated AsciiDoc.
    pub fn toString(self: TocPosition) []const u8 {
        return @tagName(self);
    }
};

/// Directory where the AsciiDoc output file is written (created if missing).
output_dir: []const u8 = "zig-out/docs",
/// Output file name within `output_dir`. When empty, the module name is used.
output_file_name: []const u8 = "",
/// Optional path to a custom Trama template file (AsciiDoc source). Relative paths use the process working directory.
template_path: ?[]const u8 = null,
/// When true, hidden commands are included.
include_hidden: bool = false,
/// When false and the output file already exists, generation fails with `error.PathAlreadyExists` instead of replacing it.
overwrite: bool = true,
/// AsciiDoc `:toc:` placement attribute. See <https://docs.asciidoctor.org/asciidoc/latest/toc/position/>.
toc_position: TocPosition = .auto,
