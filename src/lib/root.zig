//! Fangz is a command-line parser for Zig 0.15.
//!
//! The API follows explicit, struct-based configuration similar to Cobra.

pub const App = @import("App.zig");
pub const Command = @import("Command.zig");
pub const KeyValuePair = Command.KeyValuePair;
pub const KeyValueList = Command.KeyValueList;
pub const DocGenerator = @import("DocGenerator.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const ParseContext = @import("ParseContext.zig");
pub const FangzError = @import("error.zig").FangzError;
/// Supported shell targets for completion script generation.
pub const Shell = @import("Completion.zig").Shell;
