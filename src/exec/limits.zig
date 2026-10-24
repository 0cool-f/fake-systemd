//! `Limit*=` settings translated to `setrlimit` arguments (systemd.exec(5), "Limit*=").
const std = @import("std");
const linux = std.os.linux;
const timespan = @import("../unit/timespan.zig");

pub const Limit = struct {
    resource: linux.rlimit_resource,
    soft: u64,
    hard: u64,
};

pub const Error = error{InvalidLimit};

pub const infinity = std.math.maxInt(u64);

/// `key` is the directive name (`LimitNOFILE`). `value` is one number for both limits or
/// `soft:hard`; each is a plain number, a number with a binary suffix (K, M, G, T, P, E) or
/// `infinity`. `LimitCPU` accepts timespans in seconds and `LimitRTTIME` in microseconds.
pub fn parse(key: []const u8, value: []const u8) Error!Limit {
    if (!std.mem.startsWith(u8, key, "Limit")) return error.InvalidLimit;
    const resource = std.meta.stringToEnum(linux.rlimit_resource, key["Limit".len..]) orelse return error.InvalidLimit;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, value, " \t"), ':');
    const first = parts.next() orelse return error.InvalidLimit;
    const second = parts.next();
    if (parts.next() != null) return error.InvalidLimit;
    const soft = try parseValue(resource, first);
    const hard = if (second) |s| try parseValue(resource, s) else soft;
    if (soft > hard) return error.InvalidLimit;
    return .{ .resource = resource, .soft = soft, .hard = hard };
}

fn parseValue(resource: linux.rlimit_resource, text: []const u8) Error!u64 {
    const t = std.mem.trim(u8, text, " \t");
    if (std.mem.eql(u8, t, "infinity")) return infinity;
    switch (resource) {
        .CPU => {
            const usec = timespan.parse(t) catch return error.InvalidLimit;
            return if (usec == timespan.infinity) infinity else (usec + std.time.us_per_s - 1) / std.time.us_per_s;
        },
        .RTTIME => {
            const usec = timespan.parseWithDefault(t, 1) catch return error.InvalidLimit;
            return if (usec == timespan.infinity) infinity else usec;
        },
        else => {},
    }
    if (t.len == 0) return error.InvalidLimit;
    var number = t;
    var shift: u6 = 0;
    switch (t[t.len - 1]) {
        'K' => shift = 10,
        'M' => shift = 20,
        'G' => shift = 30,
        'T' => shift = 40,
        'P' => shift = 50,
        'E' => shift = 60,
        else => {},
    }
    if (shift != 0) number = t[0 .. t.len - 1];
    const n = std.fmt.parseInt(u64, number, 10) catch return error.InvalidLimit;
    return std.math.shlExact(u64, n, shift) catch error.InvalidLimit;
}

test "single value sets both limits" {
    const l = try parse("LimitNOFILE", "65536");
    try std.testing.expectEqual(linux.rlimit_resource.NOFILE, l.resource);
    try std.testing.expectEqual(@as(u64, 65536), l.soft);
    try std.testing.expectEqual(@as(u64, 65536), l.hard);
}

test "soft and hard, infinity and suffixes" {
    const a = try parse("LimitCORE", "0:infinity");
    try std.testing.expectEqual(@as(u64, 0), a.soft);
    try std.testing.expectEqual(infinity, a.hard);
    const b = try parse("LimitMEMLOCK", "64M");
    try std.testing.expectEqual(@as(u64, 64 << 20), b.soft);
    const c = try parse("LimitAS", "infinity");
    try std.testing.expectEqual(infinity, c.soft);
}

test "time limits" {
    const cpu = try parse("LimitCPU", "2min");
    try std.testing.expectEqual(@as(u64, 120), cpu.soft);
    const rt = try parse("LimitRTTIME", "500");
    try std.testing.expectEqual(@as(u64, 500), rt.soft);
}

test "invalid limits" {
    try std.testing.expectError(error.InvalidLimit, parse("LimitBOGUS", "1"));
    try std.testing.expectError(error.InvalidLimit, parse("LimitNOFILE", "abc"));
    try std.testing.expectError(error.InvalidLimit, parse("LimitNOFILE", "10:5"));
    try std.testing.expectError(error.InvalidLimit, parse("LimitNOFILE", "1:2:3"));
    try std.testing.expectError(error.InvalidLimit, parse("LimitNOFILE", ""));
    try std.testing.expectError(error.InvalidLimit, parse("Foo", "1"));
}
