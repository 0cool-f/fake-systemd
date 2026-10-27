// SPDX-License-Identifier: GPL-3.0-or-later
//! `flock` on `index.lock`: shared for reads, exclusive for writes (§7.5). The lock file is
//! private to its owner (mode 0600) so that no other account can hold it and stall every verb;
//! an existing lock that does not pass `verify` is refused.
const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Fs = @import("../core/Fs.zig");
const Diag = @import("../core/Diag.zig");

pub const Mode = enum { shared, exclusive };

pub const lock_mode = 0o600;

pub const Options = struct {
    /// Wait after which a notice is printed.
    notice_after_ms: i64 = 1000,
    /// Wait after which acquisition fails with `error.LockTimeout`.
    timeout_ms: i64 = 30_000,
    poll_ms: i64 = 20,
};

pub const Lock = struct {
    io: Io,
    /// Null when a shared lock was requested and no lock file exists yet, or an unprivileged
    /// reader may not open the private file.
    file: ?Io.File,

    pub fn release(l: *Lock) void {
        if (l.file) |f| {
            f.unlock(l.io);
            f.close(l.io);
        }
        l.file = null;
    }
};

/// True when `uid` may own the lock file or its directory: the running user and root, and, for an
/// offline tree below `--root`, the real user and the owner of the tree, because an image
/// extracted by an unprivileged user is built by root.
fn trustedOwner(fs: Fs, uid: u32) bool {
    if (uid == linux.geteuid() or uid == 0) return true;
    if (fs.host_root) return false;
    if (uid == linux.getuid()) return true;
    const tree = fs.dirInfo("/") catch return false;
    return uid == tree.uid;
}

/// The directory of a lock file must belong to a trusted owner and not be writable by anyone
/// else, or the lock file could be replaced.
fn verifyDir(fs: Fs, dir_abs: []const u8) !void {
    const info = try fs.dirInfo(dir_abs);
    if (info.kind != .directory) return error.UntrustedLock;
    if (!trustedOwner(fs, info.uid)) return error.UntrustedLock;
    if (info.mode & 0o022 != 0) return error.UntrustedLock;
}

/// An open lock file must be a regular file owned by a trusted owner. One of ours with group or
/// other permissions (from an earlier version) is made private; a root-owned file that a non-root
/// user has opened is left alone.
fn verify(fs: Fs, file: Io.File) !void {
    const info = try Fs.fileInfo(file);
    const euid = linux.geteuid();
    if (info.kind != .file) return error.UntrustedLock;
    if (info.uid != euid and !(info.uid == 0 and euid != 0) and !(euid == 0 and !fs.host_root and trustedOwner(fs, info.uid))) return error.UntrustedLock;
    if (info.uid == euid and info.mode & 0o077 != 0) try file.setPermissions(fs.io, .fromMode(lock_mode));
}

/// Opens the lock file, creating it and its directories when `create` is set.
fn open(fs: Fs, lock_abs: []const u8, create: bool) !Io.File {
    const dir = std.fs.path.dirname(lock_abs) orelse "/";
    if (create) try fs.makePath(dir);
    try verifyDir(fs, dir);
    const file = try fs.openNoFollow(lock_abs, .{
        .access = if (create) .read_write else .read,
        .create = if (create) lock_mode else null,
    });
    errdefer file.close(fs.io);
    try verify(fs, file);
    return file;
}

/// Takes the lock at `lock_abs`. An exclusive request creates the file and its directories;
/// a shared request on a missing file succeeds without locking, since nothing has been written yet.
pub fn acquire(fs: Fs, diag: *Diag, lock_abs: []const u8, mode: Mode, opts: Options) !Lock {
    const file = open(fs, lock_abs, mode == .exclusive) catch |e| switch (e) {
        error.FileNotFound => if (mode == .shared) return .{ .io = fs.io, .file = null } else return e,
        error.AccessDenied => if (mode == .shared and linux.geteuid() != 0) return .{ .io = fs.io, .file = null } else return e,
        error.UntrustedLock => {
            diag.err("refusing {s}: its owner or permissions are not safe for a lock", .{lock_abs});
            return e;
        },
        else => return e,
    };
    errdefer file.close(fs.io);

    const kind: Io.File.Lock = if (mode == .shared) .shared else .exclusive;
    const start = Io.Timestamp.now(fs.io, .awake);
    var noticed = false;
    while (!try file.tryLock(fs.io, kind)) {
        const waited_ms = start.untilNow(fs.io, .awake).toMilliseconds();
        if (waited_ms >= opts.timeout_ms) {
            diag.err("timed out after {d} s waiting for {s}", .{ @divTrunc(opts.timeout_ms, 1000), lock_abs });
            return error.LockTimeout;
        }
        if (!noticed and waited_ms >= opts.notice_after_ms) {
            diag.notice("waiting for lock {s} held by another process", .{lock_abs});
            noticed = true;
        }
        try fs.io.sleep(.fromMilliseconds(opts.poll_ms), .awake);
    }
    return .{ .io = fs.io, .file = file };
}

/// Takes an exclusive lock without waiting; null when another process holds it. Creates the file and its directories.
pub fn tryAcquire(fs: Fs, lock_abs: []const u8) !?Lock {
    const file = try open(fs, lock_abs, true);
    errdefer file.close(fs.io);
    if (!try file.tryLock(fs.io, .exclusive)) {
        file.close(fs.io);
        return null;
    }
    return .{ .io = fs.io, .file = file };
}

const testing = std.testing;

test "exclusive lock excludes others until released" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    const path = "/var/lib/fake-systemd/dinit/index.lock";
    const quick: Options = .{ .notice_after_ms = 30, .timeout_ms = 120, .poll_ms = 5 };

    var first = try acquire(fs, &diag, path, .exclusive, .{});
    try testing.expectError(error.LockTimeout, acquire(fs, &diag, path, .exclusive, quick));
    try testing.expectError(error.LockTimeout, acquire(fs, &diag, path, .shared, quick));
    try testing.expect(std.mem.find(u8, w.buffered(), "fake-systemd: waiting for lock " ++ path) != null);
    try testing.expect(std.mem.find(u8, w.buffered(), "fake-systemd: timed out after 0 s waiting for " ++ path) != null);
    first.release();

    var second = try acquire(fs, &diag, path, .exclusive, quick);
    second.release();
}

test "shared locks coexist and block writers" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    const path = "/state/index.lock";
    const quick: Options = .{ .notice_after_ms = 10, .timeout_ms = 60, .poll_ms = 5 };

    var created = try acquire(fs, &diag, path, .exclusive, quick);
    created.release();
    var a = try acquire(fs, &diag, path, .shared, quick);
    var b = try acquire(fs, &diag, path, .shared, quick);
    try testing.expectError(error.LockTimeout, acquire(fs, &diag, path, .exclusive, quick));
    a.release();
    b.release();
}

test "shared lock on a missing file does not create it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var l = try acquire(fs, &diag, "/nope/index.lock", .shared, .{});
    l.release();
    try testing.expect(!fs.exists("/nope"));
}

test "tryAcquire fails while the lock is held and succeeds after release" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    const path = "/state/jobs/a.service.lock";
    var first = (try tryAcquire(fs, path)).?;
    try testing.expect((try tryAcquire(fs, path)) == null);
    first.release();
    var second = (try tryAcquire(fs, path)).?;
    second.release();
}

fn modeOf(fs: Fs, path: []const u8) !u16 {
    var file = try fs.openNoFollow(path, .{});
    defer file.close(fs.io);
    return (try Fs.fileInfo(file)).mode;
}

test "the lock file is created private to its owner" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var l = try acquire(fs, &diag, "/state/index.lock", .exclusive, .{});
    l.release();
    try testing.expectEqual(@as(u16, 0o600), try modeOf(fs, "/state/index.lock"));
    var job = (try tryAcquire(fs, "/state/jobs/a.service.lock")).?;
    job.release();
    try testing.expectEqual(@as(u16, 0o600), try modeOf(fs, "/state/jobs/a.service.lock"));
}

test "a lock of ours with group or other permissions is made private" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    try fs.makePath("/state");
    try fs.writeFileInPlace("/state/index.lock", "", 0o644);
    var l = try acquire(fs, &diag, "/state/index.lock", .shared, .{});
    l.release();
    try testing.expectEqual(@as(u16, 0o600), try modeOf(fs, "/state/index.lock"));
}

test "a lock directory that others can write to is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    try fs.makePath("/state");
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(tmp.dir.handle, "state", 0o777)));
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, "/state/index.lock", .exclusive, .{}));
    try testing.expectError(error.UntrustedLock, tryAcquire(fs, "/state/jobs.lock"));
    try testing.expect(std.mem.find(u8, w.buffered(), "refusing /state/index.lock") != null);
}

test "a lock that is not a regular file is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    try fs.makePath("/state/dir.lock");
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, "/state/dir.lock", .shared, .{}));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(tmp.dir.handle, "state/fifo.lock", linux.S.IFIFO | 0o600, 0)));
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, "/state/fifo.lock", .shared, .{}));
    try fs.symLink("dir.lock", "/state/link.lock");
    try testing.expectError(error.SymLinkLoop, acquire(fs, &diag, "/state/link.lock", .exclusive, .{}));
}

test "as root a lock owned by another account is refused" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var l = try acquire(fs, &diag, "/state/index.lock", .exclusive, .{});
    l.release();
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchownat(tmp.dir.handle, "state/index.lock", 4242, 4242, 0)));
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, "/state/index.lock", .shared, .{}));
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, "/state/index.lock", .exclusive, .{}));
}

test "an offline tree owned by an unprivileged user is trusted, the host root is not" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    try fs.makePath("/var/lib/fake-systemd/dinit");
    for ([_][:0]const u8{ ".", "var", "var/lib", "var/lib/fake-systemd", "var/lib/fake-systemd/dinit" }) |p| {
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchownat(tmp.dir.handle, p, 4242, 4242, 0)));
    }
    const path = "/var/lib/fake-systemd/dinit/index.lock";
    var offline = try acquire(fs, &diag, path, .exclusive, .{});
    offline.release();
    fs.host_root = true;
    try testing.expectError(error.UntrustedLock, acquire(fs, &diag, path, .exclusive, .{}));
}
