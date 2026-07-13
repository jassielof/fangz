const std = @import("std");

const Command = @import("../Command.zig");
const Example = @import("Example.zig");
const Flag = @import("Flag.zig");

name: []const u8,
short: []const u8,
long_display: []const u8,
full_signature: []const u8,
/// Short help (`Flag.brief`).
brief: []const u8,
/// Long prose (`Flag.description`).
description: []const u8,
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
flag_examples: []Example,
kv_examples: []Example,

pub fn deinit(self: *Flag, allocator: std.mem.Allocator) void {
    if (self.value_hint_owned) |s| allocator.free(s);
    allocator.free(self.short);
    allocator.free(self.long_display);
    allocator.free(self.full_signature);
    allocator.free(self.default_value);
    if (self.flag_examples.len > 0) {
        for (self.flag_examples) |*ex| ex.deinit(allocator);
        allocator.free(self.flag_examples);
    }
    if (self.kv_examples.len > 0) {
        for (self.kv_examples) |*ex| ex.deinit(allocator);
        allocator.free(self.kv_examples);
    }
}
