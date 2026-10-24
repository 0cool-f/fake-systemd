// SPDX-License-Identifier: GPL-3.0-or-later
//! `.timer` units in the verbs (§10): enable, disable, start and stop arm and disarm a timer in
//! the index; each timer is assigned to a native cron-like scheduler or to the built-in runner,
//! whose own service is translated through the normal pipeline while a timer needs it.
//! The state of a timer lives only in the index, so it reads the same under every scheduler.
const std = @import("std");
const Io = std.Io;
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const index_pkg = @import("../index/root.zig");
const reconcile = @import("../reconcile/root.zig");
const backend_pkg = @import("../backend/root.zig");
const tz_mod = @import("../exec/tz.zig");
const timers = @import("../timers/root.zig");
const rt = @import("../timers/runtime.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const lifecycle = @import("lifecycle.zig");

const Index = index_pkg.Index;
const Name = unit.name.Name;
const Exit = cli.output.Exit;
const adapters = rt.adapters;
const timer_unit = rt.timer_unit;

/// Scheduler assigned to a timer.
const Choice = union(enum) {
    builtin,
    cron: struct { kind: adapters.Kind, entries: []const timers.cron.Entry },

    fn text(c: Choice) []const u8 {
        return switch (c) {
            .builtin => rt.runner.builtin_scheduler,
            .cron => |k| k.kind.schedulerName(),
        };
    }
};

fn target(s: *Session) adapters.Target {
    return .{ .ctx = s.ctx, .backend = s.deps.backend, .runner = s.runner() };
}

fn nativeScheduler(s: *Session) ?adapters.Kind {
    if (s.timer_adapter) |c| return c.kind;
    const kind = if (s.ctx.scope == .system) adapters.detect(target(s)) else null;
    s.timer_adapter = .{ .kind = kind };
    return kind;
}

/// Entries of the native scheduler `kind` for `loaded`, or null when it cannot run the timer exactly.
fn exactEntries(s: *Session, loaded: timer_unit.Loaded, kind: adapters.Kind) ?[]const timers.cron.Entry {
    if (loaded.unit.timer.persistent and !kind.catchUp()) return null;
    return timers.cron.translate(s.ctx.gpa, loaded.unit.timer, loaded.specs);
}

/// §10.1: native when the timer is exactly translatable, else built-in; `Scheduler=` forces one.
fn choose(s: *Session, loaded: timer_unit.Loaded) !Choice {
    if (s.ctx.scope == .user) return .builtin;
    const mode = s.ctx.config.timers_scheduler;
    if (mode == .builtin) return .builtin;
    const kind = nativeScheduler(s) orelse {
        if (mode == .native) {
            s.ctx.diag.err("{s}: Scheduler=native, but no cron-like scheduler is installed and enabled", .{loaded.name});
            return error.Refused;
        }
        return .builtin;
    };
    if (exactEntries(s, loaded, kind)) |entries| return .{ .cron = .{ .kind = kind, .entries = entries } };
    if (mode == .native) {
        s.ctx.diag.err("{s}: Scheduler=native, but the timer cannot be expressed exactly for {s}", .{ loaded.name, kind.text() });
        return error.Refused;
    }
    return .builtin;
}

fn nowTimes() rt.runner.Times {
    return rt.runner.real_clock.now_fn(null);
}

fn secs(us: ?i64) ?i64 {
    return if (us) |v| @divFloor(v, std.time.us_per_s) else null;
}

/// Next elapse of a timer that is being armed now, in Unix microseconds.
fn firstElapse(s: *Session, loaded: timer_unit.Loaded, last_trigger: ?i64) ?i64 {
    const times = nowTimes();
    var zones: timer_unit.ZoneCache = .init(s.ctx);
    const boot = times.real_us - times.boot_us;
    const sched_state: timers.schedule.State = .{
        .last_trigger_usec = if (loaded.unit.timer.persistent) if (last_trigger) |l| l * std.time.us_per_s else null else null,
        .last_trigger_persisted = true,
        .boot_realtime_usec = boot,
        .startup_realtime_usec = if (s.ctx.scope == .system) boot else times.real_us,
        .timer_activated_usec = times.real_us,
    };
    return timer_unit.nextElapse(loaded, sched_state, zones.zones(), times.real_us);
}

fn register(s: *Session, idx: *Index, loaded: timer_unit.Loaded, choice: Choice) !void {
    const existing = idx.findTimer(loaded.name);
    const last = if (existing) |e| e.last_trigger else null;
    try idx.putTimer(s.ctx.gpa, .{
        .name = loaded.name,
        .scheduler = choice.text(),
        .src_hash = loaded.src_hash,
        .src_stat = loaded.src_stat,
        .last_trigger = last,
        .next_trigger = secs(firstElapse(s, loaded, last)),
        .last_result = if (existing) |e| e.last_result else null,
    });
    s.markDirty();
}

fn loadFailed(s: *Session, name: Name, verb: []const u8, e: timer_unit.Error) !u8 {
    switch (e) {
        error.OutOfMemory => return e,
        error.NotFound, error.Masked => try cli.output.writeUnitDoesNotExist(s.err(), verb, name.full),
        error.NotATimer, error.InvalidCalendar => {},
        error.Unreadable => s.ctx.diag.err("{s}: cannot read the unit", .{name.full}),
    }
    return Exit.failure;
}

/// Arms the timer: assigns a scheduler, records it in the index and installs the jobs.
pub fn arm(s: *Session, name: Name) !u8 {
    if (!s.deps.backend.caps().translates) {
        s.reportNoBackend();
        return Exit.failure;
    }
    const loaded = timer_unit.load(s.ctx, name.full) catch |e| return loadFailed(s, name, "enable", e);
    if (!loaded.hasTrigger()) {
        s.ctx.diag.err("{s}: the timer has no OnCalendar=, OnBootSec= or other trigger directive", .{name.full});
        return Exit.failure;
    }
    const choice = choose(s, loaded) catch return Exit.failure;
    if (choice == .builtin and s.ctx.scope == .user and !s.deps.backend.caps().user_services) {
        s.ctx.diag.err("{s}: user timers need the built-in runner, which needs a user service manager that the {s} backend lacks", .{ name.full, s.deps.backend.name() });
        return Exit.failure;
    }
    warnIgnored(s, loaded);
    if (s.ctx.dry_run) {
        try s.out().print("would arm timer {s} on {s}\n", .{ name.full, choice.text() });
        return Exit.success;
    }
    const idx = try s.index(.write);
    try register(s, idx, loaded, choice);
    try applySchedulers(s, idx);
    return Exit.success;
}

/// Disarms the timer and rewrites the scheduler files without it.
pub fn disarm(s: *Session, name: Name) !u8 {
    if (!s.deps.backend.caps().translates) return Exit.success;
    if (s.ctx.dry_run) {
        try s.out().print("would disarm timer {s}\n", .{name.full});
        return Exit.success;
    }
    const idx = try s.index(.write);
    if (!idx.removeTimer(name.full)) {
        s.ctx.diag.info("{s}: the timer is not armed", .{name.full});
        return Exit.success;
    }
    s.markDirty();
    try applySchedulers(s, idx);
    return Exit.success;
}

fn warnIgnored(s: *Session, loaded: timer_unit.Loaded) void {
    for (loaded.unit.issues) |issue| {
        if (std.mem.eql(u8, issue.key, "WakeSystem") or std.mem.eql(u8, issue.key, "OnClockChange") or std.mem.eql(u8, issue.key, "OnTimezoneChange")) {
            s.ctx.diag.warn("{s}: {s}= is ignored", .{ loaded.name, issue.key });
        }
    }
}

/// Writes the native scheduler files for every timer assigned to one, and enables or disables
/// the runner service according to whether a built-in timer is left.
pub fn applySchedulers(s: *Session, idx: *Index) !void {
    const gpa = s.ctx.gpa;
    var placed: std.ArrayList(adapters.Placed) = .empty;
    var builtin_count: usize = 0;
    for (idx.timers.items) |t| {
        const kind = adapters.kindFromScheduler(t.scheduler) orelse {
            builtin_count += 1;
            continue;
        };
        const loaded = timer_unit.load(s.ctx, t.name) catch continue;
        const entries = exactEntries(s, loaded, kind) orelse {
            s.ctx.diag.warn("{s}: no longer expressible for {s}, left out", .{ t.name, kind.text() });
            continue;
        };
        const delay = loaded.unit.timer.randomized_delay_sec orelse 0;
        try placed.append(gpa, .{ .kind = kind, .job = .{
            .timer = t.name,
            .service = loaded.service,
            .entries = entries,
            .random_delay_us = if (delay == std.math.maxInt(u64)) 0 else delay,
            .persistent = loaded.unit.timer.persistent,
        } });
    }
    adapters.sync(target(s), placed.items) catch |e| s.ctx.diag.warn("cannot install the native scheduler jobs: {t}", .{e});
    try ensureRunner(s, builtin_count > 0);
}

fn runnerPath(s: *Session) ![]const u8 {
    const dir = try lifecycle.adminDir(s, false);
    return std.fs.path.join(s.ctx.gpa, &.{ dir, rt.embedded.runner_unit });
}

/// Installs, enables and starts the runner service, or removes it again.
fn ensureRunner(s: *Session, want: bool) !void {
    const gpa = s.ctx.gpa;
    const path = try runnerPath(s);
    const name = try unit.name.parse(gpa, rt.embedded.runner_unit);
    const existing: ?[]const u8 = s.ctx.fs.readFileAlloc(gpa, path, 1 << 16) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (existing) |content| {
        if (!rt.embedded.isOwned(content)) {
            if (want) s.ctx.diag.warn("{s} is not owned by fake-systemd, using it as the runner unit", .{path});
            return;
        }
    }
    if (s.ctx.dry_run) return s.ctx.diag.info("would {s} {s}", .{ if (want) "install" else "remove", path });
    if (want) {
        const text = rt.embedded.unitText(s.ctx.scope);
        if (existing == null or !std.mem.eql(u8, existing.?, text)) {
            try s.ctx.fs.makePath(std.fs.path.dirname(path).?);
            try s.ctx.fs.writeFileAtomic(path, text, 0o644);
        }
        const was_active = runnerActive(s);
        var visited: lifecycle.Visited = .empty;
        if (try lifecycle.enableUnit(s, name, &visited, 0) != 0) return;
        if (s.ctx.offline) return;
        const service = (try pipeline.prepare(s, name)).service() orelse return;
        const result = if (was_active) s.deps.backend.kill(s.env(), service, "HUP") else s.deps.backend.start(s.env(), service);
        result catch |e| {
            _ = s.backendFailed(if (was_active) "signal" else "start", name.full, e);
        };
    } else if (existing != null) {
        const service = (try pipeline.prepare(s, name)).service();
        if (service != null and !s.ctx.offline and runnerActive(s)) {
            s.deps.backend.stop(s.env(), service.?) catch |e| {
                _ = s.backendFailed("stop", name.full, e);
            };
        }
        _ = try lifecycle.disableUnit(s, name);
        try lifecycle.revertGenerated(s, name);
        try s.ctx.fs.deleteFile(path);
    }
}

fn runnerService(s: *Session) ?[]const u8 {
    const name = unit.name.parse(s.ctx.gpa, rt.embedded.runner_unit) catch return null;
    const plan = pipeline.prepare(s, name) catch return null;
    return plan.service();
}

fn runnerActive(s: *Session) bool {
    if (s.ctx.offline) return false;
    const service = runnerService(s) orelse return false;
    const st = s.deps.backend.status(s.env(), service) catch return false;
    return st.state == .active or st.state == .activating or st.state == .reloading;
}

/// `daemon-reload`: drops the timers whose unit is gone, assigns schedulers again, rewrites the
/// native scheduler files and tells the runner to read the index.
pub fn reconcileAll(s: *Session) !void {
    if (!s.deps.backend.caps().translates) return;
    const idx = try s.index(.write);
    if (idx.timers.items.len == 0 and !runnerFileExists(s)) return;
    const snapshot = try s.ctx.gpa.dupe(Index.Timer, idx.timers.items);
    for (snapshot) |t| {
        const loaded = timer_unit.load(s.ctx, t.name) catch |e| {
            switch (e) {
                error.NotFound, error.Masked, error.NotATimer => {
                    s.ctx.diag.info("{s}: the timer unit is gone, dropping it", .{t.name});
                    if (!s.ctx.dry_run) _ = idx.removeTimer(t.name);
                    s.markDirty();
                },
                else => {},
            }
            continue;
        };
        const choice = choose(s, loaded) catch continue;
        if (s.ctx.dry_run) continue;
        try register(s, idx, loaded, choice);
    }
    try applySchedulers(s, idx);
}

fn runnerFileExists(s: *Session) bool {
    const path = runnerPath(s) catch return false;
    return s.ctx.fs.exists(path);
}

// ---- queries ----

/// State of a timer unit for the query verbs.
pub const State = struct {
    armed: bool,
    scheduler: []const u8 = "",
    next_us: ?i64 = null,
    last_us: ?i64 = null,
    result: ?[]const u8 = null,
};

pub fn state(s: *Session, name: Name) !State {
    if (!s.deps.backend.caps().translates) return .{ .armed = false };
    const idx = try s.index(.read);
    const t = idx.findTimer(name.full) orelse return .{ .armed = false };
    return .{
        .armed = true,
        .scheduler = t.scheduler,
        .next_us = if (t.next_trigger) |n| n * std.time.us_per_s else null,
        .last_us = if (t.last_trigger) |l| l * std.time.us_per_s else null,
        .result = t.last_result,
    };
}

/// A timer is active when it is armed and something is there to fire it.
pub fn activeState(s: *Session, name: Name) cli.output.ActiveState {
    const st = state(s, name) catch return .inactive;
    if (!st.armed or s.ctx.offline) return .inactive;
    if (adapters.kindFromScheduler(st.scheduler) != null) return .active;
    return if (runnerActive(s)) .active else .inactive;
}

fn writeTimestampText(s: *Session, w: *Io.Writer, tz: tz_mod.Tz, us: i64) !void {
    _ = s;
    try rt.format.timestamp(w, tz, us);
    try w.writeAll("; ");
    try rt.format.relative(w, us, nowTimes().real_us);
}

pub const StatusTexts = struct { trigger: ?[]const u8, last_run: ?[]const u8 };

/// The `Trigger:` and `Last run:` texts of `status`.
pub fn statusTexts(s: *Session, st: State) !StatusTexts {
    const tz = tz_mod.loadLocal(s.ctx.gpa, s.ctx.fs.*, s.ctx.environ);
    var trigger: ?[]const u8 = null;
    var last_run: ?[]const u8 = null;
    if (st.next_us) |n| {
        var aw: Io.Writer.Allocating = .init(s.ctx.gpa);
        try writeTimestampText(s, &aw.writer, tz, n);
        trigger = aw.written();
    }
    if (st.last_us) |l| {
        var aw: Io.Writer.Allocating = .init(s.ctx.gpa);
        try writeTimestampText(s, &aw.writer, tz, l);
        if (st.result) |r| try aw.writer.print(" ({s})", .{r});
        last_run = aw.written();
    }
    return .{ .trigger = trigger, .last_run = last_run };
}

fn rowLess(_: void, a: rt.format.Row, b: rt.format.Row) bool {
    const an = a.next_us orelse std.math.maxInt(i64);
    const bn = b.next_us orelse std.math.maxInt(i64);
    if (an != bn) return an < bn;
    return std.mem.lessThan(u8, a.unit, b.unit);
}

/// `list-timers` (§3.1): the armed timers, sorted by next elapse.
pub fn list(s: *Session) !u8 {
    const gpa = s.ctx.gpa;
    var rows: std.ArrayList(rt.format.Row) = .empty;
    if (s.deps.backend.caps().translates) {
        const idx = try s.index(.read);
        for (idx.timers.items) |t| {
            const name = unit.name.parse(gpa, t.name) catch continue;
            const service = serviceOfEntry(s, name);
            if (t.next_trigger == null and !s.req.options.all) continue;
            try rows.append(gpa, .{
                .next_us = if (t.next_trigger) |n| n * std.time.us_per_s else null,
                .last_us = if (t.last_trigger) |l| l * std.time.us_per_s else null,
                .unit = t.name,
                .activates = service,
            });
        }
    }
    std.mem.sort(rt.format.Row, rows.items, {}, rowLess);
    const tz = tz_mod.loadLocal(gpa, s.ctx.fs.*, s.ctx.environ);
    const o = s.req.options;
    try rt.format.writeTable(s.out(), gpa, tz, nowTimes().real_us, rows.items, .{ .no_legend = o.no_legend, .all = o.all });
    return Exit.success;
}

/// The unit a timer in the index starts; falls back to the name with `.service` when the unit cannot be read.
pub fn serviceOfEntry(s: *Session, name: Name) []const u8 {
    const loaded = timer_unit.load(s.ctx, name.full) catch return std.fmt.allocPrint(s.ctx.gpa, "{s}.service", .{name.base()}) catch "-";
    return loaded.service;
}
