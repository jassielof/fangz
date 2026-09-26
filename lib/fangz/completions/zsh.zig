const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\#{s} completion
        \\_{s}_completion() {{
        \\  local -a reply
        \\  local line value
        \\  for line in "${{(@f)$({s} __complete "${{(@)words[2,-1]}}")}}"; do
        \\    [[ -n $line ]] || continue
        \\    value=${{line%%$'\t'*}}
        \\    if [[ $line == *$'\t'* ]]; then
        \\      reply+=("${{value//:/\\:}}:${{line#*$'\t'}}")
        \\    else
        \\      reply+=("${{value//:/\\:}}")
        \\    fi
        \\  done
        \\  _describe 'values' reply
        \\}}
        \\compdef _{s}_completion {s}
        \\
    , .{ name, name, name, name, name });
}
