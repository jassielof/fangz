//! Representative CLI tree for help, parse, and docgen behavior (no consumer-specific wiring).

const std = @import("std");
const testing = std.testing;
const fangz = @import("fangz");

const OutputMode = enum { pretty, text, minimal, json };

const FailFast = enum { none, @"error", warn, any };

/// Minimal app shape similar to real consumers: root flags, enum output, nested `status`.
fn wireSampleApp(app: *fangz.App) !void {
    const root = app.root();

    try root.addPositional(.{
        .name = "paths",
        .brief = "Files or directories to process. When omitted, defaults are discovered from the project manifest.",
        .variadic = true,
    });

    try root.addFlag(?[]const u8, .{
        .name = "config-path",
        .brief = "Path to configuration file",
        .description = "When omitted, the tool searches upward from the working directory for a project config file.",
        .value_hint = "PATH",
    });

    try root.addFlag(OutputMode, .{
        .name = "format",
        .short = 'f',
        .brief = "Output format",
        .value_hint = "FORMAT",
        .default = .pretty,
        .allowed_values_style = .comma,
    });

    try root.addFlag(bool, .{
        .name = "include-build-scripts",
        .brief = "Include build.zig and build/*.zig files in targets",
        .default = false,
    });

    try root.addFlag(FailFast, .{
        .name = "fail-fast",
        .short = 'F',
        .brief = "Stop after the first matching severity",
        .value_hint = "WHEN",
        .default = .none,
    });

    _ = try root.addSubcommand(.{
        .name = "status",
        .brief = "Show project status and effective settings",
        .description = "Print project metadata and resolved targets. Exits 0 after a successful report.",
    });
}

test "nested subcommand appears in full help" {
    var app = try makeApp();
    defer app.deinit();

    try wireSampleApp(&app);
    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "status") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Show project status and effective settings") != null);
    try testing.expect(std.mem.indexOf(u8, text, "archive") == null);
}

test "short help omits flags that are not registered" {
    var app = try makeApp();
    defer app.deinit();

    try wireSampleApp(&app);
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
    var app = try makeApp();
    defer app.deinit();

    try wireSampleApp(&app);
    try app.root_command.freeze();

    var buf: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try fangz.HelpRenderer.render(&writer, app.root(), .none, .full);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "--config-path") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PATH") != null);
}

test "parse errors on unknown flag" {
    var app = try makeApp();
    defer app.deinit();

    try wireSampleApp(&app);
    try app.root_command.freeze();

    const argv: []const []const u8 = &.{ "--rule", "alpha=deny" };
    try testing.expectError(error.UnknownFlag, fangz.Parser.parse(testing.allocator, testing.io, app.root(), argv));
}

test "generated AsciiDoc synopsis omits key-value metavar when flag absent" {
    var app = try makeApp();
    defer app.deinit();

    try wireSampleApp(&app);
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
    var app = try makeApp();
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
    var app = try makeApp();
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
    var app = try makeApp();
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
    var app = try makeApp();
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

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .display_name = "Sample",
        .brief = "CLI UX fixture app.",
        .version = "0.0.0",
    });
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}
