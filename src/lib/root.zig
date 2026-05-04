//! Fangz is a command-line parser library.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

pub const App = @import("App.zig");
pub const Command = @import("Command.zig");
pub const CliExample = Command.CliExample;
pub const KeyValueHelp = Command.KeyValueHelp;
pub const KeyValueKeyMeta = Command.KeyValueKeyMeta;
pub const KeyValueValueMeta = Command.KeyValueValueMeta;
pub const KeyValuePair = Command.KeyValuePair;
pub const KeyValueList = Command.KeyValueList;
const completions = @import("completions/root.zig");
pub const Shell = completions.Shell;
pub const DocGenerator = @import("DocGenerator.zig");
pub const HelpRenderer = @import("HelpRenderer.zig");
const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const ParseContext = @import("ParseContext.zig");
pub const Parser = @import("Parser.zig");
pub const Tokenizer = @import("Tokenizer.zig");

comptime {
    refAllDecls(@This());
}
