// SPDX-License-Identifier: GPL-3.0-or-later
//! Command line of the multi-call entry points `fake-systemd --exec` and `fake-systemd --log`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const executor = @import("executor.zig");

pub const Mode = enum { exec, log };

pub const Parsed = struct {
    mode: Mode,
    unit: []const u8,
    scope: core.Scope = .system,
    phase: executor.Phase = .start,
    /// `--exec` only: the process stays resident and SIGTERM runs `ExecStop=` before it ends the unit.
    stop_on_signal: bool = false,
    /// `--exec` only: stdout and stderr of the unit go to one `fake-systemd --log` child.
    log: bool = false,
    /// `--exec` only: the process stays resident and records how the main process ended.
    record_exit: bool = false,
    /// Filesystem root for units, accounts, directories and logs; defaults to `/`.
    root: ?[]const u8 = null,
    /// Logger only: size at which `current` is rotated, in bytes.
    max_size: ?u64 = null,
    /// Logger only: number of files kept.
    keep: ?u32 = null,
};

pub const Result = union(enum) {
    ok: Parsed,
    err: []const u8,
};

pub const usage =
    \\usage: fake-systemd --exec <unit> [--user] [--phase start|stop|reload|stop-post|stop-main] [--stop-on-signal] [--log] [--record-exit] [--root DIR]
    \\       fake-systemd --log <unit> [--user] [--root DIR] [--max-size BYTES] [--keep N]
    \\
;

/// Returns the mode flag when `args` (without the program name) start with one.
pub fn isServiceCommand(args: []const []const u8) bool {
    return args.len > 0 and (std.mem.eql(u8, args[0], "--exec") or std.mem.eql(u8, args[0], "--log"));
}

fn value(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

pub fn parse(gpa: Allocator, args: []const []const u8) Allocator.Error!Result {
    if (!isServiceCommand(args)) return .{ .err = "expected --exec or --log" };
    const mode: Mode = if (std.mem.eql(u8, args[0], "--exec")) .exec else .log;
    var parsed: Parsed = .{ .mode = mode, .unit = "" };
    var have_unit = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--user")) {
            parsed.scope = .user;
        } else if (std.mem.eql(u8, a, "--system")) {
            parsed.scope = .system;
        } else if (std.mem.eql(u8, a, "--root")) {
            parsed.root = value(args, &i) orelse return .{ .err = "--root needs a directory" };
        } else if (mode == .exec and std.mem.eql(u8, a, "--stop-on-signal")) {
            parsed.stop_on_signal = true;
        } else if (mode == .exec and std.mem.eql(u8, a, "--log")) {
            parsed.log = true;
        } else if (mode == .exec and std.mem.eql(u8, a, "--record-exit")) {
            parsed.record_exit = true;
        } else if (mode == .exec and std.mem.eql(u8, a, "--phase")) {
            const v = value(args, &i) orelse return .{ .err = "--phase needs a value" };
            parsed.phase = std.meta.stringToEnum(executor.Phase, v) orelse
                return .{ .err = try std.fmt.allocPrint(gpa, "unknown phase '{s}'", .{v}) };
        } else if (mode == .log and std.mem.eql(u8, a, "--max-size")) {
            const v = value(args, &i) orelse return .{ .err = "--max-size needs a value" };
            parsed.max_size = std.fmt.parseInt(u64, v, 10) catch return .{ .err = "invalid --max-size" };
        } else if (mode == .log and std.mem.eql(u8, a, "--keep")) {
            const v = value(args, &i) orelse return .{ .err = "--keep needs a value" };
            parsed.keep = std.fmt.parseInt(u32, v, 10) catch return .{ .err = "invalid --keep" };
        } else if (a.len > 0 and a[0] == '-') {
            return .{ .err = try std.fmt.allocPrint(gpa, "unknown option '{s}'", .{a}) };
        } else if (!have_unit) {
            parsed.unit = a;
            have_unit = true;
        } else return .{ .err = "only one unit name is accepted" };
    }
    if (!have_unit) return .{ .err = "missing unit name" };
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

test "exec arguments" {
    const p = try expectOk(&.{ "--exec", "foo.service", "--user", "--phase", "stop-post", "--root", "/r" });
    try std.testing.expectEqual(Mode.exec, p.mode);
    try std.testing.expectEqualStrings("foo.service", p.unit);
    try std.testing.expectEqual(core.Scope.user, p.scope);
    try std.testing.expectEqual(executor.Phase.@"stop-post", p.phase);
    try std.testing.expectEqualStrings("/r", p.root.?);
    const d = try expectOk(&.{ "--exec", "x" });
    try std.testing.expect(!d.stop_on_signal);
    try std.testing.expect((try expectOk(&.{ "--exec", "x", "--stop-on-signal" })).stop_on_signal);
    const flags = try expectOk(&.{ "--exec", "x", "--log", "--record-exit" });
    try std.testing.expect(flags.log and flags.record_exit and !d.log and !d.record_exit);
    try std.testing.expectEqual(executor.Phase.start, d.phase);
    try std.testing.expectEqual(core.Scope.system, d.scope);
}

test "log arguments" {
    const p = try expectOk(&.{ "--log", "--max-size", "100", "u", "--keep", "3" });
    try std.testing.expectEqual(Mode.log, p.mode);
    try std.testing.expectEqual(@as(u64, 100), p.max_size.?);
    try std.testing.expectEqual(@as(u32, 3), p.keep.?);
    try std.testing.expectEqualStrings("u", p.unit);
}

test "argument errors" {
    try expectErr(&.{"--exec"}, "missing unit name");
    try expectErr(&.{ "--exec", "a", "b" }, "only one unit name is accepted");
    try expectErr(&.{ "--exec", "a", "--phase", "bogus" }, "unknown phase 'bogus'");
    try expectErr(&.{ "--exec", "a", "--phase" }, "--phase needs a value");
    try expectErr(&.{ "--exec", "a", "--keep", "1" }, "unknown option '--keep'");
    try expectErr(&.{ "--log", "a", "--stop-on-signal" }, "unknown option '--stop-on-signal'");
    try expectErr(&.{ "--log", "a", "--record-exit" }, "unknown option '--record-exit'");
    try expectErr(&.{ "--log", "a", "--max-size", "x" }, "invalid --max-size");
    try expectErr(&.{"--other"}, "expected --exec or --log");
    try std.testing.expect(isServiceCommand(&.{ "--log", "x" }));
    try std.testing.expect(!isServiceCommand(&.{"status"}));
}
