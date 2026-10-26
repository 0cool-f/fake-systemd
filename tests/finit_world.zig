// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the finit tests: a tmp root with accounts, a native service and systemd
//! units, the finit backend bound to the harness context, and a runner that answers like
//! `initctl`.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const finit = h.backend.Finit;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_conf = "service [2345] <net/lo/up> env:-/etc/default/syslog /usr/sbin/syslogd -n -- Native syslog\n";
const static_conf = "service [2345] /usr/sbin/crond -n -- Static cron\n";

/// Accounts, `setpriv`, a native `syslog` service in `available/`, a static `crond` in `/etc/finit.d`, and
/// translatable systemd units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/etc/finit.d/available/syslog.conf", native_conf, 0o644);
    try t.write("/etc/finit.d/crond.conf", static_conf, 0o644);
    try t.write("/etc/finit.d/enabled/.KEEP", "", 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a finit backend to `t` with the generic profile.
pub fn use(t: *h.Harness, f: *finit) void {
    f.* = .init(&t.ctx, h.detect.profile.generic.dirs(.finit));
}

/// `initctl -p status` of a running service, as finit 4.12 prints it.
pub const running_text =
    "     Status : running\n   Identity : foo\nDescription : Foo\n     Origin : /etc/finit.d/enabled/foo.conf\n" ++
    "    Command : /usr/bin/fake-systemd --exec foo.service --log\n   PID file : none\n        PID : 4242\n       User : root\n";

/// What `id -g` prints for any account.
pub const group_id = "4242";

pub const stopped_text = "     Status : stopped (code=signal, status=15/TERM)\n   Identity : foo\n        PID : 0\n";

/// An identity finit knows, with what `initctl -p status` prints for it.
pub const Entry = struct {
    ident: []const u8,
    text: []const u8 = running_text,
};

/// Runner that answers like `initctl` and records every call. A service is known once an entry
/// names it; `start` and `stop` change its text, and a bare `reload` loads `on_reload`.
pub const Initctl = struct {
    gpa: std.mem.Allocator,
    fs: ?*h.core.Fs = null,
    calls: std.ArrayList([]const []const u8) = .empty,
    known: std.ArrayList(Entry) = .empty,
    /// Identities a bare `reload` makes known.
    on_reload: []const Entry = &.{},
    /// File written by every `reload`, as the executor of a task writes its exit file.
    exit_file: ?struct { path: []const u8, text: []const u8 } = null,
    /// Text of a service after `start`; running when null.
    after_start: ?[]const u8 = null,
    /// Calls whose command is listed here exit with status 1.
    fail_commands: []const []const u8 = &.{},

    pub fn runner(s: *Initctl) h.backend.Runner {
        return .{ .ptr = s, .run_fn = runFn };
    }

    fn find(s: *Initctl, ident: []const u8) ?*Entry {
        for (s.known.items) |*e| if (std.mem.eql(u8, e.ident, ident)) return e;
        return null;
    }

    fn isFlag(w: []const u8) bool {
        return w.len > 1 and w[0] == '-';
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const s: *Initctl = @ptrCast(@alignCast(ptr));
        const copy = try s.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try s.gpa.dupe(u8, w);
        try s.calls.append(s.gpa, copy);
        if (argv.len == 0) return .{ .code = 127 };
        if (argv.len == 5 and std.mem.eql(u8, argv[0], "sh") and std.mem.eql(u8, argv[2], finit.status_script)) {
            const entry = s.find(argv[4]) orelse return .{ .code = 69 };
            return .{ .code = 0, .stdout = entry.text };
        }
        if (std.mem.eql(u8, argv[0], "id")) return .{ .code = 0, .stdout = group_id ++ "\n" };
        if (!std.mem.eql(u8, argv[0], "initctl")) return .{ .code = 0 };
        var quiet = false;
        var words: std.ArrayList([]const u8) = .empty;
        for (argv[1..]) |w| {
            if (isFlag(w)) {
                if (std.mem.eql(u8, w, "-q")) quiet = true;
            } else try words.append(s.gpa, w);
        }
        if (words.items.len == 0) return .{ .code = 0 };
        const cmd = words.items[0];
        for (s.fail_commands) |f| if (std.mem.eql(u8, f, cmd)) return .{ .code = 1 };
        if (words.items.len == 1) {
            if (std.mem.eql(u8, cmd, "reload")) {
                for (s.on_reload) |e| if (s.find(e.ident) == null) try s.known.append(s.gpa, e);
                try s.writeExit();
            }
            return .{ .code = 0 };
        }
        const entry = s.find(words.items[1]) orelse return .{ .code = 69 };
        if (std.mem.eql(u8, cmd, "status")) return .{ .code = 0, .stdout = if (quiet) "" else entry.text };
        if (std.mem.eql(u8, cmd, "start") or std.mem.eql(u8, cmd, "restart")) entry.text = s.after_start orelse running_text;
        if (std.mem.eql(u8, cmd, "stop")) entry.text = stopped_text;
        if (std.mem.eql(u8, cmd, "reload")) try s.writeExit();
        return .{ .code = 0 };
    }

    fn writeExit(s: *Initctl) !void {
        const e = s.exit_file orelse return;
        const fs = s.fs orelse return;
        try fs.makePath(std.fs.path.dirname(e.path).?);
        try fs.writeFileAtomic(e.path, e.text, 0o644);
    }

    pub fn callIs(s: Initctl, index: usize, expected: []const []const u8) bool {
        if (index >= s.calls.items.len) return false;
        const call = s.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// Number of calls that start with `prefix`.
    pub fn count(s: Initctl, prefix: []const []const u8) usize {
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
    pub fn dump(s: Initctl, gpa: std.mem.Allocator) ![]const u8 {
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
