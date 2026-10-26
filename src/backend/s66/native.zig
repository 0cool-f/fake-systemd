// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading 66 files and tool output: the command of a frontend file, the services it depends on,
//! the settings recorded in a generated one, and the state of a service from `66 runstate`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const interface = @import("../interface.zig");
const runit_native = @import("../runit/native.zig");
const s6_native = @import("../s6/native.zig");
const render = @import("render.zig");

// ---- frontend files ----------------------------------------------------------------------------

fn lineKey(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.findScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trimStart(u8, line[eq + 1 ..], " \t") };
}

/// Text of the value of `key` in `section`: what follows the `=`, and for a value in
/// parentheses everything up to the matching `)`, which may span lines. Null when absent.
fn sectionValue(gpa: Allocator, content: []const u8, section: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var inside = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            inside = std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], section);
            continue;
        }
        if (!inside) continue;
        const kv = lineKey(line) orelse continue;
        if (!std.mem.eql(u8, kv.key, key)) continue;
        if (kv.value.len == 0 or kv.value[0] != '(') return try gpa.dupe(u8, kv.value);
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 0;
        var rest: []const u8 = kv.value;
        while (true) {
            for (rest) |c| {
                if (c == '(') {
                    depth += 1;
                    if (depth == 1) continue;
                } else if (c == ')') {
                    depth -= 1;
                    if (depth == 0) return try out.toOwnedSlice(gpa);
                }
                try out.append(gpa, c);
            }
            try out.append(gpa, '\n');
            rest = lines.next() orelse return try out.toOwnedSlice(gpa);
        }
    }
    return null;
}

/// The last statement of an execline script: lines are chained programs, so the program that
/// runs is on the last line that is not inside a block.
fn lastStatement(script: []const u8) []const u8 {
    var depth: usize = 0;
    var quoted = false;
    var start: usize = 0;
    var last: []const u8 = "";
    for (script, 0..) |c, i| {
        switch (c) {
            '"' => quoted = !quoted,
            '{' => if (!quoted) {
                depth += 1;
            },
            '}' => if (!quoted and depth > 0) {
                depth -= 1;
            },
            '\n' => if (!quoted and depth == 0) {
                const line = std.mem.trim(u8, script[start..i], " \t\r");
                if (line.len > 0 and line[0] != '#') last = line;
                start = i + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, script[start..], " \t\r\n");
    return if (tail.len > 0 and tail[0] != '#') tail else last;
}

/// Words of the program an `Execute` script runs: the last `exec` line of a shell script; for
/// execline the end of the chain of the last statement, where `execl-cmdline -s { program ... }`
/// runs the program in the block.
fn executeWords(gpa: Allocator, script: []const u8) Allocator.Error!?[]const []const u8 {
    const trimmed = std.mem.trimStart(u8, script, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "#!") and std.mem.find(u8, trimmed[0 .. std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len], "execlineb") == null) {
        return runit_native.extractCommand(gpa, trimmed);
    }
    const statement = lastStatement(trimmed);
    const words = (try s6_native.extractExecline(gpa, statement)) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(words[0]), "execl-cmdline")) return words;
    const open = std.mem.findScalar(u8, statement, '{') orelse return words;
    const close = std.mem.findScalarLast(u8, statement, '}') orelse return words;
    if (close <= open) return words;
    return (try s6_native.extractExecline(gpa, statement[open + 1 .. close])) orelse words;
}

/// Command words of the service a frontend file defines, or null when it has none.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    const script = (try sectionValue(gpa, content, "Start", "Execute")) orelse return null;
    return executeWords(gpa, script);
}

/// Services named in the `Depends` key of `[Main]`.
pub fn dependsOf(gpa: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    const value = (try sectionValue(gpa, content, "Main", "Depends")) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (it.next()) |word| {
        if (word[0] == '#') continue;
        try out.append(gpa, word);
    }
    return out.toOwnedSlice(gpa);
}

// ---- settings recorded in generated files ----------------------------------------------------------

pub fn parseFlags(text: []const u8) render.Flags {
    var out: render.Flags = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tail = std.mem.cutPrefix(u8, line, render.flags_prefix) orelse continue;
        var it = std.mem.tokenizeScalar(u8, tail, ' ');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "remain")) out.remain = true;
            if (std.mem.eql(u8, tok, "restarts")) out.restarts = true;
            if (std.mem.cutPrefix(u8, tok, "ok-codes=")) |v| out.ok_codes = v;
            if (std.mem.cutPrefix(u8, tok, "ok-signals=")) |v| out.ok_signals = v;
        }
        break;
    }
    return out;
}

// ---- 66 runstate -----------------------------------------------------------------------------------

pub const State = enum { down, starting, up, stopping, finishing, restarting, done, failed, waiting };
pub const Result = enum { success, exited, signaled, @"timeout-start", @"timeout-stop", @"crash-limit", @"exec-failed" };
pub const Who = enum { self, user, event, boot, shutdown };

/// The runtime record of a service as `66 runstate -nf state,result,who,pid,code` prints it.
pub const Runstate = struct {
    state: State,
    result: Result,
    who: Who,
    pid: u32,
    code: u32,
};

pub const runstate_fields = "state,result,who,pid,code";

pub fn parseRunstate(text: []const u8) ?Runstate {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    const state = std.meta.stringToEnum(State, it.next() orelse return null) orelse return null;
    const result = std.meta.stringToEnum(Result, it.next() orelse return null) orelse return null;
    const who = std.meta.stringToEnum(Who, it.next() orelse return null) orelse return null;
    const pid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const code = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ .state = state, .result = result, .who = who, .pid = pid, .code = code };
}

fn listHas(list: []const u8, value: u32) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |item| {
        if ((std.fmt.parseInt(u32, item, 10) catch continue) == value) return true;
    }
    return false;
}

/// True when the end the record describes is a success for systemd: exit status 0, a signal that
/// ends a service cleanly, or an exit status or signal that `SuccessExitStatus=` lists.
fn endedCleanly(r: Runstate, flags: render.Flags) bool {
    return switch (r.result) {
        .success => true,
        .exited => r.code == 0 or listHas(flags.ok_codes, r.code),
        .signaled => switch (r.code) {
            1, 2, 13, 15 => true,
            else => listHas(flags.ok_signals, r.code),
        },
        .@"timeout-start", .@"timeout-stop", .@"crash-limit", .@"exec-failed" => false,
    };
}

/// Normalizes a runtime record. A process that ended by itself without a clean exit, and that
/// 66 does not start again, is a failure; one the user, the boot or the shutdown brought down is
/// not.
pub fn normalize(r: Runstate, flags: render.Flags) interface.Status {
    const pid: ?u32 = if (r.pid != 0) r.pid else null;
    const state: output.ActiveState = switch (r.state) {
        .up => .active,
        .starting, .restarting => .activating,
        .stopping, .finishing => .deactivating,
        .done => if (flags.remain) .active else .inactive,
        .failed => .failed,
        .waiting => .inactive,
        .down => blk: {
            if (r.result == .@"timeout-start" or r.result == .@"timeout-stop") break :blk .failed;
            if (r.who != .self or endedCleanly(r, flags)) break :blk .inactive;
            break :blk if (flags.restarts) .activating else .failed;
        },
    };
    return .{ .state = state, .pid = pid };
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command of the frontend files of the 66-service repository" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/dhcpcd", "${ArgsStart}" }, try extractCommand(a,
        \\[Main]
        \\Type = classic
        \\Description = "dhcpcd daemon"
        \\
        \\[Start]
        \\Execute = ( /usr/bin/execl-cmdline -s { /usr/bin/dhcpcd ${ArgsStart} } )
        \\
        \\[Stop]
        \\Execute = ( /usr/bin/execl-cmdline -s { /usr/bin/dhcpcd ${ArgsStop} } )
        \\
    ));
    try expectWords(&.{ "dbus-daemon", "${Args}" }, try extractCommand(a,
        \\[Main]
        \\Type = classic
        \\
        \\[Start]
        \\MaxDeath = 3
        \\Execute = (
        \\    execl-toc -S ${Socket} -m 0755
        \\    if {
        \\        execl-toc -d /var/lib/dbus
        \\        dbus-uuidgen --ensure
        \\    }
        \\    dbus-daemon ${Args}
        \\)
        \\
        \\[Stop]
        \\Execute = ( s6-rmrf ${Socket} )
        \\
    ));
}

test "a shell Execute gives the last exec line, whatever parentheses it holds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectWords(&.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--log" }, try extractCommand(arena.allocator(),
        \\# Generated automatically by fake-systemd. Remove this block to take ownership of the file.
        \\[Main]
        \\Type = classic
        \\
        \\[Start]
        \\Execute = (#!/bin/sh
        \\x=$(id -g root)
        \\exec /usr/bin/fake-systemd --exec foo.service --log
        \\)
        \\
    ));
}

test "frontend files without a command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try extractCommand(a, "[Main]\nType = module\n") == null);
    try testing.expect(try extractCommand(a, "[Main]\nType = event\nEventType = timer\nEvery = 5s\n") == null);
    try testing.expect(try extractCommand(a, "") == null);
}

test "dependencies come from the Depends key, comments aside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deps = try dependsOf(a, "[Main]\nType = classic\nDepends = ( fooA #fooB fooC )\n\n[Start]\nExecute = ( true )\n");
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("fooA", deps[0]);
    try testing.expectEqualStrings("fooC", deps[1]);
    const lines = try dependsOf(a, "[Main]\nDepends=(\nbar\nbaz\n)\n");
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(@as(usize, 0), (try dependsOf(a, "[Main]\nType = oneshot\n")).len);
}

test "generated flags are read back" {
    const f = parseFlags("# fake-systemd flags: remain restarts ok-codes=3,4 ok-signals=10\n[Main]\n");
    try testing.expect(f.remain and f.restarts);
    try testing.expectEqualStrings("3,4", f.ok_codes);
    try testing.expectEqualStrings("10", f.ok_signals);
    const none = parseFlags("[Main]\nType = classic\n");
    try testing.expect(!none.remain and !none.restarts and none.ok_codes.len == 0);
}

fn expectRunstate(state: output.ActiveState, pid: ?u32, flags: render.Flags, text: []const u8) !void {
    const s = normalize(parseRunstate(text) orelse return error.TestUnparsed, flags);
    try testing.expectEqual(state, s.state);
    try testing.expectEqual(pid, s.pid);
}

test "records observed from 66 0.9.1.2 map to systemd states" {
    const none: render.Flags = .{};
    try expectRunstate(.active, 21, none, "up\nsuccess\nuser\n21\n0\n");
    try expectRunstate(.inactive, null, none, "down\nsuccess\nself\n0\n0\n");
    try expectRunstate(.inactive, null, none, "down\nsuccess\nuser\n0\n0\n");
    try expectRunstate(.failed, null, none, "down\nexited\nself\n0\n3\n");
    try expectRunstate(.failed, null, none, "down\nsignaled\nself\n0\n9\n");
    try expectRunstate(.inactive, null, none, "down\nsignaled\nself\n0\n15\n");
    try expectRunstate(.inactive, null, none, "down\nexited\nuser\n0\n3\n");
    try expectRunstate(.failed, null, none, "down\ntimeout-start\nuser\n0\n0\n");
    try expectRunstate(.failed, null, none, "failed\nexited\nuser\n0\n7\n");
    try expectRunstate(.failed, null, none, "failed\ncrash-limit\nself\n0\n0\n");
    try expectRunstate(.activating, null, none, "restarting\nexited\nself\n0\n1\n");
    try expectRunstate(.activating, null, none, "starting\nsuccess\nuser\n0\n0\n");
    try expectRunstate(.deactivating, 12, none, "stopping\nsuccess\nuser\n12\n0\n");
    try expectRunstate(.deactivating, 12, none, "finishing\nexited\nself\n12\n3\n");
    try expectRunstate(.inactive, null, none, "done\nsuccess\nuser\n0\n0\n");
    try expectRunstate(.active, null, .{ .remain = true }, "done\nsuccess\nuser\n0\n0\n");
    try expectRunstate(.inactive, null, none, "waiting\nsuccess\nself\n0\n0\n");
}

test "SuccessExitStatus= makes an exit status or a signal a success" {
    const flags: render.Flags = .{ .ok_codes = "3,4", .ok_signals = "10" };
    try expectRunstate(.inactive, null, flags, "down\nexited\nself\n0\n4\n");
    try expectRunstate(.failed, null, flags, "down\nexited\nself\n0\n5\n");
    try expectRunstate(.inactive, null, flags, "down\nsignaled\nself\n0\n10\n");
    try expectRunstate(.failed, null, flags, "down\nsignaled\nself\n0\n11\n");
}

test "a service that restarts after every exit is activating, not failed" {
    try expectRunstate(.activating, null, .{ .restarts = true }, "down\nexited\nself\n0\n1\n");
    try expectRunstate(.inactive, null, .{ .restarts = true }, "down\nexited\nuser\n0\n1\n");
}

test "unparsable records are rejected" {
    try testing.expect(parseRunstate("") == null);
    try testing.expect(parseRunstate("runstate: fatal: service: x is not parsed\n") == null);
    try testing.expect(parseRunstate("up\nsuccess\nuser\n21\n") == null);
    try testing.expect(parseRunstate("sideways\nsuccess\nuser\n21\n0\n") == null);
}
