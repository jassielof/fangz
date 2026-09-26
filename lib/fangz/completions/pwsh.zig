const std = @import("std");

pub fn render(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        \\Register-ArgumentCompleter -Native -CommandName '{s}' -ScriptBlock {{
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $tokens = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object {{ $_.Extent.Text }})
        \\    if ($wordToComplete -eq '') {{
        \\        # The word under the cursor is empty, so PowerShell omits it; pass it explicitly.
        \\        # Windows PowerShell 5.1 drops empty native arguments, so send a literal "" there.
        \\        $tokens += if ($PSNativeCommandArgumentPassing -and $PSNativeCommandArgumentPassing -ne 'Legacy') {{ '' }} else {{ '""' }}
        \\    }}
        \\    & {s} __complete @tokens | Where-Object {{ $_ }} | ForEach-Object {{
        \\        $value, $description = $_ -split "`t", 2
        \\        if (-not $description) {{ $description = $value }}
        \\        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
        \\    }}
        \\}}
        \\
    , .{ name, name });
}
