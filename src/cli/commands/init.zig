const std = @import("std");
const fangz = @import("fangz");
const utils = @import("utils.zig");

pub fn register(root: *fangz.Command) !void {
    const init_cmd = try root.addSubcommand(.{
        .name = "init",
        .description = "Initialize a new CLI scaffold project",
        .group_id = "scaffold",
    });
    try init_cmd.addPositional(.{
        .name = "name",
        .description = "Project directory name",
        .required = true,
    });
    try init_cmd.addFlag(.{
        .name = "minimal",
        .description = "Create only core files",
        .value_type = .bool,
        .default_value = .{ .bool = false },
    });
    init_cmd.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const allocator = ctx.allocator;
    const project_name = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const dry_run = utils.isDryRun(ctx);
    const minimal = ctx.boolFlag("minimal") orelse false;

    const base = try utils.join2(allocator, utils.workDir(ctx), project_name);
    defer allocator.free(base);

    std.debug.print("Scaffolding '{s}' in {s}\n", .{ project_name, base });

    try utils.ensureDir(base, dry_run);

    const src_cli = try utils.join3(allocator, base, "src", "cli");
    defer allocator.free(src_cli);
    const src_cli_commands = try utils.join2(allocator, src_cli, "commands");
    defer allocator.free(src_cli_commands);
    const src_lib = try utils.join3(allocator, base, "src", "lib");
    defer allocator.free(src_lib);

    try utils.ensureDir(src_cli_commands, dry_run);
    try utils.ensureDir(src_lib, dry_run);
    if (!minimal) {
        const tests = try utils.join2(allocator, base, "tests");
        defer allocator.free(tests);
        try utils.ensureDir(tests, dry_run);
    }

    const build_path = try utils.join2(allocator, base, "build.zig");
    defer allocator.free(build_path);
    try utils.writeNewFile(build_path, buildTemplate(), dry_run);

    const main_path = try utils.join2(allocator, src_cli, "main.zig");
    defer allocator.free(main_path);
    try utils.writeNewFile(main_path, mainTemplate(project_name), dry_run);

    const root_lib_path = try utils.join2(allocator, src_lib, "root.zig");
    defer allocator.free(root_lib_path);
    try utils.writeNewFile(root_lib_path, libRootTemplate(), dry_run);

    const root_cmd_path = try utils.join2(allocator, src_cli_commands, "root.zig");
    defer allocator.free(root_cmd_path);
    try utils.writeNewFile(root_cmd_path, cliRootTemplate(), dry_run);

    if (!minimal) {
        const tests_path = try utils.join2(allocator, base, "tests/suite.zig");
        defer allocator.free(tests_path);
        try utils.writeNewFile(tests_path, testsTemplate(), dry_run);
    }

    std.debug.print("Done. Next: cd {s} && zig build\n", .{project_name});
}

fn buildTemplate() []const u8 {
    return 
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const mod = b.addModule("app", .{
    \\        .root_source_file = b.path("src/lib/root.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "app",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/cli/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\            .imports = &.{.{ .name = "app", .module = mod }},
    \\        }),
    \\    });
    \\    b.installArtifact(exe);
    \\}
    \\
    ;
}

fn mainTemplate(project_name: []const u8) []const u8 {
    _ = project_name;
    return 
    \\const std = @import("std");
    \\const app = @import("app");
    \\
    \\pub fn main() !void {
    \\    _ = app;
    \\    _ = std;
    \\}
    \\
    ;
}

fn libRootTemplate() []const u8 {
    return 
    \\pub const VERSION = "0.1.0";
    \\
    ;
}

fn cliRootTemplate() []const u8 {
    return 
    \\pub fn register() void {}
    \\
    ;
}

fn testsTemplate() []const u8 {
    return 
    \\test "placeholder" {}
    \\
    ;
}
