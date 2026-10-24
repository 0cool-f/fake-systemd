// SPDX-License-Identifier: GPL-3.0-or-later
//! Native cron-like schedulers (§10.2): detection of an installed and enabled one, rendering
//! of the jobs of the timers assigned to it, and installation.
//!
//! Observed behavior of the schedulers (Alpine 3.23 cronie 1.7.2, dcron 4.5, fcron 3.4.0, BusyBox 1.37;
//! Debian 12 cron 3.0pl1), pinned by the rendering tests:
//! - cronie and Debian cron read `/etc/cron.d/*` (with a user field), notice changes by themselves
//!   within a minute, and have no catch-up for cron.d jobs.
//! - dcron 4.5 does not read `/etc/cron.d`; like BusyBox crond it reads `<crontabs>/root`
//!   (no user field) and re-reads it when `<crontabs>/cron.update` names the user.
//! - fcron has the `bootrun` option, which runs a job missed during downtime at startup; its
//!   table is installed with `fcrontab FILE`, which reloads the daemon at once.
//! - `%` ends a cron command line and has to be written as `\%` in every one of them.
const std = @import("std");
const core = @import("../core/root.zig");
const backend_pkg = @import("../backend/root.zig");
const index_pkg = @import("../index/root.zig");
const cron = @import("cron.zig");

const Backend = backend_pkg.Backend;

pub const Kind = enum {
    cronie,
    cron,
    dcron,
    fcron,
    busybox,

    pub fn text(k: Kind) []const u8 {
        return @tagName(k);
    }

    /// Scheduler column of the index: `cron:<adapter>`.
    pub fn schedulerName(k: Kind) []const u8 {
        return switch (k) {
            .cronie => "cron:cronie",
            .cron => "cron:cron",
            .dcron => "cron:dcron",
            .fcron => "cron:fcron",
            .busybox => "cron:busybox",
        };
    }

    /// Whether the scheduler runs jobs missed while it was not running (`Persistent=`).
    pub fn catchUp(k: Kind) bool {
        return k == .fcron;
    }

    pub fn family(k: Kind) Family {
        return switch (k) {
            .cronie, .cron => .cron_d,
            .dcron, .busybox => .crontab,
            .fcron => .fcron,
        };
    }

    /// Names of the init services that run the scheduler.
    fn services(k: Kind) []const []const u8 {
        return switch (k) {
            .cronie => &.{ "cronie", "crond" },
            .cron => &.{"cron"},
            .dcron => &.{ "dcron", "crond" },
            .fcron => &.{"fcron"},
            .busybox => &.{ "crond", "busybox-crond" },
        };
    }
};

pub const Family = enum { cron_d, crontab, fcron };

pub fn kindFromScheduler(text: []const u8) ?Kind {
    const rest = std.mem.cutPrefix(u8, text, "cron:") orelse return null;
    return std.meta.stringToEnum(Kind, rest);
}

pub const cron_d_path = "/etc/cron.d/fake-systemd";
pub const block_begin = "# BEGIN fake-systemd";
pub const block_end = "# END fake-systemd";
pub const fcron_table = "/var/spool/fcron/root.orig";
const crontab_dirs = [_][]const u8{ "/etc/crontabs", "/var/spool/cron/crontabs" };
const bin_dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };

pub const Target = struct {
    ctx: *core.Context,
    backend: Backend,
    runner: backend_pkg.Runner,
    /// Path of the program the jobs run.
    exe: []const u8 = backend_pkg.policy.executor_path,
};

fn findTool(fs: core.Fs, name: []const u8, gpa: std.mem.Allocator) ?[]const u8 {
    for (bin_dirs) |dir| {
        const path = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
        const st = fs.lstat(path) catch continue;
        if (st.kind == .file or st.kind == .sym_link) return path;
    }
    return null;
}

/// The scheduler installed on the system, if one is recognized.
fn installedKinds(fs: core.Fs, gpa: std.mem.Allocator, out: *[5]?Kind) void {
    out.* = @splat(null);
    var n: usize = 0;
    if (findTool(fs, "fcron", gpa) != null and findTool(fs, "fcrontab", gpa) != null) {
        out[n] = .fcron;
        n += 1;
    }
    if (findTool(fs, "cron", gpa) != null) {
        out[n] = .cron;
        n += 1;
    }
    if (findTool(fs, "crond", gpa)) |crond| {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const st = fs.lstat(crond) catch return;
        const is_busybox = st.kind == .sym_link and blk: {
            const target = fs.readLink(crond, &link_buf) catch break :blk false;
            break :blk std.mem.eql(u8, std.fs.path.basename(target), "busybox");
        };
        if (is_busybox) {
            out[n] = .busybox;
        } else if (findTool(fs, "cronnext", gpa) != null) {
            out[n] = .cronie;
        } else {
            out[n] = .dcron;
        }
    }
}

fn serviceEnabled(t: Target, kind: Kind) bool {
    const env: backend_pkg.interface.Env = .{ .ctx = t.ctx, .runner = t.runner, .online = !t.ctx.offline };
    for (kind.services()) |svc| {
        const state = t.backend.isEnabled(env, svc) catch continue;
        if (state == .enabled or state == .enabled_runtime) return true;
    }
    return false;
}

/// The first scheduler that is installed and whose service is enabled in the backend.
/// fcron needs its command to install a table, so it is not available without a running system.
pub fn detect(t: Target) ?Kind {
    var kinds: [5]?Kind = undefined;
    installedKinds(t.ctx.fs.*, t.ctx.gpa, &kinds);
    for (kinds) |maybe| {
        const kind = maybe orelse break;
        if (kind == .fcron and t.ctx.offline) continue;
        if (serviceEnabled(t, kind)) return kind;
    }
    return null;
}

/// A timer placed on a native scheduler.
pub const Job = struct {
    timer: []const u8,
    service: []const u8,
    entries: []const cron.Entry,
    /// `RandomizedDelaySec=` in microseconds, 0 for none.
    random_delay_us: u64 = 0,
    persistent: bool = false,
};

pub const Placed = struct { kind: Kind, job: Job };

fn plainWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "_.@:+=,/-", c) != null)) return false;
    }
    return true;
}

fn writeWord(w: *std.Io.Writer, word: []const u8) std.Io.Writer.Error!void {
    if (plainWord(word)) return w.writeAll(word);
    try w.writeByte('\'');
    for (word) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// The command of a job, with `%` escaped for crontab syntax.
fn writeCommand(w: *std.Io.Writer, exe: []const u8, job: Job) std.Io.Writer.Error!void {
    var cmd: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer cmd.deinit();
    try writeWord(&cmd.writer, exe);
    try cmd.writer.writeAll(" --run-job ");
    try writeWord(&cmd.writer, job.service);
    try cmd.writer.writeAll(" --timer ");
    try writeWord(&cmd.writer, job.timer);
    if (job.random_delay_us > 0) try cmd.writer.print(" --random-delay {d}", .{job.random_delay_us});
    for (cmd.written()) |c| {
        if (c == '%') try w.writeAll("\\%") else try w.writeByte(c);
    }
}

fn writeJobs(w: *std.Io.Writer, exe: []const u8, placed: []const Placed, user_field: bool, fcron_options: bool) std.Io.Writer.Error!void {
    for (placed) |p| {
        try w.print("# {s}\n", .{p.job.timer});
        for (p.job.entries) |e| {
            if (fcron_options and p.job.persistent) try w.writeAll("&bootrun ");
            try w.print("{s} {s} {s} {s} {s} ", .{ e.minute, e.hour, e.dom, e.month, e.dow });
            if (user_field) try w.writeAll("root ");
            try writeCommand(w, exe, p.job);
            try w.writeByte('\n');
        }
    }
}

/// Body of `/etc/cron.d/fake-systemd` without the marker.
pub fn renderCronD(gpa: std.mem.Allocator, exe: []const u8, placed: []const Placed) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\n");
    try writeJobs(&aw.writer, exe, placed, true, false);
    return aw.toOwnedSlice();
}

/// The delimited block of a crontab without the user field; fcron jobs get their `bootrun` option.
pub fn renderBlock(gpa: std.mem.Allocator, exe: []const u8, placed: []const Placed, fcron_options: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{s}\n", .{block_begin});
    try writeJobs(&aw.writer, exe, placed, false, fcron_options);
    try aw.writer.print("{s}\n", .{block_end});
    return aw.toOwnedSlice();
}

/// `content` with the block between the markers replaced by `block`, or removed when `block`
/// is null. Lines outside the markers are kept byte for byte; a missing block is appended.
pub fn replaceBlock(gpa: std.mem.Allocator, content: []const u8, block: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var inside = false;
    var placed = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const last = it.peek() == null;
        if (inside) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), block_end)) inside = false;
            continue;
        }
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), block_begin)) {
            inside = true;
            if (block) |b| {
                try out.appendSlice(gpa, b);
                placed = true;
            }
            continue;
        }
        if (last and line.len == 0) break;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    if (!placed) {
        if (block) |b| {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
            try out.appendSlice(gpa, b);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn readOptional(fs: core.Fs, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    return fs.readFileAlloc(gpa, path, 8 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn writeIfChanged(t: Target, path: []const u8, content: []const u8, mode: u16) !bool {
    const gpa = t.ctx.gpa;
    if (try readOptional(t.ctx.fs.*, gpa, path)) |old| {
        if (std.mem.eql(u8, old, content)) return false;
    }
    if (t.ctx.dry_run) {
        t.ctx.diag.info("would write {s}", .{path});
        return true;
    }
    try t.ctx.fs.makePath(std.fs.path.dirname(path) orelse "/");
    try t.ctx.fs.writeFileAtomic(path, content, mode);
    return true;
}

fn syncCronD(t: Target, placed: []const Placed) !void {
    const gpa = t.ctx.gpa;
    const existing = try readOptional(t.ctx.fs.*, gpa, cron_d_path);
    if (existing) |old| {
        const parsed = index_pkg.marker.parse(old);
        if (parsed == null or !parsed.?.bodyIntact()) {
            if (placed.len > 0) t.ctx.diag.warn("{s} was changed by hand, leaving it alone", .{cron_d_path});
            return;
        }
    }
    if (placed.len == 0) {
        if (existing != null and !t.ctx.dry_run) try t.ctx.fs.deleteFile(cron_d_path);
        return;
    }
    const body = try renderCronD(gpa, t.exe, placed);
    const generator = try backend_pkg.interface.generatorLine(gpa, t.backend.name(), t.backend.generator());
    const content = try index_pkg.marker.compose(gpa, "fake-systemd-timers", "index", 0, generator, body);
    _ = try writeIfChanged(t, cron_d_path, content, 0o644);
}

/// Directory with the per-user crontabs of dcron and BusyBox crond: the first that exists.
fn crontabDir(fs: core.Fs) []const u8 {
    for (crontab_dirs) |d| {
        const st = fs.stat(d) catch continue;
        if (st.kind == .directory) return d;
    }
    return crontab_dirs[1];
}

fn syncCrontab(t: Target, placed: []const Placed) !void {
    const gpa = t.ctx.gpa;
    const dir = crontabDir(t.ctx.fs.*);
    const path = try std.fs.path.join(gpa, &.{ dir, "root" });
    const existing = try readOptional(t.ctx.fs.*, gpa, path);
    if (existing == null and placed.len == 0) return;
    const block: ?[]const u8 = if (placed.len == 0) null else try renderBlock(gpa, t.exe, placed, false);
    const content = try replaceBlock(gpa, existing orelse "", block);
    if (!try writeIfChanged(t, path, content, 0o600) or t.ctx.dry_run) return;
    const update = try std.fs.path.join(gpa, &.{ dir, "cron.update" });
    try t.ctx.fs.writeFileAtomic(update, "root\n", 0o644);
}

fn syncFcron(t: Target, placed: []const Placed) !void {
    const gpa = t.ctx.gpa;
    const existing = try readOptional(t.ctx.fs.*, gpa, fcron_table);
    if (existing == null and placed.len == 0) return;
    if (t.ctx.offline) {
        if (placed.len > 0) t.ctx.diag.warn("fcron cannot be updated while the system is not running", .{});
        return;
    }
    const block: ?[]const u8 = if (placed.len == 0) null else try renderBlock(gpa, t.exe, placed, true);
    const content = try replaceBlock(gpa, existing orelse "", block);
    if (existing) |old| if (std.mem.eql(u8, old, content)) return;
    if (t.ctx.dry_run) {
        t.ctx.diag.info("would install the fcron table of root", .{});
        return;
    }
    const staging = try std.fs.path.join(gpa, &.{ "/var/lib/fake-systemd", "fcrontab.new" });
    try t.ctx.fs.makePath(std.fs.path.dirname(staging).?);
    try t.ctx.fs.writeFileAtomic(staging, content, 0o600);
    defer t.ctx.fs.deleteFile(staging) catch |e| t.ctx.diag.warn("cannot remove {s}: {t}", .{ staging, e });
    const res = try t.runner.run(gpa, &.{ "fcrontab", staging, "-u", "root" }, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

/// Installs the jobs of every family: families without jobs lose what fake-systemd wrote.
pub fn sync(t: Target, placed: []const Placed) !void {
    var buf: [3]std.ArrayList(Placed) = @splat(.empty);
    for (placed) |p| try buf[@backingInt(p.kind.family())].append(t.ctx.gpa, p);
    try syncCronD(t, buf[@backingInt(Family.cron_d)].items);
    try syncCrontab(t, buf[@backingInt(Family.crontab)].items);
    try syncFcron(t, buf[@backingInt(Family.fcron)].items);
}

const testing = std.testing;

test "scheduler names round trip" {
    for (std.meta.tags(Kind)) |k| try testing.expectEqual(k, kindFromScheduler(k.schedulerName()).?);
    try testing.expect(kindFromScheduler("builtin") == null);
    try testing.expect(kindFromScheduler("cron:nope") == null);
    try testing.expect(Kind.fcron.catchUp() and !Kind.cronie.catchUp() and !Kind.busybox.catchUp());
}

test "block replacement keeps the lines around the markers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = "# BEGIN fake-systemd\n0 3 * * * x\n# END fake-systemd\n";
    const appended = try replaceBlock(a, "# user line\n* * * * * mine", block);
    try testing.expectEqualStrings("# user line\n* * * * * mine\n" ++ block, appended);
    const replaced = try replaceBlock(a, "a\n# BEGIN fake-systemd\nold\n# END fake-systemd\nb\n", block);
    try testing.expectEqualStrings("a\n" ++ block ++ "b\n", replaced);
    const removed = try replaceBlock(a, "a\n# BEGIN fake-systemd\nold\n# END fake-systemd\nb\n", null);
    try testing.expectEqualStrings("a\nb\n", removed);
    try testing.expectEqualStrings("", try replaceBlock(a, "", null));
    try testing.expectEqualStrings(block, try replaceBlock(a, "", block));
}

test "commands quote words and escape percent signs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = [_]cron.Entry{.{ .minute = "0", .hour = "3", .dom = "*", .month = "*", .dow = "*" }};
    const placed = [_]Placed{.{ .kind = .cronie, .job = .{
        .timer = "we ird%.timer",
        .service = "we ird%.service",
        .entries = &entries,
        .random_delay_us = 5_000_000,
    } }};
    const body = try renderCronD(arena.allocator(), "/usr/bin/fake-systemd", &placed);
    try testing.expect(std.mem.find(u8, body, "0 3 * * * root /usr/bin/fake-systemd --run-job 'we ird\\%.service' --timer 'we ird\\%.timer' --random-delay 5000000\n") != null);
}
