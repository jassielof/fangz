//! Core command tree model for Fangz.
//!
//! This module defines commands, flags, positional arguments, hook wiring, and
//! parent/child relationships used by parsing, help rendering, completions, and
//! documentation generation.

const std = @import("std");
const ParseContext = @import("ParseContext.zig");

const Allocator = std.mem.Allocator;

const Command = @This();

pub const FlagType = enum {
    bool,
    string,
    int,
    float,
    string_list,
};

pub const DefaultValue = union(enum) {
    bool: bool,
    string: []const u8,
    int: i64,
    float: f64,
    string_list: []const []const u8,
};

pub const Flag = struct {
    name: []const u8,
    short: ?u8 = null,
    description: []const u8 = "",
    value_type: FlagType = .bool,
    required: bool = false,
    persistent: bool = false,
    default_value: ?DefaultValue = null,
    allowed_values: ?[]const []const u8 = null,

    /// Returns whether the flag expects a value token.
    pub fn takesValue(self: Flag) bool {
        return self.value_type != .bool;
    }
};

pub fn EnumFlagConfig(comptime EnumType: type) type {
    return struct {
        name: []const u8,
        short: ?u8 = null,
        description: []const u8 = "",
        required: bool = false,
        persistent: bool = false,
        default_value: ?EnumType = null,
    };
}

fn EnumTagNameTable(comptime EnumType: type) type {
    const info = @typeInfo(EnumType);
    if (info != .@"enum") {
        @compileError("addEnumFlag expects an enum type");
    }

    return struct {
        pub const values = blk: {
            const fields = info.@"enum".fields;
            var names: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, i| {
                names[i] = field.name;
            }
            break :blk names;
        };
    };
}

pub const Positional = struct {
    name: []const u8,
    description: []const u8 = "",
    required: bool = false,
    variadic: bool = false,
};

pub const Group = struct {
    id: []const u8,
    title: []const u8,
};

pub const MutuallyExclusive = struct {
    names: []const []const u8,
};

pub const Hooks = struct {
    /// Hook callback signature used during command execution lifecycle.
    pub const HookFn = *const fn (*ParseContext) anyerror!void;
    pre_run: ?HookFn = null,
    run: ?HookFn = null,
    post_run: ?HookFn = null,
    persistent_pre_run: ?HookFn = null,
    persistent_post_run: ?HookFn = null,
};

pub const Init = struct {
    name: []const u8,
    description: []const u8 = "",
    version: ?[]const u8 = null,
    group_id: ?[]const u8 = null,
};

allocator: Allocator,
parent: ?*Command = null,
name: []const u8,
description: []const u8,
version: ?[]const u8,
group_id: ?[]const u8,
aliases: std.ArrayList([]const u8),
groups: std.ArrayList(Group),
flags: std.ArrayList(Flag),
positionals: std.ArrayList(Positional),
subcommands: std.ArrayList(*Command),
subcommand_by_name: std.StringHashMap(*Command),
subcommand_aliases: std.StringHashMap(*Command),
flag_by_name: std.StringHashMap(usize),
flag_by_short: std.AutoHashMap(u8, usize),
exclusive_groups: std.ArrayList(MutuallyExclusive),
hooks: Hooks,
min_positionals: ?usize = null,
max_positionals: ?usize = null,
require_subcommand: bool = false,
help_on_empty_args: bool = false,

/// Creates a command node with empty child collections.
pub fn init(allocator: Allocator, cfg: Init) !Command {
    return .{
        .allocator = allocator,
        .name = cfg.name,
        .description = cfg.description,
        .version = cfg.version,
        .group_id = cfg.group_id,
        .aliases = try std.ArrayList([]const u8).initCapacity(allocator, 2),
        .groups = try std.ArrayList(Group).initCapacity(allocator, 2),
        .flags = try std.ArrayList(Flag).initCapacity(allocator, 8),
        .positionals = try std.ArrayList(Positional).initCapacity(allocator, 4),
        .subcommands = try std.ArrayList(*Command).initCapacity(allocator, 8),
        .subcommand_by_name = std.StringHashMap(*Command).init(allocator),
        .subcommand_aliases = std.StringHashMap(*Command).init(allocator),
        .flag_by_name = std.StringHashMap(usize).init(allocator),
        .flag_by_short = std.AutoHashMap(u8, usize).init(allocator),
        .exclusive_groups = try std.ArrayList(MutuallyExclusive).initCapacity(allocator, 2),
        .hooks = .{},
    };
}

/// Recursively deinitializes the command and all descendants.
pub fn deinit(self: *Command) void {
    for (self.subcommands.items) |sub| {
        sub.deinit();
        self.allocator.destroy(sub);
    }
    self.subcommands.deinit(self.allocator);
    self.subcommand_by_name.deinit();
    self.subcommand_aliases.deinit();
    self.flag_by_name.deinit();
    self.flag_by_short.deinit();
    self.aliases.deinit(self.allocator);
    self.groups.deinit(self.allocator);
    self.flags.deinit(self.allocator);
    self.positionals.deinit(self.allocator);
    self.exclusive_groups.deinit(self.allocator);
}

/// Adds a user-visible alias for this command.
pub fn addAlias(self: *Command, alias: []const u8) !void {
    try self.aliases.append(self.allocator, alias);
}

/// Registers a subcommand grouping bucket for help output.
pub fn addGroup(self: *Command, group: Group) !void {
    try self.groups.append(self.allocator, group);
}

/// Adds a flag and updates fast lookup registries.
pub fn addFlag(self: *Command, flag: Flag) !void {
    if (self.flag_by_name.contains(flag.name)) return error.DuplicateFlag;
    if (flag.short) |short| {
        if (self.flag_by_short.contains(short)) return error.DuplicateFlag;
    }
    const idx = self.flags.items.len;
    try self.flags.append(self.allocator, flag);
    try self.flag_by_name.put(flag.name, idx);
    if (flag.short) |short| try self.flag_by_short.put(short, idx);
}

/// Adds a string-backed enum-like flag with allowed values derived from enum tags.
pub fn addEnumFlag(self: *Command, comptime EnumType: type, cfg: EnumFlagConfig(EnumType)) !void {
    const info = @typeInfo(EnumType);
    if (info != .@"enum") {
        @compileError("addEnumFlag expects an enum type");
    }

    try self.addFlag(.{
        .name = cfg.name,
        .short = cfg.short,
        .description = cfg.description,
        .value_type = .string,
        .required = cfg.required,
        .persistent = cfg.persistent,
        .default_value = if (cfg.default_value) |v| .{ .string = @tagName(v) } else null,
        .allowed_values = &EnumTagNameTable(EnumType).values,
    });
}

/// Appends a positional argument definition to this command.
pub fn addPositional(self: *Command, positional: Positional) !void {
    if (positional.variadic and self.positionals.items.len != 0) {
        if (self.positionals.items[self.positionals.items.len - 1].variadic) {
            return error.MultipleVariadicPositionals;
        }
    }
    if (self.positionals.items.len > 0 and self.positionals.items[self.positionals.items.len - 1].variadic) {
        return error.VariadicMustBeLast;
    }
    try self.positionals.append(self.allocator, positional);
}

/// Adds a mutually-exclusive flag group definition.
pub fn addMutuallyExclusive(self: *Command, group: MutuallyExclusive) !void {
    try self.exclusive_groups.append(self.allocator, group);
}

/// Creates and attaches a new subcommand node.
pub fn addSubcommand(self: *Command, cfg: Init) !*Command {
    var ptr = try self.allocator.create(Command);
    ptr.* = try Command.init(self.allocator, cfg);
    ptr.parent = self;
    try self.subcommands.append(self.allocator, ptr);
    try self.subcommand_by_name.put(ptr.name, ptr);
    return ptr;
}

/// Sets lifecycle hooks for the command.
pub fn setHooks(self: *Command, hooks: Hooks) void {
    self.hooks = hooks;
}

/// Sets explicit lower/upper bounds for positional token count.
pub fn setPositionalBounds(self: *Command, min: ?usize, max: ?usize) void {
    self.min_positionals = min;
    self.max_positionals = max;
}

/// Configures whether this command should show help when invoked with no args.
pub fn setHelpOnEmptyArgs(self: *Command, enabled: bool) void {
    self.help_on_empty_args = enabled;
}

/// Resolves a direct subcommand by name or alias.
pub fn findSubcommand(self: *const Command, token: []const u8) ?*Command {
    if (self.subcommand_by_name.get(token)) |sub| return sub;
    if (self.subcommand_aliases.get(token)) |sub| return sub;
    return null;
}

/// Resolves a long flag across local and inherited persistent scope.
pub fn resolveFlagByName(self: *const Command, name: []const u8) ?FlagLookup {
    var current: ?*const Command = self;
    while (current) |cmd| {
        if (cmd.flag_by_name.get(name)) |idx| {
            const flag = cmd.flags.items[idx];
            if (cmd == self or flag.persistent) return .{ .command = cmd, .index = idx };
        }
        current = cmd.parent;
    }
    return null;
}

/// Resolves a short flag across local and inherited persistent scope.
pub fn resolveFlagByShort(self: *const Command, short: u8) ?FlagLookup {
    var current: ?*const Command = self;
    while (current) |cmd| {
        if (cmd.flag_by_short.get(short)) |idx| {
            const flag = cmd.flags.items[idx];
            if (cmd == self or flag.persistent) return .{ .command = cmd, .index = idx };
        }
        current = cmd.parent;
    }
    return null;
}

/// Returns the mutable root command.
pub fn root(self: *Command) *Command {
    var node = self;
    while (node.parent) |p| node = p;
    return node;
}

/// Returns the immutable root command.
pub fn rootConst(self: *const Command) *const Command {
    var node = self;
    while (node.parent) |p| node = p;
    return node;
}

/// Binds all child aliases into lookup tables recursively.
pub fn bindAliases(self: *Command) !void {
    const expected: u32 = @intCast(self.subcommand_aliases.count() + self.subcommands.items.len * 2);
    try self.subcommand_aliases.ensureTotalCapacity(expected);
    for (self.subcommands.items) |sub| {
        for (sub.aliases.items) |alias| {
            if (self.subcommand_aliases.contains(alias)) return error.DuplicateAlias;
            try self.subcommand_aliases.put(alias, sub);
        }
        try sub.bindAliases();
    }
}

/// Collects the command ancestry from root to `self`.
pub fn collectAncestorPath(self: *const Command, allocator: Allocator) !std.ArrayList(*const Command) {
    var reversed = try std.ArrayList(*const Command).initCapacity(allocator, 8);
    var current: ?*const Command = self;
    while (current) |cmd| : (current = cmd.parent) {
        try reversed.append(allocator, cmd);
    }

    var ordered = try std.ArrayList(*const Command).initCapacity(allocator, reversed.items.len);
    var i: usize = reversed.items.len;
    while (i > 0) : (i -= 1) {
        try ordered.append(allocator, reversed.items[i - 1]);
    }
    reversed.deinit(allocator);
    return ordered;
}

/// Result of a resolved flag lookup.
pub const FlagLookup = struct {
    command: *const Command,
    index: usize,
};
