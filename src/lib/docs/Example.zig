const std = @import("std");

/// Render-ready AsciiDoc example block body for documentation templates.
description: []const u8,
content: []const u8,
content_owned: bool = false,

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    if (self.content_owned) allocator.free(self.content);
}
