// SPDX-License-Identifier: GPL-3.0-or-later
//! `journalctl` over the uniform logs written by `fake-systemd --log` (spec §3.5, §6.7): unit
//! selection, merging by timestamp, time filters, `short` and `cat` output and `--follow`.
//! Units without such logs fall back to the native log locations of the distribution profile.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const cli = @import("../cli/root.zig");
const detect = @import("../detect/root.zig");
const backend_pkg = @import("../backend/root.zig");
const name_mod = @import("../unit/name.zig");
const logger = @import("../exec/logger.zig");
const logpath = @import("../exec/logpath.zig");
const tz_mod = @import("../exec/tz.zig");
const journal_time = @import("journal_time.zig");

pub const Exit = struct {
    pub const success: u8 = 0;
    pub const failure: u8 = 1;
};

const max_log_file = 256 << 20;
const follow_poll_ms = 250;
const follow_default_lines = 10;

pub const Environment = struct {
    out: *Io.Writer,
    runner: backend_pkg.Runner,
    /// Name of the detected init, for the native log locations.
    detected: []const u8 = "unknown",
    /// Reference instant in Unix milliseconds; the clock when null.
    now_ms: ?i64 = null,
    /// Follow polls to run before returning; unlimited when null.
    max_follow_cycles: ?u32 = null,
};

const Source = struct {
    /// Full unit name.
    name: []const u8,
    /// Syslog-style identifier shown in `short` output.
    ident: []const u8,
    scope: core.Scope,
    /// In-root log directory; empty for native sources.
    dir: []const u8,
};

const Entry = struct {
    ts_ms: i64,
    source: u32,
    seq: u32,
    text: []const u8,
    /// Printed verbatim, without timestamp and identifier.
    raw: bool = false,

    fn less(_: void, a: Entry, b: Entry) bool {
        if (a.ts_ms != b.ts_ms) return a.ts_ms < b.ts_ms;
        if (a.source != b.source) return a.source < b.source;
        return a.seq < b.seq;
    }
};

const Filter = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,

    fn accepts(f: Filter, ts_ms: i64) bool {
        if (f.since_ms) |s| if (ts_ms < s) return false;
        if (f.until_ms) |u| if (ts_ms > u) return false;
        return true;
    }
};

fn identOf(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".service")) name[0 .. name.len - ".service".len] else name;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
}

fn readTrimmed(ctx: *const core.Context, path: []const u8) ?[]const u8 {
    const content = ctx.fs.readFileAlloc(ctx.gpa, path, 4096) catch return null;
    const t = std.mem.trim(u8, content, " \t\r\n");
    return if (t.len == 0) null else t;
}

fn hostname(ctx: *const core.Context) []const u8 {
    return readTrimmed(ctx, "/etc/hostname") orelse readTrimmed(ctx, "/proc/sys/kernel/hostname") orelse "localhost";
}

/// Current boot start in Unix milliseconds, from `btime` in `/proc/stat`.
fn bootTimeMs(ctx: *const core.Context) ?i64 {
    const content = ctx.fs.readFileAlloc(ctx.gpa, "/proc/stat", 1 << 20) catch return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "btime ")) continue;
        const secs = std.fmt.parseInt(i64, std.mem.trim(u8, line["btime ".len..], " \t\r"), 10) catch return null;
        return secs * 1000;
    }
    return null;
}

const Selection = struct {
    name: []const u8,
    scope: core.Scope,
};

fn addSelection(gpa: Allocator, list: *std.ArrayList(Selection), name: []const u8, scope: core.Scope) Allocator.Error!void {
    for (list.items) |s| {
        if (s.scope == scope and std.mem.eql(u8, s.name, name)) return;
    }
    try list.append(gpa, .{ .name = name, .scope = scope });
}

fn listUnitDirs(ctx: *core.Context, scope: core.Scope) ![]const []const u8 {
    const entries = ctx.fs.iterateDir(ctx.gpa, logpath.logRoot(ctx, scope)) catch return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (e.kind == .directory) try names.append(ctx.gpa, e.name);
    }
    return names.toOwnedSlice(ctx.gpa);
}

fn selectUnits(ctx: *core.Context, req: cli.journalctl.Request) ![]const Selection {
    var requested: std.ArrayList(Selection) = .empty;
    var any_request = false;
    const o = req.options;
    var groups: [2]struct { []const []const u8, core.Scope } = .{ .{ o.units, .system }, .{ o.user_units, .user } };
    for (&groups) |g| {
        for (g[0]) |raw| {
            any_request = true;
            try expandSelection(ctx, &requested, raw, g[1]);
        }
    }
    for (req.matches) |m| {
        const unit_prefix = "_SYSTEMD_UNIT=";
        const user_prefix = "_SYSTEMD_USER_UNIT=";
        if (std.mem.startsWith(u8, m, unit_prefix)) {
            any_request = true;
            try expandSelection(ctx, &requested, m[unit_prefix.len..], .system);
        } else if (std.mem.startsWith(u8, m, user_prefix)) {
            any_request = true;
            try expandSelection(ctx, &requested, m[user_prefix.len..], .user);
        } else ctx.diag.warn("match '{s}' is not supported and ignored", .{m});
    }
    if (any_request) return requested.toOwnedSlice(ctx.gpa);
    for (try listUnitDirs(ctx, .system)) |n| try requested.append(ctx.gpa, .{ .name = n, .scope = .system });
    return requested.toOwnedSlice(ctx.gpa);
}

fn expandSelection(ctx: *core.Context, list: *std.ArrayList(Selection), raw: []const u8, scope: core.Scope) !void {
    if (name_mod.hasGlob(raw)) {
        const with_service = try std.fmt.allocPrint(ctx.gpa, "{s}.service", .{raw});
        for (try listUnitDirs(ctx, scope)) |n| {
            if (name_mod.globMatch(raw, n) or name_mod.globMatch(with_service, n)) try addSelection(ctx.gpa, list, n, scope);
        }
        return;
    }
    const parsed = name_mod.parse(ctx.gpa, raw) catch {
        ctx.diag.warn("invalid unit name '{s}' ignored", .{raw});
        return;
    };
    try addSelection(ctx.gpa, list, parsed.full, scope);
}

/// Splits `content` into entries. A trailing line without newline is kept only when
/// `final` is set; the number of bytes consumed is returned.
fn appendLines(
    gpa: Allocator,
    content: []const u8,
    source: u32,
    seq: *u32,
    last_ts: *i64,
    filter: Filter,
    final: bool,
    entries: *std.ArrayList(Entry),
) Allocator.Error!usize {
    var pos: usize = 0;
    while (pos < content.len) {
        const nl = std.mem.findScalarPos(u8, content, pos, '\n');
        if (nl == null and !final) break;
        const end = nl orelse content.len;
        var line = content[pos..end];
        pos = if (nl) |n| n + 1 else content.len;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var text = line;
        if (logger.parseLine(line)) |p| {
            last_ts.* = p.unix_ms;
            text = p.message;
        }
        if (!filter.accepts(last_ts.*)) continue;
        try entries.append(gpa, .{ .ts_ms = last_ts.*, .source = source, .seq = seq.*, .text = text });
        seq.* += 1;
    }
    return pos;
}

const Loaded = struct {
    /// Bytes of `current` that were read.
    current_len: usize = 0,
    found: bool = false,
};

/// Reads the rotated files in order, then `current`.
fn loadSource(ctx: *core.Context, index: u32, src: Source, filter: Filter, entries: *std.ArrayList(Entry)) !Loaded {
    var loaded: Loaded = .{};
    var seq: u32 = 0;
    var last_ts: i64 = 0;
    const rotated = try logger.rotatedFiles(ctx.gpa, ctx.fs.*, src.dir);
    const names = try ctx.gpa.alloc([]const u8, rotated.len + 1);
    @memcpy(names[0..rotated.len], rotated);
    names[rotated.len] = logger.current_name;
    for (names) |name| {
        const path = try std.fs.path.join(ctx.gpa, &.{ src.dir, name });
        const content = ctx.fs.readFileAlloc(ctx.gpa, path, max_log_file) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                ctx.diag.warn("cannot read {s}: {t}", .{ path, e });
                continue;
            },
        };
        loaded.found = true;
        _ = try appendLines(ctx.gpa, content, index, &seq, &last_ts, filter, true, entries);
        if (std.mem.eql(u8, name, logger.current_name)) loaded.current_len = content.len;
    }
    return loaded;
}

const Native = struct {
    found: bool,
    /// Locations that were checked, for the notice.
    checked: []const []const u8,
};

fn expandNativePattern(ctx: *core.Context, pattern: []const u8, base: []const u8) ![]const u8 {
    const named = try std.mem.replaceOwned(u8, ctx.gpa, pattern, "{name}", base);
    if (std.mem.startsWith(u8, named, "~/")) return std.fs.path.join(ctx.gpa, &.{ ctx.home, named[2..] });
    return named;
}

/// Reads the native log files of the detected init for `base`. Files named per service are
/// shown whole; shared files only contribute the lines that mention the service.
fn loadNative(ctx: *core.Context, env: Environment, index: u32, base: []const u8, filter: Filter, entries: *std.ArrayList(Entry)) !Native {
    const kind = detect.InitKind.fromName(env.detected) orelse .unknown;
    const os = detect.osrelease.load(ctx.gpa, ctx.fs) catch detect.osrelease.OsRelease{};
    const patterns = detect.profile.select(os).backends.get(kind).native_logs;
    var checked: std.ArrayList([]const u8) = .empty;
    var found = false;
    var seq: u32 = 0;
    for (patterns) |pattern| {
        const path = try expandNativePattern(ctx, pattern, base);
        try checked.append(ctx.gpa, path);
        const per_service = std.mem.find(u8, pattern, "{name}") != null;
        const content = ctx.fs.readFileAlloc(ctx.gpa, path, max_log_file) catch continue;
        const mtime_ms: i64 = if (ctx.fs.stat(path)) |st| @intCast(@divFloor(st.mtime_ns, std.time.ns_per_ms)) else |_| 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (!per_service and std.mem.find(u8, line, base) == null) continue;
            if (!filter.accepts(mtime_ms)) continue;
            try entries.append(ctx.gpa, .{ .ts_ms = mtime_ms, .source = index, .seq = seq, .text = line, .raw = true });
            seq += 1;
            found = true;
        }
    }
    return .{ .found = found, .checked = try checked.toOwnedSlice(ctx.gpa) };
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Printer = struct {
    out: *Io.Writer,
    format: cli.journalctl.Output,
    host: ?[]const u8,
    tz: tz_mod.Tz,
    sources: []const Source,

    fn print(p: Printer, e: Entry) Io.Writer.Error!void {
        if (e.raw or p.format == .cat) {
            try p.out.writeAll(e.text);
            return p.out.writeByte('\n');
        }
        const secs = @divFloor(e.ts_ms, 1000);
        const c = tz_mod.civilFromUnix(secs, p.tz.offsetAt(secs));
        try p.out.print("{s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ month_names[c.month - 1], c.day, c.hour, c.minute, c.second });
        if (p.host) |h| try p.out.print("{s} ", .{h});
        try p.out.print("{s}: {s}\n", .{ p.sources[e.source].ident, e.text });
    }
};

/// Keeps only the last `n` entries of a sorted list.
fn tail(entries: []const Entry, lines: ?cli.journalctl.Lines) []const Entry {
    const l = lines orelse return entries;
    return switch (l) {
        .all => entries,
        .count => |n| entries[entries.len -| n..],
    };
}

/// Reads the open `current` files of every source and yields lines appended since the last
/// poll; follows rotation by draining the old file before opening the new one.
pub const Follower = struct {
    ctx: *core.Context,
    states: std.ArrayList(State) = .empty,
    sources: std.ArrayList(Source) = .empty,
    /// Rescan the log root for new units on every poll.
    discover: bool,

    const State = struct {
        fd: ?i32 = null,
        inode: u64 = 0,
        pending: std.ArrayList(u8) = .empty,
        last_ts: i64 = 0,
        seq: u32 = 0,
        /// Bytes of `current` already shown when following starts.
        skip: usize = 0,
    };

    fn init(ctx: *core.Context, discover: bool) Follower {
        return .{ .ctx = ctx, .discover = discover };
    }

    fn deinit(f: *Follower) void {
        for (f.states.items) |s| if (s.fd) |fd| {
            _ = linux.close(fd);
        };
    }

    fn add(f: *Follower, src: Source, shown_len: usize, seq: u32, last_ts: i64) Allocator.Error!void {
        try f.sources.append(f.ctx.gpa, src);
        try f.states.append(f.ctx.gpa, .{ .skip = shown_len, .seq = seq, .last_ts = last_ts });
    }

    fn openCurrent(f: *Follower, dir: []const u8) ?struct { fd: i32, inode: u64 } {
        const gpa = f.ctx.gpa;
        const abs = std.fs.path.join(gpa, &.{ dir, logger.current_name }) catch return null;
        const st = f.ctx.fs.stat(abs) catch return null;
        const real = f.ctx.fs.realpath(gpa, abs) catch return null;
        const rel = gpa.dupeSentinel(u8, std.mem.trimStart(u8, real, "/"), 0) catch return null;
        const rc = linux.openat(f.ctx.fs.root.handle, rel.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .fd = @intCast(rc), .inode = st.inode };
    }

    fn drain(f: *Follower, index: u32, final: bool, new: *std.ArrayList(Entry)) !void {
        const state = &f.states.items[index];
        const fd = state.fd orelse return;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (rc == 0) break;
            try state.pending.appendSlice(f.ctx.gpa, buf[0..rc]);
        }
        const consumed = try appendLines(f.ctx.gpa, try f.ctx.gpa.dupe(u8, state.pending.items), index, &state.seq, &state.last_ts, .{}, final, new);
        state.pending.replaceRange(f.ctx.gpa, 0, consumed, &.{}) catch |e| return e;
    }

    fn pollOne(f: *Follower, index: u32, new: *std.ArrayList(Entry)) !void {
        const src = f.sources.items[index];
        const state = &f.states.items[index];
        const current = std.fs.path.join(f.ctx.gpa, &.{ src.dir, logger.current_name }) catch return;
        const st = f.ctx.fs.stat(current) catch null;
        if (state.fd != null and (st == null or st.?.inode != state.inode)) {
            try f.drain(index, true, new);
            _ = linux.close(state.fd.?);
            state.fd = null;
            state.skip = 0;
        }
        if (state.fd == null) {
            if (f.openCurrent(src.dir)) |o| {
                state.fd = o.fd;
                state.inode = o.inode;
                if (state.skip > 0) _ = linux.lseek(o.fd, @intCast(state.skip), linux.SEEK.SET);
                state.skip = 0;
            }
        }
        try f.drain(index, false, new);
    }

    fn discoverNew(f: *Follower) !void {
        for (try listUnitDirs(f.ctx, .system)) |name| {
            var known = false;
            for (f.sources.items) |s| {
                if (s.scope == .system and std.mem.eql(u8, s.name, name)) known = true;
            }
            if (known) continue;
            try f.add(.{
                .name = name,
                .ident = identOf(name),
                .scope = .system,
                .dir = logpath.logDirFor(f.ctx, .system, name),
            }, 0, 0, 0);
        }
    }

    /// One poll: new entries of every source, oldest first.
    pub fn poll(f: *Follower) ![]const Entry {
        if (f.discover) try f.discoverNew();
        var new: std.ArrayList(Entry) = .empty;
        var i: u32 = 0;
        while (i < f.sources.items.len) : (i += 1) try f.pollOne(i, &new);
        std.mem.sort(Entry, new.items, {}, Entry.less);
        return new.toOwnedSlice(f.ctx.gpa);
    }
};

fn fail(ctx: *core.Context, comptime fmt: []const u8, args: anytype) u8 {
    ctx.diag.err(fmt, args);
    return Exit.failure;
}

/// Shows the logs selected by `req` on `env.out`.
pub fn show(ctx: *core.Context, env: Environment, req: cli.journalctl.Request) u8 {
    return showInner(ctx, env, req) catch |e| fail(ctx, "journalctl: {t}", .{e});
}

fn showInner(ctx: *core.Context, env: Environment, req: cli.journalctl.Request) !u8 {
    const o = req.options;
    if (o.dmesg) {
        const res = try env.runner.run(ctx.gpa, &.{"dmesg"}, .inherit);
        return res.code;
    }

    const zone = tz_mod.loadLocal(ctx.gpa, ctx.fs.*, ctx.environ);
    const now = env.now_ms orelse nowMs(ctx.io);
    var filter: Filter = .{};
    if (o.since) |s| filter.since_ms = journal_time.parse(s, now, zone) catch return fail(ctx, "Failed to parse timestamp: {s}", .{s});
    if (o.until) |u| filter.until_ms = journal_time.parse(u, now, zone) catch return fail(ctx, "Failed to parse timestamp: {s}", .{u});
    if (filter.since_ms != null and filter.until_ms != null and filter.since_ms.? > filter.until_ms.?) {
        return fail(ctx, "Specified --since= timestamp is after --until= timestamp.", .{});
    }
    var boot_selected = o.boot;
    if (o.boot_id) |id| {
        if (!std.mem.eql(u8, id, "0") and id.len > 0) {
            ctx.diag.notice("only the current boot is kept in the logs; boot '{s}' has no entries", .{id});
            boot_selected = false;
            filter.since_ms = std.math.maxInt(i64);
        }
    }
    if (boot_selected) {
        if (bootTimeMs(ctx)) |boot| {
            filter.since_ms = if (filter.since_ms) |s| @max(s, boot) else boot;
        } else ctx.diag.warn("cannot read the boot time from /proc/stat; showing all entries", .{});
    }

    const selected = try selectUnits(ctx, req);
    var sources: std.ArrayList(Source) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var loaded_lens: std.ArrayList(Loaded) = .empty;
    const explicit = req.options.units.len + req.options.user_units.len + req.matches.len > 0;
    for (selected) |sel| {
        const index: u32 = @intCast(sources.items.len);
        const src: Source = .{
            .name = sel.name,
            .ident = identOf(sel.name),
            .scope = sel.scope,
            .dir = logpath.logDirFor(ctx, sel.scope, sel.name),
        };
        try sources.append(ctx.gpa, src);
        const loaded = try loadSource(ctx, index, src, filter, &entries);
        try loaded_lens.append(ctx.gpa, loaded);
        if (loaded.found or !explicit) continue;
        const native = try loadNative(ctx, env, index, identOf(sel.name), filter, &entries);
        if (native.found) continue;
        var paths: std.Io.Writer.Allocating = .init(ctx.gpa);
        for (native.checked, 0..) |p, i| try paths.writer.print("{s}{s}", .{ if (i > 0) ", " else "", p });
        if (native.checked.len == 0) try paths.writer.writeAll("(no native log location is known for this init)");
        ctx.diag.notice("{s}: no fake-systemd logs in {s}; native services log to: {s}", .{ sel.name, src.dir, paths.written() });
    }

    std.mem.sort(Entry, entries.items, {}, Entry.less);
    var lines = o.effectiveLines();
    if (lines == null and o.follow) lines = .{ .count = follow_default_lines };
    const shown = tail(entries.items, lines);

    const printer: Printer = .{
        .out = env.out,
        .format = o.output,
        .host = if (o.no_hostname) null else hostname(ctx),
        .tz = zone,
        .sources = sources.items,
    };
    if (shown.len == 0 and !o.quiet and !o.follow) try env.out.writeAll("-- No entries --\n");
    for (shown) |e| try printer.print(e);
    try env.out.flush();
    if (!o.follow) return Exit.success;

    var follower: Follower = .init(ctx, !explicit);
    defer follower.deinit();
    for (sources.items, loaded_lens.items) |src, loaded| {
        try follower.add(src, loaded.current_len, std.math.maxInt(u32) / 2, now);
    }
    var cycles: u32 = 0;
    while (env.max_follow_cycles == null or cycles < env.max_follow_cycles.?) : (cycles += 1) {
        const fresh = try follower.poll();
        if (fresh.len > 0) {
            var all_sources: std.ArrayList(Source) = .empty;
            try all_sources.appendSlice(ctx.gpa, follower.sources.items);
            var p = printer;
            p.sources = all_sources.items;
            for (fresh) |e| try p.print(e);
            env.out.flush() catch return Exit.success;
        }
        ctx.io.sleep(.fromMilliseconds(follow_poll_ms), .awake) catch return Exit.success;
    }
    return Exit.success;
}

const testing = std.testing;
const harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: core.Fs,
    env: std.process.Environ.Map,
    err: Io.Writer.Allocating,
    out: Io.Writer.Allocating,
    diag: core.Diag,
    ctx: core.Context,
    rec: backend_pkg.runner.Recording,
};

const Harness = struct {
    h: harness,

    fn init(t: *Harness) !void {
        const h = &t.h;
        h.arena = .init(testing.allocator);
        h.tmp = testing.tmpDir(.{ .iterate = true });
        h.fs = .initDir(testing.io, h.tmp.dir);
        h.env = .init(testing.allocator);
        try h.env.put("TZ", "UTC");
        h.err = .init(testing.allocator);
        h.out = .init(testing.allocator);
        h.diag = .init(&h.err.writer, .notice);
        h.ctx = try .init(h.arena.allocator(), testing.io, &h.fs, &h.diag, &h.env, .system, 0);
        h.rec = .{ .gpa = h.arena.allocator() };
    }

    fn deinit(t: *Harness) void {
        const h = &t.h;
        h.out.deinit();
        h.err.deinit();
        h.env.deinit();
        h.tmp.cleanup();
        h.arena.deinit();
    }

    fn log(t: *Harness, unit: []const u8, file: []const u8, content: []const u8) !void {
        const dir = try std.fmt.allocPrint(t.h.arena.allocator(), "/var/log/fake-systemd/{s}", .{unit});
        try t.h.fs.makePath(dir);
        const path = try std.fs.path.join(t.h.arena.allocator(), &.{ dir, file });
        try t.h.fs.writeFileAtomic(path, content, 0o644);
    }

    fn append(t: *Harness, unit: []const u8, bytes: []const u8) !void {
        const path = try std.fmt.allocPrint(t.h.arena.allocator(), "var/log/fake-systemd/{s}/current", .{unit});
        const file = try t.h.tmp.dir.openFile(testing.io, path, .{ .mode = .write_only });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, bytes, try file.length(testing.io));
    }

    fn run(t: *Harness, args: []const []const u8) !u8 {
        const h = &t.h;
        const parsed = try cli.journalctl.parse(h.arena.allocator(), args);
        const req = switch (parsed) {
            .ok => |r| r,
            .err => return error.TestUnexpectedResult,
        };
        h.out.writer.end = 0;
        return show(&h.ctx, .{
            .out = &h.out.writer,
            .runner = h.rec.runner(),
            .detected = "dinit",
            .now_ms = test_now_ms,
            .max_follow_cycles = 0,
        }, req);
    }

    fn output(t: *Harness) []const u8 {
        return t.h.out.written();
    }
};

// 2026-10-24 12:05:01 UTC
const test_now_ms: i64 = 1_792_843_501_000;

const a_log =
    "2026-10-24T10:00:01.000+00:00 a first\n" ++
    "2026-10-24T10:00:03.000+00:00 a third\n" ++
    "2026-10-24T10:00:05.500+00:00 a fifth\n";
const b_log =
    "2026-10-24T10:00:02.000+00:00 b second\n" ++
    "2026-10-24T10:00:04.000+00:00 b fourth\n";

test "single unit in short format" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "current", a_log);
    try t.h.fs.makePath("/etc");
    try t.h.fs.writeFileAtomic("/etc/hostname", "myhost\n", 0o644);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a" }));
    try testing.expectEqualStrings(
        "Oct 24 10:00:01 myhost a: a first\nOct 24 10:00:03 myhost a: a third\nOct 24 10:00:05 myhost a: a fifth\n",
        t.output(),
    );
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a.service", "--no-hostname", "-o", "cat" }));
    try testing.expectEqualStrings("a first\na third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--no-hostname" }));
    try testing.expect(std.mem.startsWith(u8, t.output(), "Oct 24 10:00:01 a: a first"));
}

test "several units merge by timestamp and rotated files come first" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "@100.log", "2026-10-24T10:00:01.000+00:00 a first\n");
    try t.log("a.service", "current", "2026-10-24T10:00:03.000+00:00 a third\n2026-10-24T10:00:05.500+00:00 a fifth\n");
    try t.log("b.service", "current", b_log);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-u", "b", "-o", "cat" }));
    try testing.expectEqualStrings("a first\nb second\na third\nb fourth\na fifth\n", t.output());
    // Without -u every unit is shown.
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-o", "cat" }));
    try testing.expectEqualStrings("a first\nb second\na third\nb fourth\na fifth\n", t.output());
    // Glob selection.
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "b*", "-o", "cat" }));
    try testing.expectEqualStrings("b second\nb fourth\n", t.output());
}

test "line count and since/until" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "current", a_log);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-n", "2", "-o", "cat" }));
    try testing.expectEqualStrings("a third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-n", "all", "-o", "cat" }));
    try testing.expectEqualStrings("a first\na third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-e", "-o", "cat" }));
    try testing.expectEqualStrings("a first\na third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--since", "2026-10-24 10:00:02", "--until", "2026-10-24 10:00:04", "-o", "cat" }));
    try testing.expectEqualStrings("a third\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--since", "-3h", "-o", "cat" }));
    try testing.expectEqualStrings("a first\na third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--since", "today", "-o", "cat" }));
    try testing.expectEqualStrings("a first\na third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--until", "yesterday", "-o", "cat" }));
    try testing.expectEqualStrings("-- No entries --\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--until", "yesterday", "-q", "-o", "cat" }));
    try testing.expectEqualStrings("", t.output());
}

test "bad times and inverted ranges fail" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "current", a_log);
    try testing.expectEqual(@as(u8, 1), try t.run(&.{ "-u", "a", "--since", "nonsense" }));
    try testing.expect(std.mem.find(u8, t.h.err.written(), "Failed to parse timestamp: nonsense") != null);
    try testing.expectEqual(@as(u8, 1), try t.run(&.{ "-u", "a", "--since", "2026-10-24 11:00", "--until", "2026-10-24 10:00" }));
}

test "boot filter uses btime" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "current", a_log);
    try t.h.fs.makePath("/proc");
    // 10:00:02 UTC
    try t.h.fs.writeFileAtomic("/proc/stat", "cpu 1 2 3\nbtime 1792836002\nprocesses 5\n", 0o644);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-b", "-o", "cat" }));
    try testing.expectEqualStrings("a third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-b", "0", "-o", "cat" }));
    try testing.expectEqualStrings("a third\na fifth\n", t.output());
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "-b", "-1", "-o", "cat" }));
    try testing.expectEqualStrings("-- No entries --\n", t.output());
    try testing.expect(std.mem.find(u8, t.h.err.written(), "only the current boot") != null);
}

test "local offsets are applied to the output" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.h.env.put("TZ", "CET-1");
    try t.log("a.service", "current", "2026-10-24T12:00:01.000+02:00 x\nplain line without timestamp\n");
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "a", "--no-hostname" }));
    try testing.expectEqualStrings("Oct 24 11:00:01 a: x\nOct 24 11:00:01 a: plain line without timestamp\n", t.output());
}

test "units without logs print the notice and exit successfully" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "nolog" }));
    try testing.expect(std.mem.find(u8, t.h.err.written(), "nolog.service: no fake-systemd logs in /var/log/fake-systemd/nolog.service") != null);
    try testing.expect(std.mem.find(u8, t.h.err.written(), "/var/log/dinit.log") != null);
    try testing.expectEqualStrings("-- No entries --\n", t.output());
}

test "native logs of the profile are used when present" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.h.fs.makePath("/var/log");
    try t.h.fs.writeFileAtomic("/var/log/dinit.log", "dinit: Service nginx started\ndinit: Service other started\n", 0o644);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "-u", "nginx", "-o", "cat" }));
    try testing.expectEqualStrings("dinit: Service nginx started\n", t.output());
    try testing.expectEqualStrings("", t.h.err.written());
}

test "dmesg is delegated to the runner" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    t.h.rec.code = 3;
    try testing.expectEqual(@as(u8, 3), try t.run(&.{"-k"}));
    try testing.expect(t.h.rec.callIs(0, &.{"dmesg"}));
}

test "user units live under the state directory" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.h.env.put("XDG_STATE_HOME", "/xs");
    t.h.ctx = try .init(t.h.arena.allocator(), testing.io, &t.h.fs, &t.h.diag, &t.h.env, .system, 0);
    try t.h.fs.makePath("/xs/fake-systemd/log/u.service");
    try t.h.fs.writeFileAtomic("/xs/fake-systemd/log/u.service/current", "2026-10-24T10:00:01.000+00:00 user line\n", 0o644);
    try testing.expectEqual(@as(u8, 0), try t.run(&.{ "--user-unit", "u", "-o", "cat" }));
    try testing.expectEqualStrings("user line\n", t.output());
}

test "follow shows appended lines and survives rotation" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    try t.log("a.service", "current", a_log);
    var follower: Follower = .init(&t.h.ctx, false);
    defer follower.deinit();
    const dir = "/var/log/fake-systemd/a.service";
    try follower.add(.{ .name = "a.service", .ident = "a", .scope = .system, .dir = dir }, a_log.len, 0, 0);
    try testing.expectEqual(@as(usize, 0), (try follower.poll()).len);

    try t.append("a.service", "2026-10-24T10:00:06.000+00:00 a sixth\n2026-10-24T10:00:07.000+00:00 a seve");
    var fresh = try follower.poll();
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings("a sixth", fresh[0].text);

    try t.append("a.service", "nth\n");
    fresh = try follower.poll();
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings("a seventh", fresh[0].text);

    // After rotation the old file is drained and the new one is read from its start.
    try t.append("a.service", "2026-10-24T10:00:07.500+00:00 tail");
    try t.h.fs.rename(dir ++ "/current", dir ++ "/@1.log");
    try t.h.fs.writeFileAtomic(dir ++ "/current", "2026-10-24T10:00:08.000+00:00 a eighth\n", 0o644);
    fresh = try follower.poll();
    try testing.expectEqual(@as(usize, 2), fresh.len);
    try testing.expectEqualStrings("tail", fresh[0].text);
    try testing.expectEqualStrings("a eighth", fresh[1].text);
}

test "follow discovers units that appear later" {
    var t: Harness = undefined;
    try t.init();
    defer t.deinit();
    var follower: Follower = .init(&t.h.ctx, true);
    defer follower.deinit();
    try testing.expectEqual(@as(usize, 0), (try follower.poll()).len);
    try t.log("late.service", "current", "2026-10-24T10:00:01.000+00:00 hello\n");
    const fresh = try follower.poll();
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings("hello", fresh[0].text);
}
