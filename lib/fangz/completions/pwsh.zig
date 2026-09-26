const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\Register-ArgumentCompleter -Native -CommandName '{s}' -ScriptBlock {{
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $tokens = $commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object {{ $_.Extent.Text }}
        \\    & {s} __complete @tokens | Where-Object {{ $_ }} | ForEach-Object {{
        \\        $value, $description = $_ -split "`t", 2
        \\        if (-not $description) {{ $description = $value }}
        \\        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
        \\    }}
        \\}}
        \\
    , .{ name, name });
}
