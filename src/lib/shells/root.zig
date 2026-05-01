//! The shells module, for handling shell-specific logic such as completion script generation.

/// Supported shell targets for completion script generation.
pub const Shell = enum {
    /// <https://www.gnu.org/software/bash/>
    bash,
    /// <https://www.zsh.org/>
    zsh,
    /// <https://fishshell.com/>
    fish,
    /// <https://www.microsoft.com/PowerShell>
    pwsh,
    /// <https://www.nushell.sh/>
    nu,

    /// Returns the human-friendly name of the shell.
    pub fn toPrettyName(self: Shell) []const u8 {
        return switch (self) {
            .bash => "Bash",
            .zsh => "Zsh",
            .fish => "Fish",
            .pwsh => "PowerShell",
            .nu => "Nushell",
        };
    }

    /// Returns the string name of the shell, based off the enum tag.
    pub fn toStringName(self: Shell) []const u8 {
        return @tagName(self);
    }

    /// Returns a list of allowed string values for the Shell enum.
    pub fn allowedValues() []const []const u8 {
        return comptime blk: {
            const fields = @typeInfo(Shell).@"enum".fields;
            var values: [fields.len][]const u8 = undefined;

            for (fields, 0..) |field, i| {
                values[i] = field.name;
            }

            const final = values;

            break :blk &final;
        };
    }
};
