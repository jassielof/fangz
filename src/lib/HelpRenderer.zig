//! Clap-style help renderer for Fangz command trees.

const std = @import("std");
const Command = @import("Command.zig");
const Style = @import("Style.zig").Style;

/// Renders command help sections to the provided writer.
pub fn render(writer: anytype, command: *const Command, style: Style) !void {
    try writer.print("{s}{s}{s}\n", .{ style.bold(), command.name, style.reset() });
    if (command.description.len > 0) {
        try writer.print("{s}\n", .{command.description});
    }
    try renderUsage(writer, command, style);

    if (command.positionals.items.len > 0) {
        try writer.print("\n{s}Arguments:{s}\n", .{ style.bold(), style.reset() });
        try renderArguments(writer, command, style);
    }

    if (command.subcommands.items.len > 0) {
        try writer.print("\n{s}Commands:{s}\n", .{ style.bold(), style.reset() });
        try renderSubcommands(writer, command, style);
    }

    try writer.print("\n{s}Options:{s}\n", .{ style.bold(), style.reset() });
    try renderFlags(writer, command, style);
}

/// Renders usage line for a command.
fn renderUsage(writer: anytype, command: *const Command, style: Style) !void {
    try writer.print("\n{s}Usage:{s} {s}", .{ style.bold(), style.reset(), command.name });
    if (hasAnyOptions(command)) {
        try writer.print(" [OPTIONS]", .{});
    }
    if (command.subcommands.items.len > 0) {
        try writer.print(" <COMMAND>", .{});
    }
    for (command.positionals.items) |pos| {
        if (pos.variadic) {
            try writer.print(" <{s}>...", .{pos.name});
        } else if (pos.required) {
            try writer.print(" <{s}>", .{pos.name});
        } else {
            try writer.print(" [{s}]", .{pos.name});
        }
    }
    try writer.print("\n", .{});
}

/// Determines whether any options should appear in usage/help.
fn hasAnyOptions(command: *const Command) bool {
    if (command.flags.items.len > 0) return true;
    if (command.rootConst().version != null) return true;
    var current = command.parent;
    while (current) |parent| : (current = parent.parent) {
        for (parent.flags.items) |flag| {
            if (flag.persistent) return true;
        }
    }
    return true; // help is always available
}

/// Renders positional arguments table-like list.
fn renderArguments(writer: anytype, command: *const Command, style: Style) !void {
    var spec_width: usize = 0;
    for (command.positionals.items) |arg| {
        var len = arg.name.len + 2;
        if (arg.variadic) len += 3;
        if (len > spec_width) spec_width = len;
    }

    for (command.positionals.items) |arg| {
        var spec_buf: [128]u8 = undefined;
        var sbs = std.io.fixedBufferStream(&spec_buf);
        const sw = sbs.writer();
        try sw.print("<{s}>", .{arg.name});
        if (arg.variadic) try sw.print("...", .{});

        var desc_buf: [256]u8 = undefined;
        var dbs = std.io.fixedBufferStream(&desc_buf);
        const dw = dbs.writer();
        if (arg.description.len > 0) try dw.print("{s}", .{arg.description});
        if (arg.required) try dw.print(" [required]", .{});
        if (arg.variadic) try dw.print(" [variadic]", .{});

        try printAlignedCommandRow(
            writer,
            style,
            "  ",
            spec_buf[0..sbs.pos],
            desc_buf[0..dbs.pos],
            spec_width,
        );
    }
}

/// Renders grouped and ungrouped subcommand rows.
fn renderSubcommands(writer: anytype, command: *const Command, style: Style) !void {
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

        try writer.print("  {s}{s}:{s}\n", .{ style.bold(), group.title, style.reset() });
        for (command.subcommands.items) |sub| {
            if (sub.group_id) |gid| {
                if (std.mem.eql(u8, gid, group.id)) {
                    try printAlignedCommandRow(writer, style, "    ", sub.name, sub.description, cmd_width);
                }
            }
        }
    }

    const default_indent = if (rendered_group_section) "    " else "  ";
    for (command.subcommands.items) |sub| {
        if (sub.group_id != null) continue;
        try printAlignedCommandRow(writer, style, default_indent, sub.name, sub.description, cmd_width);
    }

    try printAlignedCommandRow(
        writer,
        style,
        default_indent,
        "help",
        "Print this message or the help of the given subcommand(s)",
        cmd_width,
    );
}

/// Renders command options including inherited persistent flags.
fn renderFlags(writer: anytype, command: *const Command, style: Style) !void {
    var spec_width: usize = 0;
    for (command.flags.items) |flag| {
        const len = optionSpecLen(flag);
        if (len > spec_width) spec_width = len;
    }

    if (command.parent) |parent| {
        var chain = try parent.collectAncestorPath(command.allocator);
        defer chain.deinit(command.allocator);
        for (chain.items) |ancestor| {
            for (ancestor.flags.items) |flag| {
                if (!flag.persistent) continue;
                const len = optionSpecLen(flag);
                if (len > spec_width) spec_width = len;
            }
        }
    }

    if ("-h, --help".len > spec_width) spec_width = "-h, --help".len;
    if (command.rootConst().version != null and "-V, --version".len > spec_width) {
        spec_width = "-V, --version".len;
    }

    for (command.flags.items) |flag| {
        try renderOneFlag(writer, flag, false, style, spec_width);
    }

    if (command.parent) |parent| {
        var chain = try parent.collectAncestorPath(command.allocator);
        defer chain.deinit(command.allocator);
        for (chain.items) |ancestor| {
            for (ancestor.flags.items) |flag| {
                if (!flag.persistent) continue;
                try renderOneFlag(writer, flag, true, style, spec_width);
            }
        }
    }

    try printAlignedOptionRow(writer, style, "-h, --help", "Print help", spec_width);
    if (command.rootConst().version != null) {
        try printAlignedOptionRow(writer, style, "-V, --version", "Print version", spec_width);
    }
}

/// Renders one option line with metadata annotations.
fn renderOneFlag(
    writer: anytype,
    flag: Command.Flag,
    is_global: bool,
    style: Style,
    spec_width: usize,
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
    spec_buf[spec_len] = '-';
    spec_len += 1;
    spec_buf[spec_len] = '-';
    spec_len += 1;
    std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + flag.name.len], flag.name);
    spec_len += flag.name.len;

    const ty = typeName(flag.value_type);
    if (ty.len > 0) {
        spec_buf[spec_len] = ' ';
        spec_len += 1;
        spec_buf[spec_len] = '<';
        spec_len += 1;
        std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + ty.len], ty);
        spec_len += ty.len;
        spec_buf[spec_len] = '>';
        spec_len += 1;
        if (flag.value_type == .string_list) {
            spec_buf[spec_len] = '.';
            spec_len += 1;
            spec_buf[spec_len] = '.';
            spec_len += 1;
            spec_buf[spec_len] = '.';
            spec_len += 1;
        }
    }

    var desc_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&desc_buf);
    const d = fbs.writer();
    try d.print("{s}", .{flag.description});
    if (flag.required) try d.print(" [required]", .{});
    if (flag.default_value) |dv| {
        switch (dv) {
            .bool => |v| try d.print(" [default: {s}]", .{if (v) "true" else "false"}),
            .string => |v| try d.print(" [default: {s}]", .{v}),
            .int => |v| try d.print(" [default: {}]", .{v}),
            .float => |v| try d.print(" [default: {d}]", .{v}),
            .string_list => |_| try d.print(" [default: set]", .{}),
        }
    }
    if (flag.allowed_values) |values| {
        try d.print(" [possible values: ", .{});
        for (values, 0..) |v, i| {
            if (i != 0) try d.print(", ", .{});
            try d.print("{s}", .{v});
        }
        try d.print("]", .{});
    }
    if (is_global) try d.print(" [global]", .{});

    try printAlignedOptionRow(writer, style, spec_buf[0..spec_len], desc_buf[0..fbs.pos], spec_width);
}

/// Computes display width of an option specification string.
fn optionSpecLen(flag: Command.Flag) usize {
    var len = flag.name.len + 2;
    if (flag.short != null) len += 4;

    const ty = typeName(flag.value_type);
    if (ty.len > 0) {
        len += ty.len + 3;
        if (flag.value_type == .string_list) len += 3;
    }

    return len;
}

/// Writes an aligned option row with compact gutter spacing.
fn printAlignedOptionRow(
    writer: anytype,
    style: Style,
    spec: []const u8,
    desc: []const u8,
    spec_width: usize,
) !void {
    try writer.print("  {s}{s}{s}", .{
        style.fg(.green),
        spec,
        style.reset(),
    });

    if (spec_width > spec.len) {
        var remaining = spec_width - spec.len;
        while (remaining > 0) : (remaining -= 1) {
            try writer.print(" ", .{});
        }
    }

    const continuation_pad = 2 + spec_width + 2;
    try printMultilineDescription(writer, desc, continuation_pad);
}

/// Writes an aligned command row with compact gutter spacing.
fn printAlignedCommandRow(
    writer: anytype,
    style: Style,
    indent: []const u8,
    name: []const u8,
    desc: []const u8,
    name_width: usize,
) !void {
    try writer.print("{s}{s}{s}{s}", .{
        indent,
        style.fg(.cyan),
        name,
        style.reset(),
    });

    if (name_width > name.len) {
        var remaining = name_width - name.len;
        while (remaining > 0) : (remaining -= 1) {
            try writer.print(" ", .{});
        }
    }

    const continuation_pad = indent.len + name_width + 2;
    try printMultilineDescription(writer, desc, continuation_pad);
}

/// Prints first description line inline and aligns continuation lines.
fn printMultilineDescription(writer: anytype, desc: []const u8, continuation_pad: usize) !void {
    if (std.mem.indexOfScalar(u8, desc, '\n')) |idx| {
        try writer.print("  {s}\n", .{desc[0..idx]});
        var rest = desc[idx + 1 ..];
        while (true) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |next_idx| {
                try printSpaces(writer, continuation_pad);
                try writer.print("{s}\n", .{rest[0..next_idx]});
                rest = rest[next_idx + 1 ..];
            } else {
                try printSpaces(writer, continuation_pad);
                try writer.print("{s}\n", .{rest});
                break;
            }
        }
        return;
    }

    try writer.print("  {s}\n", .{desc});
}

/// Writes `count` ASCII spaces.
fn printSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.print(" ", .{});
    }
}

/// Returns display token for a flag type.
fn typeName(flag_type: Command.FlagType) []const u8 {
    return switch (flag_type) {
        .bool => "",
        .string => "STRING",
        .int => "INT",
        .float => "FLOAT",
        .string_list => "STRING",
    };
}
