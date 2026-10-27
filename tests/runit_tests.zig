// SPDX-License-Identifier: GPL-3.0-or-later
//! The runit backend behind the real `ops` entry point, with a recording runner standing in
//! for `sv`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("runit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const running_text = "run: foo: (pid 4242) 5s\n";
const enable_dir = "/etc/runit/runsvdir/default";

const Fixture = struct {
    t: h.Harness = undefined,
    r: world.runit = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.bind();
        f.t.detected = "runit";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.r);
        f.t.backend_override = f.r.backend();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    /// Switches to the user scope with turnstile's runit backend installed.
    fn userScope(f: *Fixture, conf: ?[]const u8) !void {
        const a = f.t.a();
        try f.t.environ.put("HOME", "/home/tester");
        f.t.ctx = try .init(a, testing.io, &f.t.fs, &f.t.diag, &f.t.environ, .user, 1000);
        try f.t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
        try f.t.write("/usr/libexec/turnstile/runit", "#!/bin/sh\n", 0o755);
        try f.t.write("/etc/turnstile/turnstiled.conf", "# comment\nbackend = runit\n", 0o644);
        if (conf) |text| try f.t.write("/etc/turnstile/backend/runit.conf", text, 0o644);
        f.bind();
    }

    fn link(f: *Fixture, name: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const target = try f.t.fs.readLink(try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ enable_dir, name }), &buf);
        return f.t.a().dupe(u8, target);
    }
};

test "enable generates the service directory, links it and never calls sv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read("/etc/sv/foo/run")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 runit/2", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expect(t.exists("/etc/sv/foo/finish"));
    try testing.expect(t.exists("/etc/sv/foo/log/run"));
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat("/etc/sv/foo/run")).mode);
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
    try h.expectContains(t.stderr(), "Created symlink '/etc/runit/runsvdir/default/foo' -> '/etc/sv/foo'.");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.exists("/etc/sv/foo/down"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "the index records every generated file and a lost index is rebuilt from the markers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const index_text = try t.read("/var/lib/fake-systemd/runit/index");
    for ([_][]const u8{ "/etc/sv/foo/run", "/etc/sv/foo/finish", "/etc/sv/foo/log/run" }) |p| try h.expectContains(index_text, p);

    try t.fs.deleteFile("/var/lib/fake-systemd/runit/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists("/etc/sv/foo/run"));
    try testing.expect(!t.exists("/etc/sv/foo/finish"));
    try testing.expect(!t.exists("/etc/sv/foo/log/run"));
}

test "offline enable writes the same link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
}

test "enable --now starts through sv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "start", "foo" }));
    try testing.expectEqual(@as(usize, 1), t.rec.calls.items.len);
}

test "is-enabled follows the link and the down file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try t.write("/etc/sv/foo/down", "", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
}

test "disable of a stopped service removes the link and keeps the service directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/runit/runsvdir/default/foo'.");
    try testing.expect(t.exists("/etc/sv/foo/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "disable of a running service writes down and keeps the link, enable removes it again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Created '/etc/sv/foo/down'.");
    try testing.expect(t.exists("/etc/sv/foo/down"));
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/sv/foo/down'.");
    try testing.expect(!t.exists("/etc/sv/foo/down"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
}

test "start of a service that is not linked links it with down, waits for runsv and starts it, and stop keeps the link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "sv", "start", "foo" }));
    try testing.expectEqual(@as(usize, 2), t.rec.calls.items.len);
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
    try testing.expect(t.exists("/etc/sv/foo/down"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "sv", "-w", "90", "force-stop", "foo" }));
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
    try testing.expect(t.exists("/etc/sv/foo/down"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expect(t.exists("/etc/sv/foo/run"));
}

test "stop leaves the link of an enabled service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqualStrings("/etc/sv/foo", try f.link("foo"));
}

test "a start that sv does not see through is a failure unless finish recorded the end" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.code = 1;
    t.rec.stdout = "timeout: down: foo: 7s, normally up, want up\n";
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "--now", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    try h.expectContains(t.stderr(), "sv: timeout: down: foo: 7s");

    const Quick = struct {
        t: *h.Harness,

        fn runner(q: *@This()) h.backend.Runner {
            return .{ .ptr = q, .run_fn = runFn };
        }

        fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
            const q: *@This() = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, argv[1], "start")) {
                try q.t.write("/etc/sv/foo/supervise/exit-status", "failed 3 0\n", 0o644);
                return .{ .code = 1, .stdout = "timeout: down: foo: 7s, normally up, want up\n" };
            }
            return .{ .code = 0, .stdout = "down: foo: 1s, normally up\n" };
        }
    };
    var quick: Quick = .{ .t = t };
    t.runner_override = quick.runner();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
}

test "status output is normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "foo" }));

    t.rec.stdout = "down: foo: 3s, normally up\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());

    t.rec.stdout = "down: foo: 0s, normally up, want up\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("activating\n", t.stdout());

    t.rec.stdout = "run: foo: (pid 4242) 3s, want down, got TERM\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("deactivating\n", t.stdout());

    t.rec.stdout = "down: foo: 3s, normally up\n";
    try t.write("/etc/sv/foo/supervise/exit-status", "failed 1 0\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    try t.write("/etc/sv/foo/supervise/exit-status", "ok -1 15\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());

    t.rec.stdout = "fail: foo: unable to change to service directory: file does not exist\n";
    t.rec.code = 1;
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "the main pid is read from the status text" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "MainPID", "-p", "ActiveState", "foo" }));
    try h.expectContains(t.stdout(), "MainPID=4242\n");
    try h.expectContains(t.stdout(), "ActiveState=active\n");
}

test "restart and kill map to sv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "-w", "90", "force-stop", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "sv", "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "sv", "term", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "--signal=SIGHUP", "foo" }));
    try testing.expect(t.rec.callIs(3, &.{ "sv", "hup", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "USR2", "foo" }));
    try testing.expect(t.rec.callIs(4, &.{ "sv", "2", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "KILL", "foo" }));
    try testing.expect(t.rec.callIs(5, &.{ "sv", "kill", "foo" }));
}

test "a signal sv has no command for goes through kill with the pid from the status" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGWINCH", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "kill", "-s", "WINCH", "4242" }));
}

test "reload runs ExecReload through the executor, and sv reload serves native services" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" }));
    const env: h.backend.interface.Env = .{ .ctx = &t.ctx, .runner = t.rec.runner(), .online = true };
    try f.r.backend().reload(env, "syslog");
    try testing.expect(t.rec.callIs(2, &.{ "sv", "reload", "syslog" }));
}

test "reload hands the pid that runsv supervises to the executor as MAINPID" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "env", "MAINPID=4242", "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" }));
}

test "daemon-reload needs nothing from runsvdir and removes links to service directories that are gone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.fs.symLink("/etc/sv/gone", enable_dir ++ "/gone");
    try t.fs.symLink("/opt/elsewhere/x", enable_dir ++ "/foreign");
    try t.fs.symLink("/etc/sv/syslog", enable_dir ++ "/syslog");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/gone"));
    _ = try t.fs.lstat(enable_dir ++ "/foreign");
    _ = try t.fs.lstat(enable_dir ++ "/syslog");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
}

test "power verbs use runit-init" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try testing.expect(t.rec.callIs(0, &.{ "runit-init", "6" }));
    try testing.expect(t.rec.callIs(1, &.{ "runit-init", "0" }));
    try testing.expect(t.rec.callIs(2, &.{ "runit-init", "0" }));
}

test "dry-run prints the sv commands it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would run: sv start foo\n");
    try h.expectContains(t.stdout(), "would create symlink '/etc/runit/runsvdir/default/foo' -> '/etc/sv/foo'\n");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.exists("/etc/sv/foo/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/foo"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "restart", "foo" }));
    try h.expectContains(t.stdout(), "would run: sv -w 90 force-stop foo\nwould run: sv start foo\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "stop", "foo" }));
    try h.expectContains(t.stdout(), "would run: sv -w 90 force-stop foo\n");
}

test "a template instance keeps its @ in the service name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "tpl@one.service" }));
    try testing.expect(t.exists("/etc/sv/tpl@one/run"));
    try testing.expectEqualStrings("/etc/sv/tpl@one", try f.link("tpl@one"));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "start", "tpl@one" }));
    const parsed = marker.parse(try t.read("/etc/sv/tpl@one/run")).?;
    try testing.expectEqualStrings("tpl@one.service", parsed.marker.unit);
}

test "a native runit service with the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/etc/sv/foo-daemon/run", "#!/bin/sh\nexec 2>&1\nexec chpst -e /etc/foo.env /usr/bin/foo --run\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists("/etc/sv/foo/run"));
    try testing.expectEqualStrings("/etc/sv/foo-daemon", try f.link("foo-daemon"));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "start", "foo-daemon" }));
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
}

test "a service directory without a run script is not a native service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.fs.makePath("/etc/sv/foo-daemon/log");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists("/etc/sv/foo/run"));
}

// ---- dependencies ----

fn addSvc(t: *h.Harness, name: []const u8, unit_lines: []const u8) !void {
    const exec = try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name});
    const text = try std.fmt.allocPrint(
        t.a(),
        "[Unit]\n{s}\n[Service]\nExecStart={s} --run\nRestart=always\n[Install]\nWantedBy=multi-user.target\n",
        .{ unit_lines, exec },
    );
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name}), text, 0o644);
    try t.write(exec, "#!/bin/sh\n", 0o755);
}

test "hard and soft dependencies become sv start lines, and the services they start are linked with down" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service\nWants=c.service");
    try addSvc(t, "b", "Wants=d.service");
    try addSvc(t, "c", "");
    try addSvc(t, "d", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const run_a = try t.read("/etc/sv/a/run");
    try h.expectContains(run_a, "\nsv start b || exit 1\nsv start c\nexec /usr/bin/a --run\n");
    try h.expectContains(try t.read("/etc/sv/b/run"), "\nsv start d\n");
    try testing.expectEqualStrings("/etc/sv/a", try f.link("a"));
    for ([_][]const u8{ "b", "c", "d" }) |dep| {
        try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "/etc/sv/{s}/down", .{dep})));
        _ = try f.link(dep);
    }
    try testing.expect(!t.exists("/etc/sv/a/down"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "b" }));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try testing.expectEqual(@as(usize, 1), t.rec.calls.items.len);
    try testing.expect(t.rec.callIs(0, &.{ "sv", "start", "a" }));
}

test "start links the dependencies first and waits for each runsv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service");
    try addSvc(t, "b", "Requires=c.service");
    try addSvc(t, "c", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "status", "b" }));
    try testing.expect(t.rec.callIs(1, &.{ "sv", "status", "c" }));
    try testing.expect(t.rec.callIs(2, &.{ "sv", "status", "a" }));
    try testing.expect(t.rec.callIs(3, &.{ "sv", "start", "a" }));
    for ([_][]const u8{ "a", "b", "c" }) |n| try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "/etc/sv/{s}/down", .{n})));
}

test "a native service that matches a dependency is referenced by its native name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service");
    try addSvc(t, "b", "");
    try t.write("/etc/sv/b-native/run", "#!/bin/sh\nexec /usr/bin/b --other\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(!t.exists("/etc/sv/b/run"));
    try h.expectContains(try t.read("/etc/sv/a/run"), "\nsv start b-native || exit 1\n");
}

test "a dependency the classifier excludes is left out of run" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service");
    try addSvc(t, "hook", "");
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/hook\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const content = try t.read("/etc/sv/a/run");
    try h.expectNotContains(content, "hook");
    try h.expectNotContains(content, "gone");
    try h.expectNotContains(content, "sv start");
}

test "dependencies are collected once no unit that was named explicitly reaches them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service");
    try addSvc(t, "b", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(t.exists("/etc/sv/b/run"));
    try t.fs.deleteFile("/usr/lib/systemd/system/a.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists("/etc/sv/a/run"));
    try testing.expect(!t.exists("/etc/sv/b/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/b"));
}

test "reverting a service removes its link and generated files" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/foo"));
    try testing.expect(!t.exists("/etc/sv/foo/run"));
    try testing.expect(!t.exists("/etc/sv/foo/log/run"));
}

// ---- restart policy, stop hooks and identity in the generated scripts ----

fn generatedFile(t: *h.Harness, path: []const u8) ![]const u8 {
    return marker.parse(try t.read(path)).?.rest;
}

test "ExecStop, ExecStopPost and KillSignal land in control/t and finish" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/hooked", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/hooked.service",
        \\[Service]
        \\ExecStart=/usr/bin/hooked
        \\ExecStop=/usr/bin/hooked-ctl stop
        \\ExecStopPost=/usr/bin/hooked-cleanup
        \\Restart=on-failure
        \\RestartSec=5
        \\SuccessExitStatus=3 SIGUSR1
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooked" }));
    const control = try generatedFile(t, "/etc/sv/hooked/control/t");
    try testing.expectEqualStrings("MAINPID=$(cat supervise/pid) /usr/bin/fake-systemd --exec hooked.service --phase stop-main\nexit 1\n", control);
    const fin = try generatedFile(t, "/etc/sv/hooked/finish");
    try h.expectContains(fin, "-1) case $(($2 & 127)) in 1|2|13|15|10) clean=1 ;; esac ;;\n0|3) clean=1 ;;\n");
    try h.expectContains(fin, "/usr/bin/fake-systemd --exec hooked.service --phase stop-post\n");
    try h.expectContains(fin, "if [ -n \"$clean\" ]; then\n    sv once .\nelse\n    case \"$(cat supervise/stat)\" in *\"want down\"*) ;; *) sleep 5 ;; esac\nfi\n");
}

test "Restart=always without hooks has no finish script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "plain", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain" }));
    try testing.expect(t.exists("/etc/sv/plain/run"));
    try testing.expect(!t.exists("/etc/sv/plain/finish"));
    try testing.expect(!t.exists("/etc/sv/plain/control/t"));
}

test "an account the executor cannot resolve is switched with setpriv in run, with its groups from the system libc" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/nativecmd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/nativecmd.service",
        \\[Service]
        \\ExecStart=/usr/bin/nativecmd --flag "a b" price$$5
        \\User=svc-directory
        \\Group=app
        \\SupplementaryGroups=audio
        \\UMask=0027
        \\WorkingDirectory=/var/lib/app
        \\Nice=5
        \\NoNewPrivileges=yes
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "nativecmd" }));
    const run_text = try generatedFile(t, "/etc/sv/nativecmd/run");
    try testing.expectEqualStrings(
        "exec 2>&1\numask 0027\ncd /var/lib/app || exit 200\n" ++
            "exec chpst -n 5 /usr/bin/setpriv --reuid=svc-directory --regid=app --groups \"$(id -G -- svc-directory | tr ' ' ,),audio\" --no-new-privs /usr/bin/nativecmd --flag 'a b' 'price$5'\n",
        run_text,
    );
}

test "numeric accounts and accounts the executor resolves go through the executor, an LDAP account gives it numeric ids" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/numeric.service", "[Service]\nExecStart=/usr/bin/n\nUser=1000\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/prep.service", "[Service]\nExecStartPre=/usr/bin/p\nExecStart=/usr/bin/n\nUser=app\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/ldap.service", "[Service]\nExecStartPre=/usr/bin/p\nExecStart=/usr/bin/n\nUser=svc-directory\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/ldap", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/n", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/p", "#!/bin/sh\n", 0o755);
    for ([_][]const u8{ "numeric", "prep", "ldap" }) |n| try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", n }));
    try h.expectContains(try t.read("/etc/sv/numeric/run"), "\nexec /usr/bin/fake-systemd --exec numeric.service\n");
    try h.expectContains(try t.read("/etc/sv/prep/run"), "\nexec /usr/bin/fake-systemd --exec prep.service\n");
    try h.expectContains(try t.read("/etc/sv/ldap/run"), "\nexec /usr/bin/fake-systemd --exec ldap.service --uid \"$(id -u -- svc-directory)\" --gid \"$(id -g -- svc-directory)\" --groups \"$(id -G -- svc-directory | tr ' ' ,)\"\n");
}

test "the Environment= of a unit with an account is applied by the executor, never exported by the part of run that root executes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/nativecmd", "#!/bin/sh\n", 0o755);
    for ([_][]const u8{ "svc-directory", "app" }) |user| {
        const text = try std.fmt.allocPrint(t.a(), "[Service]\nExecStart=/usr/bin/nativecmd\nUser={s}\nEnvironment=PATH=/var/lib/svc/bin:/usr/bin\nEnvironment=LD_PRELOAD=/var/lib/svc/x.so\n[Install]\nWantedBy=multi-user.target\n", .{user});
        const name = try std.fmt.allocPrint(t.a(), "env-{s}", .{user});
        try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name}), text, 0o644);
        try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", name }));
        const run_text = try generatedFile(t, try std.fmt.allocPrint(t.a(), "/etc/sv/{s}/run", .{name}));
        try h.expectNotContains(run_text, "export");
        try h.expectNotContains(run_text, "LD_PRELOAD");
        try h.expectContains(run_text, "/usr/bin/fake-systemd --exec env-");
    }
}

test "a unit without an account keeps Environment= in run" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/nativecmd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/plainenv.service", "[Service]\nExecStart=/usr/bin/nativecmd\nEnvironment=A=1\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plainenv" }));
    try h.expectContains(try generatedFile(t, "/etc/sv/plainenv/run"), "\nexport A=1\n");
}

test "an Environment= value with a line break goes to the executor and cannot add a dependency to run" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/nativecmd", "#!/bin/sh\n", 0o755);
    try t.write("/etc/sv/sshd/run", "#!/bin/sh\nexec sshd\n", 0o755);
    try t.write("/usr/lib/systemd/system/inject.service", "[Service]\nExecStart=/usr/bin/nativecmd\nEnvironment=\"A=1\\nsv start ../sv/sshd\\n\"\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "inject" }));
    const run_text = try generatedFile(t, "/etc/sv/inject/run");
    try h.expectNotContains(run_text, "sv start");
    try h.expectContains(run_text, "/usr/bin/fake-systemd --exec inject.service");
    try testing.expect(!t.exists("/etc/sv/sshd/down"));
}

test "a oneshot with RemainAfterExit keeps a process so that it stays active and stops through runsv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fwctl", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/fw.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/fwctl load\nExecStop=/usr/bin/fwctl flush\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "fw" }));
    try testing.expectEqualStrings(
        "exec 2>&1\n/usr/bin/fake-systemd --exec fw.service || exit $?\nexec /usr/bin/sleep 2147483647\n",
        try generatedFile(t, "/etc/sv/fw/run"),
    );
    try h.expectContains(try generatedFile(t, "/etc/sv/fw/finish"), "\nsv once .\n");
}

// ---- user services ----

test "user scope links into the directory of the user's runsvdir and gives sv the path of the link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope(null);
    try testing.expect(f.t.backend_override.?.caps().user_services);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "--now", "foo" }));
    try testing.expect(t.exists("/home/tester/.config/sv/foo/run"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/tester/.config/sv/foo", try t.fs.readLink("/home/tester/.config/service/foo", &buf));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "start", "/home/tester/.config/service/foo" }));
    try h.expectContains(try t.read("/home/tester/.config/sv/foo/log/run"), "\nexec /usr/bin/fake-systemd --log foo.service --user\n");

    t.rec.stdout = running_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "is-active", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "sv", "status", "/home/tester/.config/service/foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "reload", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "sv", "status", "/home/tester/.config/service/foo" }));
    try testing.expect(t.rec.callIs(3, &.{ "env", "MAINPID=4242", "/usr/bin/fake-systemd", "--exec", "foo.service", "--user", "--phase", "reload" }));
}

test "user dependencies start with the SVDIR of the user's runsvdir" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope(null);
    try t.write("/usr/bin/bar", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/user/bar.service", "[Service]\nExecStart=/usr/bin/bar\n[Install]\nWantedBy=default.target\n", 0o644);
    try t.write("/usr/lib/systemd/user/foo.service", "[Unit]\nRequires=bar.service\n[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(try t.read("/home/tester/.config/sv/foo/run"), "\nSVDIR=/home/tester/.config/service sv start bar || exit 1\n");
    try testing.expect(t.exists("/home/tester/.config/sv/bar/down"));
}

test "turnstile's services_dir moves the link directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope("# runit backend\nservices_dir=\"${HOME}/svc\"\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "foo" }));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/tester/.config/sv/foo", try t.fs.readLink("/home/tester/svc/foo", &buf));
}

test "user services are a capability only where turnstile runs the runit backend" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try testing.expect(!f.t.backend_override.?.caps().user_services);
    try f.t.write("/usr/libexec/turnstile/runit", "#!/bin/sh\n", 0o755);
    f.bind();
    try testing.expect(!f.t.backend_override.?.caps().user_services);
    try f.t.write("/etc/turnstile/turnstiled.conf", "backend = dinit\n", 0o644);
    f.bind();
    try testing.expect(!f.t.backend_override.?.caps().user_services);
    try f.t.write("/etc/turnstile/turnstiled.conf", "backend = runit\n", 0o644);
    f.bind();
    try testing.expect(f.t.backend_override.?.caps().user_services);
}

// ---- timers ----

test "the timer runner is generated, enabled and started like any service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    try h.expectContains(try t.read("/etc/sv/fake-systemd-timers/run"), "\nexec /usr/bin/fake-systemd --timers\n");
    try testing.expectEqualStrings("/etc/sv/fake-systemd-timers", try f.link("fake-systemd-timers"));
    try testing.expect(t.rec.callIs(t.rec.calls.items.len - 1, &.{ "sv", "start", "fake-systemd-timers" }));

    t.rec.stdout = "run: fake-systemd-timers: (pid 7) 3s\n";
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try testing.expect(t.rec.callIs(t.rec.calls.items.len - 1, &.{ "sv", "hup", "fake-systemd-timers" }));

    t.rec.stdout = "";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists("/etc/sv/fake-systemd-timers/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/fake-systemd-timers"));
}

test "disable of a stopped service that runsv supervises waits until runsv is gone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));

    const Fading = struct {
        calls: usize = 0,
        polls: usize = 0,

        fn runner(s: *@This()) h.backend.Runner {
            return .{ .ptr = s, .run_fn = runFn };
        }

        fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.calls += 1;
            const alive = "down: foo: 3s, normally up\n";
            if (std.mem.eql(u8, argv[2], "foo")) return .{ .code = 0, .stdout = alive };
            // After the link is gone `sv` is given the service directory.
            s.polls += 1;
            if (s.polls < 3) return .{ .code = 0, .stdout = alive };
            return .{ .code = 1, .stdout = "fail: /etc/sv/foo: runsv not running\n" };
        }
    };
    var fading: Fading = .{};
    t.runner_override = fading.runner();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 3), fading.polls);
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/foo"));
}

test "an account the executor resolves needs no switch in run, whatever the command" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/plain", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/plain.service", "[Service]\nExecStart=/usr/bin/plain\nUser=app\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain" }));
    try testing.expectEqualStrings("exec 2>&1\nexec /usr/bin/fake-systemd --exec plain.service\n", try generatedFile(t, "/etc/sv/plain/run"));
}

test "without setpriv chpst switches the account and generation warns about the groups" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteFile("/usr/bin/setpriv");
    try t.write("/usr/bin/plain", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/plain.service", "[Service]\nExecStart=/usr/bin/plain\nUser=svc-directory\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain" }));
    try testing.expectEqualStrings("exec 2>&1\nexec chpst -u svc-directory /usr/bin/plain\n", try generatedFile(t, "/etc/sv/plain/run"));
    try h.expectContains(t.stderr(), "plain.service: setpriv is not installed, chpst switches to svc-directory without its supplementary groups");
}

test "TimeoutStartSec and TimeoutStopSec become the waits of sv" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/slow", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/slow.service", "[Service]\nExecStart=/usr/bin/slow\nTimeoutStartSec=30\nTimeoutStopSec=infinity\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "slow" }));
    try h.expectContains(try t.read("/etc/sv/slow/run"), "\n# sv waits: start=30 stop=4294967295\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "slow" }));
    try testing.expect(t.rec.callIs(0, &.{ "sv", "-w", "30", "start", "slow" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "slow" }));
    try testing.expect(t.rec.callIs(1, &.{ "sv", "-w", "4294967295", "force-stop", "slow" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "slow" }));
    try testing.expect(t.rec.callIs(2, &.{ "sv", "-w", "4294967295", "force-stop", "slow" }));
    try testing.expect(t.rec.callIs(3, &.{ "sv", "-w", "30", "start", "slow" }));
}

test "network targets become soft dependencies on the enabled network providers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/netd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/netd.service", "[Unit]\nAfter=network-online.target\nRequires=network.target\n[Service]\nExecStart=/usr/bin/netd\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "netd" }));
    try h.expectNotContains(try t.read("/etc/sv/netd/run"), "sv start");

    f.r.enabled_override = &.{ "NetworkManager", "dhcpcd", "sshd" };
    try t.write("/usr/bin/netd2", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/netd2.service", "[Unit]\nAfter=network-online.target\nRequires=network.target\n[Service]\nExecStart=/usr/bin/netd2\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "netd2" }));
    try h.expectContains(try t.read("/etc/sv/netd2/run"), "\nsv start dhcpcd\nsv start NetworkManager\nexec /usr/bin/netd2\n");
}

test "daemon-reload removes only the links of generated services that left nothing but supervision files" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/etc/sv/mine/conf", "x\n", 0o644);
    try t.fs.symLink("/etc/sv/mine", enable_dir ++ "/mine");
    try t.write("/etc/sv/left/down", "", 0o644);
    try t.write("/etc/sv/left/supervise/lock", "", 0o644);
    try t.fs.symLink("/etc/sv/left", enable_dir ++ "/left");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    _ = try t.fs.lstat(enable_dir ++ "/mine");
    try testing.expectError(error.FileNotFound, t.fs.lstat(enable_dir ++ "/left"));
}

test "a pid that sv reports for a kill is never init" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    t.rec.stdout = "run: foo: (pid 1) 5s\n";
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGWINCH", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
}

test "two units that map to the same service directory are not both generated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/other", "#!/bin/sh\n", 0o755);
    try t.write("/etc/sv/foo/run", "#!/bin/sh\n# Generated automatically by fake-systemd. Remove this block to take ownership of the file.\n# Unit: bar.service\n# Source: /x\n# Source-Hash: xxh3:0000000000000001\n# Body-Hash: xxh3:0000000000000001\n# Generator: fake-systemd 0.1.0 runit/1\nexec x\n", 0o755);
    try testing.expect(t.run(&.{ "enable", "foo" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
}

test "the stop phases of a unit whose account the executor cannot resolve carry the numeric ids too" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/ldaphook", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/ldaphook.service", "[Service]\nExecStart=/usr/bin/ldaphook\nExecStop=/usr/bin/ldaphook --stop\nExecStopPost=/usr/bin/ldaphook --clean\nUser=svc-directory\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldaphook" }));
    const ids = " --uid \"$(id -u -- svc-directory)\" --gid \"$(id -g -- svc-directory)\" --groups \"$(id -G -- svc-directory | tr ' ' ,)\"";
    try h.expectContains(try generatedFile(t, "/etc/sv/ldaphook/finish"), "/usr/bin/fake-systemd --exec ldaphook.service --phase stop-post" ++ ids ++ "\n");
    try h.expectContains(try generatedFile(t, "/etc/sv/ldaphook/control/t"), "/usr/bin/fake-systemd --exec ldaphook.service --phase stop-main" ++ ids ++ "\n");
}

const ldap_script = "exec \"$0\" \"$@\" --uid \"$(id -u -- ldapuser)\" --gid \"$(id -g -- ldapuser)\" --groups \"$(id -G -- ldapuser | tr ' ' ,)\"";

test "reload gives the executor the numeric ids of an account only the system libc resolves" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/ldap.service", "[Service]\nExecStart=/usr/bin/ldap --run\nExecReload=/usr/bin/ldap --reload\nUser=ldapuser\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/ldap", "#!/bin/sh\n", 0o755);
    try t.expectRun(0, &.{ "enable", "ldap" });
    t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "reload", "ldap" });
    try testing.expect(t.rec.callIs(1, &.{ "/bin/sh", "-c", ldap_script, "/usr/bin/fake-systemd", "--exec", "ldap.service", "--phase", "reload" }));
}

test "the services linked with a service are those its meta file lists, not those its run script names" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service");
    try addSvc(t, "b", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try h.expectContains(try t.read("/etc/sv/a/fake-systemd.meta"), "\nStarts: b\n");
    try t.write("/etc/sv/evil/run", "#!/bin/sh\nexec /usr/bin/evil\n", 0o755);
    try t.fs.deleteFile(enable_dir ++ "/b");
    const edited = try std.mem.replaceOwned(u8, t.a(), try t.read("/etc/sv/a/run"), "\nsv start b || exit 1\n", "\nsv start evil\n");
    try t.write("/etc/sv/a/run", edited, 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    _ = try f.link("b");
    try testing.expectError(error.FileNotFound, f.link("evil"));
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}

test "a service generated before the meta file existed is generated again at daemon-reload and then links its dependencies" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service");
    try addSvc(t, "b", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    // What an older generator left: no meta file, and an index that names the older generator.
    try t.fs.deleteFile("/etc/sv/a/fake-systemd.meta");
    try t.fs.deleteFile(enable_dir ++ "/b");
    const index_path = "/var/lib/fake-systemd/runit/index";
    var old = try std.mem.replaceOwned(u8, t.a(), try t.read(index_path), "generator=2", "generator=1");
    const at = std.mem.find(u8, old, ",/etc/sv/a/fake-systemd.meta=").?;
    const end = std.mem.findAnyPos(u8, old, at + 1, ",\t\n").?;
    old = try std.mem.concat(t.a(), u8, &.{ old[0..at], old[end..] });
    try t.write(index_path, old, 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read("/etc/sv/a/fake-systemd.meta"), "\nStarts: b\n");
    try h.expectContains(try t.read(index_path), "generator=2");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    _ = try f.link("b");
}
