//! XxHash3 64-bit hashing of unit sets, stat fingerprints and generated bodies.
const std = @import("std");
const Io = std.Io;
const Fs = @import("../core/Fs.zig");

const XxHash3 = std.hash.XxHash3;

pub const prefix = "xxh3:";
/// Length of a rendered hash: `xxh3:` plus 16 hex digits.
pub const string_len = prefix.len + 16;
pub const max_file_size = 16 << 20;

pub fn ofBytes(data: []const u8) u64 {
    return XxHash3.hash(0, data);
}

/// Hash of the generated body, i.e. the file content without the marker block.
pub const bodyHash = ofBytes;

/// `bodyHash(head ++ tail)` without concatenating.
pub fn bodyHashSplit(head: []const u8, tail: []const u8) u64 {
    var h = XxHash3.init(0);
    h.update(head);
    h.update(tail);
    return h.final();
}

/// Display wrapper: `{f}` prints `xxh3:` followed by 16 lowercase hex digits.
pub const Str = struct {
    value: u64,

    pub fn format(s: Str, w: *Io.Writer) Io.Writer.Error!void {
        try w.print(prefix ++ "{x:0>16}", .{s.value});
    }
};

pub fn str(value: u64) Str {
    return .{ .value = value };
}

pub fn render(gpa: std.mem.Allocator, value: u64) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{f}", .{str(value)});
}

/// Accepts exactly `xxh3:` + 16 lowercase hex digits.
pub fn parse(s: []const u8) ?u64 {
    if (s.len != string_len or !std.mem.startsWith(u8, s, prefix)) return null;
    const digits = s[prefix.len..];
    for (digits) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    return std.fmt.parseUnsigned(u64, digits, 16) catch null;
}

fn updateInt(h: *XxHash3, comptime T: type, value: T) void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    h.update(&buf);
}

/// Hash over (path, length, content) of every file in order.
pub fn unitSetHash(fs: Fs, gpa: std.mem.Allocator, files: []const []const u8) !u64 {
    var h = XxHash3.init(0);
    for (files) |path| {
        const data = try fs.readFileAlloc(gpa, path, max_file_size);
        defer gpa.free(data);
        h.update(path);
        h.update(&[_]u8{0});
        updateInt(&h, u64, data.len);
        h.update(data);
    }
    return h.final();
}

fn updateStat(h: *XxHash3, fs: Fs, path: []const u8, with_identity: bool) void {
    h.update(path);
    h.update(&[_]u8{0});
    const st = fs.stat(path) catch {
        h.update(&[_]u8{0xff});
        return;
    };
    h.update(&[_]u8{1});
    if (with_identity) {
        updateInt(h, u64, st.inode);
        updateInt(h, u64, st.size);
    }
    updateInt(h, i96, st.mtime_ns);
}

/// Hash over (path, inode, size, mtime) of every file plus the mtime of every drop-in directory.
/// A path that cannot be stat'ed contributes a distinct sentinel, so its disappearance changes the result.
pub fn statFingerprint(fs: Fs, files: []const []const u8, dropin_dirs: []const []const u8) u64 {
    var h = XxHash3.init(0);
    for (files) |path| updateStat(&h, fs, path, true);
    h.update(&[_]u8{2});
    for (dropin_dirs) |path| updateStat(&h, fs, path, false);
    return h.final();
}

/// Stat fingerprint of one file; 0 when it does not exist.
pub fn fileFingerprint(fs: Fs, path: []const u8) u64 {
    _ = fs.stat(path) catch return 0;
    return statFingerprint(fs, &.{path}, &.{});
}

const testing = std.testing;

test "render and parse round-trip" {
    const s = try render(testing.allocator, 0xabc);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("xxh3:0000000000000abc", s);
    try testing.expectEqual(@as(?u64, 0xabc), parse(s));
    try testing.expectEqual(@as(?u64, null), parse("xxh3:0000000000000ABC"));
    try testing.expectEqual(@as(?u64, null), parse("xxh3:abc"));
    try testing.expectEqual(@as(?u64, null), parse("md5:0000000000000abc"));
    try testing.expectEqual(@as(?u64, null), parse("xxh3:000000000000000g"));
}

test "ofBytes matches the XXH3 reference value" {
    try testing.expectEqual(ofBytes("hello world"), bodyHashSplit("hello ", "world"));
    try testing.expectEqual(@as(u64, 0xd447b1ea40e6988b), ofBytes("hello world"));
}

test "unit set hash covers path, length and content" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.writeFileAtomic("/a", "one", 0o644);
    try fs.writeFileAtomic("/b", "two", 0o644);
    const gpa = testing.allocator;
    const ab = try unitSetHash(fs, gpa, &.{ "/a", "/b" });
    try testing.expectEqual(ab, try unitSetHash(fs, gpa, &.{ "/a", "/b" }));
    try testing.expect(ab != try unitSetHash(fs, gpa, &.{ "/b", "/a" }));
    try testing.expect(ab != try unitSetHash(fs, gpa, &.{"/a"}));
    try fs.writeFileAtomic("/b", "twO", 0o644);
    try testing.expect(ab != try unitSetHash(fs, gpa, &.{ "/a", "/b" }));
    try testing.expectError(error.FileNotFound, unitSetHash(fs, gpa, &.{"/missing"}));
}

test "stat fingerprint changes with content metadata, drop-in dir and removal" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.makePath("/u");
    try fs.writeFileAtomic("/u/a.service", "x", 0o644);
    try fs.makePath("/u/a.service.d");
    const files: []const []const u8 = &.{"/u/a.service"};
    const dirs: []const []const u8 = &.{"/u/a.service.d"};
    const f0 = statFingerprint(fs, files, dirs);
    try testing.expectEqual(f0, statFingerprint(fs, files, dirs));
    try fs.writeFileAtomic("/u/a.service.d/o.conf", "y", 0o644);
    const f1 = statFingerprint(fs, files, dirs);
    try testing.expect(f0 != f1);
    try fs.writeFileAtomic("/u/a.service", "xx", 0o644);
    const f2 = statFingerprint(fs, files, dirs);
    try testing.expect(f1 != f2);
    try fs.deleteFile("/u/a.service");
    try testing.expect(f2 != statFingerprint(fs, files, dirs));
    try testing.expectEqual(@as(u64, 0), fileFingerprint(fs, "/u/a.service"));
    try testing.expect(fileFingerprint(fs, "/u/a.service.d/o.conf") != 0);
}
