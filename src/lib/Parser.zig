//! Primary parser for Fangz command trees.
//!
//! This module handles command dispatch, POSIX-style option parsing, value
//! conversion/validation, and user-facing parse diagnostics.

const std = @import("std");

const Command = @import("Command.zig");
const ParseContext = @import("ParseContext.zig");
const Suggest = @import("Suggest.zig");
const Tokenizer = @import("Tokenizer.zig");

pub const ParseError = error{
    UnknownFlag,
    UnknownCommand,
    MissingFlagValue,
    MissingRequiredFlag,
    MissingRequiredPositional,
    TooManyPositionals,
    InvalidInt,
    InvalidFloat,
    InvalidEnumValue,
    KeyValueMissingEquals,
    KeyValueEmptyKey,
    KeyValueEmptyValue,
    InvalidAllowedKey,
    InvalidAllowedValue,
    UnexpectedValueForBool,
    MutuallyExclusiveFlags,
};

pub const ParseFailure = struct {
    err: ParseError,
    message: []const u8,
    hint: ?[]const u8 = null,
};

pub const ParseOutput = struct {
    context: ParseContext,
    failure: ?ParseFailure = null,
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    hint: ?[]const u8 = null,

    /// Frees owned strings stored in the diagnostic.
    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
        if (self.hint) |hint| self.allocator.free(hint);
    }
};

/// Parses argv against the command tree and returns a parse output context.
pub fn parse(allocator: std.mem.Allocator, io: std.Io, root: *Command, argv: []const []const u8) !ParseOutput {
    // freeze() is called by App before parsing; fall back to bindAliases here
    // only when Parser is used directly without going through App.
    if (!root.frozen) try root.bindAliases();

    const dispatch = try walkCommandPath(allocator, root, argv);
    if (dispatch.help_for) |help_cmd| {
        var help_ctx = try ParseContext.init(allocator, io, help_cmd);
        help_ctx.help_requested = true;
        return .{ .context = help_ctx, .failure = null };
    }

    var ctx = try ParseContext.init(allocator, io, dispatch.command);
    errdefer ctx.deinit();
    try applyDefaults(&ctx, dispatch.command);

    if (dispatch.remaining.len == 0 and dispatch.command.help_on_empty_args) {
        ctx.help_requested = true;
        return .{ .context = ctx };
    }

    var tokenizer = Tokenizer.init(dispatch.remaining);
    while (tokenizer.next()) |tok| {
        switch (tok.kind) {
            .terminator => {},
            .positional => {
                try ctx.positionals.append(allocator, tok.raw);
                if (tokenizer.after_terminator) try ctx.raw_positionals_after_terminator.append(allocator, tok.raw);
            },
            .long_flag => {
                try parseLongFlag(allocator, &ctx, dispatch.command, tok.raw, &tokenizer);
            },
            .short_flag => {
                try parseShortBundle(allocator, &ctx, dispatch.command, tok.raw, &tokenizer);
            },
        }
    }

    if (ctx.help_requested or ctx.short_help_requested or ctx.version_requested) {
        return .{ .context = ctx };
    }

    try validatePositionals(&ctx);
    try validateRequiredFlags(&ctx);
    try validateExclusiveFlags(&ctx);
    return .{ .context = ctx };
}

const DispatchResult = struct {
    command: *Command,
    remaining: []const []const u8,
    help_for: ?*Command = null,
};

/// Resolves the active command by consuming command-path tokens from argv.
fn walkCommandPath(allocator: std.mem.Allocator, root: *Command, argv: []const []const u8) !DispatchResult {
    _ = allocator;
    var current = root;
    var idx: usize = 0;

    while (idx < argv.len) : (idx += 1) {
        const token = argv[idx];
        if (std.mem.eql(u8, token, "help")) {
            var help_target = current;
            var j = idx + 1;
            while (j < argv.len) : (j += 1) {
                help_target = help_target.findSubcommand(argv[j]) orelse break;
            }
            return .{ .command = help_target, .remaining = &.{}, .help_for = help_target };
        }
        if (std.mem.startsWith(u8, token, "-")) break;
        if (current.findSubcommand(token)) |next| {
            current = next;
            continue;
        }
        if (current.subcommands.items.len > 0 and current.positionals.items.len == 0) {
            return ParseError.UnknownCommand;
        }
        break;
    }
    return .{ .command = current, .remaining = argv[idx..] };
}

/// Parses a long flag token (`--name`, `--name=value`).
fn parseLongFlag(
    allocator: std.mem.Allocator,
    ctx: *ParseContext,
    command: *Command,
    raw: []const u8,
    tokenizer: *Tokenizer,
) !void {
    const body = raw[2..];
    if (std.mem.eql(u8, body, "help")) {
        ctx.help_requested = true;
        return;
    }
    if (std.mem.eql(u8, body, "version")) {
        if (!commandAllowsVersion(command)) return ParseError.UnknownFlag;
        ctx.version_requested = true;
        return;
    }

    // Handle --no-<name> for negatable boolean flags.
    if (std.mem.startsWith(u8, body, "no-")) {
        const neg_name = body[3..];
        if (command.resolveFlagByName(neg_name)) |lookup| {
            const flag = lookup.command.flags.constSlice()[lookup.index];
            if (flag.negatable and flag.value_type == .bool) {
                try setFlagValue(allocator, ctx, flag, .{ .bool = false });
                return;
            }
        }
    }

    var name = body;
    var attached_value: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
        name = body[0..eq];
        attached_value = body[eq + 1 ..];
    }

    const lookup = command.resolveFlagByName(name) orelse return ParseError.UnknownFlag;
    const flag = lookup.command.flags.constSlice()[lookup.index];
    try parseFlagValue(allocator, ctx, flag, attached_value, tokenizer);
}

/// Parses short options with POSIX bundling rules.
fn parseShortBundle(
    allocator: std.mem.Allocator,
    ctx: *ParseContext,
    command: *Command,
    raw: []const u8,
    tokenizer: *Tokenizer,
) !void {
    const body = raw[1..];
    var eq_index: ?usize = null;
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| eq_index = eq;
    const flags_part = if (eq_index) |eq| body[0..eq] else body;
    const attached_all = if (eq_index) |eq| body[eq + 1 ..] else null;

    var i: usize = 0;
    var consumed_attached_value = false;
    while (i < flags_part.len) : (i += 1) {
        const ch = flags_part[i];
        if (ch == 'h') {
            ctx.short_help_requested = true;
            continue;
        }
        if (ch == 'V') {
            if (!commandAllowsVersion(command)) return ParseError.UnknownFlag;
            ctx.version_requested = true;
            continue;
        }

        const lookup = command.resolveFlagByShort(ch) orelse return ParseError.UnknownFlag;
        const flag = lookup.command.flags.constSlice()[lookup.index];
        if (!flag.takesValue()) {
            try setFlagValue(allocator, ctx, flag, .{ .bool = true });
            continue;
        }

        const tail = if (i + 1 < flags_part.len) flags_part[i + 1 ..] else null;
        const candidate = if (attached_all) |v| v else if (tail) |t| t else null;
        consumed_attached_value = attached_all != null or tail != null;
        try parseFlagValue(allocator, ctx, flag, candidate, tokenizer);
        return;
    }

    if (attached_all != null and !consumed_attached_value) {
        return ParseError.UnexpectedValueForBool;
    }
}

/// Parses and validates typed flag values.
fn parseFlagValue(
    allocator: std.mem.Allocator,
    ctx: *ParseContext,
    flag: Command.Flag,
    attached_value: ?[]const u8,
    tokenizer: *Tokenizer,
) !void {
    switch (flag.value_type) {
        .bool => {
            if (attached_value != null) return ParseError.UnexpectedValueForBool;
            try setFlagValue(allocator, ctx, flag, .{ .bool = true });
        },
        .string => {
            const value = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            try validateEnum(flag, value);
            try setFlagValue(allocator, ctx, flag, .{ .string = value });
        },
        .enum_tag => {
            const value = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            const allowed = flag.allowed_values orelse return ParseError.InvalidEnumValue;
            const enum_values = flag.enum_values orelse return ParseError.InvalidEnumValue;
            for (allowed, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, value)) {
                    try setFlagValue(allocator, ctx, flag, .{ .enum_tag = enum_values[i] });
                    return;
                }
            }
            return ParseError.InvalidEnumValue;
        },
        .int => {
            const raw = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            const parsed = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidInt;
            try setFlagValue(allocator, ctx, flag, .{ .int = parsed });
        },
        .float => {
            const raw = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            const parsed = std.fmt.parseFloat(f64, raw) catch return ParseError.InvalidFloat;
            try setFlagValue(allocator, ctx, flag, .{ .float = parsed });
        },
        .string_list => {
            const value = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            try validateEnum(flag, value);
            if (ctx.flags.getPtr(flag.name)) |existing| {
                switch (existing.*) {
                    .string_list => |*list| try list.append(allocator, value),
                    else => {
                        var list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                        try list.append(allocator, value);
                        existing.* = .{ .string_list = list };
                    },
                }
                return;
            }
            var list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            try list.append(allocator, value);
            try ctx.flags.put(flag.name, .{ .string_list = list });
        },
        .key_value_list => {
            const raw = attached_value orelse nextValueToken(tokenizer) orelse return ParseError.MissingFlagValue;
            const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return ParseError.KeyValueMissingEquals;
            const key = raw[0..eq_idx];
            const value = raw[eq_idx + 1 ..];
            if (key.len == 0) return ParseError.KeyValueEmptyKey;
            if (value.len == 0) return ParseError.KeyValueEmptyValue;

            if (flag.allowed_keys) |allowed_keys| {
                var key_ok = false;
                for (allowed_keys) |candidate| {
                    if (std.mem.eql(u8, candidate, key)) {
                        key_ok = true;
                        break;
                    }
                }
                if (!key_ok) return ParseError.InvalidAllowedKey;
            }
            if (flag.allowed_values) |allowed_values| {
                var value_ok = false;
                for (allowed_values) |candidate| {
                    if (std.mem.eql(u8, candidate, value)) {
                        value_ok = true;
                        break;
                    }
                }
                if (!value_ok) return ParseError.InvalidAllowedValue;
            }

            if (ctx.flags.getPtr(flag.name)) |existing| {
                switch (existing.*) {
                    .key_value_list => |*list| try list.append(allocator, .{ .key = key, .value = value }),
                    else => {
                        var list = try std.ArrayList(Command.KeyValuePair).initCapacity(allocator, 0);
                        try list.append(allocator, .{ .key = key, .value = value });
                        existing.* = .{ .key_value_list = list };
                    },
                }
                return;
            }

            var list = try std.ArrayList(Command.KeyValuePair).initCapacity(allocator, 0);
            try list.append(allocator, .{ .key = key, .value = value });
            try ctx.flags.put(flag.name, .{ .key_value_list = list });
        },
    }
}

/// Returns the next raw token as a value payload.
fn nextValueToken(tokenizer: *Tokenizer) ?[]const u8 {
    if (tokenizer.cursor >= tokenizer.argv.len) return null;
    const next_raw = tokenizer.argv[tokenizer.cursor];
    tokenizer.cursor += 1;
    return next_raw;
}

/// Inserts or replaces parsed flag value in the context map.
fn setFlagValue(allocator: std.mem.Allocator, ctx: *ParseContext, flag: Command.Flag, value: ParseContext.FlagValue) !void {
    if (ctx.flags.getPtr(flag.name)) |existing| {
        existing.deinit(allocator);
        existing.* = value;
        return;
    }
    try ctx.flags.put(flag.name, value);
}

/// Validates value against allowed-values enum list when present.
fn validateEnum(flag: Command.Flag, value: []const u8) !void {
    const allowed = flag.allowed_values orelse return;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return;
    }
    return ParseError.InvalidEnumValue;
}

fn commandAllowsVersion(command: *const Command) bool {
    return command.parent == null and command.rootConst().version != null;
}

/// Seeds the context with default values for visible flags.
fn applyDefaults(ctx: *ParseContext, command: *Command) !void {
    var chain = try command.collectAncestorPath(ctx.allocator);
    defer chain.deinit(ctx.allocator);

    for (chain.items) |cmd| {
        for (cmd.flags.constSlice()) |flag| {
            if (cmd != command and !flag.persistent) continue;
            if (ctx.flags.contains(flag.name)) continue;
            if (flag.default_value) |default_value| {
                switch (default_value) {
                    .bool => |v| try ctx.flags.put(flag.name, .{ .bool = v }),
                    .string => |v| try ctx.flags.put(flag.name, .{ .string = v }),
                    .int => |v| try ctx.flags.put(flag.name, .{ .int = v }),
                    .float => |v| try ctx.flags.put(flag.name, .{ .float = v }),
                    .enum_tag => |v| try ctx.flags.put(flag.name, .{ .enum_tag = v }),
                    .string_list => |items| {
                        var list = try std.ArrayList([]const u8).initCapacity(ctx.allocator, 0);
                        for (items) |item| try list.append(ctx.allocator, item);
                        try ctx.flags.put(flag.name, .{ .string_list = list });
                    },
                }
            } else if (flag.value_type == .bool) {
                try ctx.flags.put(flag.name, .{ .bool = false });
            }
        }
    }
}

/// Validates positional arity, requireds, and variadic policy.
fn validatePositionals(ctx: *ParseContext) !void {
    const defs = ctx.command.positionals.items;
    const got = ctx.positionals.items.len;

    var required_count: usize = 0;
    for (defs) |pos| {
        if (pos.required) required_count += 1;
    }
    if (got < required_count) return ParseError.MissingRequiredPositional;

    if (ctx.command.min_positionals) |min| {
        if (got < min) return ParseError.MissingRequiredPositional;
    }
    if (ctx.command.max_positionals) |max| {
        if (got > max) return ParseError.TooManyPositionals;
    }

    const has_variadic = defs.len > 0 and defs[defs.len - 1].variadic;
    if (!has_variadic and defs.len > 0 and got > defs.len) return ParseError.TooManyPositionals;
}

/// Validates required flags for local and inherited persistent scope.
fn validateRequiredFlags(ctx: *ParseContext) !void {
    var chain = try ctx.command.collectAncestorPath(ctx.allocator);
    defer chain.deinit(ctx.allocator);

    for (chain.items) |cmd| {
        for (cmd.flags.constSlice()) |flag| {
            if (cmd != ctx.command and !flag.persistent) continue;
            if (flag.required and !ctx.flags.contains(flag.name)) {
                return ParseError.MissingRequiredFlag;
            }
        }
    }
}

/// Validates mutually-exclusive flag groups.
fn validateExclusiveFlags(ctx: *ParseContext) !void {
    for (ctx.command.exclusive_groups.items) |group| {
        var count: usize = 0;
        for (group.names) |name| {
            if (ctx.flags.contains(name)) count += 1;
        }
        if (count > 1) return ParseError.MutuallyExclusiveFlags;
    }
}

/// Creates a user-facing diagnostic for parser errors.
pub fn diagnoseError(
    allocator: std.mem.Allocator,
    root: *Command,
    argv: []const []const u8,
    err: ParseError,
) !Diagnostic {
    return switch (err) {
        error.UnknownCommand => diagnoseUnknownCommand(allocator, root, argv),
        error.UnknownFlag => diagnoseUnknownFlag(allocator, root, argv),
        error.MissingFlagValue => makeDiagnostic(allocator, "missing value for flag", null),
        error.MissingRequiredFlag => makeDiagnostic(allocator, "missing required flag", null),
        error.MissingRequiredPositional => makeDiagnostic(allocator, "missing required positional argument", null),
        error.TooManyPositionals => makeDiagnostic(allocator, "too many positional arguments", null),
        error.InvalidInt => makeDiagnostic(allocator, "expected int value for flag", null),
        error.InvalidFloat => makeDiagnostic(allocator, "expected float value for flag", null),
        error.InvalidEnumValue => makeDiagnostic(allocator, "invalid value; expected one of allowed values", null),
        error.KeyValueMissingEquals => makeDiagnostic(allocator, "expected key=value for flag", null),
        error.KeyValueEmptyKey => makeDiagnostic(allocator, "key=value flag key cannot be empty", null),
        error.KeyValueEmptyValue => makeDiagnostic(allocator, "key=value flag value cannot be empty", null),
        error.InvalidAllowedKey => makeDiagnostic(allocator, "invalid key; expected one of allowed keys", null),
        error.InvalidAllowedValue => makeDiagnostic(allocator, "invalid value; expected one of allowed values", null),
        error.UnexpectedValueForBool => makeDiagnostic(allocator, "boolean flag does not accept a value", null),
        error.MutuallyExclusiveFlags => makeDiagnostic(allocator, "mutually exclusive flags were provided together", null),
    };
}

/// Builds unknown-command diagnostic with optional typo hint.
fn diagnoseUnknownCommand(allocator: std.mem.Allocator, root: *Command, argv: []const []const u8) !Diagnostic {
    var current = root;
    var unknown: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.startsWith(u8, token, "-")) break;
        if (current.findSubcommand(token)) |sub| {
            current = sub;
            continue;
        }
        unknown = token;
        break;
    }

    if (unknown) |token| {
        var names = try std.ArrayList([]const u8).initCapacity(allocator, current.subcommands.items.len);
        defer names.deinit(allocator);
        for (current.subcommands.items) |sub| try names.append(allocator, sub.name);
        const suggestion = Suggest.closest(token, names.items);

        const message = try std.fmt.allocPrint(allocator, "unknown command '{s}'", .{token});
        const hint = if (suggestion) |match| try std.fmt.allocPrint(allocator, "did you mean '{s}'?", .{match}) else null;
        return .{ .allocator = allocator, .message = message, .hint = hint };
    }

    return makeDiagnostic(allocator, "unknown command", null);
}

/// Builds unknown-flag diagnostic with optional typo hint.
fn diagnoseUnknownFlag(allocator: std.mem.Allocator, root: *Command, argv: []const []const u8) !Diagnostic {
    const command = detectTargetCommand(root, argv);
    const token = findUnknownFlagToken(argv) orelse return makeDiagnostic(allocator, "unexpected flag", null);

    const normalized = normalizeFlagToken(token);
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer names.deinit(allocator);
    try collectVisibleFlagNames(allocator, command, &names);

    const suggestion = Suggest.closest(normalized, names.items);
    const message = try std.fmt.allocPrint(allocator, "unexpected flag '{s}'", .{token});
    const hint = if (suggestion) |match| try std.fmt.allocPrint(allocator, "did you mean '--{s}'?", .{match}) else null;
    return .{ .allocator = allocator, .message = message, .hint = hint };
}

/// Detects active command path from argv for diagnostics.
fn detectTargetCommand(root: *Command, argv: []const []const u8) *Command {
    var current = root;
    for (argv) |token| {
        if (std.mem.startsWith(u8, token, "-")) break;
        const sub = current.findSubcommand(token) orelse break;
        current = sub;
    }
    return current;
}

/// Finds candidate unknown flag token from argv.
fn findUnknownFlagToken(argv: []const []const u8) ?[]const u8 {
    for (argv) |token| {
        if (std.mem.startsWith(u8, token, "--") and !std.mem.eql(u8, token, "--")) return token;
        if (std.mem.startsWith(u8, token, "-") and token.len > 1 and !std.mem.eql(u8, token, "-h")) return token;
    }
    return null;
}

/// Removes flag sigils and attached value from a raw flag token.
fn normalizeFlagToken(token: []const u8) []const u8 {
    var out = token;
    if (std.mem.startsWith(u8, out, "--")) out = out[2..] else if (std.mem.startsWith(u8, out, "-")) out = out[1..];
    if (std.mem.indexOfScalar(u8, out, '=')) |idx| return out[0..idx];
    return out;
}

/// Collects visible long-flag names for typo suggestions.
fn collectVisibleFlagNames(allocator: std.mem.Allocator, command: *Command, out: *std.ArrayList([]const u8)) !void {
    var chain = try command.collectAncestorPath(allocator);
    defer chain.deinit(allocator);
    for (chain.items) |cmd| {
        for (cmd.flags.constSlice()) |flag| {
            if (cmd != command and !flag.persistent) continue;
            try out.append(allocator, flag.name);
        }
    }
}

/// Creates an owned diagnostic by duplicating message/hint strings.
fn makeDiagnostic(allocator: std.mem.Allocator, message: []const u8, hint: ?[]const u8) !Diagnostic {
    return .{
        .allocator = allocator,
        .message = try allocator.dupe(u8, message),
        .hint = if (hint) |h| try allocator.dupe(u8, h) else null,
    };
}
