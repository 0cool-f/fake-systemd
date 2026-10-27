// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading runit files and `sv` output: the command of a `run` script, the services a
//! generated `run` starts first, and the state of a service from `sv status`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const interface = @import("../interface.zig");
const execline = @import("../../unit/execline.zig");
const render = @import("render.zig");

fn isRedirect(word: []const u8) bool {
    var i: usize = 0;
    while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
    return i < word.len and (word[i] == '<' or word[i] == '>');
}

/// Drops a trailing ` # comment` that is outside quotes.
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

/// Command words of the last `exec` line of a `run` script, with leading and trailing
/// redirections dropped. An `exec` that only redirects (`exec 2>&1`) has no command, and a
/// script without `exec` has none either.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var last: ?[]const []const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.endsWith(u8, line, "\\")) {
            try joined.appendSlice(gpa, line[0 .. line.len - 1]);
            try joined.append(gpa, ' ');
            continue;
        }
        try joined.appendSlice(gpa, line);
        const text = std.mem.trim(u8, stripComment(joined.items), " \t");
        defer joined.clearRetainingCapacity();
        const rest = std.mem.cutPrefix(u8, text, "exec") orelse continue;
        if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) continue;
        const words = execline.splitWords(gpa, rest) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        var start: usize = 0;
        while (start < words.len and isRedirect(words[start])) start += 1;
        var end = words.len;
        while (end > start and (isRedirect(words[end - 1]) or std.mem.eql(u8, words[end - 1], "&"))) end -= 1;
        if (end > start) last = words[start..end];
    }
    return last;
}

/// How the last run of a service ended, as recorded by its `finish` script.
pub const Verdict = enum { ok, failed };

pub fn parseVerdict(text: []const u8) ?Verdict {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const word = it.next() orelse return null;
    return std.meta.stringToEnum(Verdict, word);
}

/// First field of the status line before `;`, which is the service itself; the log service
/// follows.
fn serviceSegment(text: []const u8) []const u8 {
    const first = if (std.mem.findScalar(u8, text, '\n')) |nl| text[0..nl] else text;
    return if (std.mem.findScalar(u8, first, ';')) |semi| first[0..semi] else first;
}

fn pidOf(segment: []const u8) ?u32 {
    const open = std.mem.find(u8, segment, "(pid ") orelse return null;
    const rest = segment[open + "(pid ".len ..];
    const close = std.mem.findScalar(u8, rest, ')') orelse return null;
    return std.fmt.parseInt(u32, rest[0..close], 10) catch null;
}

fn hasFlag(segment: []const u8, flag: []const u8) bool {
    return std.mem.find(u8, segment, flag) != null;
}

/// Normalizes the output of `sv status`. Anything that is not a status line (`fail:`,
/// `warning:`, empty output) counts as inactive: the service is not supervised.
/// `verdict` is the recorded end of the last run and tells a failure from a clean stop.
pub fn parseStatus(text: []const u8, verdict: ?Verdict) interface.Status {
    const segment = serviceSegment(text);
    const pid = pidOf(segment);
    var state: output.ActiveState = .inactive;
    if (std.mem.startsWith(u8, segment, "run: ")) {
        state = if (hasFlag(segment, ", want down")) .deactivating else .active;
    } else if (std.mem.startsWith(u8, segment, "finish: ")) {
        state = .deactivating;
    } else if (std.mem.startsWith(u8, segment, "down: ")) {
        state = if (hasFlag(segment, ", want up"))
            .activating
        else if (verdict != null and verdict.? == .failed)
            .failed
        else
            .inactive;
    }
    return .{ .state = state, .pid = pid, .text = text };
}

/// Seconds `sv` waits for the start and the stop, from the waits line of a generated `run`.
pub fn parseWaits(rest: []const u8) render.Waits {
    var out: render.Waits = .{};
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        const tail = std.mem.cutPrefix(u8, line, render.waits_prefix) orelse continue;
        var it = std.mem.tokenizeScalar(u8, tail, ' ');
        while (it.next()) |tok| {
            if (std.mem.cutPrefix(u8, tok, "start=")) |v| out.start = std.fmt.parseInt(u64, v, 10) catch null;
            if (std.mem.cutPrefix(u8, tok, "stop=")) |v| out.stop = std.fmt.parseInt(u64, v, 10) catch null;
        }
        break;
    }
    return out;
}

/// True when `sv status` printed the status of a service, so a `runsv` supervises it.
pub fn hasStatusLine(text: []const u8) bool {
    for ([_][]const u8{ "run: ", "down: ", "finish: " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }
    return false;
}

/// True when the output of `sv` says no `runsv` supervises the service yet.
pub fn notSupervised(text: []const u8) bool {
    return std.mem.find(u8, text, "runsv not running") != null or
        std.mem.find(u8, text, "unable to open supervise/") != null;
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the last exec of a run script gives the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/sshd", "-D", "$OPTS" }, try extractCommand(a,
        \\#!/bin/sh
        \\exec 2>&1
        \\ssh-keygen -A >/dev/null 2>&1 # Will generate host keys
        \\[ -r conf ] && . ./conf
        \\exec /usr/bin/sshd -D $OPTS
        \\
    ));
    try expectWords(&.{ "chpst", "-u", "svc", "/usr/bin/foo", "--bar" }, try extractCommand(a, "#!/bin/sh\nexec chpst -u svc \\\n    /usr/bin/foo --bar 2>&1\n"));
    try expectWords(&.{ "dhcpcd", "-B", "-M" }, try extractCommand(a, "exec dhcpcd -B -M 1>&2\n"));
    try expectWords(&.{"/usr/bin/b"}, try extractCommand(a, "exec /usr/bin/a\nexec >/dev/null /usr/bin/b &\n"));
    try testing.expect(try extractCommand(a, "#!/bin/sh\nexec 2>&1\nsleep 1\n") == null);
    try testing.expect(try extractCommand(a, "#!/bin/sh\n# exec /usr/bin/commented\n") == null);
    try testing.expect(try extractCommand(a, "") == null);
}

fn expectStatus(state: output.ActiveState, pid: ?u32, verdict: ?Verdict, text: []const u8) !void {
    const s = parseStatus(text, verdict);
    try testing.expectEqual(state, s.state);
    try testing.expectEqual(pid, s.pid);
}

test "statuses observed from sv 2.3.1 map to systemd states" {
    try expectStatus(.active, 35, null, "run: sleeper: (pid 35) 5s\n");
    try expectStatus(.active, 47, null, "run: dn: (pid 47) 0s, normally down\n");
    try expectStatus(.active, 242, null, "run: logged: (pid 242) 1s; run: log: (pid 241) 1s\n");
    try expectStatus(.deactivating, 131, null, "run: stubborn: (pid 131) 3s, want down, got TERM\n");
    try expectStatus(.deactivating, 9, null, "finish: fin: (pid 9) 0s\n");
    try expectStatus(.inactive, null, null, "down: sleeper: 1s, normally up\n");
    try expectStatus(.inactive, null, null, "down: logged: 0s, normally up; run: log: (pid 241) 1s\n");
    try expectStatus(.inactive, null, .ok, "down: once1: 4s, normally up\n");
    try expectStatus(.failed, null, .failed, "down: rec: 3s, normally up\n");
    try expectStatus(.activating, null, null, "down: failer: 1s, normally up, want up\n");
    try expectStatus(.activating, null, .failed, "down: failer: 0s, want up\n");
    try expectStatus(.inactive, null, null, "down: dn: 1s\n");
    try expectStatus(.inactive, null, null, "fail: sleeper: unable to change to service directory: file does not exist\n");
    try expectStatus(.inactive, null, null, "fail: x: runsv not running\n");
    try expectStatus(.inactive, null, null, "warning: sleeper: unable to open supervise/ok: file does not exist\n");
    try expectStatus(.inactive, null, null, "");
}

test "a status line means a runsv supervises the service" {
    try testing.expect(hasStatusLine("run: x: (pid 1) 2s\n"));
    try testing.expect(hasStatusLine("down: x: 2s, normally up\n"));
    try testing.expect(hasStatusLine("finish: x: (pid 1) 2s\n"));
    try testing.expect(!hasStatusLine("fail: x: runsv not running\n"));
    try testing.expect(!hasStatusLine(""));
}

test "unsupervised services are recognised in sv output" {
    try testing.expect(notSupervised("fail: x: runsv not running\n"));
    try testing.expect(notSupervised("warning: x: unable to open supervise/ok: file does not exist\n"));
    try testing.expect(notSupervised("warning: x: unable to open supervise/control: file does not exist\n"));
    try testing.expect(!notSupervised("timeout: down: x: 7s, normally up, want up\n"));
    try testing.expect(!notSupervised(""));
}

test "verdicts are read from the first word" {
    try testing.expectEqual(@as(?Verdict, .ok), parseVerdict("ok 0 0\n"));
    try testing.expectEqual(@as(?Verdict, .failed), parseVerdict("failed 3 0\n"));
    try testing.expectEqual(@as(?Verdict, null), parseVerdict("garbage\n"));
    try testing.expectEqual(@as(?Verdict, null), parseVerdict(""));
}

test "waits are read from the waits line" {
    const w = parseWaits("# sv waits: start=30 stop=4294967295\nexec 2>&1\n");
    try testing.expectEqual(@as(?u64, 30), w.start);
    try testing.expectEqual(@as(?u64, 4294967295), w.stop);
    const only = parseWaits("# sv waits: stop=5\n");
    try testing.expectEqual(@as(?u64, null), only.start);
    try testing.expectEqual(@as(?u64, 5), only.stop);
    try testing.expectEqual(@as(?u64, null), parseWaits("exec 2>&1\n").stop);
}
