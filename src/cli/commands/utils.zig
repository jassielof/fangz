const std = @import("std");
const fangz = @import("fangz");

pub fn isDryRun(ctx: *fangz.ParseContext) bool {
    return ctx.boolFlag("dry-run") orelse false;
}

pub fn workDir(ctx: *fangz.ParseContext) []const u8 {
    return ctx.stringFlag("cwd") orelse ".";
}

pub fn logAction(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  - " ++ fmt ++ "\n", args);
}

pub fn ensureDir(path: []const u8, dry_run: bool) !void {
    if (dry_run) {
        logAction("mkdir {s}", .{path});
        return;
    }
    try std.fs.cwd().makePath(path);
}

pub fn writeNewFile(path: []const u8, content: []const u8, dry_run: bool) !void {
    if (dry_run) {
        logAction("write {s}", .{path});
        return;
    }

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try std.fs.cwd().makePath(parent);
        }
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = false, .exclusive = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn join2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ a, b });
}

pub fn join3(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ a, b, c });
}
