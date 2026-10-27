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
    // Any live process of the account the service runs as is a valid main process.
    try f.write("/run/fake-systemd/rel.service.pid", try pidRecord(f.a(), linux.getpid()));
    const r = try f.exec("rel.service", &.{ "--phase", "reload" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.a(), "reload {d}\n", .{linux.getpid()}), r.out);

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
        \\ExecStartPost=/bin/sh -c 'cut -d" " -f1 {s}/run/fake-systemd/d.service.pid'
    , .{ f.root, f.root });
    try f.unit("d.service", body);
    const began = Io.Timestamp.now(testing.io, .awake);
    const r = try f.exec("d.service", &.{});
    const elapsed = began.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(elapsed >= 800);
    const daemon_pid = std.mem.trim(u8, try f.read("/run/d.pid"), "\n");
    // ExecStartPost saw the pid file of the executor name the daemon.
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.a(), "prepare\n{s}\n", .{daemon_pid}), r.out);
    // The pid file goes with the main process.
    try testing.expect(!f.fs.exists("/run/fake-systemd/d.service.pid"));
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

test "unresolved accounts are refused as root instead of running the service as root" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "app:x:4000:4001::/:/bin/sh\n");
    try f.write("/etc/group", "appgrp:x:4001:app\n");
    try f.unit("ghost.service",
        \\Type=oneshot
        \\User=ldapuser
        \\ExecStart=/usr/bin/id -u
    );
    const r = try f.exec("ghost.service", &.{});
    try testing.expectEqual(@as(u8, 217), r.code);
    try testing.expectEqualStrings("", r.out);
    try expectContains(r.err, "'ldapuser' is not in /etc/passwd");

    try f.unit("noshadowgroup.service",
        \\Type=oneshot
        \\User=app
        \\Group=nosuchgroup
        \\ExecStart=/usr/bin/id -u
    );
    const g = try f.exec("noshadowgroup.service", &.{});
    try testing.expectEqual(@as(u8, 216), g.code);
    try testing.expectEqualStrings("", g.out);

    try f.unit("nosupp.service",
        \\Type=oneshot
        \\User=app
        \\SupplementaryGroups=nosuchgroup
        \\ExecStart=/usr/bin/id -u
    );
    const s = try f.exec("nosupp.service", &.{});
    try testing.expectEqual(@as(u8, 216), s.code);
    try testing.expectEqualStrings("", s.out);

    // A unit without accounts is not affected.
    try f.unit("plain.service",
        \\Type=oneshot
        \\ExecStart=/usr/bin/id -u
    );
    const p = try f.exec("plain.service", &.{});
    try testing.expectEqual(@as(u8, 0), p.code);
    try testing.expectEqualStrings("0\n", p.out);
}

test "an account database that cannot be read does not read as no such account" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A directory in place of /etc/passwd cannot be read.
    try f.fs.makePath("/etc/passwd");
    try f.unit("db.service",
        \\Type=oneshot
        \\User=app
        \\ExecStart=/usr/bin/id -u
    );
    const r = try f.exec("db.service", &.{});
    try testing.expectEqual(@as(u8, 217), r.code);
    try testing.expectEqualStrings("", r.out);
    try expectContains(r.err, "cannot read /etc/passwd or /etc/group");
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
    var fields = std.mem.tokenizeAny(u8, try f.read(path), " \n");
    return std.fmt.parseInt(i32, fields.next() orelse return error.TestUnexpectedResult, 10);
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

test "daemon detaches, writes the pid of the executor and leaves no stream open" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("bg.service", "ExecStart=/bin/sleep 30");
    // `run` returns only when the standard streams of every process that inherited them are closed.
    const r = try f.exec("bg.service", &.{ "--daemon", "--log", "--record-exit" });
    try testing.expectEqual(@as(u8, 0), r.code);
    const pid_file = "/run/fake-systemd/bg.service.daemon.pid";
    const pid = try std.fmt.parseInt(i32, std.mem.trim(u8, try f.read(pid_file), " \n"), 10);
    try testing.expect(sys_kill_check(pid));
    const stat = try std.fmt.allocPrint(f.a(), "/proc/{d}/stat", .{pid});
    const text = (try f.runArgv(&.{ "/bin/cat", stat })).out;
    // Fields after the command name: state, ppid, pgrp, session.
    const close = std.mem.findScalarLast(u8, text, ')').?;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = it.next();
    _ = it.next();
    const group = try std.fmt.parseInt(i32, it.next().?, 10);
    const session = try std.fmt.parseInt(i32, it.next().?, 10);
    // The session was made by the first child, which is gone: the executor leads nothing.
    try testing.expect(session == group and session != pid);
    try waitForFile(&f, "/run/fake-systemd/bg.service.pid");
    sys_kill(pid, .TERM);
    try waitForFile(&f, "/run/fake-systemd/bg.service.exit");
    try testing.expectEqualStrings("ok 0\n", try f.read("/run/fake-systemd/bg.service.exit"));
}

fn sys_kill_check(pid: i32) bool {
    return linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
}

const Meta = struct { uid: u32, gid: u32, mode: u16 };

fn realPath(f: *Fixture, path: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(f.a(), "{s}{s}", .{ f.root, path }, 0);
}

fn metaOf(f: *Fixture, path: []const u8) !Meta {
    var stx: linux.Statx = undefined;
    const p = try realPath(f, path);
    const rc = linux.statx(linux.AT.FDCWD, p.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .GID = true, .MODE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
    return .{ .uid = stx.uid, .gid = stx.gid, .mode = stx.mode & 0o7777 };
}

fn setMode(f: *Fixture, path: []const u8, mode: u16) !void {
    const p = try realPath(f, path);
    if (linux.errno(linux.chmod(p.ptr, mode)) != .SUCCESS) return error.ChmodFailed;
}

/// The text of an executor state file that records process `pid`.
fn pidRecord(gpa: std.mem.Allocator, pid: i32) ![]const u8 {
    const start = fs_sys.exec.procs.startTime(pid) orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(gpa, "{d} {d}\n", .{ pid, start });
}

fn setOwner(f: *Fixture, path: []const u8, uid: u32, gid: u32) !void {
    const p = try realPath(f, path);
    if (linux.errno(linux.chown(p.ptr, uid, gid)) != .SUCCESS) return error.ChownFailed;
}

/// Process state letter from `/proc/<pid>/stat`; null when the process does not exist.
fn procState(f: *Fixture, pid: i32) !?u8 {
    const path = try std.fmt.allocPrint(f.a(), "/proc/{d}/stat", .{pid});
    const res = try f.runArgv(&.{ "/bin/cat", path });
    if (res.code != 0) return null;
    const close_paren = std.mem.findScalarLast(u8, res.out, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, res.out[close_paren + 1 ..], ' ');
    return (fields.next() orelse return null)[0];
}

fn isAlive(f: *Fixture, pid: i32) !bool {
    const state = (try procState(f, pid)) orelse return false;
    return state != 'Z' and state != 'X';
}

const directory_keys = [_]struct { key: []const u8, code: u8, base: []const u8 }{
    .{ .key = "RuntimeDirectory", .code = 233, .base = "/run" },
    .{ .key = "StateDirectory", .code = 238, .base = "/var/lib" },
    .{ .key = "CacheDirectory", .code = 239, .base = "/var/cache" },
    .{ .key = "LogsDirectory", .code = 240, .base = "/var/log" },
    .{ .key = "ConfigurationDirectory", .code = 241, .base = "/etc" },
};

test "dot and empty directory components are refused for every kind and change nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (directory_keys) |k| {
        try f.fs.makePath(k.base);
        try setMode(&f, k.base, 0o711);
    }
    for (directory_keys) |k| {
        for ([_][]const u8{ ".", "./", "a/./b", "a//b", "a/" }) |bad| {
            const body = try std.fmt.allocPrint(f.a(), "Type=oneshot\nExecStart=/bin/true\n{s}={s}", .{ k.key, bad });
            try f.unit("dot.service", body);
            const r = try f.exec("dot.service", &.{});
            try testing.expectEqual(k.code, r.code);
            try expectContains(r.err, "invalid directory");
        }
    }
    for (directory_keys) |k| try testing.expectEqual(@as(u16, 0o711), (try metaOf(&f, k.base)).mode);
}

test "stop-post with RuntimeDirectory=. does not remove the runtime base" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/run/precious/data", "x");
    try f.unit("dot.service",
        \\ExecStart=/bin/sleep 30
        \\RuntimeDirectory=.
    );
    const r = try f.exec("dot.service", &.{ "--phase", "stop-post" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(f.fs.exists("/run/precious/data"));
}

test "a symlink below the base is refused and its target is left alone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fs.makePath("/etc/target");
    try setMode(&f, "/etc/target", 0o700);
    try f.fs.makePath("/var/lib/app");
    try f.fs.symLink("/etc/target", "/var/lib/app/sub");
    try f.fs.symLink("/etc/target", "/var/lib/direct");
    try f.unit("nested.service", "Type=oneshot\nExecStart=/bin/true\nStateDirectory=app/sub");
    const nested = try f.exec("nested.service", &.{});
    try testing.expectEqual(@as(u8, 238), nested.code);
    try expectContains(nested.err, "cannot set up");
    try f.unit("direct.service", "Type=oneshot\nExecStart=/bin/true\nStateDirectory=direct");
    const direct = try f.exec("direct.service", &.{});
    try testing.expectEqual(@as(u8, 238), direct.code);
    try testing.expectEqual(@as(u16, 0o700), (try metaOf(&f, "/etc/target")).mode);
}

test "stop-post does not remove through a symlink below the base" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/srv/keep/sub/data", "x");
    try f.fs.makePath("/run");
    try f.fs.symLink("/srv/keep", "/run/app");
    try f.unit("rm.service",
        \\ExecStart=/bin/sleep 30
        \\RuntimeDirectory=app/sub
    );
    const r = try f.exec("rm.service", &.{ "--phase", "stop-post" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(f.fs.exists("/srv/keep/sub/data"));
}

test "a pid file written by the service account cannot get another account's process signalled" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    try f.unit("spoof.service",
        \\ExecStart=/bin/sleep 30
        \\User=svc
        \\ExecStopPost=/bin/true
    );
    // A process of root, which the unit's account must not be able to name.
    var victim = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer victim.kill(testing.io);
    const pid = victim.id.?;
    try f.write("/run/fake-systemd/spoof.service.pid", try pidRecord(f.a(), pid));
    try setOwner(&f, "/run/fake-systemd/spoof.service.pid", 4242, 4242);
    const r = try f.exec("spoof.service", &.{ "--phase", "stop" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.err, "not the recorded process of the service");
    try testing.expect(try isAlive(&f, pid));

    // The same file written by root names the process legitimately.
    try f.write("/run/fake-systemd/spoof.service.pid", try pidRecord(f.a(), pid));
    const ok = try f.exec("spoof.service", &.{ "--phase", "stop-main" });
    try testing.expectEqual(@as(u8, 0), ok.code);
    try testing.expect(!(try isAlive(&f, pid)));
}

test "pids 0 and 1 are never signalled" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("init.service", "ExecStart=/bin/sleep 30\nExecReload=/bin/echo main=${MAINPID}");
    for ([_][]const u8{ "1\n", "0\n", "-1\n" }) |text| {
        try f.write("/run/fake-systemd/init.service.pid", text);
        const r = try f.exec("init.service", &.{ "--phase", "stop-main" });
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(try isAlive(&f, 1));
        const reload = try f.exec("init.service", &.{ "--phase", "reload" });
        try testing.expectEqualStrings("main=\n", reload.out);
    }
}

test "state files are written by root, replace files the service account owns and refuse symlinks" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    try f.unit("state.service",
        \\Type=oneshot
        \\User=svc
        \\ExecStart=/bin/true
    );
    // State an earlier version handed to the account.
    try f.write("/run/fake-systemd/state.service.exit", "ok 0\n");
    try setOwner(&f, "/run/fake-systemd/state.service.exit", 4242, 4242);
    try setMode(&f, "/run/fake-systemd/state.service.exit", 0o666);
    try setOwner(&f, "/run/fake-systemd", 4242, 4242);
    try setMode(&f, "/run/fake-systemd", 0o777);
    const r = try f.exec("state.service", &.{"--record-exit"});
    try testing.expectEqual(@as(u8, 0), r.code);
    const dir = try metaOf(&f, "/run/fake-systemd");
    try testing.expectEqual(@as(u32, 0), dir.uid);
    try testing.expectEqual(@as(u16, 0o755), dir.mode);
    const exit_file = try metaOf(&f, "/run/fake-systemd/state.service.exit");
    try testing.expectEqual(@as(u32, 0), exit_file.uid);
    try testing.expectEqual(@as(u16, 0o644), exit_file.mode);
    try testing.expectEqualStrings("ok 0\n", try f.read("/run/fake-systemd/state.service.exit"));

    // A symlink in place of a state file is not followed, even out of the root.
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "victim", .data = "untouched" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try outside.dir.realPath(testing.io, &buf);
    const target = try std.fs.path.join(f.a(), &.{ buf[0..n], "victim" });
    // The service replaces the exit file with a symlink while it runs; the executor does not follow it.
    const body = try std.fmt.allocPrint(f.a(),
        \\Type=oneshot
        \\ExecStart=/bin/sh -c 'ln -s {s} {s}/run/fake-systemd/link.service.exit'
    , .{ target, f.root });
    try f.unit("link.service", body);
    const link = try f.exec("link.service", &.{"--record-exit"});
    try testing.expectEqual(@as(u8, 0), link.code);
    try expectContains(link.err, "cannot write");
    const content = try outside.dir.readFileAlloc(testing.io, "victim", f.a(), .limited(100));
    try testing.expectEqualStrings("untouched", content);
}

test "a FIFO in place of the log file does not block the logger" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fs.makePath("/var/log/fake-systemd/web.service");
    const fifo = try realPath(&f, "/var/log/fake-systemd/web.service/current");
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, fifo.ptr, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.MknodFailed;
    const r = try f.pipeLog("one\\ntwo\\n", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.err, "log:");
}

test "a lock entry that is not a regular file does not stop logging" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fs.makePath("/var/log/fake-systemd/web.service/.lock");
    const input = "aaaaaaaaaaaaaaaaaaaa\\nbbbbbbbbbbbbbbbbbbbb\\ncccccccccccccccccccc\\ndddddddddddddddddddd\\n";
    const r = try f.pipeLog(input, &.{ "--max-size", "60" });
    try testing.expectEqual(@as(u8, 0), r.code);
    const text = try f.read("/var/log/fake-systemd/web.service/current");
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "\n"));
    try expectContains(r.err, "rotation is off");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "warning: log:"));
}

test "the log directory of a unit is 0750, its files 0640 and the directories above stay traversable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.pipeLog("one\\n", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(u16, 0o755), (try metaOf(&f, "/var/log/fake-systemd")).mode);
    try testing.expectEqual(@as(u16, 0o750), (try metaOf(&f, "/var/log/fake-systemd/web.service")).mode);
    try testing.expectEqual(@as(u16, 0o640), (try metaOf(&f, "/var/log/fake-systemd/web.service/current")).mode);
}

test "specifiers name the manager's passwd entry, not USER or HOME" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("USER", "attacker");
    try f.env.put("HOME", "/attacker");
    const entry = try std.fmt.allocPrint(f.a(), "me:x:{d}:{d}::/home/me:/bin/sh\n", .{ linux.getuid(), linux.getgid() });
    try f.write("/etc/passwd", entry);
    try f.unit("spec.service",
        \\Type=oneshot
        \\ExecStart=/bin/echo %u %h
    );
    const r = try f.exec("spec.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("me /home/me\n", r.out);
}

test "a numeric identity from the service manager is switched to without resolving the accounts" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("numeric.service",
        \\Type=oneshot
        \\User=ldapuser
        \\Group=ldapgroup
        \\StateDirectory=numsvc
        \\ExecStart=/usr/bin/id -u
        \\ExecStart=/usr/bin/id -g
        \\ExecStart=/usr/bin/id -G
    );
    const r = try f.exec("numeric.service", &.{ "--uid", "1500", "--gid", "1501", "--groups", "1502", "--record-exit" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("1500\n1501\n1501 1502\n", r.out);
    const state = try metaOf(&f, "/var/lib/numsvc");
    try testing.expectEqual(@as(u32, 1500), state.uid);
    try testing.expectEqual(@as(u32, 1501), state.gid);
    // The executor stayed root, so its own files are root's.
    try testing.expectEqual(@as(u32, 0), (try metaOf(&f, "/run/fake-systemd/numeric.service.exit")).uid);
}

test "--identity-set runs the commands as the process already is and does not refuse the names" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("set.service",
        \\Type=oneshot
        \\User=ldapuser
        \\ExecStart=/usr/bin/id -u
    );
    const r = try f.exec("set.service", &.{"--identity-set"});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("0\n", r.out);
}

fn spawnVictim() !std.process.Child {
    return std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdout = .ignore, .stderr = .ignore });
}

test "a numeric identity without the gid is refused instead of leaving gid 0 and the groups of root" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("partial.service",
        \\Type=oneshot
        \\User=ldapuser
        \\ExecStart=/usr/bin/id -u
    );
    for ([_][]const []const u8{ &.{ "--uid", "1500" }, &.{ "--gid", "1501" }, &.{ "--groups", "1502" }, &.{ "--uid", "1500", "--groups", "1502" } }) |args| {
        const r = try f.exec("partial.service", args);
        try testing.expectEqual(@as(u8, 217), r.code);
        try testing.expectEqualStrings("", r.out);
        try expectContains(r.err, "needs both --uid and --gid");
    }
    // With both, the groups default to the gid alone.
    try f.unit("full.service",
        \\Type=oneshot
        \\User=ldapuser
        \\ExecStart=/usr/bin/id -G
    );
    const ok = try f.exec("full.service", &.{ "--uid", "1500", "--gid", "1501" });
    try testing.expectEqual(@as(u8, 0), ok.code);
    try testing.expectEqualStrings("1501\n", ok.out);
}

test "an account name that starts with a dash is refused as root" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "root:x:0:0::/root:/bin/sh\n");
    try f.write("/etc/group", "root:x:0:\n");
    for ([_][]const u8{ "User=-r", "User=--", "Group=-g", "SupplementaryGroups=-a" }) |setting| {
        const body = try std.fmt.allocPrint(f.a(), "Type=oneshot\n{s}\nExecStart=/usr/bin/id -u", .{setting});
        try f.unit("dash.service", body);
        const r = try f.exec("dash.service", &.{});
        try testing.expect(r.code == 217 or r.code == 216);
        try testing.expectEqualStrings("", r.out);
    }
}

test "the directory of fake-systemd cannot be taken over through the directory settings" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    try f.fs.makePath("/var/lib/fake-systemd/sysvinit");
    try f.fs.makePath("/run/fake-systemd");
    for ([_]struct { []const u8, u8 }{
        .{ "StateDirectory=fake-systemd/sysvinit", 238 },
        .{ "RuntimeDirectory=fake-systemd", 233 },
        .{ "CacheDirectory=fake-systemd", 239 },
        .{ "LogsDirectory=fake-systemd/x", 240 },
        .{ "ConfigurationDirectory=fake-systemd", 241 },
    }) |case| {
        const body = try std.fmt.allocPrint(f.a(), "Type=oneshot\nUser=svc\n{s}\nExecStart=/bin/true", .{case[0]});
        try f.unit("evil.service", body);
        const r = try f.exec("evil.service", &.{});
        try testing.expectEqual(case[1], r.code);
        try expectContains(r.err, "reserved for fake-systemd");
    }
    try testing.expectEqual(@as(u32, 0), (try metaOf(&f, "/var/lib/fake-systemd/sysvinit")).uid);
    try testing.expectEqual(@as(u32, 0), (try metaOf(&f, "/run/fake-systemd")).uid);
    try testing.expect(!f.fs.exists("/var/cache/fake-systemd"));
}

test "an existing state directory of another package is handed to the service account as systemd does" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    try f.write("/var/lib/dpkg/info/foo.postinst", "x\n");
    try f.unit("take.service",
        \\Type=oneshot
        \\User=svc
        \\StateDirectory=dpkg
        \\ExecStart=/bin/true
    );
    const r = try f.exec("take.service", &.{});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(u32, 4242), (try metaOf(&f, "/var/lib/dpkg")).uid);
}

test "a PIDFile= that names another daemon of root is not signalled by stop, stop-main or reload" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    var victim = try spawnVictim();
    defer victim.kill(testing.io);
    const pid = victim.id.?;
    try f.write("/run/otherdaemon.pid", try std.fmt.allocPrint(f.a(), "{d}\n", .{pid}));
    try f.unit("evil.service",
        \\User=svc
        \\Type=forking
        \\PIDFile=/run/otherdaemon.pid
        \\ExecStart=/bin/true
        \\ExecReload=/bin/echo main=${MAINPID}
    );
    for ([_][]const u8{ "stop", "stop-main" }) |phase| {
        const r = try f.exec("evil.service", &.{ "--phase", phase });
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(try isAlive(&f, pid));
    }
    const reload = try f.exec("evil.service", &.{ "--phase", "reload" });
    try testing.expectEqualStrings("main=\n", reload.out);
}

test "a pid file in the runtime directory of the service, a symlink and MAINPID do not name a process to stop" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "svc:x:4242:4242::/:/bin/sh\n");
    try f.write("/etc/group", "svc:x:4242:\n");
    try f.unit("d.service",
        \\User=svc
        \\Type=forking
        \\PIDFile=/run/svc/d.pid
        \\RuntimeDirectory=svc
        \\ExecStart=/bin/sleep 1000
    );
    try f.fs.makePath("/run/svc");
    try setOwner(&f, "/run/svc", 4242, 4242);
    var victim = try spawnVictim();
    defer victim.kill(testing.io);
    const pid = victim.id.?;
    // The account writes a pid file in its own directory.
    try f.write("/run/svc/d.pid", try std.fmt.allocPrint(f.a(), "{d}\n", .{pid}));
    try setOwner(&f, "/run/svc/d.pid", 4242, 4242);
    var r = try f.exec("d.service", &.{ "--phase", "stop" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(try isAlive(&f, pid));
    // A recorded start time that the file does not carry, and a file of the account in the state directory.
    try f.write("/run/fake-systemd/d.service.pid", try std.fmt.allocPrint(f.a(), "{d}\n", .{pid}));
    try setOwner(&f, "/run/fake-systemd/d.service.pid", 4242, 4242);
    r = try f.exec("d.service", &.{ "--phase", "stop-main" });
    try testing.expect(try isAlive(&f, pid));
    // A symlink in place of the pid file.
    try f.fs.makePath("/run/svc");
    try f.fs.symLink("/proc/sys/kernel/ns_last_pid", "/run/svc/d.pid");
    r = try f.exec("d.service", &.{ "--phase", "stop" });
    try testing.expectEqual(@as(u8, 0), r.code);
    // MAINPID from the caller naming a process of root.
    try f.env.put("MAINPID", try std.fmt.allocPrint(f.a(), "{d}", .{pid}));
    r = try f.exec("d.service", &.{ "--phase", "stop" });
    _ = f.env.orderedRemove("MAINPID");
    try expectContains(r.err, "ignoring MAINPID");
    try testing.expect(try isAlive(&f, pid));
}

test "a forking daemon is only followed when it descends from the executor" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var victim = try spawnVictim();
    defer victim.kill(testing.io);
    const pid = victim.id.?;
    try f.write("/run/other.pid", try std.fmt.allocPrint(f.a(), "{d}\n", .{pid}));
    try f.unit("claim.service",
        \\Type=forking
        \\PIDFile=/run/other.pid
        \\TimeoutStartSec=1
        \\ExecStart=/bin/true
    );
    const r = try f.exec("claim.service", &.{});
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "no live process in /run/other.pid");
    try testing.expect(try isAlive(&f, pid));
}

test "a recorded pid that was reused by another process is not signalled" {
    if (!isRoot()) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.unit("reuse.service", "ExecStart=/bin/sleep 30");
    var victim = try spawnVictim();
    defer victim.kill(testing.io);
    const pid = victim.id.?;
    const start = fs_sys.exec.procs.startTime(pid).?;
    try f.write("/run/fake-systemd/reuse.service.pid", try std.fmt.allocPrint(f.a(), "{d} {d}\n", .{ pid, start + 1 }));
    const wrong = try f.exec("reuse.service", &.{ "--phase", "stop-main" });
    try testing.expectEqual(@as(u8, 0), wrong.code);
    try testing.expect(try isAlive(&f, pid));
    try f.write("/run/fake-systemd/reuse.service.pid", try pidRecord(f.a(), pid));
    const right = try f.exec("reuse.service", &.{ "--phase", "stop-main" });
    try testing.expectEqual(@as(u8, 0), right.code);
    try testing.expect(!(try isAlive(&f, pid)));
}

test "a relative or empty --root is refused by the executor and the logger" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "relative/dir", "", "." }) |root| {
        for ([_][]const u8{ "--exec", "--log" }) |mode| {
            const r = try f.runArgv(&.{ f.exe, mode, "foo.service", "--root", root });
            try testing.expectEqual(@as(u8, 1), r.code);
            try expectContains(r.err, "--root must be an absolute path");
        }
    }
}
