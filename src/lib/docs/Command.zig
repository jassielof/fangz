const std = @import("std");

const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const Positional = @import("Positional.zig");
const Subcommand = @import("Subcommand.zig");

name: []const u8,
display_path: []const u8,
path_parts: []const []const u8,
anchor: []const u8,
depth: usize,
description: []const u8,
long_description: []const u8,
usage: []const u8,
parent_display_path: []const u8,
parent_anchor: []const u8,
has_parent: bool,
positionals: []Positional,
has_positionals: bool,
options: []Flag,
has_options: bool,
subcommands: []Subcommand,
has_subcommands: bool,

pub fn empty() Command {
    return .{
        .name = "",
        .display_path = "",
        .path_parts = &.{},
        .anchor = "",
        .depth = 0,
        .description = "",
        .long_description = "",
        .usage = "",
        .parent_display_path = "",
        .parent_anchor = "",
        .has_parent = false,
        .positionals = &.{},
        .has_positionals = false,
        .options = &.{},
        .has_options = false,
        .subcommands = &.{},
        .has_subcommands = false,
    };
}
pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
    allocator.free(self.display_path);
    allocator.free(self.path_parts);
    allocator.free(self.anchor);
    allocator.free(self.usage);

    if (self.has_parent) {
        allocator.free(self.parent_display_path);
        allocator.free(self.parent_anchor);
    }

    for (self.positionals) |*pos| pos.deinit(allocator);
    allocator.free(self.positionals);

    for (self.options) |*flag| flag.deinit(allocator);
    allocator.free(self.options);

    for (self.subcommands) |*sub| sub.deinit(allocator);
    allocator.free(self.subcommands);
}
