//! The dinit backend behind the real `ops` entry point, with a recording runner standing in
//! for `dinitctl`.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("dinit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const started_text = "Service: foo\n    State: STARTED\n    Activation: explicitly started\n    Process ID: 4242\n";

const Fixture = struct {
    t: h.Harness = undefined,
    d: world.dinit = undefined,

    fn init(f: *Fixture) !void {
        try f.t.init();
        try world.populate(&f.t);
        try f.t.addFoo();
        world.use(&f.t, &f.d);
        f.t.backend_override = f.d.backend();
        f.t.detected = "dinit";
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn userScope(f: *Fixture) !void {
        const a = f.t.a();
        try f.t.environ.put("HOME", "/home/tester");
        f.t.ctx = try .init(a, testing.io, &f.t.fs, &f.t.diag, &f.t.environ, .user, 1000);
        try f.t.write("/usr/lib/systemd/user/foo.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=default.target\n", 0o644);
    }
};

test "enable generates the service, links it into the boot service directory and never calls dinitctl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    const parsed = marker.parse(try t.read("/usr/lib/dinit.d/foo")).?;
    try testing.expectEqualStrings("foo.service", parsed.marker.unit);
    try testing.expectEqualStrings("fake-systemd 0.1.0 dinit/1", parsed.marker.generator);
    try testing.expect(parsed.bodyIntact());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/usr/lib/dinit.d/foo", try t.fs.readLink("/etc/dinit.d/boot.d/foo", &buf));
    try h.expectContains(t.stderr(), "Created symlink '/etc/dinit.d/boot.d/foo' -> '/usr/lib/dinit.d/foo'.");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(t.exists("/var/log/fake-systemd/foo.service"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "offline enable writes the same link" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.ctx.offline = true;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/usr/lib/dinit.d/foo", try t.fs.readLink("/etc/dinit.d/boot.d/foo", &buf));
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
}

test "an admin unit lands in /etc/dinit.d and links relatively like dinitctl enable" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/etc/systemd/system", "mine.service", "/usr/bin/mine", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "mine" }));
    try testing.expect(t.exists("/etc/dinit.d/mine"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("../mine", try t.fs.readLink("/etc/dinit.d/boot.d/mine", &buf));
}

test "the waits-for.d directory comes from the boot service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/etc/dinit.d/boot", "type = internal\nwaits-for.d = /etc/dinit.d/enabled.d\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expect(t.fs.exists("/etc/dinit.d/enabled.d/foo"));
    try testing.expect(!t.fs.exists("/etc/dinit.d/boot.d/foo"));
}

test "enable --now starts through dinitctl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "start", "foo" }));
    try testing.expectEqual(@as(usize, 1), t.rec.calls.items.len);
}

test "disable removes the link and keeps the generated service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("enabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try h.expectContains(t.stderr(), "Removed '/etc/dinit.d/boot.d/foo'.");
    try testing.expect(t.exists("/usr/lib/dinit.d/foo"));
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "is-enabled", "foo" }));
    try testing.expectEqualStrings("disabled\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "foo" }));
    try testing.expectEqualStrings("", t.stderr());
}

test "enable --runtime adds the dependency to the running boot service only" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--runtime", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "add-dep", "waits-for", "boot", "foo" }));
    try testing.expect(!t.fs.exists("/etc/dinit.d/boot.d/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "disable", "--runtime", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "dinitctl", "--quiet", "rm-dep", "waits-for", "boot", "foo" }));
}

test "status output is normalized for is-active and is-failed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.stdout = started_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("active\n", t.stdout());
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "status", "foo" }));

    t.rec.stdout = "Service: foo\n    State: STOPPED (terminated; exited - status 1)\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("failed\n", t.stdout());
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "is-failed", "foo" }));

    t.rec.stdout = "Service: foo\n    State: STOPPED\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());

    t.rec.stdout = "Service: foo\n    State: STARTING\n";
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("activating\n", t.stdout());

    t.rec.stdout = "";
    t.rec.code = 1;
    try testing.expectEqual(@as(u8, 3), t.run(&.{ "is-active", "foo" }));
    try testing.expectEqualStrings("inactive\n", t.stdout());
}

test "the main pid is read from the status text" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.stdout = started_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "show", "-p", "MainPID", "-p", "ActiveState", "foo" }));
    try h.expectContains(t.stdout(), "MainPID=4242\n");
    try h.expectContains(t.stdout(), "ActiveState=active\n");
}

test "start, stop and kill map to dinitctl" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "start", "foo" }));
    try testing.expect(t.exists("/usr/lib/dinit.d/foo"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "stop", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "dinitctl", "--quiet", "stop", "--force", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "kill", "--signal=SIGHUP", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "dinitctl", "signal", "HUP", "foo" }));
}

test "a failing dinitctl start is reported" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    t.rec.code = 1;
    try testing.expectEqual(@as(u8, 1), t.run(&.{ "start", "foo" }));
    try h.expectContains(t.stderr(), "Failed to start foo.service");
}

test "restart starts a service dinit reports as not started" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    var rec: world.Scripted = .{ .gpa = t.a(), .fail_words = &.{"is-started"} };
    var deps = t.deps();
    deps.runner = rec.runner();
    // Start once so the service file exists, then restart through the scripted runner.
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    const code = h.ops.systemctlArgs(&t.ctx, deps, &.{ "restart", "foo" });
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(rec.callIs(0, &.{ "dinitctl", "--quiet", "is-started", "foo" }));
    try testing.expect(rec.callIs(1, &.{ "dinitctl", "--quiet", "start", "foo" }));

    rec.fail_words = &.{};
    rec.calls.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), h.ops.systemctlArgs(&t.ctx, deps, &.{ "restart", "foo" }));
    try testing.expect(rec.callIs(1, &.{ "dinitctl", "--quiet", "restart", "foo" }));
}

test "reload runs ExecReload through the executor, and fails for services fake-systemd did not generate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "reload", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--phase", "reload" }));

    try t.write("/etc/dinit.d/foo-native", "type = process\ncommand = /usr/bin/other\n", 0o644);
    const be = f.d.backend();
    const env: h.backend.interface.Env = .{ .ctx = &t.ctx, .runner = t.rec.runner(), .online = true };
    try testing.expectError(error.Unsupported, be.reload(env, "foo-native"));
    try h.expectContains(t.stderr(), "dinit has no reload action");
}

test "daemon-reload reloads the descriptions of generated services only" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "foo" }));
    t.rec.calls.clearRetainingCapacity();
    t.rec.stdout = "[[+]     ] boot\n[{+}     ] foo (pid: 4242)\n[{+}     ] syslog (pid: 9)\n";
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "list" }));
    try testing.expect(t.rec.callIs(1, &.{ "dinitctl", "--quiet", "reload", "foo" }));
    try testing.expectEqual(@as(usize, 2), t.rec.calls.items.len);
}

test "power verbs use the dinit shutdown program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{"reboot"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"poweroff"}));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"halt"}));
    try testing.expect(t.rec.callIs(0, &.{ "shutdown", "-r" }));
    try testing.expect(t.rec.callIs(1, &.{ "shutdown", "-p" }));
    try testing.expect(t.rec.callIs(2, &.{ "shutdown", "-h" }));
}

test "dry-run prints the dinitctl commands it would run and changes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "--now", "foo" }));
    try h.expectContains(t.stdout(), "would run: dinitctl --quiet start foo\n");
    try h.expectContains(t.stdout(), "would create symlink '/etc/dinit.d/boot.d/foo' -> '../foo'\n");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.exists("/usr/lib/dinit.d/foo"));
    try testing.expect(!t.exists("/etc/dinit.d/boot.d/foo"));

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "restart", "foo" }));
    try h.expectContains(t.stdout(), "would run: dinitctl --quiet restart foo\n");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "daemon-reload" }));
    try h.expectContains(t.stdout(), "would run: dinitctl list\n");
}

test "user scope uses --user, the personal directory and the user boot directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try f.userScope();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "enable", "--now", "foo" }));
    try testing.expect(t.exists("/usr/lib/dinit.d/user/foo"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/usr/lib/dinit.d/user/foo", try t.fs.readLink("/home/tester/.config/dinit.d/boot.d/foo", &buf));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--user", "--quiet", "start", "foo" }));
    try testing.expect(t.exists("/home/tester/.local/state/fake-systemd/log/foo.service"));

    t.rec.stdout = started_text;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "is-active", "foo" }));
    try testing.expect(t.rec.callIs(1, &.{ "dinitctl", "--user", "status", "foo" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--user", "reload", "foo" }));
    try testing.expect(t.rec.callIs(2, &.{ "/usr/bin/fake-systemd", "--exec", "foo.service", "--user", "--phase", "reload" }));
}

test "a template instance becomes name-instance in dinit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.addUnit("/usr/lib/systemd/system", "tpl@.service", "/usr/bin/tpl", "WantedBy=multi-user.target");
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "tpl@one.service" }));
    try testing.expect(t.exists("/usr/lib/dinit.d/tpl-one"));
    try testing.expect(t.fs.exists("/etc/dinit.d/boot.d/tpl-one"));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "start", "tpl-one" }));
    const parsed = marker.parse(try t.read("/usr/lib/dinit.d/tpl-one")).?;
    try testing.expectEqualStrings("tpl@one.service", parsed.marker.unit);
}

test "a native dinit service with the same program is used instead of generating" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try t.write("/etc/dinit.d/foo-daemon", "type = process\ncommand = /usr/bin/env A=1 /usr/bin/foo --run\nrestart = true\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "--now", "foo" }));
    try testing.expect(!t.exists("/usr/lib/dinit.d/foo"));
    try testing.expect(t.fs.exists("/etc/dinit.d/boot.d/foo-daemon"));
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "start", "foo-daemon" }));
    try h.expectContains(t.stderr(), "using native service 'foo-daemon'");
}

test "log directories are not created in dry runs and exist before dinit starts a service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "start", "foo" }));
    try testing.expect(!t.exists("/var/log/fake-systemd"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "foo" }));
    try testing.expect(t.exists("/var/log/fake-systemd/foo.service"));
}

// ---- dependency closure ----

fn addSvc(t: *h.Harness, name: []const u8, unit_lines: []const u8, install: []const u8) !void {
    const exec = try std.fmt.allocPrint(t.a(), "/usr/bin/{s}", .{name});
    const text = try std.fmt.allocPrint(
        t.a(),
        "[Unit]\n{s}\n[Service]\nExecStart={s} --run\n[Install]\n{s}\n",
        .{ unit_lines, exec, install },
    );
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.service", .{name}), text, 0o644);
    try t.write(exec, "#!/bin/sh\n", 0o755);
}

const wanted = "WantedBy=multi-user.target";

/// `systemctl` with info diagnostics visible.
fn runInfo(t: *h.Harness, args: []const []const u8) u8 {
    t.out.clearRetainingCapacity();
    t.err.clearRetainingCapacity();
    t.diag.threshold = .info;
    return h.ops.systemctlArgs(&t.ctx, t.deps(), args);
}

fn indexLine(t: *h.Harness, unit_name: []const u8) !?[]const u8 {
    const text = try t.read("/var/lib/fake-systemd/dinit/index");
    const needle = try std.fmt.allocPrint(t.a(), "unit\t{s}\t", .{unit_name});
    const at = std.mem.find(u8, text, needle) orelse return null;
    const end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
    return text[at..end];
}

fn expectOrigin(t: *h.Harness, unit_name: []const u8, origin: []const u8) !void {
    const line = (try indexLine(t, unit_name)) orelse return error.UnitNotIndexed;
    const needle = try std.fmt.allocPrint(t.a(), "\t{s}\t", .{origin});
    try h.expectContains(line, needle);
}

test "a chain a, b, c is translated through depends-on and waits-for, and only a is enabled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "Wants=c.service", wanted);
    try addSvc(t, "c", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = b\n");
    try h.expectContains(try t.read("/usr/lib/dinit.d/b"), "\nwaits-for = c\n");
    try testing.expect(t.exists("/usr/lib/dinit.d/c"));
    try testing.expect(t.fs.exists("/etc/dinit.d/boot.d/a"));
    try testing.expect(!t.fs.exists("/etc/dinit.d/boot.d/b"));
    try testing.expect(!t.fs.exists("/etc/dinit.d/boot.d/c"));
    try expectOrigin(t, "a.service", "explicit");
    try expectOrigin(t, "b.service", "dependency");
    try expectOrigin(t, "c.service", "dependency");
    try h.expectContains((try indexLine(t, "a.service")).?, "\tb.service\t");
    try testing.expect(t.rec.calls.items.len == 0);

    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try testing.expectEqual(@as(usize, 1), t.rec.calls.items.len);
    try testing.expect(t.rec.callIs(0, &.{ "dinitctl", "--quiet", "start", "a" }));
}

test "a dependency cycle keeps the first edge and drops the one that closes it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "Requires=a.service", wanted);
    try testing.expectEqual(@as(u8, 0), runInfo(t, &.{ "enable", "a" }));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = b\n");
    try h.expectNotContains(try t.read("/usr/lib/dinit.d/b"), "depends-on");
    try h.expectContains(t.stderr(), "b.service: dependency a.service dropped: dependency cycle");
    try expectOrigin(t, "b.service", "dependency");
}

test "a native service that matches a dependency is used and nothing is generated for it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "", wanted);
    try t.write("/etc/dinit.d/b-native", "type = process\ncommand = /usr/bin/b --other\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = b-native\n");
    try h.expectContains((try indexLine(t, "b.service")).?, "\tnative\t");
    try expectOrigin(t, "b.service", "dependency");
}

test "a dependency the classifier excludes is dropped from the file with an info line" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=hook.service\nWants=gone.service", wanted);
    try addSvc(t, "hook", "", "WantedBy=shutdown.target");
    try testing.expectEqual(@as(u8, 0), runInfo(t, &.{ "enable", "a" }));
    const content = try t.read("/usr/lib/dinit.d/a");
    try h.expectNotContains(content, "hook");
    try h.expectNotContains(content, "gone");
    try h.expectContains(t.stderr(), "a.service: dependency hook.service dropped: system lifecycle hook");
    try h.expectContains(t.stderr(), "a.service: dependency gone.service dropped: unit not found");
    try testing.expect(!t.exists("/usr/lib/dinit.d/hook"));
    try testing.expect((try indexLine(t, "hook.service")) == null);
}

test "dependencies are collected once no unit that was named explicitly reaches them" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "Wants=c.service", wanted);
    try addSvc(t, "c", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(t.exists("/usr/lib/dinit.d/b") and t.exists("/usr/lib/dinit.d/c"));

    try t.fs.deleteFile("/usr/lib/systemd/system/a.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists("/usr/lib/dinit.d/a"));
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
    try testing.expect(!t.exists("/usr/lib/dinit.d/c"));
    try testing.expect((try indexLine(t, "b.service")) == null);
    try testing.expect((try indexLine(t, "c.service")) == null);
}

test "an explicit unit that is also a dependency is kept, with what it depends on" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "Wants=c.service", wanted);
    try addSvc(t, "c", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "b" }));
    try expectOrigin(t, "b.service", "explicit");
    try t.fs.deleteFile("/usr/lib/systemd/system/a.service");
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try testing.expect(!t.exists("/usr/lib/dinit.d/a"));
    try testing.expect(t.exists("/usr/lib/dinit.d/b"));
    try testing.expect(t.exists("/usr/lib/dinit.d/c"));

    // Enabling a unit first and reaching it as a dependency afterwards keeps it explicit.
    try addSvc(t, "d", "Requires=b.service", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "d" }));
    try expectOrigin(t, "b.service", "explicit");
}

test "daemon-reload translates a dependency added to a managed unit later" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "", wanted);
    try addSvc(t, "c", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expect(!t.exists("/usr/lib/dinit.d/c"));
    try addSvc(t, "a", "Requires=c.service", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = c\n");
    try testing.expect(t.exists("/usr/lib/dinit.d/c"));
    try expectOrigin(t, "c.service", "dependency");
}

test "dry-run shows the dependency files and writes nothing" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "", wanted);
    const before = try t.snapshot();
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "--dry-run", "enable", "--now", "a" }));
    try h.expectContains(t.stdout(), "/usr/lib/dinit.d/b");
    try h.expectContains(t.stdout(), "/usr/lib/dinit.d/a");
    try h.expectContains(t.stdout(), "would run: dinitctl --quiet start a\n");
    try testing.expectEqualStrings(before, try t.snapshot());
}

test "reverting the requiring unit collects its dependencies" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try testing.expect(t.exists("/usr/lib/dinit.d/b"));
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "revert", "a" }));
    try testing.expect(!t.exists("/usr/lib/dinit.d/a"));
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
}

test "log directories of dependency services exist before dinit starts the service" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "start", "a" }));
    try testing.expect(t.exists("/var/log/fake-systemd/a.service"));
    try testing.expect(t.exists("/var/log/fake-systemd/b.service"));
}

// ---- daemon-reload follows dependencies ----

fn chain(t: *h.Harness) !void {
    try addSvc(t, "a", "Requires=b.service", wanted);
    try addSvc(t, "b", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = b\n");
    // The first reload stores the configuration hash; the tests start from a settled state.
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
}

test "a dependency that becomes unsupported is dropped from the unchanged requiring unit" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try chain(t);
    try addSvc(t, "b", "", "WantedBy=shutdown.target");
    try testing.expectEqual(@as(u8, 0), runInfo(t, &.{"daemon-reload"}));
    try h.expectNotContains(try t.read("/usr/lib/dinit.d/a"), "depends-on");
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
    try h.expectContains(t.stderr(), "a.service: dependency b.service dropped: system lifecycle hook");
}

test "a deleted dependency makes the requiring unit regenerate without it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try chain(t);
    try t.fs.deleteFile("/usr/lib/systemd/system/b.service");
    try testing.expectEqual(@as(u8, 0), runInfo(t, &.{"daemon-reload"}));
    try h.expectNotContains(try t.read("/usr/lib/dinit.d/a"), "depends-on");
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
    try h.expectContains(t.stderr(), "a.service: dependency b.service dropped: unit not found");
}

test "a dependency adopted as native is referenced by its native name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try chain(t);
    try t.write("/etc/dinit.d/b-native", "type = process\ncommand = /usr/bin/b --serve\n", 0o644);
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    try h.expectContains(try t.read("/usr/lib/dinit.d/a"), "\ndepends-on = b-native\n");
    try testing.expect(!t.exists("/usr/lib/dinit.d/b"));
    try h.expectContains((try indexLine(t, "b.service")).?, "\tnative\t");
}

test "a second daemon-reload with nothing changed skips both units" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const t = &f.t;
    try addSvc(t, "a", "Requires=b.service\nWants=gone.service", wanted);
    try addSvc(t, "b", "", wanted);
    try testing.expectEqual(@as(u8, 0), t.run(&.{ "enable", "a" }));
    try testing.expectEqual(@as(u8, 0), t.run(&.{"daemon-reload"}));
    const tree = try t.snapshot();
    const index_text = try t.read("/var/lib/fake-systemd/dinit/index");
    try testing.expectEqual(@as(u8, 0), runInfo(t, &.{"daemon-reload"}));
    try testing.expectEqualStrings("", t.stderr());
    try testing.expectEqualStrings(tree, try t.snapshot());
    try testing.expectEqualStrings(index_text, try t.read("/var/lib/fake-systemd/dinit/index"));
}
