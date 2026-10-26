// SPDX-License-Identifier: GPL-3.0-or-later
//! Reader of the resolve file 66 writes for a parsed service: a constant database (djb cdb, as
//! skalibs writes it) whose keys are the field names of `66 resolve` (`enabled`, `frontend`).
//! Numbers are stored as four bytes in network order; a string is the offset of a NUL-terminated
//! string in the area stored under `sa`.
const std = @import("std");

const header_bytes = 2048;

fn le32(data: []const u8, pos: usize) ?u32 {
    if (pos + 4 > data.len) return null;
    return std.mem.readInt(u32, data[pos..][0..4], .little);
}

fn hashOf(key: []const u8) u32 {
    var h: u32 = 5381;
    for (key) |c| h = ((h << 5) +% h) ^ c;
    return h;
}

/// Raw value stored under `key`, or null when the database has none or is malformed.
pub fn lookup(data: []const u8, key: []const u8) ?[]const u8 {
    if (data.len < header_bytes) return null;
    const h = hashOf(key);
    const slot = (h & 255) * 8;
    const table = le32(data, slot) orelse return null;
    const count = le32(data, slot + 4) orelse return null;
    if (count == 0) return null;
    var i: u32 = (h >> 8) % count;
    var probed: u32 = 0;
    while (probed < count) : (probed += 1) {
        const at = @as(usize, table) + @as(usize, i) * 8;
        const entry_hash = le32(data, at) orelse return null;
        const record = le32(data, at + 4) orelse return null;
        if (record == 0) return null;
        if (entry_hash == h) {
            const klen = le32(data, record) orelse return null;
            const dlen = le32(data, record + 4) orelse return null;
            const key_end = @as(usize, record) + 8 + klen;
            const end = key_end + dlen;
            if (end > data.len) return null;
            if (std.mem.eql(u8, data[record + 8 .. key_end], key)) return data[key_end..end];
        }
        i = (i + 1) % count;
    }
    return null;
}

/// A number field, null when absent or not four bytes.
pub fn number(data: []const u8, key: []const u8) ?u32 {
    const v = lookup(data, key) orelse return null;
    if (v.len != 4) return null;
    return std.mem.readInt(u32, v[0..4], .big);
}

/// A string field: the number stored under `key` is the offset of the string in the area `sa`.
/// Null when the field is absent or empty.
pub fn string(data: []const u8, key: []const u8) ?[]const u8 {
    const offset = number(data, key) orelse return null;
    const area = lookup(data, "sa") orelse return null;
    if (offset >= area.len) return null;
    const text = std.mem.sliceTo(area[offset..], 0);
    return if (text.len == 0) null else text;
}

const testing = std.testing;
const enabled_fixture = @embedFile("testdata/hello.enabled.resolve");
const disabled_fixture = @embedFile("testdata/hello.disabled.resolve");

test "the resolve files 66 0.9.1.2 wrote tell whether the service is enabled" {
    try testing.expectEqual(@as(?u32, 1), number(enabled_fixture, "enabled"));
    try testing.expectEqual(@as(?u32, 0), number(disabled_fixture, "enabled"));
}

test "strings of a resolve file are read without their terminator" {
    try testing.expectEqualStrings("hello", string(enabled_fixture, "name").?);
    try testing.expectEqualStrings("/etc/66/service/hello", string(enabled_fixture, "frontend").?);
    try testing.expectEqualStrings("global", string(enabled_fixture, "treename").?);
    try testing.expectEqualStrings("0.9.1.2", string(enabled_fixture, "rversion").?);
}

test "absent keys and malformed databases give null" {
    try testing.expect(lookup(enabled_fixture, "no-such-key") == null);
    try testing.expect(number(enabled_fixture, "no-such-key") == null);
    try testing.expect(string(enabled_fixture, "no-such-key") == null);
    try testing.expect(lookup("", "enabled") == null);
    try testing.expect(lookup(enabled_fixture[0 .. enabled_fixture.len / 2], "frontend") == null);
    var zeros: [header_bytes]u8 = @splat(0);
    try testing.expect(lookup(&zeros, "enabled") == null);
}
