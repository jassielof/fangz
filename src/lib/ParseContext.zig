//! Parsed argument context exposed to command hooks.
//!
//! This module stores resolved flags, positional values, and parse control
//! signals like help/version requests.

const std = @import("std");
const Command = @import("Command.zig");

pub const FlagValue = union(enum) {
    bool: bool,
    string: []const u8,
    int: i64,
    float: f64,
    string_list: std.ArrayList([]const u8),

    /// Releases resources for heap-backed variants.
    pub fn deinit(self: *FlagValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string_list => |*values| values.deinit(allocator),
            else => {},
        }
    }
};

const ParseContext = @This();

allocator: std.mem.Allocator,
command: *Command,
flags: std.StringHashMap(FlagValue),
positionals: std.ArrayList([]const u8),
raw_positionals_after_terminator: std.ArrayList([]const u8),
help_requested: bool = false,
version_requested: bool = false,

/// Initializes an empty parse context for a command.
pub fn init(allocator: std.mem.Allocator, command: *Command) !ParseContext {
    return .{
        .allocator = allocator,
        .command = command,
        .flags = std.StringHashMap(FlagValue).init(allocator),
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
    self.positionals.deinit(self.allocator);
    self.raw_positionals_after_terminator.deinit(self.allocator);
}

/// Returns whether a flag was parsed and stored.
pub fn hasFlag(self: *const ParseContext, name: []const u8) bool {
    return self.flags.contains(name);
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

    const raw = self.stringFlag(name) orelse return null;
    return std.meta.stringToEnum(EnumType, raw);
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

/// Gets positional token by zero-based index.
pub fn positional(self: *const ParseContext, index: usize) ?[]const u8 {
    if (index >= self.positionals.items.len) return null;
    return self.positionals.items[index];
}
