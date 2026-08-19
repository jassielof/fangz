//! Parsed argument context exposed to command hooks.
//!
//! This module stores resolved flags, positional values, and parse control signals like help/version requests.
//!
//! ## Lifetime and ownership
//!
//! `ParseContext` **borrows** from the argv slice it was parsed from. Every `[]const u8` value stored here — flag strings, positional strings, and the key/value slices inside `KeyValuePair` — is a direct sub-slice of the original argv allocation. No per-value string duplication is performed.
//!
//! Concretely, when called through `App.executeProcess`, these slices are tied to owned argument copies kept alive for the duration of command execution. `App.parseProcess` keeps those owned copies on the app until the next parse or `App.deinit`.
//!
//! If you hold a `*ParseContext` obtained from `App.parseFrom` with a caller-owned argv slice, ensure the argv allocation outlives the context.

const std = @import("std");

const Command = @import("Command.zig");

pub const FlagValue = union(enum) {
    bool: bool,
    string: []const u8,
    int: i64,
    float: f64,
    string_list: std.ArrayList([]const u8),
    key_value_list: std.ArrayList(Command.KeyValuePair),
    enum_tag: u32,

    /// Releases resources for heap-backed variants.
    pub fn deinit(self: *FlagValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string_list => |*values| values.deinit(allocator),
            .key_value_list => |*values| values.deinit(allocator),
            else => {},
        }
    }
};

const ParseContext = @This();

allocator: std.mem.Allocator,
io: std.Io,
command: *Command,
flags: std.StringHashMap(FlagValue),
/// Flag names explicitly present in argv, excluding values populated from defaults.
provided_flags: std.StringHashMap(void),
positionals: std.ArrayList([]const u8),
raw_positionals_after_terminator: std.ArrayList([]const u8),
/// Set when the user passes `--help` or `help <cmd>`.  Triggers full help rendering.
help_requested: bool = false,
/// Set when the user passes `-h`.  Triggers compact (summary-only) help rendering.
short_help_requested: bool = false,
version_requested: bool = false,

/// Initializes an empty parse context for a command.
pub fn init(allocator: std.mem.Allocator, io: std.Io, command: *Command) !ParseContext {
    return .{
        .allocator = allocator,
        .io = io,
        .command = command,
        .flags = std.StringHashMap(FlagValue).init(allocator),
        .provided_flags = std.StringHashMap(void).init(allocator),
        .positionals = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .raw_positionals_after_terminator = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Deinitializes all context-owned collections and values.
pub fn deinit(self: *ParseContext) void {
    var iter = self.flags.iterator();
    while (iter.next()) |entry| {
        var value = entry.value_ptr.*;
        value.deinit(self.allocator);
    }
    self.flags.deinit();
    self.provided_flags.deinit();
    self.positionals.deinit(self.allocator);
    self.raw_positionals_after_terminator.deinit(self.allocator);
}

/// Returns whether a flag was parsed and stored.
pub fn hasFlag(self: *const ParseContext, name: []const u8) bool {
    return self.flags.contains(name);
}

/// Returns whether argv explicitly supplied a flag, excluding default values.
pub fn wasFlagProvided(self: *const ParseContext, name: []const u8) bool {
    return self.provided_flags.contains(name);
}

/// Gets a parsed boolean flag value.
pub fn boolFlag(self: *const ParseContext, name: []const u8) ?bool {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

/// Gets a parsed string flag value.
pub fn stringFlag(self: *const ParseContext, name: []const u8) ?[]const u8 {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .string => |v| v,
        else => null,
    };
}

/// Gets a parsed string flag converted to a typed enum.
pub fn enumFlag(self: *const ParseContext, comptime EnumType: type, name: []const u8) ?EnumType {
    const info = @typeInfo(EnumType);
    if (info != .@"enum") {
        @compileError("enumFlag expects an enum type");
    }

    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .enum_tag => |raw| @as(EnumType, @enumFromInt(raw)),
        else => null,
    };
}

/// Gets a parsed integer flag value.
pub fn intFlag(self: *const ParseContext, name: []const u8) ?i64 {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .int => |v| v,
        else => null,
    };
}

/// Gets a parsed float flag value.
pub fn floatFlag(self: *const ParseContext, name: []const u8) ?f64 {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .float => |v| v,
        else => null,
    };
}

/// Gets parsed repeatable string values.
pub fn stringListFlag(self: *const ParseContext, name: []const u8) ?[]const []const u8 {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .string_list => |v| v.items,
        else => null,
    };
}

/// Gets parsed repeatable key/value pairs.
pub fn keyValueFlag(self: *const ParseContext, name: []const u8) ?[]const Command.KeyValuePair {
    const value = self.flags.get(name) orelse return null;
    return switch (value) {
        .key_value_list => |v| v.items,
        else => null,
    };
}

/// Gets positional token by zero-based index.
pub fn positional(self: *const ParseContext, index: usize) ?[]const u8 {
    if (index >= self.positionals.items.len) return null;
    return self.positionals.items[index];
}

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
    return ptr.size == .slice and ptr.is_const and ptr.child == u8;
}

fn isStringListType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    return ptr.size == .slice and ptr.is_const and isStringSlice(ptr.child);
}

fn isKeyValueListType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    return ptr.size == .slice and ptr.is_const and ptr.child == Command.KeyValuePair;
}

fn assignFieldValue(
    self: *const ParseContext,
    out: anytype,
    comptime field_name: []const u8,
    comptime FieldType: type,
) !bool {
    var name_buf: [field_name.len]u8 = undefined;

    inline for (field_name, 0..) |ch, i| {
        name_buf[i] = if (ch == '_') '-' else ch;
    }

    const name = name_buf[0..];
    const base = unwrapOptional(FieldType);

    if (comptime isOptional(FieldType)) {
        if (comptime @typeInfo(base) == .@"enum") {
            if (self.enumFlag(base, name)) |value| {
                @field(out.*, field_name) = value;
                return true;
            }
            @field(out.*, field_name) = null;
            return true;
        }

        if (comptime isStringSlice(base)) {
            if (self.stringFlag(name)) |value| {
                @field(out.*, field_name) = value;
                return true;
            }
            @field(out.*, field_name) = null;
            return true;
        }

        @compileError("Unsupported optional field type in extract: " ++ @typeName(FieldType));
    }

    if (comptime FieldType == bool) {
        if (self.boolFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }
        return false;
    }

    if (comptime FieldType == i64) {
        if (self.intFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }
        return false;
    }

    if (comptime FieldType == f64) {
        if (self.floatFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }
        return false;
    }

    if (comptime @typeInfo(FieldType) == .@"enum") {
        if (self.enumFlag(FieldType, name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }
        return false;
    }

    if (comptime isStringSlice(FieldType)) {
        if (self.stringFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }
        return false;
    }

    if (comptime isStringListType(FieldType)) {
        if (self.stringListFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }

        return false;
    }

    if (comptime isKeyValueListType(FieldType)) {
        if (self.keyValueFlag(name)) |value| {
            @field(out.*, field_name) = value;
            return true;
        }

        return false;
    }

    @compileError("Unsupported extract field type: " ++ @typeName(FieldType));
}

/// Extracts typed arguments from parsed context into a struct.
pub fn extract(self: *const ParseContext, comptime T: type) !T {
    const info = @typeInfo(T);

    if (info != .@"struct") {
        @compileError("extract expects a struct type");
    }

    var out: T = undefined;

    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;

        if (comptime std.mem.eql(u8, field.name, "positionals")) {
            if (FieldType != []const []const u8) {
                @compileError("field 'positionals' must be []const []const u8");
            }

            @field(out, field.name) = self.positionals.items;

            continue;
        }

        const assigned = try assignFieldValue(self, &out, field.name, FieldType);

        if (!assigned) {
            if (field.defaultValue()) |default_ptr| {
                @field(out, field.name) = default_ptr;
            } else if (comptime isOptional(FieldType)) {
                @field(out, field.name) = null;
            } else {
                return error.MissingRequiredFlag;
            }
        }
    }

    return out;
}
