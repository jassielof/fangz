const std = @import("std");
const fangz = @import("fangz");

const testing = std.testing;

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, .{
        .name = "git",
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
    try testing.expectEqualStrings("git", ctx.command.name);
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
    try root.addFlag(.{ .name = "l", .short = 'l', .value_type = .bool });
    try root.addFlag(.{ .name = "a", .short = 'a', .value_type = .bool });
    try root.addFlag(.{ .name = "header", .short = 'H', .value_type = .string });

    const ctx = try app.parseFrom(&.{ "-laH", "token" });
    try testing.expect(ctx.boolFlag("l").?);
    try testing.expect(ctx.boolFlag("a").?);
    try testing.expectEqualStrings("token", ctx.stringFlag("header").?);
}

test "typed flags include defaults and required validation" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(.{ .name = "count", .short = 'c', .value_type = .int, .required = true });
    try root.addFlag(.{ .name = "ratio", .value_type = .float, .default_value = .{ .float = 2.5 } });
    try root.addFlag(.{
        .name = "format",
        .value_type = .string,
        .allowed_values = &.{ "json", "table" },
        .default_value = .{ .string = "json" },
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

    try app.root().addEnumFlag(Output, .{
        .name = "output",
        .short = 'o',
        .description = "Output format",
        .default_value = .json,
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

    try app.root().addEnumFlag(Output, .{ .name = "output" });
    try testing.expectError(error.InvalidEnumValue, app.parseFrom(&.{ "--output", "yaml" }));
}

test "completion command with no args requests help" {
    var app = try makeApp();
    defer app.deinit();

    const ctx = try app.parseFrom(&.{"completion"});
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("completion", ctx.command.name);
}

test "repeatable string list flag accumulates values" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(.{ .name = "header", .short = 'H', .value_type = .string_list });
    const ctx = try app.parseFrom(&.{ "--header", "A:B", "-H", "C:D" });
    const values = ctx.stringListFlag("header").?;
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("A:B", values[0]);
    try testing.expectEqualStrings("C:D", values[1]);
}

test "global persistent flag propagates to subcommands" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(.{
        .name = "verbose",
        .short = 'v',
        .value_type = .bool,
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

    try app.root().addFlag(.{ .name = "json", .value_type = .bool });
    try app.root().addFlag(.{ .name = "yaml", .value_type = .bool });
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

    try app.root().addFlag(.{ .name = "count", .value_type = .int });
    const ctx = try app.parseFrom(&.{ "--count", "-1" });
    try testing.expectEqual(@as(i64, -1), ctx.intFlag("count").?);
}

test "bundle with attached value on bool flags errors" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag(.{ .name = "a", .short = 'a', .value_type = .bool });
    try app.root().addFlag(.{ .name = "b", .short = 'b', .value_type = .bool });
    try testing.expectError(error.UnexpectedValueForBool, app.parseFrom(&.{"-ab=foo"}));
}

test "doc generator writes single markdown file by default" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(.{
        .name = "verbose",
        .short = 'v',
        .value_type = .bool,
        .persistent = true,
        .description = "Verbose output",
    });
    const commit = try root.addSubcommand(.{
        .name = "commit",
        .description = "Record changes",
    });
    try commit.addFlag(.{
        .name = "message",
        .short = 'm',
        .value_type = .string,
        .required = true,
        .description = "Commit message",
    });

    const out_dir = "zig-out/docgen-single";
    std.fs.cwd().deleteTree(out_dir) catch {};
    defer std.fs.cwd().deleteTree(out_dir) catch {};

    try app.generateMarkdownDocs(.{
        .mode = .single_file,
        .output_dir = out_dir,
    });

    const path = out_dir ++ "/cli.md";
    const content = try readFileAlloc(testing.allocator, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "# `git`") != null);
    try testing.expect(std.mem.indexOf(u8, content, "## Commands") != null);
    try testing.expect(std.mem.indexOf(u8, content, "`commit`") != null);
    try testing.expect(std.mem.indexOf(u8, content, "--message <STRING>") != null);
}

test "doc generator writes one file per command" {
    var app = try makeApp();
    defer app.deinit();

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
    std.fs.cwd().deleteTree(out_dir) catch {};
    defer std.fs.cwd().deleteTree(out_dir) catch {};

    try app.generateMarkdownDocs(.{
        .mode = .per_command,
        .output_dir = out_dir,
    });

    const root_doc = try readFileAlloc(testing.allocator, out_dir ++ "/index.md");
    defer testing.allocator.free(root_doc);
    try testing.expect(std.mem.indexOf(u8, root_doc, "[`remote`](remote/index.md)") != null);

    const remote_doc = try readFileAlloc(testing.allocator, out_dir ++ "/remote/index.md");
    defer testing.allocator.free(remote_doc);
    try testing.expect(std.mem.indexOf(u8, remote_doc, "# `git remote`") != null);
    try testing.expect(std.mem.indexOf(u8, remote_doc, "[`add`](add/index.md)") != null);

    const add_doc = try readFileAlloc(testing.allocator, out_dir ++ "/remote/add/index.md");
    defer testing.allocator.free(add_doc);
    try testing.expect(std.mem.indexOf(u8, add_doc, "# `git remote add`") != null);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return file.readToEndAlloc(allocator, stat.size + 64);
}
