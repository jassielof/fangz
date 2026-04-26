//! Clap-style help renderer for Fangz command trees.

const std = @import("std");

const carnaval = @import("carnaval");
const ColorProfile = carnaval.ColorProfile;

const Command = @import("Command.zig");

/// Renders command help sections to the provided writer.
pub fn render(writer: anytype, command: *const Command, profile: ColorProfile) !void {
    try carnaval.Style.init().bolded().renderWithProfile(command.name, writer, profile);
    try writer.print("\n", .{});
    if (command.description.len > 0) {
        try writer.print("{s}\n", .{command.description});
    }
    const terminal_width = carnaval.terminalWidthForHandle(std.Io.File.stdout().handle);
    try renderUsage(writer, command, profile);

    if (command.positionals.items.len > 0) {
        try writer.print("\n", .{});
        try carnaval.Style.init().bolded().renderWithProfile("Arguments:", writer, profile);
        try writer.print("\n", .{});
        try renderArguments(writer, command, profile, terminal_width);
    }

    if (command.subcommands.items.len > 0) {
        try writer.print("\n", .{});
        try carnaval.Style.init().bolded().renderWithProfile("Commands:", writer, profile);
        try writer.print("\n", .{});
        try renderSubcommands(writer, command, profile, terminal_width);
    }

    try writer.print("\n", .{});
    try carnaval.Style.init().bolded().renderWithProfile("Options:", writer, profile);
    try writer.print("\n", .{});
    try renderFlags(writer, command, profile, terminal_width);
}

/// Renders usage line for a command.
fn renderUsage(writer: anytype, command: *const Command, profile: ColorProfile) !void {
    try writer.print("\n", .{});
    try carnaval.Style.init().bolded().renderWithProfile("Usage:", writer, profile);
    try writer.print(" {s}", .{command.name});
    if (command.hasAnyOptions()) {
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

/// Renders positional arguments table-like list.
fn renderArguments(writer: anytype, command: *const Command, profile: ColorProfile, terminal_width: usize) !void {
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
            profile,
            "  ",
            spec_buf[0..sbs.pos],
            desc_buf[0..dbs.pos],
            spec_width,
            terminal_width,
            command.allocator,
        );
    }
}

/// Renders grouped and ungrouped subcommand rows.
fn renderSubcommands(writer: anytype, command: *const Command, profile: ColorProfile, terminal_width: usize) !void {
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
                    try printAlignedCommandRow(writer, profile, "    ", sub.name, sub.description, cmd_width, terminal_width, command.allocator);
                }
            }
        }
    }

    const default_indent = if (rendered_group_section) "    " else "  ";
    for (command.subcommands.items) |sub| {
        if (sub.group_id != null) continue;
        try printAlignedCommandRow(writer, profile, default_indent, sub.name, sub.description, cmd_width, terminal_width, command.allocator);
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
fn renderFlags(writer: anytype, command: *const Command, profile: ColorProfile, terminal_width: usize) !void {
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
        try renderOneFlag(writer, flag, false, profile, spec_width, terminal_width, command.allocator);
    }

    if (command.parent) |parent| {
        var chain = try parent.collectAncestorPath(command.allocator);
        defer chain.deinit(command.allocator);
        for (chain.items) |ancestor| {
            for (ancestor.flags.constSlice()) |flag| {
                if (!flag.persistent) continue;
                try renderOneFlag(writer, flag, true, profile, spec_width, terminal_width, command.allocator);
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
    writer: anytype,
    flag: Command.Flag,
    is_global: bool,
    profile: ColorProfile,
    spec_width: usize,
    terminal_width: usize,
    allocator: std.mem.Allocator,
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

    const ty = if (flag.value_hint) |hint| hint else typeName(flag.value_type);
    if (ty.len > 0) {
        spec_buf[spec_len] = ' ';
        spec_len += 1;
        spec_buf[spec_len] = '<';
        spec_len += 1;
        std.mem.copyForwards(u8, spec_buf[spec_len .. spec_len + ty.len], ty);
        spec_len += ty.len;
        spec_buf[spec_len] = '>';
        spec_len += 1;
        if (flag.value_type == .string_list or flag.value_type == .key_value_list) {
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
            .enum_tag => |ordinal| try d.print(" [default: {s}]", .{enumTagName(flag, ordinal)}),
            .string_list => try d.print(" [default: set]", .{}),
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

    try printAlignedOptionRow(writer, profile, spec_buf[0..spec_len], desc_buf[0..fbs.pos], spec_width, terminal_width, allocator);
}

/// Computes display width of an option specification string.
fn optionSpecLen(flag: Command.Flag) usize {
    var len = flag.name.len + 2;
    if (flag.short != null) len += 4;

    const ty = if (flag.value_hint) |hint| hint else typeName(flag.value_type);
    if (ty.len > 0) {
        len += ty.len + 3;
        if (flag.value_type == .string_list or flag.value_type == .key_value_list) len += 3;
    }

    return len;
}

/// Writes an aligned option row with compact gutter spacing.
fn printAlignedOptionRow(
    writer: anytype,
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
    writer: anytype,
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
    writer: anytype,
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
    const wrapped = try carnaval.wrap(desc, max_desc_width, 0, allocator);
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

/// Writes `count` ASCII spaces.
fn printSpaces(writer: anytype, count: usize) !void {
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
