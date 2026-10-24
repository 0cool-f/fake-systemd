//! systemd time spans (`5min 3s`, `1h30m`, `infinity`) as microseconds.
const std = @import("std");

pub const infinity: u64 = std.math.maxInt(u64);

pub const usec_per_sec: u64 = 1_000_000;

pub const Error = error{ InvalidTimespan, Overflow };

const Unit = struct { name: []const u8, usec: u64 };

const units = [_]Unit{
    .{ .name = "usec", .usec = 1 },
    .{ .name = "us", .usec = 1 },
    .{ .name = "\u{b5}s", .usec = 1 },
    .{ .name = "\u{3bc}s", .usec = 1 },
    .{ .name = "msec", .usec = 1000 },
    .{ .name = "ms", .usec = 1000 },
    .{ .name = "seconds", .usec = usec_per_sec },
    .{ .name = "second", .usec = usec_per_sec },
    .{ .name = "sec", .usec = usec_per_sec },
    .{ .name = "s", .usec = usec_per_sec },
    .{ .name = "minutes", .usec = 60 * usec_per_sec },
    .{ .name = "minute", .usec = 60 * usec_per_sec },
    .{ .name = "min", .usec = 60 * usec_per_sec },
    .{ .name = "m", .usec = 60 * usec_per_sec },
    .{ .name = "hours", .usec = 3600 * usec_per_sec },
    .{ .name = "hour", .usec = 3600 * usec_per_sec },
    .{ .name = "hr", .usec = 3600 * usec_per_sec },
    .{ .name = "h", .usec = 3600 * usec_per_sec },
    .{ .name = "days", .usec = 86400 * usec_per_sec },
    .{ .name = "day", .usec = 86400 * usec_per_sec },
    .{ .name = "d", .usec = 86400 * usec_per_sec },
    .{ .name = "weeks", .usec = 7 * 86400 * usec_per_sec },
    .{ .name = "week", .usec = 7 * 86400 * usec_per_sec },
    .{ .name = "w", .usec = 7 * 86400 * usec_per_sec },
    .{ .name = "months", .usec = 2629800 * usec_per_sec },
    .{ .name = "month", .usec = 2629800 * usec_per_sec },
    .{ .name = "M", .usec = 2629800 * usec_per_sec },
    .{ .name = "years", .usec = 31557600 * usec_per_sec },
    .{ .name = "year", .usec = 31557600 * usec_per_sec },
    .{ .name = "y", .usec = 31557600 * usec_per_sec },
};

/// Parses `text` with seconds as the unit of a bare number.
pub fn parse(text: []const u8) Error!u64 {
    return parseWithDefault(text, usec_per_sec);
}

/// A bare number, which must be the last component, counts `default_unit_usec` each.
pub fn parseWithDefault(text: []const u8, default_unit_usec: u64) Error!u64 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return error.InvalidTimespan;
    if (std.mem.eql(u8, s, "infinity")) return infinity;

    var total: u128 = 0;
    var i: usize = 0;
    while (true) {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len) break;

        const int_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        const int_digits = s[int_start..i];
        var frac_digits: []const u8 = "";
        if (i < s.len and s[i] == '.') {
            i += 1;
            const frac_start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            frac_digits = s[frac_start..i];
        }
        if (int_digits.len == 0 and frac_digits.len == 0) return error.InvalidTimespan;

        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        var mult = default_unit_usec;
        var bare = true;
        var best: usize = 0;
        for (units) |u| {
            if (u.name.len > best and std.mem.startsWith(u8, s[i..], u.name)) {
                best = u.name.len;
                mult = u.usec;
                bare = false;
            }
        }
        i += best;
        if (bare and i < s.len) return error.InvalidTimespan;

        total += try scale(int_digits, frac_digits, mult);
        if (total >= infinity) return error.Overflow;
    }
    return @intCast(total);
}

fn scale(int_digits: []const u8, frac_digits: []const u8, mult: u64) Error!u128 {
    var value: u128 = 0;
    if (int_digits.len > 0) {
        const n = std.fmt.parseInt(u64, int_digits, 10) catch return error.Overflow;
        value = std.math.mul(u128, n, mult) catch return error.Overflow;
    }
    if (frac_digits.len > 0) {
        const use = frac_digits[0..@min(frac_digits.len, 18)];
        const f = std.fmt.parseInt(u64, use, 10) catch return error.InvalidTimespan;
        const div = std.math.pow(u128, 10, use.len);
        value += (@as(u128, f) * mult) / div;
    }
    return value;
}

const testing = std.testing;

test "single components and bare numbers" {
    try testing.expectEqual(@as(u64, 5_000_000), try parse("5"));
    try testing.expectEqual(@as(u64, 5_000_000), try parse("5s"));
    try testing.expectEqual(@as(u64, 5_000_000), try parse("5sec"));
    try testing.expectEqual(@as(u64, 300_000_000), try parse("5min"));
    try testing.expectEqual(@as(u64, 300_000_000), try parse("5m"));
    try testing.expectEqual(@as(u64, 3600_000_000), try parse("1h"));
    try testing.expectEqual(@as(u64, 86400_000_000), try parse("1day"));
    try testing.expectEqual(@as(u64, 7 * 86400_000_000), try parse("1w"));
    try testing.expectEqual(@as(u64, 2629800_000_000), try parse("1M"));
    try testing.expectEqual(@as(u64, 31557600_000_000), try parse("1y"));
    try testing.expectEqual(@as(u64, 250_000), try parse("250ms"));
    try testing.expectEqual(@as(u64, 7), try parse("7us"));
    try testing.expectEqual(@as(u64, 7), try parse("7\u{b5}s"));
    try testing.expectEqual(@as(u64, 7), try parse("7\u{3bc}s"));
    try testing.expectEqual(@as(u64, 0), try parse("0"));
}

test "combined components with and without spaces" {
    try testing.expectEqual(@as(u64, 303_000_000), try parse("5min 3s"));
    try testing.expectEqual(@as(u64, 5400_000_000), try parse("1h30m"));
    try testing.expectEqual(@as(u64, 5400_000_000), try parse("1h 30 min"));
    try testing.expectEqual(@as(u64, 90_000_000), try parse("1min 30"));
    try testing.expectEqual(@as(u64, 1_500_000), try parse("1s500ms"));
}

test "month and minute are distinguished by case" {
    try testing.expectEqual(@as(u64, 60_000_000), try parse("1m"));
    try testing.expectEqual(@as(u64, 2629800_000_000), try parse("1M"));
    try testing.expectEqual(@as(u64, 1000), try parse("1ms"));
}

test "fractions" {
    try testing.expectEqual(@as(u64, 1_500_000), try parse("1.5s"));
    try testing.expectEqual(@as(u64, 90_000_000), try parse("1.5min"));
    try testing.expectEqual(@as(u64, 500_000), try parse(".5s"));
    try testing.expectEqual(@as(u64, 2_000_000), try parse("2."));
}

test "infinity and whitespace" {
    try testing.expectEqual(infinity, try parse("infinity"));
    try testing.expectEqual(infinity, try parse("  infinity \n"));
    try testing.expectEqual(@as(u64, 3_000_000), try parse("  3s "));
}

test "custom default unit" {
    try testing.expectEqual(@as(u64, 5000), try parseWithDefault("5", 1000));
    try testing.expectEqual(@as(u64, 5_000_000), try parseWithDefault("5s", 1000));
}

test "invalid input" {
    try testing.expectError(error.InvalidTimespan, parse(""));
    try testing.expectError(error.InvalidTimespan, parse("   "));
    try testing.expectError(error.InvalidTimespan, parse("abc"));
    try testing.expectError(error.InvalidTimespan, parse("5x"));
    try testing.expectError(error.InvalidTimespan, parse("-5s"));
    try testing.expectError(error.InvalidTimespan, parse("5 3 s"));
    try testing.expectError(error.InvalidTimespan, parse("s"));
    try testing.expectError(error.InvalidTimespan, parse("."));
    try testing.expectError(error.InvalidTimespan, parse("Infinity"));
}

test "overflow" {
    try testing.expectError(error.Overflow, parse("99999999999999999999"));
    try testing.expectError(error.Overflow, parse("600000000000000y"));
}
