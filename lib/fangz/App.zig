//! High-level application orchestrator for Fangz.
//!
//! `App` owns the root command tree, parses argv input, executes hook lifecycles, and provides convenience helpers for help, errors, completions, and documentation generation.

const std = @import("std");

const carnaval = @import("carnaval");
const meta = @import("fangz_meta");

const Command = @import("Command.zig");
const Completion = @import("completions.zig");
const DocGenerator = @import("DocGenerator.zig");
const errors = @import("errors.zig");
const Error = errors.Error;
const HelpRenderer = @import("HelpRenderer.zig");
const ParseContext = @import("ParseContext.zig");
const Parser = @import("Parser.zig");

const App = @This();

/// Allocator used for app-owned parse state and command tree allocations.
allocator: std.mem.Allocator,
/// I/O context used by parsing, command execution, and generated output.
io: std.Io,
/// Root command for this application.
root_command: Command,
/// Most recent parse context retained for caller inspection.
last_context: ?ParseContext = null,
/// Process arguments owned by the app after `parseProcess`.
owned_process_args: std.ArrayList([]const u8) = .empty,
/// Whether the built-in completion command should be registered lazily.
completions_enabled: bool = true,
/// Whether the built-in completion command has already been registered.
completion_registered: bool = false,
/// Whether the built-in docs command should be registered lazily.
docs_enabled: bool = true,
/// Whether the built-in docs command has already been registered.
docs_registered: bool = false,
/// Short git commit hash shown by `--version`.
commit: []const u8 = "",
/// Git branch name shown by `--version`.
branch: []const u8 = "",

pub const AppOptions = @import("AppOptions.zig");

/// Constructs an application with a root command.
pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: AppOptions) Error!App {
    prepareConsole();

    // Fall back to build-injected meta when fields are absent.
    const name = meta.name;
    const display_name = cfg.display_name orelse meta.name;
    const version: ?[]const u8 = if (cfg.version) |v|
        (if (v.len > 0) v else null)
    else if (meta.version.len > 0)
        meta.version
    else
        null;
    const commit = cfg.commit orelse meta.commit;
    const branch = cfg.branch orelse meta.branch;
    const author_name = cfg.author_name orelse meta.author_name;
    const author_email = cfg.author_email orelse meta.author_email;
    const source_date = cfg.source_date orelse meta.source_date;
    const brief = if (cfg.brief.len > 0) cfg.brief else meta.brief;

    return .{
        .allocator = allocator,
        .io = io,
        .commit = commit,
        .branch = branch,
        .root_command = try Command.init(allocator, .{
            .name = name,
            .display_name = display_name,
            .tagline = cfg.tagline,
            .brief = brief,
            .description = cfg.description,
            .version = version,
            .author_name = author_name,
            .author_email = author_email,
            .git_branch = branch,
            .git_commit = commit,
            .source_date = source_date,
        }),
    };
}

/// Releases app-owned parse state and command tree memory.
pub fn deinit(self: *App) void {
    if (self.last_context) |*ctx| ctx.deinit();
    self.freeOwnedProcessArgs();
    self.root_command.deinit();
}

/// Returns the mutable root command.
pub fn root(self: *App) *Command {
    return &self.root_command;
}

/// Enables or disables built-in completion command registration.
pub fn setCompletionsEnabled(self: *App, enabled: bool) void {
    self.completions_enabled = enabled;
}

/// Enables or disables the built-in docs command registration.
pub fn setDocsEnabled(self: *App, enabled: bool) void {
    self.docs_enabled = enabled;
}

/// Parses explicit argv tokens and returns the active parse context.
pub fn parseFrom(self: *App, argv: []const []const u8) Error!*ParseContext {
    try self.ensureDocsCommand();
    try self.ensureCompletionCommand();
    try self.root_command.freeze();
    if (self.last_context) |*ctx| ctx.deinit();
    self.last_context = null;
    self.freeOwnedProcessArgs();

    const output = try Parser.parse(self.allocator, self.io, self.root(), argv);
    self.last_context = output.context;
    return &self.last_context.?;
}

/// Parses the current process argv and returns the parse context.
pub fn parseProcess(self: *App, process_args: std.process.Args) Error!*ParseContext {
    try self.ensureDocsCommand();
    try self.ensureCompletionCommand();
    try self.root_command.freeze();
    if (self.last_context) |*ctx| ctx.deinit();
    self.last_context = null;
    self.freeOwnedProcessArgs();

    try self.collectProcessArgsInto(process_args, &self.owned_process_args);
    const output = try Parser.parse(self.allocator, self.io, self.root(), self.owned_process_args.items);
    self.last_context = output.context;
    return &self.last_context.?;
}

/// Parses and executes command hooks for explicit argv input.
pub fn executeFrom(self: *App, argv: []const []const u8) anyerror!void {
    try self.ensureDocsCommand();
    try self.ensureCompletionCommand();
    try self.root_command.freeze();

    if (self.completions_enabled and argv.len > 0 and std.mem.eql(u8, argv[0], "__complete")) {
        try Completion.printDynamicSuggestions(self.io, self.root(), argv[1..]);
        return;
    }

    if (argv.len == 0 and self.root().help_on_empty_args) {
        try self.printHelp(self.root());
        return;
    }

    const ctx = self.parseFrom(argv) catch |err| {
        if (errors.asParseError(err)) |pe| {
            var diag = try Parser.diagnoseError(self.allocator, self.root(), argv, pe);
            defer diag.deinit();
            try self.printError(diag.message, diag.hint);
        }

        return err;
    };

    if (ctx.help_requested) {
        try self.printHelp(ctx.command);
        return;
    }

    if (ctx.short_help_requested) {
        try self.printShortHelp(ctx.command);
        return;
    }

    if (ctx.version_requested) {
        try self.printVersion();
        return;
    }

    try self.runHooks(ctx);
}

/// Parses and executes command hooks using current process argv.
pub fn executeProcess(self: *App, process_args: std.process.Args) anyerror!void {
    var args = try self.collectProcessArgs(process_args);
    defer self.deinitOwnedArgs(&args);
    try self.executeFrom(args.items);
}

fn collectProcessArgs(self: *App, process_args: std.process.Args) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer self.deinitOwnedArgs(&args);
    try self.collectProcessArgsInto(process_args, &args);
    return args;
}

fn collectProcessArgsInto(self: *App, process_args: std.process.Args, args: *std.ArrayList([]const u8)) !void {
    var it = try std.process.Args.Iterator.initAllocator(process_args, self.allocator);
    defer it.deinit();

    _ = it.skip();

    while (it.next()) |arg| {
        try args.append(self.allocator, try self.allocator.dupe(u8, arg));
    }
}

fn deinitOwnedArgs(self: *App, args: *std.ArrayList([]const u8)) void {
    for (args.items) |arg| self.allocator.free(arg);
    args.deinit(self.allocator);
}

fn freeOwnedProcessArgs(self: *App) void {
    self.deinitOwnedArgs(&self.owned_process_args);
    self.owned_process_args = .empty;
}

/// Generates AsciiDoc documentation for the current command tree.
pub fn generateDocs(self: *App, options: DocGenerator.Options) !void {
    try DocGenerator.generateDocs(self.allocator, self.io, self.root(), options);
}

/// Generates a shell completion script to the provided writer.
///
/// Use the `Shell` enum for type-safe shell selection.  The script delegates to the `__complete` runtime endpoint for dynamic suggestions.
pub fn generateCompletions(self: *App, shell: Completion.Shell, writer: *std.Io.Writer) !void {
    try Completion.generateCompletions(&self.root_command, shell, writer);
}

/// Renders full help text (`--help`) for the given command to stdout.
pub fn printHelp(self: *App, command: *const Command) !void {
    prepareConsole();
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var stdout_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
    try HelpRenderer.render(&out_writer.interface, command, profile, .full);
    try out_writer.interface.flush();
}

/// Renders compact help text (`-h`) for the given command to stdout.
pub fn printShortHelp(self: *App, command: *const Command) !void {
    prepareConsole();
    const profile = carnaval.colorProfileForHandle(std.Io.File.stdout().handle);
    var stdout_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
    try HelpRenderer.render(&out_writer.interface, command, profile, .short);
    try out_writer.interface.flush();
}

/// Prints a styled error and optional hint to stderr.
pub fn printError(self: *App, message: []const u8, hint: ?[]const u8) !void {
    prepareConsole();
    const profile = carnaval.colorProfileForHandle(std.Io.File.stderr().handle);
    var stderr_buffer: [4096]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(self.io, &stderr_buffer);
    try carnaval.Style.init().fg(.{ .ansi16 = .red }).renderWithProfile("error:", &err_writer.interface, profile);
    try err_writer.interface.print(" {s}\n", .{message});
    if (hint) |h| {
        try carnaval.Style.init().fg(.{ .ansi16 = .yellow }).renderWithProfile("hint:", &err_writer.interface, profile);
        try err_writer.interface.print(" {s}\n", .{h});
    }

    try err_writer.interface.flush();
}

/// Executes persistent and local hook lifecycle around command run.
fn runHooks(self: *App, ctx: *ParseContext) !void {
    var chain = try ctx.command.collectAncestorPath(self.allocator);
    defer chain.deinit(self.allocator);

    for (chain.items) |cmd| {
        if (cmd.hooks.persistent_pre_run) |f| try f(ctx);
    }

    if (ctx.command.hooks.pre_run) |f| try f(ctx);
    if (ctx.command.hooks.run) |f| try f(ctx);
    if (ctx.command.hooks.post_run) |f| try f(ctx);

    var i = chain.items.len;

    while (i > 0) : (i -= 1) {
        const cmd = chain.items[i - 1];
        if (cmd.hooks.persistent_post_run) |f| try f(ctx);
    }
}

/// Prints the root command version to the standard output.
///
/// Output formats:
///
/// - `0.1.0 (main@abc1234)` (default): version + branch + commit
/// - `0.1.0 (abc1234)`: version + commit only
/// - `0.1.0 (main)`: version + branch only
/// - `0.1.0`: version only
/// - `main@abc1234`: git info only (no version set)
/// - nothing: no version and no git info
fn printVersion(self: *App) !void {
    prepareConsole();
    const version = self.root().version;
    const has_commit = self.commit.len > 0;
    const has_branch = self.branch.len > 0;
    const has_git = has_commit or has_branch;

    if (version == null and !has_git) return;

    var stdout_buffer: [512]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);

    if (version) |v| {
        if (has_git) {
            if (has_branch and has_commit) {
                try out_writer.interface.print("{s} ({s}@{s})\n", .{ v, self.branch, self.commit });
            } else if (has_branch) {
                try out_writer.interface.print("{s} ({s})\n", .{ v, self.branch });
            } else {
                try out_writer.interface.print("{s} ({s})\n", .{ v, self.commit });
            }
        } else {
            try out_writer.interface.print("{s}\n", .{v});
        }
    } else {
        if (has_branch and has_commit) {
            try out_writer.interface.print("{s}@{s}\n", .{ self.branch, self.commit });
        } else if (has_branch) {
            try out_writer.interface.print("{s}\n", .{self.branch});
        } else {
            try out_writer.interface.print("{s}\n", .{self.commit});
        }
    }

    try out_writer.interface.flush();
}

/// Lazily registers the built-in completion command when enabled.
fn ensureCompletionCommand(self: *App) !void {
    if (!self.completions_enabled) return;
    if (self.completion_registered) return;
    try Completion.registerCompletionCommand(self.root());
    self.completion_registered = true;
}

/// Lazily registers the built-in docs command when enabled.
fn ensureDocsCommand(self: *App) !void {
    if (!self.docs_enabled) return;
    if (self.docs_registered) return;
    try DocGenerator.registerDocsCommand(meta.name, self.root());
    self.docs_registered = true;
}

fn prepareConsole() void {
    carnaval.prepareWindowsConsoleIfNeeded(std.Io.File.stdout().handle);
    carnaval.prepareWindowsConsoleIfNeeded(std.Io.File.stderr().handle);
}
