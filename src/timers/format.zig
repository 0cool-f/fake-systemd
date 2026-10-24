// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of `systemctl list-timers` and of the timer lines of `status`: timestamps in the local
//! zone, relative times (`12min left`, `2h 3min ago`) and the table. The relative form follows
//! `format_timestamp_relative` of systemd's `time-util.c`.
const std = @import("std");
const Io = std.Io;
const tz_mod = @import("../exec/tz.zig");

const us_per_s: u64 = 1_000_000;
const us_per_min = 60 * us_per_s;
const us_per_hour = 60 * us_per_min;
const us_per_day = 24 * us_per_hour;
const us_per_week = 7 * us_per_day;
const us_per_month: u64 = 2_629_800 * us_per_s;
const us_per_year: u64 = 31_557_600 * us_per_s;

const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// `Sat 2026-10-24 15:00:00 CEST`
pub fn timestamp(w: *Io.Writer, tz: tz_mod.Tz, unix_us: i64) Io.Writer.Error!void {
    const secs = @divFloor(unix_us, std.time.us_per_s);
    const info = tz.infoAt(secs);
    const c = tz_mod.civilFromUnix(secs, info.offset);
    try w.print("{s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        weekdays[c.weekday()], @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, info.abbreviation,
    });
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// Distance between `then_us` and `now_us`, with `left` for a future instant and `ago` for a past one.
pub fn relative(w: *Io.Writer, then_us: i64, now_us: i64) Io.Writer.Error!void {
    const future = then_us > now_us;
    const d: u64 = @intCast(if (future) then_us - now_us else now_us - then_us);
    const suffix: []const u8 = if (future) "left" else "ago";
    if (d >= us_per_year) {
        const years = d / us_per_year;
        const months = d % us_per_year / us_per_month;
        try w.print("{d} year{s} {d} month{s} {s}", .{ years, plural(years), months, plural(months), suffix });
    } else if (d >= us_per_month) {
        const months = d / us_per_month;
        const days = d % us_per_month / us_per_day;
        try w.print("{d} month{s} {d} day{s} {s}", .{ months, plural(months), days, plural(days), suffix });
    } else if (d >= us_per_week) {
        const weeks = d / us_per_week;
        const days = d % us_per_week / us_per_day;
        try w.print("{d} week{s} {d} day{s} {s}", .{ weeks, plural(weeks), days, plural(days), suffix });
    } else if (d >= 2 * us_per_day) {
        try w.print("{d} days {s}", .{ d / us_per_day, suffix });
    } else if (d >= 25 * us_per_hour) {
        try w.print("1 day {d}h {s}", .{ (d - us_per_day) / us_per_hour, suffix });
    } else if (d >= 6 * us_per_hour) {
        try w.print("{d}h {s}", .{ d / us_per_hour, suffix });
    } else if (d >= us_per_hour) {
        try w.print("{d}h {d}min {s}", .{ d / us_per_hour, d % us_per_hour / us_per_min, suffix });
    } else if (d >= 5 * us_per_min) {
        try w.print("{d}min {s}", .{ d / us_per_min, suffix });
    } else if (d >= us_per_min) {
        try w.print("{d}min {d}s {s}", .{ d / us_per_min, d % us_per_min / us_per_s, suffix });
    } else if (d >= us_per_s) {
        try w.print("{d}s {s}", .{ d / us_per_s, suffix });
    } else if (d >= 1000) {
        try w.print("{d}ms {s}", .{ d / 1000, suffix });
    } else if (d > 0) {
        try w.print("{d}us {s}", .{ d, suffix });
    } else {
        try w.writeAll("now");
    }
}

pub const Row = struct {
    /// Unix microseconds; null prints `-`.
    next_us: ?i64,
    last_us: ?i64,
    unit: []const u8,
    activates: []const u8,
};

pub const TableOptions = struct {
    no_legend: bool = false,
    all: bool = false,
};

const columns = 6;

fn cell(arena: std.mem.Allocator, tz: tz_mod.Tz, now_us: i64, row: Row, i: usize) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    switch (i) {
        0 => if (row.next_us) |n| try timestamp(&aw.writer, tz, n) else try aw.writer.writeByte('-'),
        1 => if (row.next_us) |n| try relative(&aw.writer, n, now_us) else try aw.writer.writeByte('-'),
        2 => if (row.last_us) |l| try timestamp(&aw.writer, tz, l) else try aw.writer.writeByte('-'),
        3 => if (row.last_us) |l| try relative(&aw.writer, l, now_us) else try aw.writer.writeByte('-'),
        4 => try aw.writer.writeAll(row.unit),
        else => try aw.writer.writeAll(row.activates),
    }
    return aw.written();
}

/// The `list-timers` table: columns padded to their widest cell and one space apart, then the
/// legend. Rows are written in the order given.
pub fn writeTable(w: *Io.Writer, arena: std.mem.Allocator, tz: tz_mod.Tz, now_us: i64, rows: []const Row, opts: TableOptions) !void {
    const headers = [columns][]const u8{ "NEXT", "LEFT", "LAST", "PASSED", "UNIT", "ACTIVATES" };
    const cells = try arena.alloc([columns][]const u8, rows.len);
    var widths: [columns]usize = undefined;
    for (headers, &widths) |h, *wd| wd.* = if (opts.no_legend) 0 else h.len;
    for (rows, cells) |row, *line| {
        for (0..columns) |i| {
            line[i] = try cell(arena, tz, now_us, row, i);
            widths[i] = @max(widths[i], line[i].len);
        }
    }
    if (!opts.no_legend) try writeLine(w, widths, headers);
    for (cells) |line| try writeLine(w, widths, line);
    if (opts.no_legend) return;
    try w.print("\n{d} timers listed.\n", .{rows.len});
    if (!opts.all) try w.writeAll("Pass --all to see loaded but inactive timers, too.\n");
}

fn writeLine(w: *Io.Writer, widths: [columns]usize, cells: [columns][]const u8) Io.Writer.Error!void {
    for (cells, widths, 0..) |c, width, i| {
        try w.writeAll(c);
        if (i + 1 == columns) break;
        var n = c.len;
        while (n < width + 1) : (n += 1) try w.writeByte(' ');
    }
    try w.writeByte('\n');
}

const testing = std.testing;

fn expectRelative(expected: []const u8, then_us: i64, now_us: i64) !void {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try relative(&w, then_us, now_us);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "relative times follow systemd's ranges" {
    const now: i64 = 1_000_000_000_000_000;
    const s: i64 = 1_000_000;
    try expectRelative("now", now, now);
    try expectRelative("500ms left", now + 500_000, now);
    try expectRelative("3us ago", now - 3, now);
    try expectRelative("42s left", now + 42 * s, now);
    try expectRelative("1min 30s left", now + 90 * s, now);
    try expectRelative("12min ago", now - 12 * 60 * s, now);
    try expectRelative("1h 5min left", now + 65 * 60 * s, now);
    try expectRelative("7h ago", now - 7 * 3600 * s, now);
    try expectRelative("1 day 2h left", now + 26 * 3600 * s, now);
    try expectRelative("3 days ago", now - 3 * 86400 * s, now);
    try expectRelative("1 week 2 days left", now + 9 * 86400 * s, now);
    try expectRelative("1 month 0 days ago", now - 31 * 86400 * s, now);
    try expectRelative("2 years 2 months left", now + 800 * 86400 * s, now);
}

test "timestamp in a zone" {
    const tz: tz_mod.Tz = .{ .types = &.{.{ .offset = 7200, .is_dst = true, .abbreviation = "CEST" }} };
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try timestamp(&w, tz, 1_792_836_301 * std.time.us_per_s);
    try testing.expectEqualStrings("Sat 2026-10-24 12:05:01 CEST", w.buffered());
}

test "table layout and legend" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tz: tz_mod.Tz = tz_mod.Tz.utc;
    const now: i64 = 1_792_836_301 * std.time.us_per_s;
    const rows = [_]Row{
        .{ .next_us = now + 1_700 * std.time.us_per_s, .last_us = now - 600 * std.time.us_per_s, .unit = "a.timer", .activates = "a.service" },
        .{ .next_us = null, .last_us = null, .unit = "long-name.timer", .activates = "long-name.service" },
    };
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeTable(&aw.writer, arena.allocator(), tz, now, &rows, .{});
    try testing.expectEqualStrings(
        \\NEXT                        LEFT       LAST                        PASSED    UNIT            ACTIVATES
        \\Sat 2026-10-24 10:33:21 UTC 28min left Sat 2026-10-24 09:55:01 UTC 10min ago a.timer         a.service
        \\-                           -          -                           -         long-name.timer long-name.service
        \\
        \\2 timers listed.
        \\Pass --all to see loaded but inactive timers, too.
        \\
    , aw.written());
    aw.clearRetainingCapacity();
    try writeTable(&aw.writer, arena.allocator(), tz, now, &.{}, .{ .all = true });
    try testing.expectEqualStrings("NEXT LEFT LAST PASSED UNIT ACTIVATES\n\n0 timers listed.\n", aw.written());
    aw.clearRetainingCapacity();
    try writeTable(&aw.writer, arena.allocator(), tz, now, rows[0..1], .{ .no_legend = true });
    try testing.expectEqualStrings("Sat 2026-10-24 10:33:21 UTC 28min left Sat 2026-10-24 09:55:01 UTC 10min ago a.timer a.service\n", aw.written());
}
