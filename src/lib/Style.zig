//! ANSI style helper utilities for help and error rendering.

const std = @import("std");

pub const Color = enum {
    red,
    yellow,
    green,
    cyan,
    white,
};

pub const Style = struct {
    use_color: bool,

    /// Detects whether color output should be enabled for this process.
    pub fn detect() Style {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR")) |value| {
            std.heap.page_allocator.free(value);
            return .{ .use_color = false };
        } else |_| {}

        const stdout_file = std.fs.File.stdout();
        const tty_cfg = std.io.tty.detectConfig(stdout_file);
        return .{ .use_color = tty_cfg != .no_color };
    }

    /// Returns ANSI reset sequence (or empty string when color is disabled).
    pub fn reset(self: Style) []const u8 {
        if (!self.use_color) return "";
        return "\x1b[0m";
    }

    /// Returns ANSI bold sequence (or empty string when color is disabled).
    pub fn bold(self: Style) []const u8 {
        if (!self.use_color) return "";
        return "\x1b[1m";
    }

    /// Returns ANSI foreground sequence for the requested color.
    pub fn fg(self: Style, color: Color) []const u8 {
        if (!self.use_color) return "";
        return switch (color) {
            .red => "\x1b[31m",
            .yellow => "\x1b[33m",
            .green => "\x1b[32m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }
};
