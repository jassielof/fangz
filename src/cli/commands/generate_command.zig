const std = @import("std");
const fangz = @import("fangz");
const utils = @import("utils.zig");

pub fn register(generate_cmd: *fangz.Command) !void {
    const cmd = try generate_cmd.addSubcommand(.{
        .name = "command",
        .description = "Generate a command file in src/cli/commands",
        .group_id = "generate",
    });
    try cmd.addAlias("cmd");
    try cmd.addPositional(.{
        .name = "name",
        .description = "Command file name",
        .required = true,
    });
    try cmd.addFlag(.{
        .name = "description",
        .short = 'd',
        .description = "Command description text",
        .value_type = .string,
        .default_value = .{ .string = "Generated command" },
    });
    cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const name = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const description = ctx.stringFlag("description") orelse "Generated command";
    const dry_run = utils.isDryRun(ctx);

    const commands_dir = try utils.join3(allocator, utils.workDir(ctx), "src/cli", "commands");
    defer allocator.free(commands_dir);
    try utils.ensureDir(commands_dir, dry_run);

    const filename = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
    defer allocator.free(filename);
    const file_path = try utils.join2(allocator, commands_dir, filename);
    defer allocator.free(file_path);

    const template = try renderTemplate(allocator, name, description);
    defer allocator.free(template);
    try utils.writeNewFile(file_path, template, dry_run);

    std.debug.print("Generated {s}\n", .{file_path});
    std.debug.print("Wire it in your command registry (src/cli/commands/root.zig).\n", .{});
}

fn renderTemplate(allocator: std.mem.Allocator, name: []const u8, description: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\const fangz = @import("fangz");
        \\
        \\pub fn register(root: *fangz.Command) !void {{
        \\    const cmd = try root.addSubcommand(.{{
        \\        .name = "{s}",
        \\        .description = "{s}",
        \\    }});
        \\    cmd.setHooks(.{{ .run = run }});
        \\}}
        \\
        \\fn run(ctx: *fangz.ParseContext) !void {{
        \\    _ = ctx;
        \\}}
        \\
    , .{ name, description });
}
