//! The base command structure for Fangz commands.
//!
//! It represents your typical command, such as `zig build`, where `build` is the command.
const Command = @This();

const std = @import("std");
const Arg = @import("Arg.zig");

const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const EnumSet = std.EnumSet;
const StringHashMap = std.StringHashMap;
const default_init_array_capacity = 10;

/// Represents the different parsing behaviors that can be applied to a
/// command.
pub const Property = enum {
    /// Configures to display help when arguments are not provided.
    help_on_empty_args,
    /// Specifies that a positional argument must be provided for the command.
    positional_arg_required,
    /// Specifies that a subcommand must be provided for the command.
    subcommand_required,
};

/// Function type for Run hooks. Receives the command and parsed arguments.
pub const RunFunc = *const fn (*Command, []const []const u8) void;
/// Function type for Run hooks that return errors.
pub const RunFuncE = *const fn (*Command, []const []const u8) anyerror!void;

allocator: Allocator,
/// The name of the command.
name: []const u8,
/// Use is the one-line usage message.
/// Recommended syntax:
///   [ ] identifies an optional argument. Arguments that are not enclosed in brackets are required.
///   ... indicates that you can specify multiple values for the previous argument.
///   |   indicates mutually exclusive information.
/// Example: add [-F file | -D dir]... [-f format] profile
use: ?[]const u8 = null,
/// Short is the short description shown in the 'help' output.
short: ?[]const u8 = null,
/// Long is the long message shown in the 'help <this-command>' output.
long: ?[]const u8 = null,
/// Description is a general description (kept for backward compatibility).
/// Prefer using `short` and `long` for new code.
description: ?[]const u8 = null,
/// Example is examples of how to use the command.
example: ?[]const u8 = null,
/// Aliases is an array of aliases that can be used instead of the first word in Use.
aliases: ArrayList([]const u8),
/// SuggestFor is an array of command names for which this command will be suggested -
/// similar to aliases but only suggests.
suggest_for: ArrayList([]const u8),
/// The group id under which this subcommand is grouped in the 'help' output of its parent.
group_id: ?[]const u8 = null,
/// Version defines the version for this command. If this value is non-empty and the command does not
/// define a "version" flag, a "version" boolean flag will be added to the command.
version: ?[]const u8 = null,
/// Deprecated defines, if this command is deprecated and should print this string when used.
deprecated: ?[]const u8 = null,
/// Hidden defines, if this command is hidden and should NOT show up in the list of available commands.
hidden: bool = false,
/// Annotations are key/value pairs that can be used by applications to identify or
/// group commands or set special options.
annotations: StringHashMap([]const u8),
/// Parent is a parent command for this command.
parent: ?*Command = null,
/// The *Run functions are executed in the following order:
///   * PersistentPreRun()
///   * PreRun()
///   * Run()
///   * PostRun()
///   * PersistentPostRun()
/// All functions get the same args, the arguments after the command name.
persistent_pre_run: ?RunFunc = null,
persistent_pre_run_e: ?RunFuncE = null,
pre_run: ?RunFunc = null,
pre_run_e: ?RunFuncE = null,
run: ?RunFunc = null,
run_e: ?RunFuncE = null,
post_run: ?RunFunc = null,
post_run_e: ?RunFuncE = null,
persistent_post_run: ?RunFunc = null,
persistent_post_run_e: ?RunFuncE = null,
/// inReader is a reader defined by the user that replaces stdin.
in_reader: ?std.io.AnyReader = null,
/// outWriter is a writer defined by the user that replaces stdout.
out_writer: ?std.io.AnyWriter = null,
/// errWriter is a writer defined by the user that replaces stderr.
err_writer: ?std.io.AnyWriter = null,
positional_args: ArrayList(Arg),
options: ArrayList(Arg),
subcommands: ArrayList(Command),
properties: EnumSet(Property) = .{},

/// Creates a new instance of `Command`.
///
/// **NOTE:** It is generally recommended to use `App.createCommand` to create a
/// new instance of a `Command`.
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var subcmd1 = app.createCommand("subcmd1", "First Subcommand");
/// var subcmd2 = app.createCommand("subcmd2", "Second Subcommand");
/// ```
pub fn init(allocator: Allocator, name: []const u8, description: ?[]const u8) !Command {
    return Command{
        .allocator = allocator,
        .name = name,
        .description = description,
        .aliases = try ArrayList([]const u8).initCapacity(allocator, default_init_array_capacity),
        .suggest_for = try ArrayList([]const u8).initCapacity(allocator, default_init_array_capacity),
        .annotations = StringHashMap([]const u8).init(allocator),
        .positional_args = try ArrayList(Arg).initCapacity(allocator, default_init_array_capacity),
        .options = try ArrayList(Arg).initCapacity(allocator, default_init_array_capacity),
        .subcommands = try ArrayList(Command).initCapacity(allocator, default_init_array_capacity),
    };
}

/// Deallocates all allocated memory.
pub fn deinit(self: *Command) void {
    self.positional_args.deinit(self.allocator);
    self.options.deinit(self.allocator);
    self.aliases.deinit(self.allocator);
    self.suggest_for.deinit(self.allocator);

    // Note: We don't deallocate keys/values as they're assumed to be static strings
    // If they're dynamically allocated, the caller should handle that
    self.annotations.deinit();

    for (self.subcommands.items) |*subcommand| {
        subcommand.deinit();
    }
    self.subcommands.deinit(self.allocator);
}

/// Appends the new argument to the list of arguments.
///
/// **NOTE:** It returns an `error.DuplicatePositionalArgIndex` when attempting
/// to append two positional arguments with the same index. See the examples below.
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// try root.addArg(Arg.booleanOption("version", 'v', "Show version number"));
///
/// var test = app.createCommand("test", "Run test");
/// try test.addArg(Arg.positional("FILE", null, null));
/// ```
///
/// Appending two positional arguments with the same index.
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// try root.addArg(Arg.positional("FIRST", null, 1));
/// // Returns `error.DuplicatePositionalArgIndex`.
/// try root.addArg(Arg.positional("SECOND", null, 1));
/// ```
pub fn addArg(self: *Command, arg: Arg) !void {
    var new_arg = arg;
    const is_positional = (arg.short_name == null) and (arg.long_name == null);

    // If its not a positional argument, append it and return.
    if (!is_positional) {
        return self.options.append(self.allocator, new_arg);
    }

    // Its a positonal argument.
    //
    // If the position is set check for position duplication.
    if (new_arg.index != null) {
        for (self.positional_args.items) |positional_arg| {
            std.debug.assert(positional_arg.index != null);

            if (positional_arg.index.? == new_arg.index.?) {
                return error.DuplicatePositionalArgIndex;
            }
        }
        // No duplication; append it.
        return self.positional_args.append(self.allocator, new_arg);
    }

    // If the position is not set and if its the first positional argument
    // then return immediately by giving it first position.
    if (self.positional_args.items.len == 0) {
        new_arg.setIndex(1);
        return self.positional_args.append(self.allocator, new_arg);
    }

    // If the position is not set and if its not first positional argument
    // then find the next position for it.
    var current_position: usize = 1;

    for (self.positional_args.items) |positional_arg| {
        std.debug.assert(positional_arg.index != null);

        if (positional_arg.index.? > current_position) {
            current_position = positional_arg.index.?;
        }
    }

    new_arg.setIndex(current_position + 1);
    try self.positional_args.append(self.allocator, new_arg);
}

/// Appends multiple arguments to the list of arguments.
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// try root.addArgs(&[_]Arg {
///     Arg.singleValueOption("firstname", 'f', "First name"),
///     Arg.singleValueOption("lastname", 'l', "Last name"),
/// });
///
/// var address = app.createCommand("address", "Address");
/// try address.addArgs(&[_]Arg {
///     Arg.singleValueOption("street", 's', "Street name"),
///     Arg.singleValueOption("postal", 'p', "Postal code"),
/// });
/// ```
pub fn addArgs(self: *Command, args: []const Arg) !void {
    for (args) |arg| try self.addArg(arg);
}

/// Appends the new subcommand to the list of subcommands.
/// Sets the parent of the subcommand to this command.
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
///
/// var test = app.createCommand("test", "Run test");
/// try test.addArg(Arg.positional("FILE", null, null));
///
/// try root.addSubcommand(test);
/// ```
pub fn addSubcommand(self: *Command, new_subcommand: Command) !void {
    var subcmd = new_subcommand;
    subcmd.setParent(self);
    try self.subcommands.append(self.allocator, subcmd);
}

/// Appends multiple subcommands to the list of subcommands.
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
///
/// try root.addSubcommands(&[_]Command{
///     app.createCommand("init-exe", "Initilize the project"),
///     app.createCommand("build", "Build the project"),
/// });
/// ```
pub fn addSubcommands(self: *Command, subcommands: []const Command) !void {
    for (subcommands) |subcmd| try self.addSubcommand(subcmd);
}

/// Sets a property to the command, specifying how it should be parsed and
/// processed.
///
/// ## Examples
///
/// Setting a property to indicate that the positional argument is required:
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
///
/// try root.addArg(Arg.positional("SOURCE", "Source file to move", null));
/// try root.addArg(Arg.positional("DEST", "Destination path", null));
/// root.setProperty(.positional_arg_required);
/// ```
pub fn setProperty(self: *Command, property: Property) void {
    return self.properties.insert(property);
}

/// Unsets a property from the command, reversing its effect on parsing and
/// processing.
pub fn unsetProperty(self: *Command, property: Property) void {
    return self.properties.remove(property);
}

/// Checks if the command has a specific property set.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn hasProperty(self: *const Command, property: Property) bool {
    return self.properties.contains(property);
}

/// Returns the count of positional arguments in the positional argument list.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn countPositionalArgs(self: *const Command) usize {
    return (self.positional_args.items.len);
}

/// Returns the count of options in the option list.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn countOptions(self: *const Command) usize {
    return (self.options.items.len);
}

/// Returns the count of subcommands in the subcommand list.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn countSubcommands(self: *const Command) usize {
    return (self.subcommands.items.len);
}

/// Performs a linear search to find a positional argument with the given index.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn findPositionalArgByIndex(self: *const Command, index: usize) ?*const Arg {
    for (self.positional_args.items) |*pos_arg| {
        std.debug.assert(pos_arg.index != null);

        if (pos_arg.index.? == index) {
            return pos_arg;
        }
    }
    return null;
}

/// Performs a linear search to find a short option with the given short name.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn findShortOption(self: *const Command, short_name: u8) ?*const Arg {
    for (self.options.items) |*arg| {
        if (arg.short_name) |s| {
            if (s == short_name) return arg;
        }
    }
    return null;
}

/// Performs a linear search to find a long option with the given long name.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn findLongOption(self: *const Command, long_name: []const u8) ?*const Arg {
    for (self.options.items) |*arg| {
        if (arg.long_name) |l| {
            if (mem.eql(u8, l, long_name)) return arg;
        }
    }
    return null;
}

/// Performs a linear search to find a subcommand with the given subcommand name.
///
/// **NOTE:** This function is primarily used by the parser.
pub fn findSubcommand(self: *const Command, subcommand: []const u8) ?*const Command {
    for (self.subcommands.items) |*subcmd| {
        if (std.mem.eql(u8, subcmd.name, subcommand)) {
            return subcmd;
        }
        // Check aliases
        for (subcmd.aliases.items) |alias| {
            if (std.mem.eql(u8, alias, subcommand)) {
                return subcmd;
            }
        }
    }

    return null;
}

/// Sets the Use string for the command.
pub fn setUse(self: *Command, use: []const u8) void {
    self.use = use;
}

/// Sets the short description for the command.
pub fn setShort(self: *Command, short: []const u8) void {
    self.short = short;
}

/// Sets the long description for the command.
pub fn setLong(self: *Command, long: []const u8) void {
    self.long = long;
}

/// Sets the example string for the command.
pub fn setExample(self: *Command, example: []const u8) void {
    self.example = example;
}

/// Adds an alias for the command.
pub fn addAlias(self: *Command, alias: []const u8) !void {
    try self.aliases.append(self.allocator, alias);
}

/// Adds multiple aliases for the command.
pub fn addAliases(self: *Command, aliases: []const []const u8) !void {
    for (aliases) |alias| {
        try self.addAlias(alias);
    }
}

/// Sets the group ID for the command.
pub fn setGroupID(self: *Command, group_id: []const u8) void {
    self.group_id = group_id;
}

/// Sets the version string for the command.
pub fn setVersion(self: *Command, version: []const u8) void {
    self.version = version;
}

/// Sets the deprecated message for the command.
pub fn setDeprecated(self: *Command, deprecated: []const u8) void {
    self.deprecated = deprecated;
}

/// Sets whether the command is hidden.
pub fn setHidden(self: *Command, hidden: bool) void {
    self.hidden = hidden;
}

/// Adds a command name to SuggestFor.
pub fn addSuggestFor(self: *Command, command_name: []const u8) !void {
    try self.suggest_for.append(self.allocator, command_name);
}

/// Adds multiple command names to SuggestFor.
pub fn addSuggestForMany(self: *Command, command_names: []const []const u8) !void {
    for (command_names) |name| {
        try self.addSuggestFor(name);
    }
}

/// Sets an annotation on the command.
pub fn setAnnotation(self: *Command, key: []const u8, value: []const u8) !void {
    try self.annotations.put(key, value);
}

/// Gets an annotation from the command.
pub fn getAnnotation(self: *const Command, key: []const u8) ?[]const u8 {
    return self.annotations.get(key);
}

/// Sets the parent command.
pub fn setParent(self: *Command, parent: *Command) void {
    self.parent = parent;
}

/// Returns the parent command if it exists.
pub fn getParent(self: *const Command) ?*const Command {
    return self.parent;
}

/// Checks if the command has a parent.
pub fn hasParent(self: *const Command) bool {
    return self.parent != null;
}

/// Sets the PersistentPreRun hook.
pub fn setPersistentPreRun(self: *Command, hook: RunFunc) void {
    self.persistent_pre_run = hook;
}

/// Sets the PersistentPreRunE hook.
pub fn setPersistentPreRunE(self: *Command, hook: RunFuncE) void {
    self.persistent_pre_run_e = hook;
}

/// Sets the PreRun hook.
pub fn setPreRun(self: *Command, hook: RunFunc) void {
    self.pre_run = hook;
}

/// Sets the PreRunE hook.
pub fn setPreRunE(self: *Command, hook: RunFuncE) void {
    self.pre_run_e = hook;
}

/// Sets the Run hook.
pub fn setRun(self: *Command, hook: RunFunc) void {
    self.run = hook;
}

/// Sets the RunE hook.
pub fn setRunE(self: *Command, hook: RunFuncE) void {
    self.run_e = hook;
}

/// Sets the PostRun hook.
pub fn setPostRun(self: *Command, hook: RunFunc) void {
    self.post_run = hook;
}

/// Sets the PostRunE hook.
pub fn setPostRunE(self: *Command, hook: RunFuncE) void {
    self.post_run_e = hook;
}

/// Sets the PersistentPostRun hook.
pub fn setPersistentPostRun(self: *Command, hook: RunFunc) void {
    self.persistent_post_run = hook;
}

/// Sets the PersistentPostRunE hook.
pub fn setPersistentPostRunE(self: *Command, hook: RunFuncE) void {
    self.persistent_post_run_e = hook;
}

/// Gets the effective description (short if available, otherwise description).
pub fn getDescription(self: *const Command) ?[]const u8 {
    return self.short orelse self.description;
}

/// Gets the effective long description (long if available, otherwise description).
pub fn getLongDescription(self: *const Command) ?[]const u8 {
    return self.long orelse self.description;
}

/// Returns the root command by traversing up the parent chain.
pub fn getRoot(self: *const Command) *const Command {
    var current: *const Command = self;
    while (current.parent) |parent| {
        current = parent;
    }
    return current;
}

/// Returns the root command by traversing up the parent chain (mutable version).
pub fn getRootMut(self: *Command) *Command {
    var current: *Command = self;
    while (current.parent) |parent| {
        current = parent;
    }
    return current;
}

/// Sets the source for input data.
/// If new_in is null, stdin will be used (via InOrStdin).
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// var buffer = std.ArrayList(u8).init(allocator);
/// defer buffer.deinit();
/// root.setIn(buffer.reader().any());
/// ```
pub fn setIn(self: *Command, new_in: ?std.io.AnyReader) void {
    self.in_reader = new_in;
}

/// Sets the destination for usage messages.
/// If new_out is null, stdout will be used (via OutOrStdout).
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// var buffer = std.ArrayList(u8).init(allocator);
/// defer buffer.deinit();
/// root.setOut(buffer.writer().any());
/// ```
pub fn setOut(self: *Command, new_out: ?std.io.AnyWriter) void {
    self.out_writer = new_out;
}

/// Sets the destination for error messages.
/// If new_err is null, stderr will be used (via ErrOrStderr).
///
/// ## Examples
///
/// ```zig
/// var app = App.init(allocator, "myapp", "My app description");
/// defer app.deinit();
///
/// var root = app.rootCommand();
/// var buffer = std.ArrayList(u8).init(allocator);
/// defer buffer.deinit();
/// root.setErr(buffer.writer().any());
/// ```
pub fn setErr(self: *Command, new_err: ?std.io.AnyWriter) void {
    self.err_writer = new_err;
}

/// Returns input reader, traversing up the parent chain if not set.
/// Falls back to stdin if no custom reader is set in the command tree.
pub fn inOrStdin(_: *const Command) std.io.AnyReader {
    var buffer: [0]u8 = undefined;
    const reader = std.fs.File.stdin().reader(&buffer);
    return std.io.wrapReader(reader);
}

/// Returns output writer for usage messages, traversing up the parent chain if not set.
/// Falls back to stdout if no custom writer is set in the command tree.
pub fn outOrStdout(_: *const Command) std.io.AnyWriter {
    var buffer: [0]u8 = undefined;
    const writer = std.fs.File.stdout().writer(&buffer);
    return std.io.wrapWriter(writer);
}

/// Returns output writer for error messages, traversing up the parent chain if not set.
/// Falls back to stderr if no custom writer is set in the command tree.
pub fn errOrStderr(_: *const Command) std.io.AnyWriter {
    var buffer: [0]u8 = undefined;
    const writer = std.fs.File.stderr().writer(&buffer);
    return std.io.wrapWriter(writer);
}

/// Internal helper to get input reader, traversing up parent chain.
fn getIn(self: *const Command, default_reader: std.io.AnyReader) std.io.AnyReader {
    if (self.in_reader) |reader| {
        return reader;
    }
    if (self.parent) |parent| {
        return parent.getIn(default_reader);
    }
    return default_reader;
}

/// Internal helper to get output writer, traversing up parent chain.
fn getOut(self: *const Command, default_writer: std.io.AnyWriter) std.io.AnyWriter {
    if (self.out_writer) |writer| {
        return writer;
    }
    if (self.parent) |parent| {
        return parent.getOut(default_writer);
    }
    return default_writer;
}

/// Internal helper to get error writer, traversing up parent chain.
fn getErr(self: *const Command, default_writer: std.io.AnyWriter) std.io.AnyWriter {
    if (self.err_writer) |writer| {
        return writer;
    }
    if (self.parent) |parent| {
        return parent.getErr(default_writer);
    }
    return default_writer;
}
