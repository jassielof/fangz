//! Shell completion script generation and runtime suggestion endpoint.
//!
//! This module provides script emitters for multiple shells and a shared `__complete` runtime suggestion path.

const std = @import("std");

const Command = @import("Command.zig");
pub const bash = @import("completions/bash.zig");
pub const fish = @import("completions/fish.zig");
pub const nu = @import("completions/nu.zig");
pub const pwsh = @import("completions/pwsh.zig");
pub const zsh = @import("completions/zsh.zig");
const ParseContext = @import("ParseContext.zig");

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

    pub fn parse(input: []const u8) ?Shell {
        if (std.mem.eql(u8, input, "nushell")) return .nu;

        inline for (@typeInfo(Shell).@"enum".fields) |field| {
            if (std.mem.eql(u8, input, field.name)) return @enumFromInt(field.value);
        }

        return null;
    }
};

pub fn render(writer: *std.Io.Writer, root: *const Command, shell: Shell) !void {
    switch (shell) {
        .bash => try bash.render(writer, root.name),
        .zsh => try zsh.render(writer, root.name),
        .fish => try fish.render(writer, root.name),
        .pwsh => try pwsh.render(writer, root.name),
        .nu => try nu.render(writer, root, root.name, true),
    }
}

fn shellAllowedValueLabels() []const []const u8 {
    return comptime blk: {
        const fields = @typeInfo(Shell).@"enum".fields;
        var labels: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            const shell_val: Shell = @enumFromInt(field.value);
            labels[i] = shell_val.toPrettyName();
        }
        const final = labels;
        break :blk &final;
    };
}

pub fn registerCompletionCommand(root: *Command) !void {
    if (root.findSubcommand("completion") != null) return;
    if (root.findSubcommand("completions") != null) return;

    const completion = try root.addSubcommand(.{
        .name = "completion",
        .brief = "Generate shell completion scripts",
    });

    try completion.addAlias("completions");

    try completion.addPositional(.{
        .name = "shell",
        .brief = "Target shell.",
        .required = true,
        .allowed_values = Shell.allowedValues(),
        .allowed_value_labels = shellAllowedValueLabels(),
        .allowed_values_style = .bullet_list,
    });

    completion.setHelpOnEmptyArgs(true);
    completion.setHooks(.{ .run = runCompletionCommand });
}

pub fn runCompletionCommand(ctx: *ParseContext) !void {
    const shell = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printCompletionScript(ctx.io, ctx.command.root(), shell);
}

pub fn printCompletionScript(io: std.Io, root: *Command, shell: []const u8) !void {
    const parsed_shell = Shell.parse(shell) orelse return error.InvalidEnumValue;
    var buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);

    try render(&out.interface, root, parsed_shell);
    try out.interface.flush();
}

pub fn generateCompletions(root: *const Command, shell: Shell, writer: *std.Io.Writer) !void {
    try render(writer, root, shell);
}

pub fn printDynamicSuggestions(io: std.Io, root: *Command, args: []const []const u8) !void {
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);

    try writeDynamicSuggestions(&out.interface, root, args);
    try out.interface.flush();
}

/// Writes the suggestions for the hidden `__complete` command to `writer`, one per line as `value` or `value<TAB>description`.
pub fn writeDynamicSuggestions(writer: *std.Io.Writer, root: *Command, args: []const []const u8) !void {
    const active = activeCommand(root, args);
    const prefix = if (args.len > 0) args[args.len - 1] else "";

    if (std.mem.startsWith(u8, prefix, "-")) {
        try suggestFlags(writer, active, prefix);
    } else {
        try suggestCommands(writer, active, prefix);
    }
}

fn activeCommand(root: *Command, args: []const []const u8) *Command {
    var active = root;
    var i: usize = 0;

    while (i + 1 < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.startsWith(u8, tok, "-")) {
            if (flagExpectsValue(active, tok) and i + 1 < args.len) i += 1;
            continue;
        }

        if (active.findSubcommand(tok)) |sub| active = sub;
    }

    return active;
}

/// Writes one suggestion as `value` or `value<TAB>description`.
///
/// This is the wire format of the hidden `__complete` command; each shell script splits on the tab and uses the description where the shell can show one. The description is reduced to its first line so it can never break the line-oriented protocol.
fn writeSuggestion(writer: *std.Io.Writer, value: []const u8, description: []const u8) !void {
    try writer.writeAll(value);

    const line_end = std.mem.indexOfAny(u8, description, "\r\n") orelse description.len;
    const first_line = std.mem.trim(u8, description[0..line_end], " \t");
    if (first_line.len > 0) {
        try writer.writeByte('\t');
        for (first_line) |byte| try writer.writeByte(if (byte == '\t') ' ' else byte);
    }

    try writer.writeByte('\n');
}

fn suggestCommands(writer: *std.Io.Writer, cmd: *const Command, prefix: []const u8) !void {
    for (cmd.subcommands.items) |sub| {
        if (prefix.len == 0 or std.mem.startsWith(u8, sub.name, prefix)) {
            try writeSuggestion(writer, sub.name, sub.brief);
        }
    }

    if (prefix.len == 0 or std.mem.startsWith(u8, "help", prefix)) {
        try writeSuggestion(writer, "help", "Print this message or the help of the given subcommand(s)");
    }
}

fn suggestFlags(writer: *std.Io.Writer, cmd: *const Command, prefix: []const u8) !void {
    if (try suggestFlagValuePrefix(writer, cmd, prefix)) return;

    var chain = try cmd.collectAncestorPath(std.heap.page_allocator);
    defer chain.deinit(std.heap.page_allocator);

    for (chain.items) |ancestor| {
        for (ancestor.flags.constSlice()) |flag| {
            if (ancestor != cmd and !flag.persistent) continue;

            var long_buf: [256]u8 = undefined;
            const long = std.fmt.bufPrint(&long_buf, "--{s}", .{flag.name}) catch continue;
            if (std.mem.startsWith(u8, long, prefix)) try writeSuggestion(writer, long, flag.brief);

            if (flag.short) |s| {
                var short_buf: [2]u8 = .{ '-', s };
                const short = short_buf[0..];
                if (std.mem.startsWith(u8, short, prefix)) try writeSuggestion(writer, short, flag.brief);
            }
        }
    }

    if (std.mem.startsWith(u8, "--help", prefix)) try writeSuggestion(writer, "--help", "Print help");

    if (std.mem.startsWith(u8, "-h", prefix)) try writeSuggestion(writer, "-h", "Print help");

    if (cmd.parent == null and cmd.rootConst().version != null) {
        if (std.mem.startsWith(u8, "--version", prefix)) try writeSuggestion(writer, "--version", "Print version");
        if (std.mem.startsWith(u8, "-V", prefix)) try writeSuggestion(writer, "-V", "Print version");
    }
}

fn suggestFlagValuePrefix(writer: *std.Io.Writer, cmd: *const Command, prefix: []const u8) !bool {
    if (!std.mem.startsWith(u8, prefix, "--")) return false;

    const body = prefix[2..];
    const eq_idx = std.mem.indexOfScalar(u8, body, '=') orelse return false;
    const flag_name = body[0..eq_idx];
    const value_prefix = body[eq_idx + 1 ..];
    const name_prefix = prefix[0 .. 2 + eq_idx + 1];

    const lookup = cmd.resolveFlagByName(flag_name) orelse return false;
    const flag = lookup.command.flags.constSlice()[lookup.index];
    try suggestFlagValues(writer, name_prefix, flag, value_prefix);
    return true;
}

fn suggestFlagValues(
    writer: *std.Io.Writer,
    name_prefix: []const u8,
    flag: Command.Flag,
    value_prefix: []const u8,
) !void {
    if (flag.value_type == .key_value_list) {
        if (std.mem.indexOfScalar(u8, value_prefix, '=')) |kv_eq| {
            const key = value_prefix[0..kv_eq];
            const val_prefix = value_prefix[kv_eq + 1 ..];
            if (flag.key_value_help) |kv| {
                for (kv.values) |meta| {
                    if (val_prefix.len == 0 or std.mem.startsWith(u8, meta.name, val_prefix)) {
                        try writer.print("{s}{s}={s}\n", .{ name_prefix, key, meta.name });
                    }
                }
                return;
            }
            if (flag.allowed_values) |vals| {
                for (vals) |v| {
                    if (val_prefix.len == 0 or std.mem.startsWith(u8, v, val_prefix)) {
                        try writer.print("{s}{s}={s}\n", .{ name_prefix, key, v });
                    }
                }
            }
        } else {
            if (flag.key_value_help) |kv| {
                for (kv.keys) |meta| {
                    if (value_prefix.len == 0 or std.mem.startsWith(u8, meta.name, value_prefix)) {
                        var key_buf: [256]u8 = undefined;
                        const key_value = std.fmt.bufPrint(&key_buf, "{s}{s}=", .{ name_prefix, meta.name }) catch continue;
                        var desc_buf: [512]u8 = undefined;
                        const desc = if (meta.default_value.len > 0)
                            std.fmt.bufPrint(&desc_buf, "{s} [default: {s}]", .{ meta.summary, meta.default_value }) catch meta.summary
                        else
                            meta.summary;
                        try writeSuggestion(writer, key_value, desc);
                    }
                }
                return;
            }
            if (flag.allowed_keys) |keys| {
                for (keys) |k| {
                    if (value_prefix.len == 0 or std.mem.startsWith(u8, k, value_prefix)) {
                        try writer.print("{s}{s}=\n", .{ name_prefix, k });
                    }
                }
            }
        }

        return;
    }

    if (flag.allowed_values) |vals| {
        for (vals) |v| {
            if (value_prefix.len == 0 or std.mem.startsWith(u8, v, value_prefix)) {
                try writer.print("{s}{s}\n", .{ name_prefix, v });
            }
        }
    }
}

fn flagExpectsValue(cmd: *const Command, token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "--")) {
        var name = token[2..];
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| name = name[0..eq];
        if (cmd.resolveFlagByName(name)) |lookup| {
            return lookup.command.flags.constSlice()[lookup.index].takesValue();
        }
        return false;
    }

    if (std.mem.startsWith(u8, token, "-") and token.len == 2) {
        const short = token[1];
        if (cmd.resolveFlagByShort(short)) |lookup| {
            return lookup.command.flags.constSlice()[lookup.index].takesValue();
        }
    }

    return false;
}
