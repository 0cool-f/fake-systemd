// SPDX-License-Identifier: GPL-3.0-or-later
//! The s6-rc backend behind the real `ops` entry point, with a runner that answers like the
//! s6 tools: the compile flow of a plain s6-rc system, and the repository flow of Artix.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("s6_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const up_text = "up (pid 4242 pgid 4242) 5 seconds\n";
const live = "/run/s6-rc";
const sources = "/etc/s6-rc/source";

/// Writes a service unit with the given sections and the executable it names.
fn addService(t: *h.Harness, name: []const u8, unit_section: []const u8, service: []const u8) !void {
    const path = try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name});
    const text = try std.fmt.allocPrint(
        t.a(),
        "{s}\n[Service]\nExecStart=/usr/bin/{s} --go\n{s}\n[Install]\nWantedBy=multi-user.target\n",
        .{ unit_section, name, service },
    );
    try t.write(path, text, 0o644);
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name}), "#!/bin/sh\n", 0o755);
}

const Fixture = struct {
    t: h.Harness = undefined,
    b: world.S6Rc = undefined,
    sc: world.Script = undefined,
    artix: bool = false,

    fn init(f: *Fixture, artix: bool) !void {
        f.artix = artix;
        try f.t.init();
        if (artix) try world.populateArtix(&f.t) else try world.populateRc(&f.t);
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a(), .fs = &f.t.fs };
        f.bind();
        f.t.detected = "s6-rc";
    }

    fn bind(f: *Fixture) void {
        world.useRc(&f.t, &f.b, if (f.artix) "artix" else "generic");
        f.t.backend_override = f.b.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    /// Fails with the recorded calls when `prefix` was not among them.
    fn expectCalled(f: *Fixture, prefix: []const []const u8) !void {
        if (!f.sc.called(prefix)) {
            std.debug.print("no call starts with {s}; calls:\n{s}", .{ prefix[0], try f.sc.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    /// Fails with the recorded calls when call `index` is not `expected`.
    fn expectCall(f: *Fixture, index: usize, expected: []const []const u8) !void {
        if (!f.sc.callIs(index, expected)) {
            std.debug.print("call {d} is not {s}...; calls:\n{s}", .{ index, expected[0], try f.sc.dump(f.t.a()) });
            return error.TestExpectedCall;
        }
    }

    fn link(f: *Fixture, path: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        return f.t.a().dupe(u8, try f.t.fs.readLink(path, &buf));
    }

    /// Marks `foo` as known to the live database and running.
    fn running(f: *Fixture) void {
        f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", live ++ "/servicedirs/foo-srv" }, .stdout = up_text }};
    }
};

// ---- generation and the compile flow ----------------------------------------------------------

test "enable writes the pipeline, lists it in the boot bundle, compiles and updates the live database" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const run = marker.parse(try t.read(sources ++ "/foo-srv/run")).?;
    try testing.expectEqualStrings("foo.service", run.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 s6-rc/2", run.marker.generator);
    try testing.expect(run.bodyIntact());
    try testing.expectEqualStrings("longrun\n", try t.read(sources ++ "/foo-srv/type"));
    try testing.expectEqualStrings("foo-log\n", try t.read(sources ++ "/foo-srv/producer-for"));
    try testing.expectEqualStrings("foo-srv\n", try t.read(sources ++ "/foo-log/consumer-for"));
    try testing.expectEqualStrings("foo\n", try t.read(sources ++ "/foo-log/pipeline-name"));
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(sources ++ "/foo-srv/run")).mode);
    try testing.expect(t.exists(sources ++ "/default/contents.d/foo"));
    try h.expectContains(t.stderr(), "Created '" ++ sources ++ "/default/contents.d/foo'.");
    try f.expectCall(0, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-2", sources });
    try f.expectCall(1, &.{ "s6-rc-update", "-l", live, "/etc/s6-rc/compiled-2" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
    try testing.expectEqualStrings("compiled-2", try f.link("/etc/s6-rc/compiled"));
    // The previous database was not built by fake-systemd, so it stays.
    try testing.expect(t.exists("/etc/s6-rc/compiled-1"));
    try testing.expect(t.exists("/etc/s6-rc/compiled-2/fake-systemd.db"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "the boot bundle is created when the sources do not have one" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteTree(sources ++ "/default");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("bundle\n", try t.read(sources ++ "/default/type"));
    try testing.expect(t.exists(sources ++ "/default/contents.d/foo"));
}

test "the index records every generated file and a lost index is rebuilt from the markers" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const index_text = try t.read("/var/lib/fake-systemd/s6-rc/index");
    for ([_][]const u8{ "foo-srv/run", "foo-srv/finish", "foo-srv/type", "foo-srv/fake-systemd.meta", "foo-log/run", "foo-log/pipeline-name" }) |p| {
        try h.expectContains(index_text, p);
    }

    try t.fs.deleteFile("/var/lib/fake-systemd/s6-rc/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    for ([_][]const u8{ "foo-srv/run", "foo-srv/finish", "foo-srv/type", "foo-srv/timeout-kill", "foo-srv/fake-systemd.meta", "foo-log/run", "foo-log/consumer-for", "foo-log/fake-systemd.meta" }) |p| {
        const path = try std.fmt.allocPrint(t.a(), "{s}/{s}", .{ sources, p });
        try testing.expect(!t.exists(path));
    }
}

test "a native service is found by its executable and a generated one is never taken for native" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.write(sources ++ "/mynat/type", "longrun\n", 0o644);
    try t.write(sources ++ "/mynat/run", "#!/bin/execlineb -P\nfdmove -c 2 1\nexec /usr/bin/foo --run\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(t.exists(sources ++ "/default/contents.d/mynat"));
    try t.addUnit("/usr/lib/systemd/system", "bar.service", "/usr/bin/bar", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "bar" }));
    try testing.expect(t.exists(sources ++ "/bar-srv/run"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists(sources ++ "/bar-srv/run"));
}

test "enable offline in the real root compiles but leaves the live database alone" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    f.b.offline_install = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(sources ++ "/default/contents.d/foo"));
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    try f.expectCall(0, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-2", sources });
    try testing.expectEqualStrings("compiled-2", try f.link("/etc/s6-rc/compiled"));
}

test "enable inside a --root tree writes the sources and defers the database with a notice" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(t.exists(sources ++ "/default/contents.d/foo"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try h.expectContains(t.stderr(), "the service database is not rebuilt inside a --root tree");
    try testing.expectEqualStrings("compiled-1", try f.link("/etc/s6-rc/compiled"));
}

test "a failing compile fails the enable and keeps the database in use" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{"s6-rc-compile"}, .code = 1, .stdout = "s6-rc-compile: fatal: cyclic service dependency\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "s6-rc-compile exited 1: s6-rc-compile: fatal: cyclic service dependency");
    try testing.expectEqualStrings("compiled-1", try f.link("/etc/s6-rc/compiled"));
    try testing.expect(!t.exists("/etc/s6-rc/compiled-2"));
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "a failing update leaves the compiled link where it was" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{"s6-rc-update"}, .code = 111 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("compiled-1", try f.link("/etc/s6-rc/compiled"));
}

test "a compiled directory that is not a link is kept under a numbered name" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteFile("/etc/s6-rc/compiled");
    try t.fs.deleteTree("/etc/s6-rc/compiled-1");
    try t.write("/etc/s6-rc/compiled/db", "", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("compiled-1", try f.link("/etc/s6-rc/compiled"));
    try testing.expect(t.exists("/etc/s6-rc/compiled-0/db"));
}

test "a database that is not ours is never removed: compiled-0 and numbered directories of the administrator stay" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.fs.deleteFile("/etc/s6-rc/compiled");
    try t.fs.deleteTree("/etc/s6-rc/compiled-1");
    try t.write("/etc/s6-rc/compiled/db", "", 0o644);
    try t.write("/etc/s6-rc/compiled-0/my-notes", "precious\n", 0o644);
    try t.write("/etc/s6-rc/compiled-7/db", "", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("precious\n", try t.read("/etc/s6-rc/compiled-0/my-notes"));
    try testing.expect(t.exists("/etc/s6-rc/compiled-7/db"));
    // The directory that stood for `compiled` was kept under a name that was free.
    try testing.expect(t.exists("/etc/s6-rc/compiled-9/db"));
    // A link to a directory of the administrator is not followed by the removal of the old database.
    try t.fs.deleteFile("/etc/s6-rc/compiled");
    try t.fs.symLink("compiled-7", "/etc/s6-rc/compiled");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expect(t.exists("/etc/s6-rc/compiled-7/db"));
}

test "the previous database is removed when fake-systemd built it" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists("/etc/s6-rc/compiled-2"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("compiled-3", try f.link("/etc/s6-rc/compiled"));
    try testing.expect(!t.exists("/etc/s6-rc/compiled-2"));
    try testing.expect(t.exists("/etc/s6-rc/compiled-1"));
}

test "disable takes the service out of the boot bundle and builds the database again" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '" ++ sources ++ "/default/contents.d/foo'.");
    try testing.expect(!t.exists(sources ++ "/default/contents.d/foo"));
    try testing.expect(t.exists(sources ++ "/foo-srv/run"));
    try f.expectCall(0, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-3", sources });
    try f.expectCall(1, &.{ "s6-rc-update", "-l", live, "/etc/s6-rc/compiled-3" });
    try testing.expectEqualStrings("compiled-3", try f.link("/etc/s6-rc/compiled"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "is-enabled follows the boot bundle" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try t.addUnit("/usr/lib/systemd/system", "syslog.service", "/usr/bin/native", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "syslog" }));
}

test "daemon-reload builds the database again and updates the live one" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCall(0, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-2", sources });
    try f.expectCall(1, &.{ "s6-rc-update", "-l", live, "/etc/s6-rc/compiled-2" });
    t.ctx.offline = true;
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "dry-run enable prints what it would do and writes nothing" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "foo" }));
    try h.expectContains(t.stdout(), "would create '" ++ sources ++ "/default/contents.d/foo'");
    try h.expectContains(t.stdout(), "would run: s6-rc-compile /etc/s6-rc/compiled-2 " ++ sources);
    try h.expectContains(t.stdout(), "would run: s6-rc-update -l /run/s6-rc /etc/s6-rc/compiled-2");
    try testing.expect(!t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(!t.exists(sources ++ "/default/contents.d/foo"));
    try testing.expectEqualStrings("compiled-1", try f.link("/etc/s6-rc/compiled"));
}

// ---- runtime control --------------------------------------------------------------------

test "start of a service the live database does not know builds the database first" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc-db", "-l", live, "type", "foo" }, .code = 3 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "s6-rc-db", "-l", live, "type", "foo" });
    try f.expectCall(1, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-2", sources });
    try f.expectCall(2, &.{ "s6-rc-update", "-l", live, "/etc/s6-rc/compiled-2" });
    try f.expectCalled(&.{ "s6-rc", "-l", live, "-u", "change", "foo" });
    try testing.expect(!t.exists(sources ++ "/default/contents.d/foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
}

test "start of a known service is a single s6-rc change, and nothing when it is running" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.count(&.{"s6-rc-compile"}));
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-rc", "-l", live, "-u", "change", "foo" });
    f.sc.calls.clearRetainingCapacity();
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.count(&.{ "s6-rc", "-l", live, "-u" }));
}

test "a service s6-rc lists as up whose process was stopped is started through its supervisor" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-a", "list" }, .stdout = "foo-log\nfoo-srv\n" }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCalled(&.{ "s6-svc", "-wu", "-T", "10000", "-u", live ++ "/servicedirs/foo-srv" });
    try testing.expectEqual(@as(usize, 0), f.sc.count(&.{ "s6-rc", "-l", live, "-u" }));
}

test "a failing s6-rc change fails the start with its output" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-u" }, .code = 1, .stdout = "s6-rc: warning: unable to start service foo-srv: command exited 1\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "s6-rc exited 1: s6-rc: warning: unable to start service foo-srv: command exited 1");
}

test "stop brings the pipeline down, waits for finish, and records a clean end" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try t.write(live ++ "/servicedirs/foo-srv/supervise/exit-status", "failed 256 9\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "s6-rc", "-l", live, "-d", "change", "foo" });
    try f.expectCall(1, &.{ "s6-svwait", "-D", "-t", "60000", live ++ "/servicedirs/foo-srv" });
    try testing.expectEqualStrings("ok 0 0\n", try t.read(live ++ "/servicedirs/foo-srv/supervise/exit-status"));
}

test "stop of a service that is not in the live database succeeds" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-d" }, .code = 3 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
}

test "stop that s6-rc cannot finish while the service runs is a failure" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.rules = &.{
        .{ .prefix = &.{ "s6-rc", "-l", live, "-d" }, .code = 1, .stdout = "s6-rc: fatal: timed out\n" },
        .{ .prefix = &.{"s6-svstat"}, .stdout = up_text },
    };
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
}

test "restart is a stop followed by a start" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(0, &.{ "s6-rc", "-l", live, "-d", "change", "foo" });
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-rc", "-l", live, "-u", "change", "foo" });
}

test "status maps s6-svstat output to systemd states" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expect(f.sc.called(&.{ "s6-svstat", live ++ "/servicedirs/foo-srv" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "status", "foo" }));
    try h.expectContains(t.stdout(), "Active: active (running)");
    try h.expectContains(t.stdout(), "Main PID: 4242");
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = "down (exitcode 3) 0 seconds, normally up, ready 0 seconds\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = "down (exitcode 3) 0 seconds, normally up, want up, ready 0 seconds\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("activating\n", t.stdout());
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = "down (signal SIGTERM) 1 seconds, ready 1 seconds\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = "s6-svstat: fatal: unable to read status for x: s6-supervise not running\n" }};
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
}

test "the exit status recorded by finish tells a failure from a clean stop" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const killed = "down (signal SIGKILL) 0 seconds, ready 0 seconds\n";
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = killed }};
    try t.write(live ++ "/servicedirs/foo-srv/supervise/exit-status", "failed 256 9\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try t.write(live ++ "/servicedirs/foo-srv/supervise/exit-status", "ok 0 0\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "kill goes through s6-svc -s with the signal name or number" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "SIGUSR1", "foo" }));
    try f.expectCall(0, &.{ "s6-svc", "-s", "USR1", live ++ "/servicedirs/foo-srv" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "--signal=28", "foo" }));
    try f.expectCall(1, &.{ "s6-svc", "-s", "28", live ++ "/servicedirs/foo-srv" });
    f.sc.rules = &.{.{ .prefix = &.{"s6-svc"}, .code = 111 }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
}

test "reload runs ExecReload= through the executor with the main pid, native services get SIGHUP" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "rel", "", "ExecReload=/usr/bin/rel --reload");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "rel" }));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", live ++ "/servicedirs/rel-srv" }, .stdout = "up (pid 77 pgid 77) 2 seconds\n" }};
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "rel" }));
    try f.expectCall(1, &.{ "env", "MAINPID=77", "/usr/bin/fake-systemd", "--exec", "rel.service", "--phase", "reload" });

    f.sc.calls.clearRetainingCapacity();
    try t.addUnit("/usr/lib/systemd/system", "syslog.service", "/usr/bin/native", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCall(0, &.{ "s6-svc", "-h", live ++ "/servicedirs/syslog" });
}

test "a service with ExecStop= runs its executor in stop mode, so s6-rc -d is the whole stop" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "hook", "", "ExecStop=/usr/bin/hook --stop\nKillSignal=SIGINT");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hook" }));
    try h.expectContains(try t.read(sources ++ "/hook-srv/run"), "\nexec /usr/bin/fake-systemd --exec hook.service --stop-on-signal\n");
    try testing.expect(!t.exists(sources ++ "/hook-srv/down-signal"));
    try testing.expectEqualStrings("190000\n", try t.read(sources ++ "/hook-srv/timeout-kill"));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", live ++ "/servicedirs/hook-srv" }, .stdout = "up (pid 88 pgid 88) 2 seconds\n" }};
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "hook" }));
    try f.expectCall(0, &.{ "s6-rc", "-l", live, "-d", "change", "hook" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
    try f.expectCall(1, &.{ "s6-svwait", "-D", "-t", "60000", live ++ "/servicedirs/hook-srv" });
}

test "power goes through s6-linux-init-hpr" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{ "s6-linux-init-hpr", "-p" });
    try f.expectCall(1, &.{ "s6-linux-init-hpr", "-r" });
    try f.expectCall(2, &.{ "s6-linux-init-hpr", "-h" });
}

// ---- oneshots -----------------------------------------------------------------------------

fn addOneshot(t: *h.Harness, name: []const u8, extra: []const u8) !void {
    const path = try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name});
    const text = try std.fmt.allocPrint(t.a(), "[Service]\nType=oneshot\nExecStart=/usr/bin/{s} --go\n{s}\n[Install]\nWantedBy=multi-user.target\n", .{ name, extra });
    try t.write(path, text, 0o644);
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name}), "#!/bin/sh\n", 0o755);
}

test "a oneshot is a oneshot service with up in execline and no logger of its own" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "job", "TimeoutStartSec=30\nTimeoutStopSec=20");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    try testing.expectEqualStrings("oneshot\n", try t.read(sources ++ "/job/type"));
    const up = marker.parse(try t.read(sources ++ "/job/up")).?;
    try testing.expectEqualStrings("#!/bin/execlineb -P\n", up.shebang);
    try h.expectContains(up.rest, "pipeline -w { /usr/bin/fake-systemd --log job.service }\nfdmove -c 2 1\n/usr/bin/job --go\n");
    try testing.expectEqualStrings("30000\n", try t.read(sources ++ "/job/timeout-up"));
    try testing.expectEqualStrings("20000\n", try t.read(sources ++ "/job/timeout-down"));
    try testing.expect(!t.exists(sources ++ "/job/down"));
    try testing.expect(!t.exists(sources ++ "/job-srv"));
    try testing.expect(t.exists(sources ++ "/default/contents.d/job"));
}

test "a oneshot without RemainAfterExit= runs again at each start and is inactive afterwards" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "job", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    f.sc.calls.clearRetainingCapacity();
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-a", "list" }, .stdout = "job\n" }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "job" }));
    try f.expectCall(1, &.{ "s6-rc", "-l", live, "-d", "change", "job" });
    try f.expectCall(2, &.{ "s6-rc", "-l", live, "-u", "change", "job" });
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "job" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "a oneshot with RemainAfterExit= stays active while s6-rc lists it" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "keep", "RemainAfterExit=yes");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "keep" }));
    try h.expectContains(try t.read(sources ++ "/keep/up"), "# fake-systemd flags: remain\n");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "keep" }));
    try testing.expectEqual(@as(usize, 0), f.sc.count(&.{ "s6-rc", "-l", live, "-d" }));
    try f.expectCalled(&.{ "s6-rc", "-l", live, "-u", "change", "keep" });
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "keep" }));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-a", "list" }, .stdout = "keep\n" }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "keep" }));
}

test "a oneshot is not a process: kill has nothing to signal" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "job", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "job" }));
    try h.expectContains(t.stderr(), "job: no process to signal");
}

// ---- dependencies ---------------------------------------------------------------------------

test "dependencies become a dependencies file, Wants= like Requires=, with the pipeline names" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "syslog.service", "/usr/bin/native", "WantedBy=multi-user.target");
    try addService(t, "app", "[Unit]\nRequires=dbus.service\nWants=postgresql.service syslog.service ghost.service\nAfter=network-online.target\n", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "app" }));
    try testing.expectEqualStrings("dbus\npostgresql\nsyslog\n", try t.read(sources ++ "/app-srv/dependencies"));
    try testing.expect(t.exists(sources ++ "/dbus-srv/run"));
    try testing.expect(t.exists(sources ++ "/postgresql-srv/run"));
    try testing.expect(!t.exists(sources ++ "/default/contents.d/dbus"));
    try testing.expect(!t.exists(sources ++ "/ghost-srv"));
}

test "enabled network providers become dependencies of units that wait for the network" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.write(sources ++ "/dhcpcd/type", "longrun\n", 0o644);
    try t.write(sources ++ "/dhcpcd/run", "#!/bin/sh\nexec /usr/bin/dhcpcd -B\n", 0o755);
    try t.write(sources ++ "/default/contents.d/dhcpcd", "", 0o644);
    try t.write("/usr/lib/systemd/system/net.service", "[Unit]\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/usr/bin/net\n", 0o644);
    try t.write("/usr/bin/net", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "net" }));
    try testing.expectEqualStrings("dhcpcd\n", try t.read(sources ++ "/net-srv/dependencies"));
}

test "a unit without dependencies has no dependencies file" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(!t.exists(sources ++ "/foo-srv/dependencies"));
}

// ---- identity, limits and the executor ---------------------------------------------------------

test "an account the executor cannot resolve is switched to by setpriv, and by s6-setuidgid without it" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "ldap", "", "User=svc-directory");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldap" }));
    try h.expectContains(try t.read(sources ++ "/ldap-srv/run"), "exec /usr/bin/setpriv --reuid=svc-directory --regid=\"$(id -g -- svc-directory)\" --init-groups /usr/bin/ldap --go\n");

    try t.fs.deleteFile("/usr/bin/setpriv");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read(sources ++ "/ldap-srv/run"), "exec s6-setuidgid svc-directory /usr/bin/ldap --go\n");
    try h.expectContains(t.stderr(), "setpriv is not installed, s6-setuidgid switches to svc-directory with the supplementary groups the system enumerates");
}

test "a oneshot of such an account runs setpriv through a shell that gets the command as arguments" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "ljob", "User=svc-directory");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ljob" }));
    const up = marker.parse(try t.read(sources ++ "/ljob/up")).?;
    try h.expectContains(up.rest, "sh -c \"exec /usr/bin/setpriv --reuid=svc-directory --regid=\\\"$(id -g -- svc-directory)\\\" --init-groups \\\"$@\\\"\" setpriv /usr/bin/ljob --go\n");
}

test "numeric limits become s6-softlimit options and others send the unit through the executor" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "lim", "", "LimitNOFILE=4096\nLimitCORE=0\nEnvironment=A=1\nUMask=0027\nNice=5\nWorkingDirectory=/srv");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "lim" }));
    const run = marker.parse(try t.read(sources ++ "/lim-srv/run")).?;
    try testing.expectEqualStrings(
        "exec 2>&1\nexport A=1\numask 0027\ncd /srv || exit 200\nexec /usr/bin/nice -n 5 s6-softlimit -H -o 4096 -c 0 /usr/bin/lim --go\n",
        run.rest,
    );
    try addService(t, "lim2", "", "LimitNOFILE=infinity");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "lim2" }));
    try h.expectContains(try t.read(sources ++ "/lim2-srv/run"), "exec /usr/bin/fake-systemd --exec lim2.service\n");
}

test "user scope is refused: there is no user service manager" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    const a = t.a();
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(a, testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "the s6-rc backend has no user services");
}

test "the timer runner is a generated service like any other" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    try h.expectContains(try t.read(sources ++ "/fake-systemd-timers-srv/run"), "\nexec /usr/bin/fake-systemd --timers\n");
    try testing.expect(t.exists(sources ++ "/default/contents.d/fake-systemd-timers"));
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-rc", "-l", live, "-u", "change", "fake-systemd-timers" });

    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", live ++ "/servicedirs/fake-systemd-timers-srv" }, .stdout = "up (pid 7 pgid 7) 3 seconds\n" }};
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-svc", "-s", "HUP", live ++ "/servicedirs/fake-systemd-timers-srv" });

    f.sc.rules = &.{};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists(sources ++ "/fake-systemd-timers-srv/run"));
    try testing.expect(!t.exists(sources ++ "/default/contents.d/fake-systemd-timers"));
}

// ---- the repository flow of Artix --------------------------------------------------------------

const artix_sources = "/etc/s6/adminsv";
const repo_active = "/etc/s6/repo/sources/current/active";

test "Artix: enable syncs the repository, enables the service with its dependencies and installs the set" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(artix_sources ++ "/foo-srv/run"));
    try f.expectCall(0, &.{ "s6", "repository", "sync" });
    try f.expectCall(1, &.{ "s6", "set", "enable", "-p", "foo" });
    try f.expectCall(2, &.{ "s6", "set", "commit" });
    try f.expectCall(3, &.{ "s6", "live", "install" });
    try testing.expectEqual(@as(usize, 4), f.sc.calls.items.len);
    try h.expectContains(t.stderr(), "Created symlink '" ++ repo_active ++ "/foo-srv' -> '../../.atomics/foo-srv'.");

    try t.fs.symLink("../../.atomics/foo-srv", repo_active ++ "/foo-srv");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "Artix: offline in the real root the first database is installed with --init" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    f.b.offline_install = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try f.expectCall(0, &.{ "s6", "repository", "sync" });
    try f.expectCall(1, &.{ "s6", "set", "enable", "-p", "foo" });
    try f.expectCall(2, &.{ "s6", "set", "commit" });
    try f.expectCall(3, &.{ "s6", "live", "install", "--init" });
}

test "Artix: inside a --root tree the set is left for the target" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.exists(artix_sources ++ "/foo-srv/run"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try h.expectContains(t.stderr(), "the service database is not rebuilt inside a --root tree");
}

test "Artix: disable removes the service from the set unless an enabled service needs it" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.symLink("../../.atomics/foo-srv", repo_active ++ "/foo-srv");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try f.expectCall(0, &.{ "s6", "set", "disable", "-i", "foo" });
    try f.expectCall(1, &.{ "s6", "set", "commit" });
    try f.expectCall(2, &.{ "s6", "live", "install" });
    try h.expectContains(t.stderr(), "Removed '" ++ repo_active ++ "/foo-srv'.");

    f.sc.calls.clearRetainingCapacity();
    f.sc.rules = &.{.{ .prefix = &.{ "s6", "set", "disable" }, .code = 1, .stdout = "s6-rc-set-change: fatal: the following services also need to be changed to \"usable\": bar-srv\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "s6 set disable -i foo exited 1: s6-rc-set-change: fatal: the following services also need to be changed");
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
}

test "Artix: is-enabled reads the working set, native services included" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/sshd.service", "[Service]\nExecStart=/usr/bin/sshd -D\n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/sshd", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.symLink("../../.atomics/foo-srv", repo_active ++ "/foo-srv");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "sshd" }));
    try t.fs.symLink("../../.atomics/sshd-srv", "/etc/s6/repo/sources/current/always/sshd-srv");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "sshd" }));
}

test "Artix: a native pipeline is found by its executable under the name without -srv" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/sshd.service", "[Service]\nExecStart=/usr/bin/sshd -D\n\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/sshd", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "sshd" }));
    try testing.expect(!t.exists(artix_sources ++ "/sshd-srv"));
    try f.expectCall(1, &.{ "s6", "set", "enable", "-p", "sshd" });
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "sshd" }));
    try f.expectCalled(&.{ "s6-rc", "-l", live, "-u", "change", "sshd-srv" });
}

test "Artix: daemon-reload syncs, commits and installs" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try f.expectCall(0, &.{ "s6", "repository", "sync" });
    try f.expectCall(1, &.{ "s6", "set", "commit" });
    try f.expectCall(2, &.{ "s6", "live", "install" });
}

test "the source directories a removed unit leaves empty are removed before the database is built" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(sources ++ "/foo-srv"));
    try testing.expect(!t.exists(sources ++ "/foo-log"));
    try testing.expect(t.exists(sources ++ "/default/type"));
    try testing.expect(t.exists(sources ++ "/syslog/run"));
    try f.expectCall(0, &.{ "s6-rc-compile", "/etc/s6-rc/compiled-3", sources });
}

test "Artix: the repository is synced after the empty directories of a removed unit are gone" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(artix_sources ++ "/foo-srv"));
    try testing.expect(!t.exists(artix_sources ++ "/foo-log"));
}

test "Artix: dry-run prints the s6 commands and writes nothing" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "foo" }));
    try h.expectContains(t.stdout(), "would create symlink '" ++ repo_active ++ "/foo-srv' -> '../../.atomics/foo-srv'");
    try h.expectContains(t.stdout(), "would run: s6 repository sync\nwould run: s6 set enable -p foo\nwould run: s6 set commit\nwould run: s6 live install\n");
    try testing.expect(!t.exists(artix_sources ++ "/foo-srv/run"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "Artix: the services of a collected dependency leave the working set before the repository is synced" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "dep", "", "");
    try addService(t, "main", "[Unit]\nRequires=dep.service\n", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "main" }));
    for ([_][]const u8{ "main-srv", "main-log", "dep-srv", "dep-log" }) |m| {
        try t.fs.symLink("../../.atomics/x", try std.fmt.allocPrint(t.a(), "{s}/{s}", .{ repo_active, m }));
    }
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "main" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/main.service");
    try t.fs.deleteFile("/usr/lib/systemd/system/dep.service");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(artix_sources ++ "/dep-srv"));
    // The reload may act on the units first; what matters is that the working set is cleaned
    // right before the repository is synced.
    var at: usize = 0;
    while (at < f.sc.calls.items.len and !f.sc.callIs(at, &.{ "s6", "set", "disable", "-p", "dep-log", "dep-srv", "main-log", "main-srv" })) at += 1;
    try f.expectCall(at, &.{ "s6", "set", "disable", "-p", "dep-log", "dep-srv", "main-log", "main-srv" });
    try f.expectCall(at + 1, &.{ "s6", "repository", "sync" });
    try f.expectCall(at + 2, &.{ "s6", "set", "commit" });
    try f.expectCall(at + 3, &.{ "s6", "live", "install" });
}

test "Artix: a service whose sources exist stays in the set, so does a package service" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.symLink("../../.atomics/x", repo_active ++ "/foo-srv");
    try t.fs.symLink("../../.atomics/x", repo_active ++ "/syslog-srv");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!f.sc.called(&.{ "s6", "set", "disable" }));
}

test "starting a oneshot whose command failed exits 1" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "job", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job" }));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-rc", "-l", live, "-u", "change", "job" }, .code = 1, .stdout = "s6-rc: warning: unable to start service job: command exited 1\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "job" }));
    try h.expectContains(t.stderr(), "unable to start service job");
}

// ---- names a unit may not take ------------------------------------------------------------------

test "a source directory that fake-systemd did not write is never generated into" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    // A oneshot of the administrator called foo, and a bundle that is the logger of another pipeline.
    try t.write(sources ++ "/foo/type", "oneshot\n", 0o644);
    try t.write(sources ++ "/foo/up", "#!/bin/execlineb -P\ntrue\n", 0o644);
    try testing.expect(t.run(&.{ "enable", "foo" }) != 0);
    try h.expectContains(t.stderr(), "was not generated by fake-systemd");
    try testing.expectEqualStrings("oneshot\n", try t.read(sources ++ "/foo/type"));
    try testing.expect(!t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(!t.exists(sources ++ "/foo/dependencies"));

    try addService(t, "bar", "", "");
    try t.write(sources ++ "/bar-log/type", "bundle\n", 0o644);
    try testing.expect(t.run(&.{ "enable", "bar" }) != 0);
    try testing.expect(!t.exists(sources ++ "/bar-srv/run"));
    try testing.expect(!t.exists(sources ++ "/bar-log/run"));
    try testing.expectEqualStrings("bundle\n", try t.read(sources ++ "/bar-log/type"));
}

test "the boot bundle and the names s6-rc keeps are not names of a unit" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addService(t, "default", "", "");
    try testing.expect(t.run(&.{ "enable", "default" }) != 0);
    try h.expectContains(t.stderr(), "keeps for itself");
    try testing.expectEqualStrings("bundle\n", try t.read(sources ++ "/default/type"));
    try addService(t, "s6rc-oneshot-runner", "", "");
    try testing.expect(t.run(&.{ "enable", "s6rc-oneshot-runner" }) != 0);
    try testing.expect(!t.exists(sources ++ "/s6rc-oneshot-runner-srv"));
}

test "the logger of one pipeline is not taken by a oneshot of another unit" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try addOneshot(t, "foo-log", "");
    try testing.expect(t.run(&.{ "enable", "foo-log" }) != 0);
    try h.expectContains(t.stderr(), "already generated for another unit");
    try h.expectContains(try t.read(sources ++ "/foo-log/consumer-for"), "foo-srv");
}

test "empty source directories are pruned only when the index lists files below them" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.fs.makePath(sources ++ "/placeholder");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(t.exists(sources ++ "/placeholder"));
}

test "Artix: a member of the working set that fake-systemd did not generate is not taken out of it" {
    var f: Fixture = .{};
    try f.init(true);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.symLink("../../.atomics/x", repo_active ++ "/other-srv");
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!f.sc.called(&.{ "s6", "set", "disable" }));
}

test "the Environment= of a oneshot with an account is not exported by the execline that root runs" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "envjob", "User=svc-directory\nEnvironment=PATH=/var/lib/svc/bin:/usr/bin");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "envjob" }));
    const up = try t.read(sources ++ "/envjob/up");
    try h.expectNotContains(up, "export");
    try h.expectNotContains(up, "var/lib/svc");
    try h.expectContains(up, "/usr/bin/fake-systemd --exec envjob.service");
}

test "an account the executor cannot resolve is given to it as numeric ids by a shell in the execline of a oneshot" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try addOneshot(t, "ldapjob", "User=svc-directory\nExecStartPre=/usr/bin/ldapjob --prep");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "ldapjob" }));
    const up = try t.read(sources ++ "/ldapjob/up");
    try h.expectContains(up, "sh -c \"exec \\\"$@\\\" --uid \\\"$(id -u -- svc-directory)\\\" --gid \\\"$(id -g -- svc-directory)\\\" --groups \\\"$(id -G -- svc-directory | tr ' ' ,)\\\"\" ids /usr/bin/fake-systemd --exec ldapjob.service\n");
    try h.expectNotContains(up, "setuidgid");
    try h.expectNotContains(up, "--identity-set");
}

test "daemon-reload with a lost index prunes our empty source directory and keeps the administrator's" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.fs.makePath(sources ++ "/placeholder");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.fs.deleteFile("/var/lib/fake-systemd/s6-rc/index");
    try t.fs.deleteFile("/var/lib/fake-systemd/s6-rc/owned-sources");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists(sources ++ "/foo-srv/run"));
    try testing.expect(t.exists(sources ++ "/placeholder"));
}

const ldap_script = "exec \"$0\" \"$@\" --uid \"$(id -u -- ldapuser)\" --gid \"$(id -g -- ldapuser)\" --groups \"$(id -G -- ldapuser | tr ' ' ,)\"";

test "reload gives the executor the numeric ids of an account only the system libc resolves" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/lib/systemd/system/ldap.service", "[Service]\nExecStart=/usr/bin/ldap --run\nExecReload=/usr/bin/ldap --reload\nUser=ldapuser\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/ldap", "#!/bin/sh\n", 0o755);
    try t.expectRun(0, &.{ "enable", "ldap" });
    f.sc.calls.clearRetainingCapacity();
    try t.expectRun(0, &.{ "reload", "ldap" });
    try f.expectCall(1, &.{ "/bin/sh", "-c", ldap_script, "/usr/bin/fake-systemd", "--exec", "ldap.service", "--phase", "reload" });
}

test "a line break in a literal setting is refused and reaches no generated file" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    try h.expectControlRefused(&f.t);
}

test "a record of owned source directories that cannot be read is an error and is not rewritten" {
    var f: Fixture = .{};
    try f.init(false);
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const file = try t.fs.root.openFile(testing.io, "var/lib/fake-systemd/s6-rc/owned-sources", .{ .mode = .read_write });
    defer file.close(testing.io);
    const len: usize = (1 << 20) + 1;
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.ftruncate(file.handle, len)));
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expect(t.run(&.{"daemon-reload"}) != 0);
    try testing.expectEqual(@as(u64, len), (try t.fs.stat("/var/lib/fake-systemd/s6-rc/owned-sources")).size);
}
