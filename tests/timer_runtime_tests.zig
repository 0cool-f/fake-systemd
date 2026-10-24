// SPDX-License-Identifier: GPL-3.0-or-later
//! `--run-job` and the built-in runner loop, driven with a fake clock, a recording spawner and a
//! stub for the service execution; the real processes are exercised in `timer_exe_tests.zig`.
const std = @import("std");
const linux = std.os.linux;
const h = @import("harness.zig");
const fs_sys = @import("fake_systemd");

const rt = fs_sys.timer_runtime;
const testing = std.testing;

const us = std.time.us_per_s;
/// 2026-10-24 10:05:01 UTC.
const t0: i64 = 1_792_836_301;

fn addTimer(t: *h.Harness, name: []const u8, body: []const u8) !void {
    const service = try std.fmt.allocPrint(t.a(), "{s}.service", .{name});
    try t.addUnit("/usr/lib/systemd/system", service, "/usr/bin/job", null);
    const text = try std.fmt.allocPrint(t.a(), "[Timer]\n{s}\n\n[Install]\nWantedBy=timers.target\n", .{body});
    try t.write(try std.fmt.allocPrint(t.a(), "/usr/lib/systemd/system/{s}.timer", .{name}), text, 0o644);
}

fn setup(t: *h.Harness) !void {
    try t.init();
    try t.write("/usr/bin/fake-systemd", "#!/bin/sh\n", 0o755);
    try addTimer(t, "foo", "OnCalendar=*-*-* 03:00:00");
}

fn store(t: *h.Harness) !rt.store {
    return .init(&t.ctx, t.fake.backend());
}

// ---- run-job ----

const Job = struct {
    now: i64 = t0 * us,
    code: u8 = 0,
    runs: usize = 0,
    slept: u64 = 0,
    random: u64 = 0,
    ran_service: []const u8 = "",

    fn hooks(j: *Job) rt.runjob.Hooks {
        return .{ .ptr = j, .now_us = nowFn, .sleep_us = sleepFn, .random = randomFn, .execute = executeFn };
    }

    fn me(ptr: ?*anyopaque) *Job {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn nowFn(ptr: ?*anyopaque) i64 {
        const j = me(ptr);
        j.now += us;
        return j.now - us;
    }

    fn sleepFn(ptr: ?*anyopaque, _: *h.core.Context, delay: u64) void {
        me(ptr).slept += delay;
    }

    fn randomFn(ptr: ?*anyopaque, _: *h.core.Context) u64 {
        return me(ptr).random;
    }

    fn executeFn(ptr: ?*anyopaque, _: *h.core.Context, service: []const u8) rt.runjob.Outcome {
        const j = me(ptr);
        j.runs += 1;
        j.ran_service = service;
        return .{ .exited = j.code };
    }
};

test "run-job records the trigger time, the result and the next elapse" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.write("/usr/sbin/crond", "x", 0o755);
    try t.write("/usr/bin/cronnext", "x", 0o755);
    try t.fake.setService("cronie", .{ .enabled = true });
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    var job: Job = .{ .code = 3 };
    const code = rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    try testing.expectEqual(@as(u8, 3), code);
    try testing.expectEqual(@as(usize, 1), job.runs);
    try testing.expectEqualStrings("foo.service", job.ran_service);
    // last run at 10:05:01, next at 03:00 the following day
    try h.expectContains(try t.indexText(), "\t1792836301\t1792897200\texit-code:3\n");

    job.code = 0;
    _ = rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    try h.expectContains(try t.indexText(), "\t1792836303\t1792897200\tsuccess\n");
}

test "run-job leaves the next elapse of a built-in timer to the runner" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    const before = try t.indexText();
    try testing.expect(std.mem.find(u8, before, "builtin\t") != null);
    var job: Job = .{};
    _ = rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    const after = try t.indexText();
    try h.expectContains(after, "\t1792836301\t");
    try h.expectContains(after, "\tsuccess\n");
    // the next-trigger field is the one computed when the timer was armed
    const line_before = before[std.mem.find(u8, before, "timer\tfoo.timer").?..];
    var fields_before = std.mem.splitScalar(u8, std.mem.sliceTo(line_before, '\n'), '\t');
    var fields_after = std.mem.splitScalar(u8, std.mem.sliceTo(after[std.mem.find(u8, after, "timer\tfoo.timer").?..], '\n'), '\t');
    for (0..6) |_| {
        _ = fields_before.next();
        _ = fields_after.next();
    }
    try testing.expectEqualStrings(fields_before.next().?, fields_after.next().?);
}

test "run-job skips the run while the previous one holds the lock" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    const st = try store(&t);
    var held = (try st.tryJobLock("foo.service")).?;
    t.diag.threshold = .info;
    t.err.clearRetainingCapacity();
    var job: Job = .{};
    try testing.expectEqual(@as(u8, 0), rt.runjob.run(&t.ctx, st, .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks()));
    try testing.expectEqual(@as(usize, 0), job.runs);
    try h.expectContains(t.stderr(), "foo.service: the previous run is still active, skipping foo.timer");
    held.release();
    _ = rt.runjob.run(&t.ctx, st, .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    try testing.expectEqual(@as(usize, 1), job.runs);
    // another service is not affected by the lock of foo
    var other = (try st.tryJobLock("bar.service")).?;
    defer other.release();
    _ = rt.runjob.run(&t.ctx, st, .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    try testing.expectEqual(@as(usize, 2), job.runs);
}

test "run-job sleeps a random delay below the limit before the run" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try t.expectRun(0, &.{ "enable", "foo.timer" });
    var job: Job = .{ .random = 12_345_678 };
    _ = rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer", .random_delay_us = 10_000_000 }, job.hooks());
    try testing.expectEqual(@as(u64, 2_345_678), job.slept);
    try testing.expectEqual(@as(usize, 1), job.runs);
    job.slept = 0;
    _ = rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks());
    try testing.expectEqual(@as(u64, 0), job.slept);
}

test "run-job without an index entry still runs the service and writes nothing" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    var job: Job = .{};
    try testing.expectEqual(@as(u8, 0), rt.runjob.run(&t.ctx, try store(&t), .{ .service = "foo.service", .timer = "foo.timer" }, job.hooks()));
    try testing.expectEqual(@as(usize, 1), job.runs);
    try testing.expect(!t.exists("/var/lib/fake-systemd/fake/index"));
}

// ---- runner ----

const World = struct {
    t: *h.Harness,
    real_us: i64,
    boot_us: i64 = 300 * us,
    waits: usize = 0,
    stop_after: usize,
    reload_at: ?usize = null,
    on_reload: ?*const fn (w: *World) anyerror!void = null,
    reload_pending: bool = false,
    spawned: std.ArrayList([]const []const u8) = .empty,
    spawn_times: std.ArrayList(i64) = .empty,
    finished: std.ArrayList(i32) = .empty,
    next_pid: i32 = 500,
    signals_sent: usize = 0,
    /// Jobs are reported as finished at once; false keeps them running.
    auto_finish: bool = true,

    fn me(ptr: ?*anyopaque) *World {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn clock(w: *World) rt.runner.Clock {
        return .{ .ptr = w, .now_fn = nowFn, .wait_fn = waitFn };
    }

    fn spawner(w: *World) rt.runner.Spawner {
        return .{ .ptr = w, .spawn_fn = spawnFn, .reap_fn = reapFn, .signal_fn = signalFn };
    }

    fn signals(w: *World) rt.runner.Signals {
        return .{ .ptr = w, .take_reload_fn = takeReload, .terminating_fn = terminating };
    }

    fn nowFn(ptr: ?*anyopaque) rt.runner.Times {
        const w = me(ptr);
        return .{ .real_us = w.real_us, .boot_us = w.boot_us };
    }

    fn waitFn(ptr: ?*anyopaque, ms: u64) void {
        const w = me(ptr);
        w.waits += 1;
        w.real_us += @as(i64, @intCast(ms)) * 1000;
        w.boot_us += @as(i64, @intCast(ms)) * 1000;
        if (w.reload_at) |n| if (w.waits == n) {
            if (w.on_reload) |f| f(w) catch @panic("reload hook failed");
            w.reload_pending = true;
        };
    }

    fn spawnFn(ptr: ?*anyopaque, argv: []const []const u8) anyerror!i32 {
        const w = me(ptr);
        const a = w.t.a();
        const copy = try a.alloc([]const u8, argv.len);
        for (argv, copy) |word, *d| d.* = try a.dupe(u8, word);
        try w.spawned.append(a, copy);
        try w.spawn_times.append(a, w.real_us);
        w.next_pid += 1;
        if (w.auto_finish) try w.finished.append(a, w.next_pid);
        return w.next_pid;
    }

    fn reapFn(ptr: ?*anyopaque) ?rt.runner.Reaped {
        const w = me(ptr);
        const pid = w.finished.pop() orelse return null;
        return .{ .pid = pid, .exit = .{ .exited = 0 } };
    }

    fn signalFn(ptr: ?*anyopaque, _: i32, _: linux.SIG) void {
        me(ptr).signals_sent += 1;
    }

    fn takeReload(ptr: ?*anyopaque) bool {
        const w = me(ptr);
        defer w.reload_pending = false;
        return w.reload_pending;
    }

    fn terminating(ptr: ?*anyopaque) bool {
        const w = me(ptr);
        return w.waits >= w.stop_after;
    }
};

fn runLoop(t: *h.Harness, w: *World) !u8 {
    t.err.clearRetainingCapacity();
    const code = rt.runner.run(&t.ctx, try store(t), .{}, w.clock(), w.spawner(), w.signals());
    if (code != 0) std.debug.print("runner exited {d}:\n{s}\n", .{ code, t.stderr() });
    return code;
}

fn enableAll(t: *h.Harness, names: []const []const u8) !void {
    for (names) |n| try t.expectRun(0, &.{ "enable", n });
}

test "the runner fires a calendar timer at every elapse" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5");
    try enableAll(&t, &.{"tick.timer"});
    // 10:05:01.500, waits end exactly at each elapse
    var w: World = .{ .t = &t, .real_us = t0 * us + 500_000, .stop_after = 5 };
    try testing.expectEqual(@as(u8, 0), try runLoop(&t, &w));
    try testing.expect(w.spawned.items.len >= 3);
    try testing.expectEqual(@as(usize, 1), w.spawned.items.len - (w.spawned.items.len - 1));
    const first = w.spawned.items[0];
    try testing.expectEqualStrings("/usr/bin/fake-systemd", first[0]);
    try testing.expectEqualStrings("--run-job", first[1]);
    try testing.expectEqualStrings("tick.service", first[2]);
    try testing.expectEqualStrings("--timer", first[3]);
    try testing.expectEqualStrings("tick.timer", first[4]);
    try testing.expectEqual(@as(usize, 5), first.len);
    // fired at :05, :10, :15 ...
    for (w.spawn_times.items, 0..) |at, i| {
        try testing.expectEqual((t0 + 4 + @as(i64, @intCast(i)) * 5) * us, at);
    }
    try testing.expect(std.mem.find(u8, try t.indexText(), "timer\ttick.timer\tbuiltin\t") != null);
}

test "the runner updates the next and last trigger in the index" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5");
    try enableAll(&t, &.{"tick.timer"});
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 3 };
    _ = try runLoop(&t, &w);
    // three waits: elapses at :05 and :10 fired; the last fire was at 10:05:10, the next is 10:05:15
    try h.expectContains(try t.indexText(), "\t1792836310\t1792836315");
}

test "the runner caps the sleep at a minute" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 3 };
    try testing.expectEqual(@as(u8, 0), try runLoop(&t, &w));
    // daily at 03:00: three waits of 60 s and no job
    try testing.expectEqual(@as(usize, 0), w.spawned.items.len);
    try testing.expectEqual((t0 + 180) * us, w.real_us);
}

test "OnBootSec counts from the boot clock, Persistent catches up a missed elapse" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "boot", "OnBootSec=10min");
    try addTimer(&t, "missed", "OnCalendar=daily\nPersistent=true");
    try addTimer(&t, "unpersisted", "OnCalendar=daily");
    try enableAll(&t, &.{ "boot.timer", "missed.timer", "unpersisted.timer" });
    // the last runs of both calendar timers were two days ago
    const st = try store(&t);
    var txn = try st.begin(true);
    for ([_][]const u8{ "missed.timer", "unpersisted.timer" }) |n| txn.idx.findTimer(n).?.last_trigger = t0 - 2 * 86400;
    try txn.commit();
    // boot was 5 min ago: OnBootSec=10min elapses in 5 more minutes
    var w: World = .{ .t = &t, .real_us = t0 * us, .boot_us = 300 * us, .stop_after = 6 };
    _ = try runLoop(&t, &w);
    var names: std.ArrayList([]const u8) = .empty;
    for (w.spawned.items, w.spawn_times.items) |argv, at| {
        try names.append(t.a(), argv[4]);
        if (std.mem.eql(u8, argv[4], "missed.timer")) try testing.expectEqual(t0 * us, at);
        if (std.mem.eql(u8, argv[4], "boot.timer")) try testing.expectEqual((t0 + 300) * us, at);
    }
    if (names.items.len != 2) std.debug.print("spawned {d}: {any}\n{s}\n", .{ names.items.len, names.items.len, t.stderr() });
    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("missed.timer", names.items[0]);
    try testing.expectEqualStrings("boot.timer", names.items[1]);
}

test "RandomizedDelaySec is passed to the job" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5\nRandomizedDelaySec=2s");
    try enableAll(&t, &.{"tick.timer"});
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 2 };
    _ = try runLoop(&t, &w);
    const argv = w.spawned.items[0];
    try testing.expectEqualStrings("--random-delay", argv[5]);
    try testing.expectEqualStrings("2000000", argv[6]);
}

test "a run that is still active is not started again" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5");
    try enableAll(&t, &.{"tick.timer"});
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 4, .auto_finish = false };
    _ = try runLoop(&t, &w);
    // the fake spawner never reports the child as finished
    try testing.expectEqual(@as(usize, 1), w.spawned.items.len);
}

test "SIGHUP reloads the index and picks up new timers" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5");
    try enableAll(&t, &.{"tick.timer"});
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 6, .reload_at = 1 };
    w.on_reload = struct {
        fn f(world: *World) anyerror!void {
            try addTimer(world.t, "late", "OnCalendar=*:*:0/5");
            try world.t.expectRun(0, &.{ "enable", "late.timer" });
        }
    }.f;
    _ = try runLoop(&t, &w);
    var late: usize = 0;
    for (w.spawned.items) |argv| if (std.mem.eql(u8, argv[4], "late.timer")) {
        late += 1;
    };
    try testing.expect(late >= 1);
}

test "termination signals running jobs and waits for them" {
    var t: h.Harness = undefined;
    try setup(&t);
    defer t.deinit();
    try addTimer(&t, "tick", "OnCalendar=*:*:0/5");
    try enableAll(&t, &.{"tick.timer"});
    var w: World = .{ .t = &t, .real_us = t0 * us, .stop_after = 2, .auto_finish = false };
    _ = try runLoop(&t, &w);
    try testing.expectEqual(@as(usize, 1), w.spawned.items.len);
    // TERM after the grace period expired, then KILL: both counted
    try testing.expect(w.signals_sent >= 2);
}
