const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\#{s} completion
        \\_{s}_completion() {{
        \\  local -a reply
        \\  reply=("${{(@f)$({s} __complete ${{words[2,-1]}})}}")
        \\  _describe 'values' reply
        \\}}
        \\compdef _{s}_completion {s}
        \\
    , .{ name, name, name, name, name });
}
