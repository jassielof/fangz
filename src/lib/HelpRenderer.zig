//! Help renderer module.

const std = @import("std");

const carnaval = @import("carnaval");
const ColorProfile = carnaval.ColorProfile;

const Command = @import("Command.zig");
const HelpMetadata = @import("HelpMetadata.zig");

/// Target wrap width for help prose (brief, long descriptions, example blurbs).
/// Aligned option/command summaries keep using the live terminal width instead.
const help_prose_width = 70;

/// Continuation indent for wrapped help prose.
const prose_continuation_indent = 2;

/// Controls the verbosity of the rendered help output.
///
/// - `.short` — compact output triggered by `-h`: synopsis, argument list, flag list with one-liner summaries only (no metadata lines).
/// - `.full`  — complete output triggered by `--help` or `help <cmd>`: same as short plus per-flag `description`, allowed values, defaults, and other metadata.
pub const HelpMode = enum { short, full };

/// Renders command help sections to the provided writer.
pub fn render(
    writer: *std.Io.Writer,
    command: *const Command,
    profile: ColorProfile,
    mode: HelpMode,
) !void {
    const display_path = try commandDisplayPath(command.allocator, command);
    defer command.allocator.free(display_path);

    try carnaval.Style.init().bolded().renderWithProfile(display_path, writer, profile);
    try writer.print("\n", .{});

    const terminal_width = carnaval.terminalWidthForHandle(std.Io.File.stdout().handle);

    if (command.brief.len > 0) {
        try printWrappedProse(writer, command.brief, 0, command.allocator);
    }

    if (mode == .full) {
        if (command.examples) |exs| {
            if (exs.len > 0) {
                try writer.print("\n", .{});
                try carnaval.Style.init().bolded().renderWithProfile("Examples:", writer, profile);
                try writer.print("\n", .{});

                for (exs) |ex| {
                    if (ex.description.len > 0) {
                        try printWrappedProse(writer, ex.description, 2, command.allocator);
                    }
                    try writer.print("    {s}\n", .{ex.command});
                }
            }
        }
    }

    if (mode == .full and command.description.len > 0) {
        try writer.print("\n", .{});
        try printWrappedProse(writer, command.description, 0, command.allocator);
    }

    if (command.aliases.items.len > 0) {
        try writer.print("\n", .{});
        try carnaval.Style.init().bolded().renderWithProfile("Aliases:", writer, profile);
        try writer.print("\n", .{});
        for (command.aliases.items) |alias| {
            try writer.print("  {s}\n", .{alias});
        }
    }

    try renderUsage(writer, command, profile, display_path);

    if (command.positionals.items.len > 0) {
        try writer.print("\n", .{});
        try carnaval.Style.init().bolded().renderWithProfile("Arguments:", writer, profile);
        try writer.print("\n", .{});
        try renderArguments(writer, command, profile, terminal_width, mode);
    }

    if (command.subcommands.items.len > 0) {
        try writer.print("\n", .{});
        try carnaval.Style.init().bolded().renderWithProfile("Commands:", writer, profile);
        try writer.print("\n", .{});
        try renderSubcommands(writer, command, profile, terminal_width, mode);
    }

    try writer.print("\n", .{});
    try carnaval.Style.init().bolded().renderWithProfile("Options:", writer, profile);
    try writer.print("\n", .{});
    try renderFlags(writer, command, profile, terminal_width, mode);
}

/// Space-separated path from the CLI root to `command` (e.g. `docent completion`).
fn commandDisplayPath(allocator: std.mem.Allocator, command: *const Command) ![]u8 {
    var chain = try command.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (chain.items, 0..) |cmd, j| {
        if (j != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, cmd.name);
    }
    return out.toOwnedSlice(allocator);
}

/// Renders usage line for a command.
fn renderUsage(writer: *std.Io.Writer, command: *const Command, profile: ColorProfile, display_path: []const u8) !void {
    try writer.print("\n", .{});
    try carnaval.Style.init().bolded().renderWithProfile("Usage:", writer, profile);

    if (command.usage_override) |u| {
        var lines = std.mem.splitScalar(u8, u, '\n');
        var first_line = true;

        while (lines.next()) |line| {
            if (first_line) {
                try writer.print(" {s}", .{line});
                first_line = false;
            } else {
                try writer.print("\n{s}", .{line});
            }
        }

        try writer.print("\n", .{});

        return;
    }

    try writer.print(" {s}", .{display_path});

    if (command.hasAnyOptions()) {
        try writer.print(" [OPTIONS]", .{});
    }

    if (command.parent == null and command.subcommands.items.len > 0 and
        command.positionals.items.len > 0)
    {
        const pos0 = command.positionals.items[0];
        if (pos0.variadic and !pos0.required) {
            try writer.print(" [PATHS]{s}", .{HelpMetadata.variadic_metavar_suffix});
            try writer.print("\n{s} <COMMAND>", .{display_path});
            try writer.print("\n", .{});

            return;
        }
    }

    if (command.subcommands.items.len > 0) {
        try writer.print(" <COMMAND>", .{});
    }

    for (command.positionals.items) |pos| {
        if (pos.variadic) {
            try writer.print(" <{s}>{s}", .{ pos.name, HelpMetadata.variadic_metavar_suffix });
        } else if (pos.required) {
            try writer.print(" <{s}>", .{pos.name});
        } else {
            try writer.print(" [{s}]", .{pos.name});
        }
    }

    try writer.print("\n", .{});
}

/// Renders positional arguments table-like list.
fn renderArguments(writer: *std.Io.Writer, command: *const Command, profile: ColorProfile, terminal_width: usize, mode: HelpMode) !void {
    var spec_width: usize = 0;
    const suffix_len = HelpMetadata.variadic_metavar_suffix.len;

    for (command.positionals.items) |arg| {
        var len = arg.name.len + 2;
        if (arg.variadic) len += suffix_len;
        if (len > spec_width) spec_width = len;
    }

    for (command.positionals.items) |arg| {
        var spec_buf: [128]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&spec_buf);
        try sw.print("<{s}>", .{arg.name});
        if (arg.variadic) try sw.print("{s}", .{HelpMetadata.variadic_metavar_suffix});

        try printAlignedCommandRow(
            writer,
            profile,
            "  ",
            spec_buf[0..sw.end],
            arg.brief,
            spec_width,
            terminal_width,
            command.allocator,
        );

        const continuation_pad = 2 + spec_width + 2;
        if (mode == .full) {
            try HelpMetadata.renderPositionalMetadata(writer, profile, arg, continuation_pad);
        }

        if (mode == .full and arg.description.len > 0) {
            try printWrappedProse(writer, arg.description, continuation_pad, command.allocator);
        }
    }
}

/// Renders grouped and ungrouped subcommand rows.
fn renderSubcommands(writer: *std.Io.Writer, command: *const Command, profile: ColorProfile, terminal_width: usize, mode: HelpMode) !void {
    _ = mode;
    var cmd_width: usize = "help".len;
    for (command.subcommands.items) |sub| {
        if (sub.name.len > cmd_width) cmd_width = sub.name.len;
    }

    var rendered_group_section = false;
    for (command.groups.items) |group| {
        var has_in_group = false;
        for (command.subcommands.items) |sub| {
            if (sub.group_id) |gid| {
                if (std.mem.eql(u8, gid, group.id)) {
                    has_in_group = true;
                    break;
                }
            }
        }
        if (!has_in_group) continue;
        rendered_group_section = true;

        try writer.print("  ", .{});
        try carnaval.Style.init().bolded().renderWithProfile(group.title, writer, profile);
        try writer.print(":\n", .{});
        for (command.subcommands.items) |sub| {
            if (sub.group_id) |gid| {
                if (std.mem.eql(u8, gid, group.id)) {
                    try printAlignedCommandRow(writer, profile, "    ", sub.name, sub.brief, cmd_width, terminal_width, command.allocator);
                }
            }
        }
    }

    const default_indent = if (rendered_group_section) "    " else "  ";
    for (command.subcommands.items) |sub| {
        if (sub.group_id != null) continue;
        try printAlignedCommandRow(writer, profile, default_indent, sub.name, sub.brief, cmd_width, terminal_width, command.allocator);
    }

    try printAlignedCommandRow(
        writer,
        profile,
        default_indent,
        "help",
        "Print this message or the help of the given subcommand(s)",
        cmd_width,
        terminal_width,
        command.allocator,
    );
}

/// Renders command options including inherited persistent flags.
fn renderFlags(writer: *std.Io.Writer, command: *const Command, profile: ColorProfile, terminal_width: usize, mode: HelpMode) !void {
    var spec_width: usize = 0;
    for (command.flags.constSlice()) |flag| {
        const len = optionSpecLen(flag);
        if (len > spec_width) spec_width = len;
    }

    if (command.parent) |parent| {
        var chain = try parent.collectAncestorPath(command.allocator);
        defer chain.deinit(command.allocator);
        for (chain.items) |ancestor| {
            for (ancestor.flags.constSlice()) |flag| {
                if (!flag.persistent) continue;
                const len = optionSpecLen(flag);
                if (len > spec_width) spec_width = len;
            }
        }
    }

    if ("-h, --help".len > spec_width) spec_width = "-h, --help".len;
    if (command.parent == null and command.rootConst().version != null and "-V, --version".len > spec_width) {
        spec_width = "-V, --version".len;
    }

    for (command.flags.constSlice()) |flag| {
        try renderOneFlag(writer, flag, false, profile, spec_width, terminal_width, command.allocator, mode);
    }

    if (command.parent) |parent| {
        var chain = try parent.collectAncestorPath(command.allocator);
        defer chain.deinit(command.allocator);
        for (chain.items) |ancestor| {
            for (ancestor.flags.constSlice()) |flag| {
                if (!flag.persistent) continue;
                try renderOneFlag(writer, flag, true, profile, spec_width, terminal_width, command.allocator, mode);
            }
        }
    }

    try printAlignedOptionRow(writer, profile, "-h, --help", "Print help", spec_width, terminal_width, command.allocator);
    if (command.parent == null and command.rootConst().version != null) {
        try printAlignedOptionRow(writer, profile, "-V, --version", "Print version", spec_width, terminal_width, command.allocator);
    }
}

/// Renders one option line with metadata annotations.
fn renderOneFlag(
    writer: *std.Io.Writer,
    flag: Command.Flag,
    is_global: bool,
    profile: ColorProfile,
    spec_width: usize,
    terminal_width: usize,
    allocator: std.mem.Allocator,
    mode: HelpMode,
) !void {
    var spec_buf: [128]u8 = undefined;
    var spec_len: usize = 0;

    if (flag.short) |short| {
        spec_buf[spec_len] = '-';
        spec_len += 1;
        spec_buf[spec_len] = short;
        spec_len += 1;
        spec_buf[spec_len] = ',';
        spec_len += 1;
        spec_buf[spec_len] = ' ';
        spec_len += 1;
    }
    // Negatable boolean flags are rendered as --[no-]<name>.
    if (flag.negatable and flag.value_type == .bool) {
        const prefix = "--[no-]";
        std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + prefix.len], prefix);
        spec_len += prefix.len;
        std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + flag.name.len], flag.name);
        spec_len += flag.name.len;
    } else {
        spec_buf[spec_len] = '-';
        spec_len += 1;
        spec_buf[spec_len] = '-';
        spec_len += 1;
        std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + flag.name.len], flag.name);
        spec_len += flag.name.len;

        var ty_buf: [72]u8 = undefined;
        const ty: []const u8 = if (flag.value_type == .key_value_list and flag.key_metavar != null and flag.value_metavar != null)
            std.fmt.bufPrint(&ty_buf, "{s}={s}", .{ flag.key_metavar.?, flag.value_metavar.? }) catch "KEY=VALUE"
        else if (flag.value_hint) |hint|
            hint
        else
            typeName(flag.value_type);

        if (ty.len > 0) {
            spec_buf[spec_len] = ' ';
            spec_len += 1;
            spec_buf[spec_len] = '<';
            spec_len += 1;
            std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + ty.len], ty);
            spec_len += ty.len;
            spec_buf[spec_len] = '>';
            spec_len += 1;
        }
    }

    try printAlignedOptionRow(writer, profile, spec_buf[0..spec_len], flag.brief, spec_width, terminal_width, allocator);

    const continuation_pad = 2 + spec_width + 2;
    if (mode == .full) {
        const enum_name = if (flag.default_value) |dv| switch (dv) {
            .enum_tag => |ordinal| enumTagName(flag, ordinal),
            else => "",
        } else "";
        try HelpMetadata.renderFlagMetadata(writer, profile, flag, is_global, continuation_pad, enum_name);
    }

    // In full-help mode, render long prose indented below the row.
    if (mode == .full and flag.description.len > 0) {
        const indent = 4 + spec_width + 2;
        try printWrappedProse(writer, flag.description, indent, allocator);
    }

    if (mode == .full) {
        const indent = 4 + spec_width + 2;

        if (flag.examples) |exs| {
            if (exs.len > 0) {
                try printSpaces(writer, indent);
                try carnaval.Style.init().bolded().renderWithProfile("Examples:", writer, profile);
                try writer.print("\n", .{});

                for (exs) |ex| {
                    if (ex.description.len > 0) {
                        try printWrappedProse(writer, ex.description, indent + 2, allocator);
                    }

                    try printSpaces(writer, indent + 2);
                    try writer.print("{s}\n", .{ex.command});
                }
            }
        }

        if (flag.key_value_help) |kv| {
            if (kv.examples.len > 0) {
                try printSpaces(writer, indent);
                try carnaval.Style.init().bolded().renderWithProfile("Examples:", writer, profile);
                try writer.print("\n", .{});

                for (kv.examples) |ex| {
                    if (ex.description.len > 0) {
                        try printWrappedProse(writer, ex.description, indent + 2, allocator);
                    }
                    try printSpaces(writer, indent + 2);
                    try writer.print("{s}\n", .{ex.command});
                }
            }

            if (kv.override_behavior_note.len > 0) {
                try printWrappedProse(writer, kv.override_behavior_note, indent, allocator);
            }
        }
    }
}

/// Computes display width of an option specification string.
fn optionSpecLen(flag: Command.Flag) usize {
    if (flag.short != null) {
        // "-x, " prefix
        if (flag.negatable and flag.value_type == .bool) {
            return 4 + "--[no-]".len + flag.name.len;
        }
    }

    if (flag.negatable and flag.value_type == .bool) {
        return "--[no-]".len + flag.name.len;
    }

    var len = flag.name.len + 2; // "--" + name
    if (flag.short != null) len += 4; // "-x, "

    const ty_len: usize = if (flag.value_type == .key_value_list and flag.key_metavar != null and flag.value_metavar != null)
        flag.key_metavar.?.len + 1 + flag.value_metavar.?.len
    else blk: {
        const ty = if (flag.value_hint) |hint| hint else typeName(flag.value_type);
        break :blk ty.len;
    };

    if (ty_len > 0) len += ty_len + 3; // " <type>"

    return len;
}

/// Writes an aligned option row with compact gutter spacing.
fn printAlignedOptionRow(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    spec: []const u8,
    desc: []const u8,
    spec_width: usize,
    terminal_width: usize,
    allocator: std.mem.Allocator,
) !void {
    try writer.print("  ", .{});
    try carnaval.Style.init().fg(.{ .ansi16 = .green }).renderWithProfile(spec, writer, profile);

    if (spec_width > spec.len) {
        var remaining = spec_width - spec.len;
        while (remaining > 0) : (remaining -= 1) {
            try writer.print(" ", .{});
        }
    }

    const continuation_pad = 2 + spec_width + 2;
    try printMultilineDescription(writer, desc, continuation_pad, terminal_width, allocator);
}

/// Writes an aligned command row with compact gutter spacing.
fn printAlignedCommandRow(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    indent: []const u8,
    name: []const u8,
    desc: []const u8,
    name_width: usize,
    terminal_width: usize,
    allocator: std.mem.Allocator,
) !void {
    try writer.print("{s}", .{indent});
    try carnaval.Style.init().fg(.{ .ansi16 = .cyan }).renderWithProfile(name, writer, profile);

    if (name_width > name.len) {
        var remaining = name_width - name.len;
        while (remaining > 0) : (remaining -= 1) {
            try writer.print(" ", .{});
        }
    }

    const continuation_pad = indent.len + name_width + 2;
    try printMultilineDescription(writer, desc, continuation_pad, terminal_width, allocator);
}

/// Prints first description line inline and aligns continuation lines.
fn printMultilineDescription(
    writer: *std.Io.Writer,
    desc: []const u8,
    continuation_pad: usize,
    terminal_width: usize,
    allocator: std.mem.Allocator,
) !void {
    if (desc.len == 0) {
        try writer.print("\n", .{});
        return;
    }

    const max_desc_width = if (terminal_width > continuation_pad + 4) terminal_width - continuation_pad - 2 else 20;
    const wrapped = try carnaval.wrapWithOptions(desc, max_desc_width, carnaval.WrapOptions.prose, allocator);
    defer allocator.free(wrapped);

    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    if (lines.next()) |first| {
        try writer.print("  {s}\n", .{first});
    }
    while (lines.next()) |line| {
        try printSpaces(writer, continuation_pad);
        try writer.print("{s}\n", .{line});
    }
}

/// Wraps and prints a help prose block at `help_prose_width` with optional left margin.
fn printWrappedProse(
    writer: *std.Io.Writer,
    text: []const u8,
    left_margin: usize,
    allocator: std.mem.Allocator,
) !void {
    if (text.len == 0) return;

    const wrapped = try carnaval.wrapWithOptions(text, help_prose_width, carnaval.WrapOptions.prose, allocator);
    defer allocator.free(wrapped);

    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    if (lines.next()) |first| {
        try printSpaces(writer, left_margin);
        try writer.print("{s}\n", .{first});
    }
    while (lines.next()) |line| {
        try printSpaces(writer, left_margin + prose_continuation_indent);
        try writer.print("{s}\n", .{line});
    }
}

/// Writes `count` ASCII spaces.
fn printSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.print(" ", .{});
    }
}

/// Resolves the string name of an enum_tag ordinal from the flag descriptor.
/// Falls back to `"set"` if the ordinal cannot be matched.
fn enumTagName(flag: Command.Flag, ordinal: u32) []const u8 {
    const names = flag.allowed_values orelse return "set";
    const ords = flag.enum_values orelse return "set";
    for (ords, 0..) |ord, i| {
        if (ord == ordinal and i < names.len) return names[i];
    }
    return "set";
}

/// Returns display token for a flag type.
fn typeName(flag_type: Command.FlagType) []const u8 {
    return switch (flag_type) {
        .bool => "",
        .string => "STRING",
        .int => "INT",
        .float => "FLOAT",
        .string_list => "STRING",
        .key_value_list => "KEY=VALUE",
        .enum_tag => "VALUE",
    };
}
