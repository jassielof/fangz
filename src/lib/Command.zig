//! Core command tree model for Fangz.
//!
//! This module defines commands, flags, positional arguments, hook wiring, and
//! parent/child relationships used by parsing, help rendering, completions, and
//! documentation generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ParseContext = @import("ParseContext.zig");

const Command = @This();

/// Maximum number of flags a single command may register.
/// Exceeding this limit returns `error.TooManyFlags`.
pub const MAX_INLINE_FLAGS = 32;

/// Fixed-capacity inline array of Flag descriptors.
///
/// Stores all flag metadata directly inside the Command struct — no heap
/// allocation is needed for CLIs with ≤ MAX_INLINE_FLAGS flags per command.
/// The API mirrors the subset of `std.BoundedArray` used by this module.
pub const FlagArray = struct {
    buffer: [MAX_INLINE_FLAGS]Flag = undefined,
    len: usize = 0,

    pub fn append(self: *FlagArray, item: Flag) error{Overflow}!void {
        if (self.len >= MAX_INLINE_FLAGS) return error.Overflow;
        self.buffer[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *FlagArray) []Flag {
        return self.buffer[0..self.len];
    }

    pub fn constSlice(self: *const FlagArray) []const Flag {
        return self.buffer[0..self.len];
    }
};

pub const FlagType = enum {
    bool,
    string,
    int,
    float,
    string_list,
    key_value_list,
    enum_tag,
};

pub const KeyValuePair = struct {
    key: []const u8,
    value: []const u8,
};

pub const KeyValueList = []const KeyValuePair;

pub const DefaultValue = union(enum) {
    bool: bool,
    string: []const u8,
    int: i64,
    float: f64,
    string_list: []const []const u8,
    enum_tag: u32,
};

/// Controls how `allowed_values` are rendered in help output.
pub const AllowedValuesStyle = enum {
    /// Shows values inline: "[possible values: a, b, c]".
    comma,
    /// Shows values as a Carnaval bullet list below the argument/flag description.
    bullet_list,
};

pub const Flag = struct {
    name: []const u8,
    short: ?u8 = null,
    /// One-line summary shown in both `-h` and `--help` output.
    description: []const u8 = "",
    /// Extended description shown only in `--help` output.
    long_description: []const u8 = "",
    value_type: FlagType = .bool,
    required: bool = false,
    persistent: bool = false,
    /// When true, the flag also accepts a `--no-<name>` form that sets it false.
    /// Only valid for boolean flags.
    negatable: bool = false,
    default_value: ?DefaultValue = null,
    allowed_values: ?[]const []const u8 = null,
    enum_values: ?[]const u32 = null,
    allowed_keys: ?[]const []const u8 = null,
    value_hint: ?[]const u8 = null,
    /// Controls how `allowed_values` are rendered in help output.
    allowed_values_style: AllowedValuesStyle = .comma,
    /// Optional display labels for each allowed value, shown alongside the value in help output.
    /// When provided, must have the same length as `allowed_values`.
    allowed_value_labels: ?[]const []const u8 = null,

    /// Returns whether the flag expects a value token.
    pub fn takesValue(self: Flag) bool {
        return self.value_type != .bool;
    }
};

fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn isStringSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .slice) return false;
    return ptr.child == u8 and ptr.is_const;
}

fn isStringListType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .slice or !ptr.is_const) return false;
    return isStringSlice(ptr.child);
}

fn isKeyValueListType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .slice or !ptr.is_const) return false;
    return ptr.child == KeyValuePair;
}

fn typeToFlagType(comptime T: type) FlagType {
    if (T == bool) return .bool;
    if (T == i64) return .int;
    if (T == f64) return .float;
    if (isStringSlice(T)) return .string;
    if (isStringListType(T)) return .string_list;
    if (isKeyValueListType(T)) return .key_value_list;
    if (@typeInfo(T) == .@"enum") return .enum_tag;
    @compileError("unsupported flag type: " ++ @typeName(T));
}

pub fn FlagOptions(comptime T: type) type {
    const Base = unwrapOptional(T);
    return struct {
        name: []const u8,
        short: ?u8 = null,
        /// One-line summary shown in `-h` and `--help` output.
        description: []const u8 = "",
        /// Extended description shown only in `--help` output.
        long_description: []const u8 = "",
        required: bool = false,
        persistent: bool = false,
        /// Accept `--no-<name>` form to set the flag false.  Only valid for bool flags.
        negatable: bool = false,
        default: ?Base = null,
        multi: bool = false,
        value_hint: ?[]const u8 = null,
        allowed_keys: ?[]const []const u8 = null,
        allowed_values: ?[]const []const u8 = null,
        /// Controls how `allowed_values` are rendered in help output.
        allowed_values_style: AllowedValuesStyle = .comma,
        /// Optional display labels for each allowed value, shown alongside the value in help output.
        allowed_value_labels: ?[]const []const u8 = null,
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

fn EnumTagValueTable(comptime EnumType: type) type {
    const info = @typeInfo(EnumType);
    if (info != .@"enum") {
        @compileError("enum value table expects an enum type");
    }

    return struct {
        pub const values = blk: {
            const fields = info.@"enum".fields;
            var enum_values: [fields.len]u32 = undefined;
            for (fields, 0..) |field, i| {
                enum_values[i] = @intCast(field.value);
            }
            break :blk enum_values;
        };
    };
}

/// A user-supplied Nushell custom completer that can be attached to a positional argument.
///
/// `name` becomes both the `def` name and the `@name` reference in the `extern` signature.
/// `body` is the single expression (or newline-separated statements) that forms the
/// body of the generated `def <name> [] { <body> }` block.
///
/// Example — complete only YAML files:
/// ```zig
/// .nu_completer = .{
///     .name = "complete-yaml-files",
///     .body = "ls *.yaml | get name",
/// }
/// ```
pub const NuCompleter = struct {
    /// The Nushell `def` name, e.g. `"complete-zig-paths"`.  Must be a valid Nu identifier.
    name: []const u8,
    /// The body placed inside `def <name> [] { ... }`.  Single-line expressions work as-is;
    /// for multi-line bodies embed `\n` with appropriate indentation.
    body: []const u8,
};

pub const Positional = struct {
    name: []const u8,
    description: []const u8 = "",
    required: bool = false,
    variadic: bool = false,
    /// Optional constrained value set shown as `[possible values: ...]` in help.
    allowed_values: ?[]const []const u8 = null,
    /// Controls how `allowed_values` are rendered in help output.
    allowed_values_style: AllowedValuesStyle = .comma,
    /// Optional display labels for each allowed value, shown alongside the value in help output.
    /// When provided, must have the same length as `allowed_values`.
    allowed_value_labels: ?[]const []const u8 = null,
    /// Optional Nushell custom completer for this positional.
    /// When set, the generated `extern` signature uses `string@<name>` and a corresponding
    /// `def <name> [] { <body> }` is emitted inside the completions module.
    nu_completer: ?NuCompleter = null,
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
    /// One-line summary shown in `-h` and `--help` output.
    description: []const u8 = "",
    /// Extended description shown only in `--help` output.
    long_description: []const u8 = "",
    version: ?[]const u8 = null,
    group_id: ?[]const u8 = null,
};

allocator: Allocator,
parent: ?*Command = null,
name: []const u8,
/// One-line summary shown in `-h` and `--help` output.
description: []const u8,
/// Extended description shown only in `--help` output.
long_description: []const u8,
version: ?[]const u8,
group_id: ?[]const u8,
aliases: std.ArrayList([]const u8),
groups: std.ArrayList(Group),
/// Inline flag storage — no heap allocation for CLIs with ≤MAX_INLINE_FLAGS flags.
flags: FlagArray,
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
/// Set by freeze(). Prevents further structural mutations.
frozen: bool = false,

/// Creates a command node with empty child collections.
pub fn init(allocator: Allocator, cfg: Init) !Command {
    return .{
        .allocator = allocator,
        .name = cfg.name,
        .description = cfg.description,
        .long_description = cfg.long_description,
        .version = cfg.version,
        .group_id = cfg.group_id,
        .aliases = try std.ArrayList([]const u8).initCapacity(allocator, 2),
        .groups = try std.ArrayList(Group).initCapacity(allocator, 2),
        .flags = .{},
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

/// Adds a typed flag and updates fast lookup registries.
pub fn addFlag(self: *Command, comptime T: type, opts: FlagOptions(T)) !void {
    if (self.frozen) return error.FrozenCommand;

    const Base = unwrapOptional(T);
    const value_type = comptime typeToFlagType(Base);

    if (isOptional(T) and opts.default != null) return error.InvalidFlagConfiguration;
    if (opts.multi and value_type != .string_list and value_type != .key_value_list) {
        return error.InvalidFlagConfiguration;
    }

    if (opts.negatable and value_type != .bool) return error.InvalidFlagConfiguration;

    var flag: Flag = .{
        .name = opts.name,
        .short = opts.short,
        .description = opts.description,
        .long_description = opts.long_description,
        .value_type = value_type,
        .required = opts.required,
        .persistent = opts.persistent,
        .negatable = opts.negatable,
        .allowed_keys = opts.allowed_keys,
        .value_hint = opts.value_hint,
        .allowed_values_style = opts.allowed_values_style,
        .allowed_value_labels = opts.allowed_value_labels,
    };

    if (value_type == .enum_tag) {
        flag.allowed_values = &EnumTagNameTable(Base).values;
        flag.enum_values = &EnumTagValueTable(Base).values;
    } else {
        flag.allowed_values = opts.allowed_values;
    }

    if (opts.default) |default_value| {
        flag.default_value = switch (value_type) {
            .bool => .{ .bool = default_value },
            .string => .{ .string = default_value },
            .int => .{ .int = default_value },
            .float => .{ .float = default_value },
            .string_list => .{ .string_list = default_value },
            .enum_tag => .{ .enum_tag = @intFromEnum(default_value) },
            .key_value_list => null,
        };
    }

    if (self.flag_by_name.contains(flag.name)) return error.DuplicateFlag;
    if (flag.short) |short| {
        if (self.flag_by_short.contains(short)) return error.DuplicateFlag;
    }
    const idx = self.flags.len;
    self.flags.append(flag) catch return error.TooManyFlags;
    try self.flag_by_name.put(flag.name, idx);
    if (flag.short) |short| try self.flag_by_short.put(short, idx);
}

/// Adds an already-built flag descriptor and updates lookup registries.
pub fn addFlagDescriptor(self: *Command, flag: Flag) !void {
    if (self.frozen) return error.FrozenCommand;
    if (self.flag_by_name.contains(flag.name)) return error.DuplicateFlag;
    if (flag.short) |short| {
        if (self.flag_by_short.contains(short)) return error.DuplicateFlag;
    }
    const idx = self.flags.len;
    self.flags.append(flag) catch return error.TooManyFlags;
    try self.flag_by_name.put(flag.name, idx);
    if (flag.short) |short| try self.flag_by_short.put(short, idx);
}

/// Appends a positional argument definition to this command.
pub fn addPositional(self: *Command, positional: Positional) !void {
    if (self.frozen) return error.FrozenCommand;
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
    if (self.frozen) return error.FrozenCommand;
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

/// Marks this command tree as frozen.
///
/// Populates subcommand alias lookup tables then sets `frozen = true` on every
/// node, preventing further structural mutations (addFlag, addSubcommand, …).
/// Called automatically by `App.executeFrom` / `App.parseFrom` before parsing
/// begins.  It is safe to call multiple times; subsequent calls are no-ops.
pub fn freeze(self: *Command) !void {
    if (self.frozen) return;
    try self.bindAliases();
    self.setFrozenRecursive();
}

fn setFrozenRecursive(self: *Command) void {
    self.frozen = true;
    for (self.subcommands.items) |sub| sub.setFrozenRecursive();
}

/// Returns true when this command has any user-visible options.
///
/// Shared by HelpRenderer and DocGenerator to determine whether `[OPTIONS]`
/// appears in the usage line, ensuring both renderers use identical logic.
pub fn hasAnyOptions(self: *const Command) bool {
    if (self.flags.len > 0) return true;
    if (self.rootConst().version != null) return true;
    var current = self.parent;
    while (current) |p| : (current = p.parent) {
        for (p.flags.constSlice()) |flag| {
            if (flag.persistent) return true;
        }
    }
    return true; // --help is always present
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
            const flag = cmd.flags.constSlice()[idx];
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
            const flag = cmd.flags.constSlice()[idx];
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
