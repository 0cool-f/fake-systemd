// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading OpenRC files and tool output: the command of an `openrc-run` script, the flags
//! recorded in a generated script, the state of a service from the exit status of
//! `rc-service <name> status`, and the version of the installed OpenRC.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const execline = @import("../../unit/execline.zig");
const exec_norm = @import("../exec_norm.zig");

// ---- command of a script -----------------------------------------------------------------

const Var = struct { name: []const u8, value: []const u8 };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Reads one shell word at `pos.*` (quotes and escapes resolved, no expansion) and moves `pos`
/// behind it. A quoted part may span lines.
fn readWord(gpa: Allocator, content: []const u8, pos: *usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i = pos.*;
    while (i < content.len) {
        const c = content[i];
        switch (c) {
            ' ', '\t', '\n', '\r', ';', '#' => break,
            '\'' => {
                i += 1;
                while (i < content.len and content[i] != '\'') : (i += 1) try out.append(gpa, content[i]);
                i += 1;
            },
            '"' => {
                i += 1;
                while (i < content.len and content[i] != '"') : (i += 1) {
                    if (content[i] == '\\' and i + 1 < content.len and std.mem.findScalar(u8, "\"\\$`\n", content[i + 1]) != null) {
                        i += 1;
                        if (content[i] == '\n') continue;
                    }
                    try out.append(gpa, content[i]);
                }
                i += 1;
            },
            '\\' => {
                if (i + 1 < content.len and content[i + 1] != '\n') try out.append(gpa, content[i + 1]);
                i += 2;
            },
            else => {
                try out.append(gpa, c);
                i += 1;
            },
        }
    }
    pos.* = @min(i, content.len);
    return out.toOwnedSlice(gpa);
}

fn lookup(vars: []const Var, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) {
        found = v.value;
    };
    return found;
}

/// Expands `$name`, `${name}` and `${name:-default}` from `vars`; null when a name is unknown,
/// as `RC_SVCNAME` is, or the text uses another form of expansion.
fn expand(gpa: Allocator, text: []const u8, vars: []const Var) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(gpa, text[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) return null;
        var name: []const u8 = undefined;
        var fallback: ?[]const u8 = null;
        if (text[i] == '{') {
            const close = std.mem.findScalarPos(u8, text, i, '}') orelse return null;
            const inner = text[i + 1 .. close];
            if (std.mem.find(u8, inner, ":-")) |at| {
                name = inner[0..at];
                fallback = inner[at + 2 ..];
            } else name = inner;
            i = close + 1;
        } else {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            name = text[start..i];
        }
        if (name.len == 0) return null;
        for (name) |c| if (!isIdent(c)) return null;
        const value = lookup(vars, name) orelse (fallback orelse return null);
        try out.appendSlice(gpa, value);
    }
    return try out.toOwnedSlice(gpa);
}

fn startsFunction(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and isIdent(line[i])) i += 1;
    if (i == 0) return false;
    const rest = std.mem.trimStart(u8, line[i..], " \t");
    return std.mem.startsWith(u8, rest, "()");
}

const supervisors = [_][]const u8{ "start-stop-daemon", "supervise-daemon" };

/// Words of a line that runs `start-stop-daemon` or `supervise-daemon`, or null.
fn daemonLine(gpa: Allocator, line: []const u8) Allocator.Error!?[]const []const u8 {
    var text = std.mem.trim(u8, line, " \t");
    for ([_][]const u8{ "eval ", "exec " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) text = std.mem.trimStart(u8, text[prefix.len..], " \t");
    }
    const hit = for (supervisors) |s| {
        if (std.mem.startsWith(u8, text, s) and text.len > s.len and (text[s.len] == ' ' or text[s.len] == '\t')) break true;
    } else false;
    if (!hit) return null;
    const words = execline.splitWords(gpa, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const exe = (try exec_norm.commandExecutable(gpa, words)) orelse return null;
    if (std.mem.findScalar(u8, exe, '$') != null) return null;
    return words;
}

/// Command words of an `openrc-run` script: `command` followed by `command_args`, with the
/// variables the script assigned before expanded. A script that sets no `command` is read for a
/// `start-stop-daemon` or `supervise-daemon` line in its own start function.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var vars: std.ArrayList(Var) = .empty;
    var command: ?[]const u8 = null;
    var args: ?[]const u8 = null;
    var daemon: ?[]const []const u8 = null;
    var in_function = false;
    var pos: usize = 0;
    while (pos < content.len) {
        const end = std.mem.findScalarPos(u8, content, pos, '\n') orelse content.len;
        const raw = content[pos..end];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (in_function) {
            if (daemon == null) daemon = try daemonLine(gpa, line);
            if (raw.len > 0 and raw[0] == '}') in_function = false;
            pos = @min(end + 1, content.len);
            continue;
        }
        if (line.len == 0 or line[0] == '#') {
            pos = @min(end + 1, content.len);
            continue;
        }
        if (startsFunction(line)) {
            in_function = !std.mem.endsWith(u8, line, "}");
            pos = @min(end + 1, content.len);
            continue;
        }
        var cur = pos + (std.mem.findNone(u8, raw, " \t") orelse 0);
        if (std.mem.startsWith(u8, content[cur..], "export ")) cur += "export ".len;
        const name_start = cur;
        while (cur < content.len and isIdent(content[cur])) cur += 1;
        if (cur > name_start and cur < content.len and content[cur] == '=') {
            const name = content[name_start..cur];
            cur += 1;
            const value = try readWord(gpa, content, &cur);
            const expanded = (try expand(gpa, value, vars.items)) orelse value;
            const resolved = std.mem.findScalar(u8, expanded, '$') == null;
            if (resolved) try vars.append(gpa, .{ .name = name, .value = expanded });
            if (std.mem.eql(u8, name, "command")) command = if (resolved) expanded else null;
            if (std.mem.eql(u8, name, "command_args")) args = if (resolved) expanded else null;
            const next = std.mem.findScalarPos(u8, content, cur, '\n') orelse content.len;
            pos = @min(next + 1, content.len);
            continue;
        }
        if (daemon == null) daemon = try daemonLine(gpa, line);
        pos = @min(end + 1, content.len);
    }
    if (command) |c| {
        if (c.len == 0) return daemon;
        var words: std.ArrayList([]const u8) = .empty;
        try words.append(gpa, c);
        if (args) |a| {
            const split = execline.splitWords(gpa, a) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return words.items,
            };
            try words.appendSlice(gpa, split);
        }
        return try words.toOwnedSlice(gpa);
    }
    return daemon;
}

// ---- flags -------------------------------------------------------------------------------

pub const flags_prefix = "# flags:";

/// What the backend needs to read back from a generated script.
pub const Flags = struct {
    /// A oneshot that stays `started` in OpenRC but is `inactive` once its command succeeded.
    transient: bool = false,
    /// The service runs its executor with `--record-exit`, which writes how it ended.
    record_exit: bool = false,
};

pub fn parseFlags(rest: []const u8) Flags {
    var out: Flags = .{};
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        const tail = std.mem.cutPrefix(u8, line, flags_prefix) orelse continue;
        var it = std.mem.tokenizeScalar(u8, tail, ' ');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "transient")) out.transient = true;
            if (std.mem.eql(u8, tok, "record-exit")) out.record_exit = true;
        }
        break;
    }
    return out;
}

// ---- status ------------------------------------------------------------------------------

/// Exit statuses of `rc-service <name> status`.
pub const status_stopping = 4;
pub const status_starting = 8;
pub const status_inactive = 16;
pub const status_crashed = 32;
pub const status_unsupervised = 64;

/// How the main process ended, from the file `fake-systemd --exec --record-exit` writes.
pub const Exit = enum { ok, failed };

pub fn parseExit(text: []const u8) ?Exit {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return std.meta.stringToEnum(Exit, it.next() orelse return null);
}

/// Normalized state of a service from the exit status of its `status` action. `failed` says a
/// supervisor gave up on the service: OpenRC then reports `stopped` with a `failed` marker.
pub fn stateOfStatus(code: u8, failed: bool, transient: bool, exit: ?Exit) output.ActiveState {
    return switch (code) {
        0 => if (transient) .inactive else .active,
        3 => if (failed) .failed else .inactive,
        status_stopping => .deactivating,
        status_starting => .activating,
        // A process that is gone but ended cleanly, as its executor recorded, is not a failure.
        status_crashed, status_unsupervised => if (exit != null and exit.? == .ok) .inactive else .failed,
        else => .inactive,
    };
}

/// True when the exit status says the service is recorded as started although its process is
/// gone, so that `start` would do nothing.
pub fn isCrashed(code: u8) bool {
    return code == status_crashed or code == status_unsupervised;
}

/// Process id in a pid file or an OpenRC option file.
pub fn parsePid(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return if (pid <= 1) null else pid;
}

/// `pidfile=` line of an entry in `daemons/<service>/`.
pub fn pidfileOfDaemon(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.cutPrefix(u8, line, "pidfile=")) |path| return if (path.len > 0) path else null;
    }
    return null;
}

// ---- version -----------------------------------------------------------------------------

pub const Version = struct {
    major: u32,
    minor: u32,

    pub fn atLeast(v: Version, major: u32, minor: u32) bool {
        return v.major > major or (v.major == major and v.minor >= minor);
    }
};

/// `0.63.2`, `0.64.1+` or `0.45` from the version file; null when it does not start with a
/// number pair.
pub fn parseVersion(text: []const u8) ?Version {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor_text = it.next() orelse return null;
    var end: usize = 0;
    while (end < minor_text.len and std.ascii.isDigit(minor_text[end])) end += 1;
    const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "command and command_args give the words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/sshd", "-D", "-f", "/etc/ssh/sshd_config" }, try extractCommand(a,
        \\#!/sbin/openrc-run
        \\
        \\command=/usr/sbin/sshd
        \\command_args="-D -f /etc/ssh/sshd_config"
        \\pidfile="/run/${RC_SVCNAME}.pid"
        \\
        \\depend() {
        \\    need net
        \\}
        \\
    ));
    try expectWords(&.{ "/usr/bin/foo", "--name", "a b" }, try extractCommand(a, "command='/usr/bin/foo'\ncommand_args=\"--name 'a b'\"\n"));
    try expectWords(&.{"/usr/bin/foo"}, try extractCommand(a, "export command=/usr/bin/foo\n"));
}

test "variables assigned earlier are expanded and unknown ones give no command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/crond", "-n", "-S" }, try extractCommand(a, "bin=/usr/sbin\ncommand=${bin}/crond\ncommand_args=\"${crond_opts:--n} -S\"\n"));
    try testing.expect(try extractCommand(a, "command=\"/usr/bin/${RC_SVCNAME}\"\n") == null);
}

test "a multi-line command_args is read as one value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/cancd", "-p", "9", "-l", "/var/log" }, try extractCommand(a,
        \\command="/usr/sbin/cancd"
        \\command_args="-p 9
        \\              -l /var/log"
        \\command_user="cancd"
        \\
    ));
}

test "assignments inside functions are not the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try extractCommand(a, "start() {\n\tcommand=/usr/bin/inner\n}\n") == null);
}

test "a custom start function is read for the daemon it starts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ssd = try extractCommand(a,
        \\start() {
        \\    ebegin "Starting"
        \\    start-stop-daemon --start --exec /usr/sbin/foo --pidfile /run/foo.pid -- -x
        \\    eend $?
        \\}
        \\
    );
    try testing.expectEqualStrings("start-stop-daemon", ssd.?[0]);
    const sup = try extractCommand(a, "start() {\n\teval supervise-daemon foo --start /usr/bin/bar -- -y\n}\n");
    try testing.expectEqualStrings("supervise-daemon", sup.?[0]);
    try testing.expect(try extractCommand(a, "start() {\n\tstart-stop-daemon --start --exec $DAEMON\n}\n") == null);
    try testing.expect(try extractCommand(a, "") == null);
    try testing.expect(try extractCommand(a, "#!/sbin/openrc-run\ndepend() {\n\tneed net\n}\n") == null);
}

test "flags are read from the flags line" {
    try testing.expect(parseFlags("# flags: transient\nexport A=1\n").transient);
    try testing.expect(!parseFlags("export A=1\n").transient);
    try testing.expect(!parseFlags("# flags:\n").transient);
    const both = parseFlags("# flags: transient record-exit\n");
    try testing.expect(both.transient and both.record_exit);
    try testing.expect(!parseFlags("# flags: transient\n").record_exit);
}

test "exit statuses observed from rc-service status map to systemd states" {
    try testing.expectEqual(output.ActiveState.active, stateOfStatus(0, false, false, null));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(0, false, true, null));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(3, false, false, null));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(3, true, false, null));
    try testing.expectEqual(output.ActiveState.deactivating, stateOfStatus(4, false, false, null));
    try testing.expectEqual(output.ActiveState.activating, stateOfStatus(8, false, false, null));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(16, false, false, null));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(32, false, false, null));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(64, false, false, null));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(1, false, false, null));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(32, false, false, .ok));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(32, false, false, .failed));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(64, false, false, .ok));
    try testing.expectEqual(output.ActiveState.active, stateOfStatus(0, false, false, .failed));
    try testing.expect(isCrashed(32) and isCrashed(64) and !isCrashed(0));
    try testing.expectEqual(@as(?Exit, .ok), parseExit("ok 0\n"));
    try testing.expectEqual(@as(?Exit, .failed), parseExit("failed 137\n"));
    try testing.expectEqual(@as(?Exit, null), parseExit(""));
}

test "pids and pid files" {
    try testing.expectEqual(@as(?u32, 120), parsePid("120\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("0\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("1\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("x"));
    try testing.expectEqualStrings("/run/plain.pid", pidfileOfDaemon("exec=/bin/sleep\nargv_0=/bin/sleep\npidfile=/run/plain.pid\n").?);
    try testing.expect(pidfileOfDaemon("exec=/bin/sleep\n") == null);
}

test "versions of the version file" {
    const v = parseVersion("0.63.2\n").?;
    try testing.expect(v.atLeast(0, 51) and v.atLeast(0, 63) and !v.atLeast(0, 64));
    try testing.expect(parseVersion("0.64.1+").?.atLeast(0, 64));
    try testing.expect(!parseVersion("0.45.2").?.atLeast(0, 51));
    try testing.expect(parseVersion("1.0").?.atLeast(0, 99));
    try testing.expect(parseVersion("git") == null);
    try testing.expect(parseVersion("") == null);
}
