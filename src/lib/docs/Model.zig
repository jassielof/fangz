const std = @import("std");

const Command = @import("../Command.zig");
const CommandDoc = @import("Command.zig");
const Model = @import("Model.zig");

binary_name: []const u8,
display_name: []const u8,
title: []const u8,
tagline: []const u8,
subtitle: []const u8,
description: []const u8,
version: []const u8,
author_name: []const u8 = "",
author_email: []const u8 = "",
git_branch: []const u8 = "",
git_commit: []const u8 = "",
git_ref: []const u8,
source_date: []const u8 = "",
app_name_attribute: []const u8,
toc: []const u8,
app_examples: []const Command.CliExample,
/// AsciiDoc anchor for `doc help` (xref target).
help_command_anchor: []const u8,
root: CommandDoc,
/// Subcommands and `help` — excludes the root entry; used for the reference section without duplicating root.
subcommand_reference: []const CommandDoc,
commands_flat: []CommandDoc,

pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
    allocator.free(self.title);
    allocator.free(self.git_ref);
    allocator.free(self.help_command_anchor);
    for (self.commands_flat) |*cmd| cmd.deinit(allocator);
    allocator.free(self.commands_flat);
}
