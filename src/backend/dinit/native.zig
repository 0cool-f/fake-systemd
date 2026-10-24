//! Reading dinit files and `dinitctl` output: the command of a native service, and the state
//! of a service from `dinitctl status`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const interface = @import("../interface.zig");

/// Splits a dinit setting value: double quotes group, a backslash escapes the next character,
/// `$$` is a literal `$`, and a `#` preceded by whitespace starts a comment.
pub fn splitValue(gpa: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quoted = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '\\' and i + 1 < value.len) {
            i += 1;
            try cur.append(gpa, value[i]);
            in_word = true;
        } else if (c == '"') {
            quoted = !quoted;
            in_word = true;
        } else if (quoted) {
            try cur.append(gpa, c);
        } else if (c == ' ' or c == '\t') {
            if (in_word) try words.append(gpa, try cur.toOwnedSlice(gpa));
            in_word = false;
        } else if (c == '#' and !in_word) {
            break;
        } else if (c == '$' and i + 1 < value.len and value[i + 1] == '$') {
            i += 1;
            try cur.append(gpa, '$');
            in_word = true;
        } else {
            try cur.append(gpa, c);
            in_word = true;
        }
    }
    if (in_word) try words.append(gpa, try cur.toOwnedSlice(gpa));
    return words.toOwnedSlice(gpa);
}

/// Value of `key` in a service description line written as `key = value` or `key: value`.
pub fn settingValue(line: []const u8, key: []const u8) ?[]const u8 {
    const rest = std.mem.cutPrefix(u8, std.mem.trim(u8, line, " \t\r"), key) orelse return null;
    const op = std.mem.trimStart(u8, rest, " \t");
    if (op.len == 0 or (op[0] != '=' and op[0] != ':')) return null;
    const value = std.mem.trim(u8, op[1..], " \t");
    return if (value.len == 0) null else value;
}

/// `command` of a service description, `command +=` lines appended; null when it has none.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.cutPrefix(u8, line, "command") orelse continue;
        const op = std.mem.trimStart(u8, rest, " \t");
        var value: []const u8 = undefined;
        var append = false;
        if (std.mem.startsWith(u8, op, "+=")) {
            value = op[2..];
            append = true;
        } else if (op.len > 0 and (op[0] == '=' or op[0] == ':')) {
            value = op[1..];
        } else continue;
        if (!append) words.clearRetainingCapacity();
        try words.appendSlice(gpa, try splitValue(gpa, value));
        found = true;
    }
    if (!found or words.items.len == 0) return null;
    return try words.toOwnedSlice(gpa);
}

fn stateLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.cutPrefix(u8, line, "State:")) |rest| return std.mem.trim(u8, rest, " \t");
    }
    return null;
}

fn pidOf(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.cutPrefix(u8, line, "Process ID:")) |rest| {
            return std.fmt.parseInt(u32, std.mem.trim(u8, rest, " \t"), 10) catch null;
        }
    }
    return null;
}

/// A stopped service whose process ended on its own: clean statuses and the deliberate-stop
/// signals are not failures, anything else is.
fn stoppedState(reason: []const u8) output.ActiveState {
    if (std.mem.startsWith(u8, reason, "terminated; exited - status ")) {
        return if (std.mem.eql(u8, reason["terminated; exited - status ".len..], "0")) .inactive else .failed;
    }
    if (std.mem.startsWith(u8, reason, "terminated; signalled - signal ")) {
        const n = std.fmt.parseInt(u8, reason["terminated; signalled - signal ".len..], 10) catch return .failed;
        return switch (n) {
            1, 2, 13, 15 => .inactive,
            else => .failed,
        };
    }
    return .failed;
}

/// Normalizes the output of `dinitctl status`. Empty or unrecognized output counts as inactive.
pub fn parseStatus(text: []const u8) interface.Status {
    const state = stateLine(text) orelse return .{ .state = .inactive, .text = text };
    const pid = pidOf(text);
    const first_end = std.mem.findAny(u8, state, " (") orelse state.len;
    const word = state[0..first_end];
    const active: output.ActiveState = if (std.mem.eql(u8, word, "STARTED"))
        .active
    else if (std.mem.eql(u8, word, "STARTING"))
        .activating
    else if (std.mem.eql(u8, word, "STOPPING"))
        .deactivating
    else if (std.mem.eql(u8, word, "STOPPED")) blk: {
        const open = std.mem.findScalar(u8, state, '(') orelse break :blk .inactive;
        const close = std.mem.findScalarLast(u8, state, ')') orelse state.len;
        break :blk stoppedState(state[open + 1 .. close]);
    } else .inactive;
    return .{ .state = active, .pid = pid, .text = text };
}

/// Width of the state field that starts each line of `dinitctl list`, such as `[{+}     ]`.
const state_width = 10;

/// Service names of a `dinitctl list` listing, in order.
pub fn parseList(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len <= state_width or line[0] != '[' or line[state_width - 1] != ']') continue;
        const rest = std.mem.trimStart(u8, line[state_width..], " ");
        const end = std.mem.findAny(u8, rest, " \t\r") orelse rest.len;
        if (end > 0) try names.append(gpa, try gpa.dupe(u8, rest[0..end]));
    }
    return names.toOwnedSlice(gpa);
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "dinit values split like dinit does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/foo", "-a", "b c", "d#e", "$HOME", "q\"x", "\\" }, try splitValue(a, "/usr/bin/foo -a \"b c\" d#e $$HOME q\\\"x \\\\  # comment"));
    try expectWords(&.{ "x", "" }, try splitValue(a, "x \"\""));
}

test "setting values are read in both assignment forms" {
    try testing.expectEqualStrings("b", settingValue("depends-on = b", "depends-on").?);
    try testing.expectEqualStrings("b", settingValue("  depends-on: b ", "depends-on").?);
    try testing.expect(settingValue("depends-on-x = b", "depends-on") == null);
    try testing.expect(settingValue("waits-for = b", "depends-on") == null);
    try testing.expect(settingValue("depends-on =", "depends-on") == null);
}

test "command extraction handles assignments, appends and other keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/crond", "-n" }, try extractCommand(a, "type = process\ncommand         = /usr/bin/crond -n\nsmooth-recovery = true\n"));
    try expectWords(&.{ "/usr/bin/foo", "-x", "--more" }, try extractCommand(a, "command: /usr/bin/foo -x\ncommand += --more\n"));
    try expectWords(&.{"/b"}, try extractCommand(a, "command = /a\ncommand = /b\n"));
    try testing.expect(try extractCommand(a, "type = internal\nstop-command = /bin/true\ncommand-extra = x\n") == null);
    try testing.expect(try extractCommand(a, "command =\n") == null);
}

fn expectStatus(state: output.ActiveState, pid: ?u32, text: []const u8) !void {
    const s = parseStatus(text);
    try testing.expectEqual(state, s.state);
    try testing.expectEqual(pid, s.pid);
}

test "statuses observed from dinitctl 0.22 map to systemd states" {
    try expectStatus(.active, 16, "Service: sleeper\n    State: STARTED\n    Activation: explicitly started\n    Process ID: 16\n");
    try expectStatus(.active, null, "Service: oneshot\n    State: STARTED\n    Activation: explicitly started\n");
    try expectStatus(.activating, null, "Service: a1\n    State: STARTING\n    Activation: explicitly started\n");
    try expectStatus(.deactivating, 59, "Service: timeout\n    State: STOPPING\n    Process ID: 59\n");
    try expectStatus(.inactive, null, "Service: sleeper\n    State: STOPPED\n");
    try expectStatus(.failed, null, "Service: failer\n    State: STOPPED (terminated; exited - status 1)\n");
    try expectStatus(.inactive, null, "Service: a1\n    State: STOPPED (terminated; exited - status 0)\n");
    try expectStatus(.failed, null, "Service: crash\n    State: STOPPED (terminated; signalled - signal 11)\n");
    try expectStatus(.inactive, null, "Service: x\n    State: STOPPED (terminated; signalled - signal 15)\n");
    try expectStatus(.failed, null, "Service: f\n    State: STOPPED (failed to start; exited - status 1)\n");
    try expectStatus(.failed, null, "Service: n\n    State: STOPPED (could not be launched)\n        Stage: opening log file\n        Error: No such file or directory\n");
    try expectStatus(.failed, null, "Service: d\n    State: STOPPED (dependency failed/terminated)\n");
    try expectStatus(.inactive, null, "");
    try expectStatus(.inactive, null, "dinitctl: service not loaded.\n");
}

test "list output yields service names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "[[+]     ] boot\n[{+}     ] vendorsvc (pid: 23)\n[     {-}] a1 (exit status: 0)\n[     {X}] failer (exit status: 1)\n[   >>{ }] timeout (pid: 59)\n\n";
    const names = try parseList(a, text);
    try testing.expectEqual(@as(usize, 5), names.len);
    try testing.expectEqualStrings("boot", names[0]);
    try testing.expectEqualStrings("vendorsvc", names[1]);
    try testing.expectEqualStrings("failer", names[3]);
    try testing.expectEqualStrings("timeout", names[4]);
}
