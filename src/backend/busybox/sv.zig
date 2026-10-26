// SPDX-License-Identifier: GPL-3.0-or-later
//! The `sv` applet of BusyBox as the runit backend reads it. It controls a service the same way
//! and prints the same status lines; what differs is the wording of the messages that tell a
//! service is not supervised yet, and that it looks in `/var/service` unless `SVDIR` says
//! otherwise.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rn = @import("../runner.zig");
const Runner = rn.Runner;

/// Directory the `sv` applet searches for a service name when `SVDIR` is not set.
pub const default_scan_dir = "/var/service";

const Rewrite = struct { from: []const u8, to: []const u8 };

/// Messages of BusyBox, and the words runit uses for them.
const rewrites = [_]Rewrite{
    .{ .from = "can't open supervise/", .to = "unable to open supervise/" },
    .{ .from = "can't change to service directory: No such file or directory", .to = "unable to change to service directory: file does not exist" },
};

/// Output of `sv` with the messages of BusyBox in the words of runit.
pub fn normalize(gpa: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: []const u8 = text;
    for (rewrites) |r| {
        if (std.mem.find(u8, out, r.from) == null) continue;
        const size = std.mem.replacementSize(u8, out, r.from, r.to);
        const buf = try gpa.alloc(u8, size);
        _ = std.mem.replace(u8, out, r.from, r.to, buf);
        out = buf;
    }
    return out;
}

/// Runs everything through `inner`, except that a call of `sv` gets `SVDIR` when the services
/// are not in the directory `sv` searches, and its output is normalized.
pub const Adapter = struct {
    inner: Runner,
    scan_dir: []const u8 = default_scan_dir,

    pub fn runner(a: *Adapter) Runner {
        return .{ .ptr = a, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, gpa: Allocator, argv: []const []const u8, stdio: rn.Stdio) anyerror!rn.Result {
        const a: *Adapter = @ptrCast(@alignCast(ptr));
        if (argv.len == 0 or !std.mem.eql(u8, argv[0], "sv")) return a.inner.run(gpa, argv, stdio);
        var words: std.ArrayList([]const u8) = .empty;
        if (!std.mem.eql(u8, a.scan_dir, default_scan_dir)) {
            try words.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "SVDIR={s}", .{a.scan_dir}) });
        }
        try words.appendSlice(gpa, argv);
        const res = try a.inner.run(gpa, words.items, stdio);
        return .{ .code = res.code, .stdout = try normalize(gpa, res.stdout) };
    }
};

const testing = std.testing;

test "the messages of BusyBox read as those of runit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("warning: sleeper: unable to open supervise/ok: No such file or directory\n", try normalize(a, "warning: sleeper: can't open supervise/ok: No such file or directory\n"));
    try testing.expectEqualStrings("fail: x: unable to change to service directory: file does not exist\n", try normalize(a, "fail: x: can't change to service directory: No such file or directory\n"));
    try testing.expectEqualStrings("run: sleeper: (pid 18) 2s\n", try normalize(a, "run: sleeper: (pid 18) 2s\n"));
    try testing.expectEqualStrings("", try normalize(a, ""));
}

test "sv gets SVDIR when the services are elsewhere and everything else passes through" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rec: rn.Recording = .{ .gpa = a, .stdout = "warning: x: can't open supervise/ok: No such file or directory\n" };
    var ad: Adapter = .{ .inner = rec.runner(), .scan_dir = "/etc/service" };
    const res = try ad.runner().run(a, &.{ "sv", "status", "x" }, .capture);
    try testing.expect(rec.callIs(0, &.{ "env", "SVDIR=/etc/service", "sv", "status", "x" }));
    try testing.expectEqualStrings("warning: x: unable to open supervise/ok: No such file or directory\n", res.stdout);
    _ = try ad.runner().run(a, &.{ "kill", "-s", "HUP", "1" }, .inherit);
    try testing.expect(rec.callIs(1, &.{ "kill", "-s", "HUP", "1" }));

    var plain: rn.Recording = .{ .gpa = a };
    var same: Adapter = .{ .inner = plain.runner() };
    _ = try same.runner().run(a, &.{ "sv", "status", "x" }, .capture);
    try testing.expect(plain.callIs(0, &.{ "sv", "status", "x" }));
}
