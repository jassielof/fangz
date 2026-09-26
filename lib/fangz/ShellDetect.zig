//! Finds the interactive shell that started the current process by walking up the process tree.
//!
//! The parent chain is the reliable signal: `$SHELL` names the login shell, not the one the user is typing into, and most shells do not export a marker variable. Walking up from this process's parent, the nearest process that is a shell wins, so `program <- zig <- pwsh` still finds `pwsh`.
//!
//! Shells that are mostly a way to run a command line (`sh -c ...`, `cmd /c ...`) are not recognized as shells here, so the walk passes over them. A shell we cannot generate completions for (`tcsh`, `elvish`, ...) does stop the walk with `.unsupported`, instead of silently picking one further up.

const std = @import("std");
const builtin = @import("builtin");

/// The outcome of looking for the running shell. Every string is static, so results outlive the lookup.
pub const Detection = union(enum) {
    /// A supported shell, as a spelling `Shell.parse` accepts.
    shell: []const u8,
    /// The nearest shell is one we have no completion script for.
    unsupported: []const u8,
    /// No shell was found in the ancestry, or the process tree could not be read.
    unknown,
};

/// One entry of the process tree.
pub const Process = struct {
    pid: u32,
    parent: u32,
    /// The executable name or path as the operating system reports it.
    name: []const u8,
};

const Class = union(enum) {
    shell: []const u8,
    blocker: []const u8,
    other,
};

const supported = [_]struct { process: []const u8, spelling: []const u8 }{
    .{ .process = "bash", .spelling = "bash" },
    .{ .process = "zsh", .spelling = "zsh" },
    .{ .process = "fish", .spelling = "fish" },
    .{ .process = "pwsh", .spelling = "powershell" },
    .{ .process = "pwsh-preview", .spelling = "powershell" },
    .{ .process = "powershell", .spelling = "powershell" },
    .{ .process = "nu", .spelling = "nushell" },
    .{ .process = "nushell", .spelling = "nushell" },
};

/// Shells with no completion script here. Finding one is a definite answer.
const blockers = [_][]const u8{ "ksh", "mksh", "csh", "tcsh", "elvish", "xonsh", "ion", "osh", "yash" };

const max_depth = 16;

/// Looks for the shell that launched this process.
pub fn detect(allocator: std.mem.Allocator, io: std.Io) Detection {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (builtin.os.tag) {
        .windows => {
            var provider = WindowsProvider.init(arena) orelse return .unknown;
            return walk(&provider, std.os.windows.GetCurrentProcessId());
        },
        .linux => {
            var provider: ProcProvider = .{ .arena = arena, .io = io };
            return walk(&provider, @intCast(std.os.linux.getpid()));
        },
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            var provider: PsProvider = .{ .arena = arena, .io = io };
            return walk(&provider, @intCast(std.c.getpid()));
        },
        else => return .unknown,
    }
}

/// Walks up from `own_pid`'s parent through `provider`, which answers `find(pid) ?Process`.
pub fn walk(provider: anytype, own_pid: u32) Detection {
    const own = provider.find(own_pid) orelse return .unknown;

    var current = own.parent;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const process = provider.find(current) orelse return .unknown;

        switch (classify(process.name)) {
            .shell => |spelling| return .{ .shell = spelling },
            .blocker => |name| return .{ .unsupported = name },
            .other => {},
        }

        // A parent of 0, or one pointing back at itself, means the top of the tree; pid reuse can also close a loop.
        if (process.parent == 0 or process.parent == process.pid or process.parent == current) return .unknown;
        current = process.parent;
    }

    return .unknown;
}

fn classify(process_name: []const u8) Class {
    var buffer: [64]u8 = undefined;
    const name = normalize(&buffer, process_name);

    for (supported) |entry| {
        if (std.mem.eql(u8, name, entry.process)) return .{ .shell = entry.spelling };
    }
    for (blockers) |blocker| {
        if (std.mem.eql(u8, name, blocker)) return .{ .blocker = blocker };
    }
    return .other;
}

/// Reduces an executable path to a comparable name: no directory, no `.exe`, lowercase, and without the leading `-` login shells are started with (`-bash`).
fn normalize(buffer: []u8, process_name: []const u8) []const u8 {
    var name = process_name;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |index| name = name[index + 1 ..];
    if (name.len > 0 and name[0] == '-') name = name[1..];
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) name = name[0 .. name.len - 4];

    const length = @min(name.len, buffer.len);
    for (name[0..length], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    return buffer[0..length];
}

// -- Linux -----------------------------------------------------------------

const ProcProvider = struct {
    arena: std.mem.Allocator,
    io: std.Io,

    fn find(self: *ProcProvider, pid: u32) ?Process {
        var path_buffer: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;

        var file = std.Io.Dir.cwd().openFile(self.io, stat_path, .{}) catch return null;
        defer file.close(self.io);

        // /proc files report a size of zero, so read until the end instead of trusting the size.
        var read_buffer: [256]u8 = undefined;
        var reader = file.reader(self.io, &read_buffer);
        var text: [1024]u8 = undefined;
        const length = reader.interface.readSliceShort(&text) catch return null;

        const stat = parseStat(text[0..length]) orelse return null;

        // The executable is more telling than `comm`: a shell script's `comm` is the script's name, but its exe is the interpreter.
        const exe_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/exe", .{pid}) catch return null;
        var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name = if (std.Io.Dir.cwd().readLink(self.io, exe_path, &link_buffer)) |link_length|
            self.arena.dupe(u8, link_buffer[0..link_length]) catch return null
        else |_|
            self.arena.dupe(u8, stat.comm) catch return null;

        return .{ .pid = pid, .parent = stat.parent, .name = name };
    }
};

const Stat = struct {
    parent: u32,
    comm: []const u8,
};

/// Parses `/proc/<pid>/stat`: `pid (comm) state ppid ...`. The command name may itself contain spaces and parentheses, so it is delimited by the first `(` and the last `)`.
fn parseStat(text: []const u8) ?Stat {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close < open) return null;

    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    const parent_text = std.mem.trimEnd(u8, fields.next() orelse return null, "\n");
    const parent = std.fmt.parseInt(u32, parent_text, 10) catch return null;

    return .{ .parent = parent, .comm = text[open + 1 .. close] };
}

// -- macOS and the BSDs ----------------------------------------------------

const PsProvider = struct {
    arena: std.mem.Allocator,
    io: std.Io,

    fn find(self: *PsProvider, pid: u32) ?Process {
        var pid_buffer: [16]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch return null;

        const result = std.process.run(self.arena, self.io, .{
            .argv = &.{ "ps", "-o", "ppid=,comm=", "-p", pid_text },
        }) catch return null;

        const parsed = parsePs(result.stdout) orelse return null;
        return .{ .pid = pid, .parent = parsed.parent, .name = parsed.name };
    }
};

const Ps = struct {
    parent: u32,
    name: []const u8,
};

/// Parses one line of `ps -o ppid=,comm=`: the parent pid, then the command, which may be a path containing spaces.
fn parsePs(text: []const u8) ?Ps {
    const line = std.mem.trim(u8, text, " \t\r\n");
    const split = std.mem.indexOfAny(u8, line, " \t") orelse return null;

    const parent = std.fmt.parseInt(u32, line[0..split], 10) catch return null;
    const name = std.mem.trim(u8, line[split..], " \t");
    if (name.len == 0) return null;

    return .{ .parent = parent, .name = name };
}

// -- Windows ---------------------------------------------------------------

const WindowsProvider = struct {
    processes: []const Process,

    const windows = std.os.windows;

    const th32cs_snapprocess: windows.DWORD = 0x2;

    const Entry = extern struct {
        size: windows.DWORD,
        usage: windows.DWORD,
        process_id: windows.DWORD,
        default_heap_id: usize,
        module_id: windows.DWORD,
        threads: windows.DWORD,
        parent_process_id: windows.DWORD,
        priority_class_base: i32,
        flags: windows.DWORD,
        exe_file: [260]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(flags: windows.DWORD, process_id: windows.DWORD) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn Process32FirstW(snapshot: windows.HANDLE, entry: *Entry) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Process32NextW(snapshot: windows.HANDLE, entry: *Entry) callconv(.winapi) windows.BOOL;

    /// Snapshots every process once; the ancestry walk then looks entries up by pid.
    fn init(arena: std.mem.Allocator) ?WindowsProvider {
        const snapshot = CreateToolhelp32Snapshot(th32cs_snapprocess, 0);
        if (snapshot == windows.INVALID_HANDLE_VALUE) return null;
        defer windows.CloseHandle(snapshot);

        var processes: std.ArrayList(Process) = .empty;

        var entry: Entry = undefined;
        entry.size = @sizeOf(Entry);
        var more = Process32FirstW(snapshot, &entry).toBool();
        while (more) : (more = Process32NextW(snapshot, &entry).toBool()) {
            const name_wide = std.mem.sliceTo(&entry.exe_file, 0);
            const name = std.unicode.utf16LeToUtf8Alloc(arena, name_wide) catch continue;
            processes.append(arena, .{
                .pid = entry.process_id,
                .parent = entry.parent_process_id,
                .name = name,
            }) catch return null;
        }

        return .{ .processes = processes.items };
    }

    fn find(self: *WindowsProvider, pid: u32) ?Process {
        for (self.processes) |process| {
            if (process.pid == pid) return process;
        }
        return null;
    }
};

// -- Tests -----------------------------------------------------------------

const TableProvider = struct {
    processes: []const Process,

    fn find(self: *TableProvider, pid: u32) ?Process {
        for (self.processes) |process| {
            if (process.pid == pid) return process;
        }
        return null;
    }
};

fn expectShell(expected: []const u8, processes: []const Process, own_pid: u32) !void {
    var provider: TableProvider = .{ .processes = processes };
    switch (walk(&provider, own_pid)) {
        .shell => |spelling| try std.testing.expectEqualStrings(expected, spelling),
        else => return error.ShellNotDetected,
    }
}

test "classify recognizes shells however the OS spells their name" {
    try std.testing.expectEqualStrings("bash", classify("bash").shell);
    try std.testing.expectEqualStrings("bash", classify("-bash").shell);
    try std.testing.expectEqualStrings("bash", classify("/usr/bin/bash").shell);
    try std.testing.expectEqualStrings("bash", classify("C:\\Program Files\\Git\\usr\\bin\\bash.exe").shell);
    try std.testing.expectEqualStrings("zsh", classify("/bin/zsh").shell);
    try std.testing.expectEqualStrings("fish", classify("Fish").shell);
    try std.testing.expectEqualStrings("powershell", classify("pwsh.exe").shell);
    try std.testing.expectEqualStrings("powershell", classify("PowerShell.EXE").shell);
    try std.testing.expectEqualStrings("nushell", classify("nu.exe").shell);
    try std.testing.expectEqualStrings("nushell", classify("/home/u/.cargo/bin/nu").shell);
}

test "classify separates unsupported shells from ordinary programs" {
    try std.testing.expectEqualStrings("tcsh", classify("/bin/tcsh").blocker);
    try std.testing.expectEqualStrings("elvish", classify("elvish").blocker);
    try std.testing.expect(classify("zig.exe") == .other);
    try std.testing.expect(classify("WindowsTerminal.exe") == .other);
    try std.testing.expect(classify("bashful") == .other);
    try std.testing.expect(classify("") == .other);
}

test "the nearest shell in the ancestry wins" {
    try expectShell("powershell", &.{
        .{ .pid = 1, .parent = 0, .name = "explorer.exe" },
        .{ .pid = 2, .parent = 1, .name = "pwsh.exe" },
        .{ .pid = 3, .parent = 2, .name = "zig.exe" },
        .{ .pid = 4, .parent = 3, .name = "typm.exe" },
    }, 4);

    // A shell started inside another one is the one being typed into.
    try expectShell("nushell", &.{
        .{ .pid = 1, .parent = 0, .name = "-bash" },
        .{ .pid = 2, .parent = 1, .name = "nu" },
        .{ .pid = 3, .parent = 2, .name = "typm" },
    }, 3);
}

test "command wrappers are skipped" {
    try expectShell("bash", &.{
        .{ .pid = 1, .parent = 0, .name = "/bin/bash" },
        .{ .pid = 2, .parent = 1, .name = "make" },
        .{ .pid = 3, .parent = 2, .name = "/bin/sh" },
        .{ .pid = 4, .parent = 3, .name = "typm" },
    }, 4);

    try expectShell("powershell", &.{
        .{ .pid = 1, .parent = 0, .name = "pwsh.exe" },
        .{ .pid = 2, .parent = 1, .name = "cmd.exe" },
        .{ .pid = 3, .parent = 2, .name = "typm.exe" },
    }, 3);
}

test "an unsupported shell ends the search" {
    var provider: TableProvider = .{ .processes = &.{
        .{ .pid = 1, .parent = 0, .name = "bash" },
        .{ .pid = 2, .parent = 1, .name = "/bin/tcsh" },
        .{ .pid = 3, .parent = 2, .name = "typm" },
    } };

    try std.testing.expectEqualStrings("tcsh", walk(&provider, 3).unsupported);
}

test "no shell in the ancestry is unknown" {
    var provider: TableProvider = .{ .processes = &.{
        .{ .pid = 1, .parent = 0, .name = "init" },
        .{ .pid = 2, .parent = 1, .name = "cron" },
        .{ .pid = 3, .parent = 2, .name = "typm" },
    } };
    try std.testing.expect(walk(&provider, 3) == .unknown);

    // A process whose own entry cannot be found is unknown too, not a crash.
    try std.testing.expect(walk(&provider, 99) == .unknown);
}

test "a parent that is missing or loops back cannot hang the walk" {
    var orphan: TableProvider = .{ .processes = &.{.{ .pid = 5, .parent = 4, .name = "typm" }} };
    try std.testing.expect(walk(&orphan, 5) == .unknown);

    var loop: TableProvider = .{ .processes = &.{
        .{ .pid = 1, .parent = 2, .name = "a" },
        .{ .pid = 2, .parent = 1, .name = "b" },
        .{ .pid = 3, .parent = 2, .name = "typm" },
    } };
    try std.testing.expect(walk(&loop, 3) == .unknown);
}

test "parseStat reads the parent pid even when the command name is awkward" {
    const plain = parseStat("1234 (bash) S 1200 1234 1234 0 -1\n").?;
    try std.testing.expectEqual(@as(u32, 1200), plain.parent);
    try std.testing.expectEqualStrings("bash", plain.comm);

    const awkward = parseStat("77 (my (weird) name) R 41 77 77 0\n").?;
    try std.testing.expectEqual(@as(u32, 41), awkward.parent);
    try std.testing.expectEqualStrings("my (weird) name", awkward.comm);

    try std.testing.expect(parseStat("garbage") == null);
    try std.testing.expect(parseStat("1 (x) S notanumber") == null);
}

test "parsePs reads the parent pid and the command" {
    const macos = parsePs("  501 /bin/zsh\n").?;
    try std.testing.expectEqual(@as(u32, 501), macos.parent);
    try std.testing.expectEqualStrings("/bin/zsh", macos.name);

    const spaced = parsePs("42 /Applications/Some App.app/Contents/MacOS/some\n").?;
    try std.testing.expectEqualStrings("/Applications/Some App.app/Contents/MacOS/some", spaced.name);

    try std.testing.expect(parsePs("") == null);
    try std.testing.expect(parsePs("12") == null);
    try std.testing.expect(parsePs("x /bin/zsh") == null);
}
