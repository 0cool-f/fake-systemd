// SPDX-License-Identifier: GPL-3.0-or-later
//! XxHash3 64-bit hashing of unit sets, stat fingerprints and generated bodies.
const std = @import("std");
const Io = std.Io;
const Fs = @import("../core/Fs.zig");
const Config = @import("../config/Config.zig");

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

/// Hash over (path, inode, size, mtime) of every file plus the mtime of every drop-in directory
/// and the given executable stats (`executableStat`).
/// A path that cannot be stat'ed contributes a distinct sentinel, so its disappearance changes the result.
pub fn statFingerprint(fs: Fs, files: []const []const u8, dropin_dirs: []const []const u8, executable_stats: []const u64) u64 {
    var h = XxHash3.init(0);
    for (files) |path| updateStat(&h, fs, path, true);
    h.update(&[_]u8{2});
    for (dropin_dirs) |path| updateStat(&h, fs, path, false);
    h.update(&[_]u8{3});
    for (executable_stats) |s| updateInt(&h, u64, s);
    return h.final();
}

/// Hash over the state of every candidate path of one executable: missing, present but not
/// executable, or executable with its (inode, size, mtime).
pub fn executableStat(fs: Fs, candidates: []const []const u8) u64 {
    var h = XxHash3.init(0);
    for (candidates) |path| {
        h.update(path);
        h.update(&[_]u8{0});
        const st = fs.stat(path) catch {
            h.update(&[_]u8{0xff});
            continue;
        };
        const runnable = st.kind == .file and st.mode & 0o111 != 0;
        h.update(&[_]u8{if (runnable) 1 else 2});
        updateInt(&h, u64, st.inode);
        updateInt(&h, u64, st.size);
        updateInt(&h, i96, st.mtime_ns);
    }
    return h.final();
}

/// Hash of the effective configuration that influences classification and translation:
/// `Translate`, `Allow`, `Deny` and the aliases in key order.
pub fn configHash(gpa: std.mem.Allocator, config: Config) !u64 {
    var h = XxHash3.init(0);
    h.update(@tagName(config.translate));
    for ([_][]const []const u8{ config.allow, config.deny }) |list| {
        h.update(&[_]u8{1});
        for (list) |item| {
            h.update(item);
            h.update(&[_]u8{0});
        }
    }
    h.update(&[_]u8{2});
    const keys = try gpa.alloc([]const u8, config.aliases.count());
    defer gpa.free(keys);
    var it = config.aliases.keyIterator();
    for (keys) |*k| k.* = it.next().?.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (keys) |k| {
        h.update(k);
        h.update(&[_]u8{0});
        h.update(config.aliases.get(k).?);
        h.update(&[_]u8{0});
    }
    return h.final();
}

/// Stat fingerprint of one file; 0 when it does not exist.
pub fn fileFingerprint(fs: Fs, path: []const u8) u64 {
    _ = fs.stat(path) catch return 0;
    return statFingerprint(fs, &.{path}, &.{}, &.{});
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
    const f0 = statFingerprint(fs, files, dirs, &.{});
    try testing.expectEqual(f0, statFingerprint(fs, files, dirs, &.{}));
    try fs.writeFileAtomic("/u/a.service.d/o.conf", "y", 0o644);
    const f1 = statFingerprint(fs, files, dirs, &.{});
    try testing.expect(f0 != f1);
    try fs.writeFileAtomic("/u/a.service", "xx", 0o644);
    const f2 = statFingerprint(fs, files, dirs, &.{});
    try testing.expect(f1 != f2);
    try fs.deleteFile("/u/a.service");
    try testing.expect(f2 != statFingerprint(fs, files, dirs, &.{}));
    try testing.expectEqual(@as(u64, 0), fileFingerprint(fs, "/u/a.service"));
    try testing.expect(fileFingerprint(fs, "/u/a.service.d/o.conf") != 0);
}

test "executable stat tells missing, non-executable and executable apart" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    const candidates: []const []const u8 = &.{ "/bin/a", "/usr/bin/a" };
    const missing = executableStat(fs, candidates);
    try fs.makePath("/usr/bin");
    try fs.writeFileAtomic("/usr/bin/a", "x", 0o644);
    const plain = executableStat(fs, candidates);
    try testing.expect(missing != plain);
    try fs.writeFileAtomic("/usr/bin/a", "x", 0o755);
    const runnable = executableStat(fs, candidates);
    try testing.expect(plain != runnable);
    try fs.deleteFile("/usr/bin/a");
    try testing.expectEqual(missing, executableStat(fs, candidates));
}

test "config hash follows Translate, Allow, Deny and aliases, not insertion order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c1: Config = .{};
    const base = try configHash(a, c1);
    try testing.expectEqual(base, try configHash(a, .{ .log_level = .info, .init = "dinit" }));
    try testing.expect(base != try configHash(a, .{ .translate = .eager }));
    try testing.expect(base != try configHash(a, .{ .deny = &.{"x"} }));
    try testing.expect(try configHash(a, .{ .deny = &.{"x"} }) != try configHash(a, .{ .allow = &.{"x"} }));
    try c1.aliases.put(a, "a.service", "x");
    try c1.aliases.put(a, "b.service", "y");
    var c2: Config = .{};
    try c2.aliases.put(a, "b.service", "y");
    try c2.aliases.put(a, "a.service", "x");
    try testing.expectEqual(try configHash(a, c1), try configHash(a, c2));
    try testing.expect(base != try configHash(a, c1));
}
