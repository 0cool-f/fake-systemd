// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from systemd src/shared/calendarspec.c (LGPL-2.1-or-later), copyright the systemd authors.
//! `OnCalendar=` expressions (systemd.time(7) "Calendar Events"): parsing, the normalized form
//! printed by `systemd-analyze calendar`, and the next elapse in a time zone. The matching
//! algorithm follows systemd's `calendarspec.c`, including its `mktime` probing, so DST gaps and
//! overlaps resolve the same way.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const tz_mod = @import("../exec/tz.zig");
const Tz = tz_mod.Tz;

pub const Error = error{InvalidCalendar} || Allocator.Error;

const usec_per_sec: i64 = 1_000_000;
const int_max: i64 = std.math.maxInt(i32);
const min_year: i64 = 1970;
const max_year: i64 = 2199;
const components_max = 240;
/// 9999-12-30 23:59:59 UTC in microseconds.
const formattable_max: i64 = 253402214399000000;

/// One element of a comma separated field: `start`, `start..stop`, with an optional repeat step.
/// `stop` is -1 and `repeat` 0 when absent. Seconds are stored in microseconds.
pub const Component = struct {
    start: i32,
    stop: i32 = -1,
    repeat: i32 = 0,
};

pub const Spec = struct {
    /// Bit 0 is Monday; -1 means any weekday.
    weekdays_bits: i32 = -1,
    /// Empty slices mean `*`, except `microsecond`, which is never empty.
    year: []const Component = &.{},
    month: []const Component = &.{},
    day: []const Component = &.{},
    hour: []const Component = &.{},
    minute: []const Component = &.{},
    microsecond: []const Component = &.{},
    /// The day field counts from the end of the month (`~`).
    end_of_month: bool = false,
    /// Evaluated in UTC (explicit `UTC` suffix or `@timestamp`).
    utc: bool = false,
    /// 0 or 1 when the expression ends with the local standard or daylight zone abbreviation.
    dst: i8 = -1,
    /// Explicit zone name from the expression; the caller loads it for `next`.
    timezone: ?[]const u8 = null,
    /// The local zone abbreviation matched when `dst` is 0 or 1.
    dst_name: ?[]const u8 = null,
    storage: []Component = &.{},
    strings: []u8 = &.{},

    pub fn deinit(spec: *Spec, gpa: Allocator) void {
        gpa.free(spec.storage);
        gpa.free(spec.strings);
        spec.* = .{};
    }

    /// True when `next` must be given the zone named by `timezone` rather than the local zone.
    pub fn needsNamedZone(spec: Spec) bool {
        return spec.timezone != null;
    }
};

pub const Options = struct {
    /// Standard and daylight abbreviations of the local zone; an expression ending with one of
    /// them is pinned to that DST state.
    local_names: [2]?[]const u8 = .{ null, null },
    /// Decides whether the last word of an expression names a zone. Without it the word must
    /// look like a zone name (capitalized, `[A-Za-z0-9_+-/]`).
    zone_exists: ?*const fn (name: []const u8) bool = null,
};

pub fn parse(gpa: Allocator, text: []const u8) Error!Spec {
    return parseOptions(gpa, text, .{});
}

pub fn parseOptions(gpa: Allocator, text: []const u8, options: Options) Error!Spec {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinitLists();
    try b.parseText(text, options);
    return b.finish();
}

const Chain = std.ArrayList(Component);

const Builder = struct {
    gpa: Allocator,
    utc: bool = false,
    dst: i8 = -1,
    weekdays_bits: i32 = 0,
    end_of_month: bool = false,
    timezone: ?[]const u8 = null,
    dst_name: ?[]const u8 = null,
    year: Chain = .empty,
    month: Chain = .empty,
    day: Chain = .empty,
    hour: Chain = .empty,
    minute: Chain = .empty,
    microsecond: Chain = .empty,

    fn deinitLists(b: *Builder) void {
        b.year.deinit(b.gpa);
        b.month.deinit(b.gpa);
        b.day.deinit(b.gpa);
        b.hour.deinit(b.gpa);
        b.minute.deinit(b.gpa);
        b.microsecond.deinit(b.gpa);
    }

    fn constChain(b: *Builder, chain: *Chain, value: i32) Allocator.Error!void {
        try chain.append(b.gpa, .{ .start = value });
    }

    fn parseText(b: *Builder, text_in: []const u8, options: Options) Error!void {
        var p = text_in;
        if (p.len >= 4 and std.ascii.eqlIgnoreCase(p[p.len - 4 ..], " UTC")) {
            b.utc = true;
            p = p[0 .. p.len - 4];
        } else {
            var matched = false;
            for (options.local_names, 0..) |maybe, j| {
                const name = maybe orelse continue;
                if (name.len == 0 or p.len <= name.len) continue;
                if (!std.ascii.eqlIgnoreCase(p[p.len - name.len ..], name)) continue;
                if (p[p.len - name.len - 1] != ' ') continue;
                b.dst = @intCast(j);
                b.dst_name = name;
                p = p[0 .. p.len - name.len - 1];
                matched = true;
                break;
            }
            if (!matched) {
                if (std.mem.findScalarLast(u8, p, ' ')) |sp| {
                    const word = p[sp + 1 ..];
                    if (isZoneName(word, options)) {
                        b.timezone = word;
                        p = p[0..sp];
                    }
                }
            }
        }
        if (p.len == 0) return error.InvalidCalendar;

        if (try b.shorthand(p)) return;

        var pos: usize = 0;
        try b.parseWeekdays(p, &pos);
        const done = try b.parseDate(p, &pos);
        if (!done) try b.parseTime(p, &pos);
        if (pos != p.len) return error.InvalidCalendar;
    }

    fn shorthand(b: *Builder, p: []const u8) Error!bool {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(p, "minutely")) {
            try b.constChain(&b.microsecond, 0);
        } else if (eq(p, "hourly")) {
            try b.constChain(&b.minute, 0);
            try b.constChain(&b.microsecond, 0);
        } else if (eq(p, "daily")) {
            try b.midnight();
        } else if (eq(p, "monthly")) {
            try b.constChain(&b.day, 1);
            try b.midnight();
        } else if (eq(p, "annually") or eq(p, "yearly") or eq(p, "anually")) {
            try b.constChain(&b.month, 1);
            try b.constChain(&b.day, 1);
            try b.midnight();
        } else if (eq(p, "weekly")) {
            b.weekdays_bits = 1;
            try b.midnight();
        } else if (eq(p, "quarterly")) {
            for ([_]i32{ 1, 4, 7, 10 }) |m| try b.constChain(&b.month, m);
            try b.constChain(&b.day, 1);
            try b.midnight();
        } else if (eq(p, "biannually") or eq(p, "bi-annually") or eq(p, "semiannually") or eq(p, "semi-annually")) {
            for ([_]i32{ 1, 7 }) |m| try b.constChain(&b.month, m);
            try b.constChain(&b.day, 1);
            try b.midnight();
        } else return false;
        return true;
    }

    fn midnight(b: *Builder) Allocator.Error!void {
        try b.constChain(&b.hour, 0);
        try b.constChain(&b.minute, 0);
        try b.constChain(&b.microsecond, 0);
    }

    fn parseWeekdays(b: *Builder, s: []const u8, pos: *usize) Error!void {
        const names = [_]struct { name: []const u8, nr: u3 }{
            .{ .name = "Monday", .nr = 0 },    .{ .name = "Mon", .nr = 0 },
            .{ .name = "Tuesday", .nr = 1 },   .{ .name = "Tue", .nr = 1 },
            .{ .name = "Wednesday", .nr = 2 }, .{ .name = "Wed", .nr = 2 },
            .{ .name = "Thursday", .nr = 3 },  .{ .name = "Thu", .nr = 3 },
            .{ .name = "Friday", .nr = 4 },    .{ .name = "Fri", .nr = 4 },
            .{ .name = "Saturday", .nr = 5 },  .{ .name = "Sat", .nr = 5 },
            .{ .name = "Sunday", .nr = 6 },    .{ .name = "Sun", .nr = 6 },
        };
        var l: i32 = -1;
        var first = true;
        while (true) {
            var matched: ?usize = null;
            for (names, 0..) |n, i| {
                const rest = s[pos.*..];
                if (rest.len < n.name.len or !std.ascii.eqlIgnoreCase(rest[0..n.name.len], n.name)) continue;
                const after = at(s, pos.* + n.name.len);
                if (after != 0 and after != '-' and after != '.' and after != ',' and after != ' ') return error.InvalidCalendar;
                b.weekdays_bits |= @as(i32, 1) << n.nr;
                if (l >= 0) {
                    if (l > n.nr) return error.InvalidCalendar;
                    var j: i32 = l + 1;
                    while (j < n.nr) : (j += 1) b.weekdays_bits |= @as(i32, 1) << @intCast(j);
                }
                pos.* += n.name.len;
                matched = i;
                break;
            }
            const i = matched orelse {
                if (first) return;
                return error.InvalidCalendar;
            };
            const cur = at(s, pos.*);
            if (cur == 0) return;
            if (cur == ' ') {
                pos.* = skipSpaces(s, pos.*);
                return;
            }
            if (cur == '.') {
                if (l >= 0) return error.InvalidCalendar;
                if (at(s, pos.* + 1) != '.') return error.InvalidCalendar;
                l = names[i].nr;
                pos.* += 2;
            } else if (cur == '-') {
                if (l >= 0) return error.InvalidCalendar;
                l = names[i].nr;
                pos.* += 1;
            } else if (cur == ',') {
                l = -1;
                pos.* += 1;
            }
            const nxt = at(s, pos.*);
            if (nxt == 0 or nxt == ' ') {
                pos.* = skipSpaces(s, pos.*);
                if (l < 0) return;
                return error.InvalidCalendar;
            }
            first = false;
        }
    }

    /// Returns true when the expression is complete (`@timestamp`).
    fn parseDate(b: *Builder, s: []const u8, pos: *usize) Error!bool {
        var t = pos.*;
        if (at(s, t) == 0) return false;

        if (at(s, t) == '@') {
            t += 1;
            const value = try parseUnsigned(s, &t);
            if (value > std.math.maxInt(i64)) return error.InvalidCalendar;
            try b.fromTimestamp(@intCast(value));
            pos.* = t;
            return true;
        }

        var first: Chain = .empty;
        defer first.deinit(b.gpa);
        var second: Chain = .empty;
        defer second.deinit(b.gpa);
        var third: Chain = .empty;
        defer third.deinit(b.gpa);

        try b.parseChain(&first, s, &t, false);
        const c0 = at(s, t);
        if (c0 == 0 or c0 == ':') return false;
        if (c0 == '~') b.end_of_month = true else if (c0 != '-') return error.InvalidCalendar;
        t += 1;
        try b.parseChain(&second, s, &t, false);

        const c1 = at(s, t);
        if (c1 == 0 or c1 == ' ') {
            pos.* = skipSpaces(s, t);
            std.mem.swap(Chain, &b.month, &first);
            std.mem.swap(Chain, &b.day, &second);
            return false;
        } else if (b.end_of_month) return error.InvalidCalendar;

        if (c1 == '~') b.end_of_month = true else if (c1 != '-') return error.InvalidCalendar;
        t += 1;
        try b.parseChain(&third, s, &t, false);
        const c2 = at(s, t);
        if (c2 != 0 and c2 != ' ') return error.InvalidCalendar;

        pos.* = skipSpaces(s, t);
        std.mem.swap(Chain, &b.year, &first);
        std.mem.swap(Chain, &b.month, &second);
        std.mem.swap(Chain, &b.day, &third);
        return false;
    }

    fn fromTimestamp(b: *Builder, time: i64) Error!void {
        if (time > 253402300799) return error.InvalidCalendar;
        const c = tz_mod.civilFromUnix(time, 0);
        b.utc = true;
        try b.constChain(&b.year, c.year);
        try b.constChain(&b.month, c.month);
        try b.constChain(&b.day, c.day);
        try b.constChain(&b.hour, c.hour);
        try b.constChain(&b.minute, c.minute);
        try b.constChain(&b.microsecond, @as(i32, c.second) * 1_000_000);
    }

    fn parseTime(b: *Builder, s: []const u8, pos: *usize) Error!void {
        var t = pos.*;
        var h: Chain = .empty;
        defer h.deinit(b.gpa);
        var m: Chain = .empty;
        defer m.deinit(b.gpa);
        var sec: Chain = .empty;
        defer sec.deinit(b.gpa);

        if (at(s, t) == 0) {
            try b.constChain(&h, 0);
            try b.constChain(&m, 0);
            try b.constChain(&sec, 0);
        } else {
            try b.parseChain(&h, s, &t, false);
            if (at(s, t) != ':') return error.InvalidCalendar;
            t += 1;
            try b.parseChain(&m, s, &t, false);
            if (at(s, t) == 0) {
                try b.constChain(&sec, 0);
            } else {
                if (at(s, t) != ':') return error.InvalidCalendar;
                t += 1;
                try b.parseChain(&sec, s, &t, true);
                if (at(s, t) != 0) return error.InvalidCalendar;
            }
        }
        pos.* = t;
        std.mem.swap(Chain, &b.hour, &h);
        std.mem.swap(Chain, &b.minute, &m);
        std.mem.swap(Chain, &b.microsecond, &sec);
    }

    fn parseChain(b: *Builder, chain: *Chain, s: []const u8, pos: *usize, usec: bool) Error!void {
        if (at(s, pos.*) == '*') {
            if (usec) try chain.append(b.gpa, .{ .start = 0, .repeat = 1_000_000 });
            pos.* += 1;
            return;
        }
        var t = pos.*;
        var nesting: usize = 0;
        while (true) {
            if (nesting > components_max) return error.InvalidCalendar;
            const start = try parseDecimal(s, &t, usec);
            var stop: i64 = -1;
            var repeat: i64 = 0;
            if (at(s, t) == '.' and at(s, t + 1) == '.') {
                t += 2;
                stop = try parseDecimal(s, &t, usec);
                repeat = if (usec) usec_per_sec else 1;
            }
            if (at(s, t) == '/') {
                t += 1;
                repeat = try parseDecimal(s, &t, usec);
                if (repeat == 0) return error.InvalidCalendar;
            } else {
                if (start > int_max - repeat) return error.InvalidCalendar;
                if (usec and stop >= 0 and start + repeat > stop) return error.InvalidCalendar;
            }
            const e = at(s, t);
            if (e != 0 and e != ' ' and e != ',' and e != '-' and e != '~' and e != ':') return error.InvalidCalendar;
            try chain.append(b.gpa, .{ .start = @intCast(start), .stop = @intCast(stop), .repeat = @intCast(repeat) });
            if (e != ',') break;
            t += 1;
            nesting += 1;
        }
        pos.* = t;
    }

    fn finish(b: *Builder) Error!Spec {
        var spec: Spec = .{
            .utc = b.utc,
            .dst = b.dst,
            .end_of_month = b.end_of_month,
            .weekdays_bits = b.weekdays_bits,
        };
        if (b.timezone) |tzname| {
            if (std.mem.eql(u8, tzname, "UTC")) {
                spec.utc = true;
            }
        }
        if (spec.weekdays_bits <= 0 or spec.weekdays_bits >= 127) spec.weekdays_bits = -1;
        if (spec.end_of_month and b.day.items.len == 0) spec.end_of_month = false;

        fixYear(b.year.items);
        const chains = [_]*Chain{ &b.year, &b.month, &b.day, &b.hour, &b.minute, &b.microsecond };
        for (chains) |c| normalizeChain(c);

        spec.year = b.year.items;
        spec.month = b.month.items;
        spec.day = b.day.items;
        spec.hour = b.hour.items;
        spec.minute = b.minute.items;
        spec.microsecond = b.microsecond.items;
        if (!valid(spec)) return error.InvalidCalendar;

        var total: usize = 0;
        for (chains) |c| total += c.items.len;
        const storage = try b.gpa.alloc(Component, total);
        errdefer b.gpa.free(storage);
        var at_i: usize = 0;
        var slices: [6][]const Component = undefined;
        for (chains, 0..) |c, i| {
            @memcpy(storage[at_i..][0..c.items.len], c.items);
            slices[i] = storage[at_i..][0..c.items.len];
            at_i += c.items.len;
        }

        var str_len: usize = 0;
        const zone_name: ?[]const u8 = if (b.timezone != null and !std.mem.eql(u8, b.timezone.?, "UTC")) b.timezone else null;
        if (zone_name) |z| str_len += z.len;
        if (b.dst_name) |d| str_len += d.len;
        const strings = try b.gpa.alloc(u8, str_len);
        var si: usize = 0;
        if (zone_name) |z| {
            @memcpy(strings[si..][0..z.len], z);
            spec.timezone = strings[si..][0..z.len];
            si += z.len;
        }
        if (b.dst_name) |d| {
            @memcpy(strings[si..][0..d.len], d);
            spec.dst_name = strings[si..][0..d.len];
        }

        spec.year = slices[0];
        spec.month = slices[1];
        spec.day = slices[2];
        spec.hour = slices[3];
        spec.minute = slices[4];
        spec.microsecond = slices[5];
        spec.storage = storage;
        spec.strings = strings;
        return spec;
    }
};

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (at(s, i) == ' ') i += 1;
    return i;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parseUnsigned(s: []const u8, pos: *usize) Error!u64 {
    var i = pos.*;
    if (!isDigit(at(s, i))) return error.InvalidCalendar;
    var value: u64 = 0;
    while (isDigit(at(s, i))) : (i += 1) {
        value = std.math.mul(u64, value, 10) catch return error.InvalidCalendar;
        value = std.math.add(u64, value, at(s, i) - '0') catch return error.InvalidCalendar;
    }
    pos.* = i;
    return value;
}

/// Up to six fractional digits, rounded half up on the seventh.
fn parseFraction(s: []const u8, pos: *usize) Error!u64 {
    var i = pos.*;
    var val: u64 = 0;
    var n: usize = 0;
    while (n < 6) : ({
        n += 1;
        i += 1;
    }) {
        if (!isDigit(at(s, i))) {
            if (n == 0) return error.InvalidCalendar;
            while (n < 6) : (n += 1) val *= 10;
            break;
        }
        val = val * 10 + (at(s, i) - '0');
    }
    if (at(s, i) >= '5' and at(s, i) <= '9') val += 1;
    while (isDigit(at(s, i))) i += 1;
    pos.* = i;
    return val;
}

fn parseDecimal(s: []const u8, pos: *usize, usec: bool) Error!i64 {
    var t = pos.*;
    var value = try parseUnsigned(s, &t);
    if (usec) {
        value = std.math.mul(u64, value, 1_000_000) catch return error.InvalidCalendar;
        if (at(s, t) == '.' and at(s, t + 1) != '.') {
            t += 1;
            const add = try parseFraction(s, &t);
            value = std.math.add(u64, value, add) catch return error.InvalidCalendar;
        }
    }
    if (value > int_max) return error.InvalidCalendar;
    pos.* = t;
    return @intCast(value);
}

fn isZoneName(word: []const u8, options: Options) bool {
    if (options.zone_exists) |f| return f(word);
    if (word.len == 0 or word[0] < 'A' or word[0] > 'Z') return false;
    for (word) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '+' and c != '-' and c != '/') return false;
    }
    if (word[word.len - 1] == '/' or std.mem.find(u8, word, "//") != null) return false;
    const weekdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    for (weekdays) |d| {
        if (std.ascii.startsWithIgnoreCase(word, d) and word.len <= 9) return false;
    }
    return true;
}

fn fixYear(items: []Component) void {
    for (items) |*c| {
        if (c.start >= 0 and c.start < 70) c.start += 2000;
        if (c.stop >= 0 and c.stop < 70) c.stop += 2000;
        if (c.start >= 70 and c.start < 100) c.start += 1900;
        if (c.stop >= 70 and c.stop < 100) c.stop += 1900;
    }
}

fn componentLess(_: void, a: Component, b: Component) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.stop != b.stop) return a.stop < b.stop;
    return a.repeat < b.repeat;
}

fn normalizeChain(chain: *Chain) void {
    for (chain.items) |*i| {
        if (i.stop > i.start and i.repeat > 0) i.stop -= @mod(i.stop - i.start, i.repeat);
        if ((i.stop > i.start and i.repeat > 0 and i.start + i.repeat > i.stop) or i.start == i.stop) {
            i.repeat = 0;
            i.stop = -1;
        }
    }
    if (chain.items.len <= 1) return;
    std.mem.sort(Component, chain.items, {}, componentLess);
    var w: usize = 1;
    for (chain.items[1..]) |c| {
        const prev = chain.items[w - 1];
        if (prev.start == c.start and prev.stop == c.stop and prev.repeat == c.repeat) continue;
        chain.items[w] = c;
        w += 1;
    }
    chain.shrinkRetainingCapacity(w);
}

fn chainValid(items: []const Component, from: i64, to_in: i64, end_of_month: bool) bool {
    if (items.len == 0) return true;
    var to = to_in;
    if (end_of_month) to -= 3;
    const c = items[0];
    if (c.start < from or c.start > to) return false;
    if (c.repeat > to - from) return false;
    if (c.stop >= 0) {
        if (c.stop < from or c.stop > to) return false;
        if (@as(i64, c.start) + c.repeat > c.stop) return false;
    } else {
        if (end_of_month and @as(i64, c.start) - c.repeat < from) return false;
        if (!end_of_month and @as(i64, c.start) + c.repeat > to) return false;
    }
    return chainValid(items[1..], from, to, end_of_month);
}

fn valid(spec: Spec) bool {
    return chainValid(spec.year, min_year, max_year, false) and
        chainValid(spec.month, 1, 12, false) and
        chainValid(spec.day, 1, 31, spec.end_of_month) and
        chainValid(spec.hour, 0, 23, false) and
        chainValid(spec.minute, 0, 59, false) and
        chainValid(spec.microsecond, 0, 60 * usec_per_sec - 1, false);
}

// ---------------------------------------------------------------------------------------------
// Normalized form

/// Writes the normalized form `systemd-analyze calendar` prints.
pub fn normalized(spec: Spec, w: *Writer) Writer.Error!void {
    if (spec.weekdays_bits > 0 and spec.weekdays_bits <= 127) {
        try formatWeekdays(spec, w);
        try w.writeByte(' ');
    }
    try formatChain(w, 4, spec.year, true, false);
    try w.writeByte('-');
    try formatChain(w, 2, spec.month, true, false);
    try w.writeByte(if (spec.end_of_month) '~' else '-');
    try formatChain(w, 2, spec.day, true, false);
    try w.writeByte(' ');
    try formatChain(w, 2, spec.hour, true, false);
    try w.writeByte(':');
    try formatChain(w, 2, spec.minute, true, false);
    try w.writeByte(':');
    try formatChain(w, 2, spec.microsecond, true, true);
    if (spec.utc) {
        try w.writeAll(" UTC");
    } else if (spec.timezone) |z| {
        try w.print(" {s}", .{z});
    } else if (spec.dst_name) |n| {
        if (n.len > 0) try w.print(" {s}", .{n});
    }
}

fn formatWeekdays(spec: Spec, w: *Writer) Writer.Error!void {
    const days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    var need_comma = false;
    var l: i32 = -1;
    var x: i32 = 0;
    while (x < 7) : (x += 1) {
        if (spec.weekdays_bits & (@as(i32, 1) << @intCast(x)) != 0) {
            if (l < 0) {
                if (need_comma) try w.writeByte(',') else need_comma = true;
                try w.writeAll(days[@intCast(x)]);
                l = x;
            }
        } else if (l >= 0) {
            if (x > l + 1) {
                try w.writeAll(if (x > l + 2) ".." else ",");
                try w.writeAll(days[@intCast(x - 1)]);
            }
            l = -1;
        }
    }
    if (l >= 0 and x > l + 1) {
        try w.writeAll(if (x > l + 2) ".." else ",");
        try w.writeAll(days[@intCast(x - 1)]);
    }
}

fn chainIsStar(items: []const Component, usec: bool) bool {
    if (items.len == 0) return true;
    if (usec) {
        for (items) |c| if (c.start == 0 and c.stop < 0 and c.repeat == usec_per_sec) return true;
    }
    return false;
}

fn padInt(w: *Writer, v: i32, width: usize) Writer.Error!void {
    const u: u32 = @intCast(v);
    if (width == 4) try w.print("{d:0>4}", .{u}) else try w.print("{d:0>2}", .{u});
}

fn formatChain(w: *Writer, space: usize, items: []const Component, start: bool, usec: bool) Writer.Error!void {
    const d: i32 = if (usec) 1_000_000 else 1;
    if (start and chainIsStar(items, usec)) {
        try w.writeByte('*');
        return;
    }
    const c = items[0];
    try padInt(w, @divTrunc(c.start, d), space);
    if (@rem(c.start, d) > 0) try w.print(".{d:0>6}", .{@as(u32, @intCast(@rem(c.start, d)))});
    if (c.stop > 0) {
        try w.writeAll("..");
        try padInt(w, @divTrunc(c.stop, d), space);
    }
    if (@rem(c.stop, d) > 0) try w.print(".{d:0>6}", .{@as(u32, @intCast(@rem(c.stop, d)))});
    if (c.repeat > 0 and !(c.stop > 0 and c.repeat == d)) try w.print("/{d}", .{@divTrunc(c.repeat, d)});
    if (@rem(c.repeat, d) > 0) try w.print(".{d:0>6}", .{@as(u32, @intCast(@rem(c.repeat, d)))});
    if (items.len > 1) {
        try w.writeByte(',');
        try formatChain(w, space, items[1..], false, usec);
    }
}

// ---------------------------------------------------------------------------------------------
// Next elapse

const Tm = struct {
    sec: i64,
    min: i64,
    hour: i64,
    mday: i64,
    /// 0 to 11, may be out of range before normalization.
    mon: i64,
    /// Years since 1900.
    year: i64,
    wday: i64 = 0,
    yday: i64 = 0,
    isdst: i32 = -1,
};

/// A `mktime`/`localtime` pair that mimics glibc, including its cached offset guess, which
/// decides which of two equal wall-clock times in a DST overlap is returned.
const Clock = struct {
    zone: *const Tz,
    utc: bool,
    /// Negated UTC offset of the previous result, the guess for the next call.
    off: i64 = 0,

    fn offsetAt(c: Clock, t: i64) tz_mod.Info {
        if (c.utc) return .{ .offset = 0 };
        return c.zone.infoAt(t);
    }

    fn localtime(c: Clock, t: i64) Tm {
        const info = c.offsetAt(t);
        const civ = tz_mod.civilFromUnix(t, info.offset);
        const days = tz_mod.daysFromCivil(civ.year, civ.month, civ.day);
        return .{
            .sec = civ.second,
            .min = civ.minute,
            .hour = civ.hour,
            .mday = civ.day,
            .mon = @as(i64, civ.month) - 1,
            .year = @as(i64, civ.year) - 1900,
            .wday = civ.weekday(),
            .yday = days - tz_mod.daysFromCivil(civ.year, 1, 1),
            .isdst = @intFromBool(info.is_dst),
        };
    }

    /// Wall-clock seconds of `tm` read as UTC, out-of-range fields carried over.
    fn wallSeconds(tm: Tm) error{Range}!i64 {
        const years = @divFloor(tm.mon, 12);
        const mon: u8 = @intCast(@mod(tm.mon, 12) + 1);
        const year = std.math.cast(i32, tm.year + 1900 + years) orelse return error.Range;
        if (year < -100000 or year > 100000) return error.Range;
        const days = tz_mod.daysFromCivil(year, mon, 1) + tm.mday - 1;
        return days * 86400 + tm.hour * 3600 + tm.min * 60 + tm.sec;
    }

    fn mktime(c: *Clock, tm: *Tm) error{Range}!i64 {
        if (c.utc) {
            const t = try wallSeconds(tm.*);
            tm.* = c.localtime(t);
            return t;
        }
        const req = try wallSeconds(tm.*);
        const isdst = tm.isdst;
        const t0 = req + c.off;
        var t = t0;
        var t1 = t0;
        var t2 = t0;
        var dst2 = false;
        var remaining: u8 = 6;
        var info: tz_mod.Info = undefined;
        var found = false;
        while (true) {
            info = c.offsetAt(t);
            const dt = req - (t + info.offset);
            if (dt == 0) break;
            if (t == t1 and t != t2 and
                (if (isdst < 0)
                    @intFromBool(dst2) <= @intFromBool(info.is_dst)
                else
                    (isdst != 0) != info.is_dst))
            {
                found = true;
                break;
            }
            remaining -= 1;
            if (remaining == 0) return error.Range;
            t1 = t2;
            t2 = t;
            t += dt;
            dst2 = info.is_dst;
        }
        if (!found and isdst >= 0 and (isdst != 0) != info.is_dst) {
            const dst_difference: i64 = @as(i64, @intFromBool(isdst == 0)) - @intFromBool(!info.is_dst);
            const stride: i64 = 601200;
            const delta_bound: i64 = 457243209 / 2 + stride;
            var delta: i64 = stride;
            search: while (delta < delta_bound) : (delta += stride) {
                var direction: i64 = -1;
                while (direction <= 1) : (direction += 2) {
                    const ot = t + delta * direction;
                    const oi = c.offsetAt(ot);
                    if ((isdst != 0) == oi.is_dst) {
                        t = req - oi.offset;
                        break :search;
                    }
                }
            } else {
                t += 3600 * dst_difference;
            }
        }
        c.off = t - req;
        tm.* = c.localtime(t);
        return t;
    }

    /// `mktime_or_timegm_usec`: also rejects years before 1970 and negative results.
    fn mktimeChecked(c: *Clock, tm: *Tm) error{Range}!i64 {
        if (tm.year < 69) return error.Range;
        if (tm.year > 582642) return error.Range;
        const t = try c.mktime(tm);
        if (t < 0) return error.Range;
        return t;
    }
};

const Bounds = enum(i8) { err = -1, changed = 0, ok = 1 };

fn cmp3(a: i64, b: i64) i32 {
    return @as(i32, @intFromBool(a > b)) - @intFromBool(a < b);
}

fn cmpTm(a: Tm, b: Tm) i32 {
    const fields = [_][2]i64{ .{ a.year, b.year }, .{ a.mon, b.mon }, .{ a.mday, b.mday }, .{ a.hour, b.hour }, .{ a.min, b.min }, .{ a.sec, b.sec } };
    for (fields) |p| {
        const r = cmp3(p[0], p[1]);
        if (r != 0) return r;
    }
    return 0;
}

fn withinBounds(clock: *Clock, tm: *Tm) Bounds {
    if (tm.year + 1900 > max_year) return .err;
    var t = tm.*;
    _ = clock.mktimeChecked(&t) catch return .err;

    const cmp: i32 = blk: {
        if (t.year != tm.year) {
            const r = cmp3(t.year, tm.year);
            t.mon = 0;
            t.mday = 1;
            break :blk r;
        } else if (t.mon != tm.mon) {
            t.mday = 1;
            break :blk cmp3(t.mon, tm.mon);
        } else if (t.mday != tm.mday) {
            t.hour = 0;
            break :blk cmp3(t.mday, tm.mday);
        } else if (t.hour != tm.hour) {
            t.min = 0;
            break :blk cmp3(t.hour, tm.hour);
        } else if (t.min != tm.min) {
            t.sec = 0;
            break :blk cmp3(t.min, tm.min);
        } else break :blk cmp3(t.sec, tm.sec);
    };
    if (cmp < 0) return .err;
    if (cmp > 0) tm.* = t;
    return if (cmp == 0) .ok else .changed;
}

fn matchesWeekday(spec: Spec, clock: *Clock, tm: Tm) bool {
    if (spec.weekdays_bits < 0 or spec.weekdays_bits >= 127) return true;
    var t = tm;
    _ = clock.mktimeChecked(&t) catch return false;
    const k: u5 = @intCast(if (t.wday == 0) 6 else t.wday - 1);
    return spec.weekdays_bits & (@as(i32, 1) << k) != 0;
}

/// Day of the month that is the `day`-th last one in `tm`'s month, or -1.
fn findEndOfMonth(clock: *Clock, tm: Tm, day: i64) i64 {
    var t = tm;
    t.mon += 1;
    t.mday = 1 - day;
    _ = clock.mktimeChecked(&t) catch return -1;
    if (t.mon != tm.mon) return -1;
    return t.mday;
}

fn divRoundUp(a: i64, b: i64) i64 {
    return @divFloor(a + b - 1, b);
}

/// Earliest value in `items` that is at least `val`. Null when there is none; otherwise whether
/// `val` moved.
fn findMatching(clock: *Clock, items: []const Component, end_of_month: bool, tm: Tm, val: *i64) ?bool {
    if (items.len == 0) return false;
    var d: i64 = -1;
    var d_set = false;
    for (items) |c| {
        var start: i64 = undefined;
        var stop: i64 = undefined;
        if (end_of_month) {
            start = findEndOfMonth(clock, tm, c.start);
            stop = findEndOfMonth(clock, tm, c.stop);
            if (stop > 0) std.mem.swap(i64, &start, &stop);
        } else {
            start = c.start;
            stop = c.stop;
        }
        if (start >= val.*) {
            if (!d_set or start < d) {
                d = start;
                d_set = true;
            }
        } else if (c.repeat > 0) {
            const k = start + divRoundUp(val.* - start, c.repeat) * c.repeat;
            if ((!d_set or k < d) and (stop < 0 or k <= stop)) {
                d = k;
                d_set = true;
            }
        }
    }
    if (!d_set) return null;
    const changed = val.* != d;
    val.* = d;
    return changed;
}

const Level = enum { year, month, day, hour, minute };

/// Resets every field below `level` to its minimum.
fn resetBelow(c: *Tm, tm_usec: *i64, level: Level) void {
    switch (level) {
        .year => {
            c.mon = 0;
            c.mday = 1;
            c.hour = 0;
            c.min = 0;
            c.sec = 0;
        },
        .month => {
            c.mday = 1;
            c.hour = 0;
            c.min = 0;
            c.sec = 0;
        },
        .day => {
            c.hour = 0;
            c.min = 0;
            c.sec = 0;
        },
        .hour => {
            c.min = 0;
            c.sec = 0;
        },
        .minute => c.sec = 0,
    }
    tm_usec.* = 0;
}

fn findNext(spec: Spec, clock: *Clock, tm: *Tm, usec: *i64) error{NoEntry}!void {
    var c = tm.*;
    var tm_usec = usec.*;
    var invalidate_dst = false;
    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        // Normalizes the fields only; an out-of-range year is rejected by findMatching below.
        _ = clock.mktimeChecked(&c) catch |e| switch (e) {
            error.Range => {},
        };
        if (!invalidate_dst) c.isdst = spec.dst;

        var year = c.year + 1900;
        const year_changed = findMatching(clock, spec.year, false, c, &year) orelse return error.NoEntry;
        c.year = year - 1900;
        if (year_changed) resetBelow(&c, &tm_usec, .year);
        if (@backingInt(withinBounds(clock, &c)) <= 0) return error.NoEntry;

        var r: Bounds = .err;
        var mon = c.mon + 1;
        if (findMatching(clock, spec.month, false, c, &mon)) |changed| {
            c.mon = mon - 1;
            if (changed) resetBelow(&c, &tm_usec, .month);
            r = withinBounds(clock, &c);
        }
        if (r == .err) {
            c.year += 1;
            resetBelow(&c, &tm_usec, .year);
            continue;
        }
        if (r == .changed) continue;

        r = .err;
        var mday = c.mday;
        if (findMatching(clock, spec.day, spec.end_of_month, c, &mday)) |changed| {
            c.mday = mday;
            if (changed) resetBelow(&c, &tm_usec, .day);
            r = withinBounds(clock, &c);
        }
        if (r == .err) {
            c.mon += 1;
            resetBelow(&c, &tm_usec, .month);
            continue;
        }
        if (r == .changed) continue;

        if (!matchesWeekday(spec, clock, c)) {
            c.mday += 1;
            resetBelow(&c, &tm_usec, .day);
            continue;
        }

        r = .err;
        var hour = c.hour;
        if (findMatching(clock, spec.hour, false, c, &hour)) |changed| {
            c.hour = hour;
            if (changed) resetBelow(&c, &tm_usec, .hour);
            r = withinBounds(clock, &c);
        }
        if (r == .err) {
            c.mday += 1;
            resetBelow(&c, &tm_usec, .day);
            continue;
        }
        if (r == .changed) continue;

        r = .err;
        var minute = c.min;
        if (findMatching(clock, spec.minute, false, c, &minute)) |changed| {
            c.min = minute;
            if (changed) resetBelow(&c, &tm_usec, .minute);
            r = withinBounds(clock, &c);
        }
        if (r == .err) {
            c.hour += 1;
            c.min = 0;
            c.sec = 0;
            tm_usec = 0;
            continue;
        }
        if (r == .changed) continue;

        r = .err;
        var us = c.sec * usec_per_sec + tm_usec;
        if (findMatching(clock, spec.microsecond, false, c, &us) != null) {
            c.sec = @divFloor(us, usec_per_sec);
            tm_usec = @mod(us, usec_per_sec);
            r = withinBounds(clock, &c);
        } else {
            c.sec = @divFloor(us, usec_per_sec);
            tm_usec = @mod(us, usec_per_sec);
        }
        if (r == .err) {
            c.min += 1;
            c.sec = 0;
            tm_usec = 0;
            continue;
        }
        if (r == .changed) continue;

        // The result must lie after the input; otherwise skip an hour and let mktime settle DST.
        var stuck = cmpTm(tm.*, c);
        if (stuck == 0) stuck = cmp3(usec.*, tm_usec + 1);
        if (stuck >= 0) {
            invalidate_dst = true;
            c.hour += 1;
            continue;
        }

        tm.* = c;
        usec.* = tm_usec;
        return;
    }
    return error.NoEntry;
}

/// First elapse strictly after `after_usec` (Unix microseconds), or null when the expression
/// never elapses again. `tz` is the zone named by `spec.timezone`, or the local zone when the
/// spec names none; it is ignored for UTC specs.
pub fn next(spec: Spec, tz: *const Tz, after_usec: i64) ?i64 {
    if (after_usec > formattable_max) return null;
    const usec = after_usec + 1;
    var clock: Clock = .{ .zone = tz, .utc = spec.utc };
    var tm = clock.localtime(@divFloor(usec, usec_per_sec));
    var tm_usec = @mod(usec, usec_per_sec);
    findNext(spec, &clock, &tm, &tm_usec) catch return null;
    const t = clock.mktimeChecked(&tm) catch return null;
    return t * usec_per_sec + tm_usec;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn expectNormalized(text: []const u8, expected: []const u8) !void {
    var spec = try parse(testing.allocator, text);
    defer spec.deinit(testing.allocator);
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try normalized(spec, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "normalized forms match systemd-analyze" {
    try expectNormalized("daily", "*-*-* 00:00:00");
    try expectNormalized("weekly", "Mon *-*-* 00:00:00");
    try expectNormalized("quarterly", "*-01,04,07,10-01 00:00:00");
    try expectNormalized("*:0/20", "*-*-* *:00/20:00");
    try expectNormalized("Mon..Fri,Sat 2026-*~03 *:*", "Mon..Sat 2026-*~03 *:*:00");
    try expectNormalized("*-*-* *:*:0/15.5", "*-*-* *:*:00/15.500000");
    try expectNormalized("3,1,2:00", "*-*-* 01,02,03:00:00");
    try expectNormalized("Mon *-*-* 10:00 Europe/Rome", "Mon *-*-* 10:00:00 Europe/Rome");
    try expectNormalized("daily utc", "*-*-* 00:00:00 UTC");
}

test "invalid expressions are rejected" {
    const bad = [_][]const u8{ "foo", "Fri..Mon *-*-* *:*", "*-*-* 24:00", "*-*-*/5 *:*:*", "Sun..Tue,Thu", "", "tomorrow" };
    for (bad) |text| try testing.expectError(error.InvalidCalendar, parse(testing.allocator, text));
}

const rome_fat = @embedFile("../exec/testdata/rome_fat.tzif");

test "next honors the zone and skips a nonexistent local time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rome = try Tz.parse(arena.allocator(), rome_fat);
    var spec = try parse(testing.allocator, "Sun *-*-* 02:30:00");
    defer spec.deinit(testing.allocator);
    // 2026-03-28 12:00:00 UTC; Sunday 2026-03-29 02:30 does not exist in Rome.
    const got = next(spec, &rome, 1774699200 * usec_per_sec).?;
    try testing.expectEqual(@as(i64, 1775349000) * usec_per_sec, got);
}
