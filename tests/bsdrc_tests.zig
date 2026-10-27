// SPDX-License-Identifier: GPL-3.0-or-later
//! The BSD-style rc backend behind the real `ops` entry point, with a runner that answers like
//! the rc scripts, and the golden scripts of the corpus.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("bsdrc_world.zig");
const dinit_world = @import("dinit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const rc_d = "/etc/rc.d";

const Fixture = struct {
    t: h.Harness = undefined,
    b: world.bsdrc = undefined,
    sc: world.Script = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populateBsdRc(&f.t);
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "bsd-rc";
    }

    fn bind(f: *Fixture) void {
        world.useBsdRc(&f.t, &f.b);
        f.t.backend_override = f.b.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn executable(f: *Fixture, path: []const u8) bool {
        const st = f.t.fs.stat(path) catch return false;
        return st.mode & 0o111 != 0;
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

    fn status(f: *Fixture, service: []const u8, code: u8, stdout: []const u8) void {
        const a = f.t.a();
        const path = std.fmt.allocPrint(a, "{s}/rc.{s}", .{ rc_d, service }) catch @panic("out of memory");
        const prefix = a.dupe([]const u8, &.{ path, "status" }) catch @panic("out of memory");
        const rule: world.Rule = .{ .prefix = prefix, .code = code, .stdout = stdout };
        f.sc.rules = std.mem.concat(a, world.Rule, &.{ f.sc.rules, &.{rule} }) catch @panic("out of memory");
    }

    /// The generated script of `service` without its marker, behind a newline.
    fn script(f: *Fixture, service: []const u8) ![]const u8 {
        const rest = marker.parse(try f.t.read(try std.fmt.allocPrint(f.t.a(), "{s}/rc.{s}", .{ rc_d, service }))).?.rest;
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

const block_start = "# BEGIN fake-systemd\n";
const block_end = "# END fake-systemd\n";

// ---- generation and enablement ----------------------------------------------------------------

test "enable generates a disabled script, makes it executable and lists it in both hooks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(rc_d ++ "/rc.foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 bsd-rc/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/bin/sh\n", parsed.shebang);
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(rc_d ++ "/rc.foo")).mode);
    try h.expectContains(t.stderr(), "Made '/etc/rc.d/rc.foo' executable.");
    // Enabling is the execute permission and the hooks: no program runs.
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expectEqualStrings(
        world.slackware_rc_local ++ "\n" ++ block_start ++ "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo start\n" ++ block_end,
        try t.read(rc_d ++ "/rc.local"),
    );
    try testing.expectEqualStrings(
        "#!/bin/sh\n\n" ++ block_start ++ "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo stop\n" ++ block_end,
        try t.read(rc_d ++ "/rc.local_shutdown"),
    );
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
}

test "a script that was only translated is not executable, and generating it again keeps an enabled one enabled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(!f.executable(rc_d ++ "/rc.foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.write("/usr/lib/systemd/system/foo.service", "[Unit]\nDescription=changed\n[Service]\nExecStart=/usr/bin/foo --run\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(rc_d ++ "/rc.foo"), "# changed\n");
    try testing.expect(f.executable(rc_d ++ "/rc.foo"));
}

test "enable twice changes nothing, and disable clears the permission and the hooks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const local = try t.read(rc_d ++ "/rc.local");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqualStrings(local, try t.read(rc_d ++ "/rc.local"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Made '/etc/rc.d/rc.foo' not executable.");
    try testing.expect(!f.executable(rc_d ++ "/rc.foo"));
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
    // The stop hook keeps the script, whose service may still run; the start hook does not.
    try h.expectContains(try t.read(rc_d ++ "/rc.local_shutdown"), "rc.foo stop\n");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "the hooks keep what the administrator wrote and the stop hook goes with its last script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(rc_d ++ "/rc.local_shutdown", "#!/bin/sh\necho bye\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("#!/bin/sh\necho bye\n\n" ++ block_start ++ "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo stop\n" ++ block_end, try t.read(rc_d ++ "/rc.local_shutdown"));
    try t.fs.deleteFile(rc_d ++ "/rc.local_shutdown");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("#!/bin/sh\n\n" ++ block_start ++ "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo stop\n" ++ block_end, try t.read(rc_d ++ "/rc.local_shutdown"));
    // Removing the unit removes the script at the next reload and the hooks with it.
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(rc_d ++ "/rc.foo"));
    // The script is never deleted, as it may be the system's own.
    try testing.expectEqualStrings("#!/bin/sh\n", try t.read(rc_d ++ "/rc.local_shutdown"));
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
}

test "start writes the stop hook before the service runs, so that it stops at shutdown" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(!t.exists(rc_d ++ "/rc.local") or !h.contains(try t.read(rc_d ++ "/rc.local"), "rc.foo"));
    try h.expectContains(try t.read(rc_d ++ "/rc.local_shutdown"), "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo stop\n");
    // The script is not executable, so it runs through the shell.
    try f.expectCall(0, &.{ "sh", rc_d ++ "/rc.foo", "start" });
}

test "dry-run says what would change and writes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would make '/etc/rc.d/rc.foo' executable\n");
    try h.expectContains(t.stdout(), "would run: /etc/rc.d/rc.foo start\n");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(!t.exists(rc_d ++ "/rc.foo"));
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
}

test "offline enable writes the same files and calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(f.executable(rc_d ++ "/rc.foo"));
    try h.expectContains(try t.read(rc_d ++ "/rc.local"), "[ -x /etc/rc.d/rc.foo ] && /etc/rc.d/rc.foo start\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
}

test "the index records the script, and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/bsd-rc/index"), rc_d ++ "/rc.foo");
    try t.fs.deleteFile("/var/lib/fake-systemd/bsd-rc/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(rc_d ++ "/rc.foo"));
    try testing.expect(t.exists(rc_d ++ "/rc.syslog"));
}

test "a template instance is a script named rc.name.instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(f.executable(rc_d ++ "/rc.tpl.one"));
    try testing.expectEqualStrings("tpl@one.service", marker.parse(try t.read(rc_d ++ "/rc.tpl.one")).?.marker.unit);
    try h.expectContains(try t.read(rc_d ++ "/rc.local"), "[ -x /etc/rc.d/rc.tpl.one ] && /etc/rc.d/rc.tpl.one start\n");
}

test "a unit named like a boot script of the system is refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "local.service", "/usr/bin/local", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "local" }));
    try h.expectContains(t.stderr(), "rc.local is a boot script of the system, not a service");
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
}

test "user scope is refused with the reason" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "BSD-style rc has no service manager for users");
}

// ---- native scripts ---------------------------------------------------------------------------

test "a native script that starts the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(rc_d ++ "/rc.foo-daemon", "#!/bin/sh\nstart() {\n  /usr/bin/foo $OPTS\n}\ncase \"$1\" in\n'start')\n  start\n  ;;\nesac\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists(rc_d ++ "/rc.foo"));
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
    try h.expectContains(t.stderr(), "Made '/etc/rc.d/rc.foo-daemon' executable.");
    // Nothing starts it at boot: rc.M does not know the script.
    try h.expectContains(t.stderr(), "no boot script starts rc.foo-daemon; start it from rc.local");
    try f.expectCall(0, &.{ rc_d ++ "/rc.foo-daemon", "start" });
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
}

test "a native script that rc.M starts is enabled by the permission alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/syslogd.service", "[Service]\nExecStart=/usr/sbin/syslogd\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "syslogd" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "syslogd" }));
    try h.expectContains(t.stderr(), "Made '/etc/rc.d/rc.syslog' not executable.");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "syslogd" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "syslogd" }));
    try testing.expect(f.executable(rc_d ++ "/rc.syslog"));
    try h.expectNotContains(t.stderr(), "no boot script");
    // The system boot starts it, so no block is written for it.
    try testing.expectEqualStrings(world.slackware_rc_local, try t.read(rc_d ++ "/rc.local"));
    try testing.expect(!t.exists(rc_d ++ "/rc.foo") and !t.exists(rc_d ++ "/rc.syslogd"));
}

test "the state of a native script is its pid file, else a process named like its program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/syslogd.service", "[Service]\nExecStart=/usr/sbin/syslogd\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    f.sc.rules = &.{.{ .prefix = &.{ "pgrep", "-x", "syslogd" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "syslogd" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    f.sc.rules = &.{.{ .prefix = &.{ "pgrep", "-x", "syslogd" }, .code = 0, .stdout = "812\n975\n" }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "syslogd" }));
    try h.expectContains(t.stdout(), "Main PID: 812");
    // A pid file of a live process decides without asking for processes.
    try dinit_world.liveProcess(t, 900);
    try t.write("/run/syslog.pid", "900\n", 0o644);
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "syslogd" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "HUP", "syslogd" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "900" });
}

// ---- dependencies -----------------------------------------------------------------------------

test "dependencies: required scripts fail the start, wanted ones do not, and the hook orders them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service\nWants=c.service\nAfter=b.service d.service\nBefore=e.service", "");
    for ([_][]const u8{ "b", "c", "d", "e" }) |n| try addSvc(t, n, "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a", "e", "b" }));
    const body = try f.script("a");
    try h.expectContains(body, "\n# Requires: b\n# Wants: c\n# After: d\n# Before: e\n");
    try h.expectContains(body, "\nscript_dir=/etc/rc.d\n");
    try h.expectContains(body, "\n\tstart_dep b || {\n\t\techo \"a.service: cannot start\" b >&2\n\t\treturn 1\n\t}\n\tstart_dep c || :\n");
    // The dependencies the unit pulls in are generated, and started by the script, not enabled.
    for ([_][]const u8{ "b", "c" }) |dep| try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "{s}/rc.{s}", .{ rc_d, dep })));
    try testing.expect(!f.executable(rc_d ++ "/rc.c"));
    // b before a before e; d is only named in After= and has no script.
    const local = try t.read(rc_d ++ "/rc.local");
    const at_b = std.mem.find(u8, local, "rc.b start").?;
    const at_a = std.mem.find(u8, local, "rc.a start").?;
    const at_e = std.mem.find(u8, local, "rc.e start").?;
    try testing.expect(at_b < at_a and at_a < at_e);
    // Stopping goes the other way, and covers the scripts that were not enabled.
    const down = try t.read(rc_d ++ "/rc.local_shutdown");
    try testing.expect(std.mem.find(u8, down, "rc.e stop").? < std.mem.find(u8, down, "rc.a stop").?);
    try testing.expect(std.mem.find(u8, down, "rc.a stop").? < std.mem.find(u8, down, "rc.b stop").?);
    try h.expectContains(down, "rc.c stop\n");
}

test "a dependency the classifier excludes is left out, and the network targets are noted" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service\nAfter=network-online.target", "");
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/hook\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectNotContains(body, "hook");
    try h.expectNotContains(body, "start_dep");
    try h.expectContains(body, "# network.target: rc.local runs after rc.inet1 and rc.inet2, which bring the network up\n");
}

// ---- how the script runs the unit ----------------------------------------------------------------

test "a daemon is detached by the executor and stopped through its pid file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try testing.expectEqual(@as(u8, 0), f.t.run(&.{ "enable", "foo" }));
    const body = try f.script("foo");
    try h.expectContains(body, "\n\t/usr/bin/fake-systemd --exec foo.service --daemon --log --record-exit\n");
    try h.expectContains(body, "\ndaemon_pid=/run/fake-systemd/foo.service.daemon.pid\nstop_wait=100\n");
    try h.expectContains(body, "\n\tkill -TERM \"$_pid\" 2>/dev/null\n");
    try h.expectNotContains(body, "start-stop-daemon");
    try h.expectNotContains(body, "lock");
}

test "ExecStop makes the executor stop on the signal, ExecStopPost runs after the stop, ExecReload is the reload verb" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hooks", "", "ExecStop=/usr/bin/hooks stop\nExecStopPost=/usr/bin/hooks clean\nExecReload=/usr/bin/hooks reload\nTimeoutStopSec=20");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooks" }));
    const body = try f.script("hooks");
    try h.expectContains(body, "--exec hooks.service --daemon --stop-on-signal --log --record-exit\n");
    try h.expectContains(body, "\nstop_wait=30\n");
    try h.expectContains(body, "/usr/bin/fake-systemd --exec hooks.service --phase stop-post || rc=$?\n");
    try h.expectContains(body, "reload)\n\tdo_reload\n");
    try h.expectContains(body, "--exec hooks.service --phase reload\n");
    try h.expectContains(try f.script("foo"), "reload)\n\techo \"foo.service does not support reload\" >&2\n\texit 3\n");
}

test "a oneshot runs to the end in start, and one that remains keeps a state" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "job", "", "Type=oneshot\nExecStop=/usr/bin/job stop");
    try addSvc(t, "kept", "", "Type=oneshot\nRemainAfterExit=yes");
    try t.expectRun(0, &.{ "enable", "job", "kept" });
    const job = try f.script("job");
    try h.expectContains(job, "\n\t/usr/bin/fake-systemd --exec job.service --log --record-exit > /dev/null\n");
    try h.expectContains(job, "echo \"job.service has finished\"");
    try h.expectNotContains(job, "--daemon");
    const kept = try f.script("kept");
    try h.expectContains(kept, "\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n");
    try h.expectContains(kept, "is active (exited)");
}

test "an account only the system libc resolves is given to the root executor as numeric ids" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldap", "", "User=ldapuser\nGroup=ldapgrp\nSupplementaryGroups=audio");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    const body = try f.script("ldap");
    try h.expectContains(body, "\n\t/usr/bin/fake-systemd --exec ldap.service --daemon --log --record-exit --uid \"$(id -u -- ldapuser)\" --gid \"$(getent group ldapgrp | cut -d: -f3)\" --groups \"$(id -G -- ldapuser | tr ' ' ,),$(getent group audio | cut -d: -f3)\"\n");
    // The files stay root's and nothing switches before the executor.
    try h.expectNotContains(body, "chown");
    try h.expectNotContains(body, "setpriv");
    try h.expectNotContains(body, "su -s");
    try h.expectNotContains(body, "--identity-set");
}

test "an account the executor resolves needs no switch in the script" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "plain", "", "User=app\nGroup=app");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "plain" }));
    const body = try f.script("plain");
    try h.expectNotContains(body, "setpriv");
    try h.expectNotContains(body, "chown");
}

test "an account name with shell characters is refused for a switch through the system libc" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "evil", "", "User=a;touch$IFS/x");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "evil" }));
    try h.expectContains(t.stderr(), "must be plain names");
    try testing.expect(!t.exists(rc_d ++ "/rc.evil"));
}

test "Restart=, a forking daemon without a pid file and KillMode are noted" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "again", "", "Restart=on-failure\nKillMode=mixed");
    try addSvc(t, "fork", "", "Type=forking");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "again", "fork" }));
    const again = try f.script("again");
    try h.expectContains(again, "\n# Restart=on-failure is not honored: BSD-style rc does not supervise services, a service that dies stays dead\n");
    try h.expectContains(again, "\n# KillMode=mixed is handled like control-group\n");
    try h.expectContains(try f.script("fork"), "\n# Type=forking without PIDFile=: the daemon is started but not followed, and stop cannot signal it\n");
}

// ---- runtime control --------------------------------------------------------------------------

test "start, stop, restart and reload run the script, and a failure is reported" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(0, &.{ rc_d ++ "/rc.foo", "start" });
    try f.expectCall(1, &.{ rc_d ++ "/rc.foo", "stop" });
    try f.expectCall(2, &.{ rc_d ++ "/rc.foo", "restart" });
    try f.expectCall(3, &.{ rc_d ++ "/rc.foo", "reload" });
    try testing.expectEqual(@as(usize, 4), f.sc.calls.items.len);

    f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.foo", "start" }, .code = 1, .stdout = "Starting foo: first line\nfoo: cannot bind port\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    try h.expectContains(t.stderr(), "foo: cannot bind port");
    f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.foo", "stop" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
}

test "status codes of the script are normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const cases = [_]struct { u8, []const u8, u8 }{
        .{ 0, "active\n", 0 },
        .{ 1, "failed\n", 3 },
        .{ 3, "inactive\n", 3 },
        .{ 127, "inactive\n", 3 },
    };
    for (cases) |c| {
        f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.foo", "status" }, .code = c[0] }};
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.foo", "status" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.foo", "status" }, .code = 1, .stdout = "usage: /etc/rc.d/rc.foo start|stop\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "the main pid is the one the executor recorded, and kill signals it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    try dinit_world.liveProcess(t, 4242);
    try t.write("/run/fake-systemd/foo.service.pid", "4242 4242\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4242");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGHUP", "foo" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "4242" });
}

test "power verbs go through shutdown" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{ "shutdown", "-r", "now" });
    try f.expectCall(1, &.{ "shutdown", "-h", "-P", "now" });
    try f.expectCall(2, &.{ "shutdown", "-h", "-H", "now" });
}

// ---- capabilities, hooks and timers -----------------------------------------------------------

test "capabilities are ordering, shutdown hooks and no supervision" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = f.b.backend().caps();
    try testing.expect(c.hard_deps and c.soft_deps and c.ordering and c.shutdown_hooks and c.translates);
    try testing.expect(!c.supervision and !c.restart_policy and !c.user_services and !c.oneshot);
}

test "a boot or shutdown hook unit is a service here, with its stop run at shutdown" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/save", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/save.service", "[Unit]\nDefaultDependencies=no\nBefore=shutdown.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/save load\nExecStop=/usr/bin/save store\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "save" });
    const body = try f.script("save");
    try h.expectContains(body, "--exec save.service --phase stop || rc=$?\n");
    try h.expectContains(try t.read(rc_d ++ "/rc.local_shutdown"), "[ -x /etc/rc.d/rc.save ] && /etc/rc.d/rc.save stop\n");
}

test "the timer runner is generated as a daemon, started by its script and signalled with HUP" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    f.status("fake-systemd-timers", 3, "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    try h.expectContains(try f.script("fake-systemd-timers"), "--exec fake-systemd-timers.service --daemon --log --record-exit\n");
    try f.expectCalled(&.{ rc_d ++ "/rc.fake-systemd-timers", "start" });
    try testing.expect(f.executable(rc_d ++ "/rc.fake-systemd-timers"));

    try dinit_world.liveProcess(t, 7);
    try t.write("/run/fake-systemd/fake-systemd-timers.service.pid", "7 7\n", 0o644);
    f.sc.rules = &.{.{ .prefix = &.{ rc_d ++ "/rc.fake-systemd-timers", "status" }, .code = 0 }};
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "7" });
    f.sc.rules = &.{};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists(rc_d ++ "/rc.fake-systemd-timers"));
}

// ---- golden files -------------------------------------------------------------------------------

fn runEntry(e: world.Entry) !void {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    const a = t.a();
    try world.populateBsdRc(&t);
    const loaded = try world.load(&t, e);
    var b: world.bsdrc = undefined;
    world.useBsdRc(&t, &b);
    const be = b.backend();
    const generated = try be.generate(a, .{ .unit = &loaded.unit, .tier = loaded.resolved.tier().?, .source = loaded.resolved.fragment.?.path, .src_hash = 0x0123456789abcdef });

    try testing.expectEqual(@as(usize, 1), generated.files.len);
    const file = generated.files[0];
    // A script that was never enabled is not executable.
    try testing.expectEqual(@as(u16, 0o644), file.mode);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "rc.{s}", .{generated.service_name}), std.fs.path.basename(file.path));
    try testing.expectEqualStrings(generated.service_name, be.serviceOfFile(file.path));
    try testing.expectEqualStrings("/etc/rc.d", std.fs.path.dirname(file.path).?);

    const parsed = world.marker.parse(file.content) orelse return error.MissingMarker;
    try testing.expectEqualStrings(loaded.name.full, parsed.marker.unit);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/bin/sh\n", parsed.shebang);
    try world.expectShellSyntax(&t, file.content);
    try world.expectGolden(a, "bsdrc", e, file.content);
}

test "corpus translates to the golden BSD-style rc scripts" {
    for (world.entries("bsdrc", "bsdrc")) |e| try runEntry(e);
}

test "a hook script whose block is not closed is left untouched" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const broken = world.slackware_rc_local ++ "\n" ++ block_start ++ "[ -x /etc/rc.d/rc.old ] && /etc/rc.d/rc.old start\n";
    try t.write(rc_d ++ "/rc.local", broken, 0o755);
    try testing.expect(t.run(&.{ "enable", "foo" }) != 0);
    try testing.expectEqualStrings(broken, try t.read(rc_d ++ "/rc.local"));
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
    try h.expectContains(try t.read(rc_d ++ "/rc.foo.bar"), "# Unit: foo.bar.service\n");
}

test "a pid file that names init or a dead process is not signalled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/syslogd.service", "[Service]\nExecStart=/usr/sbin/syslogd\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/sbin/syslogd", "#!/bin/sh\n", 0o755);
    try dinit_world.liveProcess(t, 1);
    try t.write("/run/syslog.pid", "1\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "HUP", "syslogd" }));
    try t.write("/run/syslog.pid", "31337\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "-s", "HUP", "syslogd" }));
    try testing.expect(!f.sc.called(&.{"kill"}));
}

test "enable and disable change the permission bits of the script in place" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(rc_d ++ "/rc.keep", "#!/bin/sh\necho keep\n", 0o644);
    const before = try t.fs.stat(rc_d ++ "/rc.keep");
    try t.fs.symLink("rc.keep", rc_d ++ "/rc.link");
    try t.write("/usr/lib/systemd/system/keep.service", "[Service]\nExecStart=/usr/bin/keep\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/keep", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "keep" }));
    const after = try t.fs.stat(rc_d ++ "/rc.keep");
    try testing.expect(f.executable(rc_d ++ "/rc.keep"));
    // The same file, not a new one in its place.
    try testing.expectEqual(before.inode, after.inode);
    try testing.expectEqual(@as(u16, 0o755), after.mode);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "keep" }));
    try testing.expectEqual(before.inode, (try t.fs.stat(rc_d ++ "/rc.keep")).inode);
    try testing.expectEqual(@as(u16, 0o644), (try t.fs.stat(rc_d ++ "/rc.keep")).mode);
}

test "a hook script that holds nothing but the managed block is kept as a shebang, never deleted" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(rc_d ++ "/rc.local_shutdown"));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(rc_d ++ "/rc.local_shutdown"));
    try testing.expect(t.exists(rc_d ++ "/rc.local"));
    try h.expectNotContains(try t.read(rc_d ++ "/rc.local_shutdown"), "fake-systemd");
}

test "the reload phase of an account only the system libc resolves carry its numeric ids" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "ldaph", "", "User=ldapuser\nExecReload=/usr/bin/reload-ldap");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldaph" }));
    const body = try f.script("ldaph");
    const ids = " --uid \"$(id -u -- ldapuser)\" --gid \"$(id -g -- ldapuser)\" --groups \"$(id -G -- ldapuser | tr ' ' ,)\"";
    try h.expectContains(body, "--exec ldaph.service --phase reload" ++ ids);
}

test "an rc.local above one MiB survives enable unchanged" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "foo", "", "");
    const big = try testing.allocator.alloc(u8, (1 << 20) + 100);
    defer testing.allocator.free(big);
    @memset(big, '#');
    big[big.len - 1] = '\n';
    try t.write(rc_d ++ "/rc.local", big, 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const after = try t.fs.readFileAlloc(t.a(), rc_d ++ "/rc.local", 1 << 22);
    try testing.expectEqualStrings(big, after[0..big.len]);
    try h.expectContains(after, "rc.foo start");
}

test "a hook script that cannot be read in full is an error and is never rewritten" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const file = try t.fs.root.openFile(testing.io, "etc/rc.d/rc.local", .{ .mode = .read_write });
    defer file.close(testing.io);
    const len: usize = (64 << 20) + 1;
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, len)));
    try testing.expect(t.run(&.{ "enable", "foo" }) != 0);
    try testing.expectEqual(@as(u64, len), (try t.fs.stat(rc_d ++ "/rc.local")).size);
    try testing.expect(!t.exists(rc_d ++ "/rc.local_shutdown"));
}

test "the boot order comes from the units, not from the header lines of the generated scripts" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const header = try t.read(rc_d ++ "/rc.a");
    try h.expectContains(header, "\n# Requires: b\n");
    try t.write(rc_d ++ "/rc.a", try std.mem.replaceOwned(u8, t.a(), header, "\n# Requires: b\n", "\n# Before: b\n"), 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "b" }));
    const local = try t.read(rc_d ++ "/rc.local");
    try testing.expect(std.mem.find(u8, local, "rc.b start").? < std.mem.find(u8, local, "rc.a start").?);
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}
