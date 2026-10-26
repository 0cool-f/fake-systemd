// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading nosh files and tool output: the command of a bundle's `run` script, the record of the
//! unit a bundle is converted from, and the state of a service from `system-control status`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const execline = @import("../../unit/execline.zig");

// ---- command of a bundle ---------------------------------------------------------------

/// The command words of a `run` script: the last line that is not a comment, after the lines that
/// set up the environment of a nosh script, each of which chain-loads the next.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var last: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        last = line;
    }
    const line = last orelse return null;
    const words = execline.splitWords(gpa, line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (words.len == 0) return null;
    // `sh -c "exec /bin/foo args"` is how the converter writes a command with variables.
    if (words.len == 3 and std.mem.eql(u8, words[0], "sh") and std.mem.eql(u8, words[1], "-c")) {
        const inner = std.mem.cutPrefix(u8, words[2], "exec ") orelse words[2];
        return execline.splitWords(gpa, inner) catch return words;
    }
    return words;
}

// ---- record of a converted unit ----------------------------------------------------------

pub const Record = struct {
    /// Directory of the unit file, where its drop-ins sit.
    directory: []const u8,
    /// Name of the unit, with the instance.
    unit: []const u8,
    /// Hash of the files of the unit when the record was made.
    hash: []const u8,
};

fn keyValue(line: []const u8, key: []const u8) ?[]const u8 {
    const rest = std.mem.cutPrefix(u8, line, key) orelse return null;
    const value = std.mem.cutPrefix(u8, rest, " ") orelse return null;
    return std.mem.trim(u8, value, " \t\r");
}

pub fn parseRecord(body: []const u8) ?Record {
    var out: Record = .{ .directory = "", .unit = "", .hash = "" };
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (keyValue(line, "directory")) |v| out.directory = v;
        if (keyValue(line, "unit")) |v| out.unit = v;
        if (keyValue(line, "hash")) |v| out.hash = v;
    }
    if (out.directory.len == 0 or out.unit.len == 0) return null;
    return out;
}

// ---- status ----------------------------------------------------------------------------

pub const Ended = union(enum) {
    none,
    exit: u32,
    signal: u32,
};

pub const Parsed = struct {
    /// `running`, `stopped`, `done`, `ready`, ...
    state: []const u8 = "",
    /// How the last run of the service ended.
    ran: Ended = .none,
    pid: ?u32 = null,
};

fn lineValue(line: []const u8, key: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    const rest = std.mem.cutPrefix(u8, t, key) orelse return null;
    const after = std.mem.trimStart(u8, rest, " ");
    const value = std.mem.cutPrefix(u8, after, ":") orelse return null;
    return std.mem.trim(u8, value, " \t");
}

fn firstWord(text: []const u8) []const u8 {
    const end = std.mem.findAny(u8, text, " ;") orelse text.len;
    return text[0..end];
}

fn numberAfter(text: []const u8) ?u32 {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    _ = it.next() orelse return null;
    const digits = it.next() orelse return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// Reads the lines of `system-control status <name>`.
pub fn parseStatus(text: []const u8) Parsed {
    var out: Parsed = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lineValue(line, "State")) |v| out.state = firstWord(v);
        if (lineValue(line, "Main PID")) |v| out.pid = std.fmt.parseInt(u32, firstWord(v), 10) catch null;
        if (lineValue(line, "Ran")) |v| {
            const n = numberAfter(v);
            if (std.mem.startsWith(u8, v, "exit")) out.ran = .{ .exit = n orelse 0 } else out.ran = .{ .signal = n orelse 0 };
        }
    }
    return out;
}

fn cleanEnd(e: Ended) bool {
    return switch (e) {
        .none => true,
        .exit => |c| c == 0,
        .signal => |s| s == 15 or s == 2 or s == 1 or s == 13,
    };
}

/// Normalized state. A service that stopped after a run that did not end well is failed, and a
/// oneshot that is `done` is inactive when its run succeeded.
pub fn stateOf(p: Parsed) output.ActiveState {
    const s = p.state;
    // `started` is a run script that is still executing in a service that is ready after it ends.
    if (eqlAny(s, &.{ "running", "ready" })) return .active;
    if (eqlAny(s, &.{ "starting", "started", "loading" })) return .activating;
    if (std.mem.eql(u8, s, "stopping")) return .deactivating;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (eqlAny(s, &.{ "stopped", "done" })) return if (cleanEnd(p.ran)) .inactive else .failed;
    return .inactive;
}

/// States nosh shows for the moment a service changes state; a start asked then is never answered.
pub fn isTransient(state: []const u8) bool {
    return eqlAny(state, &.{ "failed", "stopping", "starting" });
}

fn eqlAny(word: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, word)) return true;
    return false;
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command is the last line of a run script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/bin/sleep", "1000" }, try extractCommand(a, "#!/bin/nosh\n#Run file generated from ./foo.service\nmove-to-control-group ../foo.service\ngetuidgid\nchdir /\nuserenv-fromenv\n/bin/sleep 1000"));
    try expectWords(&.{ "/bin/sleep", "5", "$A" }, try extractCommand(a, "#!/bin/nosh\nsetenv A 1\nsh -c \"exec /bin/sleep 5 $A\"\n"));
    try testing.expect(try extractCommand(a, "#!/bin/nosh\n# nothing\n") == null);
}

test "a record names the directory and the unit" {
    const r = parseRecord("# note\ndirectory /usr/lib/systemd/system\nunit foo@bar.service\nhash xxh3:00ff\n").?;
    try testing.expectEqualStrings("/usr/lib/systemd/system", r.directory);
    try testing.expectEqualStrings("foo@bar.service", r.unit);
    try testing.expectEqualStrings("xxh3:00ff", r.hash);
    try testing.expect(parseRecord("unit x.service\n") == null);
}

fn expectState(state: output.ActiveState, pid: ?u32, text: []const u8) !void {
    const p = parseStatus(text);
    try testing.expectEqual(state, stateOf(p));
    try testing.expectEqual(pid, p.pid);
}

test "statuses observed from nosh 1.41 map to systemd states" {
    try expectState(.active, 224, "/etc/service-bundles/services/okk: \n\tState   : running since 2026-10-26 19:53:45 +0000; 2s ago\n\tMain PID: 224\n\t Started: exit 0 at 2026-10-26 19:53:45 +0000; 2s ago\n\tConfig  : enabled\n");
    try expectState(.failed, null, "/x/bad: \n\tState   : stopped since 2026-10-26 19:53:47 +0000; 1s ago\n\t Started: exit 0 at x\n\t     Ran: exit 3 at x\n\tRestartd: exit 1 at x\n");
    try expectState(.inactive, null, "/x/once: \n\tState   : done since x\n\t Started: exit 0 at x\n\t     Ran: exit 0 at x\n\tConfig  : enabled, ready after run\n");
    try expectState(.active, null, "/x/r: \n\tState   : ready since x\n\t     Ran: exit 0 at x\n");
    try expectState(.failed, null, "/x/oncebad: \n\tState   : done since x\n\t     Ran: exit 1 at x\n");
    try expectState(.inactive, null, "/x/okk: \n\tState   : stopped since x\n\t     Ran: term 15 TERM at x\n");
    try expectState(.failed, null, "/x/k: \n\tState   : stopped since x\n\t     Ran: kill 9 KILL at x\n");
    try expectState(.activating, null, "/x/s: \n\tState   : starting since x\n");
    try expectState(.activating, 7, "/x/o: \n\tState   : started since x\n\tMain PID: 7\n");
    try expectState(.inactive, null, "/x/s: \n\tState   : stopped since x\n");
    try expectState(.inactive, null, "/etc/service-bundles/services/foo: supervise/ok: No such file or directory\n");
    try expectState(.inactive, null, "");
}

test "the moments between two states are recognised" {
    try testing.expect(isTransient("failed"));
    try testing.expect(isTransient("stopping"));
    try testing.expect(!isTransient("stopped"));
    try testing.expect(!isTransient("running"));
}
