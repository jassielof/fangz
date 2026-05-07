const std = @import("std");

const Subcommand = @This();
name: []const u8,
display_path: []const u8,
anchor: []const u8,
description: []const u8,

pub fn deinit(self: *Subcommand, allocator: std.mem.Allocator) void {
    allocator.free(self.display_path);
    allocator.free(self.anchor);
}
