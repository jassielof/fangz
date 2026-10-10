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

test "help starts with the brief instead of repeating the command path" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "Root brief." });
    defer app.deinit();

    const sync = try app.root().addSubcommand(.{ .name = "sync", .brief = "Sync things." });
    const quiet = try app.root().addSubcommand(.{ .name = "quiet" });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;

    var root_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&root_writer, app.root(), .none, .short);
    try testing.expect(std.mem.startsWith(u8, root_writer.buffered(), "Root brief.\n"));

    var sync_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&sync_writer, sync, .none, .full);
    try testing.expect(std.mem.startsWith(u8, sync_writer.buffered(), "Sync things.\n"));
    try testing.expect(std.mem.indexOf(u8, sync_writer.buffered(), "Usage: ") != null);

    // Without a brief there is nothing to lead with, and no stray blank line either.
    var quiet_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&quiet_writer, quiet, .none, .short);
    try testing.expect(std.mem.startsWith(u8, quiet_writer.buffered(), "Usage: "));
}

const long_brief = "Build a package from its manifest so it can be published or installed, validating the name, the version, and the declared compiler requirement first.";

/// Finds the row starting with `row_prefix`, then checks every wrapped line after it hangs exactly two columns to the right of where the description starts, and stays within `max_width`.
fn expectHangingRow(help: []const u8, row_prefix: []const u8, description_start: []const u8, max_width: usize) !void {
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |row| {
        if (!std.mem.startsWith(u8, row, row_prefix)) continue;

        const column = std.mem.indexOf(u8, row, description_start).?;
        var wrapped_lines: usize = 0;
        while (lines.next()) |line| : (wrapped_lines += 1) {
            if (line.len == 0 or line[0] != ' ' or line.len <= column) break;
            if (std.mem.indexOfNone(u8, line[0 .. column + 2], " ") != null) break;

            try testing.expect(line[column + 2] != ' ');
            try testing.expect(line.len <= max_width);
        }

        try testing.expect(wrapped_lines >= 1);
        return;
    }

    return error.RowNotFound;
}

test "wrapped command descriptions hang two columns past the description column" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "test app" });
    defer app.deinit();

    _ = try app.root().addSubcommand(.{ .name = "a", .brief = "Short." });
    _ = try app.root().addSubcommand(.{ .name = "bundle", .brief = long_brief });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);

    try expectHangingRow(writer.buffered(), "  bundle ", "Build", 80);
    // A one-line entry next to a wrapped one gets no continuation.
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "  a       Short.\n") != null);
}

test "wrapped option descriptions hang two columns past the description column" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "test app" });
    defer app.deinit();

    const sub = try app.root().addSubcommand(.{ .name = "run" });
    try sub.addFlag([]const u8, .{ .name = "output-dir", .brief = long_brief });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, sub, .none, .short);

    try expectHangingRow(writer.buffered(), "  --output-dir", "Build", 80);
}

test "a positional's default is listed like a flag's" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "test app" });
    defer app.deinit();

    const open = try app.root().addSubcommand(.{ .name = "open" });
    try open.addPositional(.{
        .name = "target",
        .brief = "What to open.",
        .default_hint = "the current directory",
        .allowed_values = &.{ "file", "dir" },
    });
    try open.addPositional(.{ .name = "extra", .brief = "Nothing special." });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;

    var full_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&full_writer, open, .none, .full);
    const full = full_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, full, "Default: the current directory\n") != null);
    // Only the positional that has a default gets the line.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, full, "Default: "));

    // Short help stays compact, like it does for flags.
    var short_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&short_writer, open, .none, .short);
    try testing.expect(std.mem.indexOf(u8, short_writer.buffered(), "Default:") == null);
}

test "the parent command list shows each subcommand's aliases" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "test app" });
    defer app.deinit();

    const bundle = try app.root().addSubcommand(.{ .name = "bundle", .brief = "Build it." });
    try bundle.addAlias("build");
    try bundle.addAlias("pack");
    const sync = try app.root().addSubcommand(.{ .name = "sync", .brief = "Sync it." });
    try sync.addAlias("pull");
    const bare = try app.root().addSubcommand(.{ .name = "bare" });
    try bare.addAlias("naked");
    _ = try app.root().addSubcommand(.{ .name = "plain", .brief = "No aliases." });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "Build it. (aliases: build, pack)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Sync it. (alias: pull)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(alias: naked)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No aliases.\n") != null);
}

/// Whether the styling applied to `note` in `text` includes italics (SGR code 3). A style may be emitted as several adjacent escape sequences, so this looks at the whole run of them directly before the text.
fn isItalicBefore(text: []const u8, note: []const u8) !bool {
    var end = std.mem.indexOf(u8, text, note) orelse return error.NoteNotFound;

    while (end > 0 and text[end - 1] == 'm') {
        const escape = std.mem.lastIndexOf(u8, text[0..end], "\x1b[") orelse return false;
        const codes_text = text[escape + 2 .. end - 1];
        if (std.mem.indexOfNone(u8, codes_text, "0123456789;") != null) return false;

        var codes = std.mem.splitScalar(u8, codes_text, ';');
        while (codes.next()) |code| {
            if (std.mem.eql(u8, code, "3")) return true;
        }
        end = escape;
    }
    return false;
}

test "alias notes are set in italics when the terminal can style them" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{ .brief = "test app" });
    defer app.deinit();

    const bundle = try app.root().addSubcommand(.{ .name = "bundle", .brief = "Build it." });
    try bundle.addAlias("build");
    try bundle.addAlias("pack");
    const pick = try app.root().addSubcommand(.{ .name = "pick" });
    try pick.addPositional(.{
        .name = "shell",
        .brief = "Which shell.",
        .allowed_values = &.{ "powershell", "bash" },
        .allowed_value_aliases = &.{.{ .name = "pwsh", .of = "powershell" }},
        .allowed_values_style = .bullet_list,
    });
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;

    // The parent's command list.
    var list_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&list_writer, app.root(), .ansi16, .short);
    try testing.expect(try isItalicBefore(list_writer.buffered(), "(aliases: build, pack)"));

    // An allowed-value row.
    var value_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&value_writer, pick, .ansi16, .full);
    try testing.expect(try isItalicBefore(value_writer.buffered(), "(alias: pwsh)"));

    // The Aliases section of the command's own help.
    var section_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&section_writer, bundle, .ansi16, .short);
    const section = section_writer.buffered();
    const after_heading = section[std.mem.indexOf(u8, section, "Aliases:").?..];
    try testing.expect(try isItalicBefore(after_heading, "build"));
    try testing.expect(try isItalicBefore(after_heading, "pack"));

    // Without styling the same notes are plain text.
    var plain_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&plain_writer, pick, .none, .full);
    try testing.expect(std.mem.indexOf(u8, plain_writer.buffered(), "powershell  Which") == null);
    try testing.expect(std.mem.indexOf(u8, plain_writer.buffered(), "powershell (alias: pwsh)") != null);
    try testing.expect(std.mem.indexOf(u8, plain_writer.buffered(), "\x1b[") == null);
}

test "help renders AsciiDoc inline markup when the terminal can style it" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{
        .brief = "Copies into `<dir>` and keeps Print`help and Print_text as they are.",
    });
    defer app.deinit();
    try app.root_command.freeze();

    var buf: [8192]u8 = undefined;

    var styled_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&styled_writer, app.root(), .ansi16, .short);
    const styled = styled_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, styled, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, styled, "`<dir>`") == null);
    try testing.expect(std.mem.indexOf(u8, styled, "<dir>") != null);
    // Marks that do not form a span are ordinary text, not an error.
    try testing.expect(std.mem.indexOf(u8, styled, "Print`help") != null);
    try testing.expect(std.mem.indexOf(u8, styled, "Print_text") != null);

    var plain_writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&plain_writer, app.root(), .none, .short);
    const plain = plain_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "`<dir>`") != null);
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
fn initEnvApp(app: *fangz.App) !void {
    app.* = try fangz.App.init(testing.allocator, testing.io, .{
        .display_name = "Env Demo",
        .env_prefix = "demo",
    });
    app.setCompletionsEnabled(false);
    app.setDocsEnabled(false);
}

test "environment fills flags that argv leaves unset" {
    var app: fangz.App = undefined;
    try initEnvApp(&app);
    defer app.deinit();

    try app.root().addFlag([]const u8, .{ .name = "config-path", .env = .derived });
    try app.root().addFlag(i64, .{ .name = "jobs", .env = .{ .name = "BUILD_JOBS" } });
    try app.root().addFlag(bool, .{ .name = "verbose", .env = .derived });
    try app.root().addFlag([]const []const u8, .{ .name = "tag", .env = .derived, .multi = true });

    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("DEMO_CONFIG_PATH", "from-env.toml");
    try environ.put("BUILD_JOBS", "8");
    try environ.put("DEMO_VERBOSE", "Yes");
    try environ.put("DEMO_TAG", "a,b,,c");
    app.setEnvironment(&environ);

    const ctx = try app.parseFrom(&.{});
    try testing.expectEqualStrings("from-env.toml", ctx.stringFlag("config-path").?);
    try testing.expectEqual(@as(i64, 8), ctx.intFlag("jobs").?);
    try testing.expectEqual(true, ctx.boolFlag("verbose").?);
    try testing.expectEqual(@as(usize, 3), ctx.stringListFlag("tag").?.len);
    try testing.expect(!ctx.wasFlagProvided("config-path"));
}

test "argv wins over the environment and the environment wins over defaults" {
    var app: fangz.App = undefined;
    try initEnvApp(&app);
    defer app.deinit();

    try app.root().addFlag([]const u8, .{ .name = "mode", .env = .derived, .default = "debug" });
    try app.root().addFlag([]const u8, .{ .name = "color", .env = .derived, .default = "auto" });
    try app.root().addFlag([]const u8, .{ .name = "shell", .env = .derived, .default = "sh" });

    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("DEMO_MODE", "release");
    try environ.put("DEMO_COLOR", "never");
    app.setEnvironment(&environ);

    const ctx = try app.parseFrom(&.{ "--mode", "fast" });
    try testing.expectEqualStrings("fast", ctx.stringFlag("mode").?);
    try testing.expectEqualStrings("never", ctx.stringFlag("color").?);
    try testing.expectEqualStrings("sh", ctx.stringFlag("shell").?);
}

test "environment satisfies required flags and an empty value counts as unset" {
    var app: fangz.App = undefined;
    try initEnvApp(&app);
    defer app.deinit();

    try app.root().addFlag([]const u8, .{ .name = "token", .env = .derived, .required = true });

    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    app.setEnvironment(&environ);

    try testing.expectError(error.MissingRequiredFlag, app.parseFrom(&.{}));

    try environ.put("DEMO_TOKEN", "");
    try testing.expectError(error.MissingRequiredFlag, app.parseFrom(&.{}));

    try environ.put("DEMO_TOKEN", "secret");
    const ctx = try app.parseFrom(&.{});
    try testing.expectEqualStrings("secret", ctx.stringFlag("token").?);
}

test "invalid environment values are rejected like argv values" {
    var app: fangz.App = undefined;
    try initEnvApp(&app);
    defer app.deinit();

    try app.root().addFlag(i64, .{ .name = "jobs", .env = .derived });
    try app.root().addFlag(bool, .{ .name = "quiet", .env = .derived });

    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    app.setEnvironment(&environ);

    try environ.put("DEMO_JOBS", "many");
    try testing.expectError(error.InvalidInt, app.parseFrom(&.{}));

    try environ.put("DEMO_JOBS", "2");
    try environ.put("DEMO_QUIET", "maybe");
    try testing.expectError(error.InvalidBool, app.parseFrom(&.{}));
}

test "flags without env ignore the environment and help names the variable" {
    var app: fangz.App = undefined;
    try initEnvApp(&app);
    defer app.deinit();

    try app.root().addFlag([]const u8, .{ .name = "plain" });
    try app.root().addFlag([]const u8, .{ .name = "out-dir", .env = .derived });

    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("DEMO_PLAIN", "ignored");
    app.setEnvironment(&environ);

    const ctx = try app.parseFrom(&.{});
    try testing.expect(ctx.stringFlag("plain") == null);

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Env: DEMO_OUT_DIR") != null);
}

test "help separates built-ins from grouped application commands in both modes" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{});
    defer app.deinit();
    try app.root().addGroup(.{ .id = "fonts", .title = "Fonts" });
    _ = try app.root().addSubcommand(.{ .name = "list", .brief = "List fonts.", .group_id = "fonts" });
    _ = try app.root().addSubcommand(.{ .name = "backup", .brief = "Copy fonts." });
    _ = try app.parseFrom(&.{"--help"});

    for ([_]fangz.HelpRenderer.HelpMode{ .short, .full }) |mode| {
        var buf: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try fangz.HelpRenderer.render(&writer, app.root(), .none, mode);
        const text = writer.buffered();
        const boundary = std.mem.indexOf(u8, text, "\nBuilt-in commands:\n") orelse return error.MissingBuiltins;
        const commands = text[0..boundary];
        const builtins = text[boundary..];
        try testing.expect(std.mem.indexOf(u8, commands, "\nCommands:\n  Fonts:\n") != null);
        try testing.expect(std.mem.indexOf(u8, commands, "List fonts.") != null);
        try testing.expect(std.mem.indexOf(u8, commands, "Copy fonts.") != null);
        try testing.expect(std.mem.indexOf(u8, commands, "completion") == null);
        try testing.expect(std.mem.indexOf(u8, commands, "docs") == null);
        try testing.expect(std.mem.indexOf(u8, builtins, "completion") != null);
        try testing.expect(std.mem.indexOf(u8, builtins, "(alias: completions)") != null);
        try testing.expect(std.mem.indexOf(u8, builtins, "docs") != null);
        try testing.expect(std.mem.indexOf(u8, builtins, "Print this message") != null);
    }
}

test "application docs and completion overrides are not labeled built-in" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{});
    defer app.deinit();
    _ = try app.root().addSubcommand(.{ .name = "docs", .brief = "Application documents." });
    _ = try app.root().addSubcommand(.{ .name = "completion", .brief = "Application completion." });
    _ = try app.parseFrom(&.{"--help"});
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();
    const boundary = std.mem.indexOf(u8, text, "\nBuilt-in commands:\n") orelse return error.MissingBuiltins;
    try testing.expect(std.mem.indexOf(u8, text[0..boundary], "Application documents.") != null);
    try testing.expect(std.mem.indexOf(u8, text[0..boundary], "Application completion.") != null);
    try testing.expect(std.mem.indexOf(u8, text[boundary..], "Application") == null);
}

test "help with only built-ins omits an empty application section" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{});
    defer app.deinit();
    _ = try app.parseFrom(&.{"--help"});
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .short);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\nCommands:\n") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\nBuilt-in commands:\n") != null);
}

test "disabled utilities stay absent while nested help remains built-in" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{});
    defer app.deinit();
    app.setDocsEnabled(false);
    app.setCompletionsEnabled(false);
    const fonts = try app.root().addSubcommand(.{ .name = "fonts" });
    _ = try fonts.addSubcommand(.{ .name = "list", .brief = "List fonts." });
    _ = try app.parseFrom(&.{"--help"});
    for ([_]*const fangz.Command{ app.root(), fonts }) |command| {
        var buf: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try fangz.HelpRenderer.render(&writer, command, .none, .full);
        const text = writer.buffered();
        try testing.expect(std.mem.indexOf(u8, text, "\nBuilt-in commands:\n") != null);
        try testing.expect(std.mem.indexOf(u8, text, "Print this message") != null);
        try testing.expect(std.mem.indexOf(u8, text, "completion") == null);
        try testing.expect(std.mem.indexOf(u8, text, "docs") == null);
    }
}
