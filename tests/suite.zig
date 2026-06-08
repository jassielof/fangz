const std = @import("std");
const testing = std.testing;

const fangz = @import("fangz");

comptime {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("cli_ux.zig"));
}

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .brief = "test app",
        .version = "1.2.3",
    });
}

test "dispatches nested subcommands with aliases" {
    var app = try makeApp();
    defer app.deinit();

    const remote = try app.root().addSubcommand(.{ .name = "remote", .brief = "remote ops" });
    const add = try remote.addSubcommand(.{ .name = "add", .brief = "add remote" });
    try add.addAlias("a");

    const ctx = try app.parseFrom(&.{ "remote", "a" });
    try testing.expectEqualStrings("add", ctx.command.name);
}

test "help on empty args applies to selected subcommand" {
    var app = try makeApp();
    defer app.deinit();

    const info = try app.root().addSubcommand(.{ .name = "info", .brief = "show info" });
    info.setHelpOnEmptyArgs(true);

    const ctx = try app.parseFrom(&.{"info"});
    try testing.expectEqualStrings("info", ctx.command.name);
    try testing.expect(ctx.help_requested);
}

test "help subcommand requests root help" {
    var app = try makeApp();
    defer app.deinit();

    _ = try app.root().addSubcommand(.{ .name = "status", .brief = "show status" });

    const ctx = try app.parseFrom(&.{"help"});
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("fangz", ctx.command.name);
}

test "help subcommand requests nested command help" {
    var app = try makeApp();
    defer app.deinit();

    const remote = try app.root().addSubcommand(.{ .name = "remote", .brief = "remote ops" });
    _ = try remote.addSubcommand(.{ .name = "add", .brief = "add remote" });

    const ctx = try app.parseFrom(&.{ "help", "remote", "add" });
    try testing.expect(ctx.help_requested);
    try testing.expectEqualStrings("add", ctx.command.name);
}

test "duplicate short flag errors with DuplicateShortFlag" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(bool, .{ .name = "verbose", .short = 'v' });
    try testing.expectError(error.DuplicateShortFlag, root.addFlag(bool, .{ .name = "version", .short = 'v' }));

    const prior = root.resolveLocalFlagByShort('v').?;
    try testing.expectEqual(@as(usize, 0), prior.index);
    try testing.expectEqualStrings("verbose", prior.command.flags.constSlice()[prior.index].name);
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
        .brief = "Output format",
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

    _ = try app.root().addSubcommand(.{ .name = "status", .brief = "show status" });

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
    _ = try app.root().addSubcommand(.{ .name = "status", .brief = "status" });

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

    _ = try app.root().addSubcommand(.{ .name = "commit", .brief = "commit changes" });
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
        .brief = "Verbose output",
    });
    const commit = try root.addSubcommand(.{
        .name = "commit",
        .brief = "Record changes",
    });
    try commit.addFlag([]const u8, .{
        .name = "message",
        .short = 'm',
        .required = true,
        .brief = "Commit message",
    });

    const out_dir = "zig-out/docgen-single";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, root, .{
        .output_dir = out_dir,
    });

    const path = out_dir ++ "/fangz.adoc";
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
        .brief = "Manage remotes",
    });
    _ = try remote.addSubcommand(.{
        .name = "add",
        .brief = "Add a remote",
    });

    const out_dir = "zig-out/docgen-tree";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, root, .{
        .output_dir = out_dir,
    });

    const doc = try readFileAlloc(io, testing.allocator, out_dir ++ "/fangz.adoc");
    defer testing.allocator.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "[#cmd-fangz-remote]") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "[#cmd-fangz-remote-add]") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "=== `fangz remote add`") != null);
}

test "doc generator renders examples as captioned asciidoc example blocks" {
    var app = try makeApp();
    defer app.deinit();
    const io = testing.io;

    app.root().examples = &.{
        .{ .description = "Show help", .command = "fangz --help" },
    };

    const out_dir = "zig-out/docgen-examples";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, app.root(), .{
        .output_dir = out_dir,
    });

    const doc_raw = try readFileAlloc(io, testing.allocator, out_dir ++ "/fangz.adoc");
    defer testing.allocator.free(doc_raw);
    const doc = try std.mem.replaceOwned(u8, testing.allocator, doc_raw, "\r\n", "\n");
    defer testing.allocator.free(doc);

    try testing.expect(std.mem.indexOf(u8, doc, "== Examples") == null);
    try testing.expect(std.mem.indexOf(u8, doc, ".Show help\n====\n[source,sh]\n----\nfangz --help\n----\n====") != null);
}

test "doc generator emits custom example content without an examples section heading" {
    var app = try makeApp();
    defer app.deinit();
    const io = testing.io;

    try app.root().addFlag(bool, .{
        .name = "verbose",
        .brief = "Verbose output",
        .examples = &.{
            .{
                .description = "Enable verbose mode",
                .content =
                \\NOTE: This is prose, not a shell command.
                \\+
                \\[source,sh]
                \\----
                \\fangz --verbose
                \\----
                ,
            },
        },
    });
    try app.root_command.freeze();

    const out_dir = "zig-out/docgen-example-content";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, app.root(), .{
        .output_dir = out_dir,
    });

    const doc_raw = try readFileAlloc(io, testing.allocator, out_dir ++ "/fangz.adoc");
    defer testing.allocator.free(doc_raw);
    const doc = try std.mem.replaceOwned(u8, testing.allocator, doc_raw, "\r\n", "\n");
    defer testing.allocator.free(doc);

    try testing.expect(std.mem.indexOf(u8, doc, "==== Examples") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "====== Examples") == null);
    try testing.expect(std.mem.indexOf(u8, doc, ".Enable verbose mode\n====\nNOTE: This is prose, not a shell command.") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "fangz --verbose") != null);
}

test "doc generator uses valid asciidoc section levels and root xref anchor" {
    var app = try makeApp();
    defer app.deinit();
    const io = testing.io;

    const root = app.root();
    _ = try root.addSubcommand(.{
        .name = "run",
        .brief = "Run the app",
    });
    try root.addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .short = 'r',
        .allowed_keys = &.{ "alpha" },
        .allowed_values = &.{ "allow", "deny" },
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
    });

    const out_dir = "zig-out/docgen-asciidoc";
    std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, io, root, .{
        .output_dir = out_dir,
    });

    const doc = try readFileAlloc(io, testing.allocator, out_dir ++ "/fangz.adoc");
    defer testing.allocator.free(doc);

    const root_anchor = std.mem.indexOf(u8, doc, "[#cmd-fangz]") orelse return error.TestUnexpectedResult;
    const synopsis = std.mem.indexOf(u8, doc, "== Synopsis") orelse return error.TestUnexpectedResult;
    try testing.expect(root_anchor < synopsis);
    try testing.expect(std.mem.indexOf(u8, doc, "===== Options") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "==== Options") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "xref:cmd-fangz[`fangz`]") != null);
}

test "app docs include configured author and revision metadata" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{
        .display_name = "Git",
        .tagline = "Distributed Version Control",
        .brief = "test app",
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

    const doc = try readFileAlloc(testing.io, testing.allocator, out_dir ++ "/fangz.adoc");
    defer testing.allocator.free(doc);

    try testing.expect(std.mem.indexOf(u8, doc, "= Git: Distributed Version Control") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "Ada Lovelace <ada@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "v1.2.3, 2026-05-01: main (abc1234)") != null);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

test "key-value list flag parses repeated pairs" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .short = 'r',
        .allowed_keys = &.{ "alpha", "beta" },
        .allowed_values = &.{ "allow", "deny" },
    });
    try app.root_command.freeze();

    var out = try fangz.Parser.parse(testing.allocator, testing.io, app.root(), &.{
        "--rule", "alpha=allow",
        "-r",     "beta=deny",
    });
    defer out.context.deinit();

    const pairs = out.context.keyValueFlag("rule").?;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("alpha", pairs[0].key);
    try testing.expectEqualStrings("allow", pairs[0].value);
    try testing.expectEqualStrings("beta", pairs[1].key);
    try testing.expectEqualStrings("deny", pairs[1].value);
}

test "key-value flag diagnostic when equals is missing" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .allowed_keys = &.{ "alpha", "beta" },
        .allowed_values = &.{ "allow", "deny" },
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
    });
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "onlykey" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.KeyValueMissingEquals => error.KeyValueMissingEquals,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid format") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "RULE=LEVEL") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "onlykey") != null);
        return;
    };
    return error.TestExpectedError;
}

test "key-value flag diagnostic for unknown key includes suggestion" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .allowed_keys = &.{ "alpha", "beta" },
        .allowed_values = &.{ "allow", "deny" },
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
    });
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "alph=allow" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.InvalidAllowedKey => error.InvalidAllowedKey,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid rule") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "alph") != null);
        try testing.expect(diag.hint != null);
        try testing.expect(std.mem.indexOf(u8, diag.hint.?, "alpha") != null);
        return;
    };
    return error.TestExpectedError;
}

test "key-value flag diagnostic for unknown value lists allowed levels" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .allowed_keys = &.{ "alpha", "beta" },
        .allowed_values = &.{ "allow", "deny" },
        .key_metavar = "RULE",
        .value_metavar = "LEVEL",
    });
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "alpha=nope" };
    _ = fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv) catch |err| {
        const pe: fangz.Parser.ParseError = switch (err) {
            error.InvalidAllowedValue => error.InvalidAllowedValue,
            else => return err,
        };
        var diag = try fangz.Parser.diagnoseError(testing.allocator, app.root(), argv, pe);
        defer diag.deinit();
        try testing.expect(std.mem.indexOf(u8, diag.message, "invalid level") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "nope") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "allow") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "deny") != null);
        return;
    };
    return error.TestExpectedError;
}

test "generateDocs refuses existing output when overwrite is false" {
    var app = try makeApp();
    defer app.deinit();

    const out_dir = "zig-out/fangz-docgen-overwrite-test";
    std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, testing.io, app.root(), .{
        .output_dir = out_dir,
        .output_file_name = "cli.adoc",
    });

    const second = fangz.DocGenerator.generateDocs(testing.allocator, testing.io, app.root(), .{
        .output_dir = out_dir,
        .output_file_name = "cli.adoc",
        .overwrite = false,
    });

    try testing.expectError(error.PathAlreadyExists, second);
}
