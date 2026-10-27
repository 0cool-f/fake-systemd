// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading BSD-style rc files: the command of an rc script, the managed block of a hook script,
//! and a pid file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const script = @import("script.zig");
const core_block = @import("../../core/block.zig");

// ---- command of a script -----------------------------------------------------------------

/// Programs that scripts run in their start function before the daemon itself.
const helpers = [_][]const u8{
    "echo",   "printf",  "cat",   "mkdir",    "chmod",  "chown", "chgrp", "rm",       "ln",      "touch",      "install",      "sleep",
    "kill",   "killall", "pkill", "pgrep",    "ps",     "grep",  "sed",   "awk",      "cut",     "tr",         "cp",           "mv",
    "mount",  "umount",  "rmdir", "sync",     "logger", "id",    "test",  "modprobe", "stty",    "ssh-keygen", "dbus-uuidgen", "mktemp",
    "ulimit", "setterm", "rmmod", "ifconfig", "ip",     "uname", "date",  "hostname", "dirname", "basename",
};

fn isHelper(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    for (helpers) |h| if (std.mem.eql(u8, h, base)) return true;
    return false;
}

fn isStartName(name: []const u8) bool {
    return std.ascii.findIgnoreCase(name, "start") != null and std.ascii.findIgnoreCase(name, "restart") == null;
}

/// Name of the function a line opens: `name() {`, `function name {`, `function name() {`.
fn functionOpened(line: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, rest, "function ")) rest = std.mem.trimStart(u8, rest["function ".len..], " \t");
    var end: usize = 0;
    while (end < rest.len and (script.isIdent(rest[end]) or rest[end] == '-')) end += 1;
    if (end == 0) return null;
    const tail = std.mem.trim(u8, rest[end..], " \t");
    const keyword = std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "function ");
    if (std.mem.startsWith(u8, tail, "()") or (keyword and (tail.len == 0 or tail[0] == '{'))) return rest[0..end];
    return null;
}

/// True when a line opens the `start` arm of a `case`: `start)`, `'start')`, `"start")`, or a
/// list of patterns that holds it.
fn startArm(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    const close = std.mem.findScalar(u8, trimmed, ')') orelse return false;
    var patterns = std.mem.splitScalar(u8, trimmed[0..close], '|');
    while (patterns.next()) |p| {
        const bare = std.mem.trim(u8, p, " \t'\"");
        if (std.mem.eql(u8, bare, "start")) return true;
    }
    return false;
}

fn endsArm(line: []const u8) bool {
    return std.mem.find(u8, line, ";;") != null;
}

const Context = enum { none, function, arm };

/// Command words of an rc script: the last program the start function, or the `start` arm of
/// the `case`, runs by absolute path, with the variables the script assigned before expanded.
/// Without either, a variable such as `DAEMON` that holds a program path. Null when the program
/// stays unknown.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var vars: std.ArrayList(script.Var) = .empty;
    var found: ?[]const []const u8 = null;
    var context: Context = .none;
    var lines: script.Lines = .{ .text = content };
    while (try lines.next(gpa)) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        switch (context) {
            .none => {
                if (functionOpened(line)) |name| {
                    if (isStartName(name)) context = .function;
                    continue;
                }
                if (startArm(line)) context = .arm;
            },
            .function => if (std.mem.eql(u8, line, "}")) {
                context = .none;
                continue;
            },
            .arm => {},
        }
        for (try script.splitCommands(gpa, line)) |all| {
            const words = script.trimCommand(all);
            if (words.len == 0) continue;
            if (try script.recordAssignments(gpa, words, &vars)) continue;
            if (context == .none) continue;
            var start: usize = 0;
            while (start < words.len and script.isAssignment(words[start]) != null) start += 1;
            if (start >= words.len) continue;
            const exe = (try script.expand(gpa, words[start], vars.items)) orelse continue;
            if (!script.isProgramPath(exe) or isHelper(exe)) continue;
            var out: std.ArrayList([]const u8) = .empty;
            try out.append(gpa, exe);
            for (script.withoutRedirects(words[start + 1 ..])) |a| try out.append(gpa, (try script.expand(gpa, a, vars.items)) orelse a);
            found = try out.toOwnedSlice(gpa);
        }
        if (context == .arm and endsArm(line)) context = .none;
    }
    if (found) |f| return f;
    for ([_][]const u8{ "DAEMON", "daemon", "DAEMON_BIN", "PROG", "prog", "EXEC", "exec" }) |name| {
        const value = script.lookup(vars.items, name) orelse continue;
        if (script.isProgramPath(value)) return try gpa.dupe([]const u8, &.{value});
    }
    return null;
}

// ---- managed block of a hook script -------------------------------------------------------

pub const block_begin = "# BEGIN fake-systemd";
pub const block_end = "# END fake-systemd";
pub const hook_shebang = "#!/bin/sh\n";

/// Bounds of the managed block; null when there is none, `error.MalformedBlock` unless the
/// script holds exactly one BEGIN followed by one END.
fn blockBounds(content: []const u8) core_block.Error!?core_block.Bounds {
    var fault: core_block.Fault = undefined;
    return core_block.find(content, block_begin, block_end, &fault);
}

/// Why the managed block of a hook script is not exactly one BEGIN followed by one END, null
/// when it is valid or absent; callers name the file in the error they print.
pub fn blockFault(content: []const u8) ?core_block.Fault {
    return switch (core_block.locate(content, block_begin, block_end)) {
        .malformed => |f| f,
        else => null,
    };
}

/// True when `content` holds nothing but a shebang line and blank lines.
fn onlyShebang(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0) continue;
        if (first and std.mem.startsWith(u8, t, "#!")) {
            first = false;
            continue;
        }
        return false;
    }
    return true;
}

/// The text of a hook script with its managed block holding `commands`, one line each; null
/// when the script should not exist: no commands and nothing else in it. `content` is the
/// current text, null for a script that does not exist. A script that does not hold exactly one
/// block fails with `error.MalformedBlock` and is left as it is.
pub fn withBlock(gpa: Allocator, content: ?[]const u8, commands: []const []const u8) (core_block.Error || Allocator.Error)!?[]const u8 {
    var block: std.ArrayList(u8) = .empty;
    if (commands.len > 0) {
        try block.appendSlice(gpa, block_begin);
        try block.append(gpa, '\n');
        for (commands) |c| {
            try block.appendSlice(gpa, c);
            try block.append(gpa, '\n');
        }
        try block.appendSlice(gpa, block_end);
        try block.append(gpa, '\n');
    }
    const text = content orelse {
        if (commands.len == 0) return null;
        return try std.mem.concat(gpa, u8, &.{ hook_shebang, "\n", block.items });
    };
    var out: std.ArrayList(u8) = .empty;
    if (try blockBounds(text)) |b| {
        var head = text[0..b.start];
        // Dropping the block also drops the blank line that set it apart.
        if (commands.len == 0 and std.mem.endsWith(u8, head, "\n\n")) head = head[0 .. head.len - 1];
        try out.appendSlice(gpa, head);
        try out.appendSlice(gpa, block.items);
        try out.appendSlice(gpa, text[b.end..]);
    } else {
        try out.appendSlice(gpa, text);
        if (commands.len > 0) {
            if (text.len > 0 and text[text.len - 1] != '\n') try out.append(gpa, '\n');
            if (!std.mem.endsWith(u8, out.items, "\n\n") and out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, block.items);
        }
    }
    if (commands.len == 0 and onlyShebang(out.items)) return null;
    return try out.toOwnedSlice(gpa);
}

// ---- status ------------------------------------------------------------------------------

/// Process id in a pid file.
pub fn parsePid(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    const pid = std.fmt.parseInt(u32, trimmed[0..end], 10) catch return null;
    return if (pid <= 1) null else pid;
}

/// Name `pgrep -x` matches for a program: the kernel keeps the first 15 characters.
pub fn processName(exe: []const u8) []const u8 {
    const base = std.fs.path.basename(exe);
    return base[0..@min(base.len, 15)];
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

fn extract(content: []const u8) !?[]const []const u8 {
    return extractCommand(testing.allocator, content);
}

test "the program of the start function is the last absolute command it runs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sshd =
        \\#!/bin/sh
        \\if [ -r /etc/default/sshd ]; then
        \\  . /etc/default/sshd
        \\fi
        \\sshd_start() {
        \\  if [ ! -f /etc/ssh/ssh_host_dsa_key ]; then
        \\    /usr/bin/ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
        \\  fi
        \\  /usr/bin/ssh-keygen -A
        \\  /usr/sbin/sshd $SSHD_OPTS
        \\}
        \\sshd_stop() {
        \\  killall --ns $$ sshd
        \\}
        \\case "$1" in
        \\'start')
        \\  sshd_start
        \\  ;;
        \\esac
        \\
    ;
    try expectWords(&.{ "/usr/sbin/sshd", "$SSHD_OPTS" }, try extractCommand(a, sshd));
    const dbus =
        \\start() {
        \\  mkdir -p $(dirname $PIDFILE)
        \\    echo "Starting system message bus:  /usr/bin/dbus-uuidgen --ensure ; /usr/bin/dbus-daemon --system"
        \\    /usr/bin/dbus-uuidgen --ensure
        \\    /usr/bin/dbus-daemon --system 1> /dev/null
        \\}
        \\stop() {
        \\    killall dbus-daemon 1> /dev/null 2> /dev/null
        \\}
        \\
    ;
    try expectWords(&.{ "/usr/bin/dbus-daemon", "--system" }, try extractCommand(a, dbus));
}

test "variables and the start arm of a case give the program" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/crond", "-n" }, try extractCommand(a,
        \\#!/bin/sh
        \\CROND=/usr/sbin/crond
        \\case "$1" in
        \\'start')
        \\  mkdir -p /run/cron
        \\  $CROND -n &
        \\  ;;
        \\'stop')
        \\  pkill -f "^/usr/sbin/crond"
        \\  ;;
        \\esac
        \\
    ));
    try expectWords(&.{"/usr/sbin/foo"}, try extractCommand(a, "#!/bin/sh\nDAEMON=/usr/sbin/foo\necho nothing\n"));
    try testing.expect((try extractCommand(a, "#!/bin/sh\necho hello\n")) == null);
}

test "restart functions are not the start function" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{"/usr/sbin/real"}, try extractCommand(a,
        \\restart_foo() {
        \\  /usr/sbin/other
        \\}
        \\start_foo() {
        \\  /usr/sbin/real
        \\}
        \\
    ));
    _ = try extract("");
}

test "a block is appended, replaced and removed, and an empty hook script goes away" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const created = (try withBlock(a, null, &.{"x start"})).?;
    try testing.expectEqualStrings("#!/bin/sh\n\n# BEGIN fake-systemd\nx start\n# END fake-systemd\n", created);
    try testing.expect((try withBlock(a, null, &.{})) == null);
    const replaced = (try withBlock(a, created, &.{ "y start", "z start" })).?;
    try testing.expectEqualStrings("#!/bin/sh\n\n# BEGIN fake-systemd\ny start\nz start\n# END fake-systemd\n", replaced);
    try testing.expect((try withBlock(a, replaced, &.{})) == null);
    const user = "#!/bin/sh\n#\n# local\necho hi\n";
    const added = (try withBlock(a, user, &.{"x start"})).?;
    try testing.expectEqualStrings("#!/bin/sh\n#\n# local\necho hi\n\n# BEGIN fake-systemd\nx start\n# END fake-systemd\n", added);
    try testing.expectEqualStrings(user, (try withBlock(a, added, &.{})).?);
    const kept = "#!/bin/sh\n# BEGIN fake-systemd\nold\n# END fake-systemd\necho after\n";
    try testing.expectEqualStrings("#!/bin/sh\n# BEGIN fake-systemd\nnew\n# END fake-systemd\necho after\n", (try withBlock(a, kept, &.{"new"})).?);
    try testing.expectEqualStrings("#!/bin/sh\necho after\n", (try withBlock(a, kept, &.{})).?);
}

test "pid files and process names" {
    try testing.expectEqual(@as(?u32, 42), parsePid("42\n"));
    try testing.expectEqual(@as(?u32, 7), parsePid(" 7 extra\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("0\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("1\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("x"));
    try testing.expectEqualStrings("a-very-long-nam", processName("/usr/sbin/a-very-long-name-daemon"));
}

test "a hook script whose block is not closed exactly once is not rewritten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open = "#!/bin/sh\necho mine\n# BEGIN fake-systemd\nx start\necho user\n";
    try testing.expectError(error.MalformedBlock, withBlock(a, open, &.{"y start"}));
    try testing.expectError(error.MalformedBlock, withBlock(a, open, &.{}));
    try testing.expectEqual(@as(usize, 3), blockFault(open).?.line);
    const twice = "# BEGIN fake-systemd\na\n# END fake-systemd\n# BEGIN fake-systemd\nb\n# END fake-systemd\n";
    try testing.expectError(error.MalformedBlock, withBlock(a, twice, &.{"y start"}));
    try testing.expect(blockFault("#!/bin/sh\n") == null);
}
