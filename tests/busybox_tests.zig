// SPDX-License-Identifier: GPL-3.0-or-later
//! The BusyBox init backend behind the real `ops` entry point: services as runit directories
//! when the inittab starts `runsvdir`, and as init scripts listed in the inittab when it does not.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("busybox_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const Fixture = struct {
    t: h.Harness = undefined,
    b: world.Busybox = undefined,

    fn init(f: *Fixture, setup: world.Setup) !void {
        try f.t.init();
        try world.populate(&f.t, setup);
        try f.t.addFoo();
        world.use(&f.t, &f.b);
        f.t.detected = "busybox";
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.t.rec.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n", .{ index, expected[0] });
            for (f.t.rec.calls.items) |c| std.debug.print("  {s}\n", .{try std.mem.join(f.t.a(), " ", c)});
            return error.TestExpectedCall;
        }
    }

    fn inittab(f: *Fixture) ![]const u8 {
        return f.t.read("/etc/inittab");
    }
};

// ---- the inittab starts runsvdir ----------------------------------------------------------------

test "with runsvdir in the inittab the services are runit service directories linked in its scan directory" {
    var f: Fixture = .{};
    try f.init(.runsv);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqualStrings("busybox", f.b.backend().name());
    try testing.expectEqual(world.Busybox.Mode.runsvdir, f.b.mode);
    try testing.expect(f.b.backend().caps().supervision and f.b.backend().caps().per_service_logger and !f.b.backend().caps().user_services);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read("/etc/sv/foo/run")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 runit/2", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/etc/sv/foo", try t.fs.readLink("/var/service/foo", &buf));
    try h.expectContains(t.stderr(), "Created symlink '/var/service/foo' -> '/etc/sv/foo'.");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expect(!t.exists("/var/service/foo"));
}

test "the scan directory of the inittab is where services are linked, and sv and the run scripts are told" {
    var f: Fixture = .{};
    try f.init(.runsv_etc);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqualStrings("/etc/service", f.b.scan_dir);
    try t.expectRun(0, &.{ "enable", "--now", "foo" });
    try testing.expect(t.exists("/etc/service/foo"));
    try testing.expect(!t.exists("/var/service/foo"));
    const run = try t.read("/etc/sv/foo/run");
    const parsed = marker.parse(run).?;
    try testing.expectEqualStrings("#!/bin/sh\n", parsed.shebang);
    try h.expectContains(run, "\nexport SVDIR=/etc/service\nexec 2>&1\n");
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 runit/2", parsed.marker.generator);
    try testing.expect(!std.mem.startsWith(u8, try t.read("/etc/sv/foo/log/run"), "export"));
    var saw_sv = false;
    for (t.rec.calls.items) |call| {
        if (std.mem.eql(u8, call[0], "sv")) return error.SvCalledWithoutSvdir;
        if (call.len > 2 and std.mem.eql(u8, call[0], "env") and std.mem.eql(u8, call[1], "SVDIR=/etc/service") and std.mem.eql(u8, call[2], "sv")) saw_sv = true;
    }
    try testing.expect(saw_sv);
}

test "a service whose requirement is another one finds it through sv in the other scan directory" {
    var f: Fixture = .{};
    try f.init(.runsv_etc);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/app", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/app.service", "[Unit]\nRequires=dbus.service\n[Service]\nExecStart=/usr/bin/app\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "app" });
    const run = try t.read("/etc/sv/app/run");
    try h.expectContains(run, "export SVDIR=/etc/service\n");
    try h.expectContains(run, "sv start dbus || exit 1\n");
    try testing.expect(marker.parse(run).?.bodyIntact());
}

/// Runner that answers `sv` the way BusyBox does for a service its `runsv` has not adopted yet,
/// and succeeds once `adopted` is set by a status call that comes later.
const Adopting = struct {
    gpa: std.mem.Allocator,
    calls: usize = 0,
    statuses: usize = 0,

    fn runner(a: *Adopting) h.backend.Runner {
        return .{ .ptr = a, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const a: *Adopting = @ptrCast(@alignCast(ptr));
        a.calls += 1;
        const at = for (argv, 0..) |w, i| {
            if (std.mem.eql(u8, w, "sv")) break i;
        } else return .{ .code = 0 };
        const verb = argv[at + 1];
        if (std.mem.eql(u8, verb, "status")) {
            a.statuses += 1;
            if (a.statuses <= 2) return .{ .code = 1, .stdout = "warning: foo: can't open supervise/ok: No such file or directory\n" };
            return .{ .code = 0, .stdout = "run: foo: (pid 4242) 1s\n" };
        }
        if (a.statuses < 3) return .{ .code = 1, .stdout = "warning: foo: can't open supervise/ok: No such file or directory\n" };
        return .{ .code = 0, .stdout = "ok: run: foo: (pid 4242) 0s\n" };
    }
};

test "the messages of BusyBox sv make start wait for runsvdir to adopt a new service directory" {
    var f: Fixture = .{};
    try f.init(.runsv);
    defer f.deinit();
    const t = &f.t;
    var adopting: Adopting = .{ .gpa = t.a() };
    t.runner_override = adopting.runner();
    try t.expectRun(0, &.{ "start", "foo" });
    // runsvdir had not seen the link: the start waited for it, then started the service.
    try testing.expect(adopting.statuses >= 3);
    try testing.expect(t.exists("/var/service/foo"));
    try testing.expect(t.exists("/etc/sv/foo/down"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
}

test "a user service is refused with the reason in either mode" {
    for ([_]world.Setup{ .runsv, .inittab }) |setup| {
        var f: Fixture = .{};
        try f.init(setup);
        defer f.deinit();
        const t = &f.t;
        try t.environ.put("HOME", "/home/tester");
        t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
        world.use(t, &f.b);
        try t.write("/usr/bin/mine", "#!/bin/sh\n", 0o755);
        try t.write("/home/tester/.config/systemd/user/mine.service", "[Service]\nExecStart=/usr/bin/mine\n[Install]\nWantedBy=default.target\n", 0o644);
        try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "mine" }));
        try h.expectContains(t.stderr(), "BusyBox init has no service manager for users");
    }
}

// ---- the inittab starts no service manager ---------------------------------------------------------

test "without runsvdir the services are init scripts of the sysvinit kind" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(world.Busybox.Mode.inittab, f.b.mode);
    try testing.expect(!f.b.backend().caps().supervision and f.b.backend().caps().ordering and !f.b.backend().caps().user_services);
    try t.expectRun(0, &.{ "enable", "foo" });
    const parsed = marker.parse(try t.read("/etc/init.d/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 sysvinit/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat("/etc/init.d/foo")).mode);
    try h.expectContains(t.stderr(), "foo: listed in /etc/inittab");
}

test "enable lists the script in a block at the end of the inittab, and leaves the entries of the system alone" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "enable", "foo" });
    try testing.expectEqualStrings(world.base_inittab ++
        \\# BEGIN fake-systemd
        \\::wait:/etc/init.d/foo start
        \\::shutdown:/etc/init.d/foo stop
        \\# END fake-systemd
        \\
    , try f.inittab());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "enable", "foo" });
    try testing.expectEqual(@as(usize, 0), f.t.rec.calls.items.len);
    try testing.expectEqualStrings("", t.stderr());
}

test "a running init is told to read the inittab again, an offline one is not" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "enable", "foo" });
    try f.expectCall(0, &.{ "kill", "-HUP", "1" });
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "disable", "foo" });
    try f.expectCall(0, &.{ "kill", "-HUP", "1" });
    try h.expectContains(t.stderr(), "foo: removed from /etc/inittab");
    t.ctx.offline = true;
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "enable", "foo" });
    try testing.expectEqual(@as(usize, 0), f.t.rec.calls.items.len);
    try h.expectContains(try f.inittab(), "::wait:/etc/init.d/foo start\n");
}

test "disable removes only the named script, drops an empty block, and is idempotent" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "bar.service", "/usr/bin/bar", "WantedBy=multi-user.target");
    try t.expectRun(0, &.{ "enable", "foo", "bar" });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, try f.inittab(), "start\n"));
    try t.expectRun(0, &.{ "disable", "foo" });
    const text = try f.inittab();
    try testing.expect(std.mem.find(u8, text, "/etc/init.d/foo") == null);
    try h.expectContains(text, "::wait:/etc/init.d/bar start\n::shutdown:/etc/init.d/bar stop\n");
    try t.expectRun(0, &.{ "disable", "bar" });
    try testing.expectEqualStrings(world.base_inittab, try f.inittab());
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "disable", "bar" });
    try testing.expectEqual(@as(usize, 0), f.t.rec.calls.items.len);
}

test "the requirements of a script are listed before it and stopped after it, wanted ones only order it" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/app", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/app.service", "[Unit]\nRequires=dbus.service\nWants=postgresql.service\nAfter=postgresql.service\n[Service]\nExecStart=/usr/bin/app\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    // postgresql is enabled first, so the wanted dependency is there to order after.
    try t.write("/usr/lib/systemd/system/postgresql.service", "[Service]\nExecStart=/usr/bin/dep\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "postgresql" });
    try t.expectRun(0, &.{ "enable", "app" });
    try testing.expectEqualStrings(world.base_inittab ++
        \\# BEGIN fake-systemd
        \\::wait:/etc/init.d/postgresql start
        \\::wait:/etc/init.d/dbus start
        \\::wait:/etc/init.d/app start
        \\::shutdown:/etc/init.d/app stop
        \\::shutdown:/etc/init.d/dbus stop
        \\::shutdown:/etc/init.d/postgresql stop
        \\# END fake-systemd
        \\
    , try f.inittab());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "dbus" }));
    // A requirement that is enabled later still starts before the service that needs it.
    try t.expectRun(0, &.{ "disable", "dbus" });
    try t.expectRun(0, &.{ "enable", "dbus" });
    const again = try f.inittab();
    try testing.expect(std.mem.find(u8, again, "/etc/init.d/dbus start").? < std.mem.find(u8, again, "/etc/init.d/app start").?);
    // Disabling the unit leaves the requirement it pulled in.
    try t.expectRun(0, &.{ "disable", "app" });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, try f.inittab(), "start\n"));
}

test "entries of the inittab outside the block survive byte for byte, a missing newline included" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    const odd = "# my inittab\n::sysinit:/etc/init.d/rcS\n\n  tty1::respawn:/sbin/getty 38400 tty1  \n::shutdown:/bin/sync";
    try t.write("/etc/inittab", odd, 0o600);
    try t.expectRun(0, &.{ "enable", "foo" });
    const text = try f.inittab();
    try testing.expect(std.mem.startsWith(u8, text, odd ++ "\n# BEGIN fake-systemd\n"));
    try testing.expectEqual(@as(u16, 0o600), (try t.fs.stat("/etc/inittab")).mode);
    try t.expectRun(0, &.{ "disable", "foo" });
    try testing.expectEqualStrings(odd ++ "\n", try f.inittab());
}

test "enable of a unit that has no script yet generates it, and a dry run changes nothing" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "foo" });
    try testing.expect(!t.exists("/etc/init.d/foo"));
    try testing.expectEqualStrings(world.base_inittab, try f.inittab());
    try testing.expectEqual(@as(usize, 0), f.t.rec.calls.items.len);
}

test "start, stop and status run the script, as on sysvinit" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "enable", "foo" });
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "start", "foo" });
    try f.expectCall(0, &.{ "/etc/init.d/foo", "start" });
    try t.expectRun(0, &.{ "stop", "foo" });
    try f.expectCall(1, &.{ "/etc/init.d/foo", "stop" });
    f.t.rec.code = 3;
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try f.expectCall(2, &.{ "/etc/init.d/foo", "status" });
    f.t.rec.code = 0;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
}

test "daemon-reload drops the entries of scripts that are gone, and tells init" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "enable", "foo" });
    try t.fs.deleteFile("/etc/init.d/foo");
    f.t.rec.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{"daemon-reload"});
    try testing.expectEqualStrings(world.base_inittab, try f.inittab());
    try f.expectCall(0, &.{ "kill", "-HUP", "1" });
}

test "poweroff, reboot and halt are the applets of BusyBox, in both modes" {
    for ([_]world.Setup{ .runsv, .inittab }) |setup| {
        var f: Fixture = .{};
        try f.init(setup);
        defer f.deinit();
        const t = &f.t;
        try t.expectRun(0, &.{"poweroff"});
        try f.expectCall(0, &.{"poweroff"});
        try t.expectRun(0, &.{"reboot"});
        try f.expectCall(1, &.{"reboot"});
        try t.expectRun(0, &.{"halt"});
        try f.expectCall(2, &.{"halt"});
    }
}

test "a missing inittab is a system without runsvdir" {
    var f: Fixture = .{};
    try f.t.init();
    defer f.deinit();
    try world.populate(&f.t, .inittab);
    try f.t.addFoo();
    try f.t.fs.deleteFile("/etc/inittab");
    world.use(&f.t, &f.b);
    try testing.expectEqual(world.Busybox.Mode.inittab, f.b.mode);
    try f.t.expectRun(0, &.{ "enable", "foo" });
    try testing.expectEqualStrings("# BEGIN fake-systemd\n::wait:/etc/init.d/foo start\n::shutdown:/etc/init.d/foo stop\n# END fake-systemd\n", try f.inittab());
}

test "finish brings the service down with sv down, which BusyBox's runsv takes in any order of events" {
    var f: Fixture = .{};
    try f.init(.runsv);
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "enable", "foo" });
    const finish = try t.read("/etc/sv/foo/finish");
    try h.expectContains(finish, "\nsv down .\n");
    try testing.expect(std.mem.find(u8, finish, "sv once") == null);
    const parsed = marker.parse(finish).?;
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 runit/2", parsed.marker.generator);
}

test "an inittab whose block is not closed is left untouched" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    const broken = world.base_inittab ++ "# BEGIN fake-systemd\n::wait:/etc/init.d/old start\n";
    try t.write("/etc/inittab", broken, 0o644);
    try t.expectRun(1, &.{ "enable", "foo" });
    try testing.expectEqualStrings(broken, try f.inittab());
    try h.expectContains(t.stderr(), "/etc/inittab:");
    try h.expectContains(t.stderr(), "BEGIN marker without an END marker");
}

test "an inittab with two blocks or a nested BEGIN is left untouched" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    for ([_][]const u8{
        "# BEGIN fake-systemd\n::wait:/etc/init.d/a start\n# END fake-systemd\nx::respawn:/bin/x\n# BEGIN fake-systemd\n::wait:/etc/init.d/b start\n# END fake-systemd\n",
        "# BEGIN fake-systemd\n# BEGIN fake-systemd\n::wait:/etc/init.d/a start\n# END fake-systemd\n",
    }) |tail| {
        const broken = try std.mem.concat(t.a(), u8, &.{ world.base_inittab, tail });
        try t.write("/etc/inittab", broken, 0o644);
        try t.expectRun(1, &.{ "enable", "foo" });
        try testing.expectEqualStrings(broken, try f.inittab());
    }
}

test "an inittab that cannot be read is an error, not an empty file to rewrite" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteFile("/etc/inittab");
    try t.fs.makePath("/etc/inittab");
    try t.expectRun(1, &.{ "enable", "foo" });
    try h.expectContains(t.stderr(), "cannot read /etc/inittab");
    try testing.expect((try t.fs.stat("/etc/inittab")).kind == .directory);
}

test "the order of the inittab follows the units, not the header lines of the generated scripts" {
    var f: Fixture = .{};
    try f.init(.inittab);
    defer f.deinit();
    const t = &f.t;
    for ([_][]const u8{ "app", "dep" }) |name| {
        try t.write(try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name}), "#!/bin/sh\n", 0o755);
        const requires = if (std.mem.eql(u8, name, "app")) "Requires=dep.service\n" else "";
        const text = try std.fmt.allocPrint(t.a(), "[Unit]\n{s}[Service]\nExecStart=/usr/bin/{s}\n[Install]\nWantedBy=multi-user.target\n", .{ requires, name });
        try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name}), text, 0o644);
    }
    try t.expectRun(0, &.{ "enable", "app" });
    const script = try t.read("/etc/init.d/app");
    try h.expectContains(script, "dep");
    try t.write("/etc/init.d/app", try std.mem.replaceOwned(u8, t.a(), script, "dep", "gone"), 0o755);
    // The inittab lists app alone, so that enabling dep has to place it before app.
    var list = try std.mem.replaceOwned(u8, t.a(), try f.inittab(), "::wait:/etc/init.d/dep start\n", "");
    list = try std.mem.replaceOwned(u8, t.a(), list, "::shutdown:/etc/init.d/dep stop\n", "");
    try t.write("/etc/inittab", list, 0o644);
    try t.expectRun(0, &.{ "enable", "dep" });
    const again = try f.inittab();
    try testing.expect(std.mem.find(u8, again, "/etc/init.d/dep start").? < std.mem.find(u8, again, "/etc/init.d/app start").?);
}

test "a line break in a literal setting is refused and reaches no generated file in either mode" {
    inline for (.{ .runsv, .inittab }) |setup| {
        var f: Fixture = .{};
        try f.init(setup);
        defer f.deinit();
        try h.expectControlRefused(&f.t);
    }
}
