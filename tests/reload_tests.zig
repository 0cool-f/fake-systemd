// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;
const ActiveState = @import("fake_systemd").cli.output.ActiveState;
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
    t.ctx.config.deny = &.{"foo.service"};
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(generated_foo));
}

test "a dropped unit is disabled at boot but its running service is not stopped" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expect(t.fake.serviceState("foo").enabled);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(ActiveState.active, t.fake.serviceState("foo").state);
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(generated_foo));
    try testing.expect(!t.fake.serviceState("foo").enabled);
    try testing.expectEqual(ActiveState.active, t.fake.serviceState("foo").state);
}

test "dropping a unit on an init that removes the running service with its definition says so" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.detected = "runit";
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "foo.service: the unit is gone; runit stops foo as its definition is removed");
}

test "a dry-run daemon-reload that would drop a unit changes nothing and stops nothing" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "daemon-reload" }));
    try testing.expectEqualStrings(before, try t.snapshot());
    try testing.expect(t.fake.serviceState("foo").enabled);
    try testing.expectEqual(ActiveState.active, t.fake.serviceState("foo").state);
}

test "a missing ExecStart binary keeps the generated service until the binary is back" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const generated = try t.read(generated_foo);
    try t.fs.deleteFile("/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(generated, try t.read(generated_foo));
    try testing.expect(t.fake.serviceState("foo").enabled);
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tmissing\t");
    try h.expectContains(t.stderr(), "foo.service: the ExecStart executable does not exist");

    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(generated, try t.read(generated_foo));

    try t.write("/usr/bin/foo", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(generated, try t.read(generated_foo));
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tmanaged\t");
    try testing.expect(t.fake.serviceState("foo").enabled);
}

test "a unit file that is a dangling link for a moment is not garbage collected" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try t.fs.symLink("/usr/lib/systemd/system/foo.service.new", "/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(generated_foo));
    try testing.expect(t.fake.serviceState("foo").enabled);
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tmissing\t");
}

test "an entry that fails does not keep the others from being reloaded" {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "bar.service", "/usr/bin/bar", "WantedBy=multi-user.target");
    try t.addFoo();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "bar", "foo" }));
    try t.fs.deleteFile("/usr/lib/fake.d/bar");
    try t.fs.makePath("/usr/lib/fake.d/bar");
    try t.addUnit("/usr/lib/systemd/system", "bar.service", "/usr/bin/bar2", "WantedBy=multi-user.target");
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 1), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "bar.service: ");
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo2");
    try testing.expectEqual(@as(usize, 1), t.fake.reload_count);
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

const index_path = "/var/lib/fake-systemd/fake/index";

test "an index written by a newer version is not changed by a mutating verb" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const newer = "# fake-systemd index v9 backend=fake generator=1 config=whatever\nunit\tsomething\tnew\n";
    try t.write(index_path, newer, 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "newer fake-systemd");
    try testing.expectEqual(@as(u8, 1), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(newer, try t.read(index_path));
    try testing.expect(t.exists(generated_foo));
}

test "an index that cannot be read is an error and is not replaced" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.fs.deleteFile(index_path);
    try t.fs.makePath(index_path);
    try testing.expectEqual(@as(u8, 1), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "cannot read the index");
    try testing.expect((try t.fs.stat(index_path)).kind == .directory);
}

test "a corrupt index is set aside before the entries are rebuilt from the markers" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write(index_path, "not an index at all\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "moved to " ++ index_path ++ ".bak.");
    try h.expectContains(try t.indexText(), "unit\tfoo.service\t");
    const entries = try t.fs.iterateDir(t.a(), "/var/lib/fake-systemd/fake");
    var saved = false;
    for (entries) |e| {
        if (!std.mem.startsWith(u8, e.name, "index.bak.")) continue;
        saved = true;
        try testing.expectEqualStrings("not an index at all\n", try t.read(try std.fs.path.join(t.a(), &.{ "/var/lib/fake-systemd/fake", e.name })));
    }
    try testing.expect(saved);
}

test "lines of the index that do not parse survive a reload" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const odd = "future-record\tx\ty";
    try t.write(index_path, try std.fmt.allocPrint(t.a(), "{s}{s}\n", .{ try t.indexText(), odd }), 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.indexText(), odd ++ "\n");
}

test "an index entry with a relative path is ignored and does not abort" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const hex = "xxh3:0000000000000001";
    const line = "unit\tevil.service\tsystem\tvendor\tmanaged\t" ++ hex ++ "\t" ++ hex ++ "\tetc/passwd=" ++ hex ++ ":" ++ hex ++ "\t\texplicit\t\t0.1.0";
    try t.write(index_path, try std.fmt.allocPrint(t.a(), "{s}{s}\n", .{ try t.indexText(), line }), 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(generated_foo));
    try h.expectContains(try t.indexText(), line ++ "\n");
}

test "a unit of the index whose files lie outside the service directories is never touched" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const body = "x\n";
    const victim = try marker.compose(t.a(), "evil.service", "/s/evil.service", 1, "fake-systemd 0.1.0 fake/1", body);
    try t.write("/etc/victim", victim, 0o644);
    const hex = "xxh3:0000000000000001";
    const line = try std.fmt.allocPrint(
        t.a(),
        "unit\tevil.service\tsystem\tvendor\tmanaged\t{s}\t{s}\t/etc/victim={f}:{s}\t\texplicit\t\t0.1.0",
        .{ hex, hex, h.index.hash.str(h.index.hash.bodyHash(body)), hex },
    );
    try t.write(index_path, try std.fmt.allocPrint(t.a(), "{s}{s}\n", .{ try t.indexText(), line }), 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(victim, try t.read("/etc/victim"));
    try h.expectContains(t.stderr(), "outside the directories");
}

test "a pending unit survives daemon-reload while its binary is missing and is written once it is back" {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/late.service", "[Service]\nExecStart=/usr/bin/late\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "late" }));
    try h.expectContains(try t.indexText(), "unit\tlate.service\tsystem\tvendor\tmissing\t");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.indexText(), "unit\tlate.service\tsystem\tvendor\tmissing\t");
    try testing.expect(!t.exists("/usr/lib/fake.d/late"));

    try t.write("/usr/bin/late", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists("/usr/lib/fake.d/late"));
    try h.expectContains(try t.indexText(), "unit\tlate.service\tsystem\tvendor\tmanaged\t");
}
