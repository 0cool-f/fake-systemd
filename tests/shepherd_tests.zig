// SPDX-License-Identifier: GPL-3.0-or-later
//! The Shepherd backend behind the real `ops` entry point, with a runner that answers like `herd`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("shepherd_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const available = "/etc/shepherd/available";
const enabled = "/etc/shepherd/init.d";
const config = "/etc/shepherd.scm";

const Fixture = struct {
    t: h.Harness = undefined,
    s: world.shepherd = undefined,
    herd: world.Herd = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        f.herd = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "shepherd";
    }

    fn bind(f: *Fixture) void {
        world.use(&f.t, &f.s);
        f.t.backend_override = f.s.backend();
        f.t.runner_override = f.herd.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.herd.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.herd.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn expectCalls(f: *Fixture, expected: []const []const []const u8) !void {
        for (expected, 0..) |call, i| try f.expectCall(i, call);
        if (f.herd.calls.items.len != expected.len) {
            std.debug.print("{d} calls, wanted {d}:\n{s}", .{ f.herd.calls.items.len, expected.len, try f.herd.dump(f.t.a()) });
            return error.TestUnexpectedCall;
        }
    }

    fn link(f: *Fixture, path: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        return f.t.a().dupe(u8, try f.t.fs.readLink(path, &buf));
    }

    fn scm(f: *Fixture, name: []const u8) ![]const u8 {
        const text = try f.t.read(try std.fmt.allocPrint(f.t.a(), "{s}/{s}.scm", .{ available, name }));
        return marker.parse(text).?.rest;
    }

    fn known(f: *Fixture, ident: []const u8, text: []const u8) !void {
        try f.herd.known.append(f.t.a(), .{ .ident = ident, .text = text });
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

test "enable generates the file, links it in init.d and writes the loader that starts it at boot" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(available ++ "/foo.scm")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 shepherd/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!\n", parsed.shebang);
    try testing.expect(std.mem.startsWith(u8, parsed.rest, "!#\n(use-modules (shepherd service))\n"));
    try h.expectContains(parsed.rest, "'(\"/usr/bin/fake-systemd\" \"--exec\" \"foo.service\" \"--log\")");
    try testing.expectEqualStrings("../available/foo.scm", try f.link(enabled ++ "/foo.scm"));
    try h.expectContains(t.stderr(), "Created symlink '/etc/shepherd/init.d/foo.scm' -> '../available/foo.scm'.");
    try h.expectContains(try t.read(config), "(scandir dir)");
    try h.expectContains(try t.read(config), "\"/etc/shepherd/init.d\"");
    try testing.expectEqual(@as(usize, 0), f.herd.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
}

test "a configuration that does not load init.d is left alone and the loader is written beside it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(config, "(use-modules (shepherd service))\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("(use-modules (shepherd service))\n", try t.read(config));
    try h.expectContains(t.stderr(), "does not load /etc/shepherd/init.d");
    try h.expectContains(try t.read(config ++ ".loader"), "(scandir dir)");
    try t.write(config, "(load \"/etc/shepherd/init.d/foo.scm\")\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "dbus" }));
}

test "offline enable and disable change only the links" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("../available/foo.scm", try f.link(enabled ++ "/foo.scm"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/shepherd/init.d/foo.scm'.");
    try testing.expect(t.exists(available ++ "/foo.scm"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(usize, 0), f.herd.calls.items.len);
}

test "on Guix System enable and disable only say that the declaration has to change" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/run/current-system/.KEEP", "", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "enabling needs a change of the operating-system declaration");
    try testing.expectError(error.FileNotFound, t.fs.lstat(enabled ++ "/foo.scm"));
    try testing.expect(!t.exists(config));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "disabling needs a change of the operating-system declaration");
    f.herd.known.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(1, &.{ "herd", "load", "root", available ++ "/foo.scm" });
}

test "the index records the file and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/shepherd/index"), available ++ "/foo.scm");
    try t.fs.deleteFile("/var/lib/fake-systemd/shepherd/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(available ++ "/foo.scm"));
    try testing.expect(t.exists(enabled ++ "/syslog.scm"));
}

test "Requires= becomes #:requirement and Wants= is not expressed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "web", "Requires=dbus.service postgresql.service\nWants=ghost.service\nAfter=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "web" }));
    const text = try f.scm("web");
    try h.expectContains(text, "#:requirement '(dbus postgresql)\n");
    try h.expectContains(text, ";; Wants= has no counterpart in Shepherd and is not expressed\n");
    try testing.expect(t.exists(available ++ "/dbus.scm"));
}

test "the network target becomes the network service of the profile when it exists" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(enabled ++ "/networking.scm", "(register-services (list (service '(networking) #:start (make-forkexec-constructor '(\"/usr/bin/net\")))))\n", 0o644);
    try addSvc(t, "net1", "After=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "net1" }));
    try h.expectContains(try f.scm("net1"), "#:requirement '(networking)\n");
}

test "a template instance is a service named name-instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists(enabled ++ "/tpl-one.scm"));
    try h.expectContains(try f.scm("tpl-one"), "(service '(tpl-one)");
    try h.expectContains(try f.scm("tpl-one"), "\"--exec\" \"tpl@one.service\"");
}

test "a user service lives in the configuration of the user and its executor takes --user" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\nExecReload=/usr/bin/foo --reload\n[Install]\nWantedBy=default.target\n", 0o644);
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    f.bind();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "foo" }));
    const base = "/home/tester/.config/shepherd";
    try h.expectContains(marker.parse(try t.read(base ++ "/available/foo.scm")).?.rest, "\"--exec\" \"foo.service\" \"--user\" \"--log\"");
    try testing.expectEqualStrings("../available/foo.scm", try f.link(base ++ "/init.d/foo.scm"));
    try h.expectContains(try t.read(base ++ "/init.scm"), "/home/tester/.config/shepherd/init.d");
    try f.known("foo", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "reload", "foo" }));
    try f.expectCall(0, &.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--user", "--phase", "reload" });
}

test "an account the executor cannot resolve is given to it as numeric ids that a shell looks up" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=ldapuser");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    try h.expectContains(try f.scm("ldap"), "'(\"/bin/sh\" \"-c\" \"exec \\\"$0\\\" \\\"$@\\\" --uid \\\"$(id -u -- ldapuser)\\\" --gid \\\"$(id -g -- ldapuser)\\\" --groups \\\"$(id -G -- ldapuser | tr ' ' ,)\\\"\" \"/usr/bin/fake-systemd\" \"--exec\" \"ldap.service\" \"--log\")");
    try h.expectNotContains(try f.scm("ldap"), "setpriv");
    try addSvc(t, "appsvc", "", "User=app");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "appsvc" }));
    try h.expectContains(try f.scm("appsvc"), "'(\"/usr/bin/fake-systemd\" \"--exec\" \"appsvc.service\" \"--log\")");
}

test "oneshots, remaining oneshots and hooks have their own shapes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/kept.service", "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/job\nExecStop=/usr/bin/job --off\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/job", "#!/bin/sh\n", 0o755);
    try addSvc(t, "hooked", "", "ExecStop=/usr/bin/hooked --stop\nExecStopPost=/usr/bin/cleanup\nTimeoutStopSec=8");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job", "kept", "hooked" }));
    const job = try f.scm("job");
    try h.expectContains(job, "#:one-shot? #t\n");
    try h.expectContains(job, "(eqv? 0 (status:exit-val");
    const kept = try f.scm("kept");
    try h.expectNotContains(kept, "one-shot");
    try h.expectContains(kept, "\"--phase\" \"stop\"");
    const hooked = try f.scm("hooked");
    try h.expectContains(hooked, "\"--log\" \"--stop-on-signal\"");
    try h.expectContains(hooked, "(terminate-process (process-id process) SIGTERM #:grace-period 8)");
    try h.expectContains(hooked, "\"--phase\" \"stop-post\"");
}

test "dry-run prints what it would change and runs nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would create symlink '/etc/shepherd/init.d/foo.scm' -> '../available/foo.scm'\n");
    try h.expectContains(t.stdout(), "would run: herd");
    try testing.expectEqual(@as(usize, 0), f.herd.calls.items.len);
    try testing.expect(!t.exists(available ++ "/foo.scm"));
    try testing.expect(!t.exists(config));
}

// ---- runtime control ----------------------------------------------------------------------------

test "start loads a service Shepherd does not know, then starts it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" },
        &.{ "herd", "load", "root", available ++ "/foo.scm" },
        &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" },
        &.{ "herd", "start", "foo" },
    });
}

test "start of a loaded service only asks herd, and a disabled one is enabled first" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.stopped_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }, &.{ "herd", "start", "foo" } });
    f.herd.calls.clearRetainingCapacity();
    f.herd.known.items[0].text = world.disabled_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }, &.{ "herd", "enable", "foo" }, &.{ "herd", "start", "foo" } });
}

test "the services a started one requires are loaded first" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "web", "Requires=dbus.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "web" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "web" }));
    try f.expectCall(0, &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "dbus" });
    try f.expectCall(1, &.{ "herd", "load", "root", available ++ "/dbus.scm" });
    try f.expectCall(2, &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "web" });
    try f.expectCall(3, &.{ "herd", "load", "root", available ++ "/web.scm" });
}

test "a failing herd fails start, stop, restart and reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.running_text);
    f.herd.fail_commands = &.{"start"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    f.herd.fail_commands = &.{"stop"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
    f.herd.fail_commands = &.{"restart"};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "restart", "foo" }));
}

test "stop of a service Shepherd knows follows it until it ends, and of one it does not know calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{&.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }});
    try f.known("foo", world.running_text);
    f.herd.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }, &.{ "herd", "stop", "foo" }, &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" } });
}

test "restart loads a generated file again so that a change applies" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCalls(&.{
        &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" },
        &.{ "herd", "load", "root", available ++ "/foo.scm" },
        &.{ "herd", "restart", "foo" },
    });
}

test "reload runs the executor for a generated service and asks herd for a native one" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "rel", "", "ExecReload=/usr/bin/rel --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "rel" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "rel" }));
    try f.expectCalls(&.{&.{ "/usr/bin/fake-systemd", "--exec", "rel.service", "--phase", "reload" }});
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/sbin/syslogd -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try f.known("syslogd", world.running_text);
    f.herd.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCalls(&.{&.{ "herd", "reload", "syslogd" }});
}

test "a native service is controlled by the name its definition provides" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/syslog.service", "[Service]\nExecStart=/usr/sbin/syslogd -n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try f.known("syslogd", world.stopped_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "syslog" }));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "syslogd" }, &.{ "herd", "start", "syslogd" } });
    try testing.expect(!t.exists(available ++ "/syslog.scm"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "syslog" }));
}

test "kill signals the main process that herd reports" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    try f.known("foo", world.running_text);
    f.herd.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGUSR1", "foo" }));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }, &.{ "kill", "-s", "USR1", "4242" } });
}

test "status reports the states of Shepherd as systemd states" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { []const u8, []const u8, u8 }{
        .{ world.running_text, "active\n", 0 },
        .{ world.stopped_text, "inactive\n", 3 },
        .{ world.disabled_text, "failed\n", 3 },
        .{ "Status of foo:\n  It is stopped since 19:22:05 (0 seconds ago).\n  Process terminated with signal 15.\n", "inactive\n", 3 },
        .{ "Status of foo:\n  It is stopped (one-shot).\n", "inactive\n", 3 },
        .{ "Status of foo:\n  It is starting.\n", "activating\n", 3 },
        .{ "Status of foo:\n  It is started.\n", "active\n", 0 },
    };
    for (cases) |c| {
        f.herd.known.clearRetainingCapacity();
        try f.known("foo", c[0]);
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.herd.known.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try f.known("foo", world.running_text);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4242");
}

test "daemon-reload loads the files of the services Shepherd runs again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.known("foo", world.running_text);
    f.herd.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCalls(&.{ &.{ "sh", "-c", world.shepherd.status_script, "herd-status", "foo" }, &.{ "herd", "load", "root", available ++ "/foo.scm" } });
    f.herd.fail_commands = &.{"load"};
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "could not load the service file again");
}

test "poweroff reboot and halt ask herd, or the reboot command" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCalls(&.{ &.{ "herd", "power-off" }, &.{"reboot"}, &.{ "herd", "halt" } });
}

test "reverting a service removes its link and generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expect(!t.exists(available ++ "/foo.scm"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(enabled ++ "/foo.scm"));
}

test "the reload of an account the executor cannot resolve carries the same numeric ids" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=ldapuser\nExecReload=/usr/bin/ldap --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    f.herd.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "ldap" }));
    try f.expectCalls(&.{
        &.{ "/bin/sh", "-c", "exec \"$0\" \"$@\" --uid \"$(id -u -- ldapuser)\" --gid \"$(id -g -- ldapuser)\" --groups \"$(id -G -- ldapuser | tr ' ' ,)\"", "/usr/bin/fake-systemd", "--exec", "ldap.service", "--phase", "reload" },
    });
}

test "two units that map to the same Shepherd name are not both generated" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "foo-bar", "", "");
    try addSvc(t, "foo@", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo-bar" }));
    try testing.expect(t.run(&.{ "enable", "foo@bar" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
}

test "a service name with a backslash is refused, as it would close the symbol that names it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/bs\\.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expect(t.run(&.{ "enable", "bs\\" }) != 0);
    try h.expectContains(t.stderr(), "is not a name Shepherd can register");
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}
