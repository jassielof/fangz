//! AsciiDoc documentation generator for Fangz command trees.
//!
//! Fangz converts the parser/runtime command tree into a render-friendly documentation model, then renders a single AsciiDoc file with Trama.

const std = @import("std");

const meta = @import("fangz_meta");
const trama = @import("trama");

const Command = @import("Command.zig");
pub const CommandDoc = @import("docs/Command.zig");
pub const FlagDoc = @import("docs/Flag.zig");
pub const DocumentModel = @import("docs/Model.zig");
pub const Options = @import("docs/Options.zig");
pub const PositionalDoc = @import("docs/Positional.zig");
pub const SubcommandDoc = @import("docs/Subcommand.zig");
const ParseContext = @import("ParseContext.zig");

const ListWriter = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn print(self: ListWriter, comptime format: []const u8, args: anytype) !void {
        const chunk = try std.fmt.allocPrint(self.allocator, format, args);

        defer self.allocator.free(chunk);

        try self.list.appendSlice(self.allocator, chunk);
    }
};

/// Generates AsciiDoc documentation for the given command hierarchy.
pub fn generateDocs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *const Command,
    options: Options,
) !void {
    _ = options.include_hidden;
    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);

    const doc = try renderSingleFile(
        allocator,
        root,
        options,
    );
    defer allocator.free(doc);

    const output_path = try std.fs.path.join(allocator, &.{ options.output_dir, options.output_file_name });
    defer allocator.free(output_path);
    try writeFile(io, output_path, doc, options.overwrite);
}

fn renderSingleFile(
    allocator: std.mem.Allocator,
    root: *const Command,
    options: Options,
) ![]u8 {
    var model = try buildDocumentModel(allocator, root, options);
    defer model.deinit(allocator);

    return trama.renderAlloc(
        allocator,
        @embedFile("templates/default.adoc"),
        &model,
        .{ .escape_mode = .asciidoc },
    );
}

fn buildDocumentModel(
    allocator: std.mem.Allocator,
    root: *const Command,
    options: Options,
) !DocumentModel {
    var commands = try std.ArrayList(CommandDoc).initCapacity(allocator, 8);
    errdefer {
        for (commands.items) |*cmd| cmd.deinit(allocator);
        commands.deinit(allocator);
    }

    try collectCommandDoc(allocator, root, &commands);
    try appendHelpCommandDoc(allocator, root, &commands);

    const commands_flat = try commands.toOwnedSlice(allocator);
    errdefer {
        for (commands_flat) |*cmd| cmd.deinit(allocator);
        allocator.free(commands_flat);
    }

    const display_name = if (root.display_name.len > 0) root.display_name else root.name;
    const title = if (root.tagline.len > 0)
        try std.fmt.allocPrint(allocator, "{s}: {s}", .{ display_name, root.tagline })
    else
        try allocator.dupe(u8, display_name);
    errdefer allocator.free(title);

    const git_ref = try gitRef(allocator, root.git_branch, root.git_commit);
    errdefer allocator.free(git_ref);

    const command_index = if (options.include_command_index)
        try buildCommandIndex(allocator, root, commands_flat)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(command_index);

    const help_display_path = try std.fmt.allocPrint(allocator, "{s} help", .{root.name});
    defer allocator.free(help_display_path);
    const help_command_anchor = try anchorForDisplayPath(allocator, help_display_path);
    errdefer allocator.free(help_command_anchor);

    const subcommand_reference: []const CommandDoc = if (commands_flat.len > 1)
        commands_flat[1..]
    else
        &.{};

    return .{
        .binary_name = root.name,
        .display_name = display_name,
        .title = title,
        .tagline = root.tagline,
        .subtitle = root.description,
        .description = root.description,
        .version = root.version orelse "",
        .author_name = root.author_name,
        .author_email = root.author_email,
        .git_branch = root.git_branch,
        .git_commit = root.git_commit,
        .git_ref = git_ref,
        .source_date = root.source_date,
        .app_name_attribute = root.name,
        .include_command_index = options.include_command_index,
        .command_index = command_index,
        .toc = options.toc_position,
        .app_examples = root.examples orelse &.{},
        .help_command_anchor = help_command_anchor,
        .root = if (commands_flat.len > 0) commands_flat[0] else CommandDoc.empty(),
        .subcommand_reference = subcommand_reference,
        .commands_flat = commands_flat,
    };
}

fn gitRef(allocator: std.mem.Allocator, branch: []const u8, commit: []const u8) ![]u8 {
    const has_branch = branch.len > 0;
    const has_commit = commit.len > 0;

    if (has_branch and has_commit) return std.fmt.allocPrint(allocator, "{s} ({s})", .{ branch, commit });
    if (has_branch) return allocator.dupe(u8, branch);
    if (has_commit) return allocator.dupe(u8, commit);
    return allocator.dupe(u8, "");
}

fn collectCommandDoc(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    commands: *std.ArrayList(CommandDoc),
) !void {
    const doc = try commandDocFromCommand(allocator, cmd);
    try commands.append(allocator, doc);
    for (cmd.subcommands.items) |sub| {
        try collectCommandDoc(allocator, sub, commands);
    }
}

fn appendHelpCommandDoc(
    allocator: std.mem.Allocator,
    root: *const Command,
    commands: *std.ArrayList(CommandDoc),
) !void {
    const display_path = try std.fmt.allocPrint(allocator, "{s} help", .{root.name});
    errdefer allocator.free(display_path);
    const anchor = try anchorForDisplayPath(allocator, display_path);
    errdefer allocator.free(anchor);
    const usage = try std.fmt.allocPrint(allocator, "{s} help [COMMAND]...", .{root.name});
    errdefer allocator.free(usage);
    const parent_anchor = try anchorForDisplayPath(allocator, root.name);
    errdefer allocator.free(parent_anchor);
    const parent_display_path = try allocator.dupe(u8, root.name);
    errdefer allocator.free(parent_display_path);
    const path_parts = try allocator.alloc([]const u8, 2);
    errdefer allocator.free(path_parts);
    path_parts[0] = root.name;
    path_parts[1] = "help";

    try commands.append(allocator, .{
        .name = "help",
        .display_path = display_path,
        .path_parts = path_parts,
        .anchor = anchor,
        .depth = 1,
        .description = "Print this message or the help of the given subcommand(s)",
        .long_description = "",
        .usage = usage,
        .parent_display_path = parent_display_path,
        .parent_anchor = parent_anchor,
        .has_parent = true,
        .positionals = &.{},
        .has_positionals = false,
        .options = &.{},
        .has_options = false,
        .subcommands = &.{},
        .has_subcommands = false,
    });
}

/// Registers the built-in `docs` subcommand on root.
///
/// Generates AsciiDoc documentation for the application's full command tree. Called automatically by `App.ensureDocsCommand` — applications do not need to call this directly.
pub fn registerDocsCommand(root: *Command) !void {
    if (root.findSubcommand("docs") != null) return;

    const docs = try root.addSubcommand(.{
        .name = "docs",
        .description = "Generate AsciiDoc documentation for this CLI",
    });

    try docs.addFlag([]const u8, .{
        .name = "output-dir",
        .description = "Directory where AsciiDoc documentation is written.",
        .default = "docs",
    });

    try docs.addFlag([]const u8, .{
        .name = "file",
        .description = "Output AsciiDoc file name.",
        .default = "cli.adoc",
    });

    try docs.addFlag([]const u8, .{
        .name = "template",
        .description = "Optional custom Trama template path.",
    });

    docs.setHooks(.{ .run = runDocsCommand });
}

fn runDocsCommand(ctx: *ParseContext) !void {
    const output_dir = ctx.stringFlag("output-dir") orelse "docs";
    const file = ctx.stringFlag("file") orelse "cli.adoc";
    const template = ctx.stringFlag("template");

    try generateDocs(ctx.allocator, ctx.io, ctx.command.root(), .{
        .output_dir = output_dir,
        .output_file_name = file,
        .template_path = template,
    });
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8, overwrite: bool) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = overwrite,
        .exclusive = !overwrite,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn commandDocFromCommand(allocator: std.mem.Allocator, cmd: *const Command) !CommandDoc {
    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    const display_path = try commandPathFromChain(allocator, chain.items);
    errdefer allocator.free(display_path);
    const anchor = try anchorForDisplayPath(allocator, display_path);
    errdefer allocator.free(anchor);
    const usage = try buildUsage(allocator, cmd, display_path);
    errdefer allocator.free(usage);
    const path_parts = try buildPathParts(allocator, chain.items);
    errdefer allocator.free(path_parts);
    const positionals = try buildPositionals(allocator, cmd);
    errdefer {
        for (positionals) |*pos| pos.deinit(allocator);
        allocator.free(positionals);
    }
    const options = try buildOptions(allocator, cmd);
    errdefer {
        for (options) |*flag| flag.deinit(allocator);
        allocator.free(options);
    }
    const subcommands = try buildSubcommands(allocator, cmd);
    errdefer {
        for (subcommands) |*sub| sub.deinit(allocator);
        allocator.free(subcommands);
    }

    var parent_display_path: []const u8 = "";
    var parent_anchor: []const u8 = "";
    if (cmd.parent) |parent| {
        var parent_chain = try parent.collectAncestorPath(allocator);
        defer parent_chain.deinit(allocator);
        parent_display_path = try commandPathFromChain(allocator, parent_chain.items);
        errdefer allocator.free(parent_display_path);
        parent_anchor = try anchorForDisplayPath(allocator, parent_display_path);
        errdefer allocator.free(parent_anchor);
    }

    return .{
        .name = cmd.name,
        .display_path = display_path,
        .path_parts = path_parts,
        .anchor = anchor,
        .depth = if (chain.items.len > 0) chain.items.len - 1 else 0,
        .description = cmd.description,
        .long_description = cmd.long_description,
        .usage = usage,
        .parent_display_path = parent_display_path,
        .parent_anchor = parent_anchor,
        .has_parent = cmd.parent != null,
        .positionals = positionals,
        .has_positionals = positionals.len > 0,
        .options = options,
        .has_options = options.len > 0,
        .subcommands = subcommands,
        .has_subcommands = subcommands.len > 0,
    };
}

fn buildPathParts(allocator: std.mem.Allocator, chain: []const *const Command) ![]const []const u8 {
    var parts = try allocator.alloc([]const u8, chain.len);
    for (chain, 0..) |cmd, i| parts[i] = cmd.name;
    return parts;
}

fn buildUsage(allocator: std.mem.Allocator, cmd: *const Command, display_path: []const u8) ![]u8 {
    if (cmd.usage_override) |u| {
        return allocator.dupe(u8, u);
    }
    var out = try std.ArrayList(u8).initCapacity(allocator, display_path.len + 64);
    errdefer out.deinit(allocator);
    var w = ListWriter{ .allocator = allocator, .list = &out };

    try w.print("{s}", .{display_path});
    if (cmd.hasAnyOptions()) try w.print(" [OPTIONS]", .{});

    if (cmd.parent == null and cmd.subcommands.items.len > 0 and
        cmd.positionals.items.len > 0)
    {
        const pos0 = cmd.positionals.items[0];
        if (pos0.variadic and !pos0.required) {
            try w.print(" [PATHS]...", .{});
            try w.print("\n{s} <COMMAND>", .{cmd.name});
            return out.toOwnedSlice(allocator);
        }
    }

    if (cmd.subcommands.items.len > 0) {
        try w.print(" <COMMAND>", .{});
    }
    for (cmd.positionals.items) |pos| {
        if (pos.variadic) {
            try w.print(" <{s}>...", .{pos.name});
        } else if (pos.required) {
            try w.print(" <{s}>", .{pos.name});
        } else {
            try w.print(" [{s}]", .{pos.name});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildPositionals(allocator: std.mem.Allocator, cmd: *const Command) ![]PositionalDoc {
    var items = try allocator.alloc(PositionalDoc, cmd.positionals.items.len);
    errdefer allocator.free(items);
    for (cmd.positionals.items, 0..) |pos, i| {
        const display = if (pos.variadic)
            try std.fmt.allocPrint(allocator, "<{s}>...", .{pos.name})
        else if (pos.required)
            try std.fmt.allocPrint(allocator, "<{s}>", .{pos.name})
        else
            try std.fmt.allocPrint(allocator, "[{s}]", .{pos.name});
        items[i] = .{
            .name = pos.name,
            .display = display,
            .description = pos.description,
            .required = pos.required,
            .required_text = if (pos.required) "yes" else "no",
            .variadic = pos.variadic,
            .variadic_text = if (pos.variadic) "yes" else "no",
            .value_hint = pos.name,
            .possible_values = pos.allowed_values orelse &.{},
            .has_possible_values = pos.allowed_values != null and pos.allowed_values.?.len > 0,
        };
    }
    return items;
}

fn buildOptions(allocator: std.mem.Allocator, cmd: *const Command) ![]FlagDoc {
    var out = try std.ArrayList(FlagDoc).initCapacity(allocator, cmd.flags.len + 2);
    errdefer {
        for (out.items) |*flag| flag.deinit(allocator);
        out.deinit(allocator);
    }

    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    for (chain.items) |ancestor| {
        for (ancestor.flags.constSlice()) |flag| {
            if (ancestor != cmd and !flag.persistent) continue;
            try out.append(allocator, try flagDocFromFlag(allocator, flag, if (ancestor == cmd) "local" else "global", false));
        }
    }

    try out.append(allocator, try builtinFlagDoc(allocator, "-h, --help", "help", "Print help."));
    if (cmd.parent == null and cmd.rootConst().version != null) {
        try out.append(allocator, try builtinFlagDoc(allocator, "-V, --version", "version", "Print version."));
    }

    return out.toOwnedSlice(allocator);
}

fn flagDocFromFlag(allocator: std.mem.Allocator, flag: Command.Flag, scope: []const u8, builtin: bool) !FlagDoc {
    const full_signature = try buildFlagSpec(allocator, flag);
    errdefer allocator.free(full_signature);
    const short = if (flag.short) |short_name| try std.fmt.allocPrint(allocator, "-{c}", .{short_name}) else try allocator.dupe(u8, "");
    errdefer allocator.free(short);
    const long_display = try std.fmt.allocPrint(allocator, "--{s}", .{flag.name});
    errdefer allocator.free(long_display);
    const default_value = try defaultValueString(allocator, flag);
    errdefer allocator.free(default_value);

    const kv = flag.key_value_help;
    const has_kv = kv != null and flag.value_type == .key_value_list;

    var value_hint_owned: ?[]const u8 = null;
    errdefer if (value_hint_owned) |s| allocator.free(s);
    const value_hint_doc: []const u8 = if (flag.value_type == .key_value_list and flag.key_metavar != null and flag.value_metavar != null) blk: {
        const s = try std.fmt.allocPrint(allocator, "{s}={s}", .{ flag.key_metavar.?, flag.value_metavar.? });
        value_hint_owned = s;
        break :blk s;
    } else if (flag.value_hint) |h| h else typeToken(flag.value_type);

    const hide_kv_enum = flag.value_type == .key_value_list and flag.allowed_keys != null;
    const possible = flag.allowed_values orelse &.{};
    const has_possible = flag.allowed_values != null and flag.allowed_values.?.len > 0 and !hide_kv_enum;

    return .{
        .name = flag.name,
        .short = short,
        .long_display = long_display,
        .full_signature = full_signature,
        .description = flag.description,
        .extended = flag.long_description,
        .type_name = typeToken(flag.value_type),
        .required = flag.required,
        .required_text = if (flag.required) "yes" else "no",
        .default_value = default_value,
        .has_default = flag.default_value != null,
        .scope = scope,
        .value_hint = value_hint_doc,
        .value_hint_owned = value_hint_owned,
        .possible_values = possible,
        .has_possible_values = has_possible,
        .is_bool = flag.value_type == .bool,
        .is_builtin = builtin,
        .is_repeatable = flag.value_type == .string_list or flag.value_type == .key_value_list,
        .has_key_value_metadata = has_kv,
        .kv_keys = if (has_kv) kv.?.keys else &.{},
        .kv_values = if (has_kv) kv.?.values else &.{},
        .kv_override_note = if (has_kv) kv.?.override_behavior_note else "",
        .flag_examples = flag.examples orelse &.{},
        .kv_examples = if (has_kv) kv.?.examples else &.{},
    };
}

fn builtinFlagDoc(allocator: std.mem.Allocator, signature: []const u8, name: []const u8, description: []const u8) !FlagDoc {
    return .{
        .name = name,
        .short = try allocator.dupe(u8, ""),
        .long_display = try allocator.dupe(u8, ""),
        .full_signature = try allocator.dupe(u8, signature),
        .description = description,
        .extended = "",
        .type_name = "bool",
        .required = false,
        .required_text = "no",
        .default_value = try allocator.dupe(u8, ""),
        .has_default = false,
        .scope = "built-in",
        .value_hint = "",
        .value_hint_owned = null,
        .possible_values = &.{},
        .has_possible_values = false,
        .is_bool = true,
        .is_builtin = true,
        .is_repeatable = false,
        .has_key_value_metadata = false,
        .kv_keys = &.{},
        .kv_values = &.{},
        .kv_override_note = "",
        .flag_examples = &.{},
        .kv_examples = &.{},
    };
}

fn defaultValueString(allocator: std.mem.Allocator, flag: Command.Flag) ![]const u8 {
    const value = flag.default_value orelse return allocator.dupe(u8, "");
    return switch (value) {
        .bool => |v| allocator.dupe(u8, if (v) "true" else "false"),
        .string => |v| allocator.dupe(u8, v),
        .int => |v| std.fmt.allocPrint(allocator, "{}", .{v}),
        .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
        .enum_tag => |ord| allocator.dupe(u8, resolveEnumTagName(flag, ord)),
        .string_list => allocator.dupe(u8, "set"),
    };
}

fn buildSubcommands(allocator: std.mem.Allocator, cmd: *const Command) ![]SubcommandDoc {
    const count = cmd.subcommands.items.len + if (cmd.parent == null) @as(usize, 1) else 0;
    var items = try allocator.alloc(SubcommandDoc, count);
    errdefer allocator.free(items);

    var i: usize = 0;
    for (cmd.subcommands.items) |sub| {
        items[i] = try subcommandDocFromCommand(allocator, sub);
        i += 1;
    }
    if (cmd.parent == null) {
        const display_path = try std.fmt.allocPrint(allocator, "{s} help", .{cmd.name});
        errdefer allocator.free(display_path);
        items[i] = .{
            .name = "help",
            .display_path = display_path,
            .anchor = try anchorForDisplayPath(allocator, display_path),
            .description = "Print this message or the help of the given subcommand(s)",
        };
    }
    return items;
}

fn subcommandDocFromCommand(allocator: std.mem.Allocator, cmd: *const Command) !SubcommandDoc {
    const display_path = try commandPath(allocator, cmd);
    errdefer allocator.free(display_path);
    return .{
        .name = cmd.name,
        .display_path = display_path,
        .anchor = try anchorForDisplayPath(allocator, display_path),
        .description = cmd.description,
    };
}

fn buildCommandIndex(allocator: std.mem.Allocator, root: *const Command, commands_flat: []const CommandDoc) ![]const u8 {
    _ = commands_flat;
    var out = try std.ArrayList(u8).initCapacity(allocator, 512);
    errdefer out.deinit(allocator);
    try appendCommandIndexLine(allocator, &out, root, 0);
    for (root.subcommands.items) |sub| {
        try appendCommandIndexTree(allocator, &out, sub, 1);
    }
    const help_display_path = try std.fmt.allocPrint(allocator, "{s} help", .{root.name});
    defer allocator.free(help_display_path);
    const help_anchor = try anchorForDisplayPath(allocator, help_display_path);
    defer allocator.free(help_anchor);
    try out.print(allocator, "  ** xref:{s}[`{s}`] - Print this message or the help of the given subcommand(s)\n", .{ help_anchor, help_display_path });
    return out.toOwnedSlice(allocator);
}

fn appendCommandIndexTree(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cmd: *const Command, depth: usize) !void {
    try appendCommandIndexLine(allocator, out, cmd, depth);
    for (cmd.subcommands.items) |sub| {
        try appendCommandIndexTree(allocator, out, sub, depth + 1);
    }
}

fn appendCommandIndexLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cmd: *const Command, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "  ");
    try out.append(allocator, '*');
    if (depth > 0) try out.append(allocator, '*');
    try out.append(allocator, ' ');
    const display_path = try commandPath(allocator, cmd);
    defer allocator.free(display_path);
    const anchor = try anchorForDisplayPath(allocator, display_path);
    defer allocator.free(anchor);
    try out.print(allocator, "xref:{s}[`{s}`]", .{ anchor, display_path });
    if (cmd.description.len > 0) try out.print(allocator, " - {s}", .{cmd.description});
    try out.append(allocator, '\n');
}

/// Builds the display spec string for a flag (e.g. `-m, --message <STRING>`).
fn buildFlagSpec(allocator: std.mem.Allocator, flag: Command.Flag) ![]u8 {
    const repeat = if (flag.value_type == .string_list or flag.value_type == .key_value_list) "..." else "";

    if (flag.negatable and flag.value_type == .bool) {
        if (flag.short) |short| {
            return std.fmt.allocPrint(allocator, "-{c}, --[no-]{s}", .{ short, flag.name });
        }
        return std.fmt.allocPrint(allocator, "--[no-]{s}", .{flag.name});
    }
    if (flag.short) |short| {
        if (flag.value_type == .bool) {
            return std.fmt.allocPrint(allocator, "-{c}, --{s}", .{ short, flag.name });
        }
        if (flag.value_type == .key_value_list and flag.key_metavar != null and flag.value_metavar != null) {
            return std.fmt.allocPrint(allocator, "-{c}, --{s} <{s}={s}>{s}", .{ short, flag.name, flag.key_metavar.?, flag.value_metavar.?, repeat });
        }
        if (flag.value_hint) |hint| {
            if (hint.len > 0 and (hint[0] == '<' or hint[0] == '[')) {
                return std.fmt.allocPrint(allocator, "-{c}, --{s} {s}{s}", .{ short, flag.name, hint, repeat });
            }
            return std.fmt.allocPrint(allocator, "-{c}, --{s} <{s}>{s}", .{ short, flag.name, hint, repeat });
        }
        return std.fmt.allocPrint(allocator, "-{c}, --{s} <{s}>{s}", .{ short, flag.name, typeToken(flag.value_type), repeat });
    }
    if (flag.value_type == .bool) {
        return std.fmt.allocPrint(allocator, "--{s}", .{flag.name});
    }
    if (flag.value_type == .key_value_list and flag.key_metavar != null and flag.value_metavar != null) {
        return std.fmt.allocPrint(allocator, "--{s} <{s}={s}>{s}", .{ flag.name, flag.key_metavar.?, flag.value_metavar.?, repeat });
    }
    if (flag.value_hint) |hint| {
        if (hint.len > 0 and (hint[0] == '<' or hint[0] == '[')) {
            return std.fmt.allocPrint(allocator, "--{s} {s}{s}", .{ flag.name, hint, repeat });
        }
        return std.fmt.allocPrint(allocator, "--{s} <{s}>{s}", .{ flag.name, hint, repeat });
    }
    return std.fmt.allocPrint(allocator, "--{s} <{s}>{s}", .{ flag.name, typeToken(flag.value_type), repeat });
}

fn typeToken(flag_type: Command.FlagType) []const u8 {
    return switch (flag_type) {
        .string, .string_list => "STRING",
        .key_value_list => "KEY=VALUE",
        .enum_tag => "VALUE",
        .int => "INT",
        .float => "FLOAT",
        .bool => "",
    };
}

/// Resolves the display name of an enum_tag ordinal from the flag descriptor.
fn resolveEnumTagName(flag: Command.Flag, ordinal: u32) []const u8 {
    const names = flag.allowed_values orelse return "set";
    const ords = flag.enum_values orelse return "set";
    for (ords, 0..) |ord, i| {
        if (ord == ordinal and i < names.len) return names[i];
    }
    return "set";
}

fn commandPath(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);
    return commandPathFromChain(allocator, chain.items);
}

fn commandPathFromChain(allocator: std.mem.Allocator, chain: []const *const Command) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer out.deinit(allocator);
    var w = ListWriter{ .allocator = allocator, .list = &out };
    for (chain, 0..) |node, j| {
        if (j != 0) try w.print(" ", .{});
        try w.print("{s}", .{node.name});
    }
    return out.toOwnedSlice(allocator);
}

fn anchorForDisplayPath(allocator: std.mem.Allocator, display_path: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, display_path.len + "cmd-".len);
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "cmd-");
    try appendSlug(allocator, &out, display_path);
    return out.toOwnedSlice(allocator);
}

fn appendSlug(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var previous_dash = false;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
            previous_dash = false;
        } else if (!previous_dash) {
            try out.append(allocator, '-');
            previous_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
}

fn slugify(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, name.len);
    errdefer out.deinit(allocator);
    try appendSlug(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}
