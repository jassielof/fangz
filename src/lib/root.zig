//! Fangz is a command-line parser library.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

pub const App = @import("App.zig");
pub const Command = @import("Command.zig");
pub const KeyValuePair = Command.KeyValuePair;
pub const KeyValueList = Command.KeyValueList;
pub const DocGenerator = @import("DocGenerator.zig");
const errors = @import("errors.zig");
pub const FangzError = errors.FangzError;
pub const ParseContext = @import("ParseContext.zig");
pub const Shell = @import("Completion.zig").Shell;
pub const Tokenizer = @import("Tokenizer.zig");

comptime {
    refAllDecls(@This());
}
