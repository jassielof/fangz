//! Shell completion script generation and dynamic suggestion endpoint.
//!
//! This module provides static script emitters for multiple shells and a shared `__complete` runtime suggestion path used by dynamic completion integrations.
//!
//! ## Typed API
//!
//! Use `generateCompletions(root, shell, writer)` with the `Shell` enum for type-safe script generation.  The shell-string-based `printCompletionScript` is kept for the built-in `completion <shell>` subcommand.
//!
//! ## Nushell static completions
//!
//! The Nushell renderer emits a `module completions` block with `export extern` declarations.
//! Positionals annotated with `CompletionKind.zig_paths` get a `@complete-zig-paths` custom  completer that resolves directories and `.zig` / `.zon` files from the working directory.
//!
//! ## Dynamic runtime suggestions (`__complete`)
//!
//! When a flag is being completed with `--name=<prefix>`, suggestions include:
//!
//! - For `enum_tag` and `string` flags with `allowed_values`: the allowed values.
//! - For `key_value_list` flags: `--name=<key>=` candidates from `allowed_keys`.
//! - For `key_value_list` flags after `--name=<key>=`: `--name=<key>=<value>` candidates from `allowed_values`.

// TODO: Move this to a shells directory, and also move each respective shell completion step into its own file.

const std = @import("std");

const Command = @import("Command.zig");
const ParseContext = @import("ParseContext.zig");

/// Supported shell targets for completion script generation.
pub const Shell = enum {
    /// <https://www.gnu.org/software/bash/>
    bash,
    /// <https://www.zsh.org/>
    zsh,
    /// <https://fishshell.com/>
    fish,
    /// <https://www.microsoft.com/PowerShell>
    pwsh,
    /// <https://www.nushell.sh/>
    nu,

    /// Returns the human-friendly name of the shell.
    pub fn toPrettyName(self: Shell) []const u8 {
        return switch (self) {
            .bash => "Bash",
            .zsh => "Zsh",
            .fish => "Fish",
            .pwsh => "PowerShell",
            .nu => "Nushell",
        };
    }

    /// Returns the string name of the shell, based off the enum tag.
    pub fn toStringName(self: Shell) []const u8 {
        return @tagName(self);
    }

    /// Returns a list of allowed string values for the Shell enum.
    pub fn allowedValues() []const []const u8 {
        return comptime blk: {
            const fields = @typeInfo(Shell).@"enum".fields;
            var values: [fields.len][]const u8 = undefined;

            for (fields, 0..) |field, i| {
                values[i] = field.name;
            }

            const final = values;

            break :blk &final;
        };
    }
};

/// Returns the pretty display label for each `Shell` variant, in the same order as `Shell.allowedValues()`.
fn shellAllowedValueLabels() []const []const u8 {
    return comptime blk: {
        const fields = @typeInfo(Shell).@"enum".fields;
        var labels: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            const shell_val: Shell = @enumFromInt(field.value);
            labels[i] = shell_val.toPrettyName();
        }
        const final = labels;
        break :blk &final;
    };
}

/// Registers the built-in completions subcommand on root.
///
/// Accepts completion/s spellings as aliases.
pub fn registerCompletionCommand(root: *Command) !void {
    if (root.findSubcommand("completion") != null) return;
    if (root.findSubcommand("completions") != null) return;

    const completion = try root.addSubcommand(.{
        .name = "completion",
        .description = "Generate shell completion scripts",
    });

    try completion.addAlias("completions");

    try completion.addPositional(.{
        .name = "shell",
        .description = "Target shell.",
        .required = true,
        .allowed_values = Shell.allowedValues(),
        .allowed_value_labels = shellAllowedValueLabels(),
        .allowed_values_style = .bullet_list,
    });

    completion.setHelpOnEmptyArgs(true);
    completion.setHooks(.{ .run = runCompletionCommand });
}

/// Runs completion command and writes shell script to stdout.
pub fn runCompletionCommand(ctx: *ParseContext) !void {
    const shell = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printCompletionScript(ctx.io, ctx.command.root(), shell);
}

/// Writes completion script for requested shell (string-based, used by the built-in `completion` subcommand).
pub fn printCompletionScript(io: std.Io, root: *Command, shell: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    if (std.mem.eql(u8, shell, "bash")) {
        try renderBash(w, root.name);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try renderZsh(w, root.name);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try renderFish(w, root.name);
    } else if (std.mem.eql(u8, shell, "pwsh")) {
        try renderPwsh(w, root.name);
    } else if (std.mem.eql(u8, shell, "nu") or std.mem.eql(u8, shell, "nushell")) {
        try renderNuStatic(w, root, root.name, true);
    } else {
        return error.InvalidEnumValue;
    }
    try out.interface.flush();
}

/// Generates a completion script for the given shell to `writer`.
///
/// This is the typed API intended for programmatic use.  The `writer` may be  any `anytype` writer (file, buffer, etc.).
// TODO: Writer should be respective type of the new Writergate interface, not anytype. This should be reviewed also in all the project's codebase.
pub fn generateCompletions(root: *Command, shell: Shell, writer: anytype) !void {
    switch (shell) {
        .bash => try renderBash(writer, root.name),
        .zsh => try renderZsh(writer, root.name),
        .fish => try renderFish(writer, root.name),
        .pwsh => try renderPwsh(writer, root.name),
        .nu => try renderNuStatic(writer, root, root.name, true),
    }
}

/// Prints dynamic completion suggestions for `__complete`.
pub fn printDynamicSuggestions(io: std.Io, root: *Command, args: []const []const u8) !void {
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const writer = &out.interface;

    var active = root;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        const tok = args[i];
        if (std.mem.startsWith(u8, tok, "-")) {
            if (flagExpectsValue(active, tok) and i + 1 < args.len) i += 1;
            continue;
        }
        if (active.findSubcommand(tok)) |sub| {
            active = sub;
        }
    }

    const prefix = if (args.len > 0) args[args.len - 1] else "";
    if (std.mem.startsWith(u8, prefix, "-")) {
        try suggestFlags(writer, active, prefix);
    } else {
        try suggestCommands(writer, active, prefix);
    }
    try out.interface.flush();
}

/// Suggests subcommand names matching `prefix`.
fn suggestCommands(writer: anytype, cmd: *const Command, prefix: []const u8) !void {
    for (cmd.subcommands.items) |sub| {
        if (prefix.len == 0 or std.mem.startsWith(u8, sub.name, prefix)) {
            try writer.print("{s}\n", .{sub.name});
        }
    }
    if (prefix.len == 0 or std.mem.startsWith(u8, "help", prefix)) {
        try writer.print("help\n", .{});
    }
}

/// Suggests short/long flags or flag values matching `prefix`.
///
/// When the prefix contains `=` (e.g. `--format=` or `--rule=name=`), the function switches to value-completion mode: it looks up the flag and emits candidates from `allowed_values` / `allowed_keys`.
fn suggestFlags(writer: anytype, cmd: *const Command, prefix: []const u8) !void {
    // Value-completion mode: prefix is "--flag-name=<value-prefix>"
    if (std.mem.startsWith(u8, prefix, "--")) {
        const body = prefix[2..];
        if (std.mem.indexOfScalar(u8, body, '=')) |eq_idx| {
            const flag_name = body[0..eq_idx];
            const value_prefix = body[eq_idx + 1 ..];
            const name_prefix = prefix[0 .. 2 + eq_idx + 1]; // "--flag-name="
            if (cmd.resolveFlagByName(flag_name)) |lookup| {
                const flag = lookup.command.flags.constSlice()[lookup.index];
                try suggestFlagValues(writer, name_prefix, flag, value_prefix);
                return;
            }
        }
    }

    // Flag-name completion mode
    var chain = try cmd.collectAncestorPath(std.heap.page_allocator);
    defer chain.deinit(std.heap.page_allocator);

    for (chain.items) |ancestor| {
        for (ancestor.flags.constSlice()) |flag| {
            if (ancestor != cmd and !flag.persistent) continue;

            var long_buf: [256]u8 = undefined;
            const long = std.fmt.bufPrint(&long_buf, "--{s}", .{flag.name}) catch continue;
            if (std.mem.startsWith(u8, long, prefix)) try writer.print("{s}\n", .{long});

            if (flag.short) |s| {
                var short_buf: [2]u8 = .{ '-', s };
                const short = short_buf[0..];
                if (std.mem.startsWith(u8, short, prefix)) try writer.print("{s}\n", .{short});
            }
        }
    }

    if (std.mem.startsWith(u8, "--help", prefix)) try writer.print("--help\n", .{});
    if (std.mem.startsWith(u8, "-h", prefix)) try writer.print("-h\n", .{});
    if (cmd.parent == null and cmd.rootConst().version != null) {
        if (std.mem.startsWith(u8, "--version", prefix)) try writer.print("--version\n", .{});
        if (std.mem.startsWith(u8, "-V", prefix)) try writer.print("-V\n", .{});
    }
}

/// Suggests values for a specific flag given an already-typed value prefix.
///
/// - `enum_tag` / `string` with `allowed_values`: emits `name_prefix<value>`.
/// - `key_value_list` without `=` in value_prefix: emits `name_prefix<key>=` candidates from `allowed_keys`.
/// - `key_value_list` with `=` in value_prefix: emits `name_prefix<key>=<val>` candidates from `allowed_values`.
fn suggestFlagValues(
    writer: anytype,
    name_prefix: []const u8,
    flag: Command.Flag,
    value_prefix: []const u8,
) !void {
    if (flag.value_type == .key_value_list) {
        if (std.mem.indexOfScalar(u8, value_prefix, '=')) |kv_eq| {
            // Completing the value portion: --rule=missing_doc_comment=<value>
            const key = value_prefix[0..kv_eq];
            const val_prefix = value_prefix[kv_eq + 1 ..];
            if (flag.allowed_values) |vals| {
                for (vals) |v| {
                    if (val_prefix.len == 0 or std.mem.startsWith(u8, v, val_prefix)) {
                        try writer.print("{s}{s}={s}\n", .{ name_prefix, key, v });
                    }
                }
            }
        } else {
            // Completing the key portion: --rule=<key>=
            if (flag.allowed_keys) |keys| {
                for (keys) |k| {
                    if (value_prefix.len == 0 or std.mem.startsWith(u8, k, value_prefix)) {
                        try writer.print("{s}{s}=\n", .{ name_prefix, k });
                    }
                }
            }
        }
        return;
    }

    // enum_tag or string with allowed_values
    if (flag.allowed_values) |vals| {
        for (vals) |v| {
            if (value_prefix.len == 0 or std.mem.startsWith(u8, v, value_prefix)) {
                try writer.print("{s}{s}\n", .{ name_prefix, v });
            }
        }
    }
}

/// Checks whether a token references a flag that consumes a value.
fn flagExpectsValue(cmd: *const Command, token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "--")) {
        var name = token[2..];
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| name = name[0..eq];
        if (cmd.resolveFlagByName(name)) |lookup| {
            return lookup.command.flags.constSlice()[lookup.index].takesValue();
        }
        return false;
    }
    if (std.mem.startsWith(u8, token, "-") and token.len == 2) {
        const short = token[1];
        if (cmd.resolveFlagByShort(short)) |lookup| {
            return lookup.command.flags.constSlice()[lookup.index].takesValue();
        }
    }
    return false;
}

/// Emits bash completion wrapper.
fn renderBash(w: anytype, name: []const u8) !void {
    try w.print(
        \\_{s}_completion() {{
        \\  local IFS=$'\n'
        \\  COMPREPLY=($("$(COMP_WORDS[0])" __complete "${{COMP_WORDS[@]:1}}"))
        \\}}
        \\complete -o default -F _{s}_completion {s}
        \\
    , .{ name, name, name });
}

/// Emits zsh completion wrapper.
fn renderZsh(w: anytype, name: []const u8) !void {
    try w.print(
        \\#{s} completion
        \\_{s}_completion() {{
        \\  local -a reply
        \\  reply=("${{(@f)$({s} __complete ${{words[2,-1]}})}}")
        \\  _describe 'values' reply
        \\}}
        \\compdef _{s}_completion {s}
        \\
    , .{ name, name, name, name, name });
}

/// Emits fish completion wrapper.
fn renderFish(w: anytype, name: []const u8) !void {
    try w.print(
        \\function __{s}_complete
        \\  set -l tokens (commandline -opc)
        \\  set -e tokens[1]
        \\  {s} __complete $tokens
        \\end
        \\complete -f -c {s} -a "(__{s}_complete)"
        \\
    , .{ name, name, name, name });
}

/// Emits PowerShell completion wrapper.
fn renderPwsh(w: anytype, name: []const u8) !void {
    try w.print(
        \\Register-ArgumentCompleter -Native -CommandName '{s}' -ScriptBlock {{
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $tokens = $commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object {{ $_.Extent.Text }}
        \\    & {s} __complete @tokens | ForEach-Object {{
        \\        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        \\    }}
        \\}}
        \\
    , .{ name, name });
}

/// Walks the command tree and appends every unique `NuCompleter` (deduplicated by name)
/// into `out`.  Uses `page_allocator` consistent with the rest of this file.
fn collectNuCompleters(cmd: *const Command, out: *std.ArrayList(Command.NuCompleter)) !void {
    for (cmd.positionals.items) |pos| {
        const completer = pos.nu_completer orelse continue;
        // Deduplicate by name — linear scan is fine; apps have very few completers.
        const already = for (out.items) |existing| {
            if (std.mem.eql(u8, existing.name, completer.name)) break true;
        } else false;
        if (!already) try out.append(std.heap.page_allocator, completer);
    }
    for (cmd.subcommands.items) |sub| {
        try collectNuCompleters(sub, out);
    }
}

/// Emits static Nushell `extern` module for command tree.
fn renderNuStatic(w: anytype, root: *const Command, path: []const u8, is_root: bool) !void {
    if (is_root) {
        try w.print("module completions {{\n\n", .{});

        // Collect and emit all unique user-supplied Nushell custom completers.
        var completers: std.ArrayList(Command.NuCompleter) = .empty;
        defer completers.deinit(std.heap.page_allocator);
        try collectNuCompleters(root, &completers);
        for (completers.items) |c| {
            try w.print("  def {s} [] {{\n    {s}\n  }}\n\n", .{ c.name, c.body });
        }
    }

    if (is_root) {
        try w.print("  export extern {s} [\n", .{path});
    } else {
        try w.print("  export extern \"{s}\" [\n", .{path});
    }

    for (root.flags.constSlice()) |flag| {
        try printNuFlag(w, flag);
    }
    try w.print("    --help(-h)              # Print help\n", .{});
    if (root.parent == null and root.rootConst().version != null) {
        try w.print("    --version(-V)           # Print version\n", .{});
    }

    for (root.positionals.items) |pos| {
        const at_completer = if (pos.nu_completer) |c|
            std.fmt.allocPrint(std.heap.page_allocator, "@{s}", .{c.name}) catch ""
        else
            "";
        defer if (pos.nu_completer != null) std.heap.page_allocator.free(at_completer);
        // Nushell rejects hyphens in positional parameter names, so normalize
        // kebab-case names to snake_case.
        const nu_name = try std.mem.replaceOwned(u8, std.heap.page_allocator, pos.name, "-", "_");
        defer std.heap.page_allocator.free(nu_name);
        if (pos.variadic) {
            try w.print("    ...{s}: string{s}\n", .{ nu_name, at_completer });
        } else if (pos.required) {
            try w.print("    {s}: string{s}\n", .{ nu_name, at_completer });
        } else {
            try w.print("    {s}?: string{s}\n", .{ nu_name, at_completer });
        }
    }
    try w.print("  ]\n\n", .{});

    for (root.subcommands.items) |sub| {
        const child_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ path, sub.name });
        defer std.heap.page_allocator.free(child_path);
        try renderNuStatic(w, sub, child_path, false);
    }

    if (is_root) {
        try w.print("}}\n\nexport use completions *\n", .{});
    }
}

/// Writes one static Nushell flag row.
fn printNuFlag(w: anytype, flag: Command.Flag) !void {
    if (flag.short) |short| {
        if (flag.takesValue()) {
            try w.print("    --{s}(-{c}): string\n", .{ flag.name, short });
        } else {
            try w.print("    --{s}(-{c})\n", .{ flag.name, short });
        }
        return;
    }

    if (flag.takesValue()) {
        try w.print("    --{s}: string\n", .{flag.name});
    } else {
        try w.print("    --{s}\n", .{flag.name});
    }
}
