// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from systemd src/core/timer.c (LGPL-2.1-or-later), copyright the systemd authors.
//! Next-elapse arithmetic for `.timer` units, following systemd's `timer_enter_waiting`: which
//! reference time each directive counts from, when a directive stops firing, `Persistent=`
//! catch-up and the `RandomizedDelaySec=` offset. All instants are Unix microseconds on the
//! realtime clock; the caller maps boot and startup times onto it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../unit/model.zig");
const calendar = @import("calendar.zig");
const tz_mod = @import("../exec/tz.zig");
const Tz = tz_mod.Tz;

/// What the runner knows about a timer and its service.
pub const State = struct {
    /// Last time this timer triggered its service, or the `Persistent=` stamp loaded at activation.
    last_trigger_usec: ?i64 = null,
    /// Last time the service became active.
    last_activation_usec: ?i64 = null,
    /// Last time the service became inactive.
    last_deactivation_usec: ?i64 = null,
    /// Reference of `OnBootSec=`: boot, or runner start where the host boot time is not ours.
    boot_realtime_usec: i64,
    /// Reference of `OnStartupSec=`; also the earliest instant a calendar elapse can take.
    startup_realtime_usec: i64,
    /// When the timer was activated; reference of `OnActiveSec=` and the first calendar base.
    timer_activated_usec: i64,
    /// `last_trigger_usec` comes from the `Persistent=` stamp, which does not count as a
    /// trigger for `OnUnitActiveSec=` and `OnUnitInactiveSec=`.
    last_trigger_persisted: bool = false,
};

/// Zone lookup for calendar expressions: `local` serves specs that name no zone.
pub const Zones = struct {
    local: *const Tz,
    context: ?*anyopaque = null,
    /// Returns the zone with the given name, or null when unknown (the spec is then ignored).
    lookup: ?*const fn (context: ?*anyopaque, name: []const u8) ?*const Tz = null,

    fn forSpec(z: Zones, spec: calendar.Spec) ?*const Tz {
        const name = spec.timezone orelse return z.local;
        const f = z.lookup orelse return z.local;
        return f(z.context, name);
    }
};

/// Earliest next elapse over all directives, without the randomized delay; null when the timer
/// has nothing left to fire. `tz` serves every calendar spec; use `nextElapseZones` when specs
/// name different zones.
pub fn nextElapse(
    gpa: Allocator,
    timer: model.Timer,
    specs: []const calendar.Spec,
    state: State,
    tz: *const Tz,
    now_usec: i64,
) ?i64 {
    _ = gpa;
    return nextElapseZones(timer, specs, state, .{ .local = tz }, now_usec);
}

pub fn nextElapseZones(
    timer: model.Timer,
    specs: []const calendar.Spec,
    state: State,
    zones: Zones,
    now_usec: i64,
) ?i64 {
    var best: ?i64 = null;

    for (specs) |spec| {
        const zone = zones.forSpec(spec) orelse continue;
        const base = state.last_trigger_usec orelse state.timer_activated_usec;
        const raw = calendar.next(spec, zone, base) orelse continue;
        consider(&best, @max(raw, state.startup_realtime_usec));
    }

    const triggered = state.last_trigger_usec != null;
    one_shot: for ([_]struct { values: []const u64, base: i64 }{
        .{ .values = timer.on_boot_sec, .base = state.boot_realtime_usec },
        .{ .values = timer.on_startup_sec, .base = state.startup_realtime_usec },
        .{ .values = timer.on_active_sec, .base = state.timer_activated_usec },
    }) |group| {
        for (group.values) |v| {
            const at = add(group.base, v) orelse continue :one_shot;
            if (triggered and at < now_usec) continue;
            consider(&best, at);
        }
    }

    const stamp_trigger = if (state.last_trigger_persisted) null else state.last_trigger_usec;
    if (referenceTime(state.last_activation_usec, stamp_trigger)) |base| {
        for (timer.on_unit_active_sec) |v| {
            if (add(base, v)) |at| consider(&best, at);
        }
    }
    if (referenceTime(state.last_deactivation_usec, stamp_trigger)) |base| {
        for (timer.on_unit_inactive_sec) |v| {
            if (add(base, v)) |at| consider(&best, at);
        }
    }
    return best;
}

fn consider(best: *?i64, at: i64) void {
    if (best.* == null or at < best.*.?) best.* = at;
}

/// The later of two optional instants, null when neither has happened.
fn referenceTime(a: ?i64, b: ?i64) ?i64 {
    const x = a orelse 0;
    const y = b orelse 0;
    const m = @max(x, y);
    return if (m <= 0) null else m;
}

/// `base + usec`, null when the sum is infinite or does not fit.
fn add(base: i64, usec: u64) ?i64 {
    if (usec > std.math.maxInt(i64)) return null;
    return std.math.add(i64, base, @intCast(usec)) catch null;
}

/// True when `Persistent=` applies and a calendar elapse fell between the last trigger and
/// `now_usec`, so the service is owed one run at activation.
pub fn missedWhileDown(
    timer: model.Timer,
    specs: []const calendar.Spec,
    state: State,
    tz: *const Tz,
    now_usec: i64,
) bool {
    return missedWhileDownZones(timer, specs, state, .{ .local = tz }, now_usec);
}

pub fn missedWhileDownZones(
    timer: model.Timer,
    specs: []const calendar.Spec,
    state: State,
    zones: Zones,
    now_usec: i64,
) bool {
    if (!timer.persistent) return false;
    const last = state.last_trigger_usec orelse return false;
    for (specs) |spec| {
        const zone = zones.forSpec(spec) orelse continue;
        const at = calendar.next(spec, zone, last) orelse continue;
        if (at <= now_usec) return true;
    }
    return false;
}

const siphash_key = [16]u8{ 0x51, 0x0a, 0xdb, 0x76, 0x29, 0x51, 0x42, 0xc2, 0x80, 0x35, 0xea, 0xe6, 0x8e, 0x3a, 0x37, 0xbd };

/// `RandomizedDelaySec=` offset in microseconds for a system-scope timer owned by root.
pub fn randomDelay(timer: model.Timer, unit_name: []const u8, machine_id: ?[]const u8, rng_seed: u64) u64 {
    return randomDelayFor(timer, unit_name, machine_id, 0, true, rng_seed);
}

/// `RandomizedDelaySec=` offset: `rng_seed` modulo the span, or with `FixedRandomDelay=` a
/// stable hash of machine id, scope, uid and unit name (as systemd computes it). `machine_id`
/// is the 32 hex digits of `/etc/machine-id`; anything else counts as the null id.
pub fn randomDelayFor(
    timer: model.Timer,
    unit_name: []const u8,
    machine_id: ?[]const u8,
    uid: u32,
    is_system: bool,
    rng_seed: u64,
) u64 {
    const span = timer.randomized_delay_sec orelse return 0;
    if (span == 0 or span == std.math.maxInt(u64)) return 0;
    if (!timer.fixed_random_delay) return rng_seed % span;

    var id: [16]u8 = @splat(0);
    if (machine_id) |text| {
        if (text.len == 32) {
            if (std.fmt.hexToBytes(&id, text)) |_| {} else |_| id = @splat(0);
        }
    }
    var h = std.crypto.auth.siphash.SipHash64(2, 4).init(&siphash_key);
    h.update(&id);
    h.update(&.{@intFromBool(is_system)});
    var uid_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &uid_bytes, uid, .little);
    h.update(&uid_bytes);
    h.update(unit_name);
    var out: [8]u8 = undefined;
    h.final(&out);
    return std.mem.readInt(u64, &out, .little) % span;
}

/// The elapse with its randomized delay applied; infinite results stay unchanged.
pub fn withDelay(at: i64, delay_usec: u64) i64 {
    return add(at, delay_usec) orelse std.math.maxInt(i64) - 1;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const sec: u64 = 1_000_000;
const min: u64 = 60 * sec;

const base_state: State = .{
    .boot_realtime_usec = 1_000 * 1_000_000,
    .startup_realtime_usec = 1_100 * 1_000_000,
    .timer_activated_usec = 1_200 * 1_000_000,
};

fn elapse(timer: model.Timer, st: State, now: i64) ?i64 {
    return nextElapse(testing.allocator, timer, &.{}, st, &Tz.utc, now);
}

test "OnBootSec counts from boot, OnStartupSec from startup, OnActiveSec from activation" {
    const boot = elapse(.{ .on_boot_sec = &.{5 * min} }, base_state, 1_300 * 1_000_000);
    try testing.expectEqual(@as(?i64, 1_000 * 1_000_000 + 5 * 60 * 1_000_000), boot);
    const startup = elapse(.{ .on_startup_sec = &.{10 * sec} }, base_state, 1_300 * 1_000_000);
    try testing.expectEqual(@as(?i64, 1_110 * 1_000_000), startup);
    const active = elapse(.{ .on_active_sec = &.{30 * sec} }, base_state, 1_300 * 1_000_000);
    try testing.expectEqual(@as(?i64, 1_230 * 1_000_000), active);
}

test "one-shot directives stop once the timer has triggered" {
    var st = base_state;
    st.last_trigger_usec = 1_250 * 1_000_000;
    const timer: model.Timer = .{ .on_boot_sec = &.{60 * sec}, .on_active_sec = &.{30 * sec} };
    try testing.expectEqual(@as(?i64, null), elapse(timer, st, 1_300 * 1_000_000));
    // Not yet past: still pending.
    try testing.expectEqual(@as(?i64, 1_230 * 1_000_000), elapse(.{ .on_active_sec = &.{30 * sec} }, st, 1_220 * 1_000_000));
}

test "OnUnitActiveSec and OnUnitInactiveSec wait for the reference event" {
    const active: model.Timer = .{ .on_unit_active_sec = &.{60 * sec} };
    const inactive: model.Timer = .{ .on_unit_inactive_sec = &.{60 * sec} };
    try testing.expectEqual(@as(?i64, null), elapse(active, base_state, 2_000 * 1_000_000));
    try testing.expectEqual(@as(?i64, null), elapse(inactive, base_state, 2_000 * 1_000_000));

    var st = base_state;
    st.last_activation_usec = 1_500 * 1_000_000;
    st.last_deactivation_usec = 1_520 * 1_000_000;
    try testing.expectEqual(@as(?i64, 1_560 * 1_000_000), elapse(active, st, 2_000 * 1_000_000));
    try testing.expectEqual(@as(?i64, 1_580 * 1_000_000), elapse(inactive, st, 2_000 * 1_000_000));

    // A trigger later than the activation moves the reference.
    st.last_trigger_usec = 1_600 * 1_000_000;
    try testing.expectEqual(@as(?i64, 1_660 * 1_000_000), elapse(active, st, 2_000 * 1_000_000));
    // A persistence stamp is not a trigger for unit-relative directives.
    st.last_trigger_persisted = true;
    try testing.expectEqual(@as(?i64, 1_560 * 1_000_000), elapse(active, st, 2_000 * 1_000_000));
}

test "the earliest directive wins and infinity is ignored" {
    const timer: model.Timer = .{
        .on_boot_sec = &.{ 10 * min, std.math.maxInt(u64) },
        .on_active_sec = &.{5 * min},
    };
    try testing.expectEqual(@as(?i64, 1_200 * 1_000_000 + 5 * 60 * 1_000_000), elapse(timer, base_state, 1_300 * 1_000_000));
}

const rome_fat = @embedFile("../exec/testdata/rome_fat.tzif");

test "calendar elapses count from the last trigger or activation and not before startup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rome = try Tz.parse(arena.allocator(), rome_fat);
    var spec = try calendar.parse(testing.allocator, "*-*-* 12:00:00");
    defer spec.deinit(testing.allocator);

    const day: i64 = 86_400 * 1_000_000;
    // 2026-03-28 00:00 UTC
    const t0: i64 = 1774656000 * 1_000_000;
    var st: State = .{ .boot_realtime_usec = t0, .startup_realtime_usec = t0, .timer_activated_usec = t0 + 3_600_000_000 };
    const specs = [_]calendar.Spec{spec};
    const first = nextElapse(testing.allocator, .{}, &specs, st, &rome, t0).?;
    try testing.expectEqual(t0 + 11 * 3_600_000_000, first);

    st.last_trigger_usec = first;
    const second = nextElapse(testing.allocator, .{}, &specs, st, &rome, first).?;
    // Rome springs forward on 2026-03-29, so that day is one hour shorter.
    try testing.expectEqual(first + day - 3_600_000_000, second);

    // A calendar time before the runner started is moved to the startup time.
    st.last_trigger_usec = null;
    st.startup_realtime_usec = first + 3_600_000_000;
    st.timer_activated_usec = t0;
    try testing.expectEqual(st.startup_realtime_usec, nextElapse(testing.allocator, .{}, &specs, st, &rome, first).?);
}

test "Persistent= reports an elapse missed while down" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var spec = try calendar.parse(testing.allocator, "daily UTC");
    defer spec.deinit(testing.allocator);
    const specs = [_]calendar.Spec{spec};
    const last: i64 = 1774700000 * 1_000_000;
    var st = base_state;
    st.last_trigger_usec = last;
    const timer: model.Timer = .{ .persistent = true };
    try testing.expect(missedWhileDown(timer, &specs, st, &Tz.utc, last + 3 * 86_400 * 1_000_000));
    try testing.expect(!missedWhileDown(timer, &specs, st, &Tz.utc, last + 3_600 * 1_000_000));
    try testing.expect(!missedWhileDown(.{}, &specs, st, &Tz.utc, last + 3 * 86_400 * 1_000_000));
    st.last_trigger_usec = null;
    try testing.expect(!missedWhileDown(timer, &specs, st, &Tz.utc, last + 3 * 86_400 * 1_000_000));
}

test "randomized delay is bounded and the fixed one is stable" {
    const span: u64 = 600 * sec;
    const timer: model.Timer = .{ .randomized_delay_sec = span };
    try testing.expectEqual(@as(u64, 0), randomDelay(.{}, "a.timer", null, 12345));
    try testing.expectEqual(@as(u64, 12345), randomDelay(timer, "a.timer", null, 12345));
    try testing.expect(randomDelay(timer, "a.timer", null, std.math.maxInt(u64)) < span);

    const fixed: model.Timer = .{ .randomized_delay_sec = span, .fixed_random_delay = true };
    const id = "0123456789abcdef0123456789abcdef";
    const a = randomDelay(fixed, "a.timer", id, 1);
    try testing.expect(a < span);
    try testing.expectEqual(a, randomDelay(fixed, "a.timer", id, 999));
    try testing.expect(a != randomDelay(fixed, "b.timer", id, 1));
    try testing.expect(a != randomDelay(fixed, "a.timer", "fedcba9876543210fedcba9876543210", 1));
    try testing.expect(a != randomDelayFor(fixed, "a.timer", id, 1000, false, 1));
}

test "withDelay saturates" {
    try testing.expectEqual(@as(i64, 150), withDelay(100, 50));
    try testing.expectEqual(std.math.maxInt(i64) - 1, withDelay(std.math.maxInt(i64) - 5, 50));
}
