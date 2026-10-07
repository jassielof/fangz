//! Error sets.

const std = @import("std");

const Parser = @import("Parser.zig");

/// Aggregate error set surfaced by public Fangz APIs.
pub const Error = std.mem.Allocator.Error || Parser.ParseError || error{
    DuplicateFlag,
    /// Same command already registers this short option letter on another flag.
    DuplicateShortFlag,
    DuplicateAlias,
    MultipleVariadicPositionals,
    VariadicMustBeLast,
    InvalidFlagConfiguration,
    /// Returned when a command already has MAX_INLINE_FLAGS registered flags.
    TooManyFlags,
    /// Returned when a mutation (addFlag, addSubcommand, …) is attempted after freeze().
    FrozenCommand,
};

/// When `err` is a [`Parser.ParseError`], returns it so callers can attach diagnostics.
///
/// Uses `@typeInfo(Parser.ParseError).error_set` so adding a variant to [`Parser.ParseError`] does not require updating a second manual list.
pub fn asParseError(err: Error) ?Parser.ParseError {
    const names = @typeInfo(Parser.ParseError).error_set.error_names orelse return null;
    inline for (names) |name| {
        const pe = @field(Parser.ParseError, name);
        if (err == pe) return pe;
    }
    return null;
}
