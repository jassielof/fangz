//! Snapshot coverage for documentation generated from the shared fixture CLI.

const std = @import("std");
const testing = std.testing;

const fangz = @import("fangz");
const fixture = @import("fixture");

test "shared fixture AsciiDoc matches the expected snapshot" {
    var app: fangz.App = undefined;
    try fixture.initialize(&app, testing.allocator, testing.io);
    defer app.deinit();

    _ = try app.parseFrom(&.{});
    const current = try fangz.DocGenerator.renderDocs(
        testing.allocator,
        app.root(),
        .{},
    );
    defer testing.allocator.free(current);

    try testing.expectEqualStrings(@embedFile("snapshots/fangz.adoc"), current);
    try testing.expect(std.mem.indexOf(u8, current, "== Commands") == null);
    try testing.expect(std.mem.indexOf(u8, current, "\n\n\n") == null);
}

test "AsciiDoc snapshot renders with an installed AsciiDoc processor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const name = "fangz.adoc";
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = name,
        .data = @embedFile("snapshots/fangz.adoc"),
    });
    const path = try tmp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    defer testing.allocator.free(path);

    const processors: []const []const u8 = &.{ "asciidoctor", "asciidoctorj" };
    for (processors) |processor| {
        const result = std.process.run(testing.allocator, testing.io, .{
            .argv = &.{ processor, "--out-file", "-", path },
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }

        std.debug.print("{s} could not render {s}:\n{s}", .{ processor, name, result.stderr });
        return error.AsciiDocSnapshotDidNotRender;
    }

    return error.AsciiDocProcessorNotFound;
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
    const run = try root.addSubcommand(.{
        .name = "run",
        .brief = "Run the app",
    });
    try run.addFlag(bool, .{
        .name = "dry-run",
        .brief = "Do not apply changes",
    });
    try root.addFlag([]const fangz.KeyValuePair, .{
        .name = "rule",
        .short = 'r',
        .allowed_keys = &.{"alpha"},
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
    // Built-ins appear once at root; nested Options omit -h/--help.
    try testing.expect(std.mem.indexOf(u8, doc, "== Commands") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "* xref:cmd-fangz-help[`fangz help`]") == null);
}

test "app docs include configured author and revision metadata" {
    var app = try fangz.App.init(testing.allocator, testing.io, .{
        .display_name = "Git",
        .tagline = "Distributed Version Control",
        .brief = "test app",
        .version = "1.2.3",
        .author_name = .{ .custom = "Ada Lovelace" },
        .author_email = .{ .custom = "ada@example.com" },
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
    try testing.expect(std.mem.indexOf(u8, doc, "v1.2.3, 2026-05-01 -- main (abc1234)") != null);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
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

test "shared fixture AsciiDoc separates headings from surrounding content" {
    var app: fangz.App = undefined;
    try fixture.initialize(&app, testing.allocator, testing.io);
    defer app.deinit();

    _ = try app.parseFrom(&.{});
    const current = try fangz.DocGenerator.renderDocs(testing.allocator, app.root(), .{});
    defer testing.allocator.free(current);

    try expectWellSpacedHeadings(current);
}

test "generated AsciiDoc keeps angle brackets literal and escapes attribute braces" {
    var app = try makeApp();
    defer app.deinit();

    _ = try app.root().addSubcommand(.{
        .name = "bundle",
        .brief = "Copy into <output-dir>/<name>.",
        .description = "Imports become @<namespace>/<name>:<version> and {attr} stays literal.",
    });
    _ = try app.parseFrom(&.{});

    const current = try fangz.DocGenerator.renderDocs(testing.allocator, app.root(), .{});
    defer testing.allocator.free(current);

    try testing.expect(std.mem.indexOf(u8, current, "Copy into <output-dir>/<name>.") != null);
    try testing.expect(std.mem.indexOf(u8, current, "@<namespace>/<name>:<version>") != null);
    try testing.expect(std.mem.indexOf(u8, current, "\\<") == null);
    try testing.expect(std.mem.indexOf(u8, current, "\\>") == null);
    try testing.expect(std.mem.indexOf(u8, current, "\\{attr\\}") != null);
    try expectWellSpacedHeadings(current);
}

test "generated AsciiDoc lists a positional's default" {
    var app = try makeApp();
    defer app.deinit();

    const open = try app.root().addSubcommand(.{ .name = "open" });
    try open.addPositional(.{ .name = "target", .brief = "What to open.", .default_hint = "the current directory" });
    try open.addPositional(.{ .name = "extra", .brief = "No default here." });
    _ = try app.parseFrom(&.{});

    const current = try fangz.DocGenerator.renderDocs(testing.allocator, app.root(), .{});
    defer testing.allocator.free(current);

    try testing.expect(std.mem.indexOf(u8, current, "*Default:* the current directory") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, current, "*Default:* the current directory"));
    try expectWellSpacedHeadings(current);
}

/// Asserts every heading has a blank line before and after it, and every `[#anchor]` line has one before it, so AsciiDoc does not fold them into a neighbouring paragraph. The document title (line 1) and text inside delimited blocks are exempt.
fn expectWellSpacedHeadings(doc: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);

    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| try lines.append(testing.allocator, line);

    var in_block = false;
    for (lines.items, 0..) |line, i| {
        if (isBlockDelimiter(line)) {
            in_block = !in_block;
            continue;
        }
        if (in_block or i == 0) continue;

        const previous = lines.items[i - 1];
        const next: []const u8 = if (i + 1 < lines.items.len) lines.items[i + 1] else "";

        if (std.mem.startsWith(u8, line, "[#") and previous.len != 0) {
            std.debug.print("anchor on line {d} needs a blank line before it: {s}\n", .{ i + 1, line });
            return error.AnchorNotSeparated;
        }

        if (isHeading(line)) {
            const anchored = std.mem.startsWith(u8, previous, "[#");
            if (previous.len != 0 and !anchored) {
                std.debug.print("heading on line {d} needs a blank line before it: {s}\n", .{ i + 1, line });
                return error.HeadingNotSeparated;
            }
            if (next.len != 0) {
                std.debug.print("heading on line {d} needs a blank line after it: {s}\n", .{ i + 1, line });
                return error.HeadingNotSeparated;
            }
        }
    }
}

fn isBlockDelimiter(line: []const u8) bool {
    return std.mem.eql(u8, line, "----") or std.mem.eql(u8, line, "====") or std.mem.eql(u8, line, "|===");
}

fn isHeading(line: []const u8) bool {
    const markers = std.mem.indexOfNone(u8, line, "=") orelse return false;
    return markers > 0 and markers < line.len and line[markers] == ' ';
}

fn makeApp() !fangz.App {
    return fangz.App.init(testing.allocator, testing.io, .{
        .brief = "test app",
        .version = "1.2.3",
    });
}
