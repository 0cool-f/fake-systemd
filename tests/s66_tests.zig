// SPDX-License-Identifier: GPL-3.0-or-later
//! The 66 backend behind the real `ops` entry point, with a runner that behaves like `66`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("s66_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const admin = "/etc/66/service";
const vendor = "/usr/share/66/service";

const Fixture = struct {
    t: h.Harness = undefined,
    b: world.S66 = undefined,
    f66: world.Fake66 = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.f66 = .{ .t = &f.t };
        f.bind();
        f.t.detected = "66";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.b);
        f.t.backend_override = f.b.backend();
        f.t.runner_override = f.f66.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.f66.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.f66.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectNoCall(f: *Fixture, prefix: []const []const u8) !void {
        if (f.f66.called(prefix)) {
            std.debug.print("unexpected call {s}...; calls:\n{s}", .{ prefix[0], try f.f66.dump(f.t.a()) });
            return error.TestUnexpectedCall;
        }
    }

    fn clear(f: *Fixture) void {
        f.f66.calls.clearRetainingCapacity();
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

test "enable generates the frontend file in the vendor directory and has 66 enable the service alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(vendor ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 66/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try h.expectContains(parsed.rest, "[Main]\nType = classic\nDescription = \"Unit foo.service\"\nOptions = ( !log )\n");
    try h.expectContains(parsed.rest, "\n[Start]\nTimeout = 90000\nExecute = (#!/bin/sh\nexec /usr/bin/fake-systemd --exec foo.service --log\n)\n");
    try f.expectCall(0, &.{ "66", "enable", "-P", "foo" });
    try testing.expectEqual(@as(usize, 1), f.f66.calls.items.len);
    try h.expectContains(t.stderr(), "Created '/var/lib/66/system/service/svc/foo/.resolve/foo'.");

    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.f66.calls.items.len);
}

test "an administrator unit is generated into the administrator directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/etc/systemd/system", "local.service", "/usr/bin/local", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "local" }));
    try testing.expect(t.exists(admin ++ "/local"));
    try testing.expect(!t.exists(vendor ++ "/local"));
}

test "the index records the frontend file and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/66/index"), vendor ++ "/foo");
    try t.fs.deleteFile("/var/lib/fake-systemd/66/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(vendor ++ "/foo"));
}

test "is-enabled reads the resolve file 66 wrote" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try world.markParsed(t, "foo", false);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(usize, 1), f.f66.calls.items.len);
}

test "disable has 66 disable the service alone, and does nothing for one that is not enabled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ "66", "disable", "-P", "foo" });
    try testing.expect(t.exists(vendor ++ "/foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.f66.calls.items.len);
}

test "enable --now starts the service through 66" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try f.expectCall(0, &.{ "66", "enable", "-P", "foo" });
    try f.expectCall(1, &.{ "66", "start", "foo" });
}

test "a failed 66 enable is reported with its exit status" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.f66.rules = &.{.{ .prefix = &.{ "66", "enable" }, .code = 111, .stdout = "parse: fatal: unable to parse dependencies of service: foo\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "foo: 66 enable exited 111: parse: fatal: unable to parse dependencies of service: foo");
}

test "offline in the real root runs 66 as well, and inside a --root tree nothing can run it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.expectCall(0, &.{ "66", "enable", "-P", "foo" });

    var other: Fixture = .{};
    try other.init();
    defer other.deinit();
    other.b.run_here = false;
    other.t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 1), other.t.run(&.{ "enable", "foo" }));
    try h.expectContains(other.t.stderr(), "cannot run inside a --root tree");
    try testing.expectEqual(@as(usize, 0), other.f66.calls.items.len);
    try testing.expectEqual(@as(u8, 1), other.t.run(&.{ "is-enabled", "foo" }));
}

test "dependencies become Depends and a network target maps to the enabled providers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.b.enabled_override = &.{"dhcpcd"};
    try addSvc(t, "app", "Requires=dbus.service\nWants=postgresql.service\nAfter=network-online.target\nWants=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "app" }));
    const text = try t.read(vendor ++ "/app");
    try h.expectContains(text, "\nDepends = ( dbus postgresql dhcpcd )\n");
    try testing.expect(t.exists(vendor ++ "/dbus"));
    try testing.expect(t.exists(vendor ++ "/postgresql"));
    // Only the unit that was named is enabled; 66 starts the others through Depends.
    try testing.expectEqual(@as(usize, 1), f.f66.count(&.{ "66", "enable" }));
    try f.expectCall(0, &.{ "66", "enable", "-P", "app" });
}

test "a native service wins over a translated unit that runs the same program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "syslog", "", "");
    try t.write("/usr/bin/native", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/bin/native --serve\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "syslog" }));
    try testing.expectEqualStrings(world.native_frontend, try t.read(vendor ++ "/syslog"));
    try f.expectCall(0, &.{ "66", "enable", "-P", "syslog" });
}

test "an instance is a service of its own with the name flattened" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/tpl@.service", "[Service]\nExecStart=/usr/bin/foo %i\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@tty1" }));
    try testing.expect(t.exists(vendor ++ "/tpl-tty1"));
    try h.expectContains(try t.read(vendor ++ "/tpl-tty1"), "--exec tpl@tty1.service --log");
    try f.expectCall(0, &.{ "66", "enable", "-P", "tpl-tty1" });
}

test "an instance name that 66 would take for an identifier is kept out of the file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/tpl@.service", "[Unit]\nDescription=Template for @U and %i\n[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@Home" }));
    const text = try t.read(vendor ++ "/tpl-Home");
    try h.expectContains(text, "at=@\nexec /usr/bin/fake-systemd --exec tpl\"$at\"Home.service --log\n");
    try h.expectContains(text, "Description = \"Template for (at)U and Home\"");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '#') continue;
        for ([_][]const u8{ "@I", "@U", "@u", "@G", "@g", "@H", "@S", "@R" }) |id| try testing.expect(std.mem.find(u8, line, id) == null);
    }
}

test "an account only the system libc knows is switched with setpriv, or with execl-runas without it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=ldapuser\nGroup=ldapgroup\nSupplementaryGroups=extra");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    const text = try t.read(vendor ++ "/ldap");
    try h.expectContains(text, "mkdir -p /var/log/fake-systemd/ldap.service && chown ldapuser /var/log/fake-systemd/ldap.service\n");
    try h.expectContains(text, "exec /usr/bin/setpriv --reuid=ldapuser --regid=ldapgroup --groups \"$(id -G ldapuser | tr ' ' ,),extra\" /usr/bin/fake-systemd --exec ldap.service --log\n");

    try t.fs.deleteFile("/usr/bin/setpriv");
    try addSvc(t, "ldap2", "", "User=ldapuser");
    try t.write("/usr/bin/execl-runas", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap2" }));
    try h.expectContains(try t.read(vendor ++ "/ldap2"), "exec /usr/bin/execl-runas ldapuser /usr/bin/fake-systemd --exec ldap2.service --log\n");
    try addSvc(t, "ldap3", "", "User=ldapuser\nGroup=ldapgroup");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap3" }));
    try h.expectContains(t.stderr(), "setpriv is not installed, execl-runas switches to ldapuser with its own groups only");
}

test "an account in /etc/passwd is switched by the executor, which keeps the file free of it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "known", "", "User=app\nGroup=app\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "known" }));
    const text = try t.read(vendor ++ "/known");
    try h.expectContains(text, "\nexec /usr/bin/fake-systemd --exec known.service --log\n");
    try testing.expect(std.mem.find(u8, text, "setpriv") == null);
}

test "a oneshot that stays after its command is flagged, and ExecStop= keeps the executor resident for a service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "keep", "", "Type=oneshot\nRemainAfterExit=yes\nExecStop=/usr/bin/keep --stop\nTimeoutStartSec=30");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "keep" }));
    const keep = try t.read(vendor ++ "/keep");
    try h.expectContains(keep, "# fake-systemd flags: remain\n");
    try h.expectContains(keep, "Type = oneshot\n");
    try h.expectContains(keep, "[Start]\nTimeout = 30000\nExecute = (#!/bin/sh\nexec /usr/bin/fake-systemd --exec keep.service --log\n)\n");
    try h.expectContains(keep, "[Stop]\nExecute = (#!/bin/sh\nexec /usr/bin/fake-systemd --exec keep.service --phase stop --log\n)\n");

    try addSvc(t, "hook", "", "ExecStop=/usr/bin/hook --stop\nKillSignal=SIGINT\nTimeoutStopSec=20");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hook" }));
    const hook = try t.read(vendor ++ "/hook");
    try h.expectContains(hook, "--exec hook.service --log --stop-on-signal\n");
    try h.expectContains(hook, "Timeout = 50000\n");
    try testing.expect(std.mem.find(u8, hook, "DownSignal") == null);
}

test "Restart= becomes the exit status of finish" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "failing", "", "Restart=on-failure\nRestartSec=5\nSuccessExitStatus=3 SIGUSR1\nKillSignal=SIGHUP\nExecStopPost=/usr/bin/cleanup");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "failing" }));
    const text = try t.read(vendor ++ "/failing");
    try h.expectContains(text, "# fake-systemd flags: ok-codes=3 ok-signals=10\n");
    try h.expectContains(text, "\n[Stop]\nDownSignal = SIGHUP\nTimeout = 95000\nExecute = (#!/bin/sh\n");
    try h.expectContains(text, "exited) case \"$c\" in 0|3) clean=1 ;; esac ;;\nsignaled) case \"$c\" in 1|2|13|15|10) clean=1 ;; esac ;;\n");
    try h.expectContains(text, "/usr/bin/fake-systemd --exec failing.service --phase stop-post\n[ -n \"$clean\" ] && exit 125\nsleep 5\nexit 0\n)\n");

    try addSvc(t, "always", "", "Restart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "always" }));
    try testing.expect(std.mem.find(u8, try t.read(vendor ++ "/always"), "[Stop]") == null);
}

// ---- runtime control ----------------------------------------------------------------------------

test "start asks 66 to start the service, and a failure is reported" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "66", "start", "foo" });
    f.f66.rules = &.{.{ .prefix = &.{ "66", "start" }, .code = 111, .stdout = "start: fatal: scandir: /run/66/scandir/0 is not running: No such file or directory\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "foo: 66 start exited 111: start: fatal: scandir: /run/66/scandir/0 is not running");
}

test "stop of a service that is down stops it once, and a service never parsed is left alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.f66.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.clear();
    f.f66.runstate = world.down;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "66", "stop", "foo" });
    try f.expectCall(1, &.{ "66", "runstate", "-nf", "state,result,who,pid,code", "foo" });
    try testing.expectEqual(@as(usize, 2), f.f66.calls.items.len);
}

test "a service that is still wanted up after stop is brought down for good, and a failed one is forgotten" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "loop", "", "Restart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "loop" }));
    f.clear();
    f.f66.runstate = "restarting\nexited\nself\n0\n1\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "loop" }));
    try f.expectCall(0, &.{ "66", "stop", "loop" });
    try f.expectCall(2, &.{ "66", "resolve", "-nf", "live_servicedir", "loop" });
    try f.expectCall(3, &.{ "66-svctl", "-D", "-w", "d", "-T", "30000", "--", "/run/66/state/0/loop" });

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.clear();
    f.f66.runstate = "failed\nexited\nuser\n0\n7\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "66", "stop", "foo" });
    try f.expectCall(2, &.{ "66", "free", "-P", "foo" });
}

test "restart is a stop followed by a start" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.clear();
    f.f66.runstate = world.down;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(0, &.{ "66", "stop", "foo" });
    try f.expectCall(2, &.{ "66", "start", "foo" });
}

test "status records of 66 are normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    const cases = [_]struct { []const u8, []const u8, u8 }{
        .{ world.up, "active\n", 0 },
        .{ world.down, "inactive\n", 3 },
        .{ world.never_started, "inactive\n", 3 },
        .{ "down\nexited\nself\n0\n1\n", "failed\n", 3 },
        .{ "down\nsignaled\nself\n0\n15\n", "inactive\n", 3 },
        .{ "failed\ncrash-limit\nself\n0\n0\n", "failed\n", 3 },
        .{ "restarting\nexited\nself\n0\n1\n", "activating\n", 3 },
        .{ "stopping\nsuccess\nuser\n4242\n0\n", "deactivating\n", 3 },
    };
    for (cases) |c| {
        f.f66.runstate = c[0];
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.f66.runstate = "down\nexited\nself\n0\n9\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
}

test "a service nobody parsed is inactive without asking 66" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(usize, 0), f.f66.calls.items.len);
}

test "a oneshot that is done is active only when it remains after exit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "keep", "", "Type=oneshot\nRemainAfterExit=yes");
    try addSvc(t, "run", "", "Type=oneshot");
    for ([_][]const u8{ "keep", "run" }) |name| try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", name }));
    f.f66.runstate = "done\nsuccess\nuser\n0\n0\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "keep" }));
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "run" }));
}

test "the main pid comes from the runtime record" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.f66.runstate = world.up;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "MainPID", "-p", "ActiveState", "foo" }));
    try h.expectContains(t.stdout(), "MainPID=4242\n");
    try h.expectContains(t.stdout(), "ActiveState=active\n");
}

test "kill signals the process 66 supervises, with the name without SIG" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.f66.runstate = world.up;
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "foo" }));
    try f.expectCall(1, &.{ "kill", "-s", "TERM", "4242" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "--signal=SIGHUP", "foo" }));
    try f.expectCall(3, &.{ "kill", "-s", "HUP", "4242" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "10", "foo" }));
    try f.expectCall(5, &.{ "kill", "-s", "10", "4242" });
    f.f66.runstate = world.down;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "foo: no process to signal");
    f.f66.rules = &.{.{ .prefix = &.{"kill"}, .code = 1 }};
    f.f66.runstate = world.up;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
}

test "reload hands the pid 66 supervises to the executor, native services get SIGHUP" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.clear();
    f.f66.runstate = world.up;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(1, &.{ "env", "MAINPID=4242", "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" });
    try t.addUnit("/usr/lib/systemd/system", "syslog.service", "/usr/bin/native", "WantedBy=multi-user.target");
    try world.markParsed(t, "syslog", true);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCall(3, &.{ "kill", "-s", "HUP", "4242" });
}

test "poweroff, reboot and halt are the 66 commands" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try f.expectCall(0, &.{ "66", "poweroff" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try f.expectCall(1, &.{ "66", "reboot" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(2, &.{ "66", "halt" });
}

// ---- regenerated frontend files ---------------------------------------------------------------------

fn pause() void {
    testing.io.sleep(.fromMilliseconds(30), .awake) catch {};
}

test "a frontend file that was regenerated is parsed again before the service starts, and enabled again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.f66.calls.items.len);
    try f.expectCall(0, &.{ "66", "start", "foo" });

    pause();
    t.ctx.offline = true;
    try t.write("/usr/lib/systemd/system/foo.service", "[Unit]\nDescription=Changed\n\n[Service]\nExecStart=/usr/bin/foo --other\n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(vendor ++ "/foo"), "Description = \"Changed\"");
    t.ctx.offline = false;
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "66", "parse", "-f", "foo" });
    try f.expectCall(1, &.{ "66", "enable", "-P", "foo" });
    try f.expectCall(2, &.{ "66", "start", "foo" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));

    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.f66.calls.items.len);
}

test "daemon-reload on a running system parses regenerated services again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    pause();
    try t.write("/usr/lib/systemd/system/foo.service", "[Unit]\nDescription=Changed\n\n[Service]\nExecStart=/usr/bin/foo --other\n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCall(0, &.{ "66", "parse", "-f", "foo" });
    try f.expectCall(1, &.{ "66", "enable", "-P", "foo" });
    try testing.expectEqual(@as(usize, 2), f.f66.calls.items.len);
}

test "daemon-reload removes what 66 parsed from a frontend file that is gone, and keeps the rest" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    // The resolve file of the fixture names /etc/66/service/hello as its frontend file.
    try world.markParsed(t, "orphan", true);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCall(0, &.{ "66", "remove", "-P", "orphan" });
    try testing.expectEqual(@as(usize, 1), f.f66.calls.items.len);

    try world.markParsed(t, "kept", true);
    try t.write(admin ++ "/hello", world.native_frontend, 0o644);
    f.clear();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 0), f.f66.count(&.{ "66", "remove" }));
}

// ---- user services -------------------------------------------------------------------------------------

test "a user unit is generated into the personal directory and enabled in the tree of the user" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    f.bind();
    try t.write("/usr/bin/mine", "#!/bin/sh\n", 0o755);
    try t.write("/home/tester/.config/systemd/user/mine.service", "[Service]\nExecStart=/usr/bin/mine\n[Install]\nWantedBy=default.target\n", 0o644);
    try t.expectRun(0, &.{ "--user", "enable", "mine" });
    const text = try t.read("/home/tester/.66/service/mine");
    try h.expectContains(text, "exec /usr/bin/fake-systemd --exec mine.service --user --log\n");
    try f.expectCall(0, &.{ "66", "enable", "-P", "mine" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "start", "mine" }));
    try f.expectCall(1, &.{ "66", "start", "mine" });
}

test "a vendor unit of the user goes to the user directory of the system for root, and to the home of anyone else" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.environ.put("HOME", "/home/tester");
    try t.write("/usr/bin/pkg", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/user/pkg.service", "[Service]\nExecStart=/usr/bin/pkg\n[Install]\nWantedBy=default.target\n", 0o644);
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 0);
    f.bind();
    try t.expectRun(0, &.{ "--user", "enable", "pkg" });
    try testing.expect(t.exists("/usr/share/66/service/user/pkg"));
    try t.fs.deleteFile("/usr/share/66/service/user/pkg");

    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    f.bind();
    try t.expectRun(0, &.{ "--user", "enable", "pkg" });
    try testing.expect(t.exists("/home/tester/.66/service/pkg"));
    try testing.expect(!t.exists("/usr/share/66/service/user/pkg"));
}

// ---- dry runs --------------------------------------------------------------------------------------------

test "a dry run writes nothing and names the 66 command it would run" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    var dry: h.backend.runner.Dry = .{ .out = &t.out.writer };
    t.runner_override = dry.runner();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "foo" }));
    try testing.expect(!t.exists(vendor ++ "/foo"));
    try h.expectContains(t.stdout(), "would run: 66 enable -P foo\n");
}
