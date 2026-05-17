/// Hook callback signature used during command execution lifecycle.
pub const HookFn = *const fn (*ParseContext) anyerror!void;
pre_run: ?HookFn = null,
run: ?HookFn = null,
post_run: ?HookFn = null,
persistent_pre_run: ?HookFn = null,
persistent_post_run: ?HookFn = null,
const ParseContext = @import("../ParseContext.zig");
