// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading finit files and tool output: the command of a `service`, `task`, `run` or `sysv`
//! stanza, the flags recorded in a generated file, the state of a service from `initctl status`,
//! and the identities `initctl ls` lists.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const execline = @import("../../unit/execline.zig");

// ---- command of a stanza ---------------------------------------------------------------

const stanza_keywords = [_][]const u8{ "service", "task", "run", "sysv" };

/// Words of a stanza that finit reads as options and not as the command; the last group
/// matches by prefix, as finit does.
const option_prefixes = [_][]const u8{
    "log",          "pid",       "name:",    "notify:",  "type:forking", "manual:yes", "restart:", "restarttmo:",
    "restart_sec:", "norestart", "nowarn",   "oncrash:", "respawn",      "halt:",      "kill:",    "pre:",
    "post:",        "ready:",    "cleanup:", "env:",     "cgroup",       "conflict:",  "if:",
};

fn isOption(word: []const u8) bool {
    if (word.len == 0) return false;
    switch (word[0]) {
        '@', '[', '<', ':' => return true,
        else => {},
    }
    for (option_prefixes) |p| if (std.mem.startsWith(u8, word, p)) return true;
    return false;
}

/// Stanza keyword at the start of `line`, with the rest of the line after it.
fn stanzaOf(line: []const u8) ?struct { keyword: []const u8, rest: []const u8 } {
    const end = std.mem.findAny(u8, line, " \t") orelse return null;
    const word = line[0..end];
    for (stanza_keywords) |k| if (std.mem.eql(u8, k, word)) return .{ .keyword = k, .rest = line[end..] };
    return null;
}

/// First stanza of a file: its keyword, its options and its command words.
pub const Stanza = struct {
    keyword: []const u8,
    options: []const []const u8,
    command: []const []const u8,
};

/// The first stanza, with the description after `-- ` dropped. A file without a stanza, or
/// with one whose words cannot be read, has none.
pub fn firstStanza(gpa: Allocator, content: []const u8) Allocator.Error!?Stanza {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const stanza = stanzaOf(line) orelse continue;
        var text = stanza.rest;
        if (std.mem.find(u8, text, "-- ")) |at| text = text[0..at];
        const trimmed = std.mem.trimEnd(u8, text, " \t");
        if (std.mem.endsWith(u8, trimmed, " --")) text = trimmed[0 .. trimmed.len - 3];
        const words = execline.splitWords(gpa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        var first: usize = 0;
        while (first < words.len and isOption(words[first])) first += 1;
        if (first >= words.len) return null;
        return .{ .keyword = stanza.keyword, .options = words[0..first], .command = words[first..] };
    }
    return null;
}

/// Command words of the first stanza.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    const s = (try firstStanza(gpa, content)) orelse return null;
    return s.command;
}

/// Keyword (`service`, `task`, `run`, `sysv`) of the first stanza of `content`.
pub fn kindOf(gpa: Allocator, content: []const u8) Allocator.Error!?[]const u8 {
    const s = (try firstStanza(gpa, content)) orelse return null;
    return s.keyword;
}

/// Identity `initctl` knows the first stanza by: `name:` and `:ID` as written, else the base
/// name of the command.
pub fn identityOf(gpa: Allocator, content: []const u8) Allocator.Error!?[]const u8 {
    const s = (try firstStanza(gpa, content)) orelse return null;
    var name: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    for (s.options) |o| {
        if (std.mem.startsWith(u8, o, "name:")) name = o["name:".len..];
        if (o.len > 1 and o[0] == ':') id = o[1..];
    }
    const base = name orelse std.fs.path.basename(s.command[0]);
    if (id) |i| return try std.fmt.allocPrint(gpa, "{s}:{s}", .{ base, i });
    return base;
}

/// The conditions of the first stanza, such as `service/db/running`.
pub fn conditionsOf(gpa: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    const s = (try firstStanza(gpa, content)) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (s.options) |o| {
        const inner = std.mem.cutPrefix(u8, o, "<") orelse continue;
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, inner, ">"), ',');
        while (it.next()) |c| try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

// ---- flags -----------------------------------------------------------------------------

pub const flags_prefix = "# flags:";

/// What the backend needs to read back from a generated file.
pub const Flags = struct {
    /// A oneshot that finit keeps as `done` but that is `inactive` once it succeeded.
    transient: bool = false,
};

pub fn parseFlags(rest: []const u8) Flags {
    var out: Flags = .{};
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        const tail = std.mem.cutPrefix(u8, line, flags_prefix) orelse continue;
        var it = std.mem.tokenizeScalar(u8, tail, ' ');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "transient")) out.transient = true;
        }
        break;
    }
    return out;
}

// ---- status ----------------------------------------------------------------------------

/// How a process ended, as `initctl status` prints it in the `Status` line.
pub const Ended = union(enum) {
    none,
    code: u8,
    signal: u8,
};

pub const Parsed = struct {
    /// First word of the `Status` line: `running`, `crashed`, `done`, ...
    word: []const u8 = "",
    ended: Ended = .none,
    pid: ?u32 = null,
    /// Largest number of restarts finit allows: 0 for `norestart`, -1 without a limit.
    restart_max: ?i32 = null,
};

fn valueOf(line: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const rest = std.mem.cutPrefix(u8, trimmed, key) orelse return null;
    const after = std.mem.trimStart(u8, rest, " \t");
    const value = std.mem.cutPrefix(u8, after, ":") orelse return null;
    return std.mem.trim(u8, value, " \t\r");
}

fn endedOf(detail: []const u8) Ended {
    const open = std.mem.findScalar(u8, detail, '(') orelse return .none;
    const inner = detail[open + 1 ..];
    const st = std.mem.find(u8, inner, "status=") orelse return .none;
    const digits = inner[st + "status=".len ..];
    const end = std.mem.findNone(u8, digits, "0123456789") orelse digits.len;
    const n = std.fmt.parseInt(u8, digits[0..end], 10) catch return .none;
    if (std.mem.startsWith(u8, inner, "code=signal")) return .{ .signal = n };
    if (std.mem.startsWith(u8, inner, "code=exited")) return .{ .code = n };
    return .none;
}

/// Reads the `Status` and `PID` lines of `initctl -p status <name>`.
pub fn parseStatusText(text: []const u8) Parsed {
    var out: Parsed = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (valueOf(line, "Status")) |v| {
            const end = std.mem.findAny(u8, v, " (") orelse v.len;
            out.word = v[0..end];
            out.ended = endedOf(v[end..]);
        } else if (valueOf(line, "Restarts")) |v| {
            const slash = std.mem.findScalarLast(u8, v, '/') orelse continue;
            const close = std.mem.findScalarPos(u8, v, slash, ')') orelse continue;
            out.restart_max = std.fmt.parseInt(i32, v[slash + 1 .. close], 10) catch null;
        } else if (valueOf(line, "PID")) |v| {
            const pid = std.fmt.parseInt(u32, v, 10) catch continue;
            if (pid > 0) out.pid = pid;
        }
    }
    return out;
}

/// Normalized state. A service that exits is `crashed` in finit whatever its status; a clean
/// exit is not a failure, and neither is a stop by SIGTERM or SIGINT.
pub fn stateOf(p: Parsed, flags: Flags) output.ActiveState {
    const w = p.word;
    if (std.mem.eql(u8, w, "running")) return .active;
    // A service that may not restart and whose process ended stays in `restart` after a manual start.
    const crashed = std.mem.eql(u8, w, "crashed") or (std.mem.eql(u8, w, "restart") and p.restart_max == 0);
    if (eqlAny(w, &.{ "starting", "setup", "waiting", "restart", "busy" }) and !crashed) return .activating;
    if (eqlAny(w, &.{ "stopping", "teardown", "cleanup" })) return .deactivating;
    if (std.mem.eql(u8, w, "active")) return .activating;
    if (std.mem.eql(u8, w, "failed")) return .failed;
    if (crashed) return if (cleanEnd(p.ended)) .inactive else .failed;
    if (std.mem.eql(u8, w, "done")) {
        if (!cleanEnd(p.ended)) return .failed;
        return if (flags.transient) .inactive else .active;
    }
    return .inactive;
}

fn cleanEnd(e: Ended) bool {
    return switch (e) {
        .none => true,
        .code => |c| c == 0,
        .signal => |s| s == 15 or s == 2,
    };
}

fn eqlAny(word: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, word)) return true;
    return false;
}

/// Process id in a pid file, or an exit status in an exit file; digits only.
pub fn parseNumber(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(u32, t, 10) catch null;
}

/// How the main process ended, from the file `fake-systemd --exec --record-exit` writes.
pub const Exit = enum { ok, failed };

pub fn parseExit(text: []const u8) ?Exit {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return std.meta.stringToEnum(Exit, it.next() orelse return null);
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command follows the options of a stanza" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/sshd", "-D" }, try extractCommand(a, "# start sshd\nservice [2345] <net/lo/up> env:-/etc/default/ssh /usr/sbin/sshd -D -- OpenSSH daemon\n"));
    try expectWords(&.{ "/bin/foo", "--serve" }, try extractCommand(a, "service @www:www [2345] <pid/db> name:foo log:/var/log/foo restart:5 kill:10 /bin/foo --serve\n"));
    try expectWords(&.{ "/usr/bin/fake-systemd", "--exec", "foo.service" }, try extractCommand(a, "\ttask [2345] name:foo /usr/bin/fake-systemd --exec foo.service --\n"));
    try expectWords(&.{"/etc/init.d/rc.local"}, try extractCommand(a, "sysv [S] /etc/init.d/rc.local -- local\n"));
    try testing.expect(try extractCommand(a, "# only a comment\nset foo=bar\n") == null);
    try testing.expect(try extractCommand(a, "service [2345]\n") == null);
}
test "the keyword, identity and conditions of the first stanza are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("task", (try kindOf(a, "# c\ntask [2] /bin/true\n")).?);
    try testing.expectEqualStrings("service", (try kindOf(a, "service /bin/x\ntask /bin/y\n")).?);
    try testing.expect(try kindOf(a, "tty [12345] /dev/tty1\n") == null);
    try testing.expectEqualStrings("foo", (try identityOf(a, "service [2345] name:foo /usr/bin/x\n")).?);
    try testing.expectEqualStrings("sshd", (try identityOf(a, "service [2345] /usr/sbin/sshd -D\n")).?);
    try testing.expectEqualStrings("httpd:80", (try identityOf(a, "service :80 [2345] /usr/sbin/httpd -f\n")).?);
    const conds = try conditionsOf(a, "service [2345] <service/db/running,net/route/default> name:x /bin/x\n");
    try testing.expectEqual(@as(usize, 2), conds.len);
    try testing.expectEqualStrings("service/db/running", conds[0]);
    try testing.expectEqualStrings("net/route/default", conds[1]);
    try testing.expectEqual(@as(usize, 0), (try conditionsOf(a, "service /bin/x\n")).len);
}

test "flags are read from the comment line" {
    try testing.expect(parseFlags("# flags: transient\nservice x\n").transient);
    try testing.expect(!parseFlags("service x\n").transient);
}

fn expectState(state: output.ActiveState, pid: ?u32, text: []const u8, flags: Flags) !void {
    const p = parseStatusText(text);
    try testing.expectEqual(state, stateOf(p, flags));
    try testing.expectEqual(pid, p.pid);
}

test "statuses observed from finit 4.12 map to systemd states" {
    const none: Flags = .{};
    try expectState(.active, 53, "     Status : running\n   Identity : t1\nDescription : Test one\n        PID : 53\n       User : root\n", none);
    try expectState(.inactive, null, "     Status : stopped (code=exited, status=0/SUCCESS, manual=yes)\n   Identity : t4\n        PID : 0\n", none);
    try expectState(.inactive, null, "     Status : stopped (code=signal, status=15/TERM)\n        PID : 0\n", none);
    try expectState(.inactive, null, "     Status : crashed (code=exited, status=0/SUCCESS)\n        PID : 0\n", none);
    try expectState(.failed, null, "     Status : crashed (code=exited, status=2/INVALIDARGUMENT)\n        PID : 0\n", none);
    try expectState(.failed, null, "     Status : crashed (code=signal, status=9/KILL)\n        PID : 0\n", none);
    try expectState(.activating, null, "     Status : restart (code=exited, status=1/FAILURE)\n        PID : 0\n", none);
    try expectState(.activating, null, "     Status : waiting\n        PID : 0\n", none);
    try expectState(.failed, null, "     Status : restart (code=exited, status=3/NOTIMPLEMENTED)\n        PID : 0\n   Restarts : 0 (0/0)\n", none);
    try expectState(.activating, null, "     Status : restart (code=exited, status=3/NOTIMPLEMENTED)\n        PID : 0\n   Restarts : 2 (1/-1)\n", none);
    try expectState(.failed, null, "     Status : done (code=exited, status=3/NOTIMPLEMENTED)\n        PID : 0\n", none);
    try expectState(.active, null, "     Status : done (code=exited, status=0/SUCCESS)\n", none);
    try expectState(.inactive, null, "     Status : done (code=exited, status=0/SUCCESS)\n", .{ .transient = true });
    try expectState(.inactive, null, "     Status : missing\n", none);
    try expectState(.inactive, null, "", none);
    try expectState(.inactive, null, "initctl: no such task or service(s): nosuch\n", none);
}

test "exit files and numbers" {
    try testing.expectEqual(Exit.ok, parseExit("ok 0\n").?);
    try testing.expectEqual(Exit.failed, parseExit("failed 2\n").?);
    try testing.expect(parseExit("") == null);
    try testing.expectEqual(@as(?u32, 42), parseNumber(" 42\n"));
    try testing.expect(parseNumber("x") == null);
}
