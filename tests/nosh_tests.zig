// SPDX-License-Identifier: GPL-3.0-or-later
//! The nosh backend behind the real `ops` entry point, with a runner that answers like
//! `system-control` and its unit converter.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("nosh_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const services = "/etc/service-bundles/services";
const targets = "/etc/service-bundles/targets";
const records = "/etc/service-bundles/fake-systemd";

const Fixture = struct {
    t: h.Harness = undefined,
    n: world.nosh = undefined,
    ctl: world.Control = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.ctl = .{ .gpa = f.t.a(), .fs = &f.t.fs };
        f.bind();
        f.t.detected = "nosh";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.n);
        f.t.backend_override = f.n.backend();
        f.t.runner_override = f.ctl.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.ctl.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.ctl.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectCalls(f: *Fixture, expected: []const []const []const u8) !void {
        for (expected, 0..) |call, i| try f.expectCall(i, call);
        if (f.ctl.calls.items.len != expected.len) {
            std.debug.print("{d} calls, wanted {d}:\n{s}", .{ f.ctl.calls.items.len, expected.len, try f.ctl.dump(f.t.a()) });
            return error.TestUnexpectedCall;
        }
    }

    fn state(f: *Fixture, name: []const u8, text: []const u8) !void {
        try f.ctl.states.put(f.t.a(), name, text);
    }
};

const convert_script = world.nosh.convert_script;

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

test "enable records the unit, converts it, links it and starts nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const rec = marker.parse(try t.read(records ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", rec.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 nosh/1", rec.marker.generator);
    try testing.expect(rec.bodyIntact());
    try h.expectContains(rec.rest, "directory /usr/lib/systemd/system\nunit foo.service\nhash ");
    try f.expectCalls(&.{
        &.{ "sh", "-c", convert_script, "nosh-convert", "/usr/lib/systemd/system", services, "foo.service" },
        &.{ "system-control", "enable", "foo" },
    });
    const run = marker.parse(try t.read(services ++ "/foo/service/run")).?;
    try testing.expectEqualStrings("#!/bin/nosh\n", run.shebang);
    try testing.expectEqualStrings("foo.service", run.marker.unit);
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(services ++ "/foo/service/run")).mode);
    try h.expectContains(run.rest, "/usr/bin/foo --run");
    try testing.expect(t.exists(services ++ "/foo/fake-systemd.hash"));
    try h.expectContains(t.stderr(), "Created symlink '/etc/service-bundles/targets/multi-user/wants/foo' -> '../../../services/foo'.");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
}

test "a unit that did not change is not converted again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "system-control", "status", "foo" });
    try f.expectCall(1, &.{ "system-control", "start", "foo" });
    try testing.expectEqual(@as(usize, 0), f.ctl.count(&.{"sh"}));
    try t.write("/usr/lib/systemd/system/foo.service", "[Service]\nExecStart=/usr/bin/foo --changed\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.ctl.count(&.{"sh"}));
    try h.expectContains(marker.parse(try t.read(services ++ "/foo/service/run")).?.rest, "/usr/bin/foo --changed");
}

test "disable removes the links and keeps the bundle" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCalls(&.{&.{ "system-control", "disable", "foo" }});
    try h.expectContains(t.stderr(), "Removed '/etc/service-bundles/targets/multi-user/wants/foo'.");
    try testing.expect(t.exists(services ++ "/foo/service/run"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.ctl.calls.items.len);
}

test "an enable that links nothing fails, though system-control exited 0" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.ctl.enable_fails_silently = true;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "system-control did not link the service into multi-user");
}

test "a failing converter fails the enable and leaves no bundle" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try t.write("/usr/lib/systemd/system/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    f.ctl.fail_commands = &.{"enable"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "Failed to enable foo.service");
}

test "in a root the tools of nosh do not reach, conversion and enabling are refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.n.real_root_override = false;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "nosh converts units where its tools run");
    try testing.expect(t.exists(records ++ "/foo"));
    try testing.expectEqual(@as(usize, 0), f.ctl.calls.items.len);
}

test "the index records the record and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/nosh/index"), records ++ "/foo");
    try t.fs.deleteFile("/var/lib/fake-systemd/nosh/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(records ++ "/foo"));
    try testing.expect(!t.exists(services ++ "/foo"));
    try testing.expect(t.exists(services ++ "/syslog/service/run"));
}

test "a template instance is a bundle named name@instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try f.expectCall(0, &.{ "sh", "-c", convert_script, "nosh-convert", "/usr/lib/systemd/system", services, "tpl@one.service" });
    try f.expectCall(1, &.{ "system-control", "enable", "tpl@one" });
    try testing.expect(t.exists(services ++ "/tpl@one/service/run"));
}

test "a user unit is refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "nosh services of a user are not supported");
}

test "a native bundle with the same program is used, and a converted bundle is not taken for a native one" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/sbin/syslogd -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try t.write(services ++ "/syslog/wanted-by/.KEEP", "", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "syslog" }));
    try f.expectCall(0, &.{ "system-control", "status", "syslog" });
    try f.expectCall(1, &.{ "system-control", "start", "syslog" });
    try testing.expectEqual(@as(usize, 0), f.ctl.count(&.{"sh"}));
    try testing.expect(!t.exists(records ++ "/syslog"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.write("/usr/lib/systemd/system/twin.service", "[Service]\nExecStart=/usr/bin/foo --run\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "twin" }));
    try testing.expect(t.exists(records ++ "/twin"));
}

// ---- runtime control ----------------------------------------------------------------------------

test "start converts, starts and follows a service; stop stops it; restart does both" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "sh", "-c", convert_script, "nosh-convert", "/usr/lib/systemd/system", services, "foo.service" });
    try f.expectCall(1, &.{ "system-control", "status", "foo" });
    try f.expectCall(2, &.{ "system-control", "start", "foo" });
    try f.expectCall(3, &.{ "system-control", "status", "foo" });
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{&.{ "system-control", "stop", "foo" }});
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(0, &.{ "system-control", "stop", "foo" });
    try f.expectCall(2, &.{ "system-control", "start", "foo" });
}

test "stop of a service without a bundle calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.ctl.calls.items.len);
}

test "a oneshot that failed fails the start, and one still starting is not waited for forever" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.ctl.after_start = world.done_failed_text;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "the command failed");
    f.ctl.after_start = "x: \n\tState   : starting since y\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.ctl.after_start = world.failed_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.ctl.fail_commands = &.{"start"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
}

test "reload runs the executor for a generated service and hangs up a native one" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "rel", "", "ExecReload=/usr/bin/rel --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "rel" }));
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "rel" }));
    try f.expectCalls(&.{&.{ "/usr/bin/fake-systemd", "--exec", "rel.service", "--phase", "reload" }});
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/sbin/syslogd -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCalls(&.{&.{ "system-control", "hangup", "syslog" }});
}

test "kill signals the main process that status reports" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    try f.state("foo", world.running_text);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGUSR1", "foo" }));
    try f.expectCalls(&.{ &.{ "system-control", "status", "foo" }, &.{ "kill", "-s", "USR1", "4242" } });
}

test "status reports the states of nosh as systemd states" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { []const u8, []const u8, u8 }{
        .{ world.running_text, "active\n", 0 },
        .{ world.stopped_text, "inactive\n", 3 },
        .{ world.failed_text, "failed\n", 3 },
        .{ world.done_failed_text, "failed\n", 3 },
        .{ "x: \n\tState   : done since y\n\t     Ran: exit 0 at z\n", "inactive\n", 3 },
        .{ "x: \n\tState   : ready since y\n", "active\n", 0 },
        .{ "x: \n\tState   : starting since y\n", "activating\n", 3 },
        .{ "x: \n\tState   : stopping since y\n", "deactivating\n", 3 },
    };
    for (cases) |c| {
        try f.state("foo", c[0]);
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "nosuch" }));
    try f.state("foo", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4242");
}

test "daemon-reload converts a changed unit and removes the bundle of a unit that is gone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.write("/usr/lib/systemd/system/foo.service", "[Service]\nExecStart=/usr/bin/foo --changed\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 1), f.ctl.count(&.{"sh"}));
    try h.expectContains(marker.parse(try t.read(services ++ "/foo/service/run")).?.rest, "/usr/bin/foo --changed");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(services ++ "/foo"));
    try testing.expect(t.exists(services ++ "/syslog"));
}

test "dry-run prints the commands and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would run: system-control enable foo");
    try h.expectContains(t.stdout(), "would run: system-control start foo");
    try testing.expectEqual(@as(usize, 0), f.ctl.calls.items.len);
    try testing.expect(!t.exists(services ++ "/foo"));
}

test "poweroff reboot and halt ask system-control" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCalls(&.{ &.{ "system-control", "poweroff" }, &.{ "system-control", "reboot" }, &.{ "system-control", "halt" } });
}

test "reverting a service removes its record, and the bundle follows at the next reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expect(!t.exists(records ++ "/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(services ++ "/foo"));
    _ = targets;
}

test "a start converts the generated services its bundle wants" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "web", "Requires=dbus.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "web" }));
    try testing.expect(t.exists(records ++ "/dbus"));
    try testing.expect(!t.exists(services ++ "/dbus"));
    try t.write(services ++ "/web/wants/dbus", "", 0o644);
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "web" }));
    try f.expectCall(0, &.{ "sh", "-c", convert_script, "nosh-convert", "/usr/lib/systemd/system", services, "dbus.service" });
    try testing.expectEqual(@as(usize, 1), f.ctl.count(&.{"sh"}));
    try testing.expect(t.exists(services ++ "/dbus/service/run"));
}

test "a start waits out the moment a service changes state, but not forever" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.state("foo", "x: \n\tState   : failed since y\n");
    f.ctl.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(f.ctl.count(&.{ "system-control", "status", "foo" }) > 2);
    try testing.expectEqual(@as(usize, 1), f.ctl.count(&.{ "system-control", "start", "foo" }));
}

test "a bundle without record is removed only when the converter left both the marker and the hash file in it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const a = t.a();
    const run_text = try marker.compose(a, "stale.service", "/s/stale.service", 1, "g", "#!/bin/nosh\nexec x\n");
    try t.write(services ++ "/stale/service/run", run_text, 0o755);
    try t.write(services ++ "/stale/service/precious", "keep\n", 0o644);
    try t.write(services ++ "/gone/service/run", run_text, 0o755);
    try t.write(services ++ "/gone/fake-systemd.hash", "abc\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(services ++ "/stale/service/precious"));
    try testing.expect(!t.exists(services ++ "/gone"));
    try testing.expect(t.exists(services ++ "/syslog/service/run"));
}

test "a pid that status reports is never init" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.state("foo", "/etc/service-bundles/services/foo: \n\tState   : running since 2026-10-26 19:53:45 +0000; 2s ago\n\tMain PID: 1\n\tConfig  : enabled\n");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "SIGUSR1", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.ctl.count(&.{"kill"}));
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
    f.ctl.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "reload", "ldap" });
    try f.expectCalls(&.{&.{ "/bin/sh", "-c", ldap_script, "/usr/bin/fake-systemd", "--exec", "ldap.service", "--phase", "reload" }});
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}

test "two units that map to the same service are not both generated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(records ++ "/foo", try marker.compose(t.a(), "bar.service", "/x", 1, "fake-systemd 0.1.0 nosh/1", "directory /x\n"), 0o644);
    try testing.expect(t.run(&.{ "enable", "foo" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
    try h.expectContains(try t.read(records ++ "/foo"), "# Unit: bar.service\n");
}

test "a record that cannot be read is an error, and the bundle it belongs to is not removed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const run_text = try marker.compose(t.a(), "gone.service", "/s/gone.service", 1, "g", "#!/bin/nosh\nexec x\n");
    try t.write(services ++ "/gone/service/run", run_text, 0o755);
    try t.write(services ++ "/gone/fake-systemd.hash", "abc\n", 0o644);
    try t.write(records ++ "/gone", "x\n", 0o644);
    const file = try t.fs.root.openFile(testing.io, "etc/service-bundles/fake-systemd/gone", .{ .mode = .read_write });
    defer file.close(testing.io);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, (1 << 16) + 1)));
    try testing.expect(t.run(&.{"daemon-reload"}) != 0);
    try testing.expect(t.exists(services ++ "/gone/service/run"));
}
