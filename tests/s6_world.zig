// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the s6 and s6-rc tests: a tmp root with accounts, native services and
//! systemd units, the backends bound to the harness context, and a runner that answers by rule.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const S6 = h.backend.S6;
pub const S6Rc = h.backend.S6Rc;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_run = "#!/bin/sh\nexec 2>&1\nexec /usr/bin/native --serve\n";

/// Accounts, `setpriv`, and translatable systemd units `dbus.service` and `postgresql.service`.
fn populateCommon(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Plain s6: a native `syslog` service and the scan directory.
pub fn populatePlain(t: *h.Harness) !void {
    try populateCommon(t);
    try t.write("/etc/s6/sv/syslog/run", native_run, 0o755);
    try t.write("/service/.KEEP", "", 0o644);
}

/// s6-rc without a repository: a native `syslog` longrun and a compiled database.
pub fn populateRc(t: *h.Harness) !void {
    try populateCommon(t);
    try t.write("/etc/s6-rc/source/syslog/type", "longrun\n", 0o644);
    try t.write("/etc/s6-rc/source/syslog/run", native_run, 0o755);
    try t.write("/etc/s6-rc/source/default/type", "bundle\n", 0o644);
    try t.write("/etc/s6-rc/source/default/contents.d/syslog", "", 0o644);
    try t.write("/etc/s6-rc/compiled-1/db", "", 0o644);
    try t.fs.symLink("compiled-1", "/etc/s6-rc/compiled");
}

const artix_run =
    \\#!/bin/execlineb -P
    \\fdmove -c 2 1
    \\exec /usr/bin/sshd -D -e
    \\
;

/// s6-rc as Artix lays it out: packaged services in `/etc/s6/sv` as `name-srv` and `name-log`,
/// and the repository whose working set records the enabled ones.
pub fn populateArtix(t: *h.Harness) !void {
    try populateCommon(t);
    try t.write("/etc/s6/sv/syslog-srv/type", "longrun\n", 0o644);
    try t.write("/etc/s6/sv/syslog-srv/run", native_run, 0o755);
    try t.write("/etc/s6/sv/syslog-srv/producer-for", "syslog-log\n", 0o644);
    try t.write("/etc/s6/sv/syslog-log/type", "longrun\n", 0o644);
    try t.write("/etc/s6/sv/syslog-log/consumer-for", "syslog-srv\n", 0o644);
    try t.write("/etc/s6/sv/syslog-log/pipeline-name", "syslog\n", 0o644);
    try t.write("/etc/s6/sv/sshd-srv/type", "longrun\n", 0o644);
    try t.write("/etc/s6/sv/sshd-srv/run", artix_run, 0o755);
    try t.write("/etc/s6/sv/sshd-srv/producer-for", "sshd-log\n", 0o644);
    try t.write("/etc/s6/sv/mount-net/type", "oneshot\n", 0o644);
    try t.write("/etc/s6/sv/mount-net/up", "#!/bin/execlineb -P\nexec mount -a -O _netdev\n", 0o644);
    try t.write("/etc/s6/adminsv/.KEEP", "", 0o644);
    for ([_][]const u8{ "always", "active", "usable", "masked" }) |state| {
        const keep = try std.fmt.allocPrint(t.a(), "/etc/s6/repo/sources/current/{s}/.KEEP", .{state});
        try t.write(keep, "", 0o644);
    }
}

/// Binds an s6 backend to `t` with the generic profile.
pub fn usePlain(t: *h.Harness, b: *S6) void {
    b.* = .init(&t.ctx, h.detect.profile.generic.dirs(.s6));
}

/// Binds an s6-rc backend to `t`; `profile_id` is `generic` for the compile flow or `artix` for
/// the repository flow.
pub fn useRc(t: *h.Harness, b: *S6Rc, profile_id: []const u8) void {
    const p = h.detect.profile.byName(profile_id).?;
    b.* = .init(&t.ctx, p.dirs(.s6_rc));
}

/// One rule of the runner: an argument list that a call starts with, and the answer.
pub const Rule = struct {
    prefix: []const []const u8,
    code: u8 = 0,
    stdout: []const u8 = "",
};

/// Runner that records every call and answers with the first rule whose prefix the call starts
/// with; a call no rule matches succeeds and prints nothing.
pub const Script = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList([]const []const u8) = .empty,
    rules: []const Rule = &.{},
    /// Where `s6-rc-compile` creates the database directory it is given.
    fs: ?*h.core.Fs = null,

    pub fn runner(s: *Script) h.backend.Runner {
        return .{ .ptr = s, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const s: *Script = @ptrCast(@alignCast(ptr));
        const copy = try s.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try s.gpa.dupe(u8, w);
        try s.calls.append(s.gpa, copy);
        if (s.fs) |fs| if (argv.len > 1 and std.mem.eql(u8, argv[0], "s6-rc-compile")) try fs.makePath(argv[1]);
        for (s.rules) |r| {
            if (r.prefix.len > argv.len) continue;
            const same = for (r.prefix, argv[0..r.prefix.len]) |a, b| {
                if (!std.mem.eql(u8, a, b)) break false;
            } else true;
            if (same) return .{ .code = r.code, .stdout = r.stdout };
        }
        return .{ .code = 0 };
    }

    pub fn callIs(s: Script, index: usize, expected: []const []const u8) bool {
        if (index >= s.calls.items.len) return false;
        const call = s.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// True when some call starts with `prefix`.
    pub fn called(s: Script, prefix: []const []const u8) bool {
        return s.count(prefix) > 0;
    }

    pub fn count(s: Script, prefix: []const []const u8) usize {
        var n: usize = 0;
        for (s.calls.items) |call| {
            if (call.len < prefix.len) continue;
            const same = for (prefix, call[0..prefix.len]) |a, b| {
                if (!std.mem.eql(u8, a, b)) break false;
            } else true;
            if (same) n += 1;
        }
        return n;
    }

    /// The calls as one line each, for failure messages.
    pub fn dump(s: Script, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.calls.items) |call| {
            for (call, 0..) |w, i| {
                if (i > 0) try out.append(gpa, ' ');
                try out.appendSlice(gpa, w);
            }
            try out.append(gpa, '\n');
        }
        return out.items;
    }
};
