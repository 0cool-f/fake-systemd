// SPDX-License-Identifier: GPL-3.0-or-later
//! Loading of a `.timer` unit for the runtime: its model, parsed calendars, the unit it
//! triggers and the source hashes recorded in the index.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const index_pkg = @import("../index/root.zig");
const executor = @import("../exec/executor.zig");
const tz_mod = @import("../exec/tz.zig");
const calendar = @import("calendar.zig");
const schedule = @import("schedule.zig");

const model = unit.model;

pub const Loaded = struct {
    /// Full timer name, `foo.timer`.
    name: []const u8,
    unit: model.Unit,
    specs: []const calendar.Spec,
    /// Full name of the unit the timer starts.
    service: []const u8,
    src_hash: u64,
    src_stat: u64,
    fragment_path: []const u8,

    pub fn timer(l: Loaded) model.Timer {
        return l.unit.timer;
    }

    /// True when the timer has at least one trigger directive.
    pub fn hasTrigger(l: Loaded) bool {
        const t = l.unit.timer;
        return l.specs.len + t.on_boot_sec.len + t.on_startup_sec.len + t.on_active_sec.len +
            t.on_unit_active_sec.len + t.on_unit_inactive_sec.len > 0;
    }
};

pub const Error = error{ NotFound, Masked, NotATimer, InvalidCalendar, Unreadable } || Allocator.Error;

/// Name of the unit a timer starts: `Unit=`, else the service with the timer's name.
pub fn serviceName(gpa: Allocator, name: unit.name.Name, timer: model.Timer) Allocator.Error![]const u8 {
    if (timer.unit) |u| return u;
    return std.fmt.allocPrint(gpa, "{s}.service", .{name.base()});
}

/// Loads `timer_name` in the scope of `ctx`. A calendar that does not parse is reported
/// through `ctx.diag` and fails the load.
pub fn load(ctx: *core.Context, timer_name: []const u8) Error!Loaded {
    const gpa = ctx.gpa;
    const name = unit.name.parse(gpa, timer_name) catch return error.NotATimer;
    if (name.kind != .timer) return error.NotATimer;
    const resolved = unit.resolve.resolve(gpa, ctx.fs.*, .{ .scope = ctx.scope, .xdg_config_home = ctx.xdg_config_home }, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    switch (resolved.state) {
        .not_found => return error.NotFound,
        .masked => return error.Masked,
        .found => {},
    }
    const u = unit.model.load(gpa, ctx.fs.*, resolved, .{ .env = try executor.specifierEnv(ctx) }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    var specs: std.ArrayList(calendar.Spec) = .empty;
    for (u.timer.on_calendar) |text| {
        const spec = calendar.parse(gpa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCalendar => {
                ctx.diag.err("{s}: invalid OnCalendar= '{s}'", .{ timer_name, text });
                return error.InvalidCalendar;
            },
        };
        try specs.append(gpa, spec);
    }
    const paths = try gpa.alloc([]const u8, resolved.files.len);
    for (resolved.files, paths) |f, *p| p.* = f.path;
    return .{
        .name = name.full,
        .unit = u,
        .specs = specs.items,
        .service = try serviceName(gpa, name, u.timer),
        .src_hash = index_pkg.hash.unitSetHash(ctx.fs.*, gpa, paths) catch return error.Unreadable,
        .src_stat = index_pkg.hash.statFingerprint(ctx.fs.*, paths, resolved.dropin_dirs, &.{}),
        .fragment_path = resolved.fragment.?.path,
    };
}

/// Zone lookup for calendars that name their zone; unknown names yield null.
pub const ZoneCache = struct {
    ctx: *core.Context,
    local: tz_mod.Tz,
    named: std.StringHashMapUnmanaged(?tz_mod.Tz) = .empty,

    pub fn init(ctx: *core.Context) ZoneCache {
        return .{ .ctx = ctx, .local = tz_mod.loadLocal(ctx.gpa, ctx.fs.*, ctx.environ) };
    }

    fn lookup(context: ?*anyopaque, name: []const u8) ?*const tz_mod.Tz {
        const c: *ZoneCache = @ptrCast(@alignCast(context.?));
        const slot = c.named.getOrPut(c.ctx.gpa, name) catch return null;
        if (!slot.found_existing) slot.value_ptr.* = tz_mod.loadNamed(c.ctx.gpa, c.ctx.fs.*, name);
        return if (slot.value_ptr.*) |*tz| tz else null;
    }

    pub fn zones(c: *ZoneCache) schedule.Zones {
        return .{ .local = &c.local, .context = c, .lookup = lookup };
    }
};

/// Next elapse of `loaded` without randomization, in Unix microseconds.
pub fn nextElapse(loaded: Loaded, state: schedule.State, zones: schedule.Zones, now_usec: i64) ?i64 {
    return schedule.nextElapseZones(loaded.unit.timer, loaded.specs, state, zones, now_usec);
}
