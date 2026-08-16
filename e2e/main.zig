//! End-to-end sample application used to exercise Fangz as a dependency.

const std = @import("std");
const fangz = @import("fangz");

const Output = enum { text, json };

pub fn main(init: std.process.Init) !void {
    var app = try fangz.App.init(init.gpa, init.io, .{
        .brief = "Fangz end-to-end sample application",
        .description = "A representative command tree used to validate generated shell completions.",
        .version = "1.0.0",
    });
    defer app.deinit();

    const root = app.root();
    try root.addFlag(bool, .{
        .name = "verbose",
        .short = 'v',
        .brief = "Enable verbose output.",
        .negatable = true,
    });

    const project = try root.addSubcommand(.{
        .name = "project",
        .brief = "Manage projects.",
    });
    const project_init = try project.addSubcommand(.{
        .name = "init",
        .brief = "Create a project.",
    });
    try project_init.addPositional(.{
        .name = "directory",
        .brief = "Directory for the new project.",
        .required = true,
    });
    try project_init.addFlag(Output, .{
        .name = "output",
        .short = 'o',
        .brief = "Select the output format.",
        .default = .text,
    });

    const deploy = try root.addSubcommand(.{
        .name = "deploy",
        .brief = "Deploy a project.",
    });
    try deploy.addPositional(.{
        .name = "environment",
        .brief = "Deployment environment.",
        .required = true,
        .allowed_values = &.{ "staging", "production" },
    });
    try deploy.addFlag([]const u8, .{
        .name = "region",
        .short = 'r',
        .brief = "Target deployment region.",
    });

    try app.executeProcess(init.minimal.args);
}
