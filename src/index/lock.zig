// SPDX-License-Identifier: GPL-3.0-or-later
//! `flock` on `index.lock`: shared for reads, exclusive for writes (§7.5).
const std = @import("std");
const Io = std.Io;
const Fs = @import("../core/Fs.zig");
const Diag = @import("../core/Diag.zig");

pub const Mode = enum { shared, exclusive };

pub const Options = struct {
    /// Wait after which a notice is printed.
    notice_after_ms: i64 = 1000,
    /// Wait after which acquisition fails with `error.LockTimeout`.
    timeout_ms: i64 = 30_000,
    poll_ms: i64 = 20,
};

pub const Lock = struct {
    io: Io,
    /// Null when a shared lock was requested and no lock file exists yet.
    file: ?Io.File,

    pub fn release(l: *Lock) void {
        if (l.file) |f| {
            f.unlock(l.io);
            f.close(l.io);
        }
        l.file = null;
    }
};

/// Takes the lock at `lock_abs`. An exclusive request creates the file and its directories;
/// a shared request on a missing file succeeds without locking, since nothing has been written yet.
pub fn acquire(fs: Fs, diag: *Diag, lock_abs: []const u8, mode: Mode, opts: Options) !Lock {
    const rel = std.mem.trimStart(u8, lock_abs, "/");
    const file = switch (mode) {
        .exclusive => blk: {
            try fs.makePath(std.fs.path.dirname(lock_abs) orelse "/");
            break :blk try fs.root.createFile(fs.io, rel, .{ .truncate = false });
        },
        .shared => fs.root.openFile(fs.io, rel, .{}) catch |e| switch (e) {
            error.FileNotFound => return .{ .io = fs.io, .file = null },
            else => return e,
        },
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
    try fs.makePath(std.fs.path.dirname(lock_abs) orelse "/");
    const file = try fs.root.createFile(fs.io, std.mem.trimStart(u8, lock_abs, "/"), .{ .truncate = false });
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
