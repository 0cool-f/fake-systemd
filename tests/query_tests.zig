const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
}

test "is-active output and exit codes" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "nope" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "nope", "foo" }));
    try testing.expectEqualStrings("inactive\nactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "-q", "is-active", "nope" }));
    try testing.expectEqualStrings("", t.stdout());
}

test "is-enabled output and exit codes" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "static.service", "/usr/bin/foo", null);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "static" }));
    try testing.expectEqualStrings("static\n", t.stdout());
    try testing.expectEqual(@as(u8, 4), t.run(&.{ "is-enabled", "nope" }));
    try testing.expectEqualStrings("not-found\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "nope", "foo" }));
    try testing.expectEqualStrings("not-found\nenabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 4), t.run(&.{ "-q", "is-enabled", "nope" }));
    try testing.expectEqualStrings("", t.stdout());
}

test "is-failed" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-failed", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try t.fake.setService("foo", .{ .state = .failed });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
}

test "show prints properties in order and --value only the value" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "foo" }));
    try testing.expectEqualStrings(
        \\Id=foo.service
        \\Names=foo.service
        \\Description=Unit foo.service
        \\LoadState=loaded
        \\ActiveState=active
        \\SubState=running
        \\UnitFileState=disabled
        \\FragmentPath=/usr/lib/systemd/system/foo.service
        \\MainPID=4242
        \\ExecMainStatus=0
        \\Type=simple
        \\
    , t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "ActiveState", "--value", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-P", "MainPID", "foo" }));
    try testing.expectEqualStrings("4242\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "LoadState", "--value", "nope" }));
    try testing.expectEqualStrings("not-found\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "Id", "foo", "nope" }));
    try testing.expectEqualStrings("Id=foo.service\n\nId=nope.service\n", t.stdout());
}

test "status block, exit codes and unsupported explanation" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "status", "foo" }));
    try testing.expectEqualStrings(
        \\o foo.service - Unit foo.service
        \\     Loaded: loaded (/usr/lib/systemd/system/foo.service; disabled)
        \\     Active: inactive (dead)
        \\
    , t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "     Active: active (running)\n");
    try h.expectContains(t.stdout(), "   Main PID: 4242\n");

    try testing.expectEqual(@as(u8, 4), t.run(&.{ "status", "nope" }));
    try testing.expectEqualStrings("Unit nope.service could not be found.\n", t.stderr());

    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=reboot.target\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "status", "hook" }));
    try h.expectContains(t.stdout(), "Note: not translated by fake-systemd: system lifecycle hook");
}

test "cat prints the fragment and drop-ins" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/etc/systemd/system/foo.service.d/o.conf", "[Service]\nNice=1\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "cat", "foo" }));
    try h.expectContains(t.stdout(), "# /usr/lib/systemd/system/foo.service\n[Unit]\n");
    try h.expectContains(t.stdout(), "\n# /etc/systemd/system/foo.service.d/o.conf\n[Service]\nNice=1\n");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "cat", "nope" }));
    try h.expectContains(t.stderr(), "No files found for nope.service.");
}

test "list-unit-files table, sorting, preset column and exit code" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "static.service", "/usr/bin/foo", null);
    try t.write("/usr/lib/systemd/system/systemd-x.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/lib/systemd/system-preset/90.preset", "enable foo.service\ndisable *\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"list-unit-files"}));
    try testing.expectEqualStrings(
        \\UNIT FILE         STATE       PRESET
        \\foo.service       enabled     enabled
        \\static.service    static      disabled
        \\systemd-x.service unsupported disabled
        \\
        \\3 unit files listed.
        \\
    , t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "list-unit-files", "--no-legend", "--state=static" }));
    try testing.expectEqualStrings("static.service static disabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "list-unit-files", "-t", "timer" }));
    try testing.expectEqualStrings("UNIT FILE STATE PRESET\n\n0 unit files listed.\n", t.stdout());
}

test "list-units shows translated units" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "list-units", "--no-legend", "--all", "--plain" }));
    try testing.expectEqualStrings("foo.service loaded inactive dead Unit foo.service\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "list-units", "--no-legend", "--plain" }));
    try testing.expectEqualStrings("", t.stdout());
}

test "list-timers prints the empty table" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"list-timers"}));
    try h.expectContains(t.stdout(), "0 timers listed.");
}

test "is-system-running" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"is-system-running"}));
    try testing.expectEqualStrings("running\n", t.stdout());
}

test "glob arguments expand over known unit files" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "foo-a.service", "/usr/bin/foo", "WantedBy=multi-user.target");
    try t.addUnit("/usr/lib/systemd/system", "foo-b.service", "/usr/bin/foo", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo-*" }));
    try testing.expectEqualStrings("inactive\ninactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo-*" }));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "restart", "foo-a" }));
    try testing.expect(t.rec.callIs(1, &.{ "fakectl", "restart", "foo-b" }));
}
