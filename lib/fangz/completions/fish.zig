const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\function __{s}_complete
        \\  set -l tokens (commandline -opc)
        \\  set -e tokens[1]
        \\  {s} __complete $tokens
        \\end
        \\complete -f -c {s} -a "(__{s}_complete)"
        \\
    , .{ name, name, name, name });
}
