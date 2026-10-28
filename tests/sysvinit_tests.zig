// SPDX-License-Identifier: GPL-3.0-or-later
//! The sysvinit backend behind the real `ops` entry point, with a runner that answers like the
//! init scripts, `update-rc.d`, `chkconfig` and `insserv`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("sysvinit_world.zig");
const dinit_world = @import("dinit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const init_d = "/etc/init.d";
const env_skip_systemd = "_SKIP_SYSTEMD_NATIVE=1";
const env_skip_redirect = "SYSTEMCTL_SKIP_REDIRECT=1";

const Fixture = struct {
    t: h.Harness = undefined,
    s: world.sysvinit = undefined,
    sc: world.Script = undefined,
    variant: world.Variant = .debian,

    fn init(f: *Fixture, variant: world.Variant) !void {
        f.variant = variant;
        try f.t.init();
        try world.populate(&f.t, variant);
        switch (variant) {
            .debian => {
                try f.t.write("/usr/sbin/update-rc.d", "#!/bin/sh\n", 0o755);
                try f.t.write("/sbin/insserv", "#!/bin/sh\n", 0o755);
            },
            .redhat => try f.t.write("/sbin/chkconfig", "#!/bin/sh\n", 0o755),
        }
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "sysvinit";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.s, f.variant);
        f.t.backend_override = f.s.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    /// Directory of the links of runlevel `level`.
    fn rcDir(f: *Fixture, level: u8) ![]const u8 {
        return std.fmt.allocPrint(f.t.a(), "{s}/rc{c}.d", .{ if (f.variant == .debian) "/etc" else "/etc/rc.d", level });
    }

    fn rcPath(f: *Fixture, level: u8, file: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ try f.rcDir(level), file });
    }

    /// Creates the links `Fixture.rcPath(level, file)` of the service as a tool would.
    fn link(f: *Fixture, level: u8, file: []const u8, service: []const u8) !void {
        const target = try std.fmt.allocPrint(f.t.a(), "../init.d/{s}", .{service});
        try f.t.fs.symLink(target, try f.rcPath(level, file));
    }

    fn hasLink(f: *Fixture, level: u8, file: []const u8) bool {
        const path = f.rcPath(level, file) catch return false;
        _ = f.t.fs.lstat(path) catch return false;
        return true;
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.sc.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.sc.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectCalled(f: *Fixture, prefix: []const []const u8) !void {
        if (!f.sc.called(prefix)) {
            std.debug.print("no call starts with {s}; calls:\n{s}", .{ prefix[0], try f.sc.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectNoCall(f: *Fixture, prefix: []const []const u8) !void {
        if (f.sc.called(prefix)) {
            std.debug.print("unexpected call {s}; calls:\n{s}", .{ prefix[0], try f.sc.dump(f.t.a()) });
            return error.TestUnexpectedCall;
        }
    }

    fn status(f: *Fixture, service: []const u8, code: u8, stdout: []const u8) void {
        const a = f.t.a();
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ init_d, service }) catch @panic("out of memory");
        const prefix = a.dupe([]const u8, &.{ path, "status" }) catch @panic("out of memory");
        const rule: world.Rule = .{ .prefix = prefix, .code = code, .stdout = stdout };
        f.sc.rules = std.mem.concat(a, world.Rule, &.{ f.sc.rules, &.{rule} }) catch @panic("out of memory");
    }

    fn script(f: *Fixture, name: []const u8) ![]const u8 {
        const rest = marker.parse(try f.t.read(try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ init_d, name }))).?.rest;
        return std.fmt.allocPrint(f.t.a(), "\n{s}", .{rest});
    }
};

fn addSvc(t: *h.Harness, name: []const u8, unit_lines: []const u8, service: []const u8) !void {
    const exec = try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name});
    const text = try std.fmt.allocPrint(
        t.a(),
        "[Unit]\n{s}\n[Service]\nExecStart={s} --run\n{s}\n[Install]\nWantedBy=multi-user.target\n",
        .{ unit_lines, exec, service },
    );
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name}), text, 0o644);
    try t.write(exec, "#!/bin/sh\n", 0o755);
}

// ---- generation and enablement ----------------------------------------------------------------

test "Debian enable generates the script and enables it with update-rc.d without systemctl calls back" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(init_d ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 sysvinit/2", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/bin/sh\n", parsed.shebang);
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(init_d ++ "/foo")).mode);
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo", "defaults" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    // update-rc.d would have written the links; the backend only asks for them.
    try testing.expect(!f.hasLink('2', "S80foo"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "Red Hat enable asks chkconfig, which is told not to forward to systemctl" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(init_d ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try f.expectCall(0, &.{ "env", env_skip_redirect, "chkconfig", "foo", "on" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "the links a tool wrote are reported and is-enabled reads the default runlevel" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try f.link('2', "S01foo", "foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    // A link in another runlevel does not enable the service for the default one.
    try t.fs.deleteFile("/etc/rc2.d/S01foo");
    try f.link('3', "S01foo", "foo");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    // A stop link, which is what update-rc.d disable leaves, means disabled.
    try f.link('2', "K01foo", "foo");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
}

test "the default runlevel comes from inittab, and from the profile without it" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link('3', "S20foo", "foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try t.write("/etc/inittab", "id:5:initdefault:\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try f.link('5', "S20foo", "foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    // The stub inittab of a systemd system names no level.
    try t.write("/etc/inittab", "# inittab is no longer used.\n# id:5:initdefault:\n", 0o644);
    try t.fs.deleteFile("/etc/rc.d/rc5.d/S20foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
}

test "offline in a root that is not the running one, links are written directly" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    for ("2345") |level| try testing.expect(f.hasLink(level, "S80foo"));
    for ("016") |level| try testing.expect(f.hasLink(level, "K20foo"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("../init.d/foo", try t.fs.readLink("/etc/rc2.d/S80foo", &buf));
    try h.expectContains(t.stderr(), "Created symlink '/etc/rc2.d/S80foo' -> '../init.d/foo'.");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/rc2.d/S80foo'.");
    try testing.expect(!f.hasLink('2', "S80foo") and f.hasLink('2', "K80foo"));
    try testing.expect(f.hasLink('0', "K20foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);

    // Enabling again turns the stop links of the start runlevels back, keeping their numbers.
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(f.hasLink('2', "S80foo") and !f.hasLink('2', "K80foo"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "offline Red Hat links use the priorities of the chkconfig line" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    for ("2345") |level| try testing.expect(f.hasLink(level, "S80foo"));
    for ("016") |level| try testing.expect(f.hasLink(level, "K20foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
}

test "offline in the running root, the tools write the links" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    t.fs.host_root = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo", "defaults" });
    // Without the tool the links are written directly.
    try t.fs.deleteFile("/usr/sbin/update-rc.d");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(f.hasLink('2', "S80foo"));
}

test "a service that was disabled is enabled again with update-rc.d enable" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link('2', "K01foo", "foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo", "enable" });
}

test "Debian disable names the runlevels that start the service" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link('2', "S01foo", "foo");
    try f.link('3', "S01foo", "foo");
    try f.link('0', "K01foo", "foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo", "disable", "2", "3" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    // Nothing is left to disable once the links are gone.
    try t.fs.deleteFile("/etc/rc2.d/S01foo");
    try t.fs.deleteFile("/etc/rc3.d/S01foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "Red Hat disable turns the levels off with chkconfig" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link('3', "S80foo", "foo");
    try f.link('4', "S80foo", "foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ "env", env_skip_redirect, "chkconfig", "--level", "34", "foo", "off" });
}

test "a failing tool fails the enable" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    f.sc.rules = &.{.{ .prefix = &.{ "env", env_skip_systemd }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), f.t.run(&.{ "enable", "foo" }));
}

test "enable --runtime warns and enables persistently" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--runtime", "foo" }));
    try h.expectContains(t.stderr(), "--runtime is not supported");
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo", "defaults" });
}

test "the index records the script and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/sysvinit/index"), init_d ++ "/foo");
    try t.fs.deleteFile("/var/lib/fake-systemd/sysvinit/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expect(t.exists(init_d ++ "/syslog"));
}

test "a template instance is a script named name.instance" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists(init_d ++ "/tpl.one"));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "tpl.one", "defaults" });
    const parsed = marker.parse(try t.read(init_d ++ "/tpl.one")).?;
    try testing.expectEqualStrings("tpl@one.service", parsed.marker.unit);
}

test "a native script that starts the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.write(init_d ++ "/foo-daemon", "#!/bin/sh\nDAEMON=/usr/bin/foo\nstart-stop-daemon --start --quiet --pidfile /run/foo.pid --exec $DAEMON -- --run\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "foo-daemon", "defaults" });
    try f.expectCalled(&.{ init_d ++ "/foo-daemon", "start" });
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
}

test "Red Hat natives are found by their daemon call" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try t.write(init_d ++ "/foo-daemon", "#!/bin/sh\n# chkconfig: 2345 90 10\nexec=/usr/bin/foo\nstart() {\n\tdaemon $exec --run\n}\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try f.expectCall(0, &.{ "env", env_skip_redirect, "chkconfig", "foo-daemon", "on" });
}

test "dry-run prints the links and the commands it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would create symlink '/etc/rc2.d/S80foo' -> '../init.d/foo'\n");
    try h.expectContains(t.stdout(), "would run: /etc/init.d/foo start\n");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "stop", "foo" }));
    try h.expectContains(t.stdout(), "would run: /etc/init.d/foo stop\n");
}

test "reverting a service removes its generated script" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link('2', "S01foo", "foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try f.expectCalled(&.{ "env", env_skip_systemd, "update-rc.d", "foo", "disable" });
    try testing.expect(!t.exists(init_d ++ "/foo"));
}

// ---- dependencies --------------------------------------------------------------------------------

test "a required script is enabled first, and a script that requires an enabled one keeps it enabled" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "b", "defaults" });
    try f.expectCall(1, &.{ "env", env_skip_systemd, "update-rc.d", "a", "defaults" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
    // insserv takes a Required-Start that is not enabled for a fatal error: a service is a Should-Start.
    const body = try f.script("a");
    try h.expectContains(body, "\n# Required-Start:    $remote_fs\n# Required-Stop:     $remote_fs\n# Should-Start:      b\n# Should-Stop:       b\n");
    try h.expectContains(body, "\n### END INIT INFO\n# Pulls-In: b\n");

    // A script of the system that requires b makes it a requirement insserv checks.
    try t.write(init_d ++ "/needs-b", "#!/bin/sh\n### BEGIN INIT INFO\n# Provides: needs-b\n# Required-Start: b\n# Required-Stop: b\n# Default-Start: 2\n# Default-Stop: 0\n# Short-Description: x\n### END INIT INFO\n", 0o755);
    try f.link('2', "S01b", "b");
    try f.link('2', "S02needs-b", "needs-b");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "disable", "b" }));
    try h.expectContains(t.stderr(), "required by needs-b, which is enabled");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try t.fs.deleteFile("/etc/rc2.d/S02needs-b");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "b" }));
}

test "a required script is enabled on Red Hat too, and chkconfig orders it by the header" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try f.expectCall(0, &.{ "env", env_skip_redirect, "chkconfig", "b", "on" });
    try f.expectCall(1, &.{ "env", env_skip_redirect, "chkconfig", "a", "on" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
    // chkconfig does not reject a disabled requirement, so b can be disabled.
    try f.link('3', "S80a", "a");
    try f.link('3', "S80b", "b");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "b" }));
}

test "dependencies: hard ones and the filesystems are required on Red Hat, services are Should-Start on Debian, Before is X-Start-Before" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    const unit_lines = "Requires=b.service\nBindsTo=c.service\nWants=d.service\nAfter=b.service e.service\nBefore=f.service";
    try addSvc(&d.t, "a", unit_lines, "");
    for ([_][]const u8{ "b", "c", "d", "e", "f" }) |n| try addSvc(&d.t, n, "", "");
    try testing.expectEqual(@as(u8, 0), d.t.run(&.{ "enable", "a" }));
    const deb = try d.script("a");
    try h.expectContains(deb, "\n# Provides:          a\n# Required-Start:    $remote_fs\n# Required-Stop:     $remote_fs\n# Should-Start:      b c d e\n# Should-Stop:       b c d e\n# X-Start-Before:    f\n# X-Stop-After:      f\n");
    try h.expectContains(deb, "\n# Pulls-In: b c\n");
    // Units pulled in by Requires=, BindsTo= and Wants= get scripts; those named only in After= and Before= do not.
    for ([_][]const u8{ "b", "c", "d" }) |dep| {
        try testing.expect(d.t.exists(try std.fmt.allocPrint(d.t.a(), "{s}/{s}", .{ init_d, dep })));
    }
    // Only the hard dependencies are enabled with the script.
    try d.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "b", "defaults" });
    try d.expectCall(1, &.{ "env", env_skip_systemd, "update-rc.d", "c", "defaults" });
    try d.expectCall(2, &.{ "env", env_skip_systemd, "update-rc.d", "a", "defaults" });
    try testing.expectEqual(@as(usize, 3), d.sc.calls.items.len);

    var r: Fixture = .{};
    try r.init(.redhat);
    defer r.deinit();
    try addSvc(&r.t, "a", unit_lines, "");
    for ([_][]const u8{ "b", "c", "d", "e", "f" }) |n| try addSvc(&r.t, n, "", "");
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{ "enable", "a" }));
    try h.expectContains(try r.script("a"), "\n# Required-Start:    $remote_fs b c\n# Required-Stop:     $remote_fs b c\n# Should-Start:      d e\n# Should-Stop:       d e\n# X-Start-Before:    f\n# X-Stop-After:      f\n");
}

test "a native script that matches a dependency is referenced by its native name" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try t.write(init_d ++ "/b-native", "#!/bin/sh\nDAEMON=/usr/bin/b\nstart-stop-daemon --start --exec $DAEMON -- --other\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(!t.exists(init_d ++ "/b"));
    try h.expectContains(try f.script("a"), "\n# Should-Start:      b-native\n");
    // A native requirement is the business of the administrator: it is not enabled.
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "a dependency the classifier excludes is left out of the header" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service", "");
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/hook\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectNotContains(body, "hook");
    try h.expectNotContains(body, "gone");
    try h.expectContains(body, "\n# Required-Start:    $remote_fs\n");
    try h.expectNotContains(body, "Should-Start");
}

test "network targets are the network facility, required when required" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "plain", "After=network.target", "");
    try addSvc(t, "online", "After=network-online.target\nWants=network-online.target", "");
    try addSvc(t, "hard", "Requires=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain", "online", "hard" }));
    try h.expectContains(try f.script("plain"), "\n# Required-Start:    $remote_fs\n# Required-Stop:     $remote_fs\n# Should-Start:      $network\n");
    try h.expectContains(try f.script("online"), "\n# Should-Start:      $network\n");
    try h.expectContains(try f.script("hard"), "\n# Required-Start:    $remote_fs $network\n");
    try h.expectNotContains(try f.script("hard"), "Should-Start");
}

// ---- how the script runs the unit ----------------------------------------------------------------

test "a daemon runs its executor under start-stop-daemon on Debian and detached by the executor on Red Hat" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    try testing.expectEqual(@as(u8, 0), d.t.run(&.{ "enable", "foo" }));
    const deb = try d.script("foo");
    try h.expectContains(deb, "\n\tstart-stop-daemon --start --quiet --background --make-pidfile --pidfile \"$daemon_pid\" --exec /usr/bin/fake-systemd -- --exec foo.service --log --record-exit\n");
    try h.expectContains(deb, "\n\t\tstart-stop-daemon --stop --quiet --oknodo --retry \"TERM/$stop_wait/KILL/5\" --pidfile \"$daemon_pid\" --name fake-systemd || rc=$?\n");
    try h.expectContains(deb, "\ndaemon_pid=/run/fake-systemd/foo.service.daemon.pid\nstop_wait=100\n");
    try h.expectNotContains(deb, "chkconfig");
    try h.expectNotContains(deb, "lock_file");

    var r: Fixture = .{};
    try r.init(.redhat);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{ "enable", "foo" }));
    const rh = try r.script("foo");
    try h.expectContains(rh, "\n# chkconfig: 2345 80 20\n# description: Unit foo.service\n");
    try h.expectContains(rh, "\n\t/usr/bin/fake-systemd --exec foo.service --daemon --log --record-exit\n");
    try h.expectContains(rh, "\n\t[ \"$_rc\" -eq 0 ] && : > \"$lock_file\"\n");
    try h.expectContains(rh, "\nlock_file=/var/lock/subsys/foo\n");
    try h.expectContains(rh, "\nstop_daemon() {\n");
    try h.expectNotContains(rh, "start-stop-daemon");
}

test "ExecStop makes the executor stop on the signal, ExecStopPost and runtime directories run after the stop" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hook", "", "ExecStop=/usr/bin/hook-stop");
    try addSvc(t, "post", "", "ExecStopPost=/usr/bin/hook-cleanup");
    try addSvc(t, "dirs", "", "RuntimeDirectory=dirs");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hook", "post", "dirs" }));
    try h.expectContains(try f.script("hook"), "-- --exec hook.service --stop-on-signal --log --record-exit\n");
    try h.expectNotContains(try f.script("hook"), "--phase stop-post");
    for ([_][]const u8{ "post", "dirs" }) |n| {
        const body = try f.script(n);
        try h.expectContains(body, try std.fmt.allocPrint(t.a(), "\n\t/usr/bin/fake-systemd --exec {s}.service --phase stop-post || rc=$?\n\trm -f \"$main_pid\" \"$exit_file\"\n", .{n}));
    }
}

test "ExecReload is the reload action and a unit without it reports the action unsupported" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hooked", "", "ExecReload=/usr/bin/hooked-ctl reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooked", "foo" }));
    const hooked = try f.script("hooked");
    try h.expectContains(hooked, "\ndo_reload() {\n\trunning || {\n\t\techo \"hooked.service is not running\" >&2\n\t\treturn 7\n\t}\n\t/usr/bin/fake-systemd --exec hooked.service --phase reload\n}\n");
    try h.expectContains(hooked, "\nreload)\n\tdo_reload\n\t;;\nforce-reload)\n\tdo_reload\n\t;;\n");
    try h.expectContains(try f.script("foo"), "\nreload)\n\techo \"foo.service does not support reload\" >&2\n\texit 3\n\t;;\nforce-reload)\n\tdo_stop\n\tdo_start\n\t;;\n");
}

test "TimeoutStopSec and KillMode become the wait of the stop and whether it ends in a kill" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "quick", "", "TimeoutStopSec=1.5");
    try addSvc(t, "forever", "", "TimeoutStopSec=infinity");
    try addSvc(t, "nokill", "", "TimeoutStopSec=7\nKillMode=none");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "quick", "forever", "nokill" }));
    try h.expectContains(try f.script("quick"), "\nstop_wait=12\n");
    try h.expectContains(try f.script("forever"), "\nstop_wait=2147483647\n");
    try h.expectContains(try f.script("forever"), "--retry \"TERM/$stop_wait\" --pidfile");
    try h.expectContains(try f.script("nokill"), "\nstop_wait=17\n");
    try h.expectContains(try f.script("nokill"), "--retry \"TERM/$stop_wait\" --pidfile");
    try h.expectContains(try f.script("nokill"), "# KillMode=none is handled like control-group\n");
}

test "Restart= is noted as not honored" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "again", "", "Restart=on-failure");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "again" }));
    const body = try f.script("again");
    try h.expectContains(body, "\n# Restart=on-failure is not honored: sysvinit does not supervise services, a service that dies stays dead\n");
    try h.expectContains(body, "is dead and is not restarted: sysvinit does not supervise services");
}

test "an account only the system libc resolves is given to the root executor as numeric ids" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    const t = &d.t;
    try addSvc(t, "ldap", "", "User=svc-directory\nGroup=dir-group\nExecReload=/usr/bin/reload-ldap");
    try addSvc(t, "ldapg", "", "User=svc-directory\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap", "ldapg" }));
    const ldap = try d.script("ldap");
    const ids = " --uid \"$(id -u -- svc-directory)\" --gid \"$(getent group dir-group | cut -d: -f3)\" --groups \"$(id -G -- svc-directory | tr ' ' ,)\"";
    try h.expectContains(ldap, "--pidfile \"$daemon_pid\" --exec /usr/bin/fake-systemd -- --exec ldap.service --log --record-exit" ++ ids ++ "\n");
    try h.expectContains(ldap, "\n\t/usr/bin/fake-systemd --exec ldap.service --phase reload" ++ ids ++ "\n");
    // Nothing changes hands: the files stay root's, and nothing switches before the executor.
    try h.expectNotContains(ldap, "chown");
    try h.expectNotContains(ldap, "--chuid");
    try h.expectNotContains(ldap, "setpriv");
    try h.expectNotContains(ldap, "--identity-set");
    const groups = try d.script("ldapg");
    try h.expectContains(groups, "-- --exec ldapg.service --log --record-exit --uid \"$(id -u -- svc-directory)\" --gid \"$(id -g -- svc-directory)\" --groups \"$(id -G -- svc-directory | tr ' ' ,),$(getent group audio | cut -d: -f3)\"\n");

    var r: Fixture = .{};
    try r.init(.redhat);
    defer r.deinit();
    try addSvc(&r.t, "ldap", "", "User=svc-directory");
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{ "enable", "ldap" }));
    try h.expectContains(try r.script("ldap"), "\n\t/usr/bin/fake-systemd --exec ldap.service --daemon --log --record-exit --uid \"$(id -u -- svc-directory)\" --gid \"$(id -g -- svc-directory)\" --groups \"$(id -G -- svc-directory | tr ' ' ,)\"\n");
    try h.expectNotContains(try r.script("ldap"), "chown");
}

test "an account name that starts with a dash is refused instead of reaching id as an option" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    const t = &d.t;
    const bad = [_][]const u8{ "User=-r", "User=--", "User=svc-directory\nGroup=-g", "User=svc-directory\nSupplementaryGroups=-a" };
    for (bad) |lines| {
        try addSvc(t, "dash", "", lines);
        try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "dash" }));
        try h.expectContains(t.stderr(), "must be plain names");
        try testing.expect(!t.exists(init_d ++ "/dash"));
    }
}

test "daemon-reload exits 1 when a unit is refused and still handles the others" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    const t = &d.t;
    try addSvc(t, "other", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo", "other" }));
    try addSvc(t, "foo", "", "User=-r");
    try addSvc(t, "other", "Description=handled-too", "");
    try testing.expectEqual(@as(u8, 1), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "foo.service: cannot load unit");
    try h.expectContains(try d.script("other"), "handled-too");
}

test "an account the executor resolves needs no switch in the script" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "known", "", "User=app\nGroup=app\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "known" }));
    const body = try f.script("known");
    try h.expectNotContains(body, "chuid");
    try h.expectNotContains(body, "setpriv");
    try h.expectNotContains(body, "chown");
}

test "a oneshot runs to the end in start and reads inactive afterwards, or active with RemainAfterExit" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/fw.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/job\nExecStop=/usr/bin/job-undo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job", "fw" }));
    const job = try f.script("job");
    try h.expectContains(job, "\n\t/usr/bin/fake-systemd --exec job.service --log --record-exit > /dev/null\n\t_rc=$?\n\trm -f \"$main_pid\"\n\treturn \"$_rc\"\n");
    try h.expectContains(job, "\t\techo \"job.service has finished\"\n\t\treturn 3\n");
    try h.expectNotContains(job, "daemon_pid");
    try h.expectNotContains(job, "--phase stop");
    const fw = try f.script("fw");
    try h.expectContains(fw, "\ndo_start() {\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n\tesac\n");
    try h.expectContains(fw, "\t\techo \"fw.service is active (exited)\"\n\t\treturn 0\n");
    try h.expectContains(fw, "\t\t/usr/bin/fake-systemd --exec fw.service --phase stop || rc=$?\n");
}

test "a unit without ExecStart, and a forking daemon without a pid file, are states the script keeps" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/empty.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStop=/usr/bin/cleanup\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try addSvc(t, "fork", "", "Type=forking");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "empty", "fork" }));
    const empty = try f.script("empty");
    try h.expectContains(empty, "\ndo_start() {\n\tmkdir -p \"$state_dir\" || return 1\n\techo 'ok 0' > \"$exit_file\"\n");
    try h.expectNotContains(empty, "--log");
    const fork = try f.script("fork");
    try h.expectContains(fork, "# Type=forking without PIDFile=: the daemon is started but not followed, and stop cannot signal it\n");
    try h.expectContains(fork, "\t\techo \"fork.service is active (exited)\"\n");
    try h.expectNotContains(fork, "--daemon");
}

// ---- runtime control ----------------------------------------------------------------------------

test "start, stop, restart and reload run the script and a failure is reported" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(0, &.{ init_d ++ "/foo", "start" });
    try f.expectCall(1, &.{ init_d ++ "/foo", "stop" });
    try f.expectCall(2, &.{ init_d ++ "/foo", "restart" });
    try f.expectCall(3, &.{ init_d ++ "/foo", "reload" });
    try testing.expectEqual(@as(usize, 4), f.sc.calls.items.len);

    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "start" }, .code = 1, .stdout = "Starting foo: first line\nfoo: cannot bind port\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    try h.expectContains(t.stderr(), "foo: cannot bind port");
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "stop" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "restart" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "restart", "foo" }));
}

test "status codes of the script are normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { u8, []const u8, u8 }{
        .{ 0, "active\n", 0 },
        .{ 1, "failed\n", 3 },
        .{ 2, "failed\n", 3 },
        .{ 3, "inactive\n", 3 },
        .{ 4, "inactive\n", 3 },
        .{ 127, "inactive\n", 3 },
    };
    for (cases) |c| {
        f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "status" }, .code = c[0] }};
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "status" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "status" }, .code = 0 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-failed", "foo" }));
    // A script that does not know the action prints its usage and exits 1.
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "status" }, .code = 1, .stdout = "Usage: /etc/init.d/foo {start|stop}\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "the main pid is the one the executor recorded, or the pid file of a native script" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try dinit_world.liveProcess(t, 4300);
    try t.write("/run/fake-systemd/foo.service.pid", "4300 4300\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4300");
    // Nothing is shown for a service that is not up.
    f.status("foo", 3, "");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "status", "foo" }));
    try h.expectNotContains(t.stdout(), "Main PID");
}

test "kill signals the main process" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    try dinit_world.liveProcess(t, 4242);
    try t.write("/run/fake-systemd/foo.service.pid", "4242 4242\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGHUP", "foo" }));
    try testing.expect(f.sc.called(&.{ "kill", "-s", "HUP", "4242" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "USR1", "foo" }));
    try testing.expect(f.sc.called(&.{ "kill", "-s", "USR1", "4242" }));
}

// ---- manager and power ---------------------------------------------------------------------------

test "daemon-reload runs insserv again on Debian and reads the priorities again on Red Hat" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    try testing.expectEqual(@as(u8, 0), d.t.run(&.{ "enable", "foo" }));
    d.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), d.t.run(&.{"daemon-reload"}));
    try d.expectCall(0, &.{"insserv"});
    d.sc.rules = &.{.{ .prefix = &.{"insserv"}, .code = 1 }};
    try testing.expectEqual(@as(u8, 0), d.t.run(&.{"daemon-reload"}));
    try h.expectContains(d.t.stderr(), "insserv failed");

    var r: Fixture = .{};
    try r.init(.redhat);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{ "enable", "foo" }));
    r.sc.calls.clearRetainingCapacity();
    // The script has no links yet: there is nothing to read again.
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{"daemon-reload"}));
    try r.expectNoCall(&.{"env"});
    try r.link('3', "S80foo", "foo");
    try testing.expectEqual(@as(u8, 0), r.t.run(&.{"daemon-reload"}));
    try r.expectCall(0, &.{ "env", env_skip_redirect, "chkconfig", "foo", "resetpriorities" });
    try testing.expectEqual(@as(usize, 1), r.sc.calls.items.len);
}

test "daemon-reload offline leaves the tools alone" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "power verbs go through shutdown" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{ "shutdown", "-r", "now" });
    try f.expectCall(1, &.{ "shutdown", "-h", "-P", "now" });
    try f.expectCall(2, &.{ "shutdown", "-h", "-H", "now" });
}

// ---- flavour, scope and timers ----------------------------------------------------------------

test "a generic sysvinit is Red Hat only when chkconfig is its sole tool" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(world.Variant.debian, world.sysvinit.variantFor(&t.ctx, .sysvinit));
    try t.fs.deleteFile("/usr/sbin/update-rc.d");
    try t.fs.deleteFile("/sbin/insserv");
    try testing.expectEqual(world.Variant.debian, world.sysvinit.variantFor(&t.ctx, .sysvinit));
    try t.write("/usr/sbin/chkconfig", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(world.Variant.redhat, world.sysvinit.variantFor(&t.ctx, .sysvinit));
    try t.write("/sbin/insserv", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(world.Variant.debian, world.sysvinit.variantFor(&t.ctx, .sysvinit));
    try testing.expectEqual(world.Variant.redhat, world.sysvinit.variantFor(&t.ctx, .sysvinit_redhat));
    try testing.expectEqual(world.Variant.debian, world.sysvinit.variantFor(&t.ctx, .sysvinit_debian));
}

test "capabilities are ordering only, without supervision, a restart policy or user services" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const c = f.t.backend_override.?.caps();
    try testing.expect(c.hard_deps and c.soft_deps and c.ordering and c.translates);
    try testing.expect(!c.supervision and !c.restart_policy and !c.user_services and !c.oneshot and !c.per_service_logger);
}

test "user scope is refused with the reason" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "sysvinit has no service manager for users");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "the timer runner is generated as a daemon, started by its script and signalled with HUP" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    f.status("fake-systemd-timers", 3, "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    const body = try f.script("fake-systemd-timers");
    try h.expectContains(body, "-- --exec fake-systemd-timers.service --log --record-exit\n");
    try h.expectContains(body, "# Restart=always is not honored");
    try f.expectCalled(&.{ "env", env_skip_systemd, "update-rc.d", "fake-systemd-timers", "defaults" });
    try f.expectCalled(&.{ init_d ++ "/fake-systemd-timers", "start" });

    try f.link('2', "S01fake-systemd-timers", "fake-systemd-timers");
    try dinit_world.liveProcess(t, 7);
    try t.write("/run/fake-systemd/fake-systemd-timers.service.pid", "7 7\n", 0o644);
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/fake-systemd-timers", "status" }, .code = 0 }};
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "7" });

    f.sc.rules = &.{};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists(init_d ++ "/fake-systemd-timers"));
    try f.expectCalled(&.{ "env", env_skip_systemd, "update-rc.d", "fake-systemd-timers", "disable", "2" });
}

test "status of the timer runner says it died when its process is gone" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    f.status("fake-systemd-timers", 1, "fake-systemd-timers.service is dead and is not restarted: sysvinit does not supervise services\n");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "fake-systemd-timers" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "status", "fake-systemd-timers" }));
    try h.expectContains(t.stdout(), "Active: failed (failed)");
}

test "daemon-reload enables what a script pulls in after it was generated again, and sorts the boot" {
    var d: Fixture = .{};
    try d.init(.debian);
    defer d.deinit();
    const t = &d.t;
    try addSvc(t, "late", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "late" }));
    try d.link('2', "S01late", "late");
    try addSvc(t, "early", "", "");
    try addSvc(t, "late", "Requires=early.service", "");
    d.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try d.script("late"), "\n# Pulls-In: early\n");
    try d.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "early", "defaults" });
    try d.expectCall(1, &.{"insserv"});
    try testing.expectEqual(@as(usize, 2), d.sc.calls.items.len);
    // Nothing is enabled that the script does not pull in, or that is already enabled.
    d.sc.calls.clearRetainingCapacity();
    try d.link('2', "S01early", "early");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try d.expectCall(0, &.{"insserv"});
    try testing.expectEqual(@as(usize, 1), d.sc.calls.items.len);
}

test "in another root nothing reloads, and enabling again pulls in with direct links and calls no tool" {
    var f: Fixture = .{};
    try f.init(.redhat);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try addSvc(t, "late", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "late" }));
    try addSvc(t, "early", "", "");
    try addSvc(t, "late", "Requires=early.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!f.hasLink('3', "S80early"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "late" }));
    try testing.expect(f.hasLink('3', "S80early"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "an account name with shell characters is refused for a switch through the system libc" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "evil", "", "User=a;touch$IFS/x");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "evil" }));
    try h.expectContains(t.stderr(), "must be plain names");
    try testing.expect(!t.exists(init_d ++ "/evil"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "two units that map to the same script name are not both generated" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "foo.bar", "", "");
    try addSvc(t, "foo@", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo.bar" }));
    try testing.expect(t.run(&.{ "enable", "foo@bar" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
    try h.expectContains(try t.read(init_d ++ "/foo.bar"), "# Unit: foo.bar.service\n");
}

test "a pid file that names init, a dead process or a process of another account is not signalled" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try dinit_world.liveProcess(t, 1);
    try t.write("/run/fake-systemd/foo.service.pid", "1 1\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    try t.write("/run/fake-systemd/foo.service.pid", "31337 31337\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    try testing.expect(!f.sc.called(&.{"kill"}));
    try dinit_world.liveProcess(t, 31337);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    // The script trusts the pid file only for a numeric pid above 1.
    try h.expectContains(try f.script("foo"), "case $_pid in ''|*[!0-9]*) return 1 ;; esac\n\t[ \"$_pid\" -gt 1 ]");
}

test "a dependency name ending in a backslash is left out of the header, which would continue the line" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "needs", "Requires=bs\\.service", "");
    try t.write(init_d ++ "/bs\\", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "needs" }));
    const body = try f.script("needs");
    try h.expectNotContains(body, "bs\\\n");
    try h.expectNotContains(body, "bs\\ ");
}

test "the scripts enabled with a script come from its unit, not from the header line of the generated script" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try addSvc(t, "c", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "c" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const text = try t.read(init_d ++ "/a");
    try h.expectContains(text, "\n# Pulls-In: b\n");
    try t.write(init_d ++ "/a", try std.mem.replaceOwned(u8, t.a(), text, "\n# Pulls-In: b\n", "\n# Pulls-In: c\n"), 0o755);
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try f.expectCall(0, &.{ "env", env_skip_systemd, "update-rc.d", "b", "defaults" });
    try f.expectCall(1, &.{ "env", env_skip_systemd, "update-rc.d", "a", "defaults" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "a line break in a literal setting is refused and reaches no generated file" {
    inline for (.{ .debian, .redhat }) |variant| {
        var f: Fixture = .{};
        try f.init(variant);
        defer f.deinit();
        try h.expectControlRefused(&f.t);
    }
}

test "a script that cannot be read in full is an error, not a native script whose pid file is signalled" {
    var f: Fixture = .{};
    try f.init(.debian);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const file = try t.fs.root.openFile(testing.io, "etc/init.d/foo", .{ .mode = .read_write });
    defer file.close(testing.io);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, (64 << 20) + 1)));
    try dinit_world.liveProcess(t, 4242);
    try t.write("/run/foo.pid", "4242\n", 0o644);
    try testing.expect(t.run(&.{ "kill", "foo" }) != 0);
    try testing.expect(!f.sc.called(&.{"kill"}));
}
