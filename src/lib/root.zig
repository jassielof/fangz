//! Fangz is a command-line parser library.

pub const App = @import("App.zig");
pub const Command = @import("Command.zig");
pub const KeyValuePair = Command.KeyValuePair;
pub const KeyValueList = Command.KeyValueList;
pub const DocGenerator = @import("DocGenerator.zig");
pub const FangzError = @import("error.zig").FangzError;
pub const ParseContext = @import("ParseContext.zig");
/// Supported shell targets for completion script generation.
pub const Shell = @import("Completion.zig").Shell;
pub const Tokenizer = @import("Tokenizer.zig");
