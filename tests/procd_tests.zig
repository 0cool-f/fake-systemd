// SPDX-License-Identifier: GPL-3.0-or-later
//! The procd backend behind the real `ops` entry point, with a runner that answers like the
//! init scripts and `ubus`, and the golden scripts of the corpus.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("bsdrc_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const init_d = "/etc/init.d";
const rc_d = "/etc/rc.d";

const Fixture = struct {
    t: h.Harness = undefined,
    p: world.procd = undefined,
    sc: world.Script = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populateProcd(&f.t);
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "procd";
    }

    fn bind(f: *Fixture) void {
        world.useProcd(&f.t, &f.p);
        f.t.backend_override = f.p.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn hasLink(f: *Fixture, file: []const u8) bool {
        const path = std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ rc_d, file }) catch return false;
        _ = f.t.fs.lstat(path) catch return false;
        return true;
    }

    /// What `/etc/init.d/<service> enable` writes.
    fn link(f: *Fixture, file: []const u8, service: []const u8) !void {
        const target = try std.fmt.allocPrint(f.t.a(), "../init.d/{s}", .{service});
        try f.t.fs.symLink(target, try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ rc_d, file }));
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

    /// What `ubus call service list` prints.
    fn listing(f: *Fixture, json: []const u8) void {
        f.sc.rules = std.mem.concat(f.t.a(), world.Rule, &.{ &.{.{ .prefix = &.{ "ubus", "call", "service", "list" }, .stdout = json }}, f.sc.rules }) catch @panic("out of memory");
    }

    /// The generated script of `service` without its marker, behind a newline.
    fn script(f: *Fixture, service: []const u8) ![]const u8 {
        const rest = marker.parse(try f.t.read(try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ init_d, service }))).?.rest;
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

const running_listing =
    \\{
    \\  "foo": {
    \\    "instances": {
    \\      "instance1": {
    \\        "running": true,
    \\        "pid": 4321,
    \\        "command": [
    \\          "/usr/bin/fake-systemd"
    \\        ]
    \\      }
    \\    }
    \\  }
    \\}
    \\
;

// ---- generation and enablement ----------------------------------------------------------------

test "enable generates the script and asks the script itself to write the links" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(init_d ++ "/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 procd/2", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/bin/sh /etc/rc.common\n", parsed.shebang);
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(init_d ++ "/foo")).mode);
    try f.expectCall(0, &.{ init_d ++ "/foo", "enable" });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    // The runner stands for the script, which writes S50foo and K50foo; the backend only adds the
    // stop link that a script written for it needs when it is started without being enabled.
    try testing.expect(f.hasLink("K50foo"));
    try testing.expect(!f.hasLink("S50foo"));

    try f.link("S50foo", "foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "disable asks the script, and the stop link of a generated script stays" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.link("S50foo", "foo");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ init_d ++ "/foo", "disable" });
    try t.fs.deleteFile("/etc/rc.d/S50foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "enable" }, .code = 1 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
}

test "offline in a root that is not the running one, the links are written directly" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(f.hasLink("S50foo") and f.hasLink("K50foo"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("../init.d/foo", try t.fs.readLink("/etc/rc.d/S50foo", &buf));
    try h.expectContains(t.stderr(), "Created symlink '/etc/rc.d/S50foo' -> '../init.d/foo'.");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/rc.d/S50foo'.");
    try testing.expect(!f.hasLink("S50foo") and f.hasLink("K50foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "offline in the running root, the links are written directly as well, since the script needs a booted system" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    t.fs.host_root = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(f.hasLink("S50foo") and f.hasLink("K50foo"));
}

test "dry-run prints the link and the command it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would create symlink '/etc/rc.d/S50foo' -> '../init.d/foo'\n");
    try h.expectContains(t.stdout(), "would run: /etc/init.d/foo start\n");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expect(!f.hasLink("K50foo"));
}

test "a service started without being enabled gets its stop link, and a stale one goes at the next reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(f.hasLink("K50foo") and !f.hasLink("S50foo"));
    try f.expectCalled(&.{ init_d ++ "/foo", "start" });
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expect(!f.hasLink("K50foo"));
    try testing.expect(f.hasLink("S50cron"));
}

test "the index records the script, and a lost index is rebuilt from the marker" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(try t.read("/var/lib/fake-systemd/procd/index"), init_d ++ "/foo");
    try t.fs.deleteFile("/var/lib/fake-systemd/procd/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(init_d ++ "/foo"));
    try testing.expect(t.exists(init_d ++ "/cron"));
}

test "a template instance is a script named name.instance" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try f.expectCall(0, &.{ init_d ++ "/tpl.one", "enable" });
    try testing.expectEqualStrings("tpl@one.service", marker.parse(try t.read(init_d ++ "/tpl.one")).?.marker.unit);
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
    try h.expectContains(t.stderr(), "procd has no service manager for users");
}

// ---- native scripts ---------------------------------------------------------------------------

test "a native procd script that starts the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/cron.service", "[Service]\nExecStart=/usr/sbin/crond -f\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "cron" }));
    try testing.expect(marker.parse(try t.read(init_d ++ "/cron")) == null);
    try h.expectContains(t.stderr(), "using native service 'cron'");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "cron" }));
    try f.expectCalled(&.{ init_d ++ "/cron", "start" });
}

test "two busybox applets are not the same program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/sleeper.service", "[Service]\nExecStart=/bin/sleep 1000\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "sleeper" }));
    try h.expectNotContains(t.stderr(), "native service");
    try testing.expect(t.exists(init_d ++ "/sleeper"));
}

// ---- how the script runs the unit ----------------------------------------------------------------

test "a daemon is a procd instance of the executor with the respawn and stop timeout of the unit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const body = try f.script("foo");
    try h.expectContains(body, "\nUSE_PROCD=1\nSTART=50\nSTOP=50\n");
    try h.expectContains(body, "\nstart_service() {\n\tprocd_running foo || rm -f \"$main_pid\"\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/fake-systemd --exec foo.service --log\n\tprocd_set_param term_timeout 90\n\tprocd_close_instance\n}\n");
    // Restart=no is no respawn parameter, which procd would take as its default.
    try h.expectNotContains(body, "respawn");
    try addSvc(t, "again", "", "Restart=always\nRestartSec=3");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "again" }));
    try h.expectContains(try f.script("again"), "\n\tprocd_set_param respawn 10 3 5\n");
    try addSvc(t, "failing", "", "Restart=on-failure");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "failing" }));
    const failing = try f.script("failing");
    try h.expectContains(failing, "\n\tprocd_set_param respawn 10 1 5\n");
    try h.expectContains(failing, "\n# Restart=on-failure is approximated by respawning on every exit\n");
}

test "start and restart end in service_started, which waits for the main process the executor records" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "fork", "", "Type=forking\nPIDFile=/run/fork.pid\nTimeoutStartSec=30");
    try addSvc(t, "hooks", "", "ExecStop=/usr/bin/hooks stop");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo", "fork", "hooks" }));
    const forking = try f.script("fork");
    try h.expectContains(forking, "\nmain_pid=/run/fake-systemd/fork.service.pid\nstart_wait=30\nmain_replaced=1\n");
    try h.expectContains(forking, "\nservice_started() {\n");
    // The executor of a unit without stop hooks becomes the main process and records its own pid.
    try h.expectContains(try f.script("foo"), "\nstart_wait=90\nmain_replaced=0\n");
    try h.expectContains(try f.script("hooks"), "\nstart_wait=90\nmain_replaced=1\n");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "fork" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "fork" }));
    try f.expectCall(0, &.{ init_d ++ "/fork", "start" });
    try f.expectCall(2, &.{ init_d ++ "/fork", "restart" });
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/fork", "start" }, .code = 1, .stdout = "" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "fork" }));
    try h.expectContains(t.stderr(), "Failed to start fork.service");
}

test "the stop waits for the instance, runs ExecStopPost after it and the executor stops on the signal" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hooks", "", "ExecStop=/usr/bin/hooks stop\nExecStopPost=/usr/bin/hooks clean\nExecReload=/usr/bin/hooks reload\nTimeoutStopSec=20\nKillSignal=SIGINT");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hooks", "foo" }));
    const body = try f.script("hooks");
    try h.expectContains(body, "procd_set_param command /usr/bin/fake-systemd --exec hooks.service --stop-on-signal --log\n");
    try h.expectContains(body, "\n\tprocd_set_param term_timeout 30\n");
    try h.expectContains(body, "\nstop_service() {\n\tregistered && _was_up=1\n}\n");
    try h.expectContains(body, "\nservice_stopped() {\n\t_n=0\n\twhile procd_running hooks && [ \"$_n\" -lt 35 ]; do\n\t\tsleep 1\n");
    try h.expectContains(body, "\t[ -n \"$_was_up\" ] && /usr/bin/fake-systemd --exec hooks.service --phase stop-post\n");
    try h.expectContains(body, "\treturn 7\n\t}\n\t/usr/bin/fake-systemd --exec hooks.service --phase reload\n");
    try h.expectContains(body, "\n# KillSignal= is not honored: procd stops an instance with SIGTERM\n");
    // A unit without ExecReload= says so instead of restarting through procd.
    try h.expectContains(try f.script("foo"), "\nreload_service() {\n\techo \"foo.service does not support reload\" >&2\n\treturn 3\n}\n");
    try h.expectNotContains(try f.script("foo"), "stop_service");
}

test "EnvironmentFile= is a file procd watches, so that a reload restarts the instance when it changed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "env", "", "EnvironmentFile=-/etc/default/env\nEnvironmentFile=/etc/env.conf");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "env" }));
    try h.expectContains(try f.script("env"), "\n\tprocd_set_param file /etc/default/env /etc/env.conf\n");
}

test "dependencies: required scripts fail the start, wanted ones do not, and START orders by them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "b", "", "");
    try t.write(init_d ++ "/d", "#!/bin/sh /etc/rc.common\nSTART=60\nSTOP=40\n", 0o755);
    try addSvc(t, "a", "Requires=b.service\nWants=c.service\nAfter=d.service\nBefore=e.service", "");
    try addSvc(t, "c", "", "");
    try addSvc(t, "e", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectContains(body, "\n# Requires: b\n# Wants: c\n# After: d\n# Before: e\n");
    try h.expectContains(body, "\nSTART=61\nSTOP=39\n");
    try h.expectContains(body, "\nstart_service() {\n\tprocd_running a || rm -f \"$main_pid\"\n\t/etc/init.d/b start || {\n\t\techo \"a.service: cannot start\" b >&2\n\t\treturn 1\n\t}\n\t/etc/init.d/c start || :\n\tprocd_open_instance\n");
    // The scripts of the units it pulls in are generated and not enabled.
    for ([_][]const u8{ "b", "c" }) |dep| {
        try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "{s}/{s}", .{ init_d, dep })));
        try testing.expect(!f.hasLink(try std.fmt.allocPrint(t.a(), "S50{s}", .{dep})));
    }
    try testing.expectEqual(@as(usize, 1), f.sc.count(&.{ init_d ++ "/a", "enable" }));
    try testing.expectEqual(@as(usize, 0), f.sc.count(&.{ init_d ++ "/b", "enable" }));
}

test "a script follows the services it requires by START, and precedes the ones it is before" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(init_d ++ "/late", "#!/bin/sh /etc/rc.common\nSTART=90\nSTOP=10\n", 0o755);
    try t.write(init_d ++ "/early", "#!/bin/sh /etc/rc.common\nSTART=30\nSTOP=70\n", 0o755);
    try t.write("/usr/lib/systemd/system/late.service", "[Service]\nExecStart=/usr/bin/late\n", 0o644);
    try t.write("/usr/lib/systemd/system/early.service", "[Service]\nExecStart=/usr/bin/early\n", 0o644);
    try t.write("/usr/bin/late", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/early", "#!/bin/sh\n", 0o755);
    try addSvc(t, "after-late", "After=late.service", "");
    try addSvc(t, "before-early", "Before=early.service", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "after-late", "before-early" }));
    try h.expectContains(try f.script("after-late"), "\nSTART=91\nSTOP=09\n");
    try h.expectContains(try f.script("before-early"), "\nSTART=29\nSTOP=71\n");
}

test "a dependency the classifier excludes is left out, and the network targets order by START alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service\nAfter=network-online.target", "");
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/hook\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    const body = try f.script("a");
    try h.expectNotContains(body, "hook");
    try h.expectNotContains(body, "/etc/init.d/");
    try h.expectContains(body, "\nSTART=50\n");
    // The unit follows the network script of the profile wherever its START is.
    try t.write(init_d ++ "/network", "#!/bin/sh /etc/rc.common\nSTART=75\nSTOP=10\n", 0o755);
    try addSvc(t, "net", "After=network.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "net" }));
    try h.expectContains(try f.script("net"), "\nSTART=76\nSTOP=24\n");
}

test "a oneshot is a script of its own that runs the executor to the end in start" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "job", "", "Type=oneshot\nExecStop=/usr/bin/job stop");
    try addSvc(t, "kept", "", "Type=oneshot\nRemainAfterExit=yes\nExecStop=/usr/bin/kept stop");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job", "kept" }));
    const job = try f.script("job");
    try h.expectNotContains(job, "USE_PROCD");
    try h.expectContains(job, "\nEXTRA_COMMANDS=\"status running\"\n");
    try h.expectContains(job, "\n\t/usr/bin/fake-systemd --exec job.service --log --record-exit > /dev/null\n");
    try h.expectContains(job, "echo \"job.service has finished\"");
    const kept = try f.script("kept");
    try h.expectContains(kept, "\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n");
    try h.expectContains(kept, "/usr/bin/fake-systemd --exec kept.service --phase stop || _rc=$?\n");
    try h.expectContains(kept, "is active (exited)");
}

test "an account the executor does not find is warned about, the executor switches the rest" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "known", "", "User=app\nGroup=app");
    try addSvc(t, "unknown", "", "User=ghost");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "known", "unknown" }));
    try h.expectContains(t.stderr(), "unknown.service: User=ghost is not in /etc/passwd");
    try h.expectNotContains(t.stderr(), "warning: known.service");
    try h.expectNotContains(try f.script("known"), "procd_set_param user");
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
    try f.expectCall(0, &.{ init_d ++ "/foo", "start" });
    try f.expectCall(1, &.{ init_d ++ "/foo", "stop" });
    try f.expectCall(2, &.{ init_d ++ "/foo", "restart" });
    try f.expectCall(3, &.{ init_d ++ "/foo", "reload" });
    try testing.expectEqual(@as(usize, 4), f.sc.calls.items.len);

    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/foo", "start" }, .code = 1, .stdout = "first line\nfoo.service: cannot start dep\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    try h.expectContains(t.stderr(), "cannot start dep");
}

test "status is what ubus lists: running with its pid, failed after a failure, inactive otherwise" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.listing(running_listing);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Main PID: 4321");
    try f.expectCalled(&.{ "ubus", "call", "service", "list", "{\"name\": \"foo\"}" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));

    f.sc.rules = &.{};
    f.listing("{\"foo\":{\"instances\":{\"instance1\":{\"running\":false,\"exit_code\":3}}}}");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    f.sc.rules = &.{};
    f.listing("{\"foo\":{\"instances\":{\"instance1\":{\"running\":false,\"exit_code\":0}}}}");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    f.sc.rules = &.{};
    f.listing("{\n\t\n}\n");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "status of a script without instances is its status action" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "kept", "", "Type=oneshot\nRemainAfterExit=yes");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "kept" }));
    const cases = [_]struct { u8, []const u8, u8 }{
        .{ 0, "active\n", 0 },
        .{ 1, "failed\n", 3 },
        .{ 3, "inactive\n", 3 },
    };
    for (cases) |c| {
        f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/kept", "status" }, .code = c[0] }};
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "kept" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    // A native script that is not a procd script has no status verb: rc.common prints its help.
    f.sc.rules = &.{.{ .prefix = &.{ init_d ++ "/boot", "status" }, .code = 0, .stdout = "Syntax: /etc/init.d/boot [command]\n\nAvailable commands:\n\tstart\tStart the service\n" }};
    const env: h.backend.interface.Env = .{ .ctx = &t.ctx, .runner = f.sc.runner(), .online = true };
    const st = try f.p.backend().status(env, "boot");
    try testing.expectEqualStrings("inactive", st.state.text());
}

test "kill signals the process procd reports" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "no process to signal");
    f.listing(running_listing);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGHUP", "foo" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "4321" });
}

test "daemon-reload and power verbs" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{"reboot"});
    try f.expectCall(1, &.{"poweroff"});
    try f.expectCall(2, &.{"halt"});
}

// ---- capabilities, hooks and timers -----------------------------------------------------------

test "capabilities are dependencies, ordering, supervision, restart policy and shutdown hooks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const c = f.p.backend().caps();
    try testing.expect(c.hard_deps and c.soft_deps and c.ordering and c.supervision and c.restart_policy and c.shutdown_hooks and c.translates);
    try testing.expect(!c.user_services and !c.oneshot and !c.per_service_logger);
}

test "a boot or shutdown hook unit is a service here, with its stop link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/save", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/save.service", "[Unit]\nDefaultDependencies=no\nBefore=shutdown.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/save load\nExecStop=/usr/bin/save store\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "save" });
    try h.expectContains(try f.script("save"), "--exec save.service --phase stop || _rc=$?\n");
    try testing.expect(f.hasLink("K50save"));
}

test "the timer runner is a respawned instance signalled with HUP" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    const body = try f.script("fake-systemd-timers");
    try h.expectContains(body, "procd_set_param command /usr/bin/fake-systemd --exec fake-systemd-timers.service --log\n");
    try h.expectContains(body, "\n\tprocd_set_param respawn 10 1 5\n");
    try f.expectCalled(&.{ init_d ++ "/fake-systemd-timers", "enable" });
    try f.expectCalled(&.{ init_d ++ "/fake-systemd-timers", "start" });

    try f.link("S50fake-systemd-timers", "fake-systemd-timers");
    f.listing("{\"fake-systemd-timers\":{\"instances\":{\"instance1\":{\"running\":true,\"pid\":7}}}}");
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCalled(&.{ "kill", "-s", "HUP", "7" });
}

// ---- golden files -------------------------------------------------------------------------------

fn runEntry(e: world.Entry) !void {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    const a = t.a();
    try world.populateProcd(&t);
    const loaded = try world.load(&t, e);
    var p: world.procd = undefined;
    world.useProcd(&t, &p);
    const be = p.backend();
    const generated = try be.generate(a, .{ .unit = &loaded.unit, .tier = loaded.resolved.tier().?, .source = loaded.resolved.fragment.?.path, .src_hash = 0x0123456789abcdef });

    try testing.expectEqual(@as(usize, 1), generated.files.len);
    const file = generated.files[0];
    try testing.expectEqual(@as(u16, 0o755), file.mode);
    try testing.expectEqualStrings(std.fs.path.basename(file.path), generated.service_name);
    try testing.expectEqualStrings(generated.service_name, be.serviceOfFile(file.path));
    try testing.expectEqualStrings("/etc/init.d", std.fs.path.dirname(file.path).?);

    const parsed = world.marker.parse(file.content) orelse return error.MissingMarker;
    try testing.expectEqualStrings(loaded.name.full, parsed.marker.unit);
    try testing.expect(parsed.bodyIntact());
    try testing.expectEqualStrings("#!/bin/sh /etc/rc.common\n", parsed.shebang);
    try world.expectShellSyntax(&t, file.content);
    try world.expectGolden(a, "procd", e, file.content);
}

test "corpus translates to the golden procd scripts" {
    for (world.entries("procd", "procd")) |e| try runEntry(e);
}

test "a stop link of a native script whose file is gone is left alone, one of a removed generated script goes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.link("K90nativegone", "nativegone");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(f.hasLink("K50foo"));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!f.hasLink("K50foo"));
    try testing.expect(f.hasLink("K90nativegone"));
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

test "daemon-reload with a lost index still removes the stop link of our removed script and keeps a native one" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.link("K90nativegone", "nativegone");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(f.hasLink("K50foo"));
    try t.fs.deleteFile("/var/lib/fake-systemd/procd/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!f.hasLink("K50foo"));
    try testing.expect(f.hasLink("K90nativegone"));
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}

test "a script that cannot be read in full is an error, and disable removes no link of it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const file = try t.fs.root.openFile(testing.io, "etc/init.d/foo", .{ .mode = .read_write });
    defer file.close(testing.io);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, (1 << 20) + 1)));
    try testing.expect(t.run(&.{ "disable", "foo" }) != 0);
    try testing.expect(f.hasLink("S50foo") and f.hasLink("K50foo"));
}

test "a script generated by an older generator is generated again at daemon-reload" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const path = init_d ++ "/foo";
    const parsed = marker.parse(try t.read(path)).?;
    const from = std.mem.find(u8, parsed.rest, "\nservice_started() {").?;
    const to = std.mem.find(u8, parsed.rest, "\nservice_stopped() {").?;
    const old_body = try std.mem.concat(t.a(), u8, &.{ parsed.rest[0..from], parsed.rest[to..] });
    const old_script = try marker.compose(t.a(), parsed.marker.unit, parsed.marker.source, parsed.marker.source_hash, "fake-systemd 0.1.0 procd/1", old_body);
    try t.write(path, old_script, 0o755);
    const index_path = "/var/lib/fake-systemd/procd/index";
    var old = try std.mem.replaceOwned(u8, t.a(), try t.read(index_path), "generator=2", "generator=1");
    const entry = try std.fmt.allocPrint(t.a(), "{s}=", .{path});
    const at = std.mem.find(u8, old, entry).? + entry.len;
    const end = std.mem.findAnyPos(u8, old, at, ",\t\n").?;
    const recorded = try std.fmt.allocPrint(t.a(), "{f}:{f}", .{ h.index.hash.str(h.index.hash.ofBytes(old_script)), h.index.hash.str(h.index.hash.fileFingerprint(t.fs, path)) });
    old = try std.mem.concat(t.a(), u8, &.{ old[0..at], recorded, old[end..] });
    try t.write(index_path, old, 0o644);
    try testing.expect(std.mem.find(u8, try t.read(path), "service_started") == null);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(path), "\nservice_started() {\n");
    try h.expectContains(try t.read(index_path), "generator=2");
}
