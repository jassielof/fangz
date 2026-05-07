const std = @import("std");

const Command = @import("../Command.zig");
const Flag = @import("Flag.zig");

name: []const u8,
short: []const u8,
long_display: []const u8,
full_signature: []const u8,
/// One-line summary (typically `Flag.description`).
description: []const u8,
/// Extra prose (`Flag.long_description`).
extended: []const u8,
type_name: []const u8,
required: bool,
required_text: []const u8,
default_value: []const u8,
has_default: bool,
scope: []const u8,
value_hint: []const u8,
value_hint_owned: ?[]const u8 = null,
possible_values: []const []const u8,
has_possible_values: bool,
is_bool: bool,
is_builtin: bool,
is_repeatable: bool,
has_key_value_metadata: bool,
kv_keys: []const Command.KeyValueKeyMeta,
kv_values: []const Command.KeyValueValueMeta,
kv_override_note: []const u8,
flag_examples: []const Command.CliExample,
kv_examples: []const Command.CliExample,

pub fn deinit(self: *Flag, allocator: std.mem.Allocator) void {
    if (self.value_hint_owned) |s| allocator.free(s);
    allocator.free(self.short);
    allocator.free(self.long_display);
    allocator.free(self.full_signature);
    allocator.free(self.default_value);
}
