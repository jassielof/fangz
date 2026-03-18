//! Markdown documentation generator for Fangz command trees.
//!
//! Supports self-contained single-file output and per-command directory output.

const std = @import("std");
const Command = @import("Command.zig");

/// Modes for generation the documentation.
pub const Mode = enum {
    /// Generate a single markdown file containing the entire command hierarchy.
    single_file,
    /// Generate separate markdown files for each command, organized in directories.
    per_command,
};

/// Options for documentation generation.
pub const Options = struct {
    /// The generation mode to use.
    mode: Mode = .single_file,
    /// The output directory where documentation files will be written.
    output_dir: []const u8 = "docs",
    /// The file name to use when generating a single markdown file.
    single_file_name: []const u8 = "cli.md",
    /// Whether to include hidden commands in the generated documentation.
    include_hidden: bool = false,
    /// Whether to overwrite existing files in the output directory.
    overwrite: bool = true,
};

/// Generates markdown documentation for the given command hierarchy based on the provided options.
pub fn generateMarkdownDocs(
    allocator: std.mem.Allocator,
    root: *const Command,
    options: Options,
) !void {
    _ = options.include_hidden; // Reserved for future hidden-command support.
    try std.fs.cwd().makePath(options.output_dir);

    switch (options.mode) {
        .single_file => {
            const doc = try renderSingleFileMarkdown(allocator, root);
            defer allocator.free(doc);

            const output_path = try std.fs.path.join(allocator, &.{ options.output_dir, options.single_file_name });
            defer allocator.free(output_path);
            try writeFile(output_path, doc, options.overwrite);
        },
        .per_command => {
            try writePerCommand(allocator, root, options.output_dir, options.overwrite);
        },
    }
}

/// Renders all commands recursively into one markdown document.
fn renderSingleFileMarkdown(allocator: std.mem.Allocator, root: *const Command) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer out.deinit(allocator);

    try appendCommandDocRecursive(allocator, &out, root, true);
    return out.toOwnedSlice(allocator);
}

/// Appends a command section and subcommand sections recursively.
fn appendCommandDocRecursive(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cmd: *const Command,
    is_first: bool,
) !void {
    const w = out.writer(allocator);
    if (!is_first) {
        try w.print("\n---\n\n", .{});
    }

    const section = try renderCommandMarkdown(allocator, cmd, false);
    defer allocator.free(section);
    try w.print("{s}", .{section});

    for (cmd.subcommands.items) |sub| {
        try appendCommandDocRecursive(allocator, out, sub, false);
    }
}

/// Writes command docs as one file per command directory.
fn writePerCommand(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    dir_path: []const u8,
    overwrite: bool,
) !void {
    try std.fs.cwd().makePath(dir_path);

    const body = try renderCommandMarkdown(allocator, cmd, true);
    defer allocator.free(body);

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "index.md" });
    defer allocator.free(file_path);
    try writeFile(file_path, body, overwrite);

    for (cmd.subcommands.items) |sub| {
        const slug = try slugify(allocator, sub.name);
        defer allocator.free(slug);
        const child_dir = try std.fs.path.join(allocator, &.{ dir_path, slug });
        defer allocator.free(child_dir);
        try writePerCommand(allocator, sub, child_dir, overwrite);
    }
}

/// Writes one file with overwrite semantics.
fn writeFile(path: []const u8, content: []const u8, overwrite: bool) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }

    const file = try std.fs.cwd().createFile(path, .{
        .truncate = overwrite,
        .exclusive = !overwrite,
    });
    defer file.close();
    try file.writeAll(content);
}

/// Renders one command markdown document section.
fn renderCommandMarkdown(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    include_links: bool,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    const path_name = try commandPath(allocator, cmd);
    defer allocator.free(path_name);

    try w.print("# `{s}`\n\n", .{path_name});
    if (cmd.description.len > 0) {
        try w.print("{s}\n\n", .{cmd.description});
    }

    if (include_links and cmd.parent != null) {
        try w.print("> Parent: `{s}`\n\n", .{cmd.parent.?.name});
    }

    try w.print("## Usage\n\n", .{});
    try w.print("`{s}", .{path_name});
    if (cmd.hasAnyOptions()) try w.print(" [OPTIONS]", .{});
    if (cmd.subcommands.items.len > 0) try w.print(" <COMMAND>", .{});
    for (cmd.positionals.items) |pos| {
        if (pos.variadic) {
            try w.print(" <{s}>...", .{pos.name});
        } else if (pos.required) {
            try w.print(" <{s}>", .{pos.name});
        } else {
            try w.print(" [{s}]", .{pos.name});
        }
    }
    try w.print("`\n\n", .{});

    if (cmd.aliases.items.len > 0) {
        try w.print("## Aliases\n\n", .{});
        for (cmd.aliases.items) |alias| {
            try w.print("- `{s}`\n", .{alias});
        }
        try w.print("\n", .{});
    }

    if (cmd.version) |version| {
        try w.print("## Version\n\n`{s}`\n\n", .{version});
    }

    if (cmd.positionals.items.len > 0) {
        try w.print("## Arguments\n\n", .{});
        try w.print("| Name | Required | Variadic | Description |\n", .{});
        try w.print("|---|---|---|---|\n", .{});
        for (cmd.positionals.items) |pos| {
            try w.print("| `{s}` | {s} | {s} | {s} |\n", .{
                pos.name,
                yesNo(pos.required),
                yesNo(pos.variadic),
                pos.description,
            });
        }
        try w.print("\n", .{});
    }

    try w.print("## Options\n\n", .{});
    try w.print("| Flag | Type | Required | Default | Scope | Description |\n", .{});
    try w.print("|---|---|---|---|---|---|\n", .{});
    try appendOptionsTable(allocator, cmd, w);
    try w.print("| `-h, --help` | `bool` | no | - | local | Print help |\n", .{});
    if (cmd.rootConst().version != null) {
        try w.print("| `-V, --version` | `bool` | no | - | local | Print version |\n", .{});
    }
    try w.print("\n", .{});

    if (cmd.subcommands.items.len > 0) {
        try w.print("## Commands\n\n", .{});
        for (cmd.subcommands.items) |sub| {
            if (include_links) {
                const slug = try slugify(allocator, sub.name);
                defer allocator.free(slug);
                try w.print("- [`{s}`]({s}/index.md): {s}\n", .{
                    sub.name,
                    slug,
                    sub.description,
                });
            } else {
                try w.print("- `{s}`: {s}\n", .{ sub.name, sub.description });
            }
        }
        try w.print("- `help`: Print this message or help of subcommands\n\n", .{});
    }

    return out.toOwnedSlice(allocator);
}

/// Appends options table rows for local and inherited persistent flags.
fn appendOptionsTable(allocator: std.mem.Allocator, cmd: *const Command, w: anytype) !void {
    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    for (chain.items) |ancestor| {
        for (ancestor.flags.constSlice()) |flag| {
            if (ancestor != cmd and !flag.persistent) continue;

            const spec = try flagSpec(allocator, flag);
            defer allocator.free(spec);
            const typ = if (flag.value_type == .bool) "bool" else switch (flag.value_type) {
                .string => "string",
                .int => "int",
                .float => "float",
                .string_list => "string[]",
                .key_value_list => "key=value[]",
                .enum_tag => "enum",
                .bool => unreachable,
            };
            const def = defaultText(flag);
            const scope = if (ancestor == cmd) "local" else "global";
            const desc = try optionDescription(allocator, flag);
            defer allocator.free(desc);

            try w.print("| `{s}` | `{s}` | {s} | `{s}` | {s} | {s} |\n", .{
                spec,
                typ,
                yesNo(flag.required),
                def,
                scope,
                desc,
            });
        }
    }
}

/// Builds one human-readable option description string.
fn optionDescription(allocator: std.mem.Allocator, flag: Command.Flag) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 128);
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{s}", .{flag.description});
    if (flag.allowed_values) |values| {
        try w.print(" (possible values: ", .{});
        for (values, 0..) |v, i| {
            if (i != 0) try w.print(", ", .{});
            try w.print("{s}", .{v});
        }
        try w.print(")", .{});
    }
    return out.toOwnedSlice(allocator);
}

/// Builds display spec text for a single flag.
fn flagSpec(allocator: std.mem.Allocator, flag: Command.Flag) ![]u8 {
    if (flag.short) |short| {
        if (flag.value_type == .bool) {
            return std.fmt.allocPrint(allocator, "-{c}, --{s}", .{ short, flag.name });
        }
        return std.fmt.allocPrint(allocator, "-{c}, --{s} <{s}>", .{
            short,
            flag.name,
            if (flag.value_hint) |hint| hint else typeToken(flag.value_type),
        });
    }

    if (flag.value_type == .bool) {
        return std.fmt.allocPrint(allocator, "--{s}", .{flag.name});
    }
    return std.fmt.allocPrint(allocator, "--{s} <{s}>", .{
        flag.name,
        if (flag.value_hint) |hint| hint else typeToken(flag.value_type),
    });
}

/// Returns uppercase display token for value types.
fn typeToken(flag_type: Command.FlagType) []const u8 {
    return switch (flag_type) {
        .string, .string_list => "STRING",
        .key_value_list => "KEY=VALUE",
        .enum_tag => "VALUE",
        .int => "INT",
        .float => "FLOAT",
        .bool => "BOOL",
    };
}

/// Returns display text for default values in docs.
///
/// For `enum_tag` flags the actual variant name is looked up from the flag's
/// `allowed_values` / `enum_values` tables, matching the behaviour of the
/// help renderer.
fn defaultText(flag: Command.Flag) []const u8 {
    const default_value = flag.default_value orelse return "-";
    return switch (default_value) {
        .bool => |v| if (v) "true" else "false",
        .string => |v| v,
        .int => "set",
        .float => "set",
        .enum_tag => |ordinal| blk: {
            const names = flag.allowed_values orelse break :blk "set";
            const ords = flag.enum_values orelse break :blk "set";
            for (ords, 0..) |ord, i| {
                if (ord == ordinal and i < names.len) break :blk names[i];
            }
            break :blk "set";
        },
        .string_list => "set",
    };
}

/// Builds fully-qualified command path text from ancestry.
fn commandPath(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    var out = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    for (chain.items, 0..) |node, i| {
        if (i != 0) try w.print(" ", .{});
        try w.print("{s}", .{node.name});
    }
    return out.toOwnedSlice(allocator);
}

/// Converts command name to a file-system-safe slug.
fn slugify(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, name.len);
    errdefer out.deinit(allocator);
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
        } else {
            try out.append(allocator, '-');
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Converts bool to `yes` or `no` table text.
fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
