//! Snapshot coverage for shell completions generated from the shared fixture CLI.

const std = @import("std");
const testing = std.testing;

const fangz = @import("fangz");
const fixture = @import("fixture");

test "shared fixture shell completions match the expected snapshots" {
    const completion_snapshots = [_]struct {
        shell: fangz.Shell,
        expected: []const u8,
    }{
        .{ .shell = .bash, .expected = @embedFile("snapshots/fangz.bash") },
        .{ .shell = .zsh, .expected = @embedFile("snapshots/fangz.zsh") },
        .{ .shell = .fish, .expected = @embedFile("snapshots/fangz.fish") },
        .{ .shell = .nu, .expected = @embedFile("snapshots/fangz.nu") },
        .{ .shell = .pwsh, .expected = @embedFile("snapshots/fangz.ps1") },
    };

    inline for (completion_snapshots) |snapshot| {
        var app: fangz.App = undefined;
        try fixture.initialize(&app, testing.allocator, testing.io);
        defer app.deinit();

        _ = try app.parseFrom(&.{});
        var current_buffer: [16 * 1024]u8 = undefined;
        var current = std.Io.Writer.fixed(&current_buffer);
        try app.generateCompletions(snapshot.shell, &current);

        try testing.expectEqualStrings(snapshot.expected, current.buffered());
    }
}

test "completion command with no args requests help" {
    var app = try makeApp();
    defer app.deinit();

    const ctx = try app.parseFrom(&.{"completion"});
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("completion", ctx.command.name);
}

test "completions alias resolves to completion command" {
    var app = try makeApp();
    defer app.deinit();

    const ctx = try app.parseFrom(&.{"completions"});
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("completion", ctx.command.name);
}

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .brief = "test app",
        .version = "1.2.3",
    });
}
