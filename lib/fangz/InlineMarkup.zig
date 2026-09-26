//! AsciiDoc-style inline formatting for terminal help text.
//!
//! Help text is written in AsciiDoc, so it can carry `code` (backticks), *bold* (asterisks), and _italic_ (underscores). The generated documentation keeps that markup as-is; this module makes the terminal render it too.
//!
//! The rules are AsciiDoc's constrained formatting: a mark only opens a span at a word boundary with non-space text right after it, and only closes it right before a word boundary. Marks that do not form a span, like the backtick in "Print`help" or the underscore in "Print_text", are ordinary text and are printed unchanged.

const std = @import("std");

const carnaval = @import("carnaval");
const ColorProfile = carnaval.ColorProfile;

/// Returns `text` with its inline markup rendered as terminal styling; the caller owns the result.
///
/// With `.none` the text is returned untouched (markers included) because there is nothing to style with, and plain markup still reads fine. Under `.ascii` colors are unavailable, so code spans keep their backticks instead of losing every visual cue.
pub fn render(allocator: std.mem.Allocator, text: []const u8, profile: ColorProfile) ![]u8 {
    if (profile == .none) return allocator.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const mark = text[index];
        if (isMark(mark) and opensSpan(text, index)) {
            if (findClose(text, index)) |close| {
                try appendSpan(allocator, &out, mark, text[index + 1 .. close], profile);
                index = close + 1;
                continue;
            }
        }

        try out.append(allocator, mark);
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn isMark(byte: u8) bool {
    return byte == '`' or byte == '*' or byte == '_';
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn opensSpan(text: []const u8, index: usize) bool {
    const before_ok = index == 0 or !isWordByte(text[index - 1]);
    if (!before_ok) return false;

    if (index + 1 >= text.len) return false;
    const next = text[index + 1];
    return !std.ascii.isWhitespace(next) and next != text[index];
}

fn closesSpan(text: []const u8, index: usize) bool {
    if (std.ascii.isWhitespace(text[index - 1])) return false;
    return index + 1 == text.len or !isWordByte(text[index + 1]);
}

fn findClose(text: []const u8, open: usize) ?usize {
    const mark = text[open];
    var index = open + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] == mark and closesSpan(text, index)) return index;
    }
    return null;
}

fn appendSpan(allocator: std.mem.Allocator, out: *std.ArrayList(u8), mark: u8, inner: []const u8, profile: ColorProfile) !void {
    if (mark == '`' and profile == .ascii) {
        try out.append(allocator, '`');
        try out.appendSlice(allocator, inner);
        try out.append(allocator, '`');
        return;
    }

    const style = switch (mark) {
        '`' => carnaval.Style.init().fg(.{ .ansi16 = .cyan }),
        '*' => carnaval.Style.init().bolded(),
        else => carnaval.Style.init().italicized(),
    };

    const styled = try style.renderAllocWithProfile(inner, allocator, profile);
    defer allocator.free(styled);
    try out.appendSlice(allocator, styled);
}

/// Removes SGR escape sequences so tests can compare the visible text.
fn stripSgr(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len and text[index] != 'm') : (index += 1) {}
            index += 1;
            continue;
        }
        try out.append(allocator, text[index]);
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn expectVisible(profile: ColorProfile, input: []const u8, expected_visible: []const u8, expect_styled: bool) !void {
    const allocator = std.testing.allocator;

    const rendered = try render(allocator, input, profile);
    defer allocator.free(rendered);
    const visible = try stripSgr(allocator, rendered);
    defer allocator.free(visible);

    try std.testing.expectEqualStrings(expected_visible, visible);
    try std.testing.expectEqual(expect_styled, std.mem.indexOfScalar(u8, rendered, 0x1b) != null);
}

test "spans render without their markers" {
    try expectVisible(.ansi16, "run `typm list` now", "run typm list now", true);
    try expectVisible(.ansi16, "a *bold* word", "a bold word", true);
    try expectVisible(.ansi16, "an _italic_ word", "an italic word", true);
    try expectVisible(.ansi16, "`code`, *bold*, and _italic_.", "code, bold, and italic.", true);
}

test "spans may touch punctuation" {
    try expectVisible(.ansi16, "(`--force`)", "(--force)", true);
    try expectVisible(.ansi16, "see `<output-dir>/<name>`, then stop", "see <output-dir>/<name>, then stop", true);
}

test "marks that do not form a span are printed as-is" {
    try expectVisible(.ansi16, "Print`help", "Print`help", false);
    try expectVisible(.ansi16, "Print_text", "Print_text", false);
    try expectVisible(.ansi16, "use snake_case_names here", "use snake_case_names here", false);
    try expectVisible(.ansi16, "an `unclosed span", "an `unclosed span", false);
    try expectVisible(.ansi16, "2 * 3 * 4", "2 * 3 * 4", false);
    try expectVisible(.ansi16, "files like *.typ and *.toml", "files like *.typ and *.toml", false);
    try expectVisible(.ansi16, "trailing `", "trailing `", false);
}

test "code spans keep their contents literal" {
    try expectVisible(.ansi16, "`a_b*c` end", "a_b*c end", true);
}

test "no color profile leaves the markup alone" {
    try expectVisible(.none, "`code`, *bold*, and _italic_.", "`code`, *bold*, and _italic_.", false);
}

test "ascii profile styles emphasis but keeps backticks around code" {
    try expectVisible(.ascii, "`code` and *bold*", "`code` and bold", true);
}
