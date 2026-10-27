// SPDX-License-Identifier: GPL-3.0-or-later
//! `fake-systemd --run-job <service> --timer <timer>` (§10.1): runs the unit a timer starts.
//!
//! The service runs in-process through the executor in a child whose output goes to the uniform
//! logger of the unit, so `journalctl -u` shows it whatever the backend is: starting the
//! generated service through the backend would not give a per-run exit status on every init,
//! and a timer fired by cron has to work while the backend knows nothing about the run. A
//! per-service lock skips the run when the previous one is still active.
const std = @import("std");
const linux = std.os.linux;
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const executor = @import("../exec/executor.zig");
const identity = @import("../exec/identity.zig");
const logger = @import("../exec/logger.zig");
const sys = @import("../exec/sys.zig");
const accounts = @import("../exec/accounts.zig");
const numeric = @import("../exec/numeric.zig");
const schedule = @import("schedule.zig");
const timer_unit = @import("timer_unit.zig");
const Store = @import("store.zig");

pub const Options = struct {
    service: []const u8,
    timer: []const u8,
    /// Upper bound of the `RandomizedDelaySec=` sleep before the run, in microseconds.
    random_delay_us: u64 = 0,
};

/// How the service ended.
pub const Outcome = union(enum) {
    exited: u8,
    signaled: u8,
    /// The service could not be started at all.
    failed,

    pub fn exitCode(o: Outcome) u8 {
        return switch (o) {
            .exited => |c| c,
            .signaled => |s| 128 +| s,
            .failed => 1,
        };
    }

    /// Text stored in the index: `success`, `exit-code:N`, `signal:N` or `failed`.
    pub fn text(o: Outcome, buf: []u8) []const u8 {
        return (switch (o) {
            .exited => |c| if (c == 0) std.fmt.bufPrint(buf, "success", .{}) else std.fmt.bufPrint(buf, "exit-code:{d}", .{c}),
            .signaled => |s| std.fmt.bufPrint(buf, "signal:{d}", .{s}),
            .failed => std.fmt.bufPrint(buf, "failed", .{}),
        }) catch "failed";
    }
};

/// Clock, sleep, randomness and the service execution, replaceable in tests.
pub const Hooks = struct {
    ptr: ?*anyopaque = null,
    now_us: *const fn (ptr: ?*anyopaque) i64 = realNow,
    sleep_us: *const fn (ptr: ?*anyopaque, ctx: *core.Context, us: u64) void = realSleep,
    random: *const fn (ptr: ?*anyopaque, ctx: *core.Context) u64 = realRandom,
    execute: *const fn (ptr: ?*anyopaque, ctx: *core.Context, service: []const u8) Outcome = realExecute,
};

fn realNow(_: ?*anyopaque) i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.us_per_s + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn realSleep(_: ?*anyopaque, ctx: *core.Context, us: u64) void {
    ctx.io.sleep(.fromNanoseconds(@intCast(@min(us, std.math.maxInt(i64) / 1000) * 1000)), .awake) catch |e| {
        ctx.diag.warn("sleep interrupted: {t}", .{e});
    };
}

fn realRandom(_: ?*anyopaque, ctx: *core.Context) u64 {
    var bytes: [8]u8 = undefined;
    ctx.io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

var forward_child: std.atomic.Value(i32) = .init(0);

fn onSignal(sig: linux.SIG) callconv(.c) void {
    const pid = forward_child.load(.seq_cst);
    if (pid > 0) _ = linux.kill(pid, sig);
}

fn installHandlers() void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &action, null);
}

/// Numeric ids of an account that only the system libc resolves, for the executor to switch to. A
/// unit that cannot be loaded is left to the executor, which reports it.
fn identityOf(ctx: *core.Context, service: []const u8) error{NotResolved}!?identity.Switch {
    const loaded = executor.loadUnit(ctx, service) catch return null;
    const db = accounts.Db.load(ctx.gpa, ctx.fs.*) catch return null;
    return numeric.lookup(ctx, db, loaded) catch |e| switch (e) {
        error.OutOfMemory => return error.NotResolved,
        error.NotResolved => {
            ctx.diag.err("{s}: User= is not in /etc/passwd and the system libc does not resolve it; refusing to run the service as root", .{service});
            return error.NotResolved;
        },
    };
}

/// Forks the executor with its output on a pipe read by the unit's logger; waits for the exit.
fn realExecute(_: ?*anyopaque, ctx: *core.Context, service: []const u8) Outcome {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        ctx.diag.err("{s}: cannot create a pipe", .{service});
        return .failed;
    }
    const ids = identityOf(ctx, service) catch return .{ .exited = 217 };
    installHandlers();
    switch (sys.fork()) {
        .failed => |e| {
            ctx.diag.err("{s}: cannot fork: {t}", .{ service, e });
            sys.closeFd(fds[0]);
            sys.closeFd(fds[1]);
            return .failed;
        },
        .child => {
            const null_fd: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0));
            _ = linux.dup3(null_fd, 0, 0);
            _ = linux.dup3(fds[1], 1, 0);
            _ = linux.dup3(fds[1], 2, 0);
            sys.exitNow(executor.run(ctx, .{ .unit = service, .identity = ids }));
        },
        .parent => |pid| {
            forward_child.store(pid, .seq_cst);
            sys.closeFd(fds[1]);
            _ = logger.run(ctx, ctx.gpa, service, .{}, fds[0]);
            sys.closeFd(fds[0]);
            const exit = sys.waitPid(pid);
            forward_child.store(0, .seq_cst);
            const e = exit orelse return .failed;
            return switch (e) {
                .exited => |c| .{ .exited = c },
                .signaled => |s| .{ .signaled = s },
            };
        },
    }
}

fn micros(secs: i64) i64 {
    return secs * std.time.us_per_s;
}

fn machineId(ctx: *core.Context) ?[]const u8 {
    const content = ctx.fs.readFileAlloc(ctx.gpa, "/etc/machine-id", 256) catch return null;
    return std.mem.trim(u8, content, " \t\r\n");
}

/// Sleep before the run: `RandomizedDelaySec=` of the timer, capped by the delay passed on the command line.
fn randomDelay(ctx: *core.Context, opts: Options, loaded: ?timer_unit.Loaded, hooks: Hooks) u64 {
    if (opts.random_delay_us == 0) return 0;
    var timer: unit.model.Timer = .{ .randomized_delay_sec = opts.random_delay_us };
    if (loaded) |l| timer.fixed_random_delay = l.unit.timer.fixed_random_delay;
    return schedule.randomDelayFor(timer, opts.timer, machineId(ctx), ctx.uid, ctx.scope == .system, hooks.random(hooks.ptr, ctx));
}

/// Records the trigger time, then the result and the next elapse, in the timer entry.
fn record(ctx: *core.Context, store: Store, timer: []const u8, start_us: i64, outcome: ?Outcome, next_us: ?i64) void {
    var txn = store.begin(true) catch |e| {
        if (e != error.NoIndex) ctx.diag.warn("{s}: cannot update the index: {t}", .{ timer, e });
        return;
    };
    const entry = txn.idx.findTimer(timer) orelse {
        txn.release();
        return;
    };
    entry.last_trigger = @divFloor(start_us, std.time.us_per_s);
    if (outcome) |o| {
        var buf: [32]u8 = undefined;
        entry.last_result = ctx.gpa.dupe(u8, o.text(&buf)) catch null;
    }
    if (next_us) |n| {
        if (!std.mem.eql(u8, entry.scheduler, "builtin")) entry.next_trigger = @divFloor(n, std.time.us_per_s);
    }
    txn.commit() catch |e| ctx.diag.warn("{s}: cannot write the index: {t}", .{ timer, e });
}

/// Next elapse after a run that started at `start_us` and ended at `end_us`.
fn nextAfter(ctx: *core.Context, loaded: timer_unit.Loaded, start_us: i64, end_us: i64) ?i64 {
    var zones: timer_unit.ZoneCache = .init(ctx);
    const state: schedule.State = .{
        .last_trigger_usec = start_us,
        .last_activation_usec = start_us,
        .last_deactivation_usec = end_us,
        .boot_realtime_usec = start_us,
        .startup_realtime_usec = start_us,
        .timer_activated_usec = start_us,
    };
    return timer_unit.nextElapse(loaded, state, zones.zones(), end_us);
}

/// Runs the job and returns the exit status of the service (0 when the run was skipped).
pub fn run(ctx: *core.Context, store: Store, opts: Options, hooks: Hooks) u8 {
    var lock = (store.tryJobLock(opts.service) catch |e| {
        ctx.diag.err("{s}: cannot take the job lock: {t}", .{ opts.service, e });
        return 1;
    }) orelse {
        ctx.diag.info("{s}: the previous run is still active, skipping {s}", .{ opts.service, opts.timer });
        return 0;
    };
    defer lock.release();

    const loaded: ?timer_unit.Loaded = timer_unit.load(ctx, opts.timer) catch null;
    const delay = randomDelay(ctx, opts, loaded, hooks);
    if (delay > 0) hooks.sleep_us(hooks.ptr, ctx, delay);

    const start = hooks.now_us(hooks.ptr);
    record(ctx, store, opts.timer, start, null, null);
    const outcome = hooks.execute(hooks.ptr, ctx, opts.service);
    const end = hooks.now_us(hooks.ptr);
    const next = if (loaded) |l| nextAfter(ctx, l, start, end) else null;
    record(ctx, store, opts.timer, start, outcome, next);
    return outcome.exitCode();
}

test "outcome texts and exit codes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("success", (Outcome{ .exited = 0 }).text(&buf));
    try std.testing.expectEqualStrings("exit-code:3", (Outcome{ .exited = 3 }).text(&buf));
    try std.testing.expectEqualStrings("signal:9", (Outcome{ .signaled = 9 }).text(&buf));
    try std.testing.expectEqualStrings("failed", (Outcome{ .failed = {} }).text(&buf));
    try std.testing.expectEqual(@as(u8, 137), (Outcome{ .signaled = 9 }).exitCode());
    try std.testing.expectEqual(@as(u8, 3), (Outcome{ .exited = 3 }).exitCode());
}
