// SPDX-License-Identifier: GPL-3.0-or-later
//! Filesystem access rooted at a directory handle. Every method takes an absolute path
//! that is resolved relative to the root. Operations that follow symlinks (`stat`, `exists`,
//! `readFileAlloc`, `iterateDir`, `devIno`) resolve them inside the root, so an absolute link
//! never escapes it; `lstat` and `readLink` never follow.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const linux = std.os.linux;

const Fs = @This();

pub const Kind = File.Kind;

pub const Stat = struct {
    kind: Kind,
    size: u64,
    inode: u64,
    mtime_ns: i96,
    /// Permission bits only (`& 0o7777`).
    mode: u16,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

pub const DevIno = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,

    pub fn eql(a: DevIno, b: DevIno) bool {
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
    }
};

pub const max_symlink_hops = 40;

io: Io,
root: Dir,
owns_root: bool,
/// True when the root is the host `/`, where the OS resolves symlinks itself.
host_root: bool = false,

/// Opens `abs_root_path` as the root; release with `deinit`.
pub fn initRoot(io: Io, abs_root_path: []const u8) !Fs {
    const root = try Dir.openDirAbsolute(io, abs_root_path, .{ .iterate = true });
    return .{ .io = io, .root = root, .owns_root = true, .host_root = std.mem.eql(u8, abs_root_path, "/") };
}

/// Uses an already open directory as the root; the caller keeps ownership of `dir`.
pub fn initDir(io: Io, dir: Dir) Fs {
    return .{ .io = io, .root = dir, .owns_root = false };
}

pub fn deinit(fs: *Fs) void {
    if (fs.owns_root) fs.root.close(fs.io);
    fs.* = undefined;
}

fn rel(abs: []const u8) []const u8 {
    std.debug.assert(abs.len > 0 and abs[0] == '/');
    const trimmed = std.mem.trimStart(u8, abs, "/");
    return if (trimmed.len == 0) "." else trimmed;
}

fn toStat(raw: File.Stat) Stat {
    return .{
        .kind = raw.kind,
        .size = raw.size,
        .inode = raw.inode,
        .mtime_ns = raw.mtime.toNanoseconds(),
        .mode = @intCast(raw.permissions.toMode() & 0o7777),
    };
}

pub fn readFileAlloc(fs: Fs, gpa: std.mem.Allocator, abs: []const u8, max_size: usize) ![]u8 {
    var buf: [path_cap]u8 = undefined;
    return fs.root.readFileAlloc(fs.io, rel(try fs.follow(&buf, abs)), gpa, .limited(max_size));
}

pub fn stat(fs: Fs, abs: []const u8) !Stat {
    var buf: [path_cap]u8 = undefined;
    return toStat(try fs.root.statFile(fs.io, rel(try fs.follow(&buf, abs)), .{}));
}

pub fn lstat(fs: Fs, abs: []const u8) !Stat {
    var buf: [path_cap]u8 = undefined;
    return fs.lstatRaw(try fs.followParent(&buf, abs));
}

fn lstatRaw(fs: Fs, abs: []const u8) !Stat {
    return toStat(try fs.root.statFile(fs.io, rel(abs), .{ .follow_symlinks = false }));
}

/// True when the path resolves inside the root; any other failure reads as absent.
pub fn exists(fs: Fs, abs: []const u8) bool {
    var buf: [path_cap]u8 = undefined;
    const target = fs.follow(&buf, abs) catch return false;
    fs.root.access(fs.io, rel(target), .{}) catch return false;
    return true;
}

pub fn readLink(fs: Fs, abs: []const u8, buf: []u8) ![]u8 {
    var path: [path_cap]u8 = undefined;
    return fs.readLinkRaw(try fs.followParent(&path, abs), buf);
}

fn readLinkRaw(fs: Fs, abs: []const u8, buf: []u8) ![]u8 {
    const n = try fs.root.readLink(fs.io, rel(abs), buf);
    return buf[0..n];
}

/// Returns entries sorted by name; free with `freeEntries`.
/// Kind of directory entry `e`: filesystems that do not report a type in the listing are asked.
fn entryKind(fs: Fs, dir: Dir, e: Dir.Entry) Kind {
    if (e.kind != .unknown) return e.kind;
    const st = dir.statFile(fs.io, e.name, .{ .follow_symlinks = false }) catch return .unknown;
    return st.kind;
}

pub fn iterateDir(fs: Fs, gpa: std.mem.Allocator, abs: []const u8) ![]Entry {
    var buf: [path_cap]u8 = undefined;
    var dir = try fs.root.openDir(fs.io, rel(try fs.follow(&buf, abs)), .{ .iterate = true });
    defer dir.close(fs.io);
    var list: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(gpa, list.toOwnedSlice(gpa) catch &.{});
    var it = dir.iterate();
    while (try it.next(fs.io)) |e| {
        const name = try gpa.dupe(u8, e.name);
        errdefer gpa.free(name);
        try list.append(gpa, .{ .name = name, .kind = fs.entryKind(dir, e) });
    }
    std.mem.sort(Entry, list.items, {}, entryLessThan);
    return list.toOwnedSlice(gpa);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.name);
    gpa.free(entries);
}

/// Creates `abs` and its missing parents. Existing components that are symlinks are resolved
/// inside the root.
pub fn makePath(fs: Fs, abs: []const u8) !void {
    if (fs.host_root) return fs.root.createDirPath(fs.io, rel(abs));
    var cur: [path_cap]u8 = undefined;
    var cur_len: usize = 0;
    var cand_buf: [path_cap]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            cur_len = std.mem.findScalarLast(u8, cur[0..cur_len], '/') orelse 0;
            continue;
        }
        const cand = try std.fmt.bufPrint(&cand_buf, "{s}/{s}", .{ cur[0..cur_len], comp });
        const kind: Kind = if (fs.lstatRaw(cand)) |st| st.kind else |e| switch (e) {
            error.FileNotFound => blk: {
                try fs.root.createDir(fs.io, rel(cand), .default_dir);
                break :blk .directory;
            },
            else => return e,
        };
        switch (kind) {
            .directory => {
                @memcpy(cur[0..cand.len], cand);
                cur_len = cand.len;
            },
            .sym_link => {
                var real_buf: [path_cap]u8 = undefined;
                const real = try fs.resolveInto(&real_buf, cand);
                if ((try fs.lstatRaw(real)).kind != .directory) return error.NotDir;
                cur_len = if (real.len == 1) 0 else real.len;
                @memcpy(cur[0..cur_len], real[0..cur_len]);
            },
            else => return error.NotDir,
        }
    }
}

/// Path whose parent directory is resolved inside the root; the final component is kept as is.
fn followParent(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (fs.host_root) return abs;
    const base = std.fs.path.basename(abs);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return fs.resolveInto(out, abs);
    }
    const dir = std.fs.path.dirname(abs) orelse "/";
    var dir_buf: [path_cap]u8 = undefined;
    const real_dir = try fs.resolveInto(&dir_buf, dir);
    return std.fmt.bufPrint(out, "{s}/{s}", .{ if (real_dir.len == 1) "" else real_dir, base }) catch error.NameTooLong;
}

pub fn deleteFile(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.deleteFile(fs.io, rel(try fs.followParent(&buf, abs)));
}

/// Removes `abs` and everything below it; a symlink at `abs` is removed itself.
pub fn deleteTree(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.deleteTree(fs.io, rel(try fs.followParent(&buf, abs)));
}

pub fn rename(fs: Fs, src_abs: []const u8, dst_abs: []const u8) !void {
    var src: [path_cap]u8 = undefined;
    var dst: [path_cap]u8 = undefined;
    try fs.root.rename(rel(try fs.followParent(&src, src_abs)), fs.root, rel(try fs.followParent(&dst, dst_abs)), fs.io);
}

/// Creates `abs` as a symlink whose content is `target` verbatim.
pub fn symLink(fs: Fs, target: []const u8, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.symLink(fs.io, target, rel(try fs.followParent(&buf, abs)), .{});
}

/// Writes `content` to a sibling temporary file, syncs it, renames it over `abs` and syncs
/// the directory. Fails with `DestinationIsSymlink` when `abs` is a symlink.
pub fn writeFileAtomic(fs: Fs, abs: []const u8, content: []const u8, mode: u16) !void {
    var real_buf: [path_cap]u8 = undefined;
    const real = try fs.followParent(&real_buf, abs);
    try fs.refuseSymlinkDestination(real);
    var tmp_buf: [Dir.max_path_bytes]u8 = undefined;
    const tmp_abs = try fs.tempSibling(&tmp_buf, real);
    {
        const file = try fs.root.createFile(fs.io, rel(tmp_abs), .{
            .exclusive = true,
            .permissions = .fromMode(mode),
        });
        defer file.close(fs.io);
        errdefer fs.deleteFile(tmp_abs) catch {};
        try file.setPermissions(fs.io, .fromMode(mode));
        try file.writeStreamingAll(fs.io, content);
        try file.sync(fs.io);
    }
    errdefer fs.deleteFile(tmp_abs) catch {};
    try fs.rename(tmp_abs, real);
    try fs.syncDir(std.fs.path.dirname(real) orelse "/");
}

fn refuseSymlinkDestination(fs: Fs, abs: []const u8) !void {
    const st = fs.lstat(abs) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    if (st.kind == .sym_link) return error.DestinationIsSymlink;
}

fn tempSibling(fs: Fs, buf: []u8, abs: []const u8) ![]u8 {
    var random: [4]u8 = undefined;
    fs.io.random(&random);
    const dir = std.fs.path.dirname(abs) orelse "/";
    const sep = if (std.mem.eql(u8, dir, "/")) "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}.{s}.tmp{x}", .{
        dir, sep, std.fs.path.basename(abs), std.mem.readInt(u32, &random, .little),
    });
}

fn syncDir(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    var dir = try fs.root.openDir(fs.io, rel(try fs.follow(&buf, abs)), .{ .iterate = true });
    defer dir.close(fs.io);
    const as_file: File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(fs.io);
}

const path_cap = Dir.max_path_bytes;

/// Resolves `abs` inside the root, following symlinks component by component. Absolute
/// link targets are re-rooted; the result is an absolute in-root path owned by the caller.
pub fn realpath(fs: Fs, gpa: std.mem.Allocator, abs: []const u8) ![]u8 {
    var out: [path_cap]u8 = undefined;
    return gpa.dupe(u8, try fs.resolveInto(&out, abs));
}

/// Path to hand to the OS for a symlink-following operation: `abs` itself on the host root,
/// the in-root resolved path otherwise.
fn follow(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (fs.host_root) return abs;
    return fs.resolveInto(out, abs);
}

fn resolveInto(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (abs.len > path_cap) return error.NameTooLong;
    var bufs: [2][path_cap]u8 = undefined;
    var link_buf: [path_cap]u8 = undefined;
    var cur: usize = 0;
    @memcpy(bufs[0][0..abs.len], abs);
    var pending: []const u8 = bufs[0][0..abs.len];
    var len: usize = 0;
    var hops: usize = 0;
    while (nextComponent(pending)) |next| {
        const component, const rest = next;
        pending = rest;
        if (std.mem.eql(u8, component, "..")) {
            len = std.mem.findScalarLast(u8, out[0..len], '/') orelse 0;
            continue;
        }
        if (std.mem.eql(u8, component, ".")) continue;
        const prev_len = len;
        if (len + 1 + component.len > path_cap) return error.NameTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..component.len], component);
        len += 1 + component.len;
        if ((try fs.lstatRaw(out[0..len])).kind != .sym_link) continue;
        hops += 1;
        if (hops > max_symlink_hops) return error.SymLinkLoop;
        const target = try fs.readLinkRaw(out[0..len], &link_buf);
        len = if (std.fs.path.isAbsolute(target)) 0 else prev_len;
        const need = target.len + 1 + rest.len;
        if (need > path_cap) return error.NameTooLong;
        const other = 1 - cur;
        @memcpy(bufs[other][0..target.len], target);
        bufs[other][target.len] = '/';
        @memcpy(bufs[other][target.len + 1 ..][0..rest.len], rest);
        cur = other;
        pending = bufs[other][0..need];
    }
    if (len == 0) {
        out[0] = '/';
        return out[0..1];
    }
    return out[0..len];
}

fn nextComponent(path: []const u8) ?struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimStart(u8, path, "/");
    if (trimmed.len == 0) return null;
    const end = std.mem.findScalar(u8, trimmed, '/') orelse trimmed.len;
    return .{ trimmed[0..end], trimmed[end..] };
}

/// Device and inode of `abs` (following symlinks inside the root), for same-filesystem-object
/// comparisons.
pub fn devIno(fs: Fs, abs: []const u8) !DevIno {
    var resolved_buf: [path_cap]u8 = undefined;
    const target = try fs.follow(&resolved_buf, abs);
    var path_buf: [path_cap:0]u8 = undefined;
    const sub = rel(target);
    if (sub.len > path_cap) return error.NameTooLong;
    @memcpy(path_buf[0..sub.len], sub);
    path_buf[sub.len] = 0;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(fs.root.handle, path_buf[0..sub.len :0], 0, .{ .INO = true }, &sx);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .dev_major = sx.dev_major, .dev_minor = sx.dev_minor, .ino = sx.ino },
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

const testing = std.testing;

fn tmpFs(tmp: *testing.TmpDir) Fs {
    return .initDir(testing.io, tmp.dir);
}

test "atomic write creates, replaces and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/etc/d");
    try fs.writeFileAtomic("/etc/d/f", "one", 0o640);
    try fs.writeFileAtomic("/etc/d/f", "two", 0o640);
    const data = try fs.readFileAlloc(testing.allocator, "/etc/d/f", 100);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("two", data);
    try testing.expectEqual(@as(u16, 0o640), (try fs.stat("/etc/d/f")).mode);
    const entries = try fs.iterateDir(testing.allocator, "/etc/d");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
}

test "atomic write refuses a symlink destination" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/real", "x", 0o644);
    try fs.symLink("real", "/link");
    try testing.expectError(error.DestinationIsSymlink, fs.writeFileAtomic("/link", "y", 0o644));
    const data = try fs.readFileAlloc(testing.allocator, "/real", 10);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("x", data);
}

test "realpath re-roots absolute symlinks and handles dot-dot" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib/real");
    try fs.makePath("/etc");
    try fs.symLink("/usr/lib/real", "/etc/abs");
    try fs.symLink("../usr", "/etc/rel");
    const a = try fs.realpath(testing.allocator, "/etc/abs");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/usr/lib/real", a);
    const b = try fs.realpath(testing.allocator, "/etc/rel/lib/../lib/real");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/usr/lib/real", b);
    const root = try fs.realpath(testing.allocator, "/");
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/", root);
}

test "realpath detects symlink loops" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.symLink("/b", "/a");
    try fs.symLink("/a", "/b");
    try testing.expectError(error.SymLinkLoop, fs.realpath(testing.allocator, "/a"));
}

test "iterateDir returns entries sorted by name with kinds" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/d/sub");
    try fs.writeFileAtomic("/d/b", "", 0o644);
    try fs.writeFileAtomic("/d/a", "", 0o644);
    try fs.symLink("a", "/d/c");
    const entries = try fs.iterateDir(testing.allocator, "/d");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("a", entries[0].name);
    try testing.expectEqualStrings("b", entries[1].name);
    try testing.expectEqualStrings("c", entries[2].name);
    try testing.expectEqual(Kind.sym_link, entries[2].kind);
    try testing.expectEqualStrings("sub", entries[3].name);
    try testing.expectEqual(Kind.directory, entries[3].kind);
}

test "devIno is stable for a path and differs between files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/x", "", 0o644);
    try fs.writeFileAtomic("/y", "", 0o644);
    const x1 = try fs.devIno("/x");
    const x2 = try fs.devIno("/x");
    const y = try fs.devIno("/y");
    try testing.expect(x1.eql(x2));
    try testing.expect(!x1.eql(y));
    try testing.expectEqual((try fs.stat("/x")).inode, x1.ino);
    try testing.expectError(error.FileNotFound, fs.devIno("/missing"));
}

test "stat, lstat, exists, readLink, rename and delete" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/f", "abc", 0o600);
    try fs.symLink("f", "/l");
    try testing.expectEqual(Kind.file, (try fs.stat("/l")).kind);
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/l")).kind);
    try testing.expectEqual(@as(u64, 3), (try fs.stat("/f")).size);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("f", try fs.readLink("/l", &buf));
    try testing.expect(fs.exists("/f"));
    try fs.rename("/f", "/g");
    try testing.expect(!fs.exists("/f"));
    try fs.deleteFile("/g");
    try fs.makePath("/t/u");
    try fs.deleteTree("/t");
    try testing.expect(!fs.exists("/t"));
}

test "following operations resolve absolute symlinks inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib/data");
    try fs.writeFileAtomic("/usr/lib/data/file", "inside", 0o644);
    try fs.makePath("/etc");
    try fs.symLink("/usr/lib/data/file", "/etc/file-link");
    try fs.symLink("/usr/lib/data", "/etc/dir-link");

    const data = try fs.readFileAlloc(testing.allocator, "/etc/file-link", 100);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("inside", data);
    const via_dir = try fs.readFileAlloc(testing.allocator, "/etc/dir-link/file", 100);
    defer testing.allocator.free(via_dir);
    try testing.expectEqualStrings("inside", via_dir);

    try testing.expectEqual(Kind.file, (try fs.stat("/etc/file-link")).kind);
    try testing.expectEqual(@as(u64, 6), (try fs.stat("/etc/dir-link/file")).size);
    try testing.expect(fs.exists("/etc/file-link"));
    try testing.expect((try fs.devIno("/etc/file-link")).eql(try fs.devIno("/usr/lib/data/file")));

    const entries = try fs.iterateDir(testing.allocator, "/etc/dir-link");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("file", entries[0].name);
}

test "an absolute symlink to a path missing inside the root does not escape" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/etc");
    try fs.symLink("/etc/os-release", "/etc/escape");
    try fs.symLink("/proc/self/exe", "/etc/exe");
    try fs.symLink("/", "/etc/up");
    try testing.expectError(error.FileNotFound, fs.stat("/etc/escape"));
    try testing.expectError(error.FileNotFound, fs.readFileAlloc(testing.allocator, "/etc/escape", 10));
    try testing.expectError(error.FileNotFound, fs.devIno("/etc/exe"));
    try testing.expect(!fs.exists("/etc/escape"));
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/etc/escape")).kind);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/etc/os-release", try fs.readLink("/etc/escape", &buf));
    try testing.expect((try fs.devIno("/etc/up/etc/up/etc")).eql(try fs.devIno("/etc")));
}

test "relative symlinks with dot-dot cannot climb above the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/a/b");
    try fs.writeFileAtomic("/target", "t", 0o644);
    try fs.symLink("../../../../../target", "/a/b/up");
    const data = try fs.readFileAlloc(testing.allocator, "/a/b/up", 10);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("t", data);
}

/// A tmp root with `/etc/escape` as an absolute symlink to `target`, a directory that exists
/// next to the root (outside it) and not inside it.
fn escapeFixture(tmp: *testing.TmpDir, outside: *testing.TmpDir) !struct { Fs, []u8 } {
    const fs = tmpFs(tmp);
    try fs.makePath("/etc");
    const real = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(real);
    const target = try testing.allocator.dupe(u8, real);
    errdefer testing.allocator.free(target);
    try fs.symLink(target, "/etc/escape");
    return .{ fs, target };
}

fn outsideEntries(outside: *testing.TmpDir) !usize {
    var n: usize = 0;
    var it = outside.dir.iterate();
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "mutations through an absolute directory symlink stay inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    const fs, const target = try escapeFixture(&tmp, &outside);
    defer testing.allocator.free(target);

    // The link's target does not exist inside the root, so every operation fails there.
    try testing.expectError(error.FileNotFound, fs.writeFileAtomic("/etc/escape/f", "x", 0o644));
    try testing.expectError(error.FileNotFound, fs.symLink("t", "/etc/escape/l"));
    try testing.expectError(error.FileNotFound, fs.deleteFile("/etc/escape/f"));
    try testing.expectError(error.FileNotFound, fs.rename("/etc/escape/a", "/etc/b"));
    try testing.expectError(error.FileNotFound, fs.makePath("/etc/escape/sub/dir"));
    try testing.expectEqual(@as(usize, 0), try outsideEntries(&outside));
}

test "re-rooted absolute directory symlink is used for every mutation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    const fs, const target = try escapeFixture(&tmp, &outside);
    defer testing.allocator.free(target);

    // Same absolute path inside the root: operations land there, never at the real path.
    try fs.makePath(target);
    try fs.writeFileAtomic("/etc/escape/f", "x", 0o644);
    try testing.expect(fs.exists("/etc/escape/f"));
    try fs.makePath("/etc/escape/sub/dir");
    try fs.symLink("f", "/etc/escape/l");
    try fs.rename("/etc/escape/f", "/etc/escape/g");
    try testing.expect(fs.exists("/etc/escape/g"));
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/etc/escape/l")).kind);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("f", try fs.readLink("/etc/escape/l", &buf));
    try fs.deleteFile("/etc/escape/g");
    try fs.deleteTree("/etc/escape/sub");
    try testing.expect(!fs.exists("/etc/escape/sub"));
    try testing.expectEqual(@as(usize, 0), try outsideEntries(&outside));
}

test "deleting a symlink removes the link, not its target" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/real/d");
    try fs.writeFileAtomic("/real/d/f", "x", 0o644);
    try fs.symLink("/real", "/link");
    try fs.symLink("/real/d/f", "/flink");
    try fs.deleteFile("/flink");
    try testing.expect(fs.exists("/real/d/f"));
    try fs.deleteTree("/link");
    try testing.expectError(error.FileNotFound, fs.lstat("/link"));
    try testing.expect(fs.exists("/real/d/f"));
}

test "makePath reuses a directory reached through a symlink component" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib");
    try fs.symLink("/usr/lib", "/lib");
    try fs.makePath("/lib/x/y");
    try testing.expect(fs.exists("/usr/lib/x/y"));
    try fs.writeFileAtomic("/f", "", 0o644);
    try testing.expectError(error.NotDir, fs.makePath("/f/sub"));
}

test "rename moves a link inside a symlinked directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/real");
    try fs.symLink("/real", "/d");
    try fs.symLink("x", "/d/a");
    try fs.rename("/d/a", "/d/b");
    try testing.expect((try fs.lstat("/real/b")).kind == .sym_link);
    try testing.expectError(error.FileNotFound, fs.lstat("/real/a"));
}
