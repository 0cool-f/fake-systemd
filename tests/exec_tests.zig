// SPDX-License-Identifier: GPL-3.0-or-later
//! End-to-end tests of `fake-systemd --exec` and `--log`: the real binary runs against units
//! in a tmp filesystem root.
const std = @import("std");
const Io = std.Io;
const fs_sys = @import("fake_systemd");
const build_options = @import("build_options");

const core = fs_sys.core;
const testing = std.testing;
const linux = std.os.linux;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    exe: []const u8,
    fs: core.Fs,
    env: std.process.Environ.Map,

    fn init(f: *Fixture) !void {
        f.arena = .init(testing.allocator);
        const gpa = f.arena.allocator();
        f.tmp = testing.tmpDir(.{ .iterate = true });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &buf);
        f.root = try gpa.dupe(u8, buf[0..n]);
        const exe: []const u8 = build_options.exe_path;
        f.exe = if (std.fs.path.isAbsolute(exe))
            exe
        else
            try std.fs.path.join(gpa, &.{ try std.process.currentPathAlloc(testing.io, gpa), exe });
        f.fs = .initDir(testing.io, f.tmp.dir);
        f.env = .init(gpa);
        try f.env.put("PATH", "/usr/bin:/bin");
        try f.env.put("TZ", "UTC");
        try f.env.put("LEAKED_FROM_MANAGER", "yes");
        try f.env.put("PASSED_FROM_MANAGER", "passed");
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    fn write(f: *Fixture, path: []const u8, content: []const u8) !void {
        try f.fs.makePath(std.fs.path.dirname(path).?);
        try f.fs.writeFileAtomic(path, content, 0o644);
    }

    /// Writes a unit with a `[Service]` body; `root` expands to the tmp root.
    fn unit(f: *Fixture, name: []const u8, body: []const u8) !void {
        const text = try std.fmt.allocPrint(f.a(), "[Service]\n{s}\n", .{body});
        const path = try std.fmt.allocPrint(f.a(), "/etc/systemd/system/{s}", .{name});
        try f.write(path, text);
    }

    fn argv(f: *Fixture, mode_args: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(f.a(), f.exe);
        try list.appendSlice(f.a(), mode_args);
        try list.appendSlice(f.a(), &.{ "--root", f.root });
        return list.toOwnedSlice(f.a());
    }

    const Result = struct { code: u8, out: []const u8, err: []const u8 };

    fn runArgv(f: *Fixture, args: []const []const u8) !Result {
        const res = try std.process.run(f.a(), testing.io, .{ .argv = args, .environ_map = &f.env });
        const code: u8 = switch (res.term) {
            .exited => |c| c,
            .signal => |s| 128 + @as(u8, @intCast(@backingInt(s))),
            else => 255,
        };
        return .{ .code = code, .out = res.stdout, .err = res.stderr };
    }

    fn exec(f: *Fixture, unit_name: []const u8, extra: []const []const u8) !Result {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(f.a(), &.{ "--exec", unit_name });
        try args.appendSlice(f.a(), extra);
        return f.runArgv(try f.argv(args.items));
    }

    fn pipeLog(f: *Fixture, input: []const u8, extra: []const []const u8) !Result {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(f.a(), &.{ "--log", "web.service" });
        try args.appendSlice(f.a(), extra);
        // The shell script prints the input (escapes interpreted) into the logger command.
        var sh_args: std.ArrayList([]const u8) = .empty;
        try sh_args.appendSlice(f.a(), &.{ "/bin/sh", "-c", "input=$1; shift; printf %b \"$input\" | \"$@\"", "sh", input });
        try sh_args.appendSlice(f.a(), try f.argv(args.items));
        return f.runArgv(sh_args.items);
    }

    fn read(f: *Fixture, path: []const u8) ![]u8 {
        return f.fs.readFileAlloc(f.a(), path, 1 << 22);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) != null) {
        std.debug.print("expected not to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedLacks;
    }
}

fn isRoot() bool {
    return linux.geteuid() == 0;
}

test "oneshot runs the commands in order with expanded variables" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/app.env", "FROM_FILE=file value\nOVERRIDDEN=file\n");
    try f.unit("seq.service",
        \\Type=oneshot
        \\Environment=OVERRIDDEN=unit WORDS="a b"
        \\EnvironmentFile=-/etc/missing.env
        \\EnvironmentFile=/etc/app.env
        \\ExecStartPre=/bin/echo pre
        \\ExecStart=/bin/echo one OVERRIDDEN=${OVERRIDDEN} file=${FROM_FILE}
        \\ExecStart=/bin/echo split $WORDS braced ${WORDS} dollars $$
        \\ExecStart=:/bin/echo literal $WORDS ${WORDS} $$
        \\ExecStart=-/bin/sh -c 'exit 3'
        \\ExecStartPost=/bin/echo post
    );
    const r = try f.exec("seq.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings(
        "pre\none OVERRIDDEN=file file=file value\nsplit a b braced a b dollars $\nliteral $WORDS ${WORDS} $$\npost\n",
        r.out,
    );
}

test "oneshot stops at the first failing command with its status" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("fail.service",
        \\Type=oneshot
        \\ExecStart=/bin/echo first
        \\ExecStart=/bin/sh -c 'exit 7'
        \\ExecStart=/bin/echo never
    );
    const r = try f.exec("fail.service", &.{});
    try testing.expectEqual(@as(u8, 7), r.code);
    try testing.expectEqualStrings("first\n", r.out);

    try f.unit("success.service",
        \\Type=oneshot
        \\SuccessExitStatus=7
        \\ExecStart=/bin/sh -c 'exit 7'
        \\ExecStart=/bin/echo after
    );
    const ok = try f.exec("success.service", &.{});
    try testing.expectEqual(@as(u8, 0), ok.code);
    try testing.expectEqualStrings("after\n", ok.out);
}

test "a failing ExecStartPre prevents the main command" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("pre.service",
        \\ExecStartPre=/bin/sh -c 'exit 9'
        \\ExecStart=/bin/echo main
    );
    const r = try f.exec("pre.service", &.{});
    try testing.expectEqual(@as(u8, 9), r.code);
    try testing.expectEqualStrings("", r.out);

    try f.unit("preok.service",
        \\ExecStartPre=-/bin/sh -c 'exit 9'
        \\ExecStartPre=-/does/not/exist
        \\ExecStart=/bin/echo main
    );
    const ok = try f.exec("preok.service", &.{});
    try testing.expectEqual(@as(u8, 0), ok.code);
    try testing.expectEqualStrings("main\n", ok.out);
}

test "simple services replace the executor and get a clean environment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("env.service",
        \\PassEnvironment=PASSED_FROM_MANAGER
        \\Environment=SET=1 REMOVED=1
        \\UnsetEnvironment=REMOVED
        \\ExecStart=/usr/bin/env
    );
    const r = try f.exec("env.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.out, "SET=1\n");
    try expectContains(r.out, "PASSED_FROM_MANAGER=passed\n");
    try expectContains(r.out, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin");
    try expectContains(r.out, "INVOCATION_ID=");
    try expectLacks(r.out, "LEAKED_FROM_MANAGER");
    try expectLacks(r.out, "REMOVED");
}

test "bare executables are searched and missing ones exit 203" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("path.service", "ExecStart=echo found");
    const r = try f.exec("path.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("found\n", r.out);

    try f.unit("missing.service", "ExecStart=/does/not/exist");
    const m = try f.exec("missing.service", &.{});
    try testing.expectEqual(@as(u8, 203), m.code);
    try expectContains(m.err, "/does/not/exist");

    try f.unit("optional.service", "ExecStart=-/does/not/exist");
    try testing.expectEqual(@as(u8, 0), (try f.exec("optional.service", &.{})).code);
}

test "umask, nice, limits and working directory are applied" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("props.service",
        \\Type=oneshot
        \\UMask=0077
        \\Nice=7
        \\LimitNOFILE=512
        \\WorkingDirectory=/usr
        \\ExecStart=/bin/sh -c 'umask; ulimit -n; pwd'
        \\ExecStart=/usr/bin/nice
    );
    const r = try f.exec("props.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("0077\n512\n/usr\n7\n", r.out);

    try f.unit("cwd.service",
        \\Type=oneshot
        \\WorkingDirectory=-/does/not/exist
        \\ExecStart=/bin/echo still runs
    );
    try testing.expectEqualStrings("still runs\n", (try f.exec("cwd.service", &.{})).out);
    try f.unit("badcwd.service",
        \\WorkingDirectory=/does/not/exist
        \\ExecStart=/bin/echo never
    );
    const bad = try f.exec("badcwd.service", &.{});
    try testing.expectEqual(@as(u8, 200), bad.code);

    try f.unit("badlimit.service",
        \\LimitNOFILE=lots
        \\ExecStart=/bin/echo never
    );
    try testing.expectEqual(@as(u8, 205), (try f.exec("badlimit.service", &.{})).code);
}

test "NoNewPrivileges is set unless the command is privileged with plus" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("nnp.service",
        \\Type=oneshot
        \\NoNewPrivileges=yes
        \\ExecStart=/bin/sh -c 'grep NoNewPrivs /proc/self/status'
        \\ExecStart=+/bin/sh -c 'grep NoNewPrivs /proc/self/status'
    );
    const r = try f.exec("nnp.service", &.{});
    try testing.expectEqualStrings("NoNewPrivs:\t1\nNoNewPrivs:\t0\n", r.out);
}

test "runtime directories are created, exported and removed by stop-post" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("dirs.service",
        \\Type=oneshot
        \\RuntimeDirectory=dirsvc
        \\RuntimeDirectoryMode=0700
        \\StateDirectory=dirsvc
        \\ExecStart=/bin/sh -c 'echo $RUNTIME_DIRECTORY $STATE_DIRECTORY'
        \\ExecStopPost=/bin/echo stopped
    );
    const r = try f.exec("dirs.service", &.{});
    try testing.expectEqualStrings("/run/dirsvc /var/lib/dirsvc\n", r.out);
    try testing.expect(f.fs.exists("/run/dirsvc"));
    try testing.expectEqual(@as(u16, 0o700), (try f.fs.stat("/run/dirsvc")).mode);
    const post = try f.exec("dirs.service", &.{ "--phase", "stop-post" });
    try testing.expectEqual(@as(u8, 0), post.code);
    try testing.expectEqualStrings("stopped\n", post.out);
    try testing.expect(!f.fs.exists("/run/dirsvc"));
    try testing.expect(f.fs.exists("/var/lib/dirsvc"));
}

test "reload runs ExecReload with MAINPID and fails without one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("rel.service",
        \\ExecStart=/bin/sleep 30
        \\ExecReload=/bin/echo reload ${MAINPID}
    );
    try f.write("/run/fake-systemd/rel.service.pid", "1\n");
    const r = try f.exec("rel.service", &.{ "--phase", "reload" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("reload 1\n", r.out);

    try f.unit("norel.service", "ExecStart=/bin/sleep 30");
    const n = try f.exec("norel.service", &.{ "--phase", "reload" });
    try testing.expectEqual(@as(u8, 1), n.code);
    try expectContains(n.err, "no ExecReload=");
}

fn waitForFile(f: *Fixture, path: []const u8) !void {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (f.fs.exists(path)) return;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.TestTimedOut;
}

test "stop terminates the main process and runs ExecStop and ExecStopPost" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("sl.service",
        \\ExecStart=/bin/sleep 30
        \\ExecStop=/bin/echo stop-command ${MAINPID}
        \\ExecStopPost=/bin/echo stop-post
        \\RuntimeDirectory=slsvc
    );
    var child = try std.process.spawn(testing.io, .{
        .argv = try f.argv(&.{ "--exec", "sl.service" }),
        .environ_map = &f.env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    try waitForFile(&f, "/run/fake-systemd/sl.service.pid");
    // The pid file is written before the exec; wait for the exec so the signal is not lost.
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    const r = try f.exec("sl.service", &.{ "--phase", "stop" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.out, "stop-command ");
    try expectContains(r.out, "stop-post\n");
    const term = try child.wait(testing.io);
    switch (term) {
        .signal => |s| try testing.expectEqual(linux.SIG.TERM, s),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!f.fs.exists("/run/fake-systemd/sl.service.pid"));
}

test "stop-main runs ExecStop and terminates the process, and leaves ExecStopPost to stop-post" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("sm.service",
        \\ExecStart=/bin/sleep 30
        \\ExecStop=/bin/echo stop-command
        \\ExecStopPost=/bin/echo stop-post
    );
    var child = try std.process.spawn(testing.io, .{
        .argv = try f.argv(&.{ "--exec", "sm.service" }),
        .environ_map = &f.env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    try waitForFile(&f, "/run/fake-systemd/sm.service.pid");
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    const r = try f.exec("sm.service", &.{ "--phase", "stop-main" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.out, "stop-command\n");
    try testing.expect(std.mem.find(u8, r.out, "stop-post") == null);
    const term = try child.wait(testing.io);
    switch (term) {
        .signal => |s| try testing.expectEqual(linux.SIG.TERM, s),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(f.fs.exists("/run/fake-systemd/sm.service.pid"));

    const post = try f.exec("sm.service", &.{ "--phase", "stop-post" });
    try testing.expectEqual(@as(u8, 0), post.code);
    try expectContains(post.out, "stop-post\n");
    try testing.expect(!f.fs.exists("/run/fake-systemd/sm.service.pid"));
}

test "forking services are followed through the pid file" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fs.makePath("/run");
    const body = try std.fmt.allocPrint(f.a(),
        \\Type=forking
        \\PIDFile=/run/d.pid
        \\ExecStartPre=/bin/echo prepare
        \\ExecStart=/bin/sh -c 'sleep 1 & echo $! > {s}/run/d.pid'
        \\ExecStartPost=/bin/echo started
    , .{f.root});
    try f.unit("d.service", body);
    const began = Io.Timestamp.now(testing.io, .awake);
    const r = try f.exec("d.service", &.{});
    const elapsed = began.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("prepare\nstarted\n", r.out);
    try testing.expect(elapsed >= 800);
    const daemon_pid = std.mem.trim(u8, try f.read("/run/d.pid"), "\n");
    const tracked = std.mem.trim(u8, try f.read("/run/fake-systemd/d.service.pid"), "\n");
    try testing.expectEqualStrings(daemon_pid, tracked);
}

test "forking without a live pid file times out" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("nopid.service",
        \\Type=forking
        \\PIDFile=/run/none.pid
        \\TimeoutStartSec=1
        \\ExecStart=/bin/true
    );
    const r = try f.exec("nopid.service", &.{});
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "no live process in /run/none.pid");
}

test "accounts from /etc/passwd are used for the identity" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "app:x:4000:4001::/:/bin/sh\n");
    try f.write("/etc/group", "appgrp:x:4001:app\nextra:x:4002:\n");
    try f.unit("id.service",
        \\Type=oneshot
        \\User=app
        \\SupplementaryGroups=extra
        \\StateDirectory=idsvc
        \\ExecStart=/usr/bin/id -u
        \\ExecStart=/usr/bin/id -g
        \\ExecStart=/usr/bin/id -G
        \\ExecStart=+/usr/bin/id -u
        \\ExecStart=/bin/sh -c 'echo $USER $LOGNAME $HOME'
    );
    const r = try f.exec("id.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("4000\n4001\n4001 4002\n0\napp app /\n", r.out);
    const ls = try f.runArgv(&.{ "/usr/bin/stat", "-c", "%u %g", try std.fs.path.join(f.a(), &.{ f.root, "var/lib/idsvc" }) });
    try testing.expectEqualStrings("4000 4001\n", ls.out);
}

test "unresolved accounts leave the identity alone with a warning" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("ghost.service",
        \\Type=oneshot
        \\User=ldapuser
        \\ExecStart=/usr/bin/id -u
    );
    const r = try f.exec("ghost.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("0\n", r.out);
    try expectContains(r.err, "'ldapuser' is not in /etc/passwd");
}

test "executor reports unknown units and bad arguments" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.exec("nothere.service", &.{});
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "nothere.service");
    const bad = try f.runArgv(&.{ f.exe, "--exec" });
    try testing.expectEqual(@as(u8, 1), bad.code);
    try expectContains(bad.err, "missing unit name");
}

test "logger writes timestamped lines and rotates" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.pipeLog("one\\ntwo\\n\\nlast without newline", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    const text = try f.read("/var/log/fake-systemd/web.service/current");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const l1 = lines.next().?;
    try testing.expectEqual(@as(?usize, 29), std.mem.findScalar(u8, l1, ' '));
    try testing.expect(std.mem.endsWith(u8, l1, "+00:00 one"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "+00:00 two"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "+00:00 "));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "+00:00 last without newline"));

    const rotated = try f.pipeLog("aaaaaaaaaaaaaaaaaaaa\\nbbbbbbbbbbbbbbbbbbbb\\ncccccccccccccccccccc\\n", &.{ "--max-size", "100", "--keep", "2" });
    try testing.expectEqual(@as(u8, 0), rotated.code);
    const entries = try f.fs.iterateDir(f.a(), "/var/log/fake-systemd/web.service");
    var rotated_files: usize = 0;
    for (entries) |e| {
        if (e.name[0] == '@') rotated_files += 1;
    }
    try testing.expectEqual(@as(usize, 1), rotated_files);
}

/// Number of zombie processes whose parent is `parent`.
fn countZombies(f: *Fixture, parent: i32) !usize {
    var proc = try Io.Dir.openDirAbsolute(testing.io, "/proc", .{ .iterate = true });
    defer proc.close(testing.io);
    var count: usize = 0;
    var it = proc.iterate();
    while (try it.next(testing.io)) |entry| {
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const path = try std.fmt.allocPrint(f.a(), "{s}/stat", .{entry.name});
        const stat = proc.readFileAlloc(testing.io, path, f.a(), .limited(4096)) catch continue;
        const close_paren = std.mem.findScalarLast(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
        const state = fields.next() orelse continue;
        const ppid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        if (state[0] == 'Z' and ppid == parent) count += 1;
    }
    return count;
}

test "orphans adopted by the forking supervisor are reaped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fs.makePath("/run");
    const body = try std.fmt.allocPrint(f.a(),
        \\Type=forking
        \\PIDFile=/run/o.pid
        \\ExecStart=/bin/sh -c '(true &); (true &); (true &); sleep 3 & echo $! > {s}/run/o.pid'
    , .{f.root});
    try f.unit("o.service", body);
    var child = try std.process.spawn(testing.io, .{
        .argv = try f.argv(&.{ "--exec", "o.service" }),
        .environ_map = &f.env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    const executor_pid = child.id.?;
    try waitForFile(&f, "/run/o.pid");
    try testing.io.sleep(.fromMilliseconds(700), .awake);
    try testing.expectEqual(@as(usize, 0), try countZombies(&f, executor_pid));
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

test "ExecStartPost keeps the executor resident as supervisor of a simple service" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("sp.service",
        \\Type=simple
        \\ExecStart=/bin/sh -c 'echo main; exit 5'
        \\ExecStartPost=/bin/echo post
    );
    const r = try f.exec("sp.service", &.{});
    try testing.expectEqual(@as(u8, 5), r.code);
    try expectContains(r.out, "main\n");
    try expectContains(r.out, "post\n");

    try f.unit("spok.service",
        \\Type=simple
        \\SuccessExitStatus=5
        \\ExecStart=/bin/sh -c 'exit 5'
        \\ExecStartPost=/bin/true
    );
    try testing.expectEqual(@as(u8, 0), (try f.exec("spok.service", &.{})).code);

    try f.unit("spsig.service",
        \\ExecStart=/bin/sh -c 'kill -9 $$$$'
        \\ExecStartPost=/bin/true
    );
    try testing.expectEqual(@as(u8, 128 + 9), (try f.exec("spsig.service", &.{})).code);
}

test "ExecStartPost of an exec service runs after the main process started" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("ex.service",
        \\Type=exec
        \\ExecStart=/bin/sh -c 'sleep 1; echo main; exit 6'
        \\ExecStartPost=/bin/echo post
    );
    const began = Io.Timestamp.now(testing.io, .awake);
    const r = try f.exec("ex.service", &.{});
    try testing.expectEqual(@as(u8, 6), r.code);
    try testing.expectEqualStrings("post\nmain\n", r.out);
    try testing.expect(began.untilNow(testing.io, .awake).toMilliseconds() >= 900);

    try f.unit("exmiss.service",
        \\Type=exec
        \\ExecStart=/does/not/exist
        \\ExecStartPost=/bin/true
    );
    try testing.expectEqual(@as(u8, 203), (try f.exec("exmiss.service", &.{})).code);
}

test "a failing ExecStartPost stops the main process" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("pf.service",
        \\ExecStart=/bin/sleep 30
        \\ExecStartPost=/bin/sh -c 'exit 4'
    );
    const began = Io.Timestamp.now(testing.io, .awake);
    const r = try f.exec("pf.service", &.{});
    try testing.expectEqual(@as(u8, 4), r.code);
    try testing.expect(began.untilNow(testing.io, .awake).toMilliseconds() < 10_000);
}

test "without ExecStartPost the main command replaces the executor" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("direct.service", "ExecStart=/bin/sh -c 'exit 8'");
    try testing.expectEqual(@as(u8, 8), (try f.exec("direct.service", &.{})).code);
    try f.unit("directpid.service", "ExecStart=/bin/sh -c 'echo $PPID'");
    const r = try f.exec("directpid.service", &.{});
    // The shell is a direct child of the test, not of an executor process in between.
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.a(), "{d}\n", .{linux.getpid()}), r.out);
}

fn spawnStoppable(f: *Fixture, unit_name: []const u8) !std.process.Child {
    return std.process.spawn(testing.io, .{
        .argv = try f.argv(&.{ "--exec", unit_name, "--stop-on-signal" }),
        .environ_map = &f.env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn mainPidOf(f: *Fixture, unit_name: []const u8) !i32 {
    const path = try std.fmt.allocPrint(f.a(), "/run/fake-systemd/{s}.pid", .{unit_name});
    try waitForFile(f, path);
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    return std.fmt.parseInt(i32, std.mem.trim(u8, try f.read(path), " \n"), 10);
}

test "SIGTERM to a supervisor in stop mode runs ExecStop with MAINPID, ends the main process and exits cleanly" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const body = try std.fmt.allocPrint(f.a(),
        \\ExecStart=/bin/sleep 30
        \\ExecStop=/bin/sh -c 'kill -0 $MAINPID && echo "$MAINPID" > {s}/stopped'
    , .{f.root});
    try f.unit("ss.service", body);
    var child = try std.process.spawn(testing.io, .{
        .argv = try f.argv(&.{ "--exec", "ss.service", "--stop-on-signal" }),
        .environ_map = &f.env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    const main_pid = try mainPidOf(&f, "ss.service");
    try testing.expect(main_pid != child.id.?);
    sys_kill(child.id.?, .TERM);
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
    const recorded = std.mem.trim(u8, try f.read("/stopped"), " \n");
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.a(), "{d}", .{main_pid}), recorded);
    try testing.expect(linux.errno(linux.kill(main_pid, @fromBackingInt(@intCast(0)))) == .SRCH);
}

fn sys_kill(pid: i32, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

test "other signals reach the main process of a supervisor in stop mode" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const body = try std.fmt.allocPrint(f.a(),
        \\ExecStart=/bin/sh -c 'trap "touch {s}/got-usr1" USR1; echo ready > {s}/ready; while :; do sleep 0.1; done'
        \\ExecStop=/bin/true
    , .{ f.root, f.root });
    try f.unit("fw.service", body);
    var child = try spawnStoppable(&f, "fw.service");
    errdefer child.kill(testing.io);
    try waitForFile(&f, "/ready");
    sys_kill(child.id.?, .USR1);
    try waitForFile(&f, "/got-usr1");
    sys_kill(child.id.?, .TERM);
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

test "a failing ExecStop does not keep the main process from being terminated" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("sf.service",
        \\ExecStart=/bin/sleep 30
        \\ExecStop=/bin/sh -c 'exit 3'
        \\KillSignal=SIGINT
    );
    var child = try spawnStoppable(&f, "sf.service");
    errdefer child.kill(testing.io);
    const main_pid = try mainPidOf(&f, "sf.service");
    sys_kill(child.id.?, .TERM);
    const term = try child.wait(testing.io);
    // SIGINT ends the main process; it is in the default success set.
    try testing.expectEqual(@as(u8, 0), term.exited);
    try testing.expect(linux.errno(linux.kill(main_pid, @fromBackingInt(@intCast(0)))) == .SRCH);
}

test "the exit status of the main process is the status of the supervisor when it ends by itself" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("se.service",
        \\ExecStart=/bin/sh -c 'exit 9'
        \\ExecStop=/bin/true
    );
    var child = try spawnStoppable(&f, "se.service");
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 9), term.exited);
}

test "the main command replaces the executor when there is nothing to run at stop" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("nostop.service", "ExecStart=/bin/sh -c 'echo $PPID'");
    const r = try f.exec("nostop.service", &.{"--stop-on-signal"});
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.a(), "{d}\n", .{linux.getpid()}), r.out);
}

test "a SIGTERM that comes while ExecStartPre runs ends the start" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("pre.service",
        \\ExecStartPre=/bin/sleep 5
        \\ExecStart=/bin/sleep 30
        \\ExecStop=/bin/true
    );
    var child = try spawnStoppable(&f, "pre.service");
    errdefer child.kill(testing.io);
    try waitForFile(&f, "/run/fake-systemd/pre.service.pid");
    sys_kill(child.id.?, .TERM);
    const began = Io.Timestamp.now(testing.io, .awake);
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 143), term.exited);
    try testing.expect(began.untilNow(testing.io, .awake).toMilliseconds() < 4000);
}

test "record-exit keeps the executor resident and writes how the main process ended" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("bad.service", "ExecStart=/bin/sh -c 'exit 3'");
    try f.unit("good.service", "ExecStart=/bin/sh -c 'exit 0'");
    try f.unit("accepted.service", "ExecStart=/bin/sh -c 'exit 3'\nSuccessExitStatus=3");
    try f.write("/run/fake-systemd/good.service.exit", "failed 9\n");

    const bad = try f.exec("bad.service", &.{"--record-exit"});
    try testing.expectEqual(@as(u8, 3), bad.code);
    try testing.expectEqualStrings("failed 3\n", try f.read("/run/fake-systemd/bad.service.exit"));
    const good = try f.exec("good.service", &.{"--record-exit"});
    try testing.expectEqual(@as(u8, 0), good.code);
    try testing.expectEqualStrings("ok 0\n", try f.read("/run/fake-systemd/good.service.exit"));
    const accepted = try f.exec("accepted.service", &.{"--record-exit"});
    try testing.expectEqual(@as(u8, 0), accepted.code);
    try testing.expectEqualStrings("ok 0\n", try f.read("/run/fake-systemd/accepted.service.exit"));
}

test "record-exit records a stop by SIGTERM as clean and a kill as no file" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("sleeper.service", "ExecStart=/bin/sleep 30");
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(f.a(), &.{ "--exec", "sleeper.service", "--record-exit" });
    var child = try std.process.spawn(testing.io, .{ .argv = try f.argv(args.items), .environ_map = &f.env });
    errdefer child.kill(testing.io);
    try waitForFile(&f, "/run/fake-systemd/sleeper.service.pid");
    try testing.expect(!f.fs.exists("/run/fake-systemd/sleeper.service.exit"));
    sys_kill(child.id.?, .TERM);
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
    try testing.expectEqualStrings("ok 0\n", try f.read("/run/fake-systemd/sleeper.service.exit"));
}

test "log sends stdout and stderr of the unit to one logger child" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("noisy.service", "ExecStart=/bin/sh -c 'echo out-line; echo err-line >&2'");
    const r = try f.exec("noisy.service", &.{ "--log", "--record-exit" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("", r.out);
    try waitForFile(&f, "/var/log/fake-systemd/noisy.service/current");
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        const text = try f.read("/var/log/fake-systemd/noisy.service/current");
        if (std.mem.count(u8, text, "\n") >= 2) break;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    }
    const text = try f.read("/var/log/fake-systemd/noisy.service/current");
    try expectContains(text, " out-line\n");
    try expectContains(text, " err-line\n");
}
