const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\_{s}_completion() {{
        \\  local IFS=$'\n'
        \\  COMPREPLY=($("$(COMP_WORDS[0])" __complete "${{COMP_WORDS[@]:1}}"))
        \\}}
        \\complete -o default -F _{s}_completion {s}
        \\
    , .{ name, name, name });
}
