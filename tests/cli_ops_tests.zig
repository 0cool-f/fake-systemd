// SPDX-License-Identifier: GPL-3.0-or-later
//! Regression tests for the CLI and operation fixes: revert, enable of untranslatable units,
//! `edit --root`, `preset-all`, `Also=`, configuration errors, `--root` validation and journalctl.
const std = @import("std");
const Io = std.Io;
const fs_sys = @import("fake_systemd");
const build_options = @import("build_options");
const h = @import("harness.zig");

const testing = std.testing;

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.addFoo();
}

test "revert removes a symlinked drop-in directory without touching its target" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/precious/keep.conf", "[Service]\n", 0o644);
    try t.write("/precious/sub/deep", "data", 0o644);
    try t.fs.makePath("/etc/systemd/system");
    try t.fs.symLink("/precious", "/etc/systemd/system/foo.service.d");
    try t.expectRun(0, &.{ "revert", "foo" });
    try testing.expect(t.exists("/precious/keep.conf"));
    try testing.expect(t.exists("/precious/sub/deep"));
    try testing.expectError(error.FileNotFound, t.fs.lstat("/etc/systemd/system/foo.service.d"));
}

test "revert still empties a real drop-in directory" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/etc/systemd/system/foo.service.d/override.conf", "[Service]\n", 0o644);
    try t.expectRun(0, &.{ "revert", "foo" });
    try testing.expect(!t.exists("/etc/systemd/system/foo.service.d"));
}

test "enable, reenable and preset of units that are not translated succeed with a notice" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/hook.service", "[Service]\nExecStart=/usr/bin/foo\n[Install]\nWantedBy=shutdown.target\n", 0o644);
    try t.write("/usr/lib/systemd/system/act.socket", "[Socket]\nListenStream=/run/act.sock\n[Install]\nWantedBy=sockets.target\n", 0o644);
    try t.write("/usr/lib/systemd/system-preset/50.preset", "enable hook.service\nenable act.socket\nenable gone.service\n", 0o644);
    try t.expectRun(0, &.{ "enable", "hook" });
    try h.expectContains(t.stderr(), "hook.service: not translated (system lifecycle hook");
    try t.expectRun(0, &.{ "enable", "act.socket" });
    try t.expectRun(0, &.{ "reenable", "hook" });
    try t.expectRun(0, &.{ "preset", "hook", "act.socket" });
    try testing.expect(!t.exists("/usr/lib/fake.d/hook"));
}

test "enable of a unit whose binary is missing succeeds and is remembered for daemon-reload" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/gone.service", "[Service]\nExecStart=/usr/bin/gone\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "gone" });
    try h.expectContains(t.stderr(), "gone.service: not translated");
    try h.expectContains(try t.indexText(), "unit\tgone.service\tsystem\tvendor\tmissing\txxh3:0000000000000000\txxh3:0000000000000000\t\t\texplicit");
    try t.expectRun(0, &.{ "disable", "gone" });
    try h.expectNotContains(try t.indexText(), "gone.service");
    try t.expectRun(0, &.{ "--dry-run", "enable", "gone" });
    try h.expectNotContains(try t.indexText(), "gone.service");
}

test "edit refuses --root and never starts the editor" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.environ.put("EDITOR", "myed");
    try t.expectRun(1, &.{ "--root=/somewhere", "edit", "foo" });
    try h.expectContains(t.stderr(), "edit is not supported with --root");
    try testing.expectEqual(@as(usize, 0), t.rec.calls.items.len);
    try testing.expect(!t.exists("/etc/systemd/system/foo.service.d"));
}

test "preset-all goes on after a failing unit and exits 1" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "a.service", "/usr/bin/a", "WantedBy=multi-user.target");
    try t.addUnit("/usr/lib/systemd/system", "z.service", "/usr/bin/z", "WantedBy=multi-user.target");
    try t.write("/usr/lib/systemd/system-preset/50.preset", "enable a.service\nenable z.service\n", 0o644);
    // A non-empty directory where the generated file of `a` belongs makes its translation fail.
    try t.write("/usr/lib/fake.d/a/blocker", "x", 0o644);
    try t.expectRun(1, &.{"preset-all"});
    try h.expectContains(t.stderr(), "a.service: preset failed");
    try testing.expect(t.fake.serviceState("z").enabled);
}

test "disable follows Also= like enable" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "main.service", "/usr/bin/main", "WantedBy=multi-user.target\nAlso=side.service");
    try t.addUnit("/usr/lib/systemd/system", "side.service", "/usr/bin/side", "WantedBy=multi-user.target");
    try t.expectRun(0, &.{ "enable", "main" });
    try testing.expect(t.fake.serviceState("main").enabled);
    try testing.expect(t.fake.serviceState("side").enabled);
    try t.expectRun(0, &.{ "disable", "main" });
    try testing.expect(!t.fake.serviceState("main").enabled);
    try testing.expect(!t.fake.serviceState("side").enabled);
}

test "enable of an instance whose Also= names its template does not fail half-way" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/u@.service", "[Service]\nExecStart=/usr/bin/u %i\n[Install]\nWantedBy=multi-user.target\nAlso=u@.service\n", 0o644);
    try t.write("/usr/bin/u", "#!/bin/sh\n", 0o755);
    try t.expectRun(0, &.{ "enable", "u@x" });
    try testing.expect(t.fake.serviceState("u@x").enabled);
    try t.expectRun(0, &.{ "disable", "u@x" });
}

test "a template named by Also= from a plain unit is skipped, not an error" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addUnit("/usr/lib/systemd/system", "main.service", "/usr/bin/main", "WantedBy=multi-user.target\nAlso=tpl@.service");
    try t.write("/usr/lib/systemd/system/tpl@.service", "[Service]\nExecStart=/usr/bin/main\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.expectRun(0, &.{ "enable", "main" });
    try testing.expect(t.fake.serviceState("main").enabled);
}

test "a malformed Deny= or an unreadable configuration makes mutating verbs refuse" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    t.ctx.config.load_error = "/etc/fake-systemd/fake-systemd.conf:3: invalid value for Deny= (UnterminatedQuote)";
    try t.expectRun(1, &.{ "enable", "foo" });
    try h.expectContains(t.stderr(), "refusing to run 'enable': the configuration is not usable");
    try testing.expect(!t.exists("/usr/lib/fake.d/foo"));
    try t.expectRun(1, &.{ "start", "foo" });
    try t.expectRun(1, &.{"daemon-reload"});
    try t.expectRun(1, &.{ "is-enabled", "foo" });
    try t.expectRun(0, &.{ "cat", "foo" });
}

test "a unit file over the size limit is reported by unit name" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    const big = try t.a().alloc(u8, fs_sys.unit.resolve.max_unit_file_size + 1);
    @memset(big, '#');
    try t.write("/etc/systemd/system/huge.service", big, 0o644);
    try t.expectRun(1, &.{ "enable", "huge" });
    try h.expectContains(t.stderr(), "huge.service: /etc/systemd/system/huge.service is larger than");
    try h.expectNotContains(t.stderr(), "StreamTooLong");
    try t.expectRun(1, &.{ "cat", "huge" });
    try h.expectContains(t.stderr(), "huge.service: /etc/systemd/system/huge.service is larger than");
    try t.expectRun(4, &.{ "status", "huge" });
    try h.expectContains(t.stderr(), "huge.service: cannot load unit: a unit file is larger than");
}

test "status and show escape control bytes of unit-controlled text" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/evil.service", "[Unit]\nDescription=hi\x1b]0;pwned\x07\x1b[2J\n[Service]\nExecStart=/usr/bin/foo\n", 0o644);
    try t.expectRun(3, &.{ "status", "evil" });
    try testing.expect(std.mem.indexOfScalar(u8, t.stdout(), 0x1b) == null);
    try testing.expect(std.mem.indexOfScalar(u8, t.stdout(), 0x07) == null);
    try h.expectContains(t.stdout(), "hi\\x1b]0;pwned\\x07\\x1b[2J");
    try t.expectRun(0, &.{ "show", "evil", "-p", "Description" });
    try testing.expectEqualStrings("Description=hi\\x1b]0;pwned\\x07\\x1b[2J\n", t.stdout());
    try t.expectRun(0, &.{ "list-units", "--all" });
    try testing.expect(std.mem.indexOfScalar(u8, t.stdout(), 0x1b) == null);
}

test "an abbreviated option never lets a mutating verb run" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(1, &.{ "enable", "--dry-ru", "foo" });
    try testing.expect(!t.exists("/usr/lib/fake.d/foo"));
}

test "relative XDG values fall back to the defaults" {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.environ.put("XDG_CONFIG_HOME", "relative/config");
    try t.environ.put("XDG_RUNTIME_DIR", "run");
    const ctx = try h.core.Context.init(t.a(), testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    try testing.expectEqualStrings("/root/.config", ctx.xdg_config_home);
    try testing.expectEqualStrings("/run/user/1000", ctx.xdg_runtime_dir);
}

test "an [Aliases] entry resolves the native name conflict" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.addNative("foo", "/usr/bin/other");
    try t.expectRun(1, &.{ "enable", "foo" });
    try h.expectContains(t.stderr(), "the name is taken by native service 'foo'");
    try t.ctx.config.aliases.put(t.a(), "foo.service", "foo");
    try t.expectRun(0, &.{ "enable", "foo" });
    try h.expectContains(t.stderr(), "using native service 'foo'");
}

// ---- the real binary ----

const Bin = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    dir: []const u8,
    env: std.process.Environ.Map,

    fn init(b: *Bin, tool: []const u8) !void {
        b.arena = .init(testing.allocator);
        const gpa = b.arena.allocator();
        b.tmp = testing.tmpDir(.{ .iterate = true });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try b.tmp.dir.realPath(testing.io, &buf);
        b.dir = try gpa.dupe(u8, buf[0..n]);
        const exe: []const u8 = build_options.exe_path;
        const abs = if (std.fs.path.isAbsolute(exe)) exe else try std.fs.path.join(gpa, &.{ try std.process.currentPathAlloc(testing.io, gpa), exe });
        try b.tmp.dir.symLink(testing.io, abs, tool, .{});
        b.env = .init(gpa);
        try b.env.put("PATH", "/usr/bin:/bin");
        try b.env.put("TZ", "UTC");
    }

    fn deinit(b: *Bin) void {
        b.tmp.cleanup();
        b.arena.deinit();
    }

    fn run(b: *Bin, tool: []const u8, args: []const []const u8) !struct { code: u8, err: []const u8 } {
        const gpa = b.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(gpa, try std.fs.path.join(gpa, &.{ b.dir, tool }));
        try argv.appendSlice(gpa, args);
        const res = try std.process.run(gpa, testing.io, .{ .argv = argv.items, .environ_map = &b.env });
        const code: u8 = switch (res.term) {
            .exited => |c| c,
            .signal => |s| 128 + @as(u8, @intCast(@backingInt(s))),
            else => 255,
        };
        return .{ .code = code, .err = res.stderr };
    }
};

test "a relative or empty --root is an error, not a crash" {
    var b: Bin = undefined;
    try b.init("systemctl");
    defer b.deinit();
    for ([_][]const u8{ "--root=relative/dir", "--root=", "--root=." }) |opt| {
        const r = try b.run("systemctl", &.{ opt, "status", "foo" });
        try testing.expectEqual(@as(u8, 1), r.code);
        try h.expectContains(r.err, "--root must be an absolute path");
    }
}

test "journalctl --since with a huge timestamp is an error, not an overflow" {
    var b: Bin = undefined;
    try b.init("journalctl");
    defer b.deinit();
    for ([_][]const u8{ "--since=@9223372036854775807", "--until=@-9223372036854775808" }) |opt| {
        const r = try b.run("journalctl", &.{ opt, "--no-pager" });
        try testing.expectEqual(@as(u8, 1), r.code);
        try h.expectContains(r.err, "Failed to parse timestamp");
    }
}

test "status lists every numbered backup of a generated file" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "enable", "foo" });
    const base = "/var/lib/fake-systemd/backup/fake/usr/lib/fake.d/foo";
    try t.write(base ++ ".fsnew", "a", 0o644);
    try t.write(base ++ ".fsnew.1", "b", 0o644);
    try t.write(base ++ ".fsnew.2", "c", 0o644);
    try t.write(base ++ ".fssave", "d", 0o644);
    try t.write(base ++ ".fssave.1", "e", 0o644);
    _ = t.run(&.{ "status", "foo" });
    for ([_][]const u8{ "fsnew", "fsnew.1", "fsnew.2", "fssave", "fssave.1" }) |suffix| {
        const line = try std.fmt.allocPrint(t.a(), "backup {s}.{s}\n", .{ base, suffix });
        try h.expectContains(t.stdout(), line);
    }
    try h.expectNotContains(t.stdout(), "fsnew.3");
}

test "enable of an instance enables the instance of the template its Also= names" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/lib/systemd/system/u@.service", "[Service]\nExecStart=/usr/bin/u %i\n[Install]\nWantedBy=multi-user.target\nAlso=v@.service\n", 0o644);
    try t.write("/usr/lib/systemd/system/v@.service", "[Service]\nExecStart=/usr/bin/v %i\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try t.write("/usr/bin/u", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/v", "#!/bin/sh\n", 0o755);
    try t.expectRun(0, &.{ "enable", "u@x" });
    try testing.expect(t.fake.serviceState("u@x").enabled);
    try testing.expect(t.fake.serviceState("v@x").enabled);
}
