// SPDX-License-Identifier: GPL-3.0-or-later
//! Exact translation of `OnCalendar=` timers into five-field cron entries. A timer that cron
//! cannot express without changing when it fires is rejected rather than approximated.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const model = @import("../unit/model.zig");
const calendar = @import("calendar.zig");

pub const Entry = struct {
    minute: []const u8,
    hour: []const u8,
    dom: []const u8,
    month: []const u8,
    dow: []const u8,

    pub fn eql(a: Entry, b: Entry) bool {
        return std.mem.eql(u8, a.minute, b.minute) and std.mem.eql(u8, a.hour, b.hour) and
            std.mem.eql(u8, a.dom, b.dom) and std.mem.eql(u8, a.month, b.month) and
            std.mem.eql(u8, a.dow, b.dow);
    }
};

/// One cron entry per distinct `OnCalendar=` expression. Null when the timer has monotonic
/// directives, no calendar, or any expression has a seconds part, a year, `~`, a zone, a pinned
/// DST state, or restricts both day of month and weekday (cron ORs those two, systemd ANDs them).
/// Also null when memory runs out, which makes the caller fall back to the built-in runner.
pub fn translate(gpa: Allocator, timer: model.Timer, specs: []const calendar.Spec) ?[]Entry {
    return translateAlloc(gpa, timer, specs) catch null;
}

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(gpa, e);
    gpa.free(entries);
}

fn freeEntry(gpa: Allocator, e: Entry) void {
    gpa.free(e.minute);
    gpa.free(e.hour);
    gpa.free(e.dom);
    gpa.free(e.month);
    gpa.free(e.dow);
}

fn translateAlloc(gpa: Allocator, timer: model.Timer, specs: []const calendar.Spec) Allocator.Error!?[]Entry {
    if (specs.len == 0) return null;
    if (timer.on_boot_sec.len != 0 or timer.on_startup_sec.len != 0 or timer.on_active_sec.len != 0 or
        timer.on_unit_active_sec.len != 0 or timer.on_unit_inactive_sec.len != 0) return null;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| freeEntry(gpa, e);
        entries.deinit(gpa);
    }
    for (specs) |spec| {
        const entry = (try translateSpec(gpa, spec)) orelse {
            for (entries.items) |e| freeEntry(gpa, e);
            entries.deinit(gpa);
            return null;
        };
        var duplicate = false;
        for (entries.items) |e| duplicate = duplicate or e.eql(entry);
        if (duplicate) {
            freeEntry(gpa, entry);
            continue;
        }
        entries.append(gpa, entry) catch |err| {
            freeEntry(gpa, entry);
            return err;
        };
    }
    return try entries.toOwnedSlice(gpa);
}

fn translateSpec(gpa: Allocator, spec: calendar.Spec) Allocator.Error!?Entry {
    if (spec.utc or spec.timezone != null or spec.dst != -1) return null;
    if (spec.end_of_month or spec.year.len != 0) return null;
    if (spec.microsecond.len != 1) return null;
    const s = spec.microsecond[0];
    if (s.start != 0 or s.stop != -1 or s.repeat != 0) return null;
    if (spec.day.len != 0 and spec.weekdays_bits >= 0) return null;

    const minute = try field(gpa, spec.minute, 59);
    errdefer gpa.free(minute);
    const hour = try field(gpa, spec.hour, 23);
    errdefer gpa.free(hour);
    const dom = try field(gpa, spec.day, 31);
    errdefer gpa.free(dom);
    const month = try field(gpa, spec.month, 12);
    errdefer gpa.free(month);
    const dow = try weekdays(gpa, spec.weekdays_bits);
    return .{ .minute = minute, .hour = hour, .dom = dom, .month = month, .dow = dow };
}

/// A comma separated cron field; an open-ended repetition runs up to `max`.
fn field(gpa: Allocator, items: []const calendar.Component, max: i32) Allocator.Error![]u8 {
    if (items.len == 0) return gpa.dupe(u8, "*");
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (items, 0..) |c, i| {
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.print("{d}", .{c.start}) catch return error.OutOfMemory;
        if (c.stop >= 0) {
            out.writer.print("-{d}", .{c.stop}) catch return error.OutOfMemory;
            if (c.repeat > 1) out.writer.print("/{d}", .{c.repeat}) catch return error.OutOfMemory;
        } else if (c.repeat > 0) {
            out.writer.print("-{d}/{d}", .{ max, c.repeat }) catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice();
}

/// Weekday field with Monday to Saturday as 1 to 6 and Sunday as 0, never as 7.
fn weekdays(gpa: Allocator, bits: i32) Allocator.Error![]u8 {
    if (bits < 0) return gpa.dupe(u8, "*");
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var first = true;
    var day: u5 = 0;
    while (day < 6) {
        if (bits & (@as(i32, 1) << day) == 0) {
            day += 1;
            continue;
        }
        var end = day;
        while (end + 1 < 6 and bits & (@as(i32, 1) << (end + 1)) != 0) end += 1;
        if (!first) out.writer.writeByte(',') catch return error.OutOfMemory;
        first = false;
        if (end > day) {
            out.writer.print("{d}-{d}", .{ day + 1, end + 1 }) catch return error.OutOfMemory;
        } else {
            out.writer.print("{d}", .{day + 1}) catch return error.OutOfMemory;
        }
        day = end + 1;
    }
    if (bits & (1 << 6) != 0) {
        if (!first) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.writeByte('0') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const Tz = @import("../exec/tz.zig").Tz;

fn expectTranslation(timer: model.Timer, exprs: []const []const u8, expected: []const []const u8) !void {
    const gpa = testing.allocator;
    var specs: std.ArrayList(calendar.Spec) = .empty;
    defer {
        for (specs.items) |*s| s.deinit(gpa);
        specs.deinit(gpa);
    }
    for (exprs) |e| try specs.append(gpa, try calendar.parse(gpa, e));
    const entries = translate(gpa, timer, specs.items) orelse return error.NotTranslated;
    defer freeEntries(gpa, entries);
    try testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |e, want| {
        const got = try std.fmt.allocPrint(gpa, "{s} {s} {s} {s} {s}", .{ e.minute, e.hour, e.dom, e.month, e.dow });
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

fn expectRejected(timer: model.Timer, exprs: []const []const u8) !void {
    const gpa = testing.allocator;
    var specs: std.ArrayList(calendar.Spec) = .empty;
    defer {
        for (specs.items) |*s| s.deinit(gpa);
        specs.deinit(gpa);
    }
    for (exprs) |e| try specs.append(gpa, try calendar.parse(gpa, e));
    try testing.expectEqual(@as(?[]Entry, null), translate(gpa, timer, specs.items));
}

test "translatable calendars" {
    try expectTranslation(.{}, &.{"minutely"}, &.{"* * * * *"});
    try expectTranslation(.{}, &.{"hourly"}, &.{"0 * * * *"});
    try expectTranslation(.{}, &.{"daily"}, &.{"0 0 * * *"});
    try expectTranslation(.{}, &.{"weekly"}, &.{"0 0 * * 1"});
    try expectTranslation(.{}, &.{"monthly"}, &.{"0 0 1 * *"});
    try expectTranslation(.{}, &.{"yearly"}, &.{"0 0 1 1 *"});
    try expectTranslation(.{}, &.{"quarterly"}, &.{"0 0 1 1,4,7,10 *"});
    try expectTranslation(.{}, &.{"*:0/15"}, &.{"0-59/15 * * * *"});
    try expectTranslation(.{}, &.{"*-*-* 8..18:00"}, &.{"0 8-18 * * *"});
    try expectTranslation(.{}, &.{"*-*-* 0..12/4:30"}, &.{"30 0-12/4 * * *"});
    try expectTranslation(.{}, &.{"*-*-* 2/6:05"}, &.{"5 2-23/6 * * *"});
    try expectTranslation(.{}, &.{"Mon..Fri 09:30"}, &.{"30 9 * * 1-5"});
    try expectTranslation(.{}, &.{"Sat,Sun 12:00"}, &.{"0 12 * * 6,0"});
    try expectTranslation(.{}, &.{"Sun 03:00"}, &.{"0 3 * * 0"});
    try expectTranslation(.{}, &.{"Mon,Wed,Thu..Fri 00:00"}, &.{"0 0 * * 1,3-5"});
    try expectTranslation(.{}, &.{"*-*-1,15 12:00"}, &.{"0 12 1,15 * *"});
    try expectTranslation(.{}, &.{"*-*-1/10 00:00"}, &.{"0 0 1-31/10 * *"});
    try expectTranslation(.{}, &.{"*-1/3-01 06:00"}, &.{"0 6 1 1-12/3 *"});
    try expectTranslation(.{}, &.{"*-12-25 08:00"}, &.{"0 8 25 12 *"});
    try expectTranslation(.{}, &.{"*-*-* 2,14:0,30"}, &.{"0,30 2,14 * * *"});
}

test "several calendars give one entry each and duplicates collapse" {
    try expectTranslation(.{}, &.{ "daily", "Mon 12:00", "*-*-* 00:00:00" }, &.{ "0 0 * * *", "0 12 * * 1" });
}

test "non-translatable timers are rejected" {
    try expectRejected(.{}, &.{"*:*:0/10"});
    try expectRejected(.{}, &.{"*-*-* *:*:*"});
    try expectRejected(.{}, &.{"*-*-* 12:00:30"});
    try expectRejected(.{}, &.{"*-*-* 12:00:00.5"});
    try expectRejected(.{}, &.{"*-*~1 00:00"});
    try expectRejected(.{}, &.{"2026-06-15 12:00"});
    try expectRejected(.{}, &.{"2026-*-* 12:00"});
    try expectRejected(.{}, &.{"daily UTC"});
    try expectRejected(.{}, &.{"*-*-* 09:00 Europe/Rome"});
    try expectRejected(.{}, &.{ "daily", "*-*-* 09:00:30" });
    try expectRejected(.{ .on_boot_sec = &.{60_000_000} }, &.{"daily"});
    try expectRejected(.{ .on_startup_sec = &.{60_000_000} }, &.{"daily"});
    try expectRejected(.{ .on_active_sec = &.{60_000_000} }, &.{"daily"});
    try expectRejected(.{ .on_unit_active_sec = &.{60_000_000} }, &.{"daily"});
    try expectRejected(.{ .on_unit_inactive_sec = &.{60_000_000} }, &.{"daily"});
    try expectRejected(.{}, &.{});
}

test "day of month combined with a weekday is rejected because cron ORs them" {
    try expectRejected(.{}, &.{"Mon *-*-01..07 09:00"});
    try expectRejected(.{}, &.{"Fri *-*-13 00:00"});
    try expectRejected(.{}, &.{ "daily", "Sat,Sun *-*-1/2 00:00" });
    // Month and weekday together are fine: cron ANDs those.
    try expectTranslation(.{}, &.{"Mon *-06-* 09:00"}, &.{"0 9 * 6 1"});
}

// A cron matcher for the generated fields, used to check exactness against `calendar.next`.
fn fieldMatches(text: []const u8, value: i32, lo: i32, hi: i32) bool {
    if (std.mem.eql(u8, text, "*")) return true;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        var step: i32 = 1;
        var range = part;
        if (std.mem.findScalar(u8, part, '/')) |i| {
            step = std.fmt.parseInt(i32, part[i + 1 ..], 10) catch unreachable;
            range = part[0..i];
        }
        var from: i32 = lo;
        var to: i32 = hi;
        if (std.mem.findScalar(u8, range, '-')) |i| {
            from = std.fmt.parseInt(i32, range[0..i], 10) catch unreachable;
            to = std.fmt.parseInt(i32, range[i + 1 ..], 10) catch unreachable;
        } else if (!std.mem.eql(u8, range, "*")) {
            from = std.fmt.parseInt(i32, range, 10) catch unreachable;
            to = if (step > 1 or std.mem.findScalar(u8, part, '/') != null) hi else from;
        }
        if (value >= from and value <= to and @mod(value - from, step) == 0) return true;
    }
    return false;
}

fn cronMatches(e: Entry, unix_min: i64) bool {
    const tz = @import("../exec/tz.zig");
    const secs = unix_min * 60;
    const c = tz.civilFromUnix(secs, 0);
    const wday: i32 = c.weekday();
    // Vixie semantics: both day fields restricted means either may match; the translation never
    // produces that, so a plain AND is equivalent here.
    return fieldMatches(e.minute, c.minute, 0, 59) and fieldMatches(e.hour, c.hour, 0, 23) and
        fieldMatches(e.dom, c.day, 1, 31) and fieldMatches(e.month, c.month, 1, 12) and
        fieldMatches(e.dow, wday, 0, 6);
}

test "translated entries fire exactly when the calendar does" {
    const gpa = testing.allocator;
    const exprs = [_][]const u8{
        "minutely",          "hourly",                "daily",            "weekly",
        "monthly",           "quarterly",             "*:0/15",           "*-*-* 8..18:00",
        "*-*-* 0..12/4:30",  "*-*-* 2/6:05",          "Mon..Fri 09:30",   "Sat,Sun 12:00",
        "Sun 03:00",         "*-*-1,15 12:00",        "*-*-1/10 00:00",   "*-1/3-01 06:00",
        "*-12-25 08:00",     "*-*-* 2,14:0,30",       "*-*-31 12:00",     "*-02-29 00:00",
        "Mon,Wed,Fri 07:15", "*-*-* 1,5,10..12:0/20", "*-*-28..31 23:59",
    };
    const start: i64 = 1_767_225_600; // 2026-01-01 00:00 UTC
    const span_minutes: i64 = 4 * 366 * 24 * 60 / 8;
    for (exprs) |expr| {
        var spec = try calendar.parse(gpa, expr);
        defer spec.deinit(gpa);
        const specs = [_]calendar.Spec{spec};
        const entries = translate(gpa, .{}, &specs) orelse return error.NotTranslated;
        defer freeEntries(gpa, entries);
        // Calendar side: every elapse in the window, as unix minutes.
        var next_at: ?i64 = calendar.next(spec, &Tz.utc, start * 1_000_000 - 1);
        var minute: i64 = @divExact(start, 60);
        const end = minute + span_minutes;
        while (minute < end) : (minute += 1) {
            const expected = if (next_at) |n| n == minute * 60_000_000 else false;
            if (expected) next_at = calendar.next(spec, &Tz.utc, next_at.?);
            const actual = cronMatches(entries[0], minute);
            if (expected != actual) {
                std.debug.print("cron mismatch for [{s}] at unix minute {d}: calendar {} cron {}\n", .{ expr, minute, expected, actual });
                return error.CronMismatch;
            }
        }
    }
}
