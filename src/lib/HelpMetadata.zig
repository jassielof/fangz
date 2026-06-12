//! Styled metadata lines for help option and argument rows.

const std = @import("std");

const carnaval = @import("carnaval");
const ColorProfile = carnaval.ColorProfile;

const Command = @import("Command.zig");

/// Metavar suffix for variadic positionals (`<paths>*` accepts multiple values in one slot).
pub const variadic_metavar_suffix = "*";

const ValuesLayout = enum { comma, bullet };

pub fn valuesLayout(style: Command.AllowedValuesStyle, count: usize) ValuesLayout {
    return switch (style) {
        .auto => if (count <= 3) .comma else .bullet,
        .comma => .comma,
        .bullet_list => .bullet,
    };
}

pub fn isRepeatableFlag(flag: Command.Flag) bool {
    return flag.value_type == .string_list or flag.value_type == .key_value_list;
}

pub fn renderPositionalMetadata(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    arg: Command.Positional,
    continuation_pad: usize,
) !void {
    if (arg.variadic) {
        try renderTagLine(writer, profile, continuation_pad, &.{ "Accepts multiple values" });
    }

    if (arg.allowed_values) |values| {
        if (values.len > 0) {
            try renderAllowedValues(
                writer,
                profile,
                continuation_pad,
                values,
                arg.allowed_value_labels,
                valuesLayout(arg.allowed_values_style, values.len),
                null,
            );
        }
    }
}

pub fn renderFlagMetadata(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    flag: Command.Flag,
    is_global: bool,
    continuation_pad: usize,
    enum_tag_name: []const u8,
) !void {
    var tags_buf: [4][]const u8 = undefined;
    var tag_count: usize = 0;

    if (flag.required) {
        tags_buf[tag_count] = "Required";
        tag_count += 1;
    }
    if (is_global) {
        tags_buf[tag_count] = "Global";
        tag_count += 1;
    }
    if (isRepeatableFlag(flag)) {
        tags_buf[tag_count] = "Repeatable";
        tag_count += 1;
    }

    if (tag_count > 0) {
        try renderTagLine(writer, profile, continuation_pad, tags_buf[0..tag_count]);
    }

    const default_in_list = defaultValueIndex(flag);

    if (flag.allowed_values) |values| {
        if (flag.value_type == .key_value_list and flag.allowed_keys != null) {
            return;
        }
        if (values.len > 0) {
            try renderAllowedValues(
                writer,
                profile,
                continuation_pad,
                values,
                flag.allowed_value_labels,
                valuesLayout(flag.allowed_values_style, values.len),
                default_in_list,
            );
        }
    }

    if (shouldRenderDefaultLine(flag, default_in_list)) {
        try renderDefaultLine(writer, profile, continuation_pad, flag, enum_tag_name);
    }
}

fn renderTagLine(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    pad: usize,
    tags: []const []const u8,
) !void {
    try printSpaces(writer, pad);
    for (tags, 0..) |tag, i| {
        if (i > 0) {
            try metaLabelStyle().renderWithProfile(" · ", writer, profile);
        }
        try metaTagStyle().renderWithProfile(tag, writer, profile);
    }
    try writer.print("\n", .{});
}

fn renderAllowedValues(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    pad: usize,
    values: []const []const u8,
    labels: ?[]const []const u8,
    layout: ValuesLayout,
    default_index: ?usize,
) !void {
    switch (layout) {
        .comma => {
            try printSpaces(writer, pad);
            try metaLabelStyle().renderWithProfile("Allowed", writer, profile);
            try writer.print(": ", .{});
            for (values, 0..) |value, i| {
                if (i > 0) try writer.print(", ", .{});
                try renderValueWithLabel(writer, profile, value, labels, i, default_index == i);
            }
            try writer.print("\n", .{});
        },
        .bullet => {
            try printSpaces(writer, pad);
            try metaLabelStyle().renderWithProfile("Allowed:", writer, profile);
            try writer.print("\n", .{});

            for (values, 0..) |value, i| {
                try printSpaces(writer, pad + 2);
                try metaLabelStyle().renderWithProfile("• ", writer, profile);
                try renderValueWithLabel(writer, profile, value, labels, i, default_index == i);
                try writer.print("\n", .{});
            }
        },
    }
}

fn renderValueWithLabel(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    value: []const u8,
    labels: ?[]const []const u8,
    index: usize,
    is_default: bool,
) !void {
    try metaValueStyle().renderWithProfile(value, writer, profile);
    if (is_default) {
        try writer.print(" ", .{});
        try metaTagStyle().renderWithProfile("(default)", writer, profile);
    }
    if (labels) |lbls| {
        if (index < lbls.len and lbls[index].len > 0) {
            try writer.print("  ", .{});
            try metaLabelStyle().renderWithProfile(lbls[index], writer, profile);
        }
    }
}

fn renderDefaultLine(
    writer: *std.Io.Writer,
    profile: ColorProfile,
    pad: usize,
    flag: Command.Flag,
    enum_tag_name: []const u8,
) !void {
    const dv = flag.default_value orelse return;

    var value_buf: [128]u8 = undefined;
    const value = switch (dv) {
        .bool => |v| if (v) "true" else "false",
        .string => |v| v,
        .int => |v| std.fmt.bufPrint(&value_buf, "{d}", .{v}) catch return,
        .float => |v| std.fmt.bufPrint(&value_buf, "{d}", .{v}) catch return,
        .enum_tag => enum_tag_name,
        .string_list => "set",
    };

    try printSpaces(writer, pad);
    try metaLabelStyle().renderWithProfile("Default", writer, profile);
    try writer.print(": ", .{});
    try metaValueStyle().renderWithProfile(value, writer, profile);
    try writer.print("\n", .{});
}

fn defaultValueIndex(flag: Command.Flag) ?usize {
    const dv = flag.default_value orelse return null;
    const values = flag.allowed_values orelse return null;
    if (values.len == 0) return null;

    switch (dv) {
        .enum_tag => |ordinal| {
            const ords = flag.enum_values orelse return null;
            for (ords, 0..) |ord, i| {
                if (ord == ordinal and i < values.len) return i;
            }
            return null;
        },
        else => return null,
    }
}

fn shouldRenderDefaultLine(flag: Command.Flag, default_in_list: ?usize) bool {
    if (flag.default_value == null) return false;
    if (default_in_list != null) return false;
    return true;
}

fn metaLabelStyle() carnaval.Style {
    return carnaval.Style.init().dimmed();
}

fn metaValueStyle() carnaval.Style {
    return carnaval.Style.init().fg(.{ .ansi16 = .yellow });
}

fn metaTagStyle() carnaval.Style {
    return carnaval.Style.init().dimmed().withItalic(true);
}

fn printSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.print(" ", .{});
    }
}
