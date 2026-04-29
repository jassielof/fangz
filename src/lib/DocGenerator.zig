//! AsciiDoc documentation generator for Fangz command trees.
//!
//! Generates AsciiDoc (`.adoc`) files suitable for processing with
//! `asciidoctor` or Pandoc.  Two layout modes are supported: a single
//! self-contained file and one file per command organised in subdirectories.
//!
//! The `docs` subcommand is auto-injected into every `App` via
//! `registerDocsCommand` / `App.ensureDocsCommand`.

const std = @import("std");
const Command = @import("Command.zig");
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

/// Layout modes for documentation generation.
pub const Mode = enum {
    /// One self-contained file containing the full command hierarchy.
    single_file,
    /// One file per command, organised in subdirectories.
    per_command,
};

/// Options for AsciiDoc documentation generation.
pub const Options = struct {
    /// Layout mode.
    mode: Mode = .single_file,
    /// Output directory.
    output_dir: []const u8 = "docs",
    /// File name for `.single_file` mode.
    single_file_name: []const u8 = "cli.adoc",
    /// When true, hidden commands are included.
    include_hidden: bool = false,
    /// When true, existing files are overwritten.
    overwrite: bool = true,
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

    switch (options.mode) {
        .single_file => {
            const doc = try renderSingleFile(allocator, root);
            defer allocator.free(doc);

            const output_path = try std.fs.path.join(allocator, &.{ options.output_dir, options.single_file_name });
            defer allocator.free(output_path);
            try writeFile(io, output_path, doc, options.overwrite);
        },
        .per_command => {
            try writePerCommand(io, allocator, root, options.output_dir, options.overwrite);
        },
    }
}

// ── Single-file layout ────────────────────────────────────────────────────

fn renderSingleFile(allocator: std.mem.Allocator, root: *const Command) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer out.deinit(allocator);
    try appendRecursive(allocator, &out, root, 1, true);
    return out.toOwnedSlice(allocator);
}

fn appendRecursive(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cmd: *const Command,
    depth: u8,
    is_first: bool,
) !void {
    var w = ListWriter{ .allocator = allocator, .list = out };
    if (!is_first) try w.print("\n'''\n\n", .{});

    const section = try renderCommand(allocator, cmd, false, depth);
    defer allocator.free(section);
    try w.print("{s}", .{section});

    for (cmd.subcommands.items) |sub| {
        try appendRecursive(allocator, out, sub, depth + 1, false);
    }
}

// ── Per-command layout ────────────────────────────────────────────────────

fn writePerCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    cmd: *const Command,
    dir_path: []const u8,
    overwrite: bool,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    const body = try renderCommand(allocator, cmd, true, 1);
    defer allocator.free(body);

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "index.adoc" });
    defer allocator.free(file_path);
    try writeFile(io, file_path, body, overwrite);

    for (cmd.subcommands.items) |sub| {
        const slug = try slugify(allocator, sub.name);
        defer allocator.free(slug);
        const child_dir = try std.fs.path.join(allocator, &.{ dir_path, slug });
        defer allocator.free(child_dir);
        try writePerCommand(io, allocator, sub, child_dir, overwrite);
    }
}

// ── Command renderer ──────────────────────────────────────────────────────

fn renderCommand(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    include_links: bool,
    depth: u8,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer out.deinit(allocator);
    var w = ListWriter{ .allocator = allocator, .list = &out };

    const path_name = try commandPath(allocator, cmd);
    defer allocator.free(path_name);

    // Section heading: depth × '=' then ` \`name\``
    var i: u8 = 0;
    while (i < depth) : (i += 1) try w.print("=", .{});
    try w.print(" `{s}`\n\n", .{path_name});

    if (cmd.description.len > 0) try w.print("{s}\n\n", .{cmd.description});
    if (cmd.long_description.len > 0) try w.print("{s}\n\n", .{cmd.long_description});

    if (include_links and cmd.parent != null) {
        try w.print("_Parent: `{s}`_\n\n", .{cmd.parent.?.name});
    }

    // Usage block
    try w.print("== Usage\n\n----\n{s}", .{path_name});
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
    try w.print("\n----\n\n", .{});

    // Arguments
    if (cmd.positionals.items.len > 0) {
        try w.print("== Arguments\n\n", .{});
        for (cmd.positionals.items) |pos| {
            try w.print("`<{s}>`", .{pos.name});
            if (pos.variadic) try w.print("...", .{});
            try w.print("::\n", .{});
            if (pos.description.len > 0) try w.print("{s}", .{pos.description});
            if (pos.required) try w.print(" [required]", .{});
            if (pos.variadic) try w.print(" [variadic]", .{});
            if (pos.allowed_values) |vals| {
                try w.print(" +\n[possible values: ", .{});
                for (vals, 0..) |v, j| {
                    if (j != 0) try w.print(", ", .{});
                    try w.print("{s}", .{v});
                }
                try w.print("]", .{});
            }
            try w.print("\n\n", .{});
        }
    }

    // Subcommands
    if (cmd.subcommands.items.len > 0) {
        try w.print("== Commands\n\n", .{});
        for (cmd.subcommands.items) |sub| {
            if (include_links) {
                const slug = try slugify(allocator, sub.name);
                defer allocator.free(slug);
                try w.print("link:{s}/index.adoc[`{s}`]::\n{s}\n\n", .{ slug, sub.name, sub.description });
            } else {
                try w.print("`{s}`::\n{s}\n\n", .{ sub.name, sub.description });
            }
        }
        try w.print("`help`::\nPrint this message or help of the given subcommand(s)\n\n", .{});
    }

    // Options
    try w.print("== Options\n\n", .{});
    try appendOptions(allocator, cmd, w);
    try w.print("`-h, --help`::\nPrint help.\n\n", .{});
    if (cmd.parent == null and cmd.rootConst().version != null) {
        try w.print("`-V, --version`::\nPrint version.\n\n", .{});
    }

    return out.toOwnedSlice(allocator);
}

/// Appends AsciiDoc definition-list entries for all visible flags.
fn appendOptions(allocator: std.mem.Allocator, cmd: *const Command, w: anytype) !void {
    var chain = try cmd.collectAncestorPath(allocator);
    defer chain.deinit(allocator);

    for (chain.items) |ancestor| {
        for (ancestor.flags.constSlice()) |flag| {
            if (ancestor != cmd and !flag.persistent) continue;

            const spec = try buildFlagSpec(allocator, flag);
            defer allocator.free(spec);

            var desc = try std.ArrayList(u8).initCapacity(allocator, 128);
            defer desc.deinit(allocator);
            var dw = ListWriter{ .allocator = allocator, .list = &desc };

            try dw.print("{s}", .{flag.description});
            if (flag.long_description.len > 0) try dw.print(" {s}", .{flag.long_description});
            if (flag.required) try dw.print(" [required]", .{});
            if (flag.default_value) |dv| {
                switch (dv) {
                    .bool => |v| try dw.print(" [default: {s}]", .{if (v) "true" else "false"}),
                    .string => |v| try dw.print(" [default: {s}]", .{v}),
                    .int => |v| try dw.print(" [default: {}]", .{v}),
                    .float => |v| try dw.print(" [default: {d}]", .{v}),
                    .enum_tag => |ord| try dw.print(" [default: {s}]", .{resolveEnumTagName(flag, ord)}),
                    .string_list => try dw.print(" [default: set]", .{}),
                }
            }
            if (flag.allowed_values) |vals| {
                try dw.print(" [possible values: ", .{});
                for (vals, 0..) |v, j| {
                    if (j != 0) try dw.print(", ", .{});
                    try dw.print("{s}", .{v});
                }
                try dw.print("]", .{});
            }
            if (ancestor != cmd) try dw.print(" [global]", .{});

            try w.print("`{s}`::\n{s}\n\n", .{ spec, desc.items });
        }
    }
}

// ── Built-in docs subcommand ──────────────────────────────────────────────

/// Registers the built-in `docs` subcommand on root.
///
/// Generates AsciiDoc documentation for the application's full command tree.
/// Called automatically by `App.ensureDocsCommand` — applications do not need
/// to call this directly.
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
        .name = "mode",
        .description = "AsciiDoc layout to generate.",
        .default = "single_file",
        .allowed_values = &.{ "single_file", "per_command" },
    });
    try docs.addFlag([]const u8, .{
        .name = "file",
        .description = "File name to use with --mode single_file.",
        .default = "cli.adoc",
    });
    docs.setHooks(.{ .run = runDocsCommand });
}

fn runDocsCommand(ctx: *ParseContext) !void {
    const output_dir = ctx.stringFlag("output-dir") orelse "docs";
    const mode_str = ctx.stringFlag("mode") orelse "single_file";
    const file = ctx.stringFlag("file") orelse "cli.adoc";

    const mode: Mode = if (std.mem.eql(u8, mode_str, "per_command")) .per_command else .single_file;

    try generateDocs(ctx.allocator, ctx.io, ctx.command.root(), .{
        .mode = mode,
        .output_dir = output_dir,
        .single_file_name = file,
    });
}

// ── Shared helpers ────────────────────────────────────────────────────────

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

/// Builds the display spec string for a flag (e.g. `-m, --message <STRING>`).
fn buildFlagSpec(allocator: std.mem.Allocator, flag: Command.Flag) ![]u8 {
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

    var out = try std.ArrayList(u8).initCapacity(allocator, 64);
    errdefer out.deinit(allocator);
    var w = ListWriter{ .allocator = allocator, .list = &out };
    for (chain.items, 0..) |node, j| {
        if (j != 0) try w.print(" ", .{});
        try w.print("{s}", .{node.name});
    }
    return out.toOwnedSlice(allocator);
}

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
