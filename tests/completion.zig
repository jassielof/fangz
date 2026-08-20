//! Snapshot coverage for shell completions generated from the shared fixture CLI.

const std = @import("std");
const builtin = @import("builtin");
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

test "completion snapshots load in their target shells" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    if (builtin.os.tag == .windows) {
        try sourceSnapshot(&tmp, "fangz.ps1", @embedFile("snapshots/fangz.ps1"), .pwsh);
    } else {
        try sourceSnapshot(&tmp, "fangz.bash", @embedFile("snapshots/fangz.bash"), .bash);
        try sourceSnapshot(&tmp, "fangz.zsh", @embedFile("snapshots/fangz.zsh"), .zsh);
        try sourceSnapshot(&tmp, "fangz.fish", @embedFile("snapshots/fangz.fish"), .fish);
        try sourceSnapshot(&tmp, "fangz.nu", @embedFile("snapshots/fangz.nu"), .nu);
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

const Shell = enum {
    bash,
    zsh,
    fish,
    nu,
    pwsh,
};

fn sourceSnapshot(tmp: *testing.TmpDir, name: []const u8, contents: []const u8, shell: Shell) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });
    const path = try tmp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    defer testing.allocator.free(path);

    const nu_command = try std.fmt.allocPrint(testing.allocator, "source \"{f}\"", .{std.zig.fmtString(path)});
    defer testing.allocator.free(nu_command);

    const command: []const []const u8 = switch (shell) {
        .bash => &.{ "bash", "-c", "source \"$1\"", "bash", path },
        .zsh => &.{ "zsh", "-fc", "function compdef { :; }; source \"$1\"", "zsh", path },
        .fish => &.{ "fish", "-c", "source $argv[1]", path },
        .nu => &.{ "nu", "--commands", nu_command },
        .pwsh => &.{ "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "& { . $args[0] }", path },
    };

    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = command });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s} could not load {s}:\n{s}", .{ @tagName(shell), name, result.stderr });
            return error.ShellCompletionSnapshotDidNotLoad;
        },
        else => return error.ShellCompletionSnapshotDidNotLoad,
    }
}
