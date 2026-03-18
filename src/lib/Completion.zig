//! Shell completion script generation and dynamic suggestion endpoint.
//!
//! This module provides static script emitters for multiple shells and a shared
//! `__complete` runtime suggestion path used by dynamic completion integrations.
//!
//! ## Typed API
//!
//! Use `generateCompletions(root, shell, writer)` with the `Shell` enum for
//! type-safe script generation.  The shell-string-based `printCompletionScript`
//! is kept for the built-in `completion <shell>` subcommand.
//!
//! ## Dynamic suggestions
//!
//! When a flag is being completed with `--name=<prefix>`, suggestions include:
//! - For `enum_tag` and `string` flags with `allowed_values`: the allowed values.
//! - For `key_value_list` flags: `--name=<key>=` candidates from `allowed_keys`.
//! - For `key_value_list` flags after `--name=<key>=`: `--name=<key>=<value>`
//!   candidates from `allowed_values`.

const std = @import("std");
const Command = @import("Command.zig");
const ParseContext = @import("ParseContext.zig");

/// Supported shell targets for completion script generation.
pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,
    sh,
    nu,
};

/// Registers the built-in `completion` subcommand on root.
pub fn registerCompletionCommand(root: *Command) !void {
    if (root.findSubcommand("completion") != null) return;

    const completion = try root.addSubcommand(.{
        .name = "completion",
        .description = "Generate shell completion scripts",
    });
    try completion.addPositional(.{
        .name = "shell",
        .description = "One of: bash, zsh, fish, pwsh, sh, nu, nushell",
        .required = true,
    });
    try completion.addFlag(bool, .{
        .name = "dynamic",
        .description = "For Nushell, emit dynamic completer module (default: static)",
        .default = false,
    });
    completion.setHelpOnEmptyArgs(true);
    completion.setHooks(.{ .run = runCompletionCommand });
}

/// Runs completion command and writes shell script to stdout.
pub fn runCompletionCommand(ctx: *ParseContext) !void {
    const shell = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const dynamic = ctx.boolFlag("dynamic") orelse false;
    try printCompletionScript(ctx.command.root(), shell, dynamic);
}

/// Writes completion script for requested shell (string-based, used by the
/// built-in `completion` subcommand).
pub fn printCompletionScript(root: *Command, shell: []const u8, dynamic: bool) !void {
    var buf: [8192]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const w = &out.interface;
    if (std.mem.eql(u8, shell, "bash")) {
        try renderBash(w, root.name);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try renderZsh(w, root.name);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try renderFish(w, root.name);
    } else if (std.mem.eql(u8, shell, "pwsh")) {
        try renderPwsh(w, root.name);
    } else if (std.mem.eql(u8, shell, "sh")) {
        try renderSh(w, root.name);
    } else if (std.mem.eql(u8, shell, "nu") or std.mem.eql(u8, shell, "nushell")) {
        if (dynamic) {
            try renderNuDynamic(w, root.name);
        } else {
            try renderNuStatic(w, root, root.name, true);
        }
    } else {
        return error.InvalidEnumValue;
    }
    try out.interface.flush();
}

/// Generates a completion script for the given shell to `writer`.
///
/// This is the typed API intended for programmatic use.  The `writer` may be
/// any `anytype` writer (file, buffer, etc.).
pub fn generateCompletions(root: *Command, shell: Shell, writer: anytype) !void {
    switch (shell) {
        .bash => try renderBash(writer, root.name),
        .zsh => try renderZsh(writer, root.name),
        .fish => try renderFish(writer, root.name),
        .powershell => try renderPwsh(writer, root.name),
        .sh => try renderSh(writer, root.name),
        .nu => try renderNuStatic(writer, root, root.name, true),
    }
}

/// Prints dynamic completion suggestions for `__complete`.
pub fn printDynamicSuggestions(root: *Command, args: []const []const u8) !void {
    var out_buf: [8192]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
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
/// When the prefix contains `=` (e.g. `--format=` or `--rule=name=`), the
/// function switches to value-completion mode: it looks up the flag and
/// emits candidates from `allowed_values` / `allowed_keys`.
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
    if (cmd.rootConst().version != null) {
        if (std.mem.startsWith(u8, "--version", prefix)) try writer.print("--version\n", .{});
        if (std.mem.startsWith(u8, "-V", prefix)) try writer.print("-V\n", .{});
    }
}

/// Suggests values for a specific flag given an already-typed value prefix.
///
/// - `enum_tag` / `string` with `allowed_values`: emits `name_prefix<value>`.
/// - `key_value_list` without `=` in value_prefix: emits `name_prefix<key>=`
///   candidates from `allowed_keys`.
/// - `key_value_list` with `=` in value_prefix: emits `name_prefix<key>=<val>`
///   candidates from `allowed_values`.
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

/// Emits POSIX-sh fallback (bash-style `complete`).
fn renderSh(w: anytype, name: []const u8) !void {
    try w.print(
        \\# POSIX sh fallback: source in a bash-compatible shell.
        \\_{s}_completion() {{
        \\  local IFS='
        \\'
        \\  COMPREPLY=($("$(COMP_WORDS[0])" __complete "${{COMP_WORDS[@]:1}}"))
        \\}}
        \\complete -o default -F _{s}_completion {s}
        \\
    , .{ name, name, name });
}

/// Emits Nushell dynamic module (meta-completer friendly).
fn renderNuDynamic(w: anytype, name: []const u8) !void {
    try w.print(
        \\# Nushell dynamic completion module for {s}
        \\# Note: Nushell supports a single global external completer.
        \\# This module includes helpers for composing with other completers.
        \\module "{s}-completer" {{
        \\  export def handles [spans: list<string>] {{
        \\    ($spans | length) > 0 and ($spans.0 == "{s}")
        \\  }}
        \\
        \\  export def complete [spans: list<string>] {{
        \\    let args = ($spans | skip 1)
        \\    ^{s} __complete ...$args
        \\      | lines
        \\      | where ($it | str length) > 0
        \\      | each {{|x| {{value: $x description: $x}} }}
        \\  }}
        \\
        \\  # Install as the only external completer.
        \\  export def install [] {{
        \\    $env.config = (
        \\      $env.config
        \\      | upsert completions.external.completer {{|spans|
        \\          if (handles $spans) {{ complete $spans }} else {{ null }}
        \\        }}
        \\    )
        \\  }}
        \\
        \\  # Return a completer closure that first delegates to this module.
        \\  # If this module does not handle spans, delegate to fallback.
        \\  export def chain [fallback: closure] {{
        \\    {{|spans|
        \\      if (handles $spans) {{
        \\        complete $spans
        \\      }} else {{
        \\        do $fallback $spans
        \\      }}
        \\    }}
        \\  }}
        \\
        \\  # Install while preserving an existing external completer.
        \\  # If no completer exists, falls back to null results for non-matching commands.
        \\  export def install-with-existing [] {{
        \\    let prev = ($env.config.completions.external.completer? | default {{|_spans| null }})
        \\    let chained = (chain $prev)
        \\    $env.config = ($env.config | upsert completions.external.completer $chained)
        \\  }}
        \\
        \\  # Build a dispatcher closure from a list of completer modules.
        \\  # Usage example:
        \\  #   let ext = (dispatch [ ({{|s| (mod-a handles $s)}}) ({{|s| (mod-a complete $s)}})
        \\  #                        ({{|s| (mod-b handles $s)}}) ({{|s| (mod-b complete $s)}}) ])
        \\  #   $env.config = ($env.config | upsert completions.external.completer $ext)
        \\  export def dispatch [pairs: list<closure>] {{
        \\    {{|spans|
        \\      mut i = 0
        \\      while $i < ($pairs | length) {{
        \\        let h = ($pairs | get $i)
        \\        let c = ($pairs | get ($i + 1))
        \\        if (do $h $spans) {{
        \\          return (do $c $spans)
        \\        }}
        \\        $i = ($i + 2)
        \\      }}
        \\      null
        \\    }}
        \\  }}
        \\}}
        \\
        \\export use "{s}-completer" *
        \\
    , .{ name, name, name, name, name });
}

/// Emits static Nushell `extern` module for command tree.
fn renderNuStatic(w: anytype, root: *const Command, path: []const u8, is_root: bool) !void {
    if (is_root) {
        try w.print("module completions {{\n\n", .{});
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
    if (root.rootConst().version != null) {
        try w.print("    --version(-V)           # Print version\n", .{});
    }

    for (root.positionals.items) |pos| {
        if (pos.variadic) {
            try w.print("    ...{s}: string\n", .{pos.name});
        } else if (pos.required) {
            try w.print("    {s}: string\n", .{pos.name});
        } else {
            try w.print("    {s}?: string\n", .{pos.name});
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
