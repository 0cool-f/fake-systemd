// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;
const marker = h.index.marker;

const generated_foo = "/usr/lib/fake.d/foo";
const backup_dir = "/var/lib/fake-systemd/backup/fake";

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
}

fn editGenerated(t: *h.Harness) ![]const u8 {
    const edited = try std.mem.concat(t.a(), u8, &.{ try t.read(generated_foo), "# local tweak\n" });
    try t.write(generated_foo, edited, 0o644);
    return edited;
}

test "daemon-reload with nothing changed is silent and reloads the backend" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const before = try t.read(generated_foo);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqualStrings("", t.stdout());
    try testing.expectEqualStrings(before, try t.read(generated_foo));
    try testing.expectEqual(@as(usize, 1), t.fake.reload_count);
    try testing.expect(t.rec.callIs(0, &.{ "fakectl", "reload-manager" }));
}

test "user edit survives daemon-reload silently while the source is unchanged" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const edited = try editGenerated(&t);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqualStrings(edited, try t.read(generated_foo));
}

test "new upstream version next to a local edit saves .fsnew and keeps the file" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const edited = try editGenerated(&t);
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "foo.service: local changes kept, new version saved to " ++ backup_dir ++ "/usr/lib/fake.d/foo.fsnew");
    try testing.expectEqualStrings(edited, try t.read(generated_foo));
    try h.expectContains(try t.read(backup_dir ++ "/usr/lib/fake.d/foo.fsnew"), "exec = /usr/bin/foo2");
}

test "new upstream version without local edits overwrites the generated file" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo2");
}

test "source removed: unmodified file is garbage collected" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expect(!t.exists(generated_foo));
    try h.expectNotContains(try t.indexText(), "foo.service");
}

test "source removed: modified file is saved as .fssave" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const edited = try editGenerated(&t);
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "foo.service: source unit removed, modified file saved to " ++ backup_dir ++ "/usr/lib/fake.d/foo.fssave");
    try testing.expect(!t.exists(generated_foo));
    try testing.expectEqualStrings(edited, try t.read(backup_dir ++ "/usr/lib/fake.d/foo.fssave"));
}

test "marker removed by the user: the file is adopted as native" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const parsed = marker.parse(try t.read(generated_foo)).?;
    const body = try parsed.bodyAlloc(t.a());
    try t.write(generated_foo, body, 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tnative\t");
    try testing.expectEqualStrings(body, try t.read(generated_foo));
    try testing.expectEqualStrings("", t.stderr());
}

test "generated file removed by the user is not recreated by daemon-reload but is by enable" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile(generated_foo);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "generated file " ++ generated_foo ++ " is missing");
    try testing.expect(!t.exists(generated_foo));
    try h.expectContains(try t.indexText(), "\tmissing\t");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(generated_foo));
}

test "a native service that appears takes over a managed unit" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo-native", "/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "using native service 'foo-native'");
    try testing.expect(!t.exists(generated_foo));
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tnative\t");
}

test "a unit that became unsupported is dropped" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile("/usr/bin/foo");
    try t.write("/usr/lib/systemd/system/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(generated_foo));
}

test "daemon-reload rebuilds a lost index from markers" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile("/var/lib/fake-systemd/fake/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(generated_foo));
}

test "Translate=eager translates candidates without enabling them" {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.addFoo();
    try t.addUnit("/usr/lib/systemd/system", "static.service", "/usr/bin/foo", null);
    t.ctx.config.translate = .eager;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(generated_foo));
    try testing.expect(!t.exists("/usr/lib/fake.d/static"));
    try testing.expect(!t.fake.serviceState("foo").enabled);
}

test "offline daemon-reload syncs files without contacting the backend" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.offline = true;
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo2");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expectEqual(@as(usize, 0), t.fake.reload_count);
}
