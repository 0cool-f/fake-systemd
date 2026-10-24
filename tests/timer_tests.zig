// SPDX-License-Identifier: GPL-3.0-or-later
//! Timer verbs against the fake backend and a tmp root: scheduler choice, native scheduler files,
//! the runner service and the query output.
const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;
const marker = h.index.marker;

const runner_service = "fake-systemd-timers";
const runner_unit = "/etc/systemd/system/fake-systemd-timers.service";
const cron_d = "/etc/cron.d/fake-systemd";

fn addTimer(t: *h.Harness, name: []const u8, body: []const u8) !void {
    const service = try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name});
    if (!t.exists(service)) try t.addUnit("/usr/lib/systemd/system", try std.fmt.allocPrint(t.a(), "{s}.service", .{name}), "/usr/bin/job", null);
    const text = try std.fmt.allocPrint(t.a(), "[Unit]\nDescription=Timer {s}\n\n[Timer]\n{s}\n\n[Install]\nWantedBy=timers.target\n", .{ name, body });
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.timer", .{name}), text, 0o644);
}

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try addTimer(t, "foo", "OnCalendar=*-*-* 03:00:00");
}

fn installCronie(t: *h.Harness) !void {
    try t.write("/usr/sbin/crond", "x", 0o755);
    try t.write("/usr/bin/cronnext", "x", 0o755);
    try t.fake.setService("cronie", .{ .enabled = true });
}

fn installBusybox(t: *h.Harness) !void {
    try t.fs.makePath("/usr/sbin");
    try t.fs.symLink("/bin/busybox", "/usr/sbin/crond");
    try t.fake.setService("crond", .{ .enabled = true });
}

fn indexHas(t: *h.Harness, needle: []const u8) !void {
    try h.expectContains(try t.indexText(), needle);
}

test "enable arms a built-in timer and installs, enables and starts the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tbuiltin\t");
    const unit_text = try t.read(runner_unit);
    try h.expectContains(unit_text, "ExecStart=/usr/bin/fake-systemd --timers\n");
    try h.expectContains(unit_text, "WantedBy=multi-user.target");
    try testing.expect(t.exists("/etc/fake.d/" ++ runner_service));
    try testing.expect(t.fake.serviceState(runner_service).enabled);
    try testing.expectEqual(h.core.Fs.Kind.file, (try t.fs.stat("/etc/fake.d/" ++ runner_service)).kind);
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "start", runner_service }));
    try testing.expectEqualStrings("", t.stdout());
    try testing.expect(!t.exists("/etc/fake.d/foo"));
    try testing.expect(!t.exists(cron_d));
}

test "a second timer signals the running runner instead of restarting it" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "bar", "OnBootSec=5min");
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try t.expectRun(0, &.{ "enable", "bar.timer" });
    try testing.expect(t.rec.callIs(t.rec.calls.items.len - 1, &.{ "fakectl", "kill", "HUP", runner_service }));
    try indexHas(&t, "timer\tbar.timer\tbuiltin\t");
}

test "disable of the last built-in timer stops and removes the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "bar", "OnBootSec=5min");
    try t.expectRun(0, &.{ "enable", "foo.timer", "bar.timer" });
    try t.expectRun(0, &.{ "disable", "foo.timer" });
    try testing.expect(t.exists(runner_unit));
    try h.expectNotContains(try t.indexText(), "foo.timer");
    try t.expectRun(0, &.{ "disable", "bar.timer" });
    try testing.expect(!t.exists(runner_unit));
    try testing.expect(!t.exists("/etc/fake.d/" ++ runner_service));
    try testing.expect(!t.fake.serviceState(runner_service).enabled);
    try testing.expect(t.fake.serviceState(runner_service).state == .inactive);
    try h.expectNotContains(try t.indexText(), "timer\t");
    try h.expectNotContains(try t.indexText(), runner_service);
}

test "services started by a timer are not enabled at boot" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/job", "WantedBy=multi-user.target");
    try t.expectRun(0, &.{ "enable", "foo.service" });
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try testing.expect(t.exists("/usr/lib/fake.d/foo"));
}

test "cronie gets a managed cron.d file with a marker" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try addTimer(&t, "slow", "OnCalendar=Mon,Fri *-*-* 04:30:00\nRandomizedDelaySec=30s");
    try t.expectRun(0, &.{ "enable", "foo.timer", "slow.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:cronie\t");
    try indexHas(&t, "timer\tslow.timer\tcron:cronie\t");
    const content = try t.read(cron_d);
    const parsed = marker.parse(content).?;
    try testing.expect(parsed.bodyIntact());
    try h.expectContains(content, "SHELL=/bin/sh\n");
    try h.expectContains(content, "# foo.timer\n0 3 * * * root /usr/bin/fake-systemd --run-job foo.service --timer foo.timer\n");
    try h.expectContains(content, "30 4 * * 1,5 root /usr/bin/fake-systemd --run-job slow.service --timer slow.timer --random-delay 30000000\n");
    try testing.expect(!t.exists(runner_unit));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);

    try t.expectRun(0, &.{ "disable", "foo.timer", "slow.timer" });
    try testing.expect(!t.exists(cron_d));
}

test "a cron.d file edited by hand is left alone" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    const original = try t.read(cron_d);
    try t.write(cron_d, try std.fmt.allocPrint(t.a(), "{s}# my change\n", .{original}), 0o644);
    try addTimer(&t, "bar", "OnCalendar=hourly");
    try t.expectRun(0, &.{ "enable", "bar.timer" });
    try h.expectContains(t.stderr(), "was changed by hand, leaving it alone");
    try h.expectContains(try t.read(cron_d), "# my change\n");
    try h.expectNotContains(try t.read(cron_d), "bar.service");
}

test "Debian cron and cronie share the cron.d format" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/sbin/cron", "x", 0o755);
    try t.fake.setService("cron", .{ .enabled = true });
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:cron\t");
    try h.expectContains(try t.read(cron_d), "0 3 * * * root /usr/bin/fake-systemd --run-job foo.service");
}

test "a scheduler that is installed but not enabled is not used" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/sbin/crond", "x", 0o755);
    try t.write("/usr/bin/cronnext", "x", 0o755);
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tbuiltin\t");
    try testing.expect(!t.exists(cron_d));
}

test "BusyBox crond: the block keeps the user lines and crond is notified" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installBusybox(&t);
    const user_lines = "# mine\n*/15 * * * * run-parts /etc/periodic/15min\n";
    try t.write("/etc/crontabs/root", user_lines, 0o600);
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:busybox\t");
    const block = "# BEGIN fake-systemd\n# foo.timer\n0 3 * * * /usr/bin/fake-systemd --run-job foo.service --timer foo.timer\n# END fake-systemd\n";
    try testing.expectEqualStrings(user_lines ++ block, try t.read("/etc/crontabs/root"));
    try testing.expectEqualStrings("root\n", try t.read("/etc/crontabs/cron.update"));
    try testing.expect(!t.exists(cron_d));

    try addTimer(&t, "bar", "OnCalendar=hourly");
    try t.expectRun(0, &.{ "enable", "bar.timer" });
    const both = try t.read("/etc/crontabs/root");
    try testing.expect(std.mem.startsWith(u8, both, user_lines));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, both, "# BEGIN fake-systemd"));
    try h.expectContains(both, "0 * * * * /usr/bin/fake-systemd --run-job bar.service --timer bar.timer\n");

    try t.expectRun(0, &.{ "disable", "foo.timer", "bar.timer" });
    try testing.expectEqualStrings(user_lines, try t.read("/etc/crontabs/root"));
}

test "dcron uses the root crontab, not cron.d" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/sbin/crond", "x", 0o755);
    try t.fake.setService("dcron", .{ .enabled = true });
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:dcron\t");
    try testing.expect(!t.exists(cron_d));
    try h.expectContains(try t.read("/var/spool/cron/crontabs/root"), "# BEGIN fake-systemd\n# foo.timer\n0 3 * * *");
}

const Capture = struct {
    t: *h.Harness,
    calls: std.ArrayList([]const []const u8) = .empty,
    staged: []const u8 = "",

    fn runner(c: *Capture) h.backend.Runner {
        return .{ .ptr = c, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
        const c: *Capture = @ptrCast(@alignCast(ptr));
        const a = c.t.a();
        const copy = try a.alloc([]const u8, argv.len);
        for (argv, copy) |w, *d| d.* = try a.dupe(u8, w);
        try c.calls.append(a, copy);
        if (std.mem.eql(u8, argv[0], "fcrontab")) c.staged = try c.t.read(argv[1]);
        return .{ .code = 0 };
    }
};

test "fcron takes persistent timers through fcrontab with the bootrun option" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/sbin/fcron", "x", 0o755);
    try t.write("/usr/bin/fcrontab", "x", 0o755);
    try t.fake.setService("fcron", .{ .enabled = true });
    try t.write("/var/spool/fcron/root.orig", "# mine\n@ 1h echo hi\n", 0o600);
    try addTimer(&t, "daily", "OnCalendar=daily\nPersistent=true");
    var cap: Capture = .{ .t = &t };
    t.runner_override = cap.runner();
    try t.expectRun(0, &.{ "enable", "daily.timer" });
    try indexHas(&t, "timer\tdaily.timer\tcron:fcron\t");
    try testing.expectEqualStrings("fcrontab", cap.calls.items[0][0]);
    try testing.expectEqualStrings(
        "# mine\n@ 1h echo hi\n# BEGIN fake-systemd\n# daily.timer\n&bootrun 0 0 * * * /usr/bin/fake-systemd --run-job daily.service --timer daily.timer\n# END fake-systemd\n",
        cap.staged,
    );
    try testing.expect(!t.exists("/var/lib/fake-systemd/fcrontab.new"));
}

test "persistent timers need a scheduler with catch-up, others fall back to the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try addTimer(&t, "daily", "OnCalendar=daily\nPersistent=true");
    try t.expectRun(0, &.{ "enable", "daily.timer" });
    try indexHas(&t, "timer\tdaily.timer\tbuiltin\t");
    try testing.expect(t.exists(runner_unit));
}

test "timers cron cannot express exactly go to the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try addTimer(&t, "boot", "OnBootSec=5min");
    try addTimer(&t, "secs", "OnCalendar=*:*:0/5");
    try addTimer(&t, "tz", "OnCalendar=*-*-* 03:00:00 Europe/Rome");
    try addTimer(&t, "eom", "OnCalendar=*-*~01 03:00:00");
    try t.expectRun(0, &.{ "enable", "boot.timer", "secs.timer", "tz.timer", "eom.timer" });
    for ([_][]const u8{ "boot", "secs", "tz", "eom" }) |n| {
        try indexHas(&t, try std.fmt.allocPrint(t.a(), "timer\t{s}.timer\tbuiltin\t", .{n}));
    }
    try testing.expect(!t.exists(cron_d));
}

test "Scheduler=native refuses what it cannot do, Scheduler=builtin ignores the native one" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.config.timers_scheduler = .native;
    try t.expectRun(1, &.{ "enable", "foo.timer" });
    try h.expectContains(t.stderr(), "foo.timer: Scheduler=native, but no cron-like scheduler is installed and enabled");
    try testing.expect(!t.exists("/var/lib/fake-systemd/fake/index"));

    try installCronie(&t);
    try addTimer(&t, "boot", "OnBootSec=5min");
    try t.expectRun(1, &.{ "enable", "boot.timer" });
    try h.expectContains(t.stderr(), "boot.timer: Scheduler=native, but the timer cannot be expressed exactly for cronie");
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:cronie\t");

    t.ctx.config.timers_scheduler = .builtin;
    try t.expectRun(0, &.{ "reenable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tbuiltin\t");
    try testing.expect(!t.exists(cron_d));
}

test "user timers always use the built-in runner and need user services" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    t.ctx.scope = .user;
    t.fake.caps.user_services = false;
    try t.write("/root/.config/systemd/user/u.timer", "[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.write("/root/.config/systemd/user/u.service", "[Service]\nExecStart=/usr/bin/job\n", 0o644);
    try t.expectRun(1, &.{ "--user", "enable", "u.timer" });
    try h.expectContains(t.stderr(), "user timers need the built-in runner");
    try testing.expect(!t.exists(cron_d));
}

test "is-enabled, is-active, status and list-timers read the index" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(1, &.{ "is-enabled", "foo.timer" });
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try t.expectRun(3, &.{ "is-active", "foo.timer" });

    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try t.expectRun(0, &.{ "is-enabled", "foo.timer" });
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try t.expectRun(0, &.{ "is-active", "foo.timer" });
    try testing.expectEqualStrings("active\n", t.stdout());

    try t.expectRun(0, &.{ "status", "foo.timer" });
    try h.expectContains(t.stdout(), "* foo.timer - Timer foo\n");
    try h.expectContains(t.stdout(), "Active: active (waiting)");
    try h.expectContains(t.stdout(), "Trigger: ");
    try h.expectContains(t.stdout(), "left\n");
    try h.expectContains(t.stdout(), "Triggers: * foo.service\n");
    try h.expectContains(t.stdout(), "Scheduler: builtin\n");

    try t.expectRun(0, &.{"list-timers"});
    try h.expectContains(t.stdout(), "NEXT ");
    try h.expectContains(t.stdout(), " foo.timer foo.service\n");
    try h.expectContains(t.stdout(), "\n1 timers listed.\nPass --all to see loaded but inactive timers, too.\n");
    try t.expectRun(0, &.{ "list-timers", "--no-legend" });
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, t.stdout(), "\n"));
    try t.expectRun(0, &.{ "list-timers", "--all" });
    try h.expectNotContains(t.stdout(), "Pass --all");
}

test "start and stop arm and disarm; reload is refused" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "start", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tbuiltin\t");
    try t.expectRun(1, &.{ "reload", "foo.timer" });
    try h.expectContains(t.stderr(), "Job type reload is not applicable for unit foo.timer.");
    try t.expectRun(0, &.{ "stop", "foo.timer" });
    try h.expectNotContains(try t.indexText(), "timer\t");
}

test "enable of a timer without [Install] explains and succeeds; a missing timer fails" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/plain.timer", "[Timer]\nOnCalendar=daily\n", 0o644);
    try t.expectRun(0, &.{ "enable", "plain.timer" });
    try h.expectContains(t.stderr(), "The unit files have no installation config");
    try t.expectRun(1, &.{ "enable", "nope.timer" });
    try h.expectContains(t.stderr(), "nope.timer does not exist");
    try t.write("/usr/lib/systemd/system/bad.timer", "[Timer]\nOnCalendar=not a date\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.expectRun(1, &.{ "enable", "bad.timer" });
    try h.expectContains(t.stderr(), "bad.timer: invalid OnCalendar= 'not a date'");
    try t.write("/usr/lib/systemd/system/empty.timer", "[Timer]\n[Install]\nWantedBy=timers.target\n", 0o644);
    try t.expectRun(1, &.{ "enable", "empty.timer" });
    try h.expectContains(t.stderr(), "the timer has no OnCalendar=");
}

test "daemon-reload drops timers whose unit is gone and cleans the scheduler files" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try addTimer(&t, "boot", "OnBootSec=5min");
    try t.expectRun(0, &.{ "enable", "foo.timer", "boot.timer" });
    try testing.expect(t.exists(cron_d));
    try testing.expect(t.exists(runner_unit));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.timer");
    try t.expectRun(0, &.{"daemon-reload"});
    try testing.expect(!t.exists(cron_d));
    try h.expectNotContains(try t.indexText(), "foo.timer");
    try indexHas(&t, "timer\tboot.timer\tbuiltin\t");
    try testing.expect(t.exists(runner_unit));
    try testing.expect(t.rec.callIs(t.rec.calls.items.len - 2, &.{ "fakectl", "kill", "HUP", runner_service }));
    try t.fs.deleteFile("/usr/lib/systemd/system/boot.timer");
    try t.expectRun(0, &.{"daemon-reload"});
    try testing.expect(!t.exists(runner_unit));
    try testing.expect(!t.fake.serviceState(runner_service).enabled);
}

test "daemon-reload reassigns schedulers when the configuration changes" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try installCronie(&t);
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    try indexHas(&t, "timer\tfoo.timer\tcron:cronie\t");
    t.ctx.config.timers_scheduler = .builtin;
    try t.expectRun(0, &.{"daemon-reload"});
    try indexHas(&t, "timer\tfoo.timer\tbuiltin\t");
    try testing.expect(!t.exists(cron_d));
    try testing.expect(t.exists(runner_unit));
}

test "dry-run enable changes nothing" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "--dry-run", "enable", "foo.timer" });
    try h.expectContains(t.stdout(), "would arm timer foo.timer on builtin");
    try testing.expect(!t.exists(runner_unit));
    try testing.expect(!t.exists("/var/lib/fake-systemd/fake/index"));
}
