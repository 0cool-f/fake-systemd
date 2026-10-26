// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the nosh tests: a tmp root with a native bundle, the target bundles and
//! systemd units, the nosh backend bound to the harness context, and a runner that answers like
//! `system-control` and its converter.
const std = @import("std");
const h = @import("harness.zig");

pub const nosh = h.backend.Nosh;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";

/// A native `syslog` bundle, the target bundles `multi-user` and `shutdown`, and translatable
/// systemd units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/service-bundles/services/syslog/service/run", "#!/bin/nosh\n#Run file\nmove-to-control-group ../syslog.service\n/usr/sbin/syslogd -n\n", 0o755);
    try t.write("/etc/service-bundles/targets/multi-user/wants/.KEEP", "", 0o644);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a nosh backend to `t` with the generic profile; the tools reach the tmp root.
pub fn use(t: *h.Harness, n: *nosh) void {
    n.* = .init(&t.ctx, h.detect.profile.generic.dirs(.nosh));
    n.real_root_override = true;
    n.settle_ms = 200;
    n.transient_ms = 200;
}

pub const running_text = "/etc/service-bundles/services/foo: \n\tState   : running since 2026-10-26 19:53:45 +0000; 2s ago\n\tMain PID: 4242\n\t Started: exit 0 at 2026-10-26 19:53:45 +0000; 2s ago\n\tConfig  : enabled\n";
pub const stopped_text = "/etc/service-bundles/services/foo: \n\tState   : stopped since 2026-10-26 19:53:47 +0000; 1s ago\n\t     Ran: term 15 TERM at 2026-10-26 19:53:47 +0000; 1s ago\n";
pub const failed_text = "/etc/service-bundles/services/foo: \n\tState   : stopped since 2026-10-26 19:53:47 +0000; 1s ago\n\t     Ran: exit 3 at 2026-10-26 19:53:47 +0000; 1s ago\n";
pub const done_failed_text = "/etc/service-bundles/services/foo: \n\tState   : done since 2026-10-26 19:53:47 +0000; 1s ago\n\t     Ran: exit 1 at 2026-10-26 19:53:47 +0000; 1s ago\n";

/// Runner that answers like `system-control` and records every call. The converter makes the
/// bundle of the unit named in its call; `enable` and `disable` make and remove the links of
/// `wanted-by`.
pub const Control = struct {
    gpa: std.mem.Allocator,
    fs: *h.core.Fs,
    calls: std.ArrayList([]const []const u8) = .empty,
    /// Text `status` prints for each service, by name; missing means the bundle has not run.
    states: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Text of a service after `start`; running when null.
    after_start: ?[]const u8 = null,
    /// Calls whose first word after the tool is listed here exit with status 1.
    fail_commands: []const []const u8 = &.{},
    /// `system-control enable` exits 0 without linking, as the real one does on an error.
    enable_fails_silently: bool = false,

    pub fn runner(s: *Control) h.backend.Runner {
        return .{ .ptr = s, .run_fn = runFn };
    }

    fn bundleName(unit: []const u8) []const u8 {
        return std.mem.cutSuffix(u8, unit, ".service") orelse unit;
    }

    fn convert(s: *Control, dir: []const u8, root: []const u8, unit: []const u8) !u8 {
        const unit_path = try std.fs.path.join(s.gpa, &.{ dir, unit });
        const template = if (std.mem.findScalar(u8, unit, '@')) |at| try std.fmt.allocPrint(s.gpa, "{s}@.service", .{unit[0..at]}) else unit;
        const text = s.fs.readFileAlloc(s.gpa, try std.fs.path.join(s.gpa, &.{ dir, template }), 1 << 16) catch {
            _ = unit_path;
            return 1;
        };
        const exec = if (std.mem.find(u8, text, "ExecStart=")) |at| blk: {
            const rest = text[at + "ExecStart=".len ..];
            break :blk rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];
        } else "/bin/true";
        const name = bundleName(unit);
        const bundle = try std.fs.path.join(s.gpa, &.{ root, name });
        const run = try std.fmt.allocPrint(s.gpa, "#!/bin/nosh\n#Run file generated from ./{s}\nmove-to-control-group ../{s}\n{s}", .{ unit, unit, exec });
        try s.fs.makePath(try std.fs.path.join(s.gpa, &.{ bundle, "service" }));
        try s.fs.writeFileAtomic(try std.fs.path.join(s.gpa, &.{ bundle, "service", "run" }), run, 0o755);
        try s.fs.makePath(try std.fs.path.join(s.gpa, &.{ bundle, "wanted-by" }));
        s.fs.symLink("../../../targets/multi-user", try std.fs.path.join(s.gpa, &.{ bundle, "wanted-by", "multi-user" })) catch |e| if (e != error.PathAlreadyExists) return e;
        return 0;
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const s: *Control = @ptrCast(@alignCast(ptr));
        const copy = try s.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try s.gpa.dupe(u8, w);
        try s.calls.append(s.gpa, copy);
        if (argv.len == 0) return .{ .code = 127 };
        if (argv.len == 7 and std.mem.eql(u8, argv[0], "sh")) return .{ .code = try s.convert(argv[4], argv[5], argv[6]) };
        if (!std.mem.eql(u8, argv[0], "system-control") or argv.len < 2) return .{ .code = 0 };
        const cmd = argv[1];
        for (s.fail_commands) |f| if (std.mem.eql(u8, f, cmd)) return .{ .code = 1 };
        if (argv.len < 3) return .{ .code = 0 };
        const name = argv[2];
        const bundle = try std.fs.path.join(s.gpa, &.{ "/etc/service-bundles/services", name });
        if (std.mem.eql(u8, cmd, "enable") or std.mem.eql(u8, cmd, "disable")) {
            if (s.enable_fails_silently) return .{ .code = 0 };
            const wanted = try std.fs.path.join(s.gpa, &.{ bundle, "wanted-by" });
            const entries = s.fs.iterateDir(s.gpa, wanted) catch return .{ .code = 0 };
            for (entries) |e| {
                const dir = try std.fs.path.join(s.gpa, &.{ "/etc/service-bundles/targets", e.name, "wants" });
                const link = try std.fs.path.join(s.gpa, &.{ dir, name });
                if (std.mem.eql(u8, cmd, "enable")) {
                    try s.fs.makePath(dir);
                    s.fs.symLink(try std.fmt.allocPrint(s.gpa, "../../../services/{s}", .{name}), link) catch {};
                } else s.fs.deleteFile(link) catch {};
            }
            return .{ .code = 0 };
        }
        if (std.mem.eql(u8, cmd, "status")) {
            if (!s.fs.exists(bundle)) return .{ .code = 1 };
            return .{ .code = 0, .stdout = s.states.get(name) orelse stopped_text };
        }
        if (std.mem.eql(u8, cmd, "start")) try s.states.put(s.gpa, try s.gpa.dupe(u8, name), s.after_start orelse running_text);
        if (std.mem.eql(u8, cmd, "stop")) try s.states.put(s.gpa, try s.gpa.dupe(u8, name), stopped_text);
        return .{ .code = 0 };
    }

    pub fn callIs(s: Control, index: usize, expected: []const []const u8) bool {
        if (index >= s.calls.items.len) return false;
        const call = s.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }

    /// Number of calls that start with `prefix`.
    pub fn count(s: Control, prefix: []const []const u8) usize {
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
    pub fn dump(s: Control, gpa: std.mem.Allocator) ![]const u8 {
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
