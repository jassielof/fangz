//! A representative Fangz application used by the end-to-end build targets.
//!
//! The sample intentionally uses the public command-tree surface broadly so
//! generated help, documentation, and shell completions have a realistic CLI
//! to exercise.

const std = @import("std");
const fangz = @import("fangz");

const ColorMode = enum { auto, always, never };
const ProjectTemplate = enum { application, library, service };
const DeploymentStrategy = enum { rolling, canary, blue_green };
const LogLevel = enum { trace, debug, info, warn, err };
const OutputFormat = enum { text, json, yaml };

const root_examples = [_]fangz.CliExample{
    .{
        .description = "Create a service project with verbose output.",
        .command = "fangz --verbose project init api --template service",
    },
    .{
        .description = "Deploy two artifacts using a canary rollout.",
        .command = "fangz deploy production api.tar worker.tar --strategy canary --parallelism 2",
    },
};

const deploy_variable_help = fangz.KeyValueHelp{
    .keys = &.{
        .{
            .name = "feature",
            .default_value = "disabled",
            .summary = "Toggle a named feature for this deployment.",
            .description = "Feature switches are applied after the selected deployment strategy is configured.",
            .group = "Feature switches",
        },
        .{
            .name = "telemetry",
            .default_value = "enabled",
            .summary = "Enable or disable telemetry collection.",
            .group = "Runtime",
        },
        .{
            .name = "maintenance",
            .default_value = "disabled",
            .summary = "Put the service in maintenance mode during rollout.",
            .group = "Runtime",
        },
    },
    .values = &.{
        .{ .name = "enabled", .summary = "Enable the setting." },
        .{ .name = "disabled", .summary = "Disable the setting." },
    },
    .override_behavior_note = "Repeat a key to override an earlier value; the final occurrence wins.",
    .examples = &.{.{
        .description = "Disable telemetry for a canary deployment.",
        .command = "fangz deploy staging --variable telemetry=disabled --strategy canary",
    }},
};

pub fn main(init: std.process.Init) !void {
    var app = try fangz.App.init(init.gpa, init.io, .{
        .display_name = "Fangz Forge",
        .tagline = "A reference CLI for shipping project workspaces.",
        .brief = "Manage projects, releases, and operational tasks.",
        .description = "Fangz Forge is a realistic sample application used to exercise a full command tree. " ++
            "It models project setup, release workflows, configuration, and runtime inspection.",
        .version = "1.0.0",
        .author_name = .{ .custom = "Fangz Contributors" },
        .author_email = .{ .custom = "maintainers@example.com" },
        .source_date = "2026-08-19",
        .branch = "e2e",
        .commit = "sample",
    });
    defer app.deinit();

    const root = app.root();
    root.examples = &root_examples;
    root.setHelpOnEmptyArgs(true);
    root.setHooks(.{
        .persistent_pre_run = rootPreRun,
        .persistent_post_run = rootPostRun,
    });

    try root.addGroup(.{ .id = "workspace", .title = "Workspace commands" });
    try root.addGroup(.{ .id = "delivery", .title = "Delivery commands" });
    try root.addGroup(.{ .id = "operations", .title = "Operational commands" });

    try addGlobalFlags(root);
    try addProjectCommands(root);
    try addDeliveryCommands(root);
    try addOperationalCommands(root);
    try addHiddenCommands(root);

    try app.executeProcess(init.minimal.args);
}

fn addGlobalFlags(root: *fangz.Command) !void {
    try root.addFlag(bool, .{
        .name = "verbose",
        .short = 'v',
        .brief = "Print detailed progress information.",
        .description = "Enable verbose progress messages for every command in the selected command path.",
        .persistent = true,
        .default = false,
        .examples = &.{.{
            .description = "Show deployment progress.",
            .command = "fangz --verbose deploy staging",
        }},
    });
    try root.addFlag(ColorMode, .{
        .name = "color",
        .brief = "Control terminal color output.",
        .description = "Choose automatic color detection, force color, or disable color entirely.",
        .persistent = true,
        .default = .auto,
        .allowed_values_style = .comma,
    });
    try root.addFlag(?[]const u8, .{
        .name = "config",
        .short = 'c',
        .brief = "Load configuration from a specific file.",
        .description = "Override the default project configuration discovery path.",
        .persistent = true,
        .value_hint = "PATH",
    });
    try root.addFlag([]const []const u8, .{
        .name = "label",
        .short = 'l',
        .brief = "Attach a repeatable label to the operation.",
        .description = "Labels are free-form and are forwarded to project and deployment integrations.",
        .persistent = true,
        .multi = true,
        .value_hint = "NAME",
    });
    try root.addFlag([]const fangz.KeyValuePair, .{
        .name = "define",
        .short = 'D',
        .brief = "Set a free-form build definition.",
        .description = "Each definition must use KEY=VALUE syntax. Definitions are not restricted to a fixed key set.",
        .persistent = true,
        .multi = true,
        .key_metavar = "KEY",
        .value_metavar = "VALUE",
    });
}

fn addProjectCommands(root: *fangz.Command) !void {
    const project = try root.addSubcommand(.{
        .name = "project",
        .brief = "Create, inspect, and list projects.",
        .description = "Project commands manage local workspace metadata without contacting a deployment environment.",
        .group_id = "workspace",
        .examples = &.{.{
            .description = "Inspect a project in JSON form.",
            .command = "fangz project inspect api --output json",
        }},
    });
    try project.addAlias("projects");
    project.setHelpOnEmptyArgs(true);

    const init = try project.addSubcommand(.{
        .name = "init",
        .brief = "Create a new project workspace.",
        .description = "Initialize a project directory from a template and optionally prepare Git metadata.",
    });
    try init.addPositional(.{
        .name = "directory",
        .brief = "Directory where the project is created.",
        .required = true,
        .completion = .{ .nu = .{
            .name = "complete-project-directory",
            .body = "ls | get name",
        } },
    });
    try init.addFlag(ProjectTemplate, .{
        .name = "template",
        .short = 't',
        .brief = "Project template to initialize.",
        .description = "Templates select the initial module layout and recommended command set.",
        .default = .application,
        .allowed_values_style = .bullet_list,
    });
    try init.addFlag(bool, .{
        .name = "git",
        .brief = "Initialize a Git repository.",
        .description = "Use --no-git when the project will be placed inside an existing repository.",
        .negatable = true,
        .default = true,
    });
    try init.addFlag([]const []const u8, .{
        .name = "module",
        .short = 'm',
        .brief = "Add a repeatable starter module.",
        .multi = true,
        .value_hint = "NAME",
    });
    init.setHooks(.{ .run = runProjectInit });

    const inspect = try project.addSubcommand(.{
        .name = "inspect",
        .brief = "Show the resolved project configuration.",
        .description = "Inspect renders the configuration after defaults, files, and command-line overrides are combined.",
    });
    try inspect.addPositional(.{
        .name = "project",
        .brief = "Project name or path.",
        .required = true,
    });
    try inspect.addFlag(OutputFormat, .{
        .name = "output",
        .short = 'o',
        .brief = "Select the inspection output format.",
        .default = .text,
    });
    try inspect.addFlag(bool, .{
        .name = "resolved",
        .brief = "Include inherited and defaulted settings.",
        .default = false,
    });
    inspect.setHooks(.{ .run = runProjectInspect });

    const list = try project.addSubcommand(.{
        .name = "list",
        .brief = "List projects in the current workspace.",
        .description = "Filter projects by repeatable tags and choose a bounded result set.",
    });
    try list.addFlag([]const []const u8, .{
        .name = "tag",
        .short = 't',
        .brief = "Filter by a repeatable project tag.",
        .multi = true,
        .value_hint = "TAG",
    });
    try list.addFlag(i64, .{
        .name = "limit",
        .brief = "Maximum number of projects to return.",
        .default = 25,
        .value_hint = "COUNT",
    });
    list.setHooks(.{ .run = runProjectList });
}

fn addDeliveryCommands(root: *fangz.Command) !void {
    const deploy = try root.addSubcommand(.{
        .name = "deploy",
        .brief = "Deploy one or more project artifacts.",
        .description = "Deploy uses an explicit environment, rollout strategy, and optional runtime settings.",
        .group_id = "delivery",
        .examples = &.{.{
            .description = "Perform a dry-run deployment with a feature override.",
            .command = "fangz deploy staging api.tar --dry-run --variable feature=enabled",
        }},
    });
    try deploy.addAlias("release");
    try deploy.addPositional(.{
        .name = "environment",
        .brief = "Target environment.",
        .required = true,
        .allowed_values = &.{ "development", "staging", "production" },
        .allowed_value_labels = &.{ "Local development", "Pre-production", "Live production" },
        .allowed_values_style = .bullet_list,
    });
    try deploy.addPositional(.{
        .name = "artifacts",
        .brief = "Artifact files to deploy.",
        .variadic = true,
    });
    deploy.setPositionalBounds(1, 5);
    try deploy.addFlag(DeploymentStrategy, .{
        .name = "strategy",
        .short = 's',
        .brief = "Rollout strategy.",
        .description = "Canary and blue-green deployments introduce additional validation before traffic is switched.",
        .default = .rolling,
        .allowed_values_style = .bullet_list,
    });
    try deploy.addFlag(i64, .{
        .name = "parallelism",
        .short = 'p',
        .brief = "Maximum concurrent deployment workers.",
        .default = 1,
        .value_hint = "COUNT",
    });
    try deploy.addFlag(f64, .{
        .name = "timeout",
        .brief = "Per-artifact timeout in seconds.",
        .default = 30.0,
        .value_hint = "SECONDS",
    });
    try deploy.addFlag(?[]const u8, .{
        .name = "region",
        .short = 'r',
        .brief = "Optional deployment region.",
        .value_hint = "REGION",
        .allowed_values = &.{ "us-east", "us-west", "eu-central", "ap-southeast" },
        .allowed_values_style = .bullet_list,
    });
    try deploy.addFlag(bool, .{
        .name = "wait",
        .brief = "Wait for the rollout to become healthy.",
        .negatable = true,
        .default = true,
    });
    try deploy.addFlag(bool, .{
        .name = "dry-run",
        .brief = "Plan the rollout without applying it.",
    });
    try deploy.addFlag(bool, .{
        .name = "force",
        .brief = "Apply despite an existing active rollout.",
    });
    try deploy.addMutuallyExclusive(.{ .names = &.{ "dry-run", "force" } });
    try deploy.addFlag([]const fangz.KeyValuePair, .{
        .name = "variable",
        .short = 'E',
        .brief = "Set a constrained deployment variable.",
        .description = "Variables are validated before the deployment hook executes.",
        .multi = true,
        .allowed_keys = &.{ "feature", "telemetry", "maintenance" },
        .allowed_values = &.{ "enabled", "disabled" },
        .key_metavar = "SETTING",
        .value_metavar = "STATE",
        .key_value_help = &deploy_variable_help,
    });
    deploy.setHooks(.{
        .pre_run = deployPreRun,
        .run = runDeploy,
        .post_run = deployPostRun,
    });

    const publish = try root.addSubcommand(.{
        .name = "publish",
        .brief = "Publish a release manifest.",
        .description = "Publish demonstrates required value flags and command-specific credentials.",
        .group_id = "delivery",
    });
    try publish.addPositional(.{
        .name = "manifest",
        .brief = "Release manifest to publish.",
        .required = true,
    });
    try publish.addFlag([]const u8, .{
        .name = "token",
        .short = 'T',
        .brief = "Publishing credential.",
        .description = "A token is required even when publishing to a development registry.",
        .required = true,
        .value_hint = "TOKEN",
    });
    try publish.addFlag(bool, .{
        .name = "signed",
        .brief = "Require a signed manifest.",
        .negatable = true,
        .default = true,
    });
    publish.setHooks(.{ .run = runPublish });
}

fn addOperationalCommands(root: *fangz.Command) !void {
    const logs = try root.addSubcommand(.{
        .name = "logs",
        .brief = "Stream or query service logs.",
        .description = "Logs accepts service names and exposes filters commonly used during deployment investigations.",
        .group_id = "operations",
    });
    try logs.addPositional(.{
        .name = "service",
        .brief = "Service whose logs should be queried.",
        .required = true,
        .allowed_values = &.{ "api", "worker", "web" },
        .allowed_values_style = .comma,
    });
    try logs.addFlag(LogLevel, .{
        .name = "level",
        .brief = "Minimum log level to return.",
        .default = .info,
    });
    try logs.addFlag(i64, .{
        .name = "tail",
        .short = 'n',
        .brief = "Number of log entries to show.",
        .default = 100,
        .value_hint = "LINES",
    });
    try logs.addFlag(bool, .{
        .name = "follow",
        .short = 'f',
        .brief = "Continue streaming new log entries.",
        .default = false,
    });
    try logs.addFlag(?[]const u8, .{
        .name = "since",
        .brief = "Only return entries newer than a timestamp.",
        .value_hint = "RFC3339",
    });
    logs.setHooks(.{ .run = runLogs });

    const run = try root.addSubcommand(.{
        .name = "run",
        .brief = "Run a workspace task with forwarded arguments.",
        .description = "Use -- to preserve dash-prefixed arguments for the underlying task runner.",
        .group_id = "operations",
    });
    try run.setUsageOverrideFormat("{s} run [OPTIONS] <TASK> [-- <ARGS>...]", .{root.name});
    try run.addPositional(.{
        .name = "task",
        .brief = "Task name to execute.",
        .required = true,
        .allowed_values = &.{ "build", "test", "lint", "package" },
    });
    try run.addPositional(.{
        .name = "args",
        .brief = "Arguments forwarded unchanged to the task.",
        .variadic = true,
    });
    run.setPositionalBounds(1, 6);
    try run.addFlag(bool, .{
        .name = "offline",
        .brief = "Disable network access for the task.",
        .default = false,
    });
    run.setHooks(.{ .run = runTask });

    const config = try root.addSubcommand(.{
        .name = "config",
        .brief = "Read and update workspace settings.",
        .description = "Configuration commands model nested command trees with constrained positional completions.",
        .group_id = "operations",
    });
    try config.addAlias("cfg");
    config.setHelpOnEmptyArgs(true);

    const config_get = try config.addSubcommand(.{
        .name = "get",
        .brief = "Read one workspace setting.",
    });
    try config_get.addPositional(settingPositional());
    config_get.setHooks(.{ .run = runConfigGet });

    const config_set = try config.addSubcommand(.{
        .name = "set",
        .brief = "Update one workspace setting.",
    });
    try config_set.addPositional(settingPositional());
    try config_set.addPositional(.{
        .name = "value",
        .brief = "New setting value.",
        .required = true,
    });
    config_set.setPositionalBounds(2, 2);
    config_set.setHooks(.{ .run = runConfigSet });
}

fn addHiddenCommands(root: *fangz.Command) !void {
    const debug = try root.addSubcommand(.{
        .name = "debug",
        .brief = "Inspect internal diagnostic state.",
        .description = "This command is intentionally hidden from generated public documentation.",
        .group_id = "operations",
        .hidden = true,
    });
    try debug.addFlag(bool, .{
        .name = "dump-tree",
        .brief = "Print the registered command tree.",
        .hidden = true,
    });
    debug.setHooks(.{ .run = runDebug });
}

fn settingPositional() fangz.Command.Positional {
    return .{
        .name = "setting",
        .brief = "Workspace setting name.",
        .required = true,
        .allowed_values = &.{ "output", "region", "retries", "telemetry" },
        .allowed_values_style = .bullet_list,
        .completion = .{ .nu = .{
            .name = "complete-workspace-setting",
            .body = "['output', 'region', 'retries', 'telemetry']",
        } },
    };
}

fn rootPreRun(ctx: *fangz.ParseContext) !void {
    // Persistent hooks also wrap built-in `completion` and `docs` commands,
    // whose standard output is machine-readable. Keep this setup hook silent.
    _ = ctx;
}

fn rootPostRun(ctx: *fangz.ParseContext) !void {
    _ = ctx;
}

fn deployPreRun(ctx: *fangz.ParseContext) !void {
    try printEvent(ctx, "validating rollout plan");
}

fn deployPostRun(ctx: *fangz.ParseContext) !void {
    try printEvent(ctx, "recording deployment result");
}

fn runProjectInit(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct {
        template: ProjectTemplate = .application,
        git: bool = true,
    });
    const directory = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "initialized");
    try printDetails(ctx, "directory={s} template={s} git={any}", .{ directory, @tagName(options.template), options.git });
}

fn runProjectInspect(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct {
        output: OutputFormat = .text,
        resolved: bool = false,
    });
    const project = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "inspected");
    try printDetails(ctx, "project={s} output={s} resolved={any}", .{ project, @tagName(options.output), options.resolved });
}

fn runProjectList(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct { limit: i64 = 25 });
    const tags = ctx.stringListFlag("tag") orelse &.{};
    try printEvent(ctx, "listed projects");
    try printDetails(ctx, "limit={d} tags={d}", .{ options.limit, tags.len });
}

fn runDeploy(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct {
        strategy: DeploymentStrategy = .rolling,
        parallelism: i64 = 1,
        timeout: f64 = 30.0,
        wait: bool = true,
        dry_run: bool = false,
        force: bool = false,
        region: ?[]const u8 = null,
    });
    const environment = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const variables = ctx.keyValueFlag("variable") orelse &.{};
    try printEvent(ctx, "deployed");
    try printDetails(ctx, "environment={s} strategy={s} workers={d} timeout={d:.1}s wait={any} dry-run={any} force={any} region={s} variables={d}", .{
        environment,
        @tagName(options.strategy),
        options.parallelism,
        options.timeout,
        options.wait,
        options.dry_run,
        options.force,
        options.region orelse "default",
        variables.len,
    });
}

fn runPublish(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct {
        token: []const u8,
        signed: bool = true,
    });
    const manifest = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "published");
    try printDetails(ctx, "manifest={s} token-length={d} signed={any}", .{ manifest, options.token.len, options.signed });
}

fn runLogs(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct {
        level: LogLevel = .info,
        tail: i64 = 100,
        follow: bool = false,
        since: ?[]const u8 = null,
    });
    const service = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "queried logs");
    try printDetails(ctx, "service={s} level={s} tail={d} follow={any} since={s}", .{
        service,
        @tagName(options.level),
        options.tail,
        options.follow,
        options.since orelse "all-time",
    });
}

fn runTask(ctx: *fangz.ParseContext) !void {
    const options = try ctx.extract(struct { offline: bool = false });
    const task = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "ran task");
    try printDetails(ctx, "task={s} forwarded-args={d} offline={any}", .{ task, ctx.positionals.items.len - 1, options.offline });
}

fn runConfigGet(ctx: *fangz.ParseContext) !void {
    const setting = ctx.positional(0) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "read configuration");
    try printDetails(ctx, "setting={s}", .{setting});
}

fn runConfigSet(ctx: *fangz.ParseContext) !void {
    const setting = ctx.positional(0) orelse return error.MissingRequiredPositional;
    const value = ctx.positional(1) orelse return error.MissingRequiredPositional;
    try printEvent(ctx, "updated configuration");
    try printDetails(ctx, "setting={s} value={s}", .{ setting, value });
}

fn runDebug(ctx: *fangz.ParseContext) !void {
    try printEvent(ctx, "ran hidden diagnostic command");
}

fn printEvent(ctx: *fangz.ParseContext, event: []const u8) !void {
    try printDetails(ctx, "{s}: {s}", .{ ctx.command.name, event });
}

fn printDetails(ctx: *fangz.ParseContext, comptime fmt: []const u8, args: anytype) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(ctx.io, &stdout_buffer);
    try out.interface.print(fmt ++ "\n", args);
    try out.interface.flush();
}
