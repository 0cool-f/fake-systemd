// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the Shepherd tests: a tmp root with accounts, a native service and systemd
//! units, the Shepherd backend bound to the harness context, and a runner that answers like `herd`.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const shepherd = h.backend.Shepherd;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_scm =
    \\(use-modules (shepherd service))
    \\(register-services
    \\ (list (service '(syslogd)
    \\         #:start (make-forkexec-constructor '("/usr/sbin/syslogd" "-n"))
    \\         #:stop (make-kill-destructor))))
    \\
;

/// Accounts, `setpriv`, a native `syslogd` service in `init.d/`, and translatable systemd units
/// `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/etc/shepherd/init.d/syslog.scm", native_scm, 0o644);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a Shepherd backend to `t` with the generic profile.
pub fn use(t: *h.Harness, s: *shepherd) void {
    s.* = .init(&t.ctx, h.detect.profile.generic.dirs(.shepherd));
}

/// `herd status foo` of a running service, as shepherd 1.0.3 prints it.
pub const running_text =
    "Status of foo:\n  It is running since 19:22:04 (1 second ago).\n  Main PID: 4242\n" ++
    "  Command: /usr/bin/fake-systemd --exec foo.service --log\n  It is enabled.\n  Provides: foo\n  Will not be respawned.\n";
pub const stopped_text = "Status of foo:\n  It is stopped.\n  It is enabled.\n  Provides: foo\n";
pub const disabled_text = "Status of foo:\n  It is stopped since 19:23:01 (1 second ago).\n  Process exited with code 3.\n  It is disabled.\n  Provides: foo\n";

/// A service the daemon knows, with what `herd status` prints for it.
pub const Entry = struct {
    ident: []const u8,
    text: []const u8 = running_text,
};

/// Runner that answers like `herd` and records every call. A service is known once an entry names
/// it or `herd load root` read its file; `start`, `stop` and `enable` change its text.
pub const Herd = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList([]const []const u8) = .empty,
    known: std.ArrayList(Entry) = .empty,
    /// Text of a service after `start` or `restart`; running when null.
    after_start: ?[]const u8 = null,
    /// Calls whose action is listed here exit with status 1.
    fail_commands: []const []const u8 = &.{},

    pub fn runner(s: *Herd) h.backend.Runner {
        return .{ .ptr = s, .run_fn = runFn };
    }

    fn find(s: *Herd, ident: []const u8) ?*Entry {
        for (s.known.items) |*e| if (std.mem.eql(u8, e.ident, ident)) return e;
        return null;
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const s: *Herd = @ptrCast(@alignCast(ptr));
        const copy = try s.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try s.gpa.dupe(u8, w);
        try s.calls.append(s.gpa, copy);
        if (argv.len == 0) return .{ .code = 127 };
        if (argv.len == 5 and std.mem.eql(u8, argv[0], "sh") and std.mem.eql(u8, argv[2], shepherd.status_script)) {
            const entry = s.find(argv[4]) orelse return .{ .code = 1 };
            return .{ .code = 0, .stdout = entry.text };
        }
        if (std.mem.eql(u8, argv[0], "id")) return .{ .code = 0, .stdout = "4242\n" };
        if (!std.mem.eql(u8, argv[0], "herd")) return .{ .code = 0 };
        if (argv.len < 2) return .{ .code = 0 };
        const action = argv[1];
        for (s.fail_commands) |f| if (std.mem.eql(u8, f, action)) return .{ .code = 1 };
        if (std.mem.eql(u8, action, "load") and argv.len == 4) {
            const stem = std.fs.path.stem(argv[3]);
            if (s.find(stem) == null) try s.known.append(s.gpa, .{ .ident = try s.gpa.dupe(u8, stem), .text = stopped_text });
            return .{ .code = 0 };
        }
        if (argv.len < 3) return .{ .code = 0 };
        const entry = s.find(argv[2]) orelse return .{ .code = 1 };
        if (std.mem.eql(u8, action, "status")) return .{ .code = 0, .stdout = entry.text };
        if (std.mem.eql(u8, action, "start") or std.mem.eql(u8, action, "restart")) {
            if (std.mem.find(u8, entry.text, "It is disabled") != null) return .{ .code = 1 };
            entry.text = s.after_start orelse running_text;
        }
        if (std.mem.eql(u8, action, "stop")) entry.text = stopped_text;
        if (std.mem.eql(u8, action, "enable")) entry.text = stopped_text;
        return .{ .code = 0 };
    }

    pub fn callIs(s: Herd, index: usize, expected: []const []const u8) bool {
        if (index >= s.calls.items.len) return false;
        const call = s.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// Number of calls that start with `prefix`.
    pub fn count(s: Herd, prefix: []const []const u8) usize {
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
    pub fn dump(s: Herd, gpa: std.mem.Allocator) ![]const u8 {
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
