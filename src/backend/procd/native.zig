// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading procd files: the command of an init script, its `START` and `STOP` priorities, and
//! the answer of `ubus call service list`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const script = @import("../bsdrc/script.zig");

// ---- command of a script -----------------------------------------------------------------

/// Command words of an init script: the arguments of the first `procd_set_param command`,
/// `procd_add_instance`, `service_start` or `service -S`, with the variables the script assigned
/// before expanded. Null when the program stays unknown, as when it comes from a file the
/// script sources.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var vars: std.ArrayList(script.Var) = .empty;
    var lines: script.Lines = .{ .text = content };
    while (try lines.next(gpa)) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        for (try script.splitCommands(gpa, line)) |all| {
            const words = script.trimCommand(all);
            if (words.len == 0) continue;
            if (try script.recordAssignments(gpa, words, &vars)) continue;
            const tail = commandWords(words) orelse continue;
            if (tail.len == 0) continue;
            const exe = (try script.expand(gpa, tail[0], vars.items)) orelse continue;
            if (exe.len == 0 or exe[0] != '/') continue;
            var out: std.ArrayList([]const u8) = .empty;
            try out.append(gpa, exe);
            for (script.withoutRedirects(tail[1..])) |a| try out.append(gpa, (try script.expand(gpa, a, vars.items)) orelse a);
            return try out.toOwnedSlice(gpa);
        }
    }
    return null;
}

/// The words of the command a procd call starts, after the call itself.
fn commandWords(words: script.Command) ?script.Command {
    const name = words[0];
    if (std.mem.eql(u8, name, "procd_set_param") or std.mem.eql(u8, name, "procd_append_param")) {
        if (words.len >= 2 and std.mem.eql(u8, words[1], "command")) return words[2..];
        return null;
    }
    if (std.mem.eql(u8, name, "procd_add_instance") or std.mem.eql(u8, name, "service_start")) return words[1..];
    if (std.mem.eql(u8, name, "service") and words.len >= 3 and std.mem.eql(u8, words[1], "-S")) return words[2..];
    return null;
}

// ---- script variables --------------------------------------------------------------------

/// True when the script sets `USE_PROCD=1`, so that its `start` registers instances with procd.
pub fn usesProcd(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const value = std.mem.cutPrefix(u8, line, "USE_PROCD=") orelse continue;
        const bare = std.mem.trim(u8, value, "\"'");
        if (bare.len > 0 and !std.mem.eql(u8, bare, "0")) return true;
    }
    return false;
}

pub const Priorities = struct {
    start: ?u8 = null,
    stop: ?u8 = null,
};

fn priority(text: []const u8) ?u8 {
    const bare = std.mem.trim(u8, text, " \t\"'");
    const n = std.fmt.parseInt(u8, bare, 10) catch return null;
    return if (n <= 99) n else null;
}

/// `START=` and `STOP=` of a script; the first assignment of each counts.
pub fn parsePriorities(content: []const u8) Priorities {
    var p: Priorities = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (p.start == null) if (std.mem.cutPrefix(u8, line, "START=")) |v| {
            p.start = priority(v);
        };
        if (p.stop == null) if (std.mem.cutPrefix(u8, line, "STOP=")) |v| {
            p.stop = priority(v);
        };
    }
    return p;
}

// ---- state -------------------------------------------------------------------------------

pub const State = struct {
    state: output.ActiveState,
    pid: ?u32 = null,
};

fn intOf(v: ?std.json.Value) ?i64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

/// State of `service` in the output of `ubus call service list`: active when an instance runs,
/// failed when none does and one ended with a failure, inactive otherwise. A service procd does
/// not list has no instances and is inactive.
pub fn stateOfListing(gpa: Allocator, text: []const u8, service: []const u8) Allocator.Error!State {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .{ .state = .inactive };
    const root = std.json.parseFromSliceLeaky(std.json.Value, gpa, trimmed, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .state = .inactive },
    };
    if (root != .object) return .{ .state = .inactive };
    const entry = root.object.get(service) orelse return .{ .state = .inactive };
    if (entry != .object) return .{ .state = .inactive };
    const instances = entry.object.get("instances") orelse return .{ .state = .inactive };
    if (instances != .object) return .{ .state = .inactive };
    var failed = false;
    var it = instances.object.iterator();
    while (it.next()) |kv| {
        const inst = kv.value_ptr.*;
        if (inst != .object) continue;
        const running = if (inst.object.get("running")) |r| (r == .bool and r.bool) else false;
        if (running) {
            const pid = intOf(inst.object.get("pid"));
            return .{ .state = .active, .pid = if (pid) |p| std.math.cast(u32, p) else null };
        }
        if (intOf(inst.object.get("exit_code"))) |code| if (code != 0) {
            failed = true;
        };
    }
    return .{ .state = if (failed) .failed else .inactive };
}

/// True for the help text `rc.common` prints for a verb the script does not define.
pub fn looksLikeHelp(text: []const u8) bool {
    return std.mem.find(u8, text, "Available commands:") != null or std.ascii.findIgnoreCase(text, "usage:") != null;
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command of a procd script comes from the instance it registers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/dropbear", "-F", "-P", "/var/run/dropbear.pid" }, try extractCommand(a,
        \\#!/bin/sh /etc/rc.common
        \\USE_PROCD=1
        \\START=19
        \\PROG=/usr/sbin/dropbear
        \\start_service() {
        \\  procd_open_instance
        \\  procd_set_param command "$PROG" -F -P /var/run/dropbear.pid
        \\  procd_set_param respawn
        \\  procd_close_instance
        \\}
        \\
    ));
    try expectWords(&.{ "/usr/sbin/crond", "-f", "-S" }, try extractCommand(a, "start_service() {\n\tprocd_add_instance /usr/sbin/crond -f -S\n}\n"));
    try expectWords(&.{ "/usr/sbin/ntpd", "-n" }, try extractCommand(a, "start() {\n\tservice_start /usr/sbin/ntpd -n\n}\n"));
    try expectWords(&.{ "/usr/sbin/old", "-x" }, try extractCommand(a, "start() {\n\tservice -S /usr/sbin/old -x\n}\n"));
    try testing.expect((try extractCommand(a, "start_service() {\n\tprocd_set_param command $UNKNOWN\n}\n")) == null);
    try testing.expect((try extractCommand(a, "start() {\n\techo hi\n}\n")) == null);
}

test "USE_PROCD and the priorities are read from the assignments" {
    try testing.expect(usesProcd("#!/bin/sh /etc/rc.common\nUSE_PROCD=1\n"));
    try testing.expect(!usesProcd("#!/bin/sh /etc/rc.common\nSTART=10\n"));
    try testing.expect(!usesProcd("USE_PROCD=0\n"));
    const p = parsePriorities("START=19\nSTOP=\"50\"\nSTART=3\n");
    try testing.expectEqual(@as(?u8, 19), p.start);
    try testing.expectEqual(@as(?u8, 50), p.stop);
    try testing.expectEqual(@as(?u8, null), parsePriorities("START=${X}\n").start);
    try testing.expectEqual(@as(?u8, null), parsePriorities("START=100\n").start);
}

test "a running instance is active, a failed one failed, and no service inactive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const running = try stateOfListing(a, "{\n\t\"t1\": {\n\t\t\"instances\": {\n\t\t\t\"instance1\": {\n\t\t\t\t\"running\": true,\n\t\t\t\t\"pid\": 1786\n\t\t\t}\n\t\t}\n\t}\n}\n", "t1");
    try testing.expectEqual(output.ActiveState.active, running.state);
    try testing.expectEqual(@as(?u32, 1786), running.pid);
    const failed = try stateOfListing(a, "{\"t4\":{\"instances\":{\"instance1\":{\"running\":false,\"exit_code\":1}}}}", "t4");
    try testing.expectEqual(output.ActiveState.failed, failed.state);
    const finished = try stateOfListing(a, "{\"t\":{\"instances\":{\"instance1\":{\"running\":false,\"exit_code\":0}}}}", "t");
    try testing.expectEqual(output.ActiveState.inactive, finished.state);
    const killed = try stateOfListing(a, "{\"t\":{\"instances\":{\"instance1\":{\"running\":false,\"exit_code\":137}}}}", "t");
    try testing.expectEqual(output.ActiveState.failed, killed.state);
    try testing.expectEqual(output.ActiveState.inactive, (try stateOfListing(a, "{\n\t\n}\n", "t")).state);
    try testing.expectEqual(output.ActiveState.inactive, (try stateOfListing(a, "{\"t\":{}}", "t")).state);
    try testing.expectEqual(output.ActiveState.inactive, (try stateOfListing(a, "not json", "t")).state);
    try testing.expectEqual(output.ActiveState.inactive, (try stateOfListing(a, "", "t")).state);
}
