//! Representative CLI tree for help, parse, and docgen behavior (no consumer-specific wiring).

const std = @import("std");
const testing = std.testing;
const fangz = @import("fangz");
const fixture = @import("fixture");

const OutputMode = enum { pretty, text, minimal, json };

const FailFast = enum { none, @"error", warn, any };

test "fixture accepts representative command workflows" {
    const workflows = [_][]const []const u8{
        &.{},
        &.{
            "project",  "init",            "example",    "--config", "forge.toml", "--label",  "ci",
            "--define", "FEATURE=enabled", "--template", "service",  "--no-git",   "--module", "api",
            "--module", "web",
        },
        &.{ "projects", "inspect", "example", "--output", "yaml", "--resolved" },
        &.{ "project", "list", "--tag", "internal", "--tag", "zig", "--limit", "3" },
        &.{
            "release",       "staging",   "api.tar",    "worker.tar",         "--strategy", "canary",
            "--parallelism", "2",         "--timeout",  "1.5",                "--region",   "us-east",
            "--no-wait",     "--dry-run", "--variable", "telemetry=disabled", "--variable", "feature=enabled",
        },
        &.{ "publish", "release.toml", "--token", "test-token", "--no-signed" },
        &.{ "logs", "api", "--level", "warn", "--tail", "20", "--follow", "--since", "2026-08-19T00:00:00Z" },
        &.{ "run", "test", "--offline", "--", "--filter", "slow" },
        &.{ "cfg", "set", "output", "json" },
    };

    for (workflows) |argv| {
        var app: fangz.App = undefined;
        try initializeFixtureApp(&app);
        defer app.deinit();
        _ = try app.parseFrom(argv);
    }
}

test "nested subcommand appears in full help" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "project") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Create, inspect, and list projects") != null);
    try testing.expect(std.mem.indexOf(u8, text, "archive") == null);
}

test "short help omits flags that are not registered" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "<RULE=LEVEL>") == null);
    try testing.expect(std.mem.indexOf(u8, text, "--rule") == null);
    try testing.expect(std.mem.indexOf(u8, text, "--all") == null);
}

test "full help documents optional path flag" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "--config") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PATH") != null);
}

test "parse errors on unknown flag" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "alpha=deny" };
    try testing.expectError(error.UnknownFlag, fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv));
}

test "generated AsciiDoc synopsis omits key-value metavar when flag absent" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root_command.freeze();

    const out_dir = "zig-out/fangz-cliux-docgen";
    std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, out_dir) catch {};

    try fangz.DocGenerator.generateDocs(testing.allocator, testing.io, app.root(), .{
        .output_dir = out_dir,
    });

    const path = try std.fs.path.join(testing.allocator, &.{ out_dir, "fangz.adoc" });
    defer testing.allocator.free(path);

    const content = try readFileAlloc(testing.io, testing.allocator, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "== Synopsis") != null);
    try testing.expect(std.mem.indexOf(u8, content, "RULE=LEVEL") == null);
    try testing.expect(std.mem.indexOf(u8, content, "== Command Index") == null);
}

test "help metadata uses distinct variadic and repeatable markers" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root().addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze.",
        .variadic = true,
    });

    try app.root().addFlag(bool, .{
        .name = "bins",
        .brief = "Analyze all binary targets",
        .default = false,
    });

    try app.root().addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name",
        .value_hint = "STRING",
        .multi = true,
    });

    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "<paths>*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Accepts multiple values") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--bin <STRING>...") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Repeatable") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[variadic]") == null);
    try testing.expect(std.mem.indexOf(u8, text, "[default:") == null);
}

test "short help omits metadata annotations" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root().addPositional(.{
        .name = "paths",
        .brief = "Files or directories to analyze.",
        .variadic = true,
    });

    try app.root().addFlag([]const []const u8, .{
        .name = "bin",
        .brief = "Analyze specific binary by name",
        .value_hint = "STRING",
        .multi = true,
    });

    try app.root().addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "Accepts multiple values") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Repeatable") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Allowed") == null);
    try testing.expect(std.mem.indexOf(u8, text, "(default)") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Default:") == null);
    try testing.expect(std.mem.indexOf(u8, text, "<paths>*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--bin") != null);
}

test "help enum defaults are marked on allowed values" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    try app.root().addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try app.root().addFlag(FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = .none,
    });

    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "Allowed:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pretty (default)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[possible:") == null);
    try testing.expect(std.mem.indexOf(u8, text, "none (default)") != null);
}

test "full help wraps prose without breaking urls" {
    var app: fangz.App = undefined;
    try initializeFixtureApp(&app);
    defer app.deinit();

    const docs = try app.root().addSubcommand(.{
        .name = "docs",
        .brief = "Open documentation",
        .description = "Read the guide at https://example.com/docs/guide before editing ./config/app.toml.",
    });
    try docs.addFlag(bool, .{
        .name = "verbose",
        .brief = "Verbose output",
    });
    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, docs, .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "https://example.com/docs/guide") != null);
    try testing.expect(std.mem.indexOf(u8, text, "./config/app.toml") != null);
    try testing.expect(std.mem.indexOf(u8, text, "https://example.com/docs/\n") == null);
}

fn initializeFixtureApp(app: *fangz.App) !void {
    try fixture.initialize(app, testing.allocator, testing.io);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
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

test "extract reads a required string flag" {
    var app = try makeApp();
    defer app.deinit();

    try app.root().addFlag([]const u8, .{
        .name = "token",
        .required = true,
    });

    const ctx = try app.parseFrom(&.{ "--token", "secret" });
    const args = try ctx.extract(struct {
        token: []const u8,
    });
    try testing.expectEqualStrings("secret", args.token);
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

test "mutually exclusive flags ignore default values" {
    var app = try makeApp();
    defer app.deinit();

    const root = app.root();
    try root.addFlag(bool, .{ .name = "dry-run", .default = false });
    try root.addFlag(bool, .{ .name = "force", .default = false });
    try root.addMutuallyExclusive(.{ .names = &.{ "dry-run", "force" } });

    const ctx = try app.parseFrom(&.{"--dry-run"});
    try testing.expect(ctx.wasFlagProvided("dry-run"));
    try testing.expect(!ctx.wasFlagProvided("force"));
    try testing.expect(!ctx.boolFlag("force").?);
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

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .brief = "test app",
        .version = "1.2.3",
    });
}
