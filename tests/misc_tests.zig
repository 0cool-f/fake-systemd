const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
}

test "runtime verbs call the backend and update state" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "start", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "fakectl", "restart", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "fakectl", "reload", "foo" }));
    try testing.expect(t.rec.callIs(3, &.{ "fakectl", "stop", "foo" }));
    try testing.expect(t.fake.serviceState("foo").state == .inactive);
}

test "try-restart acts only on active services; reload-or-restart picks restart without ExecReload" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "try-restart", "foo" }));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "try-restart", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "fakectl", "restart", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload-or-restart", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "fakectl", "restart", "foo" }));
}

test "reload-or-restart reloads when the unit has ExecReload" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/rl.service", "[Service]\nExecStart=/usr/bin/foo\nExecReload=/usr/bin/foo reload\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload-or-restart", "rl" }));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "reload", "rl" }));
}

test "kill, power and sleep verbs" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "HUP", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "kill", "HUP", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expect(t.rec.callIs(1, &.{ "fakectl", "power", "poweroff" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{"suspend"}));
    try h.expectContains(t.stderr(), "loginctl is not installed");
    try t.write("/usr/bin/loginctl", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"hibernate"}));
    try testing.expect(t.rec.callIs(2, &.{ "loginctl", "hibernate" }));
}

test "exit codes for missing, masked and unsupported units" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 5), t.run(&.{ "start", "nope" }));
    try h.expectContains(t.stderr(), "Failed to start unit: Unit nope.service does not exist");
    try testing.expectEqual(@as(u8, 5), t.run(&.{ "start", "foo", "nope" }));
    try testing.expect(t.fake.serviceState("foo").state == .active);

    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=poweroff.target\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "hook" }));
    try h.expectContains(t.stderr(), "hook.service: not translated: system lifecycle hook");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "hook" }));
    try h.expectContains(t.stderr(), "nothing to do");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "hook" }));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "mask", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start unit: Unit /etc/systemd/system/foo.service is masked");
}

test "Deny= in the configuration excludes a unit" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const deny = try t.a().dupe([]const u8, &.{"foo*"});
    t.ctx.config.deny = deny;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "excluded by Deny=");
}

test "timer-triggered services are not enabled but start works" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/foo.timer", "[Timer]\nOnCalendar=daily\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(t.exists("/usr/lib/fake.d/foo"));
}

test "informational verbs and unknown verbs exit 0" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "set-environment", "A=1" }));
    try h.expectContains(t.stderr(), "'set-environment' has no effect without systemd and is ignored");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "frobnicate", "x" }));
    try h.expectContains(t.stderr(), "warning: unknown verb 'frobnicate' ignored");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "-H", "host", "status" }));
    try h.expectContains(t.stderr(), "not supported");
}

test "help and version" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"--version"}));
    try testing.expectEqualStrings("fake-systemd 0.1.0\nbackend: fake\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{"--help"}));
    try h.expectContains(t.stdout(), "systemctl [OPTIONS...] COMMAND [UNIT...]");
}

test "null backend: queries answer, mutations fail with guidance" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    var nb: h.backend.NullBackend = .{ .detected = "unknown" };
    t.backend_override = nb.backend();
    t.detected = "unknown";

    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "no supported init system was detected (found: unknown)");
    try h.expectContains(t.stderr(), "FAKE_SYSTEMD_INIT");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "mask", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "unmask", "foo" }));
    try testing.expect(!t.exists("/var/lib/fake-systemd"));
}

test "preset applies enable and disable rules, first match wins" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "bar.service", "/usr/bin/bar", "WantedBy=multi-user.target");
    try t.addUnit("/usr/lib/systemd/system", "baz.service", "/usr/bin/baz", "WantedBy=multi-user.target");
    try t.write("/usr/lib/systemd/system-preset/50-a.preset", "# comment\nenable foo.service\n", 0o644);
    try t.write("/usr/lib/systemd/system-preset/90-b.preset", "disable foo.service\nenable ba?.service\ndisable *\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "preset", "foo", "bar" }));
    try testing.expect(t.fake.serviceState("foo").enabled);
    try testing.expect(t.fake.serviceState("bar").enabled);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"preset-all"}));
    try testing.expect(t.fake.serviceState("baz").enabled);
}

test "preset without preset files does nothing" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "preset", "foo" }));
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"preset-all"}));
}

const EditRunner = struct {
    fs: *h.core.Fs,
    content: []const u8,
    calls: usize = 0,

    fn runner(e: *EditRunner) h.backend.Runner {
        return .{ .ptr = e, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const e: *EditRunner = @ptrCast(@alignCast(ptr));
        e.calls += 1;
        try e.fs.writeFileAtomic(argv[argv.len - 1], e.content, 0o644);
        return .{ .code = 0 };
    }
};

test "edit writes the drop-in with the editor and syncs the unit" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.environ.put("EDITOR", "myed -w");

    var ed: EditRunner = .{ .fs = &t.fs, .content = "[Service]\nExecStart=\nExecStart=/usr/bin/foo2\n" };
    try t.write("/usr/bin/foo2", "#!/bin/sh\n", 0o755);
    t.rec.code = 0;
    var deps = t.deps();
    deps.runner = ed.runner();
    t.out.clearRetainingCapacity();
    t.err.clearRetainingCapacity();
    const code = h.ops.systemctlArgs(&t.ctx, deps, &.{ "edit", "foo" });
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 1), ed.calls);
    try testing.expectEqualStrings(ed.content, try t.read("/etc/systemd/system/foo.service.d/override.conf"));
    try h.expectContains(try t.read("/usr/lib/fake.d/foo"), "exec = /usr/bin/foo2");
}

test "edit passes the editor words and removes an untouched drop-in" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.environ.put("EDITOR", "myed -w");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "edit", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "myed", "-w", "/etc/systemd/system/foo.service.d/override.conf" }));
    try testing.expect(!t.exists("/etc/systemd/system/foo.service.d"));
    try h.expectContains(t.stderr(), "no changes made");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "edit", "nope" }));
}

test "user scope uses the personal directories" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/root/.config/systemd/user", "mine.service", "/usr/bin/mine", "WantedBy=default.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "mine" }));
    try testing.expect(t.exists("/home/fake/.config/fake.d/mine"));
    try h.expectContains(try t.read("/root/.local/state/fake-systemd/fake/index"), "unit\tmine.service\tuser\tpersonal\tmanaged\t");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "mask", "other" }));
    var link: [64]u8 = undefined;
    try testing.expectEqualStrings("/dev/null", try t.fs.readLink("/root/.config/systemd/user/other.service", &link));
}

test "journalctl accepts its options and notices units without logs" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.out.clearRetainingCapacity();
    t.err.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), h.ops.journalctlArgs(&t.ctx, t.deps(), &.{ "-u", "foo", "-n", "5" }));
    try h.expectContains(t.stderr(), "foo.service: no fake-systemd logs in /var/log/fake-systemd/foo.service");
}
