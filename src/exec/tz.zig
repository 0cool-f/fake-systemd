// SPDX-License-Identifier: GPL-3.0-or-later
//! Time zones: TZif (RFC 8536, versions 1 to 4) files with their POSIX TZ footer, bare POSIX TZ
//! strings, and conversions between Unix time and civil time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");

pub const Error = error{ InvalidTzif, InvalidPosixTz } || Allocator.Error;

pub const Info = struct {
    /// Seconds east of UTC.
    offset: i32,
    is_dst: bool = false,
    abbreviation: []const u8 = "UTC",
};

pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,

    /// Weekday with Sunday as 0.
    pub fn weekday(c: Civil) u8 {
        const days = daysFromCivil(c.year, c.month, c.day);
        return @intCast(@mod(days + 4, 7));
    }
};

pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @intFromBool(m <= 2);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// Civil time of the instant `unix` shifted by `offset` seconds.
pub fn civilFromUnix(unix: i64, offset: i32) Civil {
    const local = unix + offset;
    const days = @divFloor(local, 86400);
    const rem: u32 = @intCast(local - days * 86400);
    var c = civilFromDays(days);
    c.hour = @intCast(rem / 3600);
    c.minute = @intCast(rem % 3600 / 60);
    c.second = @intCast(rem % 60);
    return c;
}

/// Seconds since the epoch of `c` read as UTC.
pub fn unixFromCivil(c: Civil) i64 {
    return daysFromCivil(c.year, c.month, c.day) * 86400 + @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + c.second;
}

fn isLeap(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

/// A rule date of a POSIX TZ string.
const RuleDate = union(enum) {
    /// `Jn`: day 1 to 365, February 29 never counted.
    julian1: u16,
    /// `n`: day 0 to 365, February 29 counted.
    julian0: u16,
    /// `Mm.w.d`: weekday `d` of week `w` (5 is the last) of month `m`.
    month: struct { month: u8, week: u8, weekday: u8 },
};

const Rule = struct {
    date: RuleDate,
    /// Seconds after local midnight; may be negative or beyond a day.
    time: i32 = 7200,

    /// Seconds since the epoch of the rule's local wall time in `year`, as if that time were UTC.
    fn localSeconds(r: Rule, year: i32) i64 {
        const day: i64 = switch (r.date) {
            .julian1 => |n| blk: {
                var d: i64 = n - 1;
                if (isLeap(year) and n >= 60) d += 1;
                break :blk daysFromCivil(year, 1, 1) + d;
            },
            .julian0 => |n| daysFromCivil(year, 1, 1) + n,
            .month => |m| blk: {
                const first = daysFromCivil(year, m.month, 1);
                const first_wd: i64 = @mod(first + 4, 7);
                var d = first + @mod(@as(i64, m.weekday) - first_wd, 7) + 7 * (@as(i64, m.week) - 1);
                const last = first + daysInMonth(year, m.month) - 1;
                while (d > last) d -= 7;
                break :blk d;
            },
        };
        return day * 86400 + r.time;
    }
};

/// A parsed POSIX TZ string such as `CET-1CEST,M3.5.0,M10.5.0/3`.
pub const Posix = struct {
    std_name: []const u8,
    std_offset: i32,
    dst_name: ?[]const u8 = null,
    dst_offset: i32 = 0,
    start: Rule = .{ .date = .{ .month = .{ .month = 3, .week = 2, .weekday = 0 } } },
    end: Rule = .{ .date = .{ .month = .{ .month = 11, .week = 1, .weekday = 0 } } },

    pub fn infoAt(p: Posix, unix: i64) Info {
        const std_info: Info = .{ .offset = p.std_offset, .abbreviation = p.std_name };
        const dst_name = p.dst_name orelse return std_info;
        const dst_info: Info = .{ .offset = p.dst_offset, .is_dst = true, .abbreviation = dst_name };
        const year = civilFromUnix(unix, p.std_offset).year;
        const start = p.start.localSeconds(year) - p.std_offset;
        const end = p.end.localSeconds(year) - p.dst_offset;
        const in_dst = if (start < end) unix >= start and unix < end else unix >= start or unix < end;
        return if (in_dst) dst_info else std_info;
    }
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(p: Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn name(p: *Parser) Error![]const u8 {
        const start = p.pos;
        if (p.peek() == '<') {
            const end = std.mem.findScalarPos(u8, p.text, p.pos, '>') orelse return error.InvalidPosixTz;
            p.pos = end + 1;
            return p.text[start + 1 .. end];
        }
        while (p.peek()) |c| : (p.pos += 1) {
            if (!std.ascii.isAlphabetic(c)) break;
        }
        if (p.pos - start < 3) return error.InvalidPosixTz;
        return p.text[start..p.pos];
    }

    fn number(p: *Parser, max_digits: usize) Error!u32 {
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) {
            if (!std.ascii.isDigit(c) or p.pos - start == max_digits) break;
        }
        if (p.pos == start) return error.InvalidPosixTz;
        return std.fmt.parseInt(u32, p.text[start..p.pos], 10) catch error.InvalidPosixTz;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds.
    fn time(p: *Parser) Error!i32 {
        var sign: i32 = 1;
        if (p.peek()) |c| {
            if (c == '-' or c == '+') {
                if (c == '-') sign = -1;
                p.pos += 1;
            }
        }
        var total: i32 = @intCast(try p.number(3) * 3600);
        if (p.peek() == ':') {
            p.pos += 1;
            total += @intCast(try p.number(2) * 60);
            if (p.peek() == ':') {
                p.pos += 1;
                total += @intCast(try p.number(2));
            }
        }
        return sign * total;
    }

    fn rule(p: *Parser) Error!Rule {
        var r: Rule = .{ .date = undefined };
        switch (p.peek() orelse return error.InvalidPosixTz) {
            'J' => {
                p.pos += 1;
                const n = try p.number(3);
                if (n < 1 or n > 365) return error.InvalidPosixTz;
                r.date = .{ .julian1 = @intCast(n) };
            },
            'M' => {
                p.pos += 1;
                const m = try p.number(2);
                if (p.peek() != '.') return error.InvalidPosixTz;
                p.pos += 1;
                const w = try p.number(1);
                if (p.peek() != '.') return error.InvalidPosixTz;
                p.pos += 1;
                const d = try p.number(1);
                if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return error.InvalidPosixTz;
                r.date = .{ .month = .{ .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d) } };
            },
            else => {
                const n = try p.number(3);
                if (n > 365) return error.InvalidPosixTz;
                r.date = .{ .julian0 = @intCast(n) };
            },
        }
        if (p.peek() == '/') {
            p.pos += 1;
            r.time = try p.time();
        }
        return r;
    }
};

/// Parses a POSIX TZ string. Names borrow from `text`. A DST name without rules uses the
/// US defaults of the C library (second Sunday of March to first Sunday of November).
pub fn parsePosix(text: []const u8) Error!Posix {
    var p: Parser = .{ .text = text };
    const std_name = try p.name();
    const std_off = -(try p.time());
    var result: Posix = .{ .std_name = std_name, .std_offset = std_off };
    if (p.peek() == null) return result;
    result.dst_name = try p.name();
    result.dst_offset = result.std_offset + 3600;
    if (p.peek()) |c| {
        if (c != ',') result.dst_offset = -(try p.time());
    }
    if (p.peek() == ',') {
        p.pos += 1;
        result.start = try p.rule();
        if (p.peek() != ',') return error.InvalidPosixTz;
        p.pos += 1;
        result.end = try p.rule();
    }
    if (p.peek() != null) return error.InvalidPosixTz;
    return result;
}

pub const LocalType = struct {
    offset: i32,
    is_dst: bool,
    abbreviation: []const u8,
};

pub const Tz = struct {
    transitions: []const i64 = &.{},
    /// Index into `types` per transition.
    indices: []const u8 = &.{},
    types: []const LocalType = &.{},
    footer: ?Posix = null,

    pub const utc: Tz = .{ .types = &.{.{ .offset = 0, .is_dst = false, .abbreviation = "UTC" }} };

    /// Parses a TZif file. Everything the result references is allocated with `gpa`, which is
    /// expected to be an arena.
    pub fn parse(gpa: Allocator, bytes: []const u8) Error!Tz {
        var offset: usize = 0;
        var header = try Header.read(bytes, offset);
        var time_size: usize = 4;
        if (header.version >= '2') {
            offset += header.dataLen(4) + Header.len;
            header = try Header.read(bytes, offset);
            time_size = 8;
        }
        const data_start = offset + Header.len;
        if (bytes.len < data_start + header.dataLen(time_size)) return error.InvalidTzif;
        if (header.typecnt == 0) return error.InvalidTzif;
        var pos = data_start;

        const transitions = try gpa.alloc(i64, header.timecnt);
        for (transitions) |*t| {
            t.* = if (time_size == 8)
                std.mem.readInt(i64, bytes[pos..][0..8], .big)
            else
                std.mem.readInt(i32, bytes[pos..][0..4], .big);
            pos += time_size;
        }
        const indices = try gpa.dupe(u8, bytes[pos..][0..header.timecnt]);
        pos += header.timecnt;
        const raw_types = bytes[pos..][0 .. header.typecnt * 6];
        pos += header.typecnt * 6;
        const chars = bytes[pos..][0..header.charcnt];
        pos += header.charcnt;
        pos += header.leapcnt * (time_size + 4) + header.isstdcnt + header.isutcnt;

        const types = try gpa.alloc(LocalType, header.typecnt);
        for (types, 0..) |*t, i| {
            const raw = raw_types[i * 6 ..][0..6];
            const abbr_start: usize = raw[5];
            if (abbr_start >= chars.len) return error.InvalidTzif;
            const abbr_end = std.mem.findScalarPos(u8, chars, abbr_start, 0) orelse chars.len;
            t.* = .{
                .offset = std.mem.readInt(i32, raw[0..4], .big),
                .is_dst = raw[4] != 0,
                .abbreviation = try gpa.dupe(u8, chars[abbr_start..abbr_end]),
            };
        }
        for (indices) |i| if (i >= types.len) return error.InvalidTzif;

        var footer: ?Posix = null;
        if (header.version >= '2' and pos < bytes.len and bytes[pos] == '\n') {
            const rest = bytes[pos + 1 ..];
            const end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
            if (end > 0) footer = parsePosix(try gpa.dupe(u8, rest[0..end])) catch null;
        }
        return .{ .transitions = transitions, .indices = indices, .types = types, .footer = footer };
    }

    pub fn infoAt(tz: Tz, unix: i64) Info {
        if (tz.transitions.len == 0 or unix < tz.transitions[0]) {
            if (tz.transitions.len == 0) {
                if (tz.footer) |f| return f.infoAt(unix);
            }
            return typeInfo(tz.firstStandardType());
        }
        const last = tz.transitions.len - 1;
        if (unix >= tz.transitions[last]) {
            if (tz.footer) |f| return f.infoAt(unix);
            return typeInfo(tz.types[tz.indices[last]]);
        }
        var lo: usize = 0;
        var hi: usize = last;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (tz.transitions[mid] <= unix) lo = mid else hi = mid - 1;
        }
        return typeInfo(tz.types[tz.indices[lo]]);
    }

    fn firstStandardType(tz: Tz) LocalType {
        for (tz.types) |t| if (!t.is_dst) return t;
        return tz.types[0];
    }

    /// UTC offset in seconds at the instant `unix`.
    pub fn offsetAt(tz: Tz, unix: i64) i32 {
        return tz.infoAt(unix).offset;
    }

    /// Instant whose local wall clock reads `local` (seconds as if UTC). In the repeated hour
    /// of a backward shift the first occurrence wins; in a skipped hour the standard offset
    /// before the shift applies.
    pub fn unixFromLocal(tz: Tz, local: i64) i64 {
        const before = tz.offsetAt(local - 86400);
        const after = tz.offsetAt(local + 86400);
        const first = local - before;
        if (tz.offsetAt(first) == before) return first;
        const second = local - after;
        if (tz.offsetAt(second) == after) return second;
        return first;
    }
};

fn typeInfo(t: LocalType) Info {
    return .{ .offset = t.offset, .is_dst = t.is_dst, .abbreviation = t.abbreviation };
}

const Header = struct {
    version: u8,
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,

    const len = 44;

    fn read(bytes: []const u8, at: usize) Error!Header {
        if (bytes.len < at + len) return error.InvalidTzif;
        const h = bytes[at..][0..len];
        if (!std.mem.eql(u8, h[0..4], "TZif")) return error.InvalidTzif;
        var counts: [6]u32 = undefined;
        for (&counts, 0..) |*c, i| c.* = std.mem.readInt(u32, h[20 + i * 4 ..][0..4], .big);
        return .{
            .version = if (h[4] == 0) '1' else h[4],
            .isutcnt = counts[0],
            .isstdcnt = counts[1],
            .leapcnt = counts[2],
            .timecnt = counts[3],
            .typecnt = counts[4],
            .charcnt = counts[5],
        };
    }

    fn dataLen(h: Header, time_size: usize) usize {
        return @as(usize, h.timecnt) * (time_size + 1) + @as(usize, h.typecnt) * 6 + h.charcnt +
            @as(usize, h.leapcnt) * (time_size + 4) + h.isstdcnt + h.isutcnt;
    }
};

const zoneinfo_dir = "/usr/share/zoneinfo";

/// The local zone as the C library finds it: `TZ` (a zoneinfo name, an absolute path or a POSIX
/// string), else `/etc/localtime`. Falls back to UTC when nothing is readable or valid.
pub fn loadLocal(gpa: Allocator, fs: Fs, environ: *const std.process.Environ.Map) Tz {
    if (environ.get("TZ")) |raw| {
        const spec = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        if (spec.len == 0) return .utc;
        if (loadNamed(gpa, fs, spec)) |tz| return tz;
        const owned = gpa.dupe(u8, spec) catch return .utc;
        return fromPosixOwned(gpa, owned) orelse .utc;
    }
    return loadFile(gpa, fs, "/etc/localtime") orelse .utc;
}

fn fromPosixOwned(gpa: Allocator, text: []const u8) ?Tz {
    const p = parsePosix(text) catch return null;
    const types = gpa.alloc(LocalType, 1) catch return null;
    types[0] = .{ .offset = p.std_offset, .is_dst = false, .abbreviation = p.std_name };
    return .{ .types = types, .footer = p };
}

/// A zone by name (below `/usr/share/zoneinfo`) or by absolute path; null when unreadable or invalid.
pub fn loadNamed(gpa: Allocator, fs: Fs, spec: []const u8) ?Tz {
    if (std.mem.findScalar(u8, spec, '/') != null and spec[0] == '/') return loadFile(gpa, fs, spec);
    if (std.mem.find(u8, spec, "..") != null) return null;
    const path = std.fs.path.join(gpa, &.{ zoneinfo_dir, spec }) catch return null;
    return loadFile(gpa, fs, path);
}

fn loadFile(gpa: Allocator, fs: Fs, path: []const u8) ?Tz {
    const bytes = fs.readFileAlloc(gpa, path, 1 << 20) catch return null;
    return Tz.parse(gpa, bytes) catch null;
}

const rome_slim = @embedFile("testdata/rome_slim.tzif");
const rome_fat = @embedFile("testdata/rome_fat.tzif");

fn expectOffsetAt(tz: Tz, civil: Civil, utc_offset: i32, expected: i32) !void {
    const unix = unixFromCivil(civil) - utc_offset;
    try std.testing.expectEqual(expected, tz.offsetAt(unix));
}

test "civil conversions round trip" {
    const c = civilFromUnix(1_793_000_000, 0);
    try std.testing.expectEqual(unixFromCivil(c), 1_793_000_000);
    try std.testing.expectEqual(@as(u8, 4), (Civil{ .year = 2026, .month = 10, .day = 22 }).weekday());
    const leap = civilFromDays(daysFromCivil(2024, 2, 29));
    try std.testing.expectEqual(@as(u8, 29), leap.day);
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const neg = civilFromUnix(-1, 3600);
    try std.testing.expectEqual(@as(u8, 59), neg.minute);
    try std.testing.expectEqual(@as(i32, 1970), neg.year);
}

test "POSIX TZ strings" {
    const rome = try parsePosix("CET-1CEST,M3.5.0,M10.5.0/3");
    try std.testing.expectEqualStrings("CET", rome.std_name);
    try std.testing.expectEqual(@as(i32, 3600), rome.std_offset);
    try std.testing.expectEqual(@as(i32, 7200), rome.dst_offset);
    try std.testing.expectEqual(@as(i32, 3600), rome.infoAt(unixFromCivil(.{ .year = 2026, .month = 1, .day = 15 })).offset);
    try std.testing.expectEqual(@as(i32, 7200), rome.infoAt(unixFromCivil(.{ .year = 2026, .month = 7, .day = 15 })).offset);
    // 2026-03-29 01:00 UTC is the instant of the spring-forward change.
    const change = unixFromCivil(.{ .year = 2026, .month = 3, .day = 29, .hour = 1 });
    try std.testing.expectEqual(@as(i32, 3600), rome.infoAt(change - 1).offset);
    try std.testing.expectEqual(@as(i32, 7200), rome.infoAt(change).offset);
    const back = unixFromCivil(.{ .year = 2026, .month = 10, .day = 25, .hour = 1 });
    try std.testing.expectEqual(@as(i32, 7200), rome.infoAt(back - 1).offset);
    try std.testing.expectEqual(@as(i32, 3600), rome.infoAt(back).offset);

    const ny = try parsePosix("EST5EDT,M3.2.0,M11.1.0");
    try std.testing.expectEqual(@as(i32, -14400), ny.infoAt(unixFromCivil(.{ .year = 2026, .month = 7, .day = 1 })).offset);
    const sydney = try parsePosix("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try std.testing.expectEqual(@as(i32, 39600), sydney.infoAt(unixFromCivil(.{ .year = 2026, .month = 12, .day = 25 })).offset);
    try std.testing.expectEqual(@as(i32, 36000), sydney.infoAt(unixFromCivil(.{ .year = 2026, .month = 6, .day = 25 })).offset);

    const fixed = try parsePosix("<+0530>-5:30");
    try std.testing.expectEqualStrings("+0530", fixed.std_name);
    try std.testing.expectEqual(@as(i32, 19800), fixed.infoAt(0).offset);
    const julian = try parsePosix("AAA3BBB,J60,J300");
    try std.testing.expectEqual(@as(i32, -7200), julian.infoAt(unixFromCivil(.{ .year = 2026, .month = 7, .day = 1 })).offset);

    try std.testing.expectError(error.InvalidPosixTz, parsePosix(""));
    try std.testing.expectError(error.InvalidPosixTz, parsePosix("CET-1CEST,M13.5.0,M10.5.0"));
    try std.testing.expectError(error.InvalidPosixTz, parsePosix("CET-1garbage!"));
}

test "TZif v2 slim file uses the footer for current dates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tz = try Tz.parse(arena.allocator(), rome_slim);
    try std.testing.expect(tz.footer != null);
    try expectOffsetAt(tz, .{ .year = 2026, .month = 1, .day = 10 }, 0, 3600);
    try expectOffsetAt(tz, .{ .year = 2026, .month = 8, .day = 10 }, 0, 7200);
    try expectOffsetAt(tz, .{ .year = 2051, .month = 8, .day = 10 }, 0, 7200);
    try std.testing.expectEqualStrings("CEST", tz.infoAt(unixFromCivil(.{ .year = 2026, .month = 8, .day = 10 })).abbreviation);
}

test "TZif fat file has transitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tz = try Tz.parse(arena.allocator(), rome_fat);
    try std.testing.expect(tz.transitions.len > 10);
    try expectOffsetAt(tz, .{ .year = 2000, .month = 1, .day = 10 }, 0, 3600);
    try expectOffsetAt(tz, .{ .year = 2000, .month = 7, .day = 10 }, 0, 7200);
    try expectOffsetAt(tz, .{ .year = 1975, .month = 7, .day = 10 }, 0, 7200);
    try expectOffsetAt(tz, .{ .year = 2026, .month = 7, .day = 10 }, 0, 7200);
    const change = unixFromCivil(.{ .year = 1990, .month = 3, .day = 25, .hour = 1 });
    try std.testing.expectEqual(@as(i32, 3600), tz.offsetAt(change - 1));
    try std.testing.expectEqual(@as(i32, 7200), tz.offsetAt(change));
}

test "local to UTC conversion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tz = try Tz.parse(arena.allocator(), rome_slim);
    const summer = unixFromCivil(.{ .year = 2026, .month = 7, .day = 1, .hour = 12 });
    try std.testing.expectEqual(summer - 7200, tz.unixFromLocal(summer));
    const winter = unixFromCivil(.{ .year = 2026, .month = 1, .day = 1, .hour = 12 });
    try std.testing.expectEqual(winter - 3600, tz.unixFromLocal(winter));
    // 02:30 on the last Sunday of October happens twice; the first one is CEST.
    const ambiguous = unixFromCivil(.{ .year = 2026, .month = 10, .day = 25, .hour = 2, .minute = 30 });
    try std.testing.expectEqual(ambiguous - 7200, tz.unixFromLocal(ambiguous));
}

test "invalid TZif data is rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidTzif, Tz.parse(arena.allocator(), "nope"));
    try std.testing.expectError(error.InvalidTzif, Tz.parse(arena.allocator(), rome_slim[0..30]));
    try std.testing.expectError(error.InvalidTzif, Tz.parse(arena.allocator(), rome_slim[0 .. rome_slim.len / 2]));
}

test "TZ environment variable selects the zone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: Fs = .initDir(std.testing.io, tmp.dir);
    try fs.makePath("/etc");
    try fs.makePath("/usr/share/zoneinfo/Test");
    try fs.writeFileAtomic("/etc/localtime", rome_slim, 0o644);
    try fs.writeFileAtomic("/usr/share/zoneinfo/Test/Rome", rome_slim, 0o644);
    const july = unixFromCivil(.{ .year = 2026, .month = 7, .day = 1 });

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(i32, 7200), loadLocal(gpa, fs, &env).offsetAt(july));
    try env.put("TZ", ":Test/Rome");
    try std.testing.expectEqual(@as(i32, 7200), loadLocal(gpa, fs, &env).offsetAt(july));
    try env.put("TZ", "UTC");
    try std.testing.expectEqual(@as(i32, 0), loadLocal(gpa, fs, &env).offsetAt(july));
    try env.put("TZ", "XXX-3");
    try std.testing.expectEqual(@as(i32, 10800), loadLocal(gpa, fs, &env).offsetAt(july));
    try env.put("TZ", "");
    try std.testing.expectEqual(@as(i32, 0), loadLocal(gpa, fs, &env).offsetAt(july));
}
