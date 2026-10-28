// SPDX-License-Identifier: GPL-3.0-or-later
//! The OpenRC backend behind the real `ops` entry point, with a runner that answers like
//! `rc-service`, `rc-update` and `kill`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("openrc_world.zig");
const dinit_world = @import("dinit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const init_d = "/etc/init.d";
const runlevel = "/etc/runlevels/default";
const state = "/run/openrc";

const Fixture = struct {
    t: h.Harness = undefined,
    o: world.openrc = undefined,
    sc: world.Script = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "openrc";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.o);
        f.t.backend_override = f.o.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    /// Switches to the user scope with OpenRC user sessions installed.
    fn userScope(f: *Fixture) !void {
        const a = f.t.a();
        try f.t.environ.put("HOME", "/home/tester");
        try f.t.environ.put("XDG_RUNTIME_DIR", "/run/user/1000");
        f.t.ctx = try .init(a, testing.io, &f.t.fs, &f.t.diag, &f.t.environ, .user, 1000);
        try f.t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
        try f.t.write("/etc/init.d/user", "#!/sbin/openrc-run\n", 0o755);
        f.bind();
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

    fn link(f: *Fixture, name: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const target = try f.t.fs.readLink(try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ runlevel, name }), &buf);
        return f.t.a().dupe(u8, target);
    }

    /// Writes the dependency cache after the scripts so that OpenRC counts it as current.
    fn freshCache(f: *Fixture) !void {
        try testing.io.sleep(.fromMilliseconds(30), .awake);
        try f.t.write(state ++ "/deptree", "", 0o644);
    }

    fn status(f: *Fixture, service: []const u8, code: u8) void {
        const a = f.t.a();
        const prefix = a.dupe([]const u8, &.{ "rc-service", service, "status" }) catch @panic("out of memory");
        const rule: world.Rule = .{ .prefix = prefix, .code = code };
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

test "enable generates the script, links it with rc-update and starts nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(init_d ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 openrc/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/sbin/openrc-run\n", parsed.shebang);
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(init_d ++ "/foo")).mode);
    try h.expectContains(t.stderr(), "Created symlink '/etc/runlevels/default/foo' -> '/etc/init.d/foo'.");
    try f.expectCall(0, &.{ "rc-update", "add", "foo", "default" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    // rc-update would have written the link; the backend only asks for it online.
    try testing.expectError(error.FileNotFound, t.fs.lstat(runlevel ++ "/foo"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "the index records the script and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/openrc/index"), init_d ++ "/foo");

    try t.fs.deleteFile("/var/lib/fake-systemd/openrc/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expect(t.exists(init_d ++ "/syslog"));
}

test "offline enable writes the link of rc-update and calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings(init_d ++ "/foo", try f.link("foo"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/runlevels/default/foo'.");
    try testing.expectError(error.FileNotFound, t.fs.lstat(runlevel ++ "/foo"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
}

test "enable --now refreshes the dependency cache, then starts through rc-service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try f.expectCall(1, &.{ "rc-update", "-u" });
    try f.expectCall(2, &.{ "rc-service", "foo", "status" });
    try f.expectCall(3, &.{ "rc-service", "foo", "start" });
    try f.expectCall(3, &.{ "rc-service", "foo", "start" });
    try testing.expectEqual(@as(usize, 4), f.sc.calls.items.len);
}

test "the dependency cache is left alone when it is newer than the scripts" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.freshCache();
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "rc-service", "foo", "status" });
    try f.expectCall(1, &.{ "rc-service", "foo", "start" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(2, &.{ "rc-service", "foo", "restart" });
    try testing.expectEqual(@as(usize, 3), f.sc.calls.items.len);
}

test "disable removes the link with rc-update and keeps the script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.makePath(runlevel);
    try t.fs.symLink(init_d ++ "/foo", runlevel ++ "/foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ "rc-update", "del", "foo", "default" });
    try h.expectContains(t.stderr(), "Removed '/etc/runlevels/default/foo'.");
    try testing.expect(t.exists(init_d ++ "/foo"));
}

test "a failing rc-update fails the enable" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.sc.rules = &.{.{ .prefix = &.{"rc-update"}, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), f.t.run(&.{ "enable", "foo" }));
}

test "enable --runtime warns and enables persistently" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--runtime", "foo" }));
    try h.expectContains(t.stderr(), "--runtime is not supported");
    try f.expectCall(0, &.{ "rc-update", "add", "foo", "default" });
}

test "a template instance is a script named name.instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists(init_d ++ "/tpl.one"));
    try f.expectCall(0, &.{ "rc-update", "add", "tpl.one", "default" });
    const parsed = marker.parse(try t.read(init_d ++ "/tpl.one")).?;
    try testing.expectEqualStrings("tpl@one.service", parsed.marker.unit);
}

test "a native service with the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(init_d ++ "/foo-daemon", "#!/sbin/openrc-run\ncommand=/usr/bin/foo\ncommand_args=\"--run\"\ncommand_user=svc\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try f.expectCall(0, &.{ "rc-update", "add", "foo-daemon", "default" });
    try f.expectCalled(&.{ "rc-service", "foo-daemon", "start" });
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
}

test "a native service that starts its daemon in a custom start function is found by its program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(init_d ++ "/foo-custom", "#!/sbin/openrc-run\nstart() {\n\tstart-stop-daemon --start --exec /usr/bin/foo --pidfile /run/foo.pid -- --run\n}\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try f.expectCall(0, &.{ "rc-update", "add", "foo-custom", "default" });
}

test "dry-run prints the OpenRC commands it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would create symlink '/etc/runlevels/default/foo' -> '/etc/init.d/foo'\n");
    try h.expectContains(t.stdout(), "would run: rc-service foo start\n");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "stop", "foo" }));
    try h.expectContains(t.stdout(), "would run: rc-service foo stop\n");
}

test "reverting a service removes its link and generated script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.makePath(runlevel);
    try t.fs.symLink(init_d ++ "/foo", runlevel ++ "/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try f.expectCalled(&.{ "rc-update", "del", "foo", "default" });
    try testing.expect(!t.exists(init_d ++ "/foo"));
}

// ---- runtime control ----------------------------------------------------------------------------

test "start asks rc-service, zaps a service whose executor ended before it starts it, and stop stops it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.freshCache();
    f.sc.calls.clearRetainingCapacity();
    f.status("foo", 3);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(1, &.{ "rc-service", "foo", "start" });

    f.sc.calls.clearRetainingCapacity();
    f.sc.rules = &.{};
    f.status("foo", 32);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(1, &.{ "rc-service", "foo", "zap" });
    try f.expectCall(2, &.{ "rc-service", "foo", "start" });

    f.sc.calls.clearRetainingCapacity();
    f.sc.rules = &.{};
    f.status("foo", 64);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(1, &.{ "rc-service", "foo", "zap" });
    try f.expectCall(2, &.{ "rc-service", "foo", "start" });

    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "rc-service", "foo", "stop" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "a failing rc-service fails start, stop, restart and reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "start" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "stop" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "restart" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "restart", "foo" }));
}

test "a service a supervisor gave up on is reset with zap, since stop leaves its failed marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.makePath(state ++ "/failed");
    try t.fs.symLink(init_d ++ "/foo", state ++ "/failed/foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "rc-service", "foo", "zap" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "status codes of rc-service are normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { u8, []const u8, u8 }{
        .{ 0, "active\n", 0 },
        .{ 3, "inactive\n", 3 },
        .{ 4, "deactivating\n", 3 },
        .{ 8, "activating\n", 3 },
        .{ 16, "inactive\n", 3 },
        .{ 32, "failed\n", 3 },
        .{ 64, "failed\n", 3 },
        .{ 1, "inactive\n", 3 },
    };
    for (cases) |c| {
        f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = c[0] }};
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = 32 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = 0 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-failed", "foo" }));

    try t.fs.makePath(state ++ "/failed");
    try t.fs.symLink(init_d ++ "/foo", state ++ "/failed/foo");
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = 3 }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
}

test "the main pid is read from the supervisor or from the pid file of start-stop-daemon" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try dinit_world.liveProcess(t, 777);
    try t.write(state ++ "/options/foo/child_pid", "4242", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4242");
    try t.fs.deleteFile(state ++ "/options/foo/child_pid");
    try t.write("/run/foo.pid", "777\n", 0o644);
    try t.write(state ++ "/options/foo/pidfile", "/run/foo.pid", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 777");
    try t.fs.deleteFile(state ++ "/options/foo/pidfile");
    try t.write(state ++ "/daemons/foo/001", "exec=/usr/bin/foo\npidfile=/run/foo.pid\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 777");
}

test "restart reload and kill map to rc-service and kill" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(0, &.{ "rc-service", "foo", "reload" });
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    try t.write(state ++ "/options/foo/child_pid", "4242", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGHUP", "foo" }));
    try testing.expect(f.sc.called(&.{ "kill", "-s", "HUP", "4242" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "USR1", "foo" }));
    try testing.expect(f.sc.called(&.{ "kill", "-s", "USR1", "4242" }));
}

test "a oneshot that finished stays started in OpenRC, reads inactive, and starts again through restart" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    try f.freshCache();
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "job", "status" }, .code = 0 }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "job" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "job" }));
    try f.expectCall(1, &.{ "rc-service", "job", "restart" });
}

test "a oneshot with RemainAfterExit stays active and its start is not repeated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/job\nExecStop=/usr/bin/job-undo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    try f.freshCache();
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "job", "status" }, .code = 0 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "job" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "job" }));
    try f.expectCall(1, &.{ "rc-service", "job", "start" });
    const body = try f.script("job");
    try h.expectContains(body, "\nstop() {\n\tebegin \"Stopping ${RC_SVCNAME}\"\n\t/usr/bin/fake-systemd --exec job.service --phase stop\n");
}

test "daemon-reload rebuilds the dependency cache through rc-update -u" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCall(0, &.{ "rc-update", "-u" });
    f.sc.rules = &.{.{ .prefix = &.{"rc-update"}, .code = 1 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "rc-update -u failed");
}

test "power verbs use openrc-shutdown under openrc-init and the init commands elsewhere" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{"reboot"});
    try f.expectCall(1, &.{"poweroff"});
    try f.expectCall(2, &.{"halt"});

    try t.write("/usr/sbin/openrc-shutdown", "#!/bin/sh\n", 0o755);
    try t.fs.makePath("/proc/1");
    try t.fs.symLink("/usr/sbin/openrc-init", "/proc/1/exe");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(3, &.{ "openrc-shutdown", "-r", "now" });
    try f.expectCall(4, &.{ "openrc-shutdown", "-p", "now" });
    try f.expectCall(5, &.{ "openrc-shutdown", "-H", "now" });
}

// ---- dependencies --------------------------------------------------------------------------------

test "hard dependencies are needs, weak ones wants, ordering after and before, and the services need no links" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service\nBindsTo=c.service\nWants=d.service\nAfter=b.service e.service\nBefore=f.service", "");
    for ([_][]const u8{ "b", "c", "d", "e", "f" }) |n| try addSvc(t, n, "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectContains(body, "\ndepend() {\n\tneed b c\n\twant d\n\tafter e\n\tbefore f\n}\n");
    for ([_][]const u8{ "b", "c", "d" }) |dep| {
        try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "{s}/{s}", .{ init_d, dep })));
        try testing.expectError(error.FileNotFound, t.fs.lstat(try std.fmt.allocPrint(t.a(), "{s}/{s}", .{ runlevel, dep })));
    }
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "b" }));
}

test "a native service that matches a dependency is referenced by its native name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try t.write(init_d ++ "/b-native", "#!/sbin/openrc-run\ncommand=/usr/bin/b\ncommand_args=--other\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(!t.exists(init_d ++ "/b"));
    try h.expectContains(try f.script("a"), "\n\tneed b-native\n");
}

test "a dependency the classifier excludes is left out of the script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service", "");
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/hook\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectNotContains(body, "hook");
    try h.expectNotContains(body, "gone");
    try h.expectNotContains(body, "depend()");
}

test "dependencies are collected once no unit that was named explicitly reaches them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(t.exists(init_d ++ "/b"));
    try t.fs.deleteFile("/usr/lib/systemd/system/a.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(init_d ++ "/a"));
    try testing.expect(!t.exists(init_d ++ "/b"));
}

test "network targets become soft dependencies on the virtual net and network-online services" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "plain", "After=network.target", "");
    try addSvc(t, "online", "After=network-online.target\nWants=network-online.target", "");
    try addSvc(t, "hard", "Requires=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain", "online", "hard" }));
    try h.expectContains(try f.script("plain"), "\ndepend() {\n\tuse net\n}\n");
    try h.expectContains(try f.script("online"), "\ndepend() {\n\tuse net network-online\n}\n");
    try h.expectContains(try f.script("hard"), "\ndepend() {\n\tuse net network-online\n}\n");
}

// ---- how the script runs the unit ----------------------------------------------------------------

test "a plain unit without Restart= runs its executor under start-stop-daemon, which logs and records the exit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const body = try f.script("foo");
    try h.expectContains(body, "\ncommand=/usr/bin/fake-systemd\ncommand_args=\"--exec foo.service --log --record-exit\"\ncommand_background=yes\npidfile=/run/foo.fake-systemd.pid\n");
    try h.expectContains(body, "\nretry=TERM/100/KILL/5\n");
    try h.expectNotContains(body, "output_logger");
    try h.expectNotContains(body, "supervisor=");
}

test "Restart= puts the unit under supervise-daemon with respawn settings from RestartSec" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "quick", "", "Restart=always");
    try addSvc(t, "slow", "", "Restart=on-failure\nRestartSec=5");
    try addSvc(t, "watch", "", "Restart=on-watchdog");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "quick", "slow", "watch" }));
    const quick = try f.script("quick");
    try h.expectContains(quick, "\nsupervisor=supervise-daemon\n");
    try h.expectContains(quick, "\nrespawn_delay=1\nrespawn_max=5\nrespawn_period=10\n");
    try h.expectNotContains(quick, "command_background");
    try h.expectNotContains(quick, "pidfile");
    const slow = try f.script("slow");
    try h.expectContains(slow, "\nrespawn_delay=5\nrespawn_max=0\n");
    try h.expectContains(slow, "# Restart=on-failure is approximated by respawning on every exit\n");
    try h.expectNotContains(quick, "approximated");
    const watch = try f.script("watch");
    try h.expectNotContains(watch, "supervisor=");
}

test "TimeoutStopSec and KillSignal become the retry schedule" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "sched", "", "TimeoutStopSec=1.5\nKillSignal=SIGUSR1\nRestart=always");
    try addSvc(t, "forever", "", "TimeoutStopSec=infinity\nRestart=always");
    try addSvc(t, "nokill", "", "TimeoutStopSec=7\nKillMode=none\nRestart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "sched", "forever", "nokill" }));
    try h.expectContains(try f.script("sched"), "\nretry=USR1/2/KILL/5\n");
    try h.expectContains(try f.script("forever"), "\nretry=TERM/2147483647\n");
    try h.expectContains(try f.script("nokill"), "\nretry=TERM/7\n");
    try addSvc(t, "bgsched", "", "TimeoutStopSec=1.5\nKillSignal=SIGUSR1");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "bgsched" }));
    // The executor takes SIGTERM and sends KillSignal= itself, with a grace period on top.
    try h.expectContains(try f.script("bgsched"), "\nretry=TERM/12/KILL/5\n");
}

test "environment, working directory, umask, limits, nice and no-new-privileges are native" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "nat", "", "Environment=A=1 \"B=two words\"\nWorkingDirectory=/srv/nat\nUMask=0027\nLimitNOFILE=4096\nLimitNPROC=100:infinity\nNice=-5\nNoNewPrivileges=yes\nRestart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "nat" }));
    const body = try f.script("nat");
    try h.expectContains(body, "\nexport A=1\nexport B='two words'\nrc_ulimit=\"-n 4096 -Su 100 -Hu unlimited\"\n");
    try h.expectContains(body, "\ndirectory=/srv/nat\numask=0027\nno_new_privs=yes\nstart_stop_daemon_args=\"--nicelevel -5\"\n");
    try h.expectNotContains(body, "--exec nat.service");
}

test "settings the script cannot carry send the unit through the executor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hook", "", "ExecStop=/usr/bin/hook-stop");
    try addSvc(t, "reserved", "", "Environment=command=oops");
    try addSvc(t, "spaced", "", "WorkingDirectory=\"/srv/with space\"");
    try addSvc(t, "megs", "", "LimitMEMLOCK=64M");
    try addSvc(t, "groups", "", "User=app\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hook", "reserved", "spaced", "megs", "groups" }));
    for ([_][]const u8{ "hook", "reserved", "spaced", "megs", "groups" }) |n| {
        const body = try f.script(n);
        try h.expectContains(body, try std.fmt.allocPrint(t.a(), "command=/usr/bin/fake-systemd\ncommand_args=\"--exec {s}.service", .{n}));
    }
    try h.expectContains(try f.script("hook"), "--exec hook.service --stop-on-signal --log --record-exit\"\n");
    try h.expectNotContains(try f.script("reserved"), "export command");
}

test "ExecStopPost and runtime directories run through stop_post, ExecReload through reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hooked", "", "ExecReload=/usr/bin/hooked-ctl reload\nExecStopPost=/usr/bin/hooked-cleanup");
    try addSvc(t, "dirs", "", "RuntimeDirectory=dirs");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooked", "dirs" }));
    const hooked = try f.script("hooked");
    try h.expectContains(hooked, "\nextra_started_commands=\"reload\"\n");
    try h.expectContains(hooked, "\nstop_post() {\n\t/usr/bin/fake-systemd --exec hooked.service --phase stop-post\n}\n");
    try h.expectContains(hooked, "\nreload() {\n\tebegin \"Reloading ${RC_SVCNAME}\"\n\t/usr/bin/fake-systemd --exec hooked.service --phase reload\n\teend $?\n}\n");
    try h.expectContains(try f.script("dirs"), "\nstop_post() {\n");
}

test "a native supervised command that is reloaded hands the pid of its child to the executor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "sup", "", "Restart=always\nExecReload=/bin/kill -HUP $MAINPID");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "sup" }));
    try h.expectContains(try f.script("sup"), "\n\tMAINPID=$(service_get_value child_pid) /usr/bin/fake-systemd --exec sup.service --phase reload\n");
}

test "forking daemons: a pid file goes through the executor, which follows it, and a daemon without one is native" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "fork", "", "Type=forking\nPIDFile=/run/fork.pid");
    try addSvc(t, "forksup", "", "Type=forking\nPIDFile=/run/forksup.pid\nRestart=on-failure");
    try addSvc(t, "forknopid", "", "Type=forking\nRestart=always");
    try addSvc(t, "forkplain", "", "Type=forking");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "fork", "forksup", "forknopid", "forkplain" }));
    const background = try f.script("fork");
    try h.expectContains(background, "\ncommand=/usr/bin/fake-systemd\ncommand_args=\"--exec fork.service --log --record-exit\"\ncommand_background=yes\npidfile=/run/fork.fake-systemd.pid\n");
    const sup = try f.script("forksup");
    try h.expectContains(sup, "supervisor=supervise-daemon\ncommand=/usr/bin/fake-systemd\n");
    try h.expectNotContains(sup, "--record-exit");
    const nopid = try f.script("forknopid");
    try h.expectContains(nopid, "# Type=forking without PIDFile=: the daemon is started but not supervised\n");
    try h.expectContains(nopid, "\ncommand=/usr/bin/forknopid\n");
    try h.expectNotContains(nopid, "supervisor=");
    try h.expectNotContains(nopid, "output_logger");
    const plain = try f.script("forkplain");
    try h.expectContains(plain, "\ncommand=/usr/bin/forkplain\ncommand_args=\"--run\"\nretry=");
    try h.expectNotContains(plain, "command_background");
}

test "logger pipes need OpenRC 0.51, older ones append to the uniform log" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "old", "", "Restart=always");
    f.o.version_override = .{ .major = 0, .minor = 45 };
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "old" }));
    const body = try f.script("old");
    try h.expectContains(body, "\noutput_log=/var/log/fake-systemd/old.service/current\nerror_log=/var/log/fake-systemd/old.service/current\n");
    try h.expectContains(body, "\nstart_pre() {\n\tmkdir -p /var/log/fake-systemd/old.service\n}\n");
    try h.expectNotContains(body, "output_logger");
}

test "an account only the system libc resolves is switched by command_user, whose logger gets a log directory it owns" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=svc-directory\nGroup=dir-group\nRestart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    const body = try f.script("ldap");
    try h.expectContains(body, "\ncommand_user=svc-directory:dir-group\n");
    try h.expectContains(body, "\nstart_pre() {\n\tmkdir -p /var/log/fake-systemd/ldap.service &&\n\t\tcheckpath -q -d -m 0755 -o svc-directory:dir-group /var/log/fake-systemd/ldap.service\n}\n");
}

test "an account the executor cannot resolve is given to it as numeric ids, with the supplementary groups looked up too" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldapg", "", "User=svc-directory\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldapg" }));
    const body = try f.script("ldapg");
    try h.expectContains(body, "\ncommand=/usr/bin/fake-systemd\ncommand_args=\"--exec ldapg.service --log --record-exit --uid \\\"\\$(id -u -- svc-directory)\\\" --gid \\\"\\$(id -g -- svc-directory)\\\" --groups \\\"\\$(id -G -- svc-directory | tr ' ' ,),\\$(getent group audio | cut -d: -f3)\\\"\"\n");
    try h.expectNotContains(body, "command_user");
    try h.expectNotContains(body, "setpriv");
    try h.expectNotContains(body, "--identity-set");
    // Root keeps the files of the executor: nothing is handed to the account.
    try h.expectNotContains(body, "checkpath");
    try h.expectNotContains(body, "start_pre() {\n\tmkdir");
}

test "an account the executor resolves needs no switch in the script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "known", "", "User=app\nGroup=app\nSupplementaryGroups=audio\nExecStartPre=/usr/bin/prep");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "known" }));
    const body = try f.script("known");
    try h.expectNotContains(body, "command_user");
    try h.expectNotContains(body, "setpriv");
    try h.expectContains(body, "command_args=\"--exec known.service --log --record-exit\"");
}

test "an executor call from a function carries the numeric ids of an account only libc resolves" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hookd", "", "User=svc-directory\nExecReload=/usr/bin/reload-hookd");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hookd" }));
    try h.expectContains(try f.script("hookd"), "\t/usr/bin/fake-systemd --exec hookd.service --phase reload --uid \"$(id -u -- svc-directory)\" --gid \"$(id -g -- svc-directory)\" --groups \"$(id -G -- svc-directory | tr ' ' ,)\"\n");
}

test "a oneshot is a start function that runs the executor and logs through the uniform logger" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    const body = try f.script("job");
    try h.expectContains(body, "# flags: transient\n");
    try h.expectContains(body, "\nstart() {\n\tebegin \"Starting ${RC_SVCNAME}\"\n\texec 4>&1\n\t_rc=$( { { /usr/bin/fake-systemd --exec job.service 2>&1; echo $? >&3; } | /usr/bin/fake-systemd --log job.service >&4; } 3>&1 )\n");
    try h.expectContains(body, "\trm -f /run/fake-systemd/job.service.pid\n\teend \"${_rc:-1}\" \"Failed to start ${RC_SVCNAME}\"\n}\n");
    try h.expectNotContains(body, "command=");
    try h.expectNotContains(body, "\nstop()");
}

test "a unit without ExecStart gets a start function that does nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/empty.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStop=/usr/bin/cleanup\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "empty" }));
    try h.expectContains(try f.script("empty"), "\nstart() {\n\t:\n}\n");
}

// ---- timers --------------------------------------------------------------------------------------

test "the timer runner is generated, enabled and started like any service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "fake-systemd-timers", "status" }, .code = 3 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    try h.expectContains(try f.script("fake-systemd-timers"), "\ncommand=/usr/bin/fake-systemd\ncommand_args=\"--timers\"\n");
    try f.expectCalled(&.{ "rc-update", "add", "fake-systemd-timers", "default" });
    try f.expectCalled(&.{ "rc-service", "fake-systemd-timers", "start" });

    try t.fs.makePath(runlevel);
    try t.fs.symLink(init_d ++ "/fake-systemd-timers", runlevel ++ "/fake-systemd-timers");
    try t.write(state ++ "/options/fake-systemd-timers/child_pid", "7", 0o644);
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "fake-systemd-timers", "status" }, .code = 0 }};
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "7" });

    f.sc.rules = &.{};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists(init_d ++ "/fake-systemd-timers"));
    try f.expectCalled(&.{ "rc-update", "del", "fake-systemd-timers", "default" });
}

// ---- user services -------------------------------------------------------------------------------

test "user services are a capability where the user service of OpenRC is installed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try testing.expect(!f.t.backend_override.?.caps().user_services);
    try f.t.write("/etc/init.d/user", "#!/sbin/openrc-run\n", 0o755);
    f.bind();
    try testing.expect(f.t.backend_override.?.caps().user_services);
    try testing.expect(f.t.backend_override.?.caps().supervision and f.t.backend_override.?.caps().soft_deps and f.t.backend_override.?.caps().ordering);
    try testing.expect(!f.t.backend_override.?.caps().oneshot and !f.t.backend_override.?.caps().per_service_logger);
}

test "user scope generates into the user's init directory and uses the user flag of the tools" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "--now", "foo" }));
    try testing.expect(t.exists("/home/tester/.config/rc/init.d/foo"));
    try f.expectCall(0, &.{ "rc-update", "--user", "add", "foo", "default" });
    try f.expectCalled(&.{ "rc-service", "--user", "foo", "start" });
    const body = marker.parse(try t.read("/home/tester/.config/rc/init.d/foo")).?.rest;
    try h.expectContains(body, "\ncommand_args=\"--exec foo.service --user --log --record-exit\"\ncommand_background=yes\npidfile=/run/user/1000/foo.fake-systemd.pid\n");
    try h.expectNotContains(body, "command_user");

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "daemon-reload" }));
    try f.expectCalled(&.{ "rc-update", "--user", "-u" });
}

test "user scope reads the state of the user's OpenRC" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "foo" }));
    try t.write("/run/user/1000/openrc/options/foo/child_pid", "99", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 99");
    try t.fs.makePath("/run/user/1000/openrc/failed");
    try t.fs.symLink("/x", "/run/user/1000/openrc/failed/foo");
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "--user", "foo", "status" }, .code = 3 }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "--user", "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
}

test "a process that is gone reads inactive when its executor recorded a clean end, and failed otherwise" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = 32 }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try t.write("/run/fake-systemd/foo.service.exit", "ok 0\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-failed", "foo" }));
    try t.write("/run/fake-systemd/foo.service.exit", "failed 3\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    // A clean end is a service that start brings up again.
    try t.write("/run/fake-systemd/foo.service.exit", "ok 0\n", 0o644);
    try f.freshCache();
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(1, &.{ "rc-service", "foo", "zap" });
    try f.expectCall(2, &.{ "rc-service", "foo", "start" });
}

test "the main pid of an executor service is the one the executor recorded" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try dinit_world.liveProcess(t, 4300);
    try t.write(state ++ "/options/foo/child_pid", "4242", 0o644);
    try t.write("/run/fake-systemd/foo.service.pid", "4300 4300\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4300");
}

test "a native command of an account only libc resolves takes command_user and owns the log directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldapnat", "", "Restart=always\nUser=svc-directory");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldapnat" }));
    const body = try f.script("ldapnat");
    try h.expectContains(body, "\ncommand=/usr/bin/ldapnat\n");
    try h.expectContains(body, "\ncommand_user=svc-directory\n");
    try h.expectContains(body, "\nstart_pre() {\n\tmkdir -p /var/log/fake-systemd/ldapnat.service &&\n\t\tcheckpath -q -d -m 0755 -o svc-directory /var/log/fake-systemd/ldapnat.service\n}\n");
}

test "a service OpenRC still records as started is crashed when its executor is gone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ "rc-service", "foo", "status" }, .code = 0 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    // The pid file of start-stop-daemon names a process that does not exist.
    try t.write("/run/foo.fake-systemd.pid", "999999999\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "rc-service", "foo", "zap" });
    try t.write("/proc/1000/stat", "", 0o644);
    try t.write("/run/foo.fake-systemd.pid", "1000\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
}

test "a unit with an account gets its Environment= from the executor, not from exports root runs" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "envsvc", "", "Restart=always\nUser=svc-directory\nEnvironment=PATH=/var/lib/svc/bin:/usr/bin\nEnvironment=LD_PRELOAD=/var/lib/svc/x.so");
    try addSvc(t, "envapp", "", "Restart=always\nUser=app\nEnvironment=PATH=/var/lib/svc/bin:/usr/bin");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "envsvc", "envapp" }));
    for ([_][]const u8{ "envsvc", "envapp" }) |name| {
        const body = try f.script(name);
        try h.expectNotContains(body, "export");
        try h.expectNotContains(body, "var/lib/svc");
        try h.expectContains(body, "--exec ");
    }
    // Without an account the script still exports them.
    try addSvc(t, "envroot", "", "Restart=always\nEnvironment=A=1");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "envroot" }));
    try h.expectContains(try f.script("envroot"), "\nexport A=1\n");
}

test "two units that map to the same script name are not both generated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "foo.bar", "", "");
    try addSvc(t, "foo@", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo.bar" }));
    try testing.expect(t.run(&.{ "enable", "foo@bar" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
    try h.expectContains(try t.read(init_d ++ "/foo.bar"), "# Unit: foo.bar.service\n");
}

test "a pid from a file the service can write is only signalled when it names a live process of that owner" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    // init is never signalled, whatever a pid file says.
    try dinit_world.liveProcess(t, 1);
    try t.write(state ++ "/options/foo/pidfile", "/run/foo.pid", 0o644);
    try t.write("/run/foo.pid", "1\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    try testing.expect(!f.sc.called(&.{"kill"}));
    // A pid without a process is not signalled either.
    try t.write("/run/foo.pid", "31337\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    try testing.expect(!f.sc.called(&.{"kill"}));
    try dinit_world.liveProcess(t, 31337);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGKILL", "foo" }));
    try testing.expect(f.sc.called(&.{ "kill", "-s", "KILL", "31337" }));
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}

test "a script that cannot be read in full is an error, not a native script whose pid file is signalled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const file = try t.fs.root.openFile(testing.io, "etc/init.d/foo", .{ .mode = .read_write });
    defer file.close(testing.io);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, (1 << 20) + 1)));
    try dinit_world.liveProcess(t, 777);
    try t.write("/run/foo.pid", "777\n", 0o644);
    try t.write(state ++ "/options/foo/pidfile", "/run/foo.pid", 0o644);
    f.sc.calls.clearRetainingCapacity();
    try testing.expect(t.run(&.{ "kill", "foo" }) != 0);
    try testing.expect(!f.sc.called(&.{"kill"}));
}
