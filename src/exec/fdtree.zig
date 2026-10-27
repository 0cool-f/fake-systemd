// SPDX-License-Identifier: GPL-3.0-or-later
//! Directory trees handled through descriptors: every step is an `*at` call from an open
//! directory, symlinks are never followed and a walk never leaves the device it started on, so
//! a tree that an unprivileged account controls cannot redirect privileged changes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const builtin = @import("builtin");

/// Seams for tests only: `stat` rewrites every status read, `before_chown` runs after an entry is
/// opened and before it is changed.
pub const Hooks = struct {
    stat: ?*const fn (Stx) Stx = null,
    before_chown: ?*const fn (dirfd: i32, name: [:0]const u8) void = null,
};
pub var hooks: Hooks = .{};

pub const Error = error{
    /// A component is a symlink or not a directory.
    NotADirectory,
    FileNotFound,
    PathAlreadyExists,
    AccessDenied,
    CrossesDevice,
    Unexpected,
    OutOfMemory,
};

fn errnoError(e: linux.E) Error {
    return switch (e) {
        .LOOP, .NOTDIR => error.NotADirectory,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub const Stx = struct {
    uid: u32,
    gid: u32,
    /// File type and permission bits.
    mode: u16,
    nlink: u32,
    dev_major: u32,
    dev_minor: u32,
    ino: u64,
    /// Mount the object is on; null when the kernel does not tell.
    mnt_id: ?u64 = null,

    pub fn isDir(s: Stx) bool {
        return s.mode & linux.S.IFMT == linux.S.IFDIR;
    }

    pub fn isRegular(s: Stx) bool {
        return s.mode & linux.S.IFMT == linux.S.IFREG;
    }

    pub fn sameDevice(a: Stx, b: Stx) bool {
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor;
    }

    pub fn sameObject(a: Stx, b: Stx) bool {
        return a.sameDevice(b) and a.ino == b.ino;
    }

    /// True when both objects are on the same mount: the same device and, when the kernel tells
    /// it, the same mount, so that a bind mount of the same filesystem differs.
    pub fn sameMount(a: Stx, b: Stx) bool {
        if (!a.sameDevice(b)) return false;
        const am = a.mnt_id orelse return true;
        const bm = b.mnt_id orelse return true;
        return am == bm;
    }
};

const stat_mask: linux.STATX = .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .INO = true, .MNT_ID = true };

fn fromStatx(stx: linux.Statx) Stx {
    const st = rawStx(stx);
    if (builtin.is_test) if (hooks.stat) |rewrite| return rewrite(st);
    return st;
}

fn rawStx(stx: linux.Statx) Stx {
    return .{
        .uid = stx.uid,
        .gid = stx.gid,
        .mode = stx.mode,
        .nlink = stx.nlink,
        .dev_major = stx.dev_major,
        .dev_minor = stx.dev_minor,
        .ino = stx.ino,
        .mnt_id = if (stx.mask.MNT_ID) stx.mnt_id else null,
    };
}

/// Status of the entry `name` of `dirfd`, a symlink being reported as itself.
pub fn statAt(dirfd: i32, name: [:0]const u8) Error!Stx {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dirfd, name.ptr, linux.AT.SYMLINK_NOFOLLOW, stat_mask, &stx);
    return switch (linux.errno(rc)) {
        .SUCCESS => fromStatx(stx),
        else => |e| errnoError(e),
    };
}

pub fn statFd(fd: i32) Error!Stx {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, stat_mask, &stx);
    return switch (linux.errno(rc)) {
        .SUCCESS => fromStatx(stx),
        else => |e| errnoError(e),
    };
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

/// Opens the directory `name` of `dirfd`; a symlink or a file there is `NotADirectory`.
pub fn openDirAt(dirfd: i32, name: [:0]const u8) Error!i32 {
    const rc = linux.openat(dirfd, name.ptr, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| errnoError(e),
    };
}

/// Opens `path`, an absolute path whose symlinks have been resolved already, below `root_fd`.
pub fn openResolved(root_fd: i32, path: []const u8) Error!i32 {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const trimmed = std.mem.trimStart(u8, path, "/");
    const sub = if (trimmed.len == 0) "." else trimmed;
    if (sub.len >= buf.len) return error.Unexpected;
    @memcpy(buf[0..sub.len], sub);
    buf[sub.len] = 0;
    const rc = linux.openat(root_fd, buf[0..sub.len :0], .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| errnoError(e),
    };
}

/// Opens the directory `name` of `dirfd`, creating it with `mode` when it is missing.
pub fn openOrCreateDirAt(dirfd: i32, name: [:0]const u8, mode: u16) Error!i32 {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        if (openDirAt(dirfd, name)) |fd| return fd else |e| if (e != error.FileNotFound) return e;
        switch (linux.errno(linux.mkdirat(dirfd, name.ptr, mode))) {
            .SUCCESS, .EXIST => {},
            else => |m| return errnoError(m),
        }
    }
    return error.Unexpected;
}

pub fn chown(fd: i32, uid: u32, gid: u32) Error!void {
    switch (linux.errno(linux.fchown(fd, uid, gid))) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
}

pub fn chmod(fd: i32, mode: u16) Error!void {
    switch (linux.errno(linux.fchmod(fd, mode))) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
}

/// Names of the entries of `dirfd` except `.` and `..`; the offset of `dirfd` is consumed.
pub fn listNames(gpa: Allocator, dirfd: i32) Error![][:0]u8 {
    var names: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const rc = linux.getdents64(dirfd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| return errnoError(e),
        }
        if (rc == 0) break;
        var pos: usize = 0;
        while (pos < rc) {
            const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[pos]);
            pos += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const copy = try gpa.dupeSentinel(u8, name, 0);
            errdefer gpa.free(copy);
            try names.append(gpa, copy);
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn freeNames(gpa: Allocator, names: [][:0]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Changes the owner of everything below `dirfd` (not of `dirfd`); a null id is left alone.
/// Symlinks are changed themselves, files with several links are skipped because the other
/// link may lie outside the tree, and directories on another device are not entered.
pub fn chownTree(gpa: Allocator, dirfd: i32, uid: ?u32, gid: ?u32) Error!void {
    const start = try statFd(dirfd);
    const u = uid orelse std.math.maxInt(u32);
    const g = gid orelse std.math.maxInt(u32);
    try chownBelow(gpa, dirfd, start, u, g);
}

fn chownBelow(gpa: Allocator, dirfd: i32, dir: Stx, uid: u32, gid: u32) Error!void {
    const names = try listNames(gpa, dirfd);
    defer freeNames(gpa, names);
    for (names) |name| {
        const st = statAt(dirfd, name) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        if (st.isDir()) {
            if (!st.sameDevice(dir)) continue;
            const child = try openDirAt(dirfd, name);
            defer close(child);
            if (!(try statFd(child)).sameObject(st)) return error.NotADirectory;
            try chown(child, uid, gid);
            try chownBelow(gpa, child, st, uid, gid);
        } else {
            try chownEntry(dirfd, name, uid, gid);
        }
    }
}

/// Changes the owner of the non-directory entry `name` of `dirfd`: the entry is opened without
/// following it, and the link count and the change apply to that open object, so a replacement
/// of the name after the check cannot redirect the change. A file with several links is skipped
/// because the other link may lie outside the tree.
fn chownEntry(dirfd: i32, name: [:0]const u8, uid: u32, gid: u32) Error!void {
    const rc = linux.openat(dirfd, name.ptr, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    const fd: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => return,
        else => |e| return errnoError(e),
    };
    defer close(fd);
    if (builtin.is_test) if (hooks.before_chown) |hook| hook(dirfd, name);
    const st = try statFd(fd);
    if (st.isDir()) return error.NotADirectory;
    if (st.isRegular() and st.nlink > 1) return;
    switch (linux.errno(linux.fchownat(fd, "", uid, gid, linux.AT.EMPTY_PATH | linux.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
}

/// Removes the entry `name` of `dirfd`: a directory with everything below it, anything else
/// by unlinking it. Nothing is followed and a directory on another device than `dirfd` is
/// refused. A missing entry is not an error.
pub fn removeAt(gpa: Allocator, dirfd: i32, name: [:0]const u8) Error!void {
    const parent = try statFd(dirfd);
    try removeEntry(gpa, dirfd, parent, name);
}

fn removeEntry(gpa: Allocator, dirfd: i32, parent: Stx, name: [:0]const u8) Error!void {
    const st = statAt(dirfd, name) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    if (!st.isDir()) {
        switch (linux.errno(linux.unlinkat(dirfd, name.ptr, 0))) {
            .SUCCESS, .NOENT => return,
            else => |e| return errnoError(e),
        }
    }
    if (!st.sameDevice(parent)) return error.CrossesDevice;
    {
        const child = try openDirAt(dirfd, name);
        defer close(child);
        if (!(try statFd(child)).sameObject(st)) return error.NotADirectory;
        const names = try listNames(gpa, child);
        defer freeNames(gpa, names);
        for (names) |n| try removeEntry(gpa, child, st, n);
    }
    switch (linux.errno(linux.unlinkat(dirfd, name.ptr, linux.AT.REMOVEDIR))) {
        .SUCCESS, .NOENT => {},
        else => |e| return errnoError(e),
    }
}

/// Makes the object with inode `ino` appear on another device, or with `device` false on another
/// mount of the same device; every other object keeps its status.
pub const FakeMount = struct {
    var ino: u64 = 0;
    var device = true;

    fn rewrite(st: Stx) Stx {
        var s = st;
        if (device) {
            if (s.ino == ino) s.dev_minor +%= 1;
        } else {
            s.mnt_id = if (s.ino == ino) 2 else 1;
        }
        return s;
    }

    pub fn set(object: u64, other_device: bool) void {
        ino = object;
        device = other_device;
        hooks.stat = rewrite;
    }
};

fn openRoot() !i32 {
    const rc = linux.openat(linux.AT.FDCWD, "/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    return @intCast(rc);
}

test "an object on another mount than the root is told from one on the same mount" {
    const root = try openRoot();
    defer close(root);
    const proc = try openResolved(root, "/proc");
    defer close(proc);
    const root_st = try statFd(root);
    const proc_st = try statFd(proc);
    try std.testing.expect(!proc_st.sameMount(root_st));
    try std.testing.expect(root_st.sameMount(root_st));
}

test "a bind mount of the same device differs by its mount id" {
    var a: Stx = std.mem.zeroes(Stx);
    var b = a;
    a.mnt_id = 1;
    b.mnt_id = 2;
    try std.testing.expect(!a.sameMount(b));
    b.mnt_id = null;
    try std.testing.expect(a.sameMount(b));
    b.mnt_id = 1;
    b.dev_minor = 1;
    try std.testing.expect(!a.sameMount(b));
}

fn markMoved(dirfd: i32, name: [:0]const u8) void {
    _ = linux.renameat(dirfd, name.ptr, dirfd, "moved");
    _ = linux.symlinkat("../outside", dirfd, name.ptr);
}

test "a removal refuses a directory on another device and keeps what is below it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tree/a/mnt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/a/mnt/f", .data = "x" });
    const tree = try openDirAt(tmp.dir.handle, "tree");
    defer close(tree);
    const a = try openDirAt(tree, "a");
    FakeMount.set((try statAt(a, "mnt")).ino, true);
    close(a);
    defer hooks = .{};
    try std.testing.expectError(error.CrossesDevice, removeAt(std.testing.allocator, tree, "a"));
    try std.testing.expectEqual(@as(usize, 1), (try tmp.dir.statFile(std.testing.io, "tree/a/mnt/f", .{})).size);
    hooks = .{};
    try removeAt(std.testing.allocator, tree, "a");
    try std.testing.expectError(error.FileNotFound, statAt(tree, "a"));
}

test "the ownership change does not enter a directory on another device" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tree/mnt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/mnt/f", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/plain", .data = "x" });
    const tree = try openDirAt(tmp.dir.handle, "tree");
    defer close(tree);
    const mnt = try openDirAt(tree, "mnt");
    defer close(mnt);
    FakeMount.set((try statFd(mnt)).ino, true);
    defer hooks = .{};
    try chownTree(std.testing.allocator, tree, 4242, 4343);
    try std.testing.expectEqual(@as(u32, 4242), (try statAt(tree, "plain")).uid);
    try std.testing.expectEqual(@as(u32, 0), (try statAt(tree, "mnt")).uid);
    try std.testing.expectEqual(@as(u32, 0), (try statAt(mnt, "f")).uid);
}

test "the ownership change applies to the opened entry, not to a name swapped in afterwards" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tree");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/victim", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside", .data = "x" });
    const tree = try openDirAt(tmp.dir.handle, "tree");
    defer close(tree);
    hooks.before_chown = markMoved;
    defer hooks = .{};
    try chownTree(std.testing.allocator, tree, 4242, 4343);
    try std.testing.expectEqual(@as(u32, 4242), (try statAt(tree, "moved")).uid);
    try std.testing.expectEqual(@as(u32, 0), (try statAt(tree, "victim")).uid);
    try std.testing.expectEqual(@as(u32, 0), (try statAt(tmp.dir.handle, "outside")).uid);
}

test "a symlink and a multiply linked file are not followed by the ownership change" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "tree", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside", .data = "x" });
    try tmp.dir.symLink(std.testing.io, "outside", "tree/link", .{});
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.linkat(tmp.dir.handle, "outside", tmp.dir.handle, "tree/hard", 0)));
    const dirfd = try openDirAt(tmp.dir.handle, "tree");
    defer close(dirfd);
    try chownTree(std.testing.allocator, dirfd, 4242, 4343);
    const outside = try statAt(tmp.dir.handle, "outside");
    try std.testing.expectEqual(@as(u32, 0), outside.uid);
    const link = try statAt(dirfd, "link");
    try std.testing.expectEqual(@as(u32, 4242), link.uid);
    const hard = try statAt(dirfd, "hard");
    try std.testing.expectEqual(@as(u32, 0), hard.uid);
}
