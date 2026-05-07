const std = @import("std");

const Positional = @This();
name: []const u8,
display: []const u8,
description: []const u8,
required: bool,
required_text: []const u8,
variadic: bool,
variadic_text: []const u8,
value_hint: []const u8,
possible_values: []const []const u8,
has_possible_values: bool,

pub fn deinit(self: *Positional, allocator: std.mem.Allocator) void {
    allocator.free(self.display);
}
