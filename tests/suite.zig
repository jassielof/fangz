const std = @import("std");
const testing = std.testing;
const refAllDecls = testing.refAllDecls;

const fangz = @import("fangz");

comptime {
    refAllDecls(@This());
}

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .description = "test app",
        .version = "1.2.3",
    });
}

test "dispatches nested subcommands with aliases" {
    var app = try makeApp();
    defer app.deinit();

    const remote = try app.root().addSubcommand(.{ .name = "remote", .description = "remote ops" });
    const add = try remote.addSubcommand(.{ .name = "add", .description = "add remote" });
    try add.addAlias("a");

    const ctx = try app.parseFrom(&.{ "remote", "a" });
    try testing.expectEqualStrings("add", ctx.command.name);
}

test "help on empty args applies to selected subcommand" {
    var app = try makeApp();
    defer app.deinit();

    const info = try app.root().addSubcommand(.{ .name = "info", .description = "show info" });
    info.setHelpOnEmptyArgs(true);

    const ctx = try app.parseFrom(&.{"info"});
    try testing.expectEqualStrings("info", ctx.command.name);
    try testing.expect(ctx.help_requested);
}

test "help subcommand requests root help" {
    var app = try makeApp();
    defer app.deinit();

    _ = try app.root().addSubcommand(.{ .name = "status", .description = "show status" });

    const ctx = try app.parseFrom(&.{"help"});
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("fangz", ctx.command.name);
}

test "help subcommand requests nested command help" {
    var app = try makeApp();
    defer app.deinit();

    const remote = try app.root().addSubcommand(.{ .name = "remote", .description = "remote ops" });
    _ = try remote.addSubcommand(.{ .name = "add", .description = "add remote" });

    const ctx = try app.parseFrom(&.{ "help", "remote", "add" });
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("add", ctx.command.name);
}

test "short flag bundling parses char by char" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(bool, .{ .name = "l", .short = 'l' });
    try root.addFlag(bool, .{ .name = "a", .short = 'a' });
    try root.addFlag([]const u8, .{ .name = "header", .short = 'H' });

    const ctx = try app.parseFrom(&.{ "-laH", "token" });
    try testing.expect(ctx.boolFlag("l").?);
    try testing.expect(ctx.boolFlag("a").?);
    try testing.expectEqualStrings("token", ctx.stringFlag("header").?);
}

test "typed flags include defaults and required validation" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(i64, .{ .name = "count", .short = 'c', .required = true });
    try root.addFlag(f64, .{ .name = "ratio", .default = 2.5 });
    try root.addFlag([]const u8, .{
        .name = "format",
        .allowed_values = &.{ "json", "table" },
        .default = "json",
    });

    try testing.expectError(error.MissingRequiredFlag, app.parseFrom(&.{}));

    const ctx = try app.parseFrom(&.{ "--count", "42" });
    try testing.expectEqual(@as(i64, 42), ctx.intFlag("count").?);
    try testing.expectApproxEqRel(@as(f64, 2.5), ctx.floatFlag("ratio").?, 0.0001);
    try testing.expectEqualStrings("json", ctx.stringFlag("format").?);
}

test "enum flag convenience parses default and explicit values" {
    const Output = enum { json, table };

    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(Output, .{
        .name = "output",
        .short = 'o',
        .description = "Output format",
        .default = .json,
    });

    const ctx_default = try app.parseFrom(&.{});
    try testing.expectEqual(Output.json, ctx_default.enumFlag(Output, "output").?);

    const ctx_explicit = try app.parseFrom(&.{ "--output", "table" });
    try testing.expectEqual(Output.table, ctx_explicit.enumFlag(Output, "output").?);
}

test "enum flag rejects invalid value" {
    const Output = enum { json, table };

    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(Output, .{ .name = "output" });
    try testing.expectError(error.InvalidEnumValue, app.parseFrom(&.{ "--output", "yaml" }));
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

test "negatable boolean flag sets to false with --no-flag" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(bool, .{ .name = "verbose", .short = 'v', .negatable = true, .default = true });

    const ctx_on = try app.parseFrom(&.{"--verbose"});
    try testing.expect(ctx_on.boolFlag("verbose").?);

    const ctx_off = try app.parseFrom(&.{"--no-verbose"});
    try testing.expect(!ctx_off.boolFlag("verbose").?);
}

test "short flag -h sets short_help_requested" {
    var app = try makeApp();
    defer app.deinit();

    const ctx = try app.parseFrom(&.{"-h"});
    try testing.expect(ctx.short_help_requested);
    try testing.expect(!ctx.help_requested);
}

test "long flag --help sets help_requested" {
    var app = try makeApp();
    defer app.deinit();

    const ctx = try app.parseFrom(&.{"--help"});
    try testing.expect(ctx.help_requested);
    try testing.expect(!ctx.short_help_requested);
}

test "version flag is only available on root command" {
    var app = try makeApp();
    defer app.deinit();

    _ = try app.root().addSubcommand(.{ .name = "status", .description = "show status" });

    const root_long = try app.parseFrom(&.{"--version"});
    try testing.expect(root_long.version_requested);
    try testing.expectEqualStrings("fangz", root_long.command.name);

    const root_short = try app.parseFrom(&.{"-V"});
    try testing.expect(root_short.version_requested);
    try testing.expectEqualStrings("fangz", root_short.command.name);

    try testing.expectError(error.UnknownFlag, app.parseFrom(&.{ "status", "--version" }));
    try testing.expectError(error.UnknownFlag, app.parseFrom(&.{ "status", "-V" }));
    try testing.expectError(error.UnknownFlag, app.parseFrom(&.{ "completion", "--version" }));
    try testing.expectError(error.UnknownFlag, app.parseFrom(&.{ "completion", "-V" }));
}

test "repeatable string list flag accumulates values" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const []const u8, .{ .name = "header", .short = 'H' });
    const ctx = try app.parseFrom(&.{ "--header", "A:B", "-H", "C:D" });
    const values = ctx.stringListFlag("header").?;
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("A:B", values[0]);
    try testing.expectEqualStrings("C:D", values[1]);
}

test "global persistent flag propagates to subcommands" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(bool, .{
        .name = "verbose",
        .short = 'v',
        .persistent = true,
    });
    _ = try app.root().addSubcommand(.{ .name = "status", .description = "status" });

    const ctx = try app.parseFrom(&.{ "status", "-v" });
    try testing.expectEqualStrings("status", ctx.command.name);
    try testing.expect(ctx.boolFlag("verbose").?);
}

test "double dash terminator keeps following tokens positional" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addPositional(.{ .name = "first", .required = true });
    try app.root().addPositional(.{ .name = "rest", .variadic = true });
    const ctx = try app.parseFrom(&.{ "one", "--", "-not-flag", "--still-not" });
    try testing.expectEqual(@as(usize, 3), ctx.positionals.items.len);
    try testing.expectEqualStrings("-not-flag", ctx.positionals.items[1]);
}

test "mutually exclusive flags fail when both are present" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(bool, .{ .name = "json" });
    try app.root().addFlag(bool, .{ .name = "yaml" });
    try app.root().addMutuallyExclusive(.{ .names = &.{ "json", "yaml" } });

    try testing.expectError(error.MutuallyExclusiveFlags, app.parseFrom(&.{ "--json", "--yaml" }));
}

test "unknown command returns error" {
    var app = try makeApp();
    defer app.deinit();

    _ = try app.root().addSubcommand(.{ .name = "commit", .description = "commit changes" });
    try testing.expectError(error.UnknownCommand, app.parseFrom(&.{"comit"}));
}

test "options requiring value accept dash-prefixed values" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(i64, .{ .name = "count" });
    const ctx = try app.parseFrom(&.{ "--count", "-1" });
    try testing.expectEqual(@as(i64, -1), ctx.intFlag("count").?);
}

test "bundle with attached value on bool flags errors" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(bool, .{ .name = "a", .short = 'a' });
    try app.root().addFlag(bool, .{ .name = "b", .short = 'b' });
    try testing.expectError(error.UnexpectedValueForBool, app.parseFrom(&.{"-ab=foo"}));
}

test "doc generator writes single asciidoc file by default" {
    var app = try makeApp();
    defer app.deinit();
    const io = testing.io;

    const root = app.root();
    try root.addFlag(bool, .{
        .name = "verbose",
        .short = 'v',
        .persistent = true,
        .description = "Verbose output",
    });
    const commit = try root.addSubcommand(.{
        .name = "commit",
        .description = "Record changes",
    });
    try commit.addFlag([]const u8, .{
        .name = "message",
        .short = 'm',
        .required = true,
        .description = "Commit message",
    });

    const out_dir = "zig-out/docgen-single";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, root, .{
        .output_dir = out_dir,
    });

    const path = out_dir ++ "/cli.adoc";
    const content = try readFileAlloc(io, testing.allocator, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "= fangz") != null);
    try testing.expect(std.mem.indexOf(u8, content, "== Command Index") == null);
    try testing.expect(std.mem.indexOf(u8, content, "[#cmd-fangz-commit]") != null);
    try testing.expect(std.mem.indexOf(u8, content, "--message <STRING>") != null);
}

test "doc generator renders nested commands as flat reference entries" {
    var app = try makeApp();
    defer app.deinit();
    const io = testing.io;

    const root = app.root();
    const remote = try root.addSubcommand(.{
        .name = "remote",
        .description = "Manage remotes",
    });
    _ = try remote.addSubcommand(.{
        .name = "add",
        .description = "Add a remote",
    });

    const out_dir = "zig-out/docgen-tree";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, root, .{
        .output_dir = out_dir,
    });

    const doc = try readFileAlloc(io, testing.allocator, out_dir ++ "/cli.adoc");
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "[#cmd-fangz]") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "[#cmd-fangz-remote]") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "[#cmd-fangz-remote-add]") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "=== `fangz remote add`") != null);
}

test "app docs include configured author and revision metadata" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{
        .display_name = "Git",
        .tagline = "Distributed Version Control",
        .description = "test app",
        .version = "1.2.3",
        .author_name = "Ada Lovelace",
        .author_email = "ada@example.com",
        .commit = "abc1234",
        .branch = "main",
        .source_date = "2026-05-01",
    });
    defer app.deinit();

    const out_dir = "zig-out/docgen-meta";
    std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};

    try app.generateDocs(.{
        .output_dir = out_dir,
    });

    const doc = try readFileAlloc(testing.io, testing.allocator, out_dir ++ "/cli.adoc");
    defer testing.allocator.free(doc);

    try testing.expect(std.mem.indexOf(u8, doc, "= Git: Distributed Version Control") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "Ada Lovelace <ada@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "v1.2.3, 2026-05-01: main (abc1234)") != null);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}
