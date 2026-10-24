// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;
const marker = h.index.marker;

const generated_foo = "/usr/lib/fake.d/foo";

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
}

test "enable of a candidate generates a marked file, indexes it and enables the service" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const content = try t.read(generated_foo);
    const parsed = marker.parse(content).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("/usr/lib/systemd/system/foo.service", parsed.marker.source);
    try testing.expect(parsed.bodyIntact());
    try testing.expect(t.fake.serviceState("foo").enabled);
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tmanaged\t");
    try h.expectContains(t.stderr(), "Created symlink '/etc/fake.d/enabled/foo' -> '/etc/fake.d/foo'.");
    try testing.expectEqualStrings("", t.stdout());
}

test "enable of an admin unit lands in the admin directory" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/etc/systemd/system", "mine.service", "/usr/bin/mine", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "mine.service" }));
    try testing.expect(t.exists("/etc/fake.d/mine"));
}

test "enable --now starts the service through the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "start", "foo" }));
    try testing.expectEqual(h.core.Fs.Kind.file, (try t.fs.stat(generated_foo)).kind);
    try testing.expect(t.fake.serviceState("foo").state == .active);
}

test "enable of a lifecycle hook is refused with the classifier reason" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "hook" }));
    try h.expectContains(t.stderr(), "hook.service: not translated: system lifecycle hook");
    try testing.expect(!t.exists("/usr/lib/fake.d/hook"));
    try testing.expect(!t.exists("/var/lib/fake-systemd/fake/index"));
}

test "units without install config print the systemd explanation and succeed" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "static.service", "/usr/bin/foo", null);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "static" }));
    try h.expectContains(t.stderr(), "The unit files have no installation config");
    try testing.expect(!t.exists("/usr/lib/fake.d/static"));
}

test "start translates a static unit" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "static.service", "/usr/bin/foo", null);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "static" }));
    try testing.expect(t.exists("/usr/lib/fake.d/static"));
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "start", "static" }));
}

test "native service found by name is used and nothing is generated" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo", "/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(generated_foo));
    try testing.expect(t.fake.serviceState("foo").enabled);
    try h.expectContains(t.stderr(), "foo.service: using native service 'foo' (/etc/fake-native/foo) instead of generating one");
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tnative\t");

    // The notice is shown once.
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try h.expectNotContains(t.stderr(), "using native service");
}

test "native service found by executable is used under its own name" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo-wrapper", "/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(generated_foo));
    try testing.expect(t.fake.serviceState("foo-wrapper").enabled);
    try testing.expect(!t.fake.serviceState("foo").enabled);
}

test "native name taken by another program is a conflict" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo", "/usr/bin/else");
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "taken by native service 'foo'");
    try h.expectContains(t.stderr(), "[Aliases]");
    try testing.expect(!t.exists(generated_foo));
}

test "configured alias maps the unit to a native service" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("custom", "/usr/bin/foo");
    try t.ctx.config.aliases.put(t.a(), "foo.service", "custom");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.fake.serviceState("custom").enabled);
}

test "disable and reenable drive the backend and keep the generated file" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try h.expectContains(t.stderr(), "Removed '/etc/fake.d/enabled/foo'.");
    try testing.expect(t.exists(generated_foo));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reenable", "foo" }));
    try testing.expect(t.fake.serviceState("foo").enabled);
}

test "Also= units are enabled too" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "main.service", "/usr/bin/main", "WantedBy=multi-user.target\nAlso=side.service");
    try t.addUnit("/usr/lib/systemd/system", "side.service", "/usr/bin/side", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "main" }));
    try testing.expect(t.fake.serviceState("side").enabled);
}

test "template instance gets its own generated service" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists("/usr/lib/fake.d/tpl@one"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "tpl@.service" }));
    try h.expectContains(t.stderr(), "template unit without DefaultInstance=");
}

test "enable errors: missing, masked, invalid, no arguments" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "nope" }));
    try h.expectContains(t.stderr(), "Failed to enable unit: Unit nope.service does not exist");

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "mask", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "Failed to enable unit: Unit /etc/systemd/system/foo.service is masked");

    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "../etc/passwd" }));
    try h.expectContains(t.stderr(), "invalid unit name");
    try testing.expectEqualStrings(before, try t.snapshot());

    try testing.expectEqual(@as(u8, 1), t.run(&.{"enable"}));
    try h.expectContains(t.stderr(), "too few arguments");
}

test "mask and unmask manage the /dev/null symlink" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "mask", "foo" }));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/dev/null", try t.fs.readLink("/etc/systemd/system/foo.service", &buf));
    try h.expectContains(t.stderr(), "Created symlink '/etc/systemd/system/foo.service' -> '/dev/null'.");
    try testing.expect(!t.fake.serviceState("foo").enabled);

    _ = t.run(&.{ "is-enabled", "foo" });
    try testing.expectEqualStrings("masked\n", t.stdout());

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "unmask", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/systemd/system/foo.service'.");
    try testing.expect(!t.exists("/etc/systemd/system/foo.service"));
}

test "revert removes generated files, drop-ins and the index entry" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.write("/etc/systemd/system/foo.service.d/override.conf", "[Service]\nNice=3\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expect(!t.exists(generated_foo));
    try testing.expect(!t.exists("/etc/systemd/system/foo.service.d"));
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try h.expectContains(t.stderr(), "Removed '/usr/lib/fake.d/foo'.");
    try h.expectContains(t.stderr(), "Removed '/etc/systemd/system/foo.service.d/override.conf'.");
    try h.expectNotContains(try t.indexText(), "foo.service");
}

test "revert keeps a modified generated file as .fssave" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const edited = try std.mem.concat(t.a(), u8, &.{ try t.read(generated_foo), "# mine\n" });
    try t.write(generated_foo, edited, 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "foo" }));
    try testing.expect(!t.exists(generated_foo));
    try testing.expectEqualStrings(edited, try t.read("/var/lib/fake-systemd/backup/fake/usr/lib/fake.d/foo.fssave"));
    try h.expectContains(t.stderr(), "source unit removed, modified file saved to");
}

test "backend failure becomes exit 1" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.rec.code = 1;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
}
