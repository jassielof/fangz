const fangz = @import("fangz");
const generate_command = @import("generate_command.zig");

pub fn register(root: *fangz.Command) !void {
    const generate_cmd = try root.addSubcommand(.{
        .name = "generate",
        .description = "Code generators for Fangz projects",
        .group_id = "scaffold",
    });
    try generate_cmd.addAlias("gen");
    try generate_cmd.addGroup(.{ .id = "generate", .title = "Generators" });
    try generate_command.register(generate_cmd);
}
