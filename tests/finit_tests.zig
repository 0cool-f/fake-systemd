// SPDX-License-Identifier: GPL-3.0-or-later
//! The finit backend behind the real `ops` entry point, with a runner that answers like
//! `initctl`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("finit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const available = "/etc/finit.d/available";
const enabled = "/etc/finit.d/enabled";
const runtime = "/run/finit/system";
const exit_file = "/run/fake-systemd/foo.service.exit";

const crashed_text = "     Status : crashed (code=exited, status=2/INVALIDARGUMENT)\n   Identity : foo\n        PID : 0\n";
const done_text = "     Status : done (code=exited, status=0/SUCCESS)\n   Identity : foo\n        PID : 0\n";

const Fixture = struct {
    t: h.Harness = undefined,
    f: world.finit = undefined,
    ic: world.Initctl = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.ic = .{ .gpa = f.t.a(), .fs = &f.t.fs };
        f.bind();
        f.t.detected = "finit";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.f);
        f.t.backend_override = f.f.backend();
        f.t.runner_override = f.ic.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.ic.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.ic.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectCalls(f: *Fixture, expected: []const []const []const u8) !void {
        for (expected, 0..) |call, i| try f.expectCall(i, call);
        if (f.ic.calls.items.len != expected.len) {
            std.debug.print("{d} calls, wanted {d}:\n{s}", .{ f.ic.calls.items.len, expected.len, try f.ic.dump(f.t.a()) });
            return error.TestUnexpectedCall;
        }
    }

    fn link(f: *Fixture, path: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        return f.t.a().dupe(u8, try f.t.fs.readLink(path, &buf));
    }

    fn conf(f: *Fixture, name: []const u8) ![]const u8 {
        const text = try f.t.read(try std.fmt.allocPrint(f.t.a(), "{s}/{s}.conf", .{ available, name }));
        return marker.parse(text).?.rest;
    }

    fn known(f: *Fixture, ident: []const u8, text: []const u8) !void {
        try f.ic.known.append(f.t.a(), .{ .ident = ident, .text = text });
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

test "enable generates the file, links it in enabled/ and runs nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(available ++ "/foo.conf")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 finit/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("", parsed.shebang);
    try testing.expectEqualStrings(
        "service [2345] name:foo norestart /usr/bin/fake-systemd --exec foo.service --log -- Unit foo.service\n",
        parsed.rest,
    );
    try testing.expectEqualStrings("../available/foo.conf", try f.link(enabled ++ "/foo.conf"));
    try h.expectContains(t.stderr(), "Created symlink '/etc/finit.d/enabled/foo.conf' -> '../available/foo.conf'.");
    try testing.expectEqual(@as(usize, 0), f.ic.calls.items.len);

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.ic.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
}

test "offline enable and disable change only the links" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("../available/foo.conf", try f.link(enabled ++ "/foo.conf"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/finit.d/enabled/foo.conf'.");
    try testing.expectError(error.FileNotFound, t.fs.lstat(enabled ++ "/foo.conf"));
    try testing.expect(t.exists(available ++ "/foo.conf"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(usize, 0), f.ic.calls.items.len);
}

test "the index records the file and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/finit/index"), available ++ "/foo.conf");

    try t.fs.deleteFile("/var/lib/fake-systemd/finit/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(available ++ "/foo.conf"));
    try testing.expect(t.exists(available ++ "/syslog.conf"));
}

test "enabling a service also enables the services its conditions name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "web", "Requires=dbus.service postgresql.service\nWants=ghost.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "web" }));
    try h.expectContains(try f.conf("web"), "<service/dbus/running,service/postgresql/running>");
    for ([_][]const u8{ "web", "dbus", "postgresql" }) |name| {
        try testing.expectEqualStrings(try std.fmt.allocPrint(t.a(), "../available/{s}.conf", .{name}), try f.link(try std.fmt.allocPrint(t.a(), "{s}/{s}.conf", .{ enabled, name })));
    }
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "web" }));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enabled ++ "/web.conf"));
    try testing.expect(t.exists(enabled ++ "/dbus.conf"));
}

test "a dependency that is a task is waited for by its success" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/prep.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/prep\n", 0o644);
    try t.write("/usr/bin/prep", "#!/bin/sh\n", 0o755);
    try addSvc(t, "web", "Requires=prep.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "web" }));
    try h.expectContains(try f.conf("web"), "<task/prep/success>");
    try h.expectContains(try f.conf("prep"), "task [2345] name:prep ");
}

test "network-online.target becomes the default route condition and network.target nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "net1", "After=network-online.target", "");
    try addSvc(t, "net2", "After=network.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "net1", "net2" }));
    try h.expectContains(try f.conf("net1"), "service [2345] <net/route/default> name:net1");
    try h.expectContains(try f.conf("net2"), "service [2345] name:net2");
}

test "a native service in available/ is enabled by a link and a static one is already enabled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const unit = "[Service]\nExecStart={s} -n\n[Install]\nWantedBy=multi-user.target\n";
    try t.write("/usr/lib/systemd/system/crond.service", try std.fmt.allocPrint(t.a(), unit, .{"/usr/sbin/crond"}), 0o644);
    try t.write("/usr/lib/systemd/system/syslog.service", try std.fmt.allocPrint(t.a(), unit, .{"/usr/sbin/syslogd"}), 0o644);
    try t.write("/usr/sbin/crond", "#!/bin/sh\n", 0o755);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "crond" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "syslog" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "syslog" }));
    try testing.expectEqualStrings("../available/syslog.conf", try f.link(enabled ++ "/syslog.conf"));
    try h.expectNotContains(try t.read(available ++ "/syslog.conf"), "Generated automatically");
}

test "a static service cannot be disabled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/crond.service", "[Service]\nExecStart=/usr/sbin/crond -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/crond", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "disable", "crond" }));
    try h.expectContains(t.stderr(), "a static service in /etc/finit.d cannot be disabled");
    try testing.expect(t.exists("/etc/finit.d/crond.conf"));
}

test "enable --runtime warns and enables persistently" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--runtime", "foo" }));
    try h.expectContains(t.stderr(), "--runtime is not supported by the finit backend");
    try testing.expect(t.exists(enabled ++ "/foo.conf"));
}

test "a template instance is a service named name-instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists(enabled ++ "/tpl-one.conf"));
    try h.expectContains(try f.conf("tpl-one"), "name:tpl-one ");
    try h.expectContains(try f.conf("tpl-one"), "--exec tpl@one.service ");
}

test "units a stanza cannot express are refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "finit has no service manager for users");
}

test "an account the executor cannot resolve is switched by setpriv, and the reload runs behind it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=ldapuser\nExecReload=/usr/bin/ldap --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    try h.expectContains(try f.conf("ldap"), "/usr/bin/setpriv --reuid=ldapuser \"--regid=$(id -g ldapuser)\" --init-groups /usr/bin/fake-systemd --exec ldap.service --log");
    try f.known("ldap", world.running_text);
    f.ic.known.items[0].text = world.running_text;
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "ldap" }));
    try f.expectCalls(&.{
        &.{ "id", "-g", "ldapuser" },
        &.{ "/usr/bin/setpriv", "--reuid=ldapuser", "--regid=" ++ world.group_id, "--init-groups", "/usr/bin/fake-systemd", "--exec", "ldap.service", "--phase", "reload" },
    });
}

test "an account the executor resolves needs no wrapper, and without setpriv the unit is refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "appsvc", "", "User=app");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "appsvc" }));
    try h.expectContains(try f.conf("appsvc"), "norestart /usr/bin/fake-systemd --exec appsvc.service");
    try t.fs.deleteFile("/usr/bin/setpriv");
    try addSvc(t, "ldap", "", "User=ldapuser");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "ldap" }));
    try h.expectContains(t.stderr(), "setpriv is needed to switch to ldapuser");
}

test "stop hooks and runtime directories add the stop-post script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hooked", "", "ExecStop=/usr/bin/hooked --stop\nExecStopPost=/usr/bin/cleanup\nTimeoutStopSec=8");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooked" }));
    const text = try f.conf("hooked");
    try h.expectContains(text, " kill:8 post:/etc/finit.d/available/hooked.stop-post /usr/bin/fake-systemd --exec hooked.service --log --stop-on-signal ");
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(available ++ "/hooked.stop-post")).mode);
    try testing.expect(h.contains(try t.read(available ++ "/hooked.stop-post"), "--exec 'hooked.service' --phase stop-post"));
}

test "a stanza longer than finit reads is refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    var after: std.ArrayList(u8) = .empty;
    try after.appendSlice(t.a(), "Requires=");
    for (0..40) |i| {
        const dep = try std.fmt.allocPrint(t.a(), "dependency-with-a-long-name-{d:0>3}", .{i});
        try addSvc(t, dep, "", "");
        try after.print(t.a(), "{s}.service ", .{dep});
    }
    try addSvc(t, "huge", after.items, "");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "huge" }));
    try h.expectContains(t.stderr(), "the stanza is longer than finit reads");
}

test "dry-run prints what it would change and runs nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would create symlink '/etc/finit.d/enabled/foo.conf' -> '../available/foo.conf'\n");
    try h.expectContains(t.stdout(), "would run: initctl");
    try testing.expectEqual(@as(usize, 0), f.ic.calls.items.len);
    try testing.expect(!t.exists(available ++ "/foo.conf"));
    try testing.expect(!t.exists(runtime ++ "/foo.conf"));
}

// ---- runtime control ----------------------------------------------------------------------------

test "start of an enabled service that finit has not read asks for a reload and no link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.ic.on_reload = &.{.{ .ident = "foo", .text = world.stopped_text }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "reload" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "start", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
    });
    try testing.expectError(error.FileNotFound, t.fs.lstat(runtime ++ "/foo.conf"));
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "stop", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
    });
}

test "start loads a service that is not enabled through a link, and stop unloads it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.ic.on_reload = &.{.{ .ident = "foo", .text = world.stopped_text }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "reload" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "start", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
    });
    try testing.expectEqualStrings(available ++ "/foo.conf", try f.link(runtime ++ "/foo.conf"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));

    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "stop", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "reload" },
    });
    try testing.expectError(error.FileNotFound, t.fs.lstat(runtime ++ "/foo.conf"));
}

test "start of a service that is loaded only asks initctl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.stopped_text);
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
        &.{ "initctl", "start", "foo" },
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" },
    });
    try testing.expectError(error.FileNotFound, t.fs.lstat(runtime ++ "/foo.conf"));
}

test "start succeeds for a service that exits at once, and fails when finit cannot run it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", crashed_text);
    f.ic.after_start = crashed_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    f.ic.after_start = "     Status : missing\n   Identity : foo\n        PID : 0\n";
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "cannot run the command");
    f.ic.fail_commands = &.{"start"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
}

test "start of a service that waits for a condition fails after the wait" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const waiting = "     Status : waiting\n   Identity : foo\n        PID : 0\n";
    try f.known("foo", waiting);
    f.ic.after_start = waiting;
    f.f.start_wait_ms = 300;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "still waiting after");
}

test "the services a started one waits for are loaded with it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "web", "Requires=dbus.service", "");
    f.ic.on_reload = &.{ .{ .ident = "dbus" }, .{ .ident = "web" } };
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "web" }));
    try testing.expectEqualStrings(available ++ "/web.conf", try f.link(runtime ++ "/web.conf"));
    try testing.expectEqualStrings(available ++ "/dbus.conf", try f.link(runtime ++ "/dbus.conf"));
    try testing.expectEqual(@as(usize, 1), f.ic.count(&.{ "initctl", "reload" }));
}

test "stop of a service finit does not know calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{&.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" }});
}

test "restart restarts a loaded service and starts one that is not" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.running_text);
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(0, &.{ "sh", "-c", world.finit.status_script, "initctl-status", "foo" });
    try f.expectCall(1, &.{ "initctl", "restart", "foo" });
    f.ic.known.clearRetainingCapacity();
    f.ic.on_reload = &.{.{ .ident = "foo" }};
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.ic.count(&.{ "initctl", "reload" }));
    try testing.expectEqual(@as(usize, 0), f.ic.count(&.{ "initctl", "restart" }));
}

test "a oneshot runs again and its recorded end decides the result" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    try h.expectContains(try f.conf("job"), "task [2345] name:job /usr/bin/fake-systemd --exec job.service --log --record-exit -- ");
    try testing.expect(h.contains(try t.read(available ++ "/job.conf"), "# flags: transient\n"));
    try f.ic.known.append(t.a(), .{ .ident = "job", .text = done_text });
    f.ic.exit_file = .{ .path = "/run/fake-systemd/job.service.exit", .text = "ok 0\n" };
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "job" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.finit.status_script, "initctl-status", "job" },
        &.{ "initctl", "reload", "job" },
    });
    f.ic.exit_file = .{ .path = "/run/fake-systemd/job.service.exit", .text = "failed 3\n" };
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "job" }));
    try h.expectContains(t.stderr(), "Failed to start job.service");
}

test "a oneshot that stays active after success reads active, otherwise inactive" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/kept.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job", "kept" }));
    try f.ic.known.append(t.a(), .{ .ident = "job", .text = done_text });
    try f.ic.known.append(t.a(), .{ .ident = "kept", .text = done_text });
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "job" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "kept" }));
}

test "reload runs the executor for a generated service and asks initctl for a native one" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "rel", "", "ExecReload=/usr/bin/rel --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "rel" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "rel" }));
    try f.expectCalls(&.{&.{ "/usr/bin/fake-systemd", "--exec", "rel.service", "--phase", "reload" }});
    try f.known("syslogd", world.running_text);
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/sbin/syslogd -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCalls(&.{&.{ "initctl", "reload", "syslogd" }});
}

test "a native service is controlled by the identity its file declares" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(available ++ "/ssh.conf", "service [2345] name:sshd /usr/sbin/sshd -D -- OpenSSH\n", 0o644);
    try t.write("/usr/sbin/sshd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/sshd.service", "[Service]\nExecStart=/usr/sbin/sshd -D\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try f.known("sshd", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "sshd" }));
    try f.expectCall(1, &.{ "initctl", "restart", "sshd" });
    try testing.expect(!t.exists(available ++ "/sshd.conf"));
}

test "kill signals the service with the name of the signal" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.running_text);
    f.ic.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGUSR1", "foo" }));
    try f.expectCalls(&.{&.{ "initctl", "signal", "foo", "USR1" }});
}

test "status reports the states of finit as systemd states" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { []const u8, []const u8, u8 }{
        .{ world.running_text, "active\n", 0 },
        .{ world.stopped_text, "inactive\n", 3 },
        .{ crashed_text, "failed\n", 3 },
        .{ "     Status : crashed (code=exited, status=0/SUCCESS)\n        PID : 0\n", "inactive\n", 3 },
        .{ "     Status : restart (code=exited, status=1/FAILURE)\n        PID : 0\n", "activating\n", 3 },
        .{ "     Status : stopping\n        PID : 12\n", "deactivating\n", 3 },
    };
    for (cases) |c| {
        f.ic.known.clearRetainingCapacity();
        try f.known("foo", c[0]);
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.ic.known.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try f.known("foo", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4242");
}

test "daemon-reload asks finit to read the files again, and a failure only warns" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCalls(&.{&.{ "initctl", "reload" }});
    f.ic.fail_commands = &.{"reload"};
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "initctl reload failed");
}

test "poweroff reboot and halt ask initctl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCalls(&.{ &.{ "initctl", "poweroff" }, &.{ "initctl", "reboot" }, &.{ "initctl", "halt" } });
}

test "reverting a service removes its link and generated files" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expect(!t.exists(available ++ "/foo.conf"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enabled ++ "/foo.conf"));
}

test "a tool that is not installed fails the command" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.ic.fail_commands = &.{"stop"};
    try f.known("foo", world.running_text);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
}
