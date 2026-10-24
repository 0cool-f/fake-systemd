// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
}

test "dry-run enable prints diff and actions and leaves the tree byte-identical" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "--now", "foo" }));
    try testing.expectEqualStrings(before, try t.snapshot());
    try h.expectContains(t.stdout(), "--- a/usr/lib/fake.d/foo\n+++ b/usr/lib/fake.d/foo\n");
    try h.expectContains(t.stdout(), "+# Generated automatically by fake-systemd.");
    try h.expectContains(t.stdout(), "+exec = /usr/bin/foo\n");
    try h.expectContains(t.stdout(), "would create symlink '/etc/fake.d/enabled/foo' -> '/etc/fake.d/foo'\n");
    try h.expectContains(t.stdout(), "would run: fakectl start foo\n");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try testing.expectEqualStrings("", t.stderr());
}

test "dry-run through the environment variable setting" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.config.dry_run = true;
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqualStrings(before, try t.snapshot());
    try h.expectContains(t.stdout(), "would run: fakectl start foo\n");
}

test "dry-run daemon-reload reports the changes it would make" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "daemon-reload" }));
    try testing.expectEqualStrings(before, try t.snapshot());
    try h.expectContains(t.stdout(), "-exec = /usr/bin/foo\n+exec = /usr/bin/foo2\n");
    try h.expectContains(t.stdout(), "would run: fakectl reload-manager\n");

    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    const before_gc = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "daemon-reload" }));
    try testing.expectEqualStrings(before_gc, try t.snapshot());
    try h.expectContains(t.stdout(), "remove /usr/lib/fake.d/foo\n");
}

test "dry-run mask, revert and edit write nothing" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "mask", "foo" }));
    try h.expectContains(t.stdout(), "would create symlink '/etc/systemd/system/foo.service' -> '/dev/null'\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "revert", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "edit", "foo" }));
    try h.expectContains(t.stdout(), "would run: vi /etc/systemd/system/foo.service.d/override.conf\n");
    try testing.expectEqualStrings(before, try t.snapshot());
}

test "offline runtime verbs print a notice and exit 0 without touching the backend" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "init is not running, not contacting it: skipping 'start foo.service'");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.exists("/usr/lib/fake.d/foo"));

    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try testing.expectEqual(@as(u8, 1), t.run(&.{"is-system-running"}));
    try testing.expectEqualStrings("offline\n", t.stdout());
}

test "offline enable still translates and enables; --now only prints the notice" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(t.exists("/usr/lib/fake.d/foo"));
    try testing.expect(t.fake.serviceState("foo").enabled);
    try h.expectContains(t.stderr(), "skipping 'start foo.service'");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
}

test "the --root option switches to offline mode" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--root=/somewhere", "start", "foo" }));
    try h.expectContains(t.stderr(), "init is not running");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
}

test "-q hides notices but not errors" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "-q", "start", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "-q", "enable", "nope" }));
    try h.expectContains(t.stderr(), "does not exist");

    try t.addNative("foo", "/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "-q", "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expect(t.fake.serviceState("foo").enabled);
}

test "-q suppresses the symlink lines" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "-q", "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}
