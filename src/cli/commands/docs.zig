const std = @import("std");
const fangz = @import("fangz");
const utils = @import("utils.zig");

pub fn register(root: *fangz.Command) !void {
    const docs = try root.addSubcommand(.{
        .name = "docs",
        .description = "Generate command documentation",
        .group_id = "scaffold",
    });

    try docs.addFlag(.{
        .name = "mode",
        .short = 'm',
        .description = "Doc mode: single or tree",
        .value_type = .string,
        .allowed_values = &.{ "single", "tree" },
        .default_value = .{ .string = "single" },
    });
    try docs.addFlag(.{
        .name = "output-dir",
        .short = 'o',
        .description = "Output directory for generated docs",
        .value_type = .string,
        .default_value = .{ .string = "docs" },
    });
    try docs.addFlag(.{
        .name = "file-name",
        .short = 'f',
        .description = "Single-file markdown name when mode=single",
        .value_type = .string,
        .default_value = .{ .string = "cli.md" },
    });
    try docs.addFlag(.{
        .name = "no-overwrite",
        .description = "Do not overwrite existing generated docs",
        .value_type = .bool,
        .default_value = .{ .bool = false },
    });

    docs.setHooks(.{ .run = run });
}

fn run(ctx: *fangz.ParseContext) !void {
    const root = ctx.command.root();
    const allocator = ctx.allocator;
    const dry_run = utils.isDryRun(ctx);

    const mode_raw = ctx.stringFlag("mode") orelse "single";
    const mode: fangz.DocGenerator.Mode = if (std.mem.eql(u8, mode_raw, "tree")) .per_command else .single_file;
    const output_dir = ctx.stringFlag("output-dir") orelse "docs";
    const file_name = ctx.stringFlag("file-name") orelse "cli.md";
    const overwrite = !(ctx.boolFlag("no-overwrite") orelse false);

    const opts = fangz.DocGenerator.Options{
        .mode = mode,
        .output_dir = output_dir,
        .single_file_name = file_name,
        .overwrite = overwrite,
    };

    if (dry_run) {
        if (mode == .single_file) {
            const path = try std.fs.path.join(allocator, &.{ output_dir, file_name });
            defer allocator.free(path);
            utils.logAction("generate docs single file {s}", .{path});
        } else {
            utils.logAction("generate docs command tree in {s}", .{output_dir});
        }
        return;
    }

    try fangz.DocGenerator.generateMarkdownDocs(allocator, root, opts);
    std.debug.print("Docs generated in {s}\n", .{output_dir});
}
