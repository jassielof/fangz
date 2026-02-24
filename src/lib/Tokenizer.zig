//! Lightweight argv tokenizer used by the parser.
//!
//! The tokenizer classifies raw tokens into short/long flag, positional, and
//! terminator (`--`) categories while tracking terminator state.

const Tokenizer = @This();

const std = @import("std");

argv: []const []const u8,
cursor: usize = 0,
after_terminator: bool = false,

pub const TokenKind = enum {
    terminator,
    long_flag,
    short_flag,
    positional,
};

pub const Token = struct {
    kind: TokenKind,
    raw: []const u8,
};

/// Creates a tokenizer over argv tokens.
pub fn init(argv: []const []const u8) Tokenizer {
    return .{ .argv = argv };
}

/// Returns the next classified token, or null when exhausted.
pub fn next(self: *Tokenizer) ?Token {
    if (self.cursor >= self.argv.len) return null;
    const raw = self.argv[self.cursor];
    self.cursor += 1;

    if (self.after_terminator) return .{ .kind = .positional, .raw = raw };
    if (std.mem.eql(u8, raw, "--")) {
        self.after_terminator = true;
        return .{ .kind = .terminator, .raw = raw };
    }
    if (std.mem.startsWith(u8, raw, "--") and raw.len > 2) return .{ .kind = .long_flag, .raw = raw };
    if (std.mem.startsWith(u8, raw, "-") and raw.len > 1) return .{ .kind = .short_flag, .raw = raw };
    return .{ .kind = .positional, .raw = raw };
}

/// Returns the remaining unprocessed raw argv slice.
pub fn remaining(self: *Tokenizer) []const []const u8 {
    return self.argv[self.cursor..];
}
