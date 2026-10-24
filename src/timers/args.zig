// SPDX-License-Identifier: GPL-3.0-or-later
//! Command line of the multi-call entry points `fake-systemd --run-job` and `fake-systemd --timers`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");

pub const Mode = enum { run_job, timers };

pub const Parsed = struct {
    mode: Mode,
    /// `--run-job` only: the unit to run.
    service: []const u8 = "",
    /// `--run-job` only: the timer that fired.
    timer: []const u8 = "",
    random_delay_us: u64 = 0,
    scope: core.Scope = .system,
    /// Filesystem root for units, index and logs; defaults to `/`.
    root: ?[]const u8 = null,
};

pub const Result = union(enum) {
    ok: Parsed,
    err: []const u8,
};

pub const usage =
    \\usage: fake-systemd --run-job <service> --timer <timer> [--random-delay USEC] [--user] [--root DIR]
    \\       fake-systemd --timers [--user] [--root DIR]
    \\
;

/// True when `args` (without the program name) start with a timer mode flag.
pub fn isTimerCommand(args: []const []const u8) bool {
    return args.len > 0 and (std.mem.eql(u8, args[0], "--run-job") or std.mem.eql(u8, args[0], "--timers"));
}

fn value(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

pub fn parse(gpa: Allocator, args: []const []const u8) Allocator.Error!Result {
    if (!isTimerCommand(args)) return .{ .err = "expected --run-job or --timers" };
    const mode: Mode = if (std.mem.eql(u8, args[0], "--run-job")) .run_job else .timers;
    var parsed: Parsed = .{ .mode = mode };
    var i: usize = 1;
    if (mode == .run_job) {
        if (args.len < 2 or std.mem.startsWith(u8, args[1], "-")) return .{ .err = "--run-job needs a service name" };
        parsed.service = args[1];
        i = 2;
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--user")) {
            parsed.scope = .user;
        } else if (std.mem.eql(u8, a, "--system")) {
            parsed.scope = .system;
        } else if (std.mem.eql(u8, a, "--root")) {
            parsed.root = value(args, &i) orelse return .{ .err = "--root needs a directory" };
        } else if (mode == .run_job and std.mem.eql(u8, a, "--timer")) {
            parsed.timer = value(args, &i) orelse return .{ .err = "--timer needs a timer name" };
        } else if (mode == .run_job and std.mem.eql(u8, a, "--random-delay")) {
            const v = value(args, &i) orelse return .{ .err = "--random-delay needs a value" };
            parsed.random_delay_us = std.fmt.parseInt(u64, v, 10) catch return .{ .err = "invalid --random-delay" };
        } else {
            return .{ .err = try std.fmt.allocPrint(gpa, "unknown option '{s}'", .{a}) };
        }
    }
    if (mode == .run_job and parsed.timer.len == 0) return .{ .err = "--run-job needs --timer" };
    return .{ .ok = parsed };
}

fn expectOk(args: []const []const u8) !Parsed {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    return switch (try parse(arena.allocator(), args)) {
        .ok => |p| p,
        .err => |m| {
            std.debug.print("unexpected error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectErr(args: []const []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    switch (try parse(arena.allocator(), args)) {
        .ok => return error.TestUnexpectedResult,
        .err => |m| try std.testing.expectEqualStrings(expected, m),
    }
}

test "run-job arguments" {
    const p = try expectOk(&.{ "--run-job", "foo.service", "--timer", "foo.timer", "--random-delay", "5000000", "--user", "--root", "/r" });
    try std.testing.expectEqual(Mode.run_job, p.mode);
    try std.testing.expectEqualStrings("foo.service", p.service);
    try std.testing.expectEqualStrings("foo.timer", p.timer);
    try std.testing.expectEqual(@as(u64, 5_000_000), p.random_delay_us);
    try std.testing.expectEqual(core.Scope.user, p.scope);
    try std.testing.expectEqualStrings("/r", p.root.?);
}

test "timers arguments" {
    const p = try expectOk(&.{ "--timers", "--user" });
    try std.testing.expectEqual(Mode.timers, p.mode);
    try std.testing.expectEqual(core.Scope.user, p.scope);
    const d = try expectOk(&.{"--timers"});
    try std.testing.expectEqual(core.Scope.system, d.scope);
}

test "argument errors" {
    try expectErr(&.{"--run-job"}, "--run-job needs a service name");
    try expectErr(&.{ "--run-job", "a.service" }, "--run-job needs --timer");
    try expectErr(&.{ "--run-job", "a.service", "--timer" }, "--timer needs a timer name");
    try expectErr(&.{ "--run-job", "a.service", "--timer", "t", "--random-delay", "x" }, "invalid --random-delay");
    try expectErr(&.{ "--timers", "--timer", "x" }, "unknown option '--timer'");
    try expectErr(&.{"--other"}, "expected --run-job or --timers");
    try std.testing.expect(isTimerCommand(&.{"--timers"}));
    try std.testing.expect(!isTimerCommand(&.{"--exec"}));
}
