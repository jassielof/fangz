const std = @import("std");
const fangz = @import("fangz");
const root_cmd = @import("commands/root.zig");

pub fn main() !void {
    var app = try fangz.App.init(std.heap.page_allocator, .{
        .name = "fangz-cli",
        .description = "Scaffolding CLI built with Fangz",
        .version = "0.1.0",
    });
    defer app.deinit();

    try root_cmd.register(app.root());
    try app.executeProcess();
}
