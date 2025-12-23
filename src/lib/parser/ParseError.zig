const ParseError = @This();

const std = @import("std");
const builtin = @import("builtin");
const Command = @import("../Command.zig");

/// Detailed information of error.
context: Context,

/// Creates a new error with an empty context.
pub fn init() ParseError {
    return ParseError{ .context = .none };
}

/// Sets the new error context.
pub fn setContext(self: *ParseError, ctx: Context) void {
    self.context = ctx;
}

/// Prints the error context in a nice error message.
/// If command is provided, uses its custom error writer (traverses up parent chain if needed).
pub fn print(self: *const ParseError, command: ?*const Command) PrintError!void {
    // Use command's error writer if available, otherwise fall back to stderr
    const err_writer = if (command) |cmd| cmd.errOrStderr() else blk: {
        var buffer: [0]u8 = undefined;
        const writer = std.fs.File.stderr().writer(&buffer);
        break :blk std.io.wrapWriter(writer);
    };
    const writer = &err_writer;

    // Print the error prefix for nicer output.
    try writer.writeAll("error: ");

    switch (self.context) {
        .none => {
            if (builtin.is_test) {
                return error.ParseErrorPrintReceivesAnEmptyContext;
            }
            return;
        },
        .unrecognized_command => |cmd_name| {
            try writer.print("unrecognized command '{s}'\n", .{cmd_name});
        },
        .positional_argument_not_provided => |cmd_name| {
            try writer.print("positional argument is missing for command '{s}'\n", .{cmd_name});
        },
        .subcommand_not_provided => |cmd_name| {
            try writer.print("subcommand is missing for command '{s}'\n", .{cmd_name});
        },
        .unrecognized_option => |option| {
            try writer.print("unrecognized option '{s}'\n", .{option});
        },
        .option_value_not_provided => |ctx| {
            try writer.print("a value is missing for option '{f}'\n", .{ctx.option});

            if (ctx.valid_values) |valid_values| {
                try writer.writeByte('\n');
                try writer.writeAll("help: valid values are:\n");

                for (valid_values) |valid_value| {
                    try writer.print("\t-> {s}\n", .{valid_value});
                }
            }
        },
        .unexpected_option_value => |ctx| {
            try writer.print(
                "a value '{s}' was not expected for option '{f}'\n",
                .{ ctx.value, ctx.option },
            );
        },
        .empty_option_value => |ctx| {
            try writer.print("empty value was not expected for option '{f}'\n", .{ctx.option});

            if (ctx.valid_values) |valid_values| {
                try writer.writeByte('\n');
                try writer.writeAll("help: valid values are:\n");

                for (valid_values) |valid_value| {
                    try writer.print("\t-> {s}\n", .{valid_value});
                }
            }
        },
        .invalid_option_value => |ctx| {
            try writer.print(
                "'{s}' is invalid value for option '{f}'\n\n",
                .{ ctx.invalid_value, ctx.option },
            );
            try writer.writeAll("help: valid values are:\n");

            for (ctx.valid_values) |valid_value| {
                try writer.print("\t-> {s}\n", .{valid_value});
            }
        },
        .too_few_option_value => |ctx| {
            try writer.print(
                "minimum of '{d}' values were expected for option '{f}'\n\n",
                .{ ctx.min_values, ctx.option },
            );
            try writer.print(
                "help: try adding '{d}' more value/s\n",
                .{ctx.min_values - ctx.num_values},
            );
        },
        .too_many_option_value => |ctx| {
            try writer.print(
                "only upto '{d}' values were expected for option '{f}'\n\n",
                .{ ctx.max_values, ctx.option },
            );
            try writer.print(
                "help: try reducing '{d}' value/s\n",
                .{ctx.num_values - ctx.max_values},
            );
        },
    }
    try writer.writeAll("\nhelp: invoke the command with '-h/--h' flag to learn more.\n");
    try writer.flush();
}

/// An error type returned by the `print`.
pub const PrintError = std.fs.File.WriteError || std.Io.Writer.Error;
/// An error type returned by the parser.
pub const Error = error{
    UnrecognizedCommand,
    PositionalArgumentNotProvided,
    SubcommandNotProvided,
    UnrecognizedOption,
    OptionValueNotProvided,
    UnexpectedOptionValue,
    EmptyOptionValue,
    InvalidOptionValue,
    TooFewOptionValue,
    TooManyOptionValue,
};

/// Represents the error context.
///
/// This is used to store the error payload related to each error.
pub const Context = union(enum) {
    /// Unknown or undefined context.
    none,
    /// An unrecognized command.
    unrecognized_command: []const u8,
    /// A command which was expecting a positional argument..
    positional_argument_not_provided: []const u8,
    /// A command which was expecting a subcommand.
    subcommand_not_provided: []const u8,
    /// An unrecognized option (long or short).
    unrecognized_option: []const u8,
    /// Name of an option which was expecting a value.
    option_value_not_provided: struct {
        option: Option,
        /// List of acceptable values for an option.
        valid_values: ?[]const []const u8,
    },
    /// A specified value for an option which was not expected.
    unexpected_option_value: struct {
        option: Option,
        /// Value which was provided.
        value: []const u8,
    },
    /// An option was expecting non-empty value.
    empty_option_value: struct {
        option: Option,
        /// List of acceptable values.
        valid_values: ?[]const []const u8,
    },
    /// An invalid value for an option.
    invalid_option_value: struct {
        option: Option,
        /// Specified value.
        invalid_value: []const u8,
        /// List of acceptable values.
        valid_values: []const []const u8,
    },
    /// Specified values are not enough for an option.
    too_few_option_value: struct {
        option: Option,
        /// How much values were provided?.
        num_values: usize,
        /// Minimum number of values required for an option.
        min_values: usize,
    },
    /// Specified values exceed the upper limitation.
    too_many_option_value: struct {
        option: Option,
        /// How many values were provided?.
        num_values: usize,
        /// Upper limitation.
        max_values: usize,
    },
};

/// Represents an option that the parser failed to parse.
pub const Option = struct {
    /// Short name of an option.
    short_name: ?u8 = null,
    /// Long name of an option.
    long_name: ?[]const u8 = null,

    pub fn init(short_name: ?u8, long_name: ?[]const u8) Option {
        return Option{ .short_name = short_name, .long_name = long_name };
    }

    pub fn format(self: Option, writer: *std.Io.Writer) !void {
        if (self.short_name != null and self.long_name != null) {
            try writer.print("-{c}/--{s}", .{ self.short_name.?, self.long_name.? });
        } else if (self.short_name) |short_name| {
            try writer.print("-{c}", .{short_name});
        } else if (self.long_name) |long_name| {
            try writer.print("--{s}", .{long_name});
        }
        try writer.flush();
    }
};
