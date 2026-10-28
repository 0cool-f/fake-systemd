// SPDX-License-Identifier: GPL-3.0-or-later
//! Checks the backends share before they write or act on what a unit or a service controls:
//! literal values, service names read back from generated files, process ids read from files a
//! service can write, and the ownership of the names a unit generates.
const std = @import("std");
const linux = std.os.linux;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const name_mod = @import("../unit/name.zig");
const marker = @import("../index/marker.zig");
const policy = @import("policy.zig");
const shell = @import("shell.zig");
const executor = @import("../exec/executor.zig");
const procs = @import("../exec/procs.zig");
const Index = @import("../index/Index.zig");
const IndexLayout = @import("../index/layout.zig");

pub const hasControl = policy.hasControl;

/// True when `name` can be the name of a service directory or script the backends create or
/// follow: the characters of a unit name, no `.` or `..`, and no leading `-` that a tool
/// would read as an option.
pub fn serviceNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > name_mod.max_len) return false;
    if (name[0] == '-' or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (!name_mod.isValidChar(c)) return false;
    return true;
}

/// First setting of `u` that a backend writes literally into a line-oriented file and that
/// holds a line break or NUL, or null. Command words and `Environment=` are not listed: they
/// reach the executor, which reads the unit itself.
pub fn controlInSetting(u: *const model.Unit) ?[]const u8 {
    if (u.description) |d| if (hasControl(d)) return "Description=";
    if (u.user) |v| if (hasControl(v)) return "User=";
    if (u.group) |v| if (hasControl(v)) return "Group=";
    if (listHasControl(u.supplementary_groups)) return "SupplementaryGroups=";
    if (u.working_directory) |v| if (hasControl(v)) return "WorkingDirectory=";
    if (u.pid_file) |v| if (hasControl(v)) return "PIDFile=";
    if (u.kill_signal) |v| if (hasControl(v)) return "KillSignal=";
    for (u.limits) |l| if (hasControl(l.key) or hasControl(l.value)) return "Limit*=";
    if (listHasControl(u.success_exit_status)) return "SuccessExitStatus=";
    for ([_][]const []const u8{ u.requires, u.wants, u.binds_to, u.after, u.before, u.conflicts, u.part_of }) |list| {
        if (listHasControl(list)) return "a dependency setting";
    }
    return null;
}

fn listHasControl(list: []const []const u8) bool {
    for (list) |item| if (hasControl(item)) return true;
    return false;
}

/// Refuses a unit whose service name or literal settings a backend cannot write safely.
pub fn checkUnit(ctx: *const core.Context, u: *const model.Unit, service: []const u8) error{Unsupported}!void {
    if (!serviceNameOk(service)) {
        ctx.diag.err("{s}: '{s}' is not a name the init can use for a service", .{ u.name.full, service });
        return error.Unsupported;
    }
    if (controlInSetting(u)) |what| {
        ctx.diag.err("{s}: {s} holds a line break or NUL, which the generated files cannot carry", .{ u.name.full, what });
        return error.Unsupported;
    }
}

/// Entries of the directory `dir`, none when it does not exist or is not a directory. Any other
/// failure is an error, so an unreadable directory is never taken for an empty one.
pub fn iterateOrEmpty(ctx: *const core.Context, dir: []const u8) ![]core.Fs.Entry {
    return ctx.fs.iterateDir(ctx.gpa, dir) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => &.{},
        else => e,
    };
}

/// Content of the file at `path`, null when it does not exist. Any other failure is an error, so a
/// file that cannot be read in full is never taken for an absent, native or foreign one.
pub fn readOrAbsent(ctx: *const core.Context, path: []const u8, max_size: usize) !?[]u8 {
    return ctx.fs.readFileAlloc(ctx.gpa, path, max_size) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// Unit recorded in the marker of the generated file `content`, null when it carries none.
pub fn unitOfMarked(content: []const u8) ?[]const u8 {
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

/// Services the generated service in `dir` starts before its own command, from the `Starts:`
/// lines of its meta file, in order; a name that is not a plain service name is dropped. Empty
/// when the directory has no meta file.
pub fn startedServices(ctx: *const core.Context, dir: []const u8) ![]const []const u8 {
    const gpa = ctx.gpa;
    const path = try std.fs.path.join(gpa, &.{ dir, marker.meta_name });
    const text = ctx.fs.readFileAlloc(gpa, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (try marker.metaStarts(gpa, text)) |name| {
        if (serviceNameOk(name)) try out.append(gpa, name);
    }
    return out.items;
}

// ---- ownership of generated names ----------------------------------------------------------

/// Who a generated file or directory belongs to.
pub const Claim = enum {
    /// Nothing is there.
    free,
    /// A file of the unit asked about.
    ours,
    /// A generated file of another unit.
    other_unit,
    /// Present without a marker of fake-systemd: a native service, whose handling is the
    /// business of the native-service decision.
    foreign,
};

/// Owner of the file at `path`, read from its comment marker.
pub fn claimFile(ctx: *const core.Context, path: []const u8, unit: []const u8) Claim {
    const content = ctx.fs.readFileAlloc(ctx.gpa, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => return .free,
        else => return .foreign,
    };
    const parsed = marker.parse(content) orelse return .foreign;
    return if (std.mem.eql(u8, parsed.marker.unit, unit)) .ours else .other_unit;
}

/// Owner of the service directory `dir`: its meta file, else the first of `entries` that
/// carries a marker. A directory that does not exist or is empty is free.
pub fn claimDir(ctx: *const core.Context, dir: []const u8, unit: []const u8, entries: []const []const u8) Claim {
    const gpa = ctx.gpa;
    const listing = ctx.fs.iterateDir(gpa, dir) catch |e| switch (e) {
        error.FileNotFound => return .free,
        else => return .foreign,
    };
    if (listing.len == 0) return .free;
    const meta = std.fs.path.join(gpa, &.{ dir, marker.meta_name }) catch return .foreign;
    if (ctx.fs.readFileAlloc(gpa, meta, 1 << 20)) |text| {
        const parsed = marker.parseMeta(gpa, text) catch return .foreign;
        const m = parsed orelse return .foreign;
        return if (std.mem.eql(u8, m.unit, unit)) .ours else .other_unit;
    } else |_| {}
    for (entries) |entry| {
        const path = std.fs.path.join(gpa, &.{ dir, entry }) catch return .foreign;
        switch (claimFile(ctx, path, unit)) {
            .free, .foreign => {},
            else => |c| return c,
        }
    }
    return .foreign;
}

/// Refuses a name that another generated unit already owns, which two unit names that map to
/// the same service name would otherwise silently share.
pub fn requireNotOther(ctx: *const core.Context, claim: Claim, unit: []const u8, path: []const u8) error{Unsupported}!void {
    if (claim != .other_unit) return;
    ctx.diag.err("{s}: {s} is already generated for another unit with the same service name", .{ unit, path });
    return error.Unsupported;
}

/// True when the service directory `dir` is gone or holds only what a supervisor and the
/// generation leave behind after the generated `run` was removed: `down`, `supervise`, `event`,
/// and `log` and `control` directories without scripts. A directory with anything else is a
/// service of someone else.
pub fn abandonedServiceDir(ctx: *const core.Context, dir: []const u8) bool {
    const gpa = ctx.gpa;
    const entries = ctx.fs.iterateDir(gpa, dir) catch |e| return e == error.FileNotFound;
    for (entries) |e| {
        if (supervisionName(e.name) or std.mem.eql(u8, e.name, "down")) continue;
        const nested = std.mem.eql(u8, e.name, "log") or std.mem.eql(u8, e.name, "control");
        if (!nested or e.kind != .directory) return false;
        const sub = std.fs.path.join(gpa, &.{ dir, e.name }) catch return false;
        const inner = ctx.fs.iterateDir(gpa, sub) catch return false;
        for (inner) |i| if (!supervisionName(i.name)) return false;
    }
    return true;
}

/// Directories the supervisors create in a service directory.
fn supervisionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "supervise") or std.mem.eql(u8, name, "event");
}

// ---- what the index says is ours -----------------------------------------------------------

/// Paths of every generated file the index of `backend` lists: `given` when the caller that holds
/// the index passes them, else the index on disk. Both are the state before the running
/// command, so a unit this command removes is still listed. Empty when there is no readable index.
pub fn indexedPaths(ctx: *const core.Context, given: ?[]const []const u8, backend: []const u8, generator: u32) []const []const u8 {
    if (given) |paths| return paths;
    const layout = IndexLayout.init(ctx.gpa, ctx.scope, ctx.xdg_state_home, backend) catch return &.{};
    const path = layout.indexPath(ctx.gpa) catch return &.{};
    var loaded = Index.load(ctx.gpa, ctx.fs.*, ctx.diag, path, backend, generator) catch return &.{};
    return pathsOfIndex(ctx.gpa, &loaded.index) catch &.{};
}

/// The paths of the generated files an index lists, for `Env.owned_paths`: taken when the command
/// starts, before units are removed from the index.
pub fn pathsOfIndex(gpa: std.mem.Allocator, index: *const Index) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (index.units.items) |unit| {
        for (unit.files) |file| try out.append(gpa, file.path);
    }
    return out.items;
}

/// Names of the directories directly below `root` that hold files carrying a marker of
/// fake-systemd, whichever unit they belong to.
pub fn markedDirs(ctx: *const core.Context, root: []const u8) ![]const []const u8 {
    const gpa = ctx.gpa;
    const entries = try iterateOrEmpty(ctx, root);
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (e.kind != .directory) continue;
        const dir = try std.fs.path.join(gpa, &.{ root, e.name });
        if (claimDir(ctx, dir, "", &.{ "run", "up" }) != .other_unit) continue;
        try out.append(gpa, e.name);
    }
    return out.items;
}

fn recordPath(ctx: *const core.Context, backend: []const u8, file: []const u8) ?[]const u8 {
    const layout = IndexLayout.init(ctx.gpa, ctx.scope, ctx.xdg_state_home, backend) catch return null;
    return std.fs.path.join(ctx.gpa, &.{ layout.state_dir, backend, file }) catch null;
}

/// Names a backend kept in the state file `file` of its state directory, one per line.
pub fn readNames(ctx: *const core.Context, backend: []const u8, file: []const u8) ![]const []const u8 {
    const path = recordPath(ctx, backend, file) orelse return error.OutOfMemory;
    const text = (try readOrAbsent(ctx, path, 1 << 20)) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try out.append(ctx.gpa, line);
    }
    return out.items;
}

/// Replaces the state file `file` with `names`, one per line.
pub fn writeNames(ctx: *const core.Context, backend: []const u8, file: []const u8, names: []const []const u8) !void {
    const path = recordPath(ctx, backend, file) orelse return error.OutOfMemory;
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    for (names) |n| try out.writer.print("{s}\n", .{n});
    try ctx.fs.makePath(std.fs.path.dirname(path) orelse "/");
    try ctx.fs.writeFileAtomic(path, out.written(), 0o644);
}

/// True when one of `paths` is `dir` or lies below it.
pub fn anyUnder(paths: []const []const u8, dir: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, dir)) return true;
        if (std.mem.startsWith(u8, p, dir) and p.len > dir.len and p[dir.len] == '/') return true;
    }
    return false;
}

/// Sets the permission bits of `path` through the open file, so its owner, links and
/// attributes stay as they are.
pub fn chmodInPlace(ctx: *const core.Context, path: []const u8, mode: u16) !void {
    const real = try ctx.fs.realpath(ctx.gpa, path);
    const sub = std.mem.trimStart(u8, real, "/");
    const file = try ctx.fs.root.openFile(ctx.io, if (sub.len == 0) "." else sub, .{});
    defer file.close(ctx.io);
    try file.setPermissions(ctx.io, .fromMode(mode));
}

// ---- process ids ---------------------------------------------------------------------------

/// Owner and permission bits of a pid file, taken from the descriptor it was read through.
pub const Owner = struct { uid: u32, mode: u16 };

/// What a pid file holds: the pid, the start time when the file is an executor record, and who
/// owns the file.
const PidRead = struct { pid: u32, start: ?u64, owner: Owner };

/// Opens `path` without following a link, checks the open file is a regular one and reads it
/// through the same descriptor, so that nothing can be swapped in between.
fn readPidFile(ctx: *const core.Context, path: []const u8) ?PidRead {
    const file = ctx.fs.openNoFollow(path, .{}) catch return null;
    defer file.close(ctx.io);
    const info = core.Fs.fileInfo(file) catch return null;
    if (info.kind != .file) return null;
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(file.handle, buf[len..].ptr, buf.len - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (rc == 0) break;
        len += rc;
    }
    var fields = std.mem.tokenizeAny(u8, buf[0..len], " \t\r\n");
    const pid = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const start: ?u64 = if (fields.next()) |f| std.fmt.parseInt(u64, f, 10) catch null else null;
    return .{ .pid = pid, .start = start, .owner = .{ .uid = info.uid, .mode = info.mode } };
}

/// Reads a file whose size `stat` does not tell, as those of `/proc`, into `buf`.
fn readUnsized(ctx: *const core.Context, path: []const u8, buf: []u8) ?[]const u8 {
    const real = ctx.fs.realpath(ctx.gpa, path) catch return null;
    const file = ctx.fs.root.openFile(ctx.io, std.mem.trimStart(u8, real, "/"), .{}) catch return null;
    defer file.close(ctx.io);
    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(file.handle, buf[len..].ptr, buf.len - len);
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

/// True when process `pid` has the name `comm` in `/proc/<pid>/comm`.
pub fn hasName(ctx: *const core.Context, pid: u32, comm: []const u8) bool {
    const path = std.fmt.allocPrint(ctx.gpa, "/proc/{d}/comm", .{pid}) catch return false;
    var buf: [64]u8 = undefined;
    const text = readUnsized(ctx, path, &buf) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text, " \r\n"), comm);
}

/// Real uid of process `pid` from `/proc/<pid>/status`; null when there is no such process.
pub fn processUid(ctx: *const core.Context, pid: u32) ?u32 {
    const path = std.fmt.allocPrint(ctx.gpa, "/proc/{d}/status", .{pid}) catch return null;
    var buf: [8192]u8 = undefined;
    const text = readUnsized(ctx, path, &buf) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, line, "Uid:") orelse continue;
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        return std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch null;
    }
    return null;
}

/// True when root may signal `pid`. It has to be above 1. A pid read from a file the service may
/// have written, described by `file`, also has to name a live process and come from a file only
/// root or the owner of the process can have written: root-owned and closed to group and others,
/// or owned by the uid of the process. A pid the init reports itself passes no file.
pub fn acceptPid(ctx: *const core.Context, pid: u32, file: ?Owner) bool {
    if (pid <= 1) return false;
    const owner = file orelse return true;
    const uid = processUid(ctx, pid) orelse return false;
    if (owner.uid == 0) return owner.mode & 0o022 == 0;
    return owner.uid == uid;
}

/// `pid` when `acceptPid` allows it.
pub fn accepted(ctx: *const core.Context, pid: ?u32, file: ?Owner) ?u32 {
    const p = pid orelse return null;
    return if (acceptPid(ctx, p, file)) p else null;
}

/// The pid in a pid file that a native service keeps, when `acceptPid` allows signaling it.
pub fn pidFromFile(ctx: *const core.Context, path: []const u8) ?u32 {
    const read = readPidFile(ctx, path) orelse return null;
    return accepted(ctx, read.pid, read.owner);
}

/// Start time of process `pid` from `/proc/<pid>/stat`; null when there is no such process.
fn processStart(ctx: *const core.Context, pid: u32) ?u64 {
    const path = std.fmt.allocPrint(ctx.gpa, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    return procs.startTimeOfStat(readUnsized(ctx, path, &buf) orelse return null);
}

/// The main process of a generated service from the state file its executor writes. The file
/// holds `<pid> <start time>` and counts only while that process still has that start time, so
/// a pid that was reused, or a file the executor did not write, signals nothing.
pub fn recordedPid(ctx: *const core.Context, path: []const u8) ?u32 {
    const read = readPidFile(ctx, path) orelse return null;
    const start = read.start orelse return null;
    if ((processStart(ctx, read.pid) orelse return null) != start) return null;
    return accepted(ctx, read.pid, read.owner);
}

const testing = std.testing;

test "control characters" {
    try testing.expect(hasControl("a\nb"));
    try testing.expect(hasControl("a\rb"));
    try testing.expect(hasControl("a\x00b"));
    try testing.expect(!hasControl("a b\tc"));
}

test "service names reject paths, dots and leading dashes" {
    try testing.expect(serviceNameOk("sshd"));
    try testing.expect(serviceNameOk("getty@tty1"));
    try testing.expect(serviceNameOk("a.b-c_d:e"));
    try testing.expect(!serviceNameOk(""));
    try testing.expect(!serviceNameOk(".."));
    try testing.expect(!serviceNameOk("."));
    try testing.expect(!serviceNameOk("../sv/sshd"));
    try testing.expect(!serviceNameOk("a/b"));
    try testing.expect(!serviceNameOk("-x"));
    try testing.expect(!serviceNameOk("a\nb"));
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: core.Fs,
    env: std.process.Environ.Map,
    out: std.Io.Writer.Allocating,
    diag: core.Diag,
    ctx: core.Context,

    fn init(f: *Fixture) !void {
        f.arena = .init(testing.allocator);
        const a = f.arena.allocator();
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.fs = .initDir(testing.io, f.tmp.dir);
        f.env = .init(a);
        f.out = .init(a);
        f.diag = .init(&f.out.writer, .notice);
        f.ctx = try .init(a, testing.io, &f.fs, &f.diag, &f.env, .system, 0);
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn write(f: *Fixture, path: []const u8, content: []const u8, mode: u16) !void {
        try f.fs.makePath(std.fs.path.dirname(path).?);
        try f.fs.writeFileAtomic(path, content, mode);
    }

    /// A process of the tmp root whose real uid is `uid` and whose start time is `start`.
    fn process(f: *Fixture, pid: u32, uid: u32, start: u64) !void {
        const path = try std.fmt.allocPrint(f.arena.allocator(), "/proc/{d}/status", .{pid});
        const text = try std.fmt.allocPrint(f.arena.allocator(), "Name:\tx\nUid:\t{d}\t{d}\t{d}\t{d}\n", .{ uid, uid, uid, uid });
        try f.write(path, text, 0o644);
        const stat_path = try std.fmt.allocPrint(f.arena.allocator(), "/proc/{d}/stat", .{pid});
        const stat = try std.fmt.allocPrint(f.arena.allocator(), "{d} (a b) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 {d} 0 0\n", .{ pid, start });
        try f.write(stat_path, stat, 0o644);
    }
};

test "a pid is never accepted for init or for nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.process(1, 0, 1);
    try f.process(2, 0, 1);
    try f.write("/run/x.pid", "1\n", 0o644);
    try testing.expect(!acceptPid(&f.ctx, 0, null));
    try testing.expect(!acceptPid(&f.ctx, 1, null));
    try testing.expect(pidFromFile(&f.ctx, "/run/x.pid") == null);
    try testing.expect(acceptPid(&f.ctx, 2, null));
}

test "a pid from a file needs a live process and an owner that can vouch for it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const me = std.os.linux.getuid();
    try f.write("/run/x.pid", "100\n", 0o644);
    // No such process.
    try testing.expect(pidFromFile(&f.ctx, "/run/x.pid") == null);
    try f.process(100, me, 1);
    try testing.expectEqual(@as(?u32, 100), pidFromFile(&f.ctx, "/run/x.pid"));
    if (me == 0) {
        // A root-owned file that others can write is not trusted, whoever owns the process.
        try f.write("/run/open.pid", "100\n", 0o666);
        try testing.expect(pidFromFile(&f.ctx, "/run/open.pid") == null);
        // A root-owned, closed file vouches for a process of any account.
        try f.write("/run/y.pid", "101\n", 0o644);
        try f.process(101, 1000, 1);
        try testing.expectEqual(@as(?u32, 101), pidFromFile(&f.ctx, "/run/y.pid"));
    } else {
        // A file owned by an account only vouches for the processes of that account.
        try f.write("/run/y.pid", "101\n", 0o644);
        try f.process(101, me + 1, 1);
        try testing.expect(pidFromFile(&f.ctx, "/run/y.pid") == null);
    }
}

test "a pid file that is a symlink is not read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.process(100, std.os.linux.getuid(), 1);
    try f.write("/run/real.pid", "100\n", 0o644);
    try f.fs.symLink("real.pid", "/run/link.pid");
    try testing.expectEqual(@as(?u32, 100), pidFromFile(&f.ctx, "/run/real.pid"));
    try testing.expect(pidFromFile(&f.ctx, "/run/link.pid") == null);
    try testing.expect(recordedPid(&f.ctx, "/run/link.pid") == null);
}

test "a pid file that is not a regular file is not read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.process(100, std.os.linux.getuid(), 1);
    try f.fs.makePath("/run");
    const dir = f.tmp.dir.handle;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(dir, "run/p.pid", linux.S.IFIFO | 0o644, 0)));
    // The reader keeps the data of the FIFO alive after its writer is gone, so that reading it would end.
    const keep = linux.openat(dir, "run/p.pid", .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(keep));
    defer _ = linux.close(@intCast(keep));
    const w = linux.openat(dir, "run/p.pid", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(w));
    const text = "100 1\n";
    try testing.expectEqual(text.len, linux.write(@intCast(w), text, text.len));
    _ = linux.close(@intCast(w));
    try testing.expect(pidFromFile(&f.ctx, "/run/p.pid") == null);
    try testing.expect(recordedPid(&f.ctx, "/run/p.pid") == null);
}

test "a recorded pid counts only while the process has the recorded start time" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.process(100, std.os.linux.getuid(), 777);
    try f.write("/run/a.pid", "100 777\n", 0o644);
    try testing.expectEqual(@as(?u32, 100), recordedPid(&f.ctx, "/run/a.pid"));
    // The pid was reused by another process.
    try f.write("/run/b.pid", "100 778\n", 0o644);
    try testing.expect(recordedPid(&f.ctx, "/run/b.pid") == null);
    // A bare pid is not a record.
    try f.write("/run/c.pid", "100\n", 0o644);
    try testing.expect(recordedPid(&f.ctx, "/run/c.pid") == null);
}

test "a service directory holds leftovers only when nothing but supervision files remain" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expect(abandonedServiceDir(&f.ctx, "/etc/sv/gone"));
    try f.write("/etc/sv/left/down", "", 0o644);
    try f.write("/etc/sv/left/supervise/lock", "", 0o644);
    try f.write("/etc/sv/left/log/supervise/lock", "", 0o644);
    try f.write("/etc/sv/left/event/ready", "", 0o644);
    try testing.expect(abandonedServiceDir(&f.ctx, "/etc/sv/left"));
    try f.write("/etc/sv/mine/conf", "", 0o644);
    try testing.expect(!abandonedServiceDir(&f.ctx, "/etc/sv/mine"));
    try f.write("/etc/sv/logrun/log/run", "", 0o755);
    try testing.expect(!abandonedServiceDir(&f.ctx, "/etc/sv/logrun"));
}

test "a name is owned by the unit whose marker it carries" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectEqual(Claim.free, claimFile(&f.ctx, "/etc/init.d/foo", "foo.service"));
    const mine = try marker.compose(a, "foo.service", "/s", 1, "g", "#!/bin/sh\n");
    try f.write("/etc/init.d/foo", mine, 0o755);
    try testing.expectEqual(Claim.ours, claimFile(&f.ctx, "/etc/init.d/foo", "foo.service"));
    try testing.expectEqual(Claim.other_unit, claimFile(&f.ctx, "/etc/init.d/foo", "foo@x.service"));
    try f.write("/etc/init.d/native", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(Claim.foreign, claimFile(&f.ctx, "/etc/init.d/native", "foo.service"));
    try testing.expectError(error.Unsupported, requireNotOther(&f.ctx, .other_unit, "foo.service", "/etc/init.d/foo"));
    try requireNotOther(&f.ctx, .foreign, "foo.service", "/etc/init.d/native");
}

test "settings that a line-oriented file cannot hold are found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u: model.Unit = .{ .name = try name_mod.parse(arena.allocator(), "foo.service"), .scope = .system };
    try testing.expect(controlInSetting(&u) == null);
    u.description = "one\ntwo";
    try testing.expectEqualStrings("Description=", controlInSetting(&u).?);
    u.description = null;
    u.after = &.{"a\nb"};
    try testing.expectEqualStrings("a dependency setting", controlInSetting(&u).?);
}

// ---- the identity of an executor phase that runs outside the generated scripts ------------------

fn accountListed(ctx: *const core.Context, file: []const u8, account: []const u8) bool {
    if (shell.allDigits(account)) return true;
    const content = ctx.fs.readFileAlloc(ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

/// The numeric ids a shell has to look up for the account of `u`, when the static executor cannot
/// resolve the account from `/etc/passwd` and `/etc/group` (LDAP, sssd) or the names are not plain.
pub fn numericOf(ctx: *const core.Context, u: *const model.Unit) ?shell.Numeric {
    if (u.scope == .user) return null;
    const user = u.user orelse return null;
    var known = accountListed(ctx, "/etc/passwd", user);
    if (u.group) |g| known = known and accountListed(ctx, "/etc/group", g);
    for (u.supplementary_groups) |g| known = known and accountListed(ctx, "/etc/group", g);
    if (known) return null;
    var plain = shell.plainAccount(user);
    if (u.group) |g| plain = plain and shell.plainAccount(g);
    for (u.supplementary_groups) |g| plain = plain and shell.plainAccount(g);
    if (!plain) return null;
    return .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups };
}

/// Words that go in front of the executor for a phase the init system does not start, so that the
/// root executor gets the numeric ids of an account only the system libc resolves. Empty for
/// every other unit, and when the unit cannot be read, which the executor then reports itself.
pub fn executorPrefix(ctx: *core.Context, unit_name: []const u8) []const []const u8 {
    const u = executor.loadUnit(ctx, unit_name) catch return &.{};
    const n = numericOf(ctx, &u) orelse return &.{};
    return shell.identityPrefix(ctx.gpa, n) catch &.{};
}

test "only an all-digit name counts as numeric, and a dashed name is never looked up" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("/etc/passwd", "root:x:0:0::/root:/bin/sh\n", 0o644);
    try f.write("/etc/group", "root:x:0:\n", 0o644);
    const a = f.arena.allocator();
    var u: model.Unit = .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
    u.user = "1000";
    try testing.expect(numericOf(&f.ctx, &u) == null);
    u.user = "1abc";
    try testing.expectEqualStrings("1abc", numericOf(&f.ctx, &u).?.user);
    u.user = "root";
    try testing.expect(numericOf(&f.ctx, &u) == null);
    u.user = "ldapuser";
    u.group = "4abc";
    try testing.expectEqualStrings("4abc", numericOf(&f.ctx, &u).?.group.?);
    for ([_][]const u8{ "-r", "--", "-u" }) |bad| {
        u.user = bad;
        u.group = null;
        try testing.expect(numericOf(&f.ctx, &u) == null);
        u.user = "ldapuser";
        u.group = bad;
        try testing.expect(numericOf(&f.ctx, &u) == null);
    }
}
