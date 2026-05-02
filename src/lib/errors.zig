//! Error sets.

const std = @import("std");

const Parser = @import("Parser.zig");

/// Aggregate error set surfaced by public Fangz APIs.
pub const Error = std.mem.Allocator.Error || Parser.ParseError || error{
    DuplicateFlag,
    DuplicateAlias,
    MultipleVariadicPositionals,
    VariadicMustBeLast,
    InvalidFlagConfiguration,
    /// Returned when a command already has MAX_INLINE_FLAGS registered flags.
    TooManyFlags,
    /// Returned when a mutation (addFlag, addSubcommand, …) is attempted after freeze().
    FrozenCommand,
};
