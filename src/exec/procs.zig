// SPDX-License-Identifier: GPL-3.0-or-later
//! Which processes the executor may treat as the main process of a unit. A pid read from a
//! file that the service can write is only a claim, so it is checked against `/proc` before
//! the executor signals it with its own privileges.
const std = @import("std");
const linux = std.os.linux;

/// Where a pid came from.
pub const Source = struct {
    /// The uid the service runs as.
    service_uid: u32,
    /// Owner of the file the pid was read from; null when it did not come from a file.
    file_owner: ?u32 = null,
};

const max_ancestors = 64;

fn readProc(buf: []u8, pid: i32, name: []const u8) ?[]const u8 {
    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/{s}", .{ pid, name }, 0) catch return null;
    const open_rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (rc == 0) break;
        len += rc;
    }
    return buf[0..len];
}

/// Parent of `pid`, or null when the process does not exist.
pub fn parentOf(pid: i32) ?i32 {
    var buf: [1024]u8 = undefined;
    const text = readProc(&buf, pid, "stat") orelse return null;
    // The command name is in parentheses and may contain anything, so fields start after the last one.
    const close_paren = std.mem.findScalarLast(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close_paren + 1 ..], ' ');
    _ = fields.next() orelse return null;
    return std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch null;
}

/// Start time, in clock ticks after boot, from the text of `/proc/<pid>/stat`.
pub fn startTimeOfStat(text: []const u8) ?u64 {
    const close_paren = std.mem.findScalarLast(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close_paren + 1 ..], ' ');
    var index: usize = 3;
    while (fields.next()) |f| : (index += 1) {
        if (index == 22) return std.fmt.parseInt(u64, f, 10) catch null;
    }
    return null;
}

/// Start time of `pid`, which tells the process from a later one that reuses the pid.
pub fn startTime(pid: i32) ?u64 {
    var buf: [1024]u8 = undefined;
    return startTimeOfStat(readProc(&buf, pid, "stat") orelse return null);
}

/// A main process as the executor records it: the pid and its start time.
pub const Record = struct { pid: i32, start: u64 };

/// Parses `<pid> <start time>`; a bare pid is not a record.
pub fn parseRecord(text: []const u8) ?Record {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const start = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    return .{ .pid = pid, .start = start };
}

/// True when `record` still names the process it was taken from.
pub fn recordLives(record: Record) bool {
    return (startTime(record.pid) orelse return false) == record.start;
}

/// A pid that a daemon started by this executor can have: a live descendant, which an orphan
/// stays while the executor is its subreaper.
pub fn acceptableDescendant(pid: i32) bool {
    if (pid <= 1 or pid == linux.getpid()) return false;
    return isDescendant(pid, linux.getpid());
}

pub const Uids = struct { real: u32, effective: u32 };

pub fn uidsOf(pid: i32) ?Uids {
    var buf: [4096]u8 = undefined;
    const text = readProc(&buf, pid, "status") orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var f = std.mem.tokenizeAny(u8, line["Uid:".len..], " \t");
        const real = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
        const effective = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
        return .{ .real = real, .effective = effective };
    }
    return null;
}

/// True when `ancestor` is among the parents of `pid`: an orphan is reparented to a
/// subreaper, so a daemon that the executor started stays below it.
pub fn isDescendant(pid: i32, ancestor: i32) bool {
    var cur = pid;
    var depth: usize = 0;
    while (depth < max_ancestors) : (depth += 1) {
        const parent = parentOf(cur) orelse return false;
        if (parent == ancestor) return true;
        if (parent <= 1) return false;
        cur = parent;
    }
    return false;
}

/// A pid is acceptable when it is above 1, is not the executor, names a live process and
/// either was written by root, descends from the executor, or runs as the service or as the
/// owner of the file that named it (a process can only claim processes of its own account).
pub fn acceptable(pid: i32, src: Source) bool {
    if (pid <= 1 or pid == linux.getpid()) return false;
    if (parentOf(pid) == null) return false;
    if (src.file_owner) |owner| if (owner == 0) return true;
    if (isDescendant(pid, linux.getpid())) return true;
    const uids = uidsOf(pid) orelse return false;
    if (uids.real != uids.effective) return false;
    return uids.real == src.service_uid or (src.file_owner != null and uids.real == src.file_owner.?);
}

test "pids 0, 1 and our own are never acceptable" {
    try std.testing.expect(!acceptable(0, .{ .service_uid = 0 }));
    try std.testing.expect(!acceptable(-5, .{ .service_uid = 0 }));
    try std.testing.expect(!acceptable(1, .{ .service_uid = 0, .file_owner = 0 }));
    try std.testing.expect(!acceptable(linux.getpid(), .{ .service_uid = linux.geteuid() }));
}

test "our parent runs as our uid and a missing process is refused" {
    const parent: i32 = @intCast(linux.getppid());
    try std.testing.expect(parentOf(linux.getpid()).? == parent);
    try std.testing.expect(uidsOf(linux.getpid()).?.real == linux.getuid());
    try std.testing.expect(parentOf(std.math.maxInt(i32) - 1) == null);
    try std.testing.expect(!acceptable(std.math.maxInt(i32) - 1, .{ .service_uid = 0, .file_owner = 0 }));
}

/// Checks run in a child of the test process, whose parent is then a live process that is not
/// init and does not descend from the child, whatever started the test.
fn parentIsJudgedByAccount() bool {
    const parent: i32 = @intCast(linux.getppid());
    if (parent <= 1) return false;
    const other = linux.geteuid() +% 1;
    // The parent does not descend from the child and runs as its uid, not as `other`.
    if (acceptable(parent, .{ .service_uid = other, .file_owner = other })) return false;
    if (!acceptable(parent, .{ .service_uid = linux.geteuid() })) return false;
    return acceptable(parent, .{ .service_uid = other, .file_owner = 0 });
}

test "a process of another account is refused unless root wrote the pid" {
    const forked = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(forked));
    if (forked == 0) linux.exit_group(if (parentIsJudgedByAccount()) 0 else 1);
    var status: i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.waitpid(@intCast(forked), &status, 0)));
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(linux.W.IFEXITED(wait_status));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(wait_status));
}
