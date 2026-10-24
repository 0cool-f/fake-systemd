// SPDX-License-Identifier: GPL-3.0-or-later
//! `fake-systemd --run-job` and `--timers` as real processes against a tmp filesystem root: the
//! service runs through the executor, its output lands in the uniform log, and the index records
//! the run.
const std = @import("std");
const Io = std.Io;
const fs_sys = @import("fake_systemd");
const build_options = @import("build_options");

const core = fs_sys.core;
const Index = fs_sys.index.Index;
const testing = std.testing;

const state_dir = "/var/lib/fake-systemd/dinit";

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
        try f.env.put("FAKE_SYSTEMD_INIT", "dinit");
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

    /// A timer with its service, armed in the index as `scheduler`.
    fn job(f: *Fixture, name: []const u8, service_body: []const u8, timer_body: []const u8, scheduler: []const u8) !void {
        try f.write(try std.fmt.allocPrint(f.a(), "/etc/systemd/system/{s}.service", .{name}), try std.fmt.allocPrint(f.a(), "[Service]\n{s}\n", .{service_body}));
        try f.write(try std.fmt.allocPrint(f.a(), "/etc/systemd/system/{s}.timer", .{name}), try std.fmt.allocPrint(f.a(), "[Timer]\n{s}\n", .{timer_body}));
        var idx: Index = Index.init("dinit", fs_sys.backend.Dinit.generator_number);
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        var diag: core.Diag = .init(&w, .@"error");
        const index_path = state_dir ++ "/index";
        if (f.fs.exists(index_path)) {
            idx = (try Index.load(f.a(), f.fs, &diag, index_path, "dinit", fs_sys.backend.Dinit.generator_number)).index;
        }
        try idx.putTimer(f.a(), .{
            .name = try std.fmt.allocPrint(f.a(), "{s}.timer", .{name}),
            .scheduler = scheduler,
            .src_hash = 1,
            .src_stat = 1,
            .last_trigger = null,
            .next_trigger = null,
        });
        try idx.save(f.a(), f.fs, index_path);
    }

    fn argv(f: *Fixture, mode_args: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(f.a(), f.exe);
        try list.appendSlice(f.a(), mode_args);
        try list.appendSlice(f.a(), &.{ "--root", f.root });
        return list.toOwnedSlice(f.a());
    }

    const Result = struct { code: u8, out: []const u8, err: []const u8 };

    fn run(f: *Fixture, mode_args: []const []const u8) !Result {
        const res = try std.process.run(f.a(), testing.io, .{ .argv = try f.argv(mode_args), .environ_map = &f.env });
        const code: u8 = switch (res.term) {
            .exited => |c| c,
            .signal => |s| 128 + @as(u8, @intCast(@backingInt(s))),
            else => 255,
        };
        return .{ .code = code, .out = res.stdout, .err = res.stderr };
    }

    fn read(f: *Fixture, path: []const u8) ![]u8 {
        return f.fs.readFileAlloc(f.a(), path, 1 << 22);
    }

    fn log(f: *Fixture, unit: []const u8) ![]const u8 {
        return f.read(try std.fmt.allocPrint(f.a(), "/var/log/fake-systemd/{s}/current", .{unit}));
    }

    fn index(f: *Fixture) ![]u8 {
        return f.read(state_dir ++ "/index");
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "run-job logs the service output to the uniform log and records the result" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.job("hello", "Type=oneshot\nExecStart=/bin/echo hello-from-job\nExecStart=/bin/sh -c 'echo to-stderr >&2'", "OnCalendar=daily", "builtin");
    const r = try f.run(&.{ "--run-job", "hello.service", "--timer", "hello.timer" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("", r.out);
    try testing.expectEqualStrings("", r.err);
    const log = try f.log("hello.service");
    try expectContains(log, " hello-from-job\n");
    try expectContains(log, " to-stderr\n");
    try testing.expect(std.mem.startsWith(u8, log, "20"));
    const index = try f.index();
    try expectContains(index, "timer\thello.timer\tbuiltin\t");
    try expectContains(index, "\tsuccess\n");
}

test "run-job returns the exit status of a failing service and records it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.job("fails", "Type=oneshot\nExecStart=/bin/sh -c 'echo before; exit 3'", "OnCalendar=daily", "builtin");
    const r = try f.run(&.{ "--run-job", "fails.service", "--timer", "fails.timer" });
    try testing.expectEqual(@as(u8, 3), r.code);
    try expectContains(try f.log("fails.service"), " before\n");
    try expectContains(try f.index(), "\texit-code:3\n");
}

test "run-job runs a simple service to the end and a cron timer gets its next elapse" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.job("simple", "ExecStart=/bin/sh -c 'echo simple-out'", "OnCalendar=daily", "cron:cronie");
    const r = try f.run(&.{ "--run-job", "simple.service", "--timer", "simple.timer" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(try f.log("simple.service"), " simple-out\n");
    const index = try f.index();
    try expectContains(index, "timer\tsimple.timer\tcron:cronie\t");
    try testing.expect(std.mem.find(u8, index, "\t-\tsuccess\n") == null);
}

test "run-job skips a service whose previous run holds the lock" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.job("busy", "Type=oneshot\nExecStart=/bin/echo should-not-run", "OnCalendar=daily", "builtin");
    var held = (try fs_sys.index.lock.tryAcquire(f.fs, state_dir ++ "/jobs/busy.service.lock")).?;
    defer held.release();
    const r = try f.run(&.{ "--run-job", "busy.service", "--timer", "busy.timer" });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("", r.out);
    try testing.expect(!f.fs.exists("/var/log/fake-systemd/busy.service/current"));
}

test "run-job without a timer name is a usage error" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run(&.{ "--run-job", "x.service" });
    try testing.expectEqual(@as(u8, 1), r.code);
    try expectContains(r.err, "--run-job needs --timer");
}

test "the runner fires a calendar timer repeatedly and stops on SIGTERM" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.job("tick", "Type=oneshot\nExecStart=/bin/echo tick-ran", "OnCalendar=*:*:0/2", "builtin");
    var child = try std.process.spawn(testing.io, .{ .argv = try f.argv(&.{"--timers"}), .environ_map = &f.env });
    try testing.io.sleep(.fromSeconds(7), .awake);
    try std.posix.kill(child.id.?, .TERM);
    const term = try child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
    const log = try f.log("tick.service");
    try testing.expect(std.mem.count(u8, log, " tick-ran\n") >= 2);
    try expectContains(try f.index(), "\tsuccess\n");
}
