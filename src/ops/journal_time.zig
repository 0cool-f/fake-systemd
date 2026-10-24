// SPDX-License-Identifier: GPL-3.0-or-later
//! Timestamps of `journalctl --since` and `--until` in the formats of systemd.time(7):
//! `now`, `today`, `yesterday`, `tomorrow`, `@<unix seconds>`, relative `-1h`, `+5min`,
//! `5 min ago`, `1h left`, and absolute `YYYY-MM-DD[ HH:MM[:SS[.ffffff]]]` or `HH:MM[:SS]`
//! (today), all in the local zone unless followed by `UTC`.
const std = @import("std");
const tz_mod = @import("../exec/tz.zig");
const timespan = @import("../unit/timespan.zig");

pub const Error = error{InvalidTime};

const day_ms: i64 = 86_400_000;

/// Unix time in milliseconds. `now_ms` is the reference instant for relative forms.
pub fn parse(text: []const u8, now_ms: i64, tz: tz_mod.Tz) Error!i64 {
    var t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return error.InvalidTime;
    if (std.mem.eql(u8, t, "now")) return now_ms;
    if (t[0] == '@') {
        const secs = std.fmt.parseInt(i64, t[1..], 10) catch return error.InvalidTime;
        return secs * 1000;
    }
    const today = startOfDay(now_ms, tz);
    if (std.mem.eql(u8, t, "today")) return today;
    if (std.mem.eql(u8, t, "yesterday")) return startOfDayShifted(now_ms, tz, -1);
    if (std.mem.eql(u8, t, "tomorrow")) return startOfDayShifted(now_ms, tz, 1);

    if (t[0] == '-' or t[0] == '+') {
        const span = spanMs(std.mem.trim(u8, t[1..], " \t")) orelse return error.InvalidTime;
        return if (t[0] == '-') now_ms - span else now_ms + span;
    }
    if (std.mem.endsWith(u8, t, " ago")) {
        return now_ms - (spanMs(std.mem.trim(u8, t[0 .. t.len - 4], " \t")) orelse return error.InvalidTime);
    }
    if (std.mem.endsWith(u8, t, " left")) {
        return now_ms + (spanMs(std.mem.trim(u8, t[0 .. t.len - 5], " \t")) orelse return error.InvalidTime);
    }

    var utc = false;
    if (std.mem.endsWith(u8, t, " UTC")) {
        utc = true;
        t = std.mem.trimEnd(u8, t[0 .. t.len - 4], " \t");
    } else if (std.mem.endsWith(u8, t, "Z") and t.len > 1 and std.ascii.isDigit(t[t.len - 2])) {
        utc = true;
        t = t[0 .. t.len - 1];
    }
    return absolute(t, now_ms, tz, utc);
}

fn spanMs(text: []const u8) ?i64 {
    const us = timespan.parse(text) catch return null;
    if (us == timespan.infinity) return null;
    return @intCast(us / 1000);
}

fn startOfDayShifted(now_ms: i64, tz: tz_mod.Tz, days: i64) i64 {
    const offset = tz.offsetAt(@divFloor(now_ms, 1000));
    const local_day = @divFloor(@divFloor(now_ms, 1000) + offset, 86400) + days;
    return tz.unixFromLocal(local_day * 86400) * 1000;
}

fn startOfDay(now_ms: i64, tz: tz_mod.Tz) i64 {
    return startOfDayShifted(now_ms, tz, 0);
}

fn absolute(text: []const u8, now_ms: i64, tz: tz_mod.Tz, utc: bool) Error!i64 {
    var date_part: ?[]const u8 = null;
    var time_part: ?[]const u8 = null;
    if (std.mem.findAny(u8, text, " T")) |sep| {
        date_part = text[0..sep];
        time_part = std.mem.trim(u8, text[sep + 1 ..], " \t");
    } else if (std.mem.findScalar(u8, text, ':') != null) {
        time_part = text;
    } else date_part = text;

    const now_secs = @divFloor(now_ms, 1000);
    var civil: tz_mod.Civil = tz_mod.civilFromUnix(now_secs, if (utc) 0 else tz.offsetAt(now_secs));
    if (date_part) |d| {
        var it = std.mem.splitScalar(u8, d, '-');
        const y = it.next() orelse return error.InvalidTime;
        const m = it.next() orelse return error.InvalidTime;
        const day = it.next() orelse return error.InvalidTime;
        if (it.next() != null) return error.InvalidTime;
        civil.year = std.fmt.parseInt(i32, y, 10) catch return error.InvalidTime;
        civil.month = std.fmt.parseInt(u8, m, 10) catch return error.InvalidTime;
        civil.day = std.fmt.parseInt(u8, day, 10) catch return error.InvalidTime;
        if (y.len != 4 or civil.month < 1 or civil.month > 12 or civil.day < 1 or civil.day > 31) return error.InvalidTime;
        civil.hour = 0;
        civil.minute = 0;
        civil.second = 0;
    }
    var frac_ms: i64 = 0;
    if (time_part) |tp| {
        var main = tp;
        if (std.mem.findScalar(u8, tp, '.')) |dot| {
            main = tp[0..dot];
            var digits = tp[dot + 1 ..];
            if (digits.len == 0 or digits.len > 9) return error.InvalidTime;
            for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidTime;
            digits = digits[0..@min(digits.len, 3)];
            frac_ms = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidTime;
            var n = digits.len;
            while (n < 3) : (n += 1) frac_ms *= 10;
        }
        var it = std.mem.splitScalar(u8, main, ':');
        const h = it.next() orelse return error.InvalidTime;
        const mi = it.next() orelse return error.InvalidTime;
        civil.hour = std.fmt.parseInt(u8, h, 10) catch return error.InvalidTime;
        civil.minute = std.fmt.parseInt(u8, mi, 10) catch return error.InvalidTime;
        civil.second = if (it.next()) |s| (std.fmt.parseInt(u8, s, 10) catch return error.InvalidTime) else 0;
        if (it.next() != null or civil.hour > 23 or civil.minute > 59 or civil.second > 60) return error.InvalidTime;
    }
    const local = tz_mod.unixFromCivil(civil);
    const unix = if (utc) local else tz.unixFromLocal(local);
    return unix * 1000 + frac_ms;
}

const rome = tz_mod.Tz{ .types = &.{.{ .offset = 3600, .is_dst = false, .abbreviation = "CET" }} };
// 2026-10-24 12:05:01 UTC
const test_now: i64 = 1_792_843_501_000;

fn expectTime(text: []const u8, expected_utc: tz_mod.Civil) !void {
    const want = tz_mod.unixFromCivil(expected_utc) * 1000;
    try std.testing.expectEqual(want, try parse(text, test_now, rome));
}

test "keywords" {
    try std.testing.expectEqual(test_now, try parse("now", test_now, rome));
    // Local midnight in a UTC+1 zone is 23:00 UTC of the day before.
    try expectTime("today", .{ .year = 2026, .month = 10, .day = 23, .hour = 23 });
    try expectTime("yesterday", .{ .year = 2026, .month = 10, .day = 22, .hour = 23 });
    try expectTime("tomorrow", .{ .year = 2026, .month = 10, .day = 24, .hour = 23 });
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), try parse("@1700000000", test_now, rome));
}

test "relative forms" {
    try std.testing.expectEqual(test_now - 3_600_000, try parse("-1h", test_now, rome));
    try std.testing.expectEqual(test_now + 300_000, try parse("+5min", test_now, rome));
    try std.testing.expectEqual(test_now - 600_000, try parse("10 min ago", test_now, rome));
    try std.testing.expectEqual(test_now + 7_200_000, try parse("2h left", test_now, rome));
    try std.testing.expectEqual(test_now - 5_400_000, try parse("-1h 30min", test_now, rome));
    try std.testing.expectEqual(test_now - 30_000, try parse("-30", test_now, rome));
}

test "absolute forms are local unless UTC" {
    try expectTime("2026-10-24 12:05:01", .{ .year = 2026, .month = 10, .day = 24, .hour = 11, .minute = 5, .second = 1 });
    try expectTime("2026-10-24T12:05", .{ .year = 2026, .month = 10, .day = 24, .hour = 11, .minute = 5 });
    try expectTime("2026-10-24", .{ .year = 2026, .month = 10, .day = 23, .hour = 23 });
    try expectTime("2026-10-24 12:05:01 UTC", .{ .year = 2026, .month = 10, .day = 24, .hour = 12, .minute = 5, .second = 1 });
    try expectTime("13:30", .{ .year = 2026, .month = 10, .day = 24, .hour = 12, .minute = 30 });
    try expectTime("13:30:15", .{ .year = 2026, .month = 10, .day = 24, .hour = 12, .minute = 30, .second = 15 });
    try std.testing.expectEqual(
        tz_mod.unixFromCivil(.{ .year = 2026, .month = 1, .day = 2, .hour = 2, .minute = 3, .second = 4 }) * 1000 + 250,
        try parse("2026-01-02 03:03:04.25", test_now, rome),
    );
}

test "invalid forms" {
    for ([_][]const u8{ "", "garbage", "2026-13-01", "2026-10-24 25:00", "-xyz", "12:", "2026-10", "@abc", "1h 3 agoo" }) |bad| {
        try std.testing.expectError(error.InvalidTime, parse(bad, test_now, rome));
    }
}
