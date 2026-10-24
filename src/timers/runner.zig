// SPDX-License-Identifier: GPL-3.0-or-later
//! The built-in timer runner, `fake-systemd --timers` (§10.3): one process that loads the timers
//! assigned to `builtin` from the index, sleeps until the earliest elapse (at most a minute, so
//! suspend and clock changes are noticed), and starts `--run-job` children.
//!
//! The loop only talks to the world through `Clock`, `Spawner` and `Signals`, so tests drive it
//! with a fake clock and a recording spawner. Elapses are Unix microseconds; boot-relative
//! directives count from `CLOCK_BOOTTIME` mapped onto the realtime clock.
const std = @import("std");
const linux = std.os.linux;
const core = @import("../core/root.zig");
const backend_pkg = @import("../backend/root.zig");
const sys = @import("../exec/sys.zig");
const schedule = @import("schedule.zig");
const timer_unit = @import("timer_unit.zig");
const Store = @import("store.zig");

pub const builtin_scheduler = "builtin";
pub const max_sleep_ms: u64 = 60_000;
const stop_grace_ms: u64 = 10_000;

pub const Options = struct {
    /// Program started for each run.
    exe: []const u8 = backend_pkg.policy.executor_path,
    /// Filesystem root passed on to the jobs (`--root`).
    root: ?[]const u8 = null,
    max_sleep_ms: u64 = max_sleep_ms,
};

pub const Times = struct {
    real_us: i64,
    boot_us: i64,
};

pub const Clock = struct {
    ptr: ?*anyopaque = null,
    now_fn: *const fn (ptr: ?*anyopaque) Times,
    /// Blocks up to `ms` milliseconds; returns early when a signal arrived.
    wait_fn: *const fn (ptr: ?*anyopaque, ms: u64) void,
};

pub const Reaped = struct { pid: i32, exit: sys.Exit };

pub const Spawner = struct {
    ptr: ?*anyopaque = null,
    spawn_fn: *const fn (ptr: ?*anyopaque, argv: []const []const u8) anyerror!i32,
    /// A child that has finished, if any; never blocks.
    reap_fn: *const fn (ptr: ?*anyopaque) ?Reaped,
    signal_fn: *const fn (ptr: ?*anyopaque, pid: i32, sig: linux.SIG) void,
};

pub const Signals = struct {
    ptr: ?*anyopaque = null,
    /// True once after each SIGHUP.
    take_reload_fn: *const fn (ptr: ?*anyopaque) bool,
    terminating_fn: *const fn (ptr: ?*anyopaque) bool,
};

/// A builtin timer as the runner tracks it.
const Entry = struct {
    name: []const u8,
    loaded: timer_unit.Loaded,
    next_us: ?i64 = null,
    /// In-memory trigger time; for `Persistent=` timers it starts from the index.
    last_trigger_us: ?i64 = null,
    persisted: bool = false,
    last_activation_us: ?i64 = null,
    last_deactivation_us: ?i64 = null,
    activated_us: i64,
    pid: ?i32 = null,
    /// Values as written in the index, to avoid rewriting it when nothing changed.
    index_next: ?i64 = null,
    index_last: ?i64 = null,
};

pub const Engine = struct {
    ctx: *core.Context,
    store: Store,
    opts: Options,
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},
    /// Runner start: reference of `OnStartupSec=` in user scope.
    started_us: i64,
    index_dirty: bool = false,

    pub fn init(ctx: *core.Context, store: Store, opts: Options, started_us: i64) Engine {
        return .{ .ctx = ctx, .store = store, .opts = opts, .arena = .init(ctx.gpa), .started_us = started_us };
    }

    pub fn deinit(e: *Engine) void {
        e.arena.deinit();
    }

    fn storeFor(e: *const Engine, ctx: *core.Context) Store {
        var s = e.store;
        s.ctx = ctx;
        return s;
    }

    /// A context whose allocator is `gpa`, for work that must not outlive its arena.
    fn scoped(e: *Engine, gpa: std.mem.Allocator) core.Context {
        var c = e.ctx.*;
        c.gpa = gpa;
        return c;
    }

    fn state(e: *const Engine, entry: Entry, times: Times) schedule.State {
        const boot = times.real_us - times.boot_us;
        return .{
            .last_trigger_usec = entry.last_trigger_us,
            .last_activation_usec = entry.last_activation_us,
            .last_deactivation_usec = entry.last_deactivation_us,
            .boot_realtime_usec = boot,
            .startup_realtime_usec = if (e.ctx.scope == .system) boot else e.started_us,
            .timer_activated_usec = entry.activated_us,
            .last_trigger_persisted = entry.persisted,
        };
    }

    /// Reads the builtin timers from the index and loads their units. Entries that were
    /// tracked before keep their run history. With `catch_up`, a `Persistent=` timer that
    /// missed an elapse while the runner was down fires at once.
    pub fn reload(e: *Engine, times: Times, catch_up: bool, spawner: Spawner) !void {
        var fresh: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        errdefer fresh.deinit();
        var ctx = e.scoped(fresh.allocator());
        const gpa = ctx.gpa;

        var txn = try e.storeFor(&ctx).begin(false);
        errdefer txn.release();
        var list: std.ArrayList(Entry) = .empty;
        for (txn.idx.timers.items) |t| {
            if (!std.mem.eql(u8, t.scheduler, builtin_scheduler)) continue;
            const loaded = timer_unit.load(&ctx, t.name) catch |err| {
                e.ctx.diag.warn("{s}: cannot load the timer: {t}", .{ t.name, err });
                continue;
            };
            var entry: Entry = .{
                .name = try gpa.dupe(u8, t.name),
                .loaded = loaded,
                .activated_us = times.real_us,
                .index_next = t.next_trigger,
                .index_last = t.last_trigger,
            };
            if (e.find(t.name)) |old| {
                entry.activated_us = old.activated_us;
                entry.last_trigger_us = old.last_trigger_us;
                entry.persisted = old.persisted;
                entry.last_activation_us = old.last_activation_us;
                entry.last_deactivation_us = old.last_deactivation_us;
                entry.pid = old.pid;
            } else if (t.last_trigger != null and loaded.unit.timer.persistent) {
                entry.last_trigger_us = t.last_trigger.? * std.time.us_per_s;
                entry.persisted = true;
            }
            try list.append(gpa, entry);
        }
        txn.release();
        var old_arena = e.arena;
        e.arena = fresh;
        e.entries = list.items;
        old_arena.deinit();

        var zone_arena: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        defer zone_arena.deinit();
        var zctx = e.scoped(zone_arena.allocator());
        var zones: timer_unit.ZoneCache = .init(&zctx);
        if (catch_up) {
            for (e.entries) |*entry| {
                const missed = schedule.missedWhileDownZones(entry.loaded.unit.timer, entry.loaded.specs, e.state(entry.*, times), zones.zones(), times.real_us);
                if (missed) e.fire(entry, times, spawner);
            }
        }
        e.recompute(&zones, times);
        try e.writeIndex();
    }

    fn find(e: *Engine, name: []const u8) ?*Entry {
        for (e.entries) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }

    fn recompute(e: *Engine, zones: *timer_unit.ZoneCache, times: Times) void {
        for (e.entries) |*entry| {
            entry.next_us = timer_unit.nextElapse(entry.loaded, e.state(entry.*, times), zones.zones(), times.real_us);
        }
    }

    /// Starts `--run-job` for `entry`, unless a run is still going.
    fn fire(e: *Engine, entry: *Entry, times: Times, spawner: Spawner) void {
        entry.last_trigger_us = times.real_us;
        entry.persisted = false;
        e.index_dirty = true;
        if (entry.pid != null) {
            e.ctx.diag.info("{s}: the previous run is still active, skipping {s}", .{ entry.loaded.service, entry.name });
            return;
        }
        var scratch: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        defer scratch.deinit();
        const gpa = scratch.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(gpa, &.{ e.opts.exe, "--run-job", entry.loaded.service, "--timer", entry.name }) catch return e.oom();
        if (e.ctx.scope == .user) argv.append(gpa, "--user") catch return e.oom();
        if (e.opts.root) |r| argv.appendSlice(gpa, &.{ "--root", r }) catch return e.oom();
        if (entry.loaded.unit.timer.randomized_delay_sec) |d| {
            if (d > 0 and d != std.math.maxInt(u64)) {
                const text = std.fmt.allocPrint(gpa, "{d}", .{d}) catch return e.oom();
                argv.appendSlice(gpa, &.{ "--random-delay", text }) catch return e.oom();
            }
        }
        const pid = spawner.spawn_fn(spawner.ptr, argv.items) catch |err| {
            e.ctx.diag.err("{s}: cannot start the job: {t}", .{ entry.name, err });
            return;
        };
        entry.pid = pid;
        entry.last_activation_us = times.real_us;
    }

    fn oom(e: *Engine) void {
        e.ctx.diag.err("out of memory", .{});
    }

    /// Collects finished jobs.
    pub fn reap(e: *Engine, times: Times, spawner: Spawner) void {
        while (spawner.reap_fn(spawner.ptr)) |r| {
            for (e.entries) |*entry| {
                if (entry.pid != null and entry.pid.? == r.pid) {
                    entry.pid = null;
                    entry.last_deactivation_us = times.real_us;
                }
            }
        }
    }

    /// Fires the timers that are due, then recomputes every elapse from `times`.
    pub fn tick(e: *Engine, times: Times, spawner: Spawner) !void {
        for (e.entries) |*entry| {
            if (entry.next_us) |n| if (n <= times.real_us) e.fire(entry, times, spawner);
        }
        var zone_arena: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        defer zone_arena.deinit();
        var zctx = e.scoped(zone_arena.allocator());
        var zones: timer_unit.ZoneCache = .init(&zctx);
        e.recompute(&zones, times);
        try e.writeIndex();
    }

    /// Milliseconds until the earliest elapse, at most `opts.max_sleep_ms`.
    pub fn waitMs(e: *const Engine, times: Times) u64 {
        var wait: u64 = e.opts.max_sleep_ms;
        for (e.entries) |entry| {
            const n = entry.next_us orelse continue;
            const delta = n - times.real_us;
            const ms: u64 = if (delta <= 0) 0 else @intCast(@divFloor(delta + 999, 1000));
            wait = @min(wait, ms);
        }
        return wait;
    }

    /// Stores the next and last trigger of every entry in the index when they changed.
    fn writeIndex(e: *Engine) !void {
        var changed = e.index_dirty;
        for (e.entries) |entry| {
            if (entry.index_next != secs(entry.next_us) or (entry.last_trigger_us != null and !entry.persisted and entry.index_last != secs(entry.last_trigger_us))) changed = true;
        }
        if (!changed) return;
        var arena: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        defer arena.deinit();
        var ctx = e.scoped(arena.allocator());
        var txn = try e.storeFor(&ctx).begin(true);
        errdefer txn.release();
        for (e.entries) |*entry| {
            const t = txn.idx.findTimer(entry.name) orelse continue;
            t.next_trigger = secs(entry.next_us);
            entry.index_next = t.next_trigger;
            if (entry.last_trigger_us != null and !entry.persisted) {
                t.last_trigger = secs(entry.last_trigger_us);
                entry.index_last = t.last_trigger;
            }
        }
        try txn.commit();
        e.index_dirty = false;
    }

    /// Asks running jobs to stop and waits for them, killing what is left after the grace period.
    pub fn terminate(e: *Engine, clock: Clock, spawner: Spawner) void {
        var running: usize = 0;
        for (e.entries) |entry| if (entry.pid) |pid| {
            spawner.signal_fn(spawner.ptr, pid, .TERM);
            running += 1;
        };
        var waited: u64 = 0;
        while (running > 0 and waited <= stop_grace_ms) : (waited += 100) {
            clock.wait_fn(clock.ptr, 100);
            e.reap(clock.now_fn(clock.ptr), spawner);
            running = 0;
            for (e.entries) |entry| if (entry.pid != null) {
                running += 1;
            };
        }
        for (e.entries) |entry| if (entry.pid) |pid| spawner.signal_fn(spawner.ptr, pid, .KILL);
        e.reap(clock.now_fn(clock.ptr), spawner);
    }
};

fn secs(us: ?i64) ?i64 {
    return if (us) |v| @divFloor(v, std.time.us_per_s) else null;
}

/// Runs until `signals` reports termination; returns the exit status.
pub fn run(ctx: *core.Context, store: Store, opts: Options, clock: Clock, spawner: Spawner, signals: Signals) u8 {
    const start = clock.now_fn(clock.ptr);
    var engine: Engine = .init(ctx, store, opts, start.real_us);
    defer engine.deinit();
    engine.reload(start, true, spawner) catch |err| {
        ctx.diag.err("cannot read the timers: {t}", .{err});
        return 1;
    };
    while (!signals.terminating_fn(signals.ptr)) {
        const now = clock.now_fn(clock.ptr);
        engine.reap(now, spawner);
        if (signals.take_reload_fn(signals.ptr)) {
            engine.reload(now, false, spawner) catch |err| ctx.diag.err("cannot reload the timers: {t}", .{err});
        }
        engine.tick(now, spawner) catch |err| ctx.diag.err("cannot update the index: {t}", .{err});
        clock.wait_fn(clock.ptr, engine.waitMs(now));
    }
    engine.terminate(clock, spawner);
    return 0;
}

// ---- real clock, spawner and signals -------------------------------------------------------

var pipe_fds: [2]i32 = .{ -1, -1 };
var reload_flag: std.atomic.Value(bool) = .init(false);
var term_flag: std.atomic.Value(bool) = .init(false);

fn wakeUp() void {
    if (pipe_fds[1] >= 0) {
        const byte = [1]u8{0};
        _ = linux.write(pipe_fds[1], &byte, 1);
    }
}

fn onSignal(sig: linux.SIG) callconv(.c) void {
    switch (sig) {
        .HUP => reload_flag.store(true, .seq_cst),
        .TERM, .INT => term_flag.store(true, .seq_cst),
        else => {},
    }
    wakeUp();
}

/// Installs the handlers and the wake-up pipe of the real loop.
pub fn installSignals() !void {
    if (linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return error.PipeFailed;
    const action: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    for ([_]linux.SIG{ .HUP, .TERM, .INT, .CHLD }) |sig| _ = linux.sigaction(sig, &action, null);
}

fn realNow(_: ?*anyopaque) Times {
    var real: linux.timespec = undefined;
    var boot: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &real);
    _ = linux.clock_gettime(.BOOTTIME, &boot);
    return .{
        .real_us = @as(i64, real.sec) * std.time.us_per_s + @divTrunc(@as(i64, real.nsec), 1000),
        .boot_us = @as(i64, boot.sec) * std.time.us_per_s + @divTrunc(@as(i64, boot.nsec), 1000),
    };
}

fn realWait(_: ?*anyopaque, ms: u64) void {
    var fds = [1]linux.pollfd{.{ .fd = pipe_fds[0], .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&fds, 1, @intCast(@min(ms, std.math.maxInt(i32))));
    var buf: [64]u8 = undefined;
    while (true) {
        const rc = linux.read(pipe_fds[0], &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
    }
}

pub const real_clock: Clock = .{ .now_fn = realNow, .wait_fn = realWait };

const RealSpawner = struct {
    fn spawn(ptr: ?*anyopaque, argv: []const []const u8) anyerror!i32 {
        const io: *const std.Io = @ptrCast(@alignCast(ptr.?));
        const child = try std.process.spawn(io.*, .{ .argv = argv });
        return child.id orelse error.NoPid;
    }

    fn reap(_: ?*anyopaque) ?Reaped {
        var status: i32 = 0;
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
        return .{ .pid = @intCast(rc), .exit = sys.decodeStatus(@bitCast(status)) };
    }

    fn signal(_: ?*anyopaque, pid: i32, sig: linux.SIG) void {
        sys.kill(pid, sig);
    }
};

pub fn realSpawner(io: *const std.Io) Spawner {
    return .{ .ptr = @constCast(io), .spawn_fn = RealSpawner.spawn, .reap_fn = RealSpawner.reap, .signal_fn = RealSpawner.signal };
}

fn realTakeReload(_: ?*anyopaque) bool {
    return reload_flag.swap(false, .seq_cst);
}

fn realTerminating(_: ?*anyopaque) bool {
    return term_flag.load(.seq_cst);
}

pub const real_signals: Signals = .{ .take_reload_fn = realTakeReload, .terminating_fn = realTerminating };
