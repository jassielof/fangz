//! Top-level Fangz error set definitions.

const std = @import("std");
const Parser = @import("Parser.zig");

/// Aggregate error set surfaced by public Fangz APIs.
pub const FangzError = std.mem.Allocator.Error || Parser.ParseError || error{
    DuplicateFlag,
    DuplicateAlias,
    MultipleVariadicPositionals,
    VariadicMustBeLast,
};
