//! Top-level Fangz error set definitions.

const std = @import("std");

const Parser = @import("Parser.zig");

/// Aggregate error set surfaced by public Fangz APIs.
// TODO: This should be renamed to something else, as just errors or not just FangzError, it's too generic, error sets need to be named representing the set of errors they get thrown for.
pub const FangzError = std.mem.Allocator.Error || Parser.ParseError || error{
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
