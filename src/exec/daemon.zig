// SPDX-License-Identifier: GPL-3.0-or-later
//! `fake-systemd --exec <unit> --daemon`: detaches the executor from its caller for inits that
//! only start commands and do not supervise them (sysvinit). The executor forks twice with a
//! `setsid` in between, writes its own pid to `daemonPidPath` and only then lets the original
//! process exit, so a caller that waits for the command knows the pid file is in place.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const sys = @import("sys.zig");

/// File that holds the pid of the detached executor, next to the other files of the unit in
/// the runtime directory.
pub fn daemonPidPath(ctx: *const core.Context, unit_name: []const u8) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(ctx.gpa, "fake-systemd/{s}.daemon.pid", .{unit_name});
    return std.fs.path.join(ctx.gpa, &.{ if (ctx.scope == .user) ctx.xdg_runtime_dir else "/run", file });
}

const ready_byte = 'k';

fn writePidFile(ctx: *core.Context, path: []const u8) bool {
    if (std.fs.path.dirname(path)) |dir| ctx.fs.makePath(dir) catch |e| {
        ctx.diag.err("cannot create {s}: {t}", .{ dir, e });
        return false;
    };
    const text = std.fmt.allocPrint(ctx.gpa, "{d}\n", .{linux.getpid()}) catch return false;
    ctx.fs.writeFileInPlace(path, text) catch |e| {
        ctx.diag.err("cannot write {s}: {t}", .{ path, e });
        return false;
    };
    return true;
}

/// Standard streams of the daemon go to `/dev/null`, so that a caller reading the output of
/// the command is not kept waiting by the detached process.
fn detachStreams() void {
    const rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const null_fd: i32 = @intCast(rc);
    for ([_]i32{ 0, 1, 2 }) |fd| _ = linux.dup2(null_fd, fd);
    if (null_fd > 2) sys.closeFd(null_fd);
}

/// Detaches the calling process. Returns the exit status of the original process, which has to
/// end with it, or null in the detached one, which carries on as the executor.
pub fn detach(ctx: *core.Context, unit_name: []const u8) ?u8 {
    const path = daemonPidPath(ctx, unit_name) catch {
        ctx.diag.err("{s}: out of memory", .{unit_name});
        return 1;
    };
    var fds: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        ctx.diag.err("{s}: cannot create the pipe to the daemon", .{unit_name});
        return 1;
    }
    switch (sys.fork()) {
        .failed => |e| {
            ctx.diag.err("{s}: cannot fork: {t}", .{ unit_name, e });
            return 1;
        },
        .parent => {
            sys.closeFd(fds[1]);
            var byte: [1]u8 = undefined;
            while (true) {
                const rc = linux.read(fds[0], &byte, 1);
                switch (linux.errno(rc)) {
                    .SUCCESS => return if (rc == 1 and byte[0] == ready_byte) 0 else 1,
                    .INTR => continue,
                    else => return 1,
                }
            }
        },
        .child => {},
    }
    sys.closeFd(fds[0]);
    if (linux.errno(linux.setsid()) != .SUCCESS) sys.exitNow(1);
    switch (sys.fork()) {
        .failed, .parent => sys.exitNow(0),
        .child => {},
    }
    _ = linux.chdir("/");
    detachStreams();
    if (!writePidFile(ctx, path)) sys.exitNow(1);
    const rc = linux.write(fds[1], &[1]u8{ready_byte}, 1);
    sys.closeFd(fds[1]);
    if (linux.errno(rc) != .SUCCESS) sys.exitNow(1);
    return null;
}

test "the pid file lies next to the other files of the unit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var diag: core.Diag = .init(&w, .notice);
    var fs: core.Fs = undefined;
    var ctx: core.Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .system, 0);
    try std.testing.expectEqualStrings("/run/fake-systemd/a.service.daemon.pid", try daemonPidPath(&ctx, "a.service"));
    ctx.scope = .user;
    ctx.xdg_runtime_dir = "/run/user/5";
    try std.testing.expectEqualStrings("/run/user/5/fake-systemd/a.service.daemon.pid", try daemonPidPath(&ctx, "a.service"));
}
