const std = @import("std");
const h = @import("harness.zig");

const testing = std.testing;
const fake = h.backend.Fake;

const generated_foo = "/usr/lib/fake.d/foo";

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
    try t.addNative("other", "/usr/bin/other");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
}

fn unitLine(t: *h.Harness) ![]const u8 {
    const text = try t.indexText();
    const start = std.mem.find(u8, text, "unit\tfoo.service").?;
    return text[start..std.mem.findScalarPos(u8, text, start, '\n').?];
}

test "an unchanged daemon-reload translates nothing and reads no unit or native file" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    const generated = t.fake.generate_count;
    const extracted = fake.extract_calls;
    const before = try t.snapshot();

    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(generated, t.fake.generate_count);
    try testing.expectEqual(extracted, fake.extract_calls);
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqualStrings(before, try t.snapshot());
}

test "native services are persisted in the index" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try h.expectContains(try t.indexText(), "native\tother\t/etc/fake-native/other\t");
}

test "touching the source updates the fingerprint and leaves generated files alone" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const before_line = try unitLine(&t);
    const before_file = try t.read(generated_foo);
    const before_stat = try t.fs.stat(generated_foo);
    const generated = t.fake.generate_count;

    const source = try t.read("/usr/lib/systemd/system/foo.service");
    try t.write("/usr/lib/systemd/system/foo.service", source, 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));

    const after_line = try unitLine(&t);
    try testing.expect(!std.mem.eql(u8, before_line, after_line));
    try testing.expectEqual(generated, t.fake.generate_count);
    try testing.expectEqualStrings(before_file, try t.read(generated_foo));
    try testing.expectEqual(before_stat.mtime_ns, (try t.fs.stat(generated_foo)).mtime_ns);
    try testing.expectEqualStrings("", t.stderr());

    // The refreshed fingerprint makes the next reload a pure skip.
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings(after_line, try unitLine(&t));
}

test "a content change regenerates" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const generated = t.fake.generate_count;
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.fake.generate_count > generated);
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo2");
}

test "a new drop-in invalidates the cached unit" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/bin/foo3", "#!/bin/sh\n", 0o755);
    try t.write("/etc/systemd/system/foo.service.d/o.conf", "[Service]\nExecStart=\nExecStart=/usr/bin/foo3\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo3");
}

test "an edited generated file is not skipped" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const edited = try std.mem.concat(t.a(), u8, &.{ try t.read(generated_foo), "# mine\n" });
    try t.write(generated_foo, edited, 0o644);
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "local changes kept");
}

test "a native service that is added or removed is picked up" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo-native", "/usr/bin/foo");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(t.stderr(), "using native service 'foo-native'");
    try testing.expect(!t.exists(generated_foo));
    try h.expectContains(try t.indexText(), "native\tfoo-native\t");

    try t.fs.deleteFile("/etc/fake-native/foo-native");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectNotContains(try t.indexText(), "foo-native");
    try h.expectNotContains(try t.indexText(), "unit\tfoo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(generated_foo));
}

test "a corrupted or absent index still gives correct results" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/var/lib/fake-systemd/fake/index", "garbage\x00\xff\nunit\tbroken\n", 0o644);
    try t.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo2", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(generated_foo), "exec = /usr/bin/foo2");
    try h.expectContains(try t.indexText(), "unit\tfoo.service\tsystem\tvendor\tmanaged\t");
    try h.expectContains(try t.indexText(), "native\tother\t");

    try t.fs.deleteFile("/var/lib/fake-systemd/fake/index");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
}
