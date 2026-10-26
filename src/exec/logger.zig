// SPDX-License-Identifier: GPL-3.0-or-later
//! The uniform per-unit logger (spec §6.7): reads lines from a descriptor, prefixes each with an
//! ISO 8601 timestamp that carries the local UTC offset, appends them to `<dir>/current` and
//! rotates by size into `@<unix-seconds>.log`. Write failures never stop the reading side, so
//! the service writing into the pipe is never blocked by them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const Fs = core.Fs;
const tz_mod = @import("tz.zig");
const logpath = @import("logpath.zig");
const name_mod = @import("../unit/name.zig");

pub const current_name = "current";
const lock_name = ".lock";
const lock_exclusive = 2;
const lock_unlock = 8;

pub const Options = struct {
    /// Size at which `current` is rotated.
    max_size: u64 = 1 << 20,
    /// Files kept, `current` included.
    keep: u32 = 10,
    /// Longest message written as one line; longer input is split.
    max_line: usize = 64 * 1024,
};

/// `2026-10-24T12:05:01.123+02:00`
pub fn formatTimestamp(buf: []u8, unix_ms: i64, offset: i32) []const u8 {
    const secs = @divFloor(unix_ms, 1000);
    const ms: u32 = @intCast(@mod(unix_ms, 1000));
    const c = tz_mod.civilFromUnix(secs, offset);
    const abs_off: u32 = @abs(offset);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(c.year)), c.month,                               c.day,
        c.hour,                     c.minute,                              c.second,
        ms,                         @as(u8, if (offset < 0) '-' else '+'), abs_off / 3600,
        abs_off % 3600 / 60,
    }) catch unreachable;
}

pub const Parsed = struct {
    unix_ms: i64,
    /// The message after the timestamp and its separating space.
    message: []const u8,
};

/// Splits a log line into its timestamp and message; null when the line has no valid prefix.
pub fn parseLine(line: []const u8) ?Parsed {
    // YYYY-MM-DDTHH:MM:SS[.fff...]+HH:MM
    if (line.len < 25 or line[4] != '-' or line[7] != '-' or line[10] != 'T' or line[13] != ':' or line[16] != ':') return null;
    const year = std.fmt.parseInt(i32, line[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, line[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, line[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, line[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, line[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, line[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    var pos: usize = 19;
    var ms: i64 = 0;
    if (line[pos] == '.') {
        pos += 1;
        var digits: usize = 0;
        while (pos < line.len and std.ascii.isDigit(line[pos])) : (pos += 1) {
            if (digits < 3) ms = ms * 10 + (line[pos] - '0');
            digits += 1;
        }
        if (digits == 0) return null;
        while (digits < 3) : (digits += 1) ms *= 10;
    }
    if (pos + 6 > line.len or (line[pos] != '+' and line[pos] != '-') or line[pos + 3] != ':') return null;
    const oh = std.fmt.parseInt(i32, line[pos + 1 .. pos + 3], 10) catch return null;
    const om = std.fmt.parseInt(i32, line[pos + 4 .. pos + 6], 10) catch return null;
    const offset: i32 = (oh * 3600 + om * 60) * @as(i32, if (line[pos] == '-') -1 else 1);
    pos += 6;
    if (pos < line.len and line[pos] != ' ') return null;
    const local = tz_mod.unixFromCivil(.{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second });
    return .{
        .unix_ms = (local - offset) * 1000 + ms,
        .message = if (pos < line.len) line[pos + 1 ..] else "",
    };
}

fn isRotatedName(name: []const u8) bool {
    if (name.len < 6 or name[0] != '@' or !std.mem.endsWith(u8, name, ".log")) return false;
    for (name[1 .. name.len - 4]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn rotatedLess(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

/// Names of the rotated files in `dir` (an in-root path), oldest first. A missing directory
/// yields no files.
pub fn rotatedFiles(gpa: Allocator, fs: Fs, dir: []const u8) Allocator.Error![]const []const u8 {
    const entries = fs.iterateDir(gpa, dir) catch return &.{};
    defer Fs.freeEntries(gpa, entries);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (entries) |e| {
        if (e.kind == .file and isRotatedName(e.name)) try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, rotatedLess);
    return names.toOwnedSlice(gpa);
}

/// Repositions `fd` and returns the new offset; 32-bit targets go through `llseek`.
pub fn seek(fd: i32, offset: i64, whence: u32) !u64 {
    if (@sizeOf(usize) == 4) {
        var result: i64 = 0;
        switch (linux.errno(linux.llseek(fd, offset, &result, whence))) {
            .SUCCESS => return @intCast(result),
            else => |e| return errnoError(e),
        }
    }
    const rc = linux.lseek(fd, offset, whence);
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        else => |e| return errnoError(e),
    }
}

pub const Logger = struct {
    gpa: Allocator,
    fs: Fs,
    diag: *core.Diag,
    /// In-root path of the unit's log directory.
    dir: []const u8,
    tz: tz_mod.Tz,
    opts: Options,
    fd: ?i32 = null,
    /// Descriptor of `<dir>/.lock`, which serializes rotation between loggers of the same unit.
    lock_fd: ?i32 = null,
    size: u64 = 0,
    lost: u64 = 0,
    line: std.ArrayList(u8) = .empty,

    /// Creates the directory; the file is opened lazily by the first line.
    pub fn init(gpa: Allocator, fs: Fs, diag: *core.Diag, dir: []const u8, tz: tz_mod.Tz, opts: Options) Logger {
        var l: Logger = .{ .gpa = gpa, .fs = fs, .diag = diag, .dir = dir, .tz = tz, .opts = opts };
        l.opts.keep = @max(opts.keep, 1);
        fs.makePath(dir) catch |e| l.report("cannot create {s}: {t}", .{ dir, e });
        return l;
    }

    pub fn deinit(l: *Logger) void {
        l.closeFile();
        if (l.lock_fd) |fd| _ = linux.close(fd);
        l.lock_fd = null;
        l.line.deinit(l.gpa);
    }

    fn closeFile(l: *Logger) void {
        if (l.fd) |fd| _ = linux.close(fd);
        l.fd = null;
    }

    fn report(l: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (l.lost == 0) l.diag.warn("log: " ++ fmt, args);
        l.lost += 1;
    }

    fn path(l: *Logger, name: []const u8) ![:0]const u8 {
        const real = try l.fs.realpath(l.gpa, l.dir);
        defer l.gpa.free(real);
        const joined = try std.fs.path.joinZ(l.gpa, &.{ std.mem.trimStart(u8, real, "/"), name });
        return joined;
    }

    fn open(l: *Logger) !void {
        const rel = try l.path(current_name);
        defer l.gpa.free(rel);
        const rc = linux.openat(l.fs.root.handle, rel.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o644);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| return errnoError(e),
        }
        const fd: i32 = @intCast(rc);
        l.size = seek(fd, 0, linux.SEEK.END) catch 0;
        l.fd = fd;
    }

    fn openLock(l: *Logger) !i32 {
        if (l.lock_fd) |fd| return fd;
        const rel = try l.path(lock_name);
        defer l.gpa.free(rel);
        const rc = linux.openat(l.fs.root.handle, rel.ptr, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o644);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| return errnoError(e),
        }
        l.lock_fd = @intCast(rc);
        return l.lock_fd.?;
    }

    /// True when `current` on disk is no longer the file this logger has open.
    fn replaced(l: *Logger) !bool {
        const fd = l.fd orelse return true;
        const ours = try (Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).stat(l.fs.io);
        const current = try std.fs.path.join(l.gpa, &.{ l.dir, current_name });
        defer l.gpa.free(current);
        const theirs = l.fs.stat(current) catch |e| switch (e) {
            error.FileNotFound => return true,
            else => return e,
        };
        return theirs.inode != ours.inode;
    }

    /// Rotates `current` under the lock of the log directory, unless another logger did it since
    /// this one opened the file; the caller opens the new `current` either way.
    fn rotate(l: *Logger, unix_secs: i64) !void {
        const lock = try l.openLock();
        while (true) switch (linux.errno(linux.flock(lock, lock_exclusive))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| return errnoError(e),
        };
        defer _ = linux.flock(lock, lock_unlock);
        const done = try l.replaced();
        l.closeFile();
        if (done) return;
        const current = try std.fs.path.join(l.gpa, &.{ l.dir, current_name });
        defer l.gpa.free(current);
        var secs = unix_secs;
        while (true) : (secs += 1) {
            const name = try std.fmt.allocPrint(l.gpa, "@{d}.log", .{secs});
            defer l.gpa.free(name);
            const target = try std.fs.path.join(l.gpa, &.{ l.dir, name });
            defer l.gpa.free(target);
            if (l.fs.exists(target)) continue;
            try l.fs.rename(current, target);
            break;
        }
        try l.prune();
    }

    fn prune(l: *Logger) !void {
        const names = try rotatedFiles(l.gpa, l.fs, l.dir);
        defer {
            for (names) |n| l.gpa.free(n);
            l.gpa.free(names);
        }
        const allowed = l.opts.keep - 1;
        if (names.len <= allowed) return;
        for (names[0 .. names.len - allowed]) |n| {
            const target = try std.fs.path.join(l.gpa, &.{ l.dir, n });
            defer l.gpa.free(target);
            l.fs.deleteFile(target) catch |e| l.diag.warn("log: cannot remove {s}: {t}", .{ target, e });
        }
    }

    /// Writes one message as one log line. Failures are counted, never returned.
    pub fn writeLine(l: *Logger, unix_ms: i64, message: []const u8) void {
        l.write(unix_ms, message) catch |e| l.report("cannot write to {s}: {t}", .{ l.dir, e });
    }

    fn write(l: *Logger, unix_ms: i64, message: []const u8) !void {
        l.line.clearRetainingCapacity();
        var ts_buf: [40]u8 = undefined;
        const ts = formatTimestamp(&ts_buf, unix_ms, l.tz.offsetAt(@divFloor(unix_ms, 1000)));
        try l.line.ensureTotalCapacity(l.gpa, ts.len + message.len + 2);
        l.line.appendSliceAssumeCapacity(ts);
        l.line.appendAssumeCapacity(' ');
        l.line.appendSliceAssumeCapacity(message);
        l.line.appendAssumeCapacity('\n');

        if (l.fd == null) try l.open();
        // Other loggers append to the same file, so the size is read, not counted.
        l.size = seek(l.fd.?, 0, linux.SEEK.END) catch l.size;
        if (l.size > 0 and l.size + l.line.items.len > l.opts.max_size) {
            try l.rotate(@divFloor(unix_ms, 1000));
            try l.open();
        }
        var rest: []const u8 = l.line.items;
        while (rest.len > 0) {
            const rc = linux.write(l.fd.?, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    rest = rest[rc..];
                    l.size += rc;
                },
                .INTR => continue,
                else => |e| {
                    // The file may have been removed or the disk filled; reopen on the next line.
                    l.closeFile();
                    return errnoError(e);
                },
            }
        }
    }

    /// Splits `data` at newlines and writes the complete lines, cutting any longer than
    /// `max_line`. Returns the number of bytes consumed; the rest is an incomplete line.
    pub fn feed(l: *Logger, unix_ms: i64, data: []const u8) usize {
        var start: usize = 0;
        while (true) {
            const pending = data[start..];
            if (std.mem.findScalar(u8, pending, '\n')) |nl| {
                l.emit(unix_ms, pending[0..nl]);
                start += nl + 1;
            } else if (pending.len >= l.opts.max_line) {
                l.writeLine(unix_ms, pending[0..l.opts.max_line]);
                start += l.opts.max_line;
            } else return start;
        }
    }

    fn emit(l: *Logger, unix_ms: i64, text: []const u8) void {
        var rest = text;
        while (rest.len > l.opts.max_line) {
            l.writeLine(unix_ms, rest[0..l.opts.max_line]);
            rest = rest[l.opts.max_line..];
        }
        l.writeLine(unix_ms, rest);
    }
};

fn errnoError(e: linux.E) anyerror {
    return switch (e) {
        .NOSPC => error.NoSpaceLeft,
        .ACCES, .PERM => error.AccessDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .IO => error.InputOutput,
        .DQUOT => error.DiskQuota,
        else => error.Unexpected,
    };
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
}

/// Reads `input_fd` until EOF and logs it for `unit_name`. Returns 1 for an invalid unit name
/// and otherwise 0: logging problems are reported on the diagnostics stream and do not fail
/// the pipeline.
pub fn run(ctx: *core.Context, gpa: Allocator, unit_name: []const u8, opts: Options, input_fd: i32) u8 {
    const name = name_mod.parse(ctx.gpa, unit_name) catch |e| {
        ctx.diag.err("log: invalid unit name '{s}': {t}", .{ unit_name, e });
        return 1;
    };
    const dir = logpath.logDir(ctx, name.full);
    const zone = tz_mod.loadLocal(ctx.gpa, ctx.fs.*, ctx.environ);
    var logger: Logger = .init(gpa, ctx.fs.*, ctx.diag, dir, zone, opts);
    defer logger.deinit();

    const buf = gpa.alloc(u8, opts.max_line * 2) catch |e| {
        ctx.diag.err("log: cannot allocate the line buffer: {t}", .{e});
        return 0;
    };
    defer gpa.free(buf);
    var len: usize = 0;
    while (true) {
        const rc = linux.read(input_fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                ctx.diag.err("log: cannot read standard input: {t}", .{e});
                break;
            },
        }
        if (rc == 0) break;
        len += rc;
        const used = logger.feed(nowMs(ctx.io), buf[0..len]);
        std.mem.copyForwards(u8, buf[0 .. len - used], buf[used..len]);
        len -= used;
    }
    if (len > 0) logger.writeLine(nowMs(ctx.io), buf[0..len]);
    if (logger.lost > 1) ctx.diag.warn("log: {d} lines could not be written", .{logger.lost});
    return 0;
}

const testing = std.testing;

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: Fs,
    err: Io.Writer.Allocating,
    diag: core.Diag,

    fn init(t: *TestEnv) void {
        t.arena = .init(testing.allocator);
        t.tmp = testing.tmpDir(.{ .iterate = true });
        t.fs = .initDir(testing.io, t.tmp.dir);
        t.err = .init(testing.allocator);
        t.diag = .init(&t.err.writer, .notice);
    }

    fn deinit(t: *TestEnv) void {
        t.err.deinit();
        t.tmp.cleanup();
        t.arena.deinit();
    }

    fn read(t: *TestEnv, path_: []const u8) ![]u8 {
        return t.fs.readFileAlloc(t.arena.allocator(), path_, 1 << 22);
    }
};

const rome = tz_mod.Tz{ .types = &.{.{ .offset = 7200, .is_dst = true, .abbreviation = "CEST" }} };

test "timestamp format with offsets" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2026-10-24T12:05:01.123+02:00", formatTimestamp(&buf, 1_792_836_301_123, 7200));
    try testing.expectEqualStrings("2026-10-24T10:05:01.007+00:00", formatTimestamp(&buf, 1_792_836_301_007, 0));
    try testing.expectEqualStrings("2026-10-24T04:35:01.000-05:30", formatTimestamp(&buf, 1_792_836_301_000, -19800));
}

test "timestamp parsing is the inverse of formatting" {
    var buf: [40]u8 = undefined;
    for ([_]i32{ 0, 7200, -19800 }) |off| {
        var line_buf: [100]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} hello world", .{formatTimestamp(&buf, 1_792_836_301_123, off)});
        const p = parseLine(line).?;
        try testing.expectEqual(@as(i64, 1_792_836_301_123), p.unix_ms);
        try testing.expectEqualStrings("hello world", p.message);
    }
    try testing.expectEqualStrings("", parseLine("2026-10-24T12:05:01.123+02:00").?.message);
    try testing.expect(parseLine("garbage") == null);
    try testing.expect(parseLine("2026-13-24T12:05:01.123+02:00 x") == null);
    try testing.expect(parseLine("2026-10-24T12:05:01.123+02:00x") == null);
}

test "lines are appended with timestamps" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/a.service", rome, .{});
    defer l.deinit();
    l.writeLine(1_792_836_301_123, "first");
    l.writeLine(1_792_836_302_000, "");
    try testing.expectEqualStrings(
        "2026-10-24T12:05:01.123+02:00 first\n2026-10-24T12:05:02.000+02:00 \n",
        try t.read("/log/a.service/current"),
    );
    // A second logger appends to the same file.
    var l2: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/a.service", rome, .{});
    defer l2.deinit();
    l2.writeLine(1_792_836_303_000, "third");
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, try t.read("/log/a.service/current"), "\n"));
}

test "size based rotation keeps the newest files" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/r", rome, .{ .max_size = 100, .keep = 3 });
    defer l.deinit();
    var i: i64 = 0;
    while (i < 12) : (i += 1) l.writeLine((1_000 + i) * 1000, "0123456789012345678901234567890123456789");
    const files = try rotatedFiles(testing.allocator, t.fs, "/log/r");
    defer {
        for (files) |f| testing.allocator.free(f);
        testing.allocator.free(files);
    }
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expect(std.mem.lessThan(u8, files[0], files[1]));
    try testing.expectEqualStrings("@1010.log", files[0]);
    try testing.expectEqualStrings("@1011.log", files[1]);
    const cur = try t.read("/log/r/current");
    try testing.expect(cur.len > 0 and cur.len <= 100);
    try testing.expectEqual(@as(u64, 0), l.lost);
}

test "rotation in the same second does not overwrite" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/s", rome, .{ .max_size = 10, .keep = 10 });
    defer l.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) l.writeLine(5_000_000, "xxxxxxxxxxxxxxxxxxxx");
    const files = try rotatedFiles(testing.allocator, t.fs, "/log/s");
    defer {
        for (files) |f| testing.allocator.free(f);
        testing.allocator.free(files);
    }
    try testing.expectEqual(@as(usize, 4), files.len);
}

test "feed buffers partial lines and splits long ones" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/f", rome, .{ .max_line = 8 });
    defer l.deinit();
    const data = "ab\ncd\nefghijklmnopqrstu\nxyz";
    const used = l.feed(1_000, data);
    try testing.expectEqualStrings("xyz", data[used..]);
    const text = try t.read("/log/f/current");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const prefix_len = "1970-01-01T02:00:01.000+02:00 ".len;
    var messages: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        try messages.append(t.arena.allocator(), ln[prefix_len..]);
    }
    try testing.expectEqual(@as(usize, 5), messages.items.len);
    try testing.expectEqualStrings("ab", messages.items[0]);
    try testing.expectEqualStrings("efghijkl", messages.items[2]);
    try testing.expectEqualStrings("mnopqrst", messages.items[3]);
    try testing.expectEqualStrings("u", messages.items[4]);
}

test "lines above 64 KiB are split" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/big", rome, .{ .max_size = 1 << 30 });
    defer l.deinit();
    const big = try testing.allocator.alloc(u8, 150_000);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    big[big.len - 1] = '\n';
    try testing.expectEqual(big.len, l.feed(0, big));
    const text = try t.read("/log/big/current");
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\n"));
}

test "write failures are counted and reported once without stopping" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    // The directory path is a regular file, so nothing can be created below it.
    try t.fs.makePath("/log");
    try t.fs.writeFileAtomic("/log/blocked", "x", 0o644);
    var l: Logger = .init(testing.allocator, t.fs, &t.diag, "/log/blocked/unit", rome, .{});
    defer l.deinit();
    l.writeLine(0, "one");
    l.writeLine(0, "two");
    l.writeLine(0, "three");
    try testing.expect(l.lost >= 3);
    const out = t.err.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "warning: log:"));
}

test "run reads a descriptor to EOF and flushes the last partial line" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("TZ", "UTC");
    var ctx: core.Context = try .init(t.arena.allocator(), testing.io, &t.fs, &t.diag, &env, .system, 0);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "input", .data = "alpha\nbeta\npartial" });
    const file = try t.tmp.dir.openFile(testing.io, "input", .{});
    defer file.close(testing.io);
    try testing.expectEqual(@as(u8, 0), run(&ctx, testing.allocator, "x.service", .{}, file.handle));
    const text = try t.read("/var/log/fake-systemd/x.service/current");
    var lines = std.mem.splitScalar(u8, text, '\n');
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "+00:00 alpha"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, " beta"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, " partial"));
    try testing.expectEqualStrings("", lines.next().?);
}

const Writer = struct {
    fs: Fs,
    id: u8,
    lines: usize,
    max_size: u64,

    fn run(w: *Writer) void {
        var buf: [256]u8 = undefined;
        var sink: Io.Writer = .fixed(&buf);
        var diag: core.Diag = .init(&sink, .notice);
        var l: Logger = .init(std.heap.page_allocator, w.fs, &diag, "/log/shared", rome, .{ .max_size = w.max_size, .keep = 1000 });
        defer l.deinit();
        var msg: [24]u8 = undefined;
        var i: usize = 0;
        while (i < w.lines) : (i += 1) {
            const text = std.fmt.bufPrint(&msg, "{c}{d:0>6} abcdefghijklm", .{ 'A' + w.id, i }) catch unreachable;
            l.writeLine(@as(i64, 1000 + @as(i64, @intCast(i))) * 1000, text);
        }
    }
};

test "two loggers of one unit rotate without losing or duplicating a line" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    const per_writer = 400;
    const max_size = 600;
    var a: Writer = .{ .fs = t.fs, .id = 0, .lines = per_writer, .max_size = max_size };
    var b: Writer = .{ .fs = t.fs, .id = 1, .lines = per_writer, .max_size = max_size };
    try t.fs.makePath("/log/shared");
    const ta = try std.Thread.spawn(.{}, Writer.run, .{&a});
    const tb = try std.Thread.spawn(.{}, Writer.run, .{&b});
    ta.join();
    tb.join();

    const gpa = testing.allocator;
    const rotated = try rotatedFiles(gpa, t.fs, "/log/shared");
    defer {
        for (rotated) |n| gpa.free(n);
        gpa.free(rotated);
    }
    try testing.expect(rotated.len >= 5);
    const seen = try gpa.alloc(u8, 2 * per_writer);
    defer gpa.free(seen);
    @memset(seen, 0);
    var total: usize = 0;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (rotated) |n| try names.append(gpa, n);
    try names.append(gpa, current_name);
    for (names.items) |name| {
        const path_ = try std.fs.path.join(gpa, &.{ "/log/shared", name });
        defer gpa.free(path_);
        const content = try t.fs.readFileAlloc(gpa, path_, 1 << 20);
        defer gpa.free(content);
        const line_len = std.mem.findScalar(u8, content, '\n') orelse continue;
        try testing.expect(content.len <= max_size + line_len + 1);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = parseLine(line).?;
            const id: usize = parsed.message[0] - 'A';
            const n = try std.fmt.parseInt(usize, parsed.message[1..7], 10);
            seen[id * per_writer + n] += 1;
            total += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2 * per_writer), total);
    for (seen) |c| try testing.expectEqual(@as(u8, 1), c);
}
