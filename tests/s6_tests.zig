// SPDX-License-Identifier: GPL-3.0-or-later
//! The plain s6 backend behind the real `ops` entry point, with a runner that answers like
//! `s6-svc`, `s6-svstat` and `s6-svok`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("s6_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const up_text = "up (pid 4242 pgid 4242) 5 seconds\n";
const scan = "/service";
const sv = "/etc/s6/sv";

const Fixture = struct {
    t: h.Harness = undefined,
    b: world.S6 = undefined,
    sc: world.Script = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populatePlain(&f.t);
        try f.t.addFoo();
        f.sc = .{ .gpa = f.t.a() };
        f.bind();
        f.t.detected = "s6";
    }

    fn bind(f: *Fixture) void {
        world.usePlain(&f.t, &f.b);
        f.t.backend_override = f.b.backend();
        f.t.runner_override = f.sc.runner();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
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

    fn link(f: *Fixture, name: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const target = try f.t.fs.readLink(try std.fmt.allocPrint(f.t.a(), "{s}/{s}", .{ scan, name }), &buf);
        return f.t.a().dupe(u8, target);
    }

    fn running(f: *Fixture) void {
        f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", scan ++ "/foo" }, .stdout = up_text }};
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

// ---- generation and enablement ----------------------------------------------------------------

test "enable generates the service directory, links it and asks s6-svscan to scan" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read(sv ++ "/foo/run")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 s6/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    try testing.expect(t.exists(sv ++ "/foo/finish"));
    try testing.expect(t.exists(sv ++ "/foo/log/run"));
    try testing.expectEqualStrings("90000\n", try t.read(sv ++ "/foo/timeout-kill"));
    try testing.expectEqual(@as(u16, 0o755), (try t.fs.stat(sv ++ "/foo/run")).mode);
    try testing.expectEqualStrings(sv ++ "/foo", try f.link("foo"));
    try h.expectContains(t.stderr(), "Created symlink '/service/foo' -> '/etc/s6/sv/foo'.");
    try f.expectCall(0, &.{ "s6-svscanctl", "-a", scan });
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    try testing.expect(!t.exists(sv ++ "/foo/down"));

    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "the index records every generated file and a lost index is rebuilt from the markers" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const index_text = try t.read("/var/lib/fake-systemd/s6/index");
    for ([_][]const u8{ sv ++ "/foo/run", sv ++ "/foo/finish", sv ++ "/foo/log/run", sv ++ "/foo/timeout-kill", sv ++ "/foo/fake-systemd.meta" }) |p| {
        try h.expectContains(index_text, p);
    }
    try t.fs.deleteFile("/var/lib/fake-systemd/s6/index");
    try t.fs.deleteFile("/usr/lib/systemd/system/foo.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    for ([_][]const u8{ "run", "finish", "log/run", "timeout-kill", "fake-systemd.meta" }) |p| {
        try testing.expect(!t.exists(try std.fmt.allocPrint(t.a(), "{s}/foo/{s}", .{ sv, p })));
    }
}

test "offline enable writes the same link and calls nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings(sv ++ "/foo", try f.link("foo"));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "enable --now starts through s6-svc" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try f.expectCall(0, &.{ "s6-svscanctl", "-a", scan });
    try f.expectCall(1, &.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/foo" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "is-enabled follows the link and the down file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try t.write(sv ++ "/foo/down", "", 0o644);
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
}

test "disable of a stopped service removes the link and has the next scan stop its supervisor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/service/foo'.");
    try testing.expect(t.exists(sv ++ "/foo/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(scan ++ "/foo"));
    try f.expectCall(0, &.{ "s6-svstat", scan ++ "/foo" });
    try f.expectCall(1, &.{ "s6-svok", scan ++ "/foo" });
    try f.expectCall(2, &.{ "s6-svscanctl", "-an", scan });
    try f.expectCall(3, &.{ "s6-svstat", sv ++ "/foo" });
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "disable of a running service writes down and keeps the link, enable removes it again" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Created '/etc/s6/sv/foo/down'.");
    try testing.expect(t.exists(sv ++ "/foo/down"));
    try testing.expectEqualStrings(sv ++ "/foo", try f.link("foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/s6/sv/foo/down'.");
    try testing.expect(!t.exists(sv ++ "/foo/down"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
}

test "start of a service that is not linked links it with down, waits for its supervisor and starts it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try f.expectCall(0, &.{ "s6-svscanctl", "-a", scan });
    try f.expectCall(1, &.{ "s6-svok", scan ++ "/foo" });
    try f.expectCall(2, &.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/foo" });
    try testing.expectEqual(@as(usize, 3), f.sc.calls.items.len);
    try testing.expectEqualStrings(sv ++ "/foo", try f.link("foo"));
    try testing.expect(t.exists(sv ++ "/foo/down"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));

    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try f.expectCall(0, &.{ "s6-svok", scan ++ "/foo" });
    try f.expectCall(1, &.{ "s6-svc", "-wd", "-T", "95000", "-d", scan ++ "/foo" });
    try testing.expectEqualStrings(sv ++ "/foo", try f.link("foo"));
    try testing.expect(t.exists(sv ++ "/foo/down"));
}

test "a start that s6-svc does not see through is a failure unless finish recorded the end" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.sc.rules = &.{.{ .prefix = &.{ "s6-svc", "-wu" }, .code = 1, .stdout = "s6-svc: fatal: timed out\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "enable", "--now", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
    try h.expectContains(t.stderr(), "foo: s6-svc: fatal: timed out");

    const Quick = struct {
        t: *h.Harness,

        fn runner(q: *@This()) h.backend.Runner {
            return .{ .ptr = q, .run_fn = runFn };
        }

        fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: h.backend.runner.Stdio) anyerror!h.backend.runner.Result {
            const q: *@This() = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, argv[0], "s6-svc")) {
                try q.t.write(sv ++ "/foo/supervise/exit-status", "failed 3 0\n", 0o644);
                return .{ .code = 1, .stdout = "s6-svc: fatal: timed out\n" };
            }
            return .{ .code = 0, .stdout = "down (exitcode 3) 1 seconds, normally up\n" };
        }
    };
    var quick: Quick = .{ .t = t };
    t.runner_override = quick.runner();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
}

test "stop records a clean end so that a killed service does not read as failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try t.write(sv ++ "/foo/supervise/exit-status", "failed 256 9\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqualStrings("ok 0 0\n", try t.read(sv ++ "/foo/supervise/exit-status"));
}

test "stop of a service nobody supervises does nothing, and a stop that fails while it runs is reported" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    f.sc.rules = &.{.{ .prefix = &.{"s6-svok"}, .code = 1 }};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    f.sc.rules = &.{
        .{ .prefix = &.{ "s6-svc", "-wd" }, .code = 1, .stdout = "s6-svc: fatal: timed out\n" },
        .{ .prefix = &.{"s6-svstat"}, .stdout = up_text },
    };
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "stop", "foo" }));
    try h.expectContains(t.stderr(), "foo: s6-svc: fatal: timed out");
}

test "the stop wait follows the timeout-kill of the service, and none is set for a service that is never killed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "slow", "", "TimeoutStopSec=7");
    try addSvc(t, "stubborn", "", "TimeoutStopSec=infinity");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "slow", "stubborn" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "slow" }));
    try f.expectCall(1, &.{ "s6-svc", "-wd", "-T", "12000", "-d", scan ++ "/slow" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "stubborn" }));
    try f.expectCall(3, &.{ "s6-svc", "-wd", "-d", scan ++ "/stubborn" });
    try testing.expectEqualStrings("0\n", try t.read(sv ++ "/stubborn/timeout-kill"));
}

test "restart is a stop followed by a start" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "restart", "foo" }));
    try f.expectCall(0, &.{ "s6-svok", scan ++ "/foo" });
    try f.expectCall(1, &.{ "s6-svc", "-wd", "-T", "95000", "-d", scan ++ "/foo" });
    try f.expectCall(2, &.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/foo" });
}

// ---- status, signals, reload ---------------------------------------------------------------------

test "status output is normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expect(f.sc.called(&.{ "s6-svstat", scan ++ "/foo" }));

    const cases = [_]struct { []const u8, []const u8, u8 }{
        .{ "down (signal SIGTERM) 3 seconds, normally up, ready 3 seconds\n", "inactive\n", 3 },
        .{ "down (exitcode 3) 0 seconds, normally up, want up, ready 0 seconds\n", "activating\n", 3 },
        .{ "up (pid 4242 pgid 4242) 3 seconds, want down\n", "deactivating\n", 3 },
        .{ "down (exitcode 1) 3 seconds, normally up, ready 3 seconds\n", "failed\n", 3 },
        .{ "down (not started yet) \n", "inactive\n", 3 },
        .{ "s6-svstat: fatal: unable to read status for x: s6-supervise not running\n", "inactive\n", 3 },
    };
    for (cases) |c| {
        f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = c[0] }};
        try testing.expectEqual(c[2], t.run(&.{ "is-active", "foo" }));
        try testing.expectEqualStrings(c[1], t.stdout());
    }
    f.sc.rules = &.{.{ .prefix = &.{"s6-svstat"}, .stdout = "down (signal SIGKILL) 0 seconds, ready 0 seconds\n" }};
    try t.write(sv ++ "/foo/supervise/exit-status", "ok 256 9\n", 0o644);
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
    try t.write(sv ++ "/foo/supervise/exit-status", "failed 256 9\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));
}

test "the main pid is read from the status text" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "MainPID", "-p", "ActiveState", "foo" }));
    try h.expectContains(t.stdout(), "MainPID=4242\n");
    try h.expectContains(t.stdout(), "ActiveState=active\n");
}

test "kill goes through s6-svc -s with the signal name or number" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "foo" }));
    try f.expectCall(0, &.{ "s6-svc", "-s", "TERM", scan ++ "/foo" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "--signal=SIGHUP", "foo" }));
    try f.expectCall(1, &.{ "s6-svc", "-s", "HUP", scan ++ "/foo" });
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "-s", "28", "foo" }));
    try f.expectCall(2, &.{ "s6-svc", "-s", "28", scan ++ "/foo" });
    f.sc.rules = &.{.{ .prefix = &.{"s6-svc"}, .code = 111, .stdout = "s6-svc: warning: unable to control /service/foo: supervisor not listening\n" }};
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "kill", "foo" }));
    try h.expectContains(t.stderr(), "supervisor not listening");
}

test "reload hands the pid that s6-supervise supervises to the executor, native services get SIGHUP" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(0, &.{ "s6-svstat", scan ++ "/foo" });
    try f.expectCall(1, &.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" });
    f.running();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try f.expectCall(3, &.{ "env", "MAINPID=4242", "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" });
    try t.addUnit("/usr/lib/systemd/system", "syslog.service", "/usr/bin/native", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "syslog" }));
    try f.expectCall(4, &.{ "s6-svc", "-h", scan ++ "/syslog" });
}

test "a service with ExecStop= runs its executor in stop mode, so s6-svc -d is the whole stop" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "hook", "", "ExecStop=/usr/bin/hook --stop\nKillSignal=SIGINT\nTimeoutStopSec=20");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "hook" }));
    try h.expectContains(try t.read(sv ++ "/hook/run"), "\nexec /usr/bin/fake-systemd --exec hook.service --stop-on-signal\n");
    try testing.expect(!t.exists(sv ++ "/hook/down-signal"));
    try testing.expectEqualStrings("50000\n", try t.read(sv ++ "/hook/timeout-kill"));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", scan ++ "/hook" }, .stdout = "up (pid 88 pgid 88) 2 seconds\n" }};
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "hook" }));
    try f.expectCall(0, &.{ "s6-svok", scan ++ "/hook" });
    try f.expectCall(1, &.{ "s6-svc", "-wd", "-T", "55000", "-d", scan ++ "/hook" });
    try testing.expectEqual(@as(usize, 2), f.sc.calls.items.len);
}

test "a oneshot that holds after its command gets ExecStop= from the backend before the process is signalled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "keep", "", "Type=oneshot\nRemainAfterExit=yes\nExecStop=/usr/bin/keep --stop");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "keep" }));
    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", scan ++ "/keep" }, .stdout = "up (pid 88 pgid 88) 2 seconds\n" }};
    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "keep" }));
    try f.expectCall(0, &.{ "s6-svok", scan ++ "/keep" });
    try f.expectCall(1, &.{ "s6-svc", "-O", scan ++ "/keep" });
    try f.expectCall(3, &.{ "env", "MAINPID=88", "/usr/bin/fake-systemd", "--exec", "keep.service", "--phase", "stop-main" });
    try f.expectCall(4, &.{ "s6-svc", "-wd", "-T", "95000", "-d", scan ++ "/keep" });
}

test "daemon-reload removes links to service directories that are gone and has s6-svscan notice" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.fs.symLink("/etc/s6/sv/gone", scan ++ "/gone");
    try t.fs.symLink("/opt/elsewhere/x", scan ++ "/foreign");
    try t.fs.symLink("/etc/s6/sv/syslog", scan ++ "/syslog");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectError(error.FileNotFound, t.fs.lstat(scan ++ "/gone"));
    _ = try t.fs.lstat(scan ++ "/foreign");
    _ = try t.fs.lstat(scan ++ "/syslog");
    try testing.expectEqual(@as(usize, 1), f.sc.calls.items.len);
    try f.expectCall(0, &.{ "s6-svscanctl", "-an", scan });

    f.sc.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
}

test "power verbs use s6-linux-init-hpr" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try f.expectCall(0, &.{ "s6-linux-init-hpr", "-r" });
    try f.expectCall(1, &.{ "s6-linux-init-hpr", "-p" });
    try f.expectCall(2, &.{ "s6-linux-init-hpr", "-h" });
}

test "dry-run prints the s6 commands it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.expectRun(0, &.{ "--dry-run", "enable", "--now", "foo" });
    try h.expectContains(t.stdout(), "would run: s6-svc -wu -T 10000 -u /service/foo\n");
    try h.expectContains(t.stdout(), "would create symlink '/service/foo' -> '/etc/s6/sv/foo'\n");
    try testing.expectEqual(@as(usize, 0), f.sc.calls.items.len);
    try testing.expect(!t.exists(sv ++ "/foo/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(scan ++ "/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "stop", "foo" }));
    try h.expectContains(t.stdout(), "would run: s6-svok /service/foo\n");
}

test "a template instance keeps its @ in the service name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "tpl@one.service" }));
    try testing.expect(t.exists(sv ++ "/tpl@one/run"));
    try testing.expectEqualStrings(sv ++ "/tpl@one", try f.link("tpl@one"));
    const parsed = marker.parse(try t.read(sv ++ "/tpl@one/run")).?;
    try testing.expectEqualStrings("tpl@one.service", parsed.marker.unit);
}

test "a native s6 service with the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(sv ++ "/foo-daemon/run", "#!/bin/execlineb -P\nfdmove -c 2 1\ns6-envdir /etc/foo.env exec /usr/bin/foo --run\n", 0o755);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists(sv ++ "/foo/run"));
    try testing.expectEqualStrings(sv ++ "/foo-daemon", try f.link("foo-daemon"));
    try f.expectCalled(&.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/foo-daemon" });
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
}

test "user scope is refused: s6 has no user service manager" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    const a = t.a();
    try t.environ.put("HOME", "/home/tester");
    t.ctx = try .init(a, testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    try t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    f.bind();
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "--user", "enable", "foo" }));
    try h.expectContains(t.stderr(), "the s6 backend has no user services");
}

// ---- dependencies ---------------------------------------------------------------------------------

test "hard and soft dependencies become s6-svc and s6-svwait lines, and the services they start are linked with down" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service\nWants=c.service", "Restart=always");
    try addSvc(t, "b", "Wants=d.service", "Restart=always");
    try addSvc(t, "c", "", "Restart=always");
    try addSvc(t, "d", "", "Restart=always");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try h.expectContains(
        try t.read(sv ++ "/a/run"),
        "\ns6-svc -u /service/b 2>/dev/null\ns6-svwait -u -t 90000 /service/b || exit 1\ns6-svc -u /service/c 2>/dev/null\ns6-svwait -u -t 5000 /service/c || :\nexec /usr/bin/a --run\n",
    );
    try h.expectContains(try t.read(sv ++ "/b/run"), "\ns6-svwait -u -t 5000 /service/d || :\n");
    try testing.expectEqualStrings(sv ++ "/a", try f.link("a"));
    for ([_][]const u8{ "b", "c", "d" }) |dep| {
        try testing.expect(t.exists(try std.fmt.allocPrint(t.a(), "{s}/{s}/down", .{ sv, dep })));
        _ = try f.link(dep);
    }
    try testing.expect(!t.exists(sv ++ "/a/down"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "b" }));
}

test "start links the dependencies first and waits for each supervisor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", "");
    try addSvc(t, "b", "", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try f.expectCall(0, &.{ "s6-svscanctl", "-a", scan });
    try f.expectCall(1, &.{ "s6-svok", scan ++ "/b" });
    try f.expectCall(2, &.{ "s6-svok", scan ++ "/a" });
    try f.expectCall(3, &.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/a" });
    try testing.expect(t.exists(sv ++ "/b/down"));
    try testing.expect(t.exists(sv ++ "/a/down"));
}

test "enabled network providers become soft dependencies" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write(sv ++ "/dhcpcd/run", "#!/bin/sh\nexec /usr/bin/dhcpcd -B\n", 0o755);
    try t.fs.symLink(sv ++ "/dhcpcd", scan ++ "/dhcpcd");
    try addSvc(t, "net", "After=network-online.target\nWants=network-online.target", "");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "net" }));
    try h.expectContains(try t.read(sv ++ "/net/run"), "\ns6-svc -u /service/dhcpcd 2>/dev/null\ns6-svwait -u -t 5000 /service/dhcpcd || :\n");
}

// ---- executor, timers --------------------------------------------------------------------------------

test "a unit that needs the executor runs it from run, and ExecStopPost= runs it from finish" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "pre", "", "ExecStartPre=/usr/bin/pre --check\nExecStopPost=/usr/bin/pre --cleanup\nRestart=on-failure\nRestartSec=3");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "pre" }));
    try h.expectContains(try t.read(sv ++ "/pre/run"), "\nexec /usr/bin/fake-systemd --exec pre.service\n");
    const finish = try t.read(sv ++ "/pre/finish");
    try h.expectContains(finish, "/usr/bin/fake-systemd --exec pre.service --phase stop-post\n");
    try h.expectContains(finish, "[ \"$(s6-svstat -o wantedup .)\" = false ] || sleep 3\n");
    try testing.expectEqualStrings("93000\n", try t.read(sv ++ "/pre/timeout-finish"));
}

test "the timer runner is generated, enabled and started like any service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/job.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try t.write("/usr/lib/systemd/system/job.timer", "[Timer]\nOnCalendar=*:*:0/5\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job.timer" }));
    try h.expectContains(try t.read(sv ++ "/fake-systemd-timers/run"), "\nexec /usr/bin/fake-systemd --timers\n");
    try testing.expectEqualStrings(sv ++ "/fake-systemd-timers", try f.link("fake-systemd-timers"));
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-svc", "-wu", "-T", "10000", "-u", scan ++ "/fake-systemd-timers" });

    f.sc.rules = &.{.{ .prefix = &.{ "s6-svstat", scan ++ "/fake-systemd-timers" }, .stdout = "up (pid 7 pgid 7) 3 seconds\n" }};
    try t.write("/usr/lib/systemd/system/job2.service", "[Service]\nType=oneshot\nExecStart=/usr/bin/job\n", 0o644);
    try t.write("/usr/lib/systemd/system/job2.timer", "[Timer]\nOnCalendar=*:*:0/7\n[Install]\nWantedBy=timers.target\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "job2.timer" }));
    try f.expectCall(f.sc.calls.items.len - 1, &.{ "s6-svc", "-s", "HUP", scan ++ "/fake-systemd-timers" });

    f.sc.rules = &.{};
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "job.timer", "job2.timer" }));
    try testing.expect(!t.exists(sv ++ "/fake-systemd-timers/run"));
    try testing.expectError(error.FileNotFound, t.fs.lstat(scan ++ "/fake-systemd-timers"));
}
