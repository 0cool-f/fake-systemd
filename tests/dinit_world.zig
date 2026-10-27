// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the dinit tests: a tmp root with accounts, dinit services and systemd
//! units, plus the dinit backend bound to the harness context.
const std = @import("std");
const h = @import("harness.zig");

pub const dinit = h.backend.Dinit;

pub const passwd =
    \\root:x:0:0:root:/root:/bin/sh
    \\daemon:x:1:1:daemon:/:/usr/bin/nologin
    \\app:x:1000:1000:app:/var/lib/app:/usr/bin/nologin
    \\nobody:x:65534:65534:nobody:/:/usr/bin/nologin
    \\
;

pub const group =
    \\root:x:0:
    \\daemon:x:1:
    \\audio:x:92:app
    \\video:x:93:app
    \\app:x:1000:
    \\nogroup:x:65534:
    \\
;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_service = "type = process\ncommand = /usr/bin/native\n";

/// Accounts, a network service and a native `syslog` service, plus translatable systemd
/// units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/lib/dinit.d/network", native_service, 0o644);
    try t.write("/usr/lib/dinit.d/syslog", native_service, 0o644);
    try t.write("/etc/dinit.d/boot.d/.KEEP", "", 0o644);
    try t.write("/usr/lib/dinit.d/boot", "type = internal\nwaits-for.d = /etc/dinit.d/boot.d\n", 0o644);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a dinit backend to `t` (which keeps it alive) and routes the ops through it.
pub fn use(t: *h.Harness, d: *dinit) void {
    d.* = .init(&t.ctx, h.detect.profile.generic.dirs(.dinit));
}

/// Runner that records calls and fails every call whose argv holds one of `fail_words`.
pub const Scripted = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList([]const []const u8) = .empty,
    fail_words: []const []const u8 = &.{},
    stdout: []const u8 = "",

    pub fn runner(s: *Scripted) h.backend.Runner {
        return .{ .ptr = s, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const s: *Scripted = @ptrCast(@alignCast(ptr));
        const copy = try s.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try s.gpa.dupe(u8, w);
        try s.calls.append(s.gpa, copy);
        for (argv) |w| for (s.fail_words) |f| if (std.mem.eql(u8, w, f)) return .{ .code = 1 };
        return .{ .code = 0, .stdout = s.stdout };
    }

    pub fn callIs(s: Scripted, index: usize, expected: []const []const u8) bool {
        if (index >= s.calls.items.len) return false;
        const call = s.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }
};

/// Makes `pid` a live process of the tmp root: the pid checks of the backends read
/// `/proc/<pid>/status` and its start time, which is `pid`, from `/proc/<pid>/stat`. It is owned by the user running the tests, as the pid files the tests write.
pub fn liveProcess(t: *h.Harness, pid: u32) !void {
    const path = try std.fmt.allocPrint(t.a(), "/proc/{d}/status", .{pid});
    const uid = std.os.linux.getuid();
    try t.write(path, try std.fmt.allocPrint(t.a(), "Name:\tx\nUid:\t{d}\t{d}\t{d}\t{d}\n", .{ uid, uid, uid, uid }), 0o644);
    const stat_path = try std.fmt.allocPrint(t.a(), "/proc/{d}/stat", .{pid});
    try t.write(stat_path, try std.fmt.allocPrint(t.a(), "{d} (x) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 {d} 0 0\n", .{ pid, pid }), 0o644);
}
