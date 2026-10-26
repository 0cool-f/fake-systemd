// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the 66 tests: a tmp root with accounts, native frontend files and systemd
//! units, the 66 backend bound to the harness context, and a runner that behaves like `66`: it
//! keeps the state `enable`, `disable`, `parse` and `remove` change in the resolve files the
//! backend reads, and answers `runstate` with a record the test chooses.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const S66 = h.backend.S66;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

/// Resolve files written by 66 0.9.1.2 for a parsed service that is enabled and one that is not.
pub const enabled_resolve = @embedFile("golden/66/enabled.resolve");
pub const disabled_resolve = @embedFile("golden/66/disabled.resolve");

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";

pub const native_frontend =
    \\[Main]
    \\Type = classic
    \\Description = "syslog daemon"
    \\
    \\[Start]
    \\Execute = ( /usr/bin/execl-cmdline -s { /usr/bin/native ${Args} } )
    \\
    \\[Environment]
    \\Args=!--serve
    \\
;

/// `runstate -nf state,result,who,pid,code` records.
pub const up = "up\nsuccess\nuser\n4242\n0\n";
pub const down = "down\nsuccess\nuser\n0\n0\n";
pub const never_started = "down\nsuccess\nself\n0\n0\n";

/// Accounts, `setpriv`, a native `syslog` frontend and translatable systemd units `dbus.service`
/// and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/66", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/usr/share/66/service/syslog", native_frontend, 0o644);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a 66 backend to `t` as on a host root, where `66` can run.
pub fn use(t: *h.Harness, b: *S66) void {
    b.* = .init(&t.ctx, h.detect.profile.generic.dirs(.s66));
    b.run_here = true;
}

pub fn resolvePath(a: std.mem.Allocator, service: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/var/lib/66/system/service/svc/{s}/.resolve/{s}", .{ service, service });
}

/// Records what 66 has parsed, as `66 parse` leaves it, without starting anything.
pub fn markParsed(t: *h.Harness, service: []const u8, enabled: bool) !void {
    const a = t.a();
    try t.write(try resolvePath(a, service), if (enabled) enabled_resolve else disabled_resolve, 0o600);
    const link = try std.fmt.allocPrint(a, "/var/lib/66/system/.resolve/service/{s}", .{service});
    try t.fs.makePath("/var/lib/66/system/.resolve/service");
    t.fs.deleteFile(link) catch {};
    try t.fs.symLink(try std.fmt.allocPrint(a, "/var/lib/66/system/service/svc/{s}", .{service}), link);
}

/// Rule of the runner: a failure for the calls that start with `prefix`.
pub const Rule = struct {
    prefix: []const []const u8,
    code: u8 = 0,
    stdout: []const u8 = "",
};

pub const Fake66 = struct {
    t: *h.Harness,
    calls: std.ArrayList([]const []const u8) = .empty,
    /// What `66 runstate` prints.
    runstate: []const u8 = never_started,
    rules: []const Rule = &.{},

    pub fn runner(f: *Fake66) h.backend.Runner {
        return .{ .ptr = f, .run_fn = runFn };
    }

    fn has(argv: []const []const u8, verb: []const u8) bool {
        for (argv[1..]) |w| if (std.mem.eql(u8, w, verb)) return true;
        return false;
    }

    fn serviceOf(argv: []const []const u8) []const u8 {
        return argv[argv.len - 1];
    }

    fn parsed(f: *Fake66, service: []const u8) bool {
        const link = std.fmt.allocPrint(f.t.a(), "/var/lib/66/system/.resolve/service/{s}", .{service}) catch return false;
        _ = f.t.fs.lstat(link) catch return false;
        return true;
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const f: *Fake66 = @ptrCast(@alignCast(ptr));
        const a = f.t.a();
        const copy = try a.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try a.dupe(u8, w);
        try f.calls.append(a, copy);
        for (f.rules) |r| {
            if (r.prefix.len > argv.len) continue;
            const same = for (r.prefix, argv[0..r.prefix.len]) |p, w| {
                if (!std.mem.eql(u8, p, w)) break false;
            } else true;
            if (same) return .{ .code = r.code, .stdout = r.stdout };
        }
        if (!std.mem.eql(u8, argv[0], "66") or argv.len < 2) return .{ .code = 0 };
        if (has(argv, "runstate")) return .{ .code = 0, .stdout = f.runstate };
        if (has(argv, "resolve")) return .{ .code = 0, .stdout = try std.fmt.allocPrint(a, "/run/66/state/0/{s}\n", .{serviceOf(argv)}) };
        if (has(argv, "enable")) try markParsed(f.t, serviceOf(argv), true);
        if (has(argv, "start") and !f.parsed(serviceOf(argv))) try markParsed(f.t, serviceOf(argv), false);
        if (has(argv, "parse")) try markParsed(f.t, serviceOf(argv), false);
        if (has(argv, "disable")) try markParsed(f.t, serviceOf(argv), false);
        if (has(argv, "remove")) {
            const service = serviceOf(argv);
            f.t.fs.deleteFile(try std.fmt.allocPrint(a, "/var/lib/66/system/.resolve/service/{s}", .{service})) catch {};
            f.t.fs.deleteTree(try std.fmt.allocPrint(a, "/var/lib/66/system/service/svc/{s}", .{service})) catch {};
        }
        return .{ .code = 0 };
    }

    pub fn callIs(f: Fake66, index: usize, expected: []const []const u8) bool {
        if (index >= f.calls.items.len) return false;
        const call = f.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// Number of calls that start with `prefix`.
    pub fn count(f: Fake66, prefix: []const []const u8) usize {
        var n: usize = 0;
        for (f.calls.items) |call| {
            if (call.len < prefix.len) continue;
            const same = for (prefix, call[0..prefix.len]) |p, w| {
                if (!std.mem.eql(u8, p, w)) break false;
            } else true;
            if (same) n += 1;
        }
        return n;
    }

    pub fn called(f: Fake66, prefix: []const []const u8) bool {
        return f.count(prefix) > 0;
    }

    /// The calls as one line each, for failure messages.
    pub fn dump(f: Fake66, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (f.calls.items) |call| {
            for (call, 0..) |w, i| {
                if (i > 0) try out.append(gpa, ' ');
                try out.appendSlice(gpa, w);
            }
            try out.append(gpa, '\n');
        }
        return out.items;
    }
};
