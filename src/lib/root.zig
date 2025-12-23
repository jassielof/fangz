//! Fangz is a command-line argument parser for Zig.

const std = @import("std");
pub const App = @import("App.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const Arg = @import("Arg.zig");
pub const ArgMatches = @import("ArgMatches.zig");
pub const Command = @import("Command.zig");
pub const yazap_error = @import("error.zig");
pub const YazapError = yazap_error.YazapError;
