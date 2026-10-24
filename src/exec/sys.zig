// SPDX-License-Identifier: GPL-3.0-or-later
//! Thin wrappers over the Linux syscalls the executor needs. Failures are reported as the raw
//! errno; `.SUCCESS` means the call worked.
const std = @import("std");
const linux = std.os.linux;

pub const E = linux.E;

pub const Exit = union(enum) {
    exited: u8,
    signaled: u8,

    /// Shell convention: the exit code, or 128 plus the signal number.
    pub fn code(e: Exit) u8 {
        return switch (e) {
            .exited => |c| c,
            .signaled => |s| 128 +| s,
        };
    }
};

fn err(rc: usize) E {
    return linux.errno(rc);
}

pub const ForkResult = union(enum) { child, parent: i32, failed: E };

/// The process is single-threaded, so the child may allocate and use the standard library.
pub fn fork() ForkResult {
    const rc = linux.fork();
    return switch (err(rc)) {
        .SUCCESS => if (rc == 0) .child else .{ .parent = @intCast(rc) },
        else => |e| .{ .failed = e },
    };
}

/// Returns only on failure.
pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) E {
    return err(linux.execve(path, argv, envp));
}

pub fn exitNow(code: u8) noreturn {
    linux.exit_group(code);
}

pub fn waitPid(pid: i32) ?Exit {
    var status: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &status, 0, null);
        switch (err(rc)) {
            .SUCCESS => return decodeStatus(@bitCast(status)),
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn decodeStatus(status: u32) Exit {
    if (linux.W.IFEXITED(status)) return .{ .exited = linux.W.EXITSTATUS(status) };
    return .{ .signaled = @intCast(@backingInt(linux.W.TERMSIG(status))) };
}

/// Non-blocking wait on a specific child. Null when it is not a child of this process.
pub fn reapChild(pid: i32) ?Exit {
    var info: linux.siginfo_t = undefined;
    while (true) {
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED, null);
        switch (err(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        }
    }
    const code: u8 = @intCast(info.fields.common.second.sigchld.status & 0xff);
    return switch (info.code) {
        1 => .{ .exited = code },
        2, 3 => .{ .signaled = code },
        else => null,
    };
}

pub fn setGroups(gids: []const u32) E {
    return err(linux.setgroups(gids.len, gids.ptr));
}

pub fn setGid(gid: u32) E {
    return err(linux.setresgid(gid, gid, gid));
}

pub fn setUid(uid: u32) E {
    return err(linux.setresuid(uid, uid, uid));
}

pub fn noNewPrivileges() E {
    return err(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
}

pub fn childSubreaper() E {
    return err(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0));
}

pub fn setUmask(mask: u32) void {
    _ = linux.syscall1(.umask, mask);
}

pub fn setNice(nice: i8) E {
    return err(linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, nice)))));
}

pub fn setRlimit(resource: linux.rlimit_resource, soft: u64, hard: u64) E {
    const lim: linux.rlimit = .{ .cur = soft, .max = hard };
    return err(linux.setrlimit(resource, &lim));
}

pub fn chdir(path: [:0]const u8) E {
    return err(linux.chdir(path.ptr));
}

pub fn isExecutable(path: [:0]const u8) bool {
    return err(linux.access(path.ptr, 1)) == .SUCCESS and !isDirectory(path);
}

fn isDirectory(path: [:0]const u8) bool {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .TYPE = true }, &stx);
    return err(rc) == .SUCCESS and stx.mode & linux.S.IFMT == linux.S.IFDIR;
}

pub fn pidfdOpen(pid: i32) union(enum) { fd: i32, failed: E } {
    const rc = linux.pidfd_open(pid, 0);
    return switch (err(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        else => |e| .{ .failed = e },
    };
}

/// Waits until `fd` is readable or hung up; EINTR restarts the wait.
pub fn waitReadable(fd: i32, timeout_ms: i32) error{PollFailed}!bool {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
    while (true) {
        const rc = linux.poll(&fds, 1, timeout_ms);
        switch (err(rc)) {
            .SUCCESS => return rc > 0,
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

pub fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

pub fn kill(pid: i32, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

/// Reaps every exited child except `keep`, which stays waitable. Adopted orphans of a
/// subreaper would otherwise stay zombies.
pub fn reapOthers(keep: i32) void {
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.ALL, 0, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        if (err(rc) != .SUCCESS) return;
        const pid = info.fields.common.first.piduid.pid;
        if (pid == 0 or pid == keep) return;
        var status: i32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
    }
}
