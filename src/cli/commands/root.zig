const fangz = @import("fangz");
const init_cmd = @import("init.zig");
const generate_cmd = @import("generate.zig");
const docs_cmd = @import("docs.zig");

pub fn register(root: *fangz.Command) !void {
    root.setHelpOnEmptyArgs(true);
    try root.addGroup(.{ .id = "scaffold", .title = "Scaffolding" });

    try root.addFlag(.{
        .name = "cwd",
        .description = "Working directory for generated files",
        .value_type = .string,
        .default_value = .{ .string = "." },
        .persistent = true,
    });
    try root.addFlag(.{
        .name = "dry-run",
        .short = 'n',
        .description = "Preview filesystem actions without writing",
        .value_type = .bool,
        .default_value = .{ .bool = false },
        .persistent = true,
    });

    try init_cmd.register(root);
    try generate_cmd.register(root);
    try docs_cmd.register(root);
}
