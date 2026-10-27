// SPDX-License-Identifier: GPL-3.0-or-later
//! procd backend (§11.3, OpenWrt): a service is a script `/etc/init.d/<name>` that starts with
//! `#!/bin/sh /etc/rc.common`, the links `S<START><name>` and `K<STOP><name>` in `/etc/rc.d`
//! enable it, and the script controls it. `/etc/init.d/<name> enable` writes the links.
//!
//! A daemon is an instance procd supervises and respawns, run through the executor so that its
//! output reaches the uniform log; the state of a service is what `ubus call service list`
//! reports. A oneshot has no instance and keeps its state in files. procd runs the stop links
//! at shutdown only, so a script that was started without being enabled has its stop link
//! written too.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const model = @import("../unit/model.zig");
const name_mod = @import("../unit/name.zig");
const resolve = @import("../unit/resolve.zig");
const timespan = @import("../unit/timespan.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const apply = @import("../reconcile/apply.zig");
const logpath = @import("../exec/logpath.zig");
const executor = @import("../exec/executor.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const shell = @import("shell.zig");
const network = @import("network.zig");
const sysv_native = @import("sysvinit/native.zig");
const sysv_render = @import("sysvinit/render.zig");
const bsdrc_native = @import("bsdrc/native.zig");
const render = @import("procd/render.zig");
const layout = @import("procd/layout.zig");
const native = @import("procd/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Procd = @This();

pub const backend_name = "procd";
pub const generator_number = 1;

/// Capabilities of §11.3: dependencies start the scripts they name and order by `START`, procd
/// supervises and respawns, and the stop links run at shutdown.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
    .supervision = true,
    .restart_policy = true,
    .shutdown_hooks = true,
};

/// Priority of a script that follows nothing in particular: after `network` (20) and the
/// services of the system that most scripts follow.
const default_start = 50;
/// Failures in a row procd tolerates before it gives up, and the seconds an instance has to
/// run to be healthy; systemd's `StartLimitBurst=` and `StartLimitIntervalSec=` defaults.
const respawn_retry = 5;
const respawn_threshold = 10;
/// Seconds the executor needs, beyond `TimeoutStopSec=`, to stop its main process.
const executor_grace = 10;
/// Longest `term_timeout` procd multiplies by 1000 without overflowing an `int`.
const max_term_timeout = 2_000_000;
const default_stop_secs = 90;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Procd {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *Procd) Backend {
    self.vt = vtable;
    return .{ .ptr = self, .vtable = &self.vt };
}

const vtable: interface.VTable = .{
    .name = backend_name,
    .generator = generator_number,
    .caps = capabilities,
    .native_scan = nativeScan,
    .scan_dirs = scanDirs,
    .generate = generate,
    .enable = enable,
    .disable = disable,
    .start = start,
    .stop = stop,
    .restart = restart,
    .reload = reload,
    .kill = kill,
    .status = status,
    .is_enabled = isEnabled,
    .reload_manager = reloadManager,
    .power = power,
};

fn me(ptr: *anyopaque) *Procd {
    return @ptrCast(@alignCast(ptr));
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = if (self.ctx.scope == .user) &.{} else layout.lookupDirs(self.dirs),
        .extractor = native.extractCommand,
    };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    if (scope == .user) return &.{};
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{ .path = layout.generationDir(self.dirs), .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn contentOf(self: *const Procd, path: []const u8) !?[]const u8 {
    return guard.readOrAbsent(self.ctx, path, 1 << 20);
}

fn serviceExists(self: *Procd, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// Script a dependency refers to, or null when it cannot be one: targets (`network.target` and
/// `network-online.target` only order, through `START`), other unit types, and units that are
/// neither a script nor a systemd unit that can be translated.
fn mapDependency(self: *Procd, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
    const gpa = self.ctx.gpa;
    const n = name_mod.parse(gpa, dep) catch return null;
    if (n.kind != .service) return null;
    for (resolutions) |r| if (std.mem.eql(u8, r.unit, n.full)) return r.service;
    if (n.isTemplate() or std.mem.startsWith(u8, n.prefix, "systemd-")) return null;
    const svc = try layout.serviceName(gpa, n);
    if (std.mem.eql(u8, svc, own)) return null;
    if (try self.serviceExists(svc)) return svc;
    const resolved = resolve.resolve(gpa, self.ctx.fs.*, .{ .scope = self.ctx.scope, .xdg_config_home = self.ctx.xdg_config_home }, n) catch return null;
    return if (resolved.state == .found) svc else null;
}

fn mapList(self: *Procd, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const []const u8, out: *std.ArrayList([]const u8)) !void {
    outer: for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        for (exclude) |ex| if (contains(ex, mapped)) continue :outer;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

fn mapDependencies(self: *Procd, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) !render.Deps {
    var requires: std.ArrayList([]const u8) = .empty;
    var wants: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var before: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &.{}, &requires);
    try self.mapList(own, resolutions, u.binds_to, &.{}, &requires);
    try self.mapList(own, resolutions, u.wants, &.{requires.items}, &wants);
    try self.mapList(own, resolutions, u.after, &.{ requires.items, wants.items }, &after);
    try self.mapList(own, resolutions, u.before, &.{}, &before);
    return .{ .requires = requires.items, .wants = wants.items, .after = after.items, .before = before.items };
}

/// `START` of the script of `service`, when it has one.
fn startOf(self: *Procd, service: []const u8) !?u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    return native.parsePriorities((try self.contentOf(path)) orelse return null).start;
}

/// `START` of the script a network target stands for.
fn networkStart(self: *Procd) !?u8 {
    for (self.dirs.network_online) |svc| if (try self.startOf(svc)) |s| return s;
    return null;
}

/// The script starts after the scripts it requires, wants or follows, and before the ones it
/// precedes, by their `START`; the ones it follows win when both cannot hold, and a script that
/// is not there yet counts for nothing. A unit that mentions a network target follows the network
/// script of the profile.
fn startPriority(self: *Procd, u: *const model.Unit, deps: render.Deps) !u8 {
    var lower: u8 = 0;
    if (network.mentions(u)) if (try self.networkStart()) |s| {
        lower = @min(s + 1, 99);
    };
    for ([_][]const []const u8{ deps.requires, deps.wants, deps.after }) |names| {
        for (names) |n| if (try self.startOf(n)) |s| {
            lower = @max(lower, @min(s + 1, 99));
        };
    }
    var upper: u8 = 99;
    for (deps.before) |n| if (try self.startOf(n)) |s| {
        upper = @min(upper, s -| 1);
    };
    return @max(lower, @min(default_start, upper));
}

fn stopPriority(start_priority: u8) u8 {
    return @min(100 - start_priority, 99);
}

fn modeFor(u: *const model.Unit) render.Mode {
    if (u.exec_start.len == 0) return .none;
    if (u.service_type == .oneshot) return .oneshot;
    // A daemon without a pid file cannot be followed: the command runs to the end and the service
    // stays active.
    if (u.service_type == .forking and u.pid_file == null) return .oneshot;
    return .daemon;
}

fn remains(u: *const model.Unit, mode: render.Mode) bool {
    return switch (mode) {
        .daemon => false,
        .oneshot => u.remain_after_exit or u.service_type == .forking,
        .none => u.remain_after_exit,
    };
}

fn ceilSeconds(us: u64) u32 {
    const secs = std.math.divCeil(u64, us, std.time.us_per_s) catch return std.math.maxInt(u32);
    return @intCast(@min(secs, max_term_timeout));
}

/// `RestartSec=` is the delay procd waits; any `Restart=` but `no` respawns on every exit, since
/// procd does not tell exit statuses apart.
fn respawnOf(u: *const model.Unit) ?render.Respawn {
    if (u.restart == .no) return null;
    const delay = u.restart_sec orelse 100 * std.time.us_per_ms;
    return .{ .threshold = respawn_threshold, .timeout = ceilSeconds(if (delay == timespan.infinity) 0 else delay), .retry = respawn_retry };
}

/// Seconds procd waits after SIGTERM: `TimeoutStopSec=`, and the time the executor needs to stop
/// its main process when it is the one that gets the signal.
fn termTimeout(u: *const model.Unit) u32 {
    const timeout = u.timeout_stop_sec orelse default_stop_secs * std.time.us_per_s;
    if (timeout == timespan.infinity) return max_term_timeout;
    const grace: u32 = if (sysv_render.stopsOnSignal(u)) executor_grace else 0;
    return @min(@max(ceilSeconds(timeout), 1) + grace, max_term_timeout);
}

fn notesFor(self: *Procd, gpa: Allocator, u: *const model.Unit, mode: render.Mode) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and mode == .oneshot) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not followed, and stop cannot signal it");
    }
    if (mode == .daemon) switch (u.restart) {
        .@"on-failure", .@"on-abnormal", .@"on-abort", .@"on-success", .@"on-watchdog" => try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={t} is approximated by respawning on every exit", .{u.restart})),
        else => {},
    };
    if (mode == .daemon and u.kill_signal != null and !std.mem.eql(u8, u.kill_signal.?, "SIGTERM")) {
        try notes.append(gpa, "KillSignal= is not honored: procd stops an instance with SIGTERM");
    }
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    try self.unknownAccountNotes(gpa, u, &notes);
    return notes.toOwnedSlice(gpa);
}

fn accountKnown(self: *Procd, file: []const u8, account: []const u8) bool {
    if (shell.allDigits(account)) return true;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

/// The executor switches account from `/etc/passwd` and `/etc/group`, which are all musl reads:
/// an account that is not in them cannot be switched to, which the script says and a warning repeats.
fn unknownAccountNotes(self: *Procd, gpa: Allocator, u: *const model.Unit, notes: *std.ArrayList([]const u8)) !void {
    if (u.user) |user| if (!self.accountKnown("/etc/passwd", user)) {
        self.ctx.diag.warn("{s}: User={s} is not in /etc/passwd, and the executor has no other source of accounts", .{ u.name.full, user });
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "User={s} is not in /etc/passwd: the executor cannot switch to it", .{user}));
    };
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) {
        self.ctx.diag.warn("{s}: Group={s} is not in /etc/group", .{ u.name.full, g });
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "Group={s} is not in /etc/group: the executor cannot switch to it", .{g}));
    };
}

fn isPlainAbsolute(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |c| if (c == '$' or c == '%' or c < ' ') return false;
    return true;
}

fn watchFiles(gpa: Allocator, u: *const model.Unit) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (u.environment_file) |f| if (isPlainAbsolute(f.path) and !contains(out.items, f.path)) try out.append(gpa, f.path);
    return out.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: procd has no service manager for users", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    const mode = modeFor(u);
    const deps = try self.mapDependencies(svc, u, input.deps);
    const start_priority = try self.startPriority(u, deps);
    const exit_file = try executor.execExitPath(self.ctx, u.name.full);
    const in: render.Input = .{
        .unit = u,
        .service = svc,
        .script_dir = layout.generationDir(self.dirs),
        .mode = mode,
        .remain = remains(u, mode),
        .deps = deps,
        .start_priority = start_priority,
        .stop_priority = stopPriority(start_priority),
        .respawn = if (mode == .daemon) respawnOf(u) else null,
        .term_timeout = termTimeout(u),
        .watch_files = try watchFiles(gpa, u),
        .executor_path = policy.executor_path,
        .state_dir = std.fs.path.dirname(exit_file) orelse "/run/fake-systemd",
        .log_dir = logpath.logDir(self.ctx, u.name.full),
        .main_pid_file = try executor.execPidPath(self.ctx, u.name.full),
        .exit_file = exit_file,
        .notes = try self.notesFor(gpa, u, mode),
    };
    const body = try render.script(gpa, in);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);
    const path = try std.fs.path.join(gpa, &.{ layout.generationDir(self.dirs), svc });
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, path, u.name.full), u.name.full, path);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = path, .content = content, .mode = 0o755 };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

fn isGenerated(self: *Procd, path: []const u8) !bool {
    const content = (try self.contentOf(path)) orelse return false;
    return marker.parse(content) != null;
}

fn startLink(self: *Procd, service: []const u8) !?layout.Found {
    for (try layout.linksOf(self.ctx, self.dirs, service)) |l| if (l.start) return l;
    return null;
}

fn isExecutable(self: *const Procd, path: []const u8) bool {
    const st = self.ctx.fs.stat(path) catch return false;
    return st.mode & 0o111 != 0;
}

/// The script's own `enable` and `disable` write the links in a running system. Without an
/// init the script cannot run: its procd library takes a lock in `/var/lock`, which only a
/// booted system has.
fn useScript(self: *Procd, env: Env, path: []const u8) bool {
    return env.online and self.isExecutable(path);
}

fn symlinkIfMissing(self: *Procd, link: []const u8, service: []const u8) !void {
    _ = self.ctx.fs.lstat(link) catch |e| switch (e) {
        error.FileNotFound => {
            try self.ctx.fs.makePath(layout.linkDir(self.dirs));
            return self.ctx.fs.symLink(try layout.linkTarget(self.ctx.gpa, service), link);
        },
        else => return e,
    };
}

/// Writes the links as `rc.common` does: `S<START>` and `K<STOP>` of the script.
fn linkDirect(self: *Procd, service: []const u8, path: []const u8) !void {
    const gpa = self.ctx.gpa;
    const prio = native.parsePriorities((try self.contentOf(path)) orelse "");
    if (prio.start == null and prio.stop == null) {
        self.ctx.diag.err("{s}: the script sets neither START nor STOP, there is no link to write", .{service});
        return error.Unsupported;
    }
    if (prio.start) |s| try self.symlinkIfMissing(try layout.linkFile(gpa, self.dirs, true, s, service), service);
    if (prio.stop) |s| try self.symlinkIfMissing(try layout.linkFile(gpa, self.dirs, false, s, service), service);
}

/// True when the link `name` in the link directory is the one `rc.common` writes for `service`.
fn pointsAtScript(self: *Procd, name: []const u8, service: []const u8) bool {
    const path = std.fs.path.join(self.ctx.gpa, &.{ layout.linkDir(self.dirs), name }) catch return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = self.ctx.fs.readLink(path, &buf) catch return false;
    const expected = layout.linkTarget(self.ctx.gpa, service) catch return false;
    return std.mem.eql(u8, target, expected);
}

/// Every generated script gets its stop link, so that a service that was started by hand or as
/// a dependency runs its stop hook at shutdown as well, and a stop link whose script is gone
/// leaves.
fn syncStopLinks(self: *Procd, env: Env) !void {
    if (env.ctx.dry_run) return;
    const gpa = env.ctx.gpa;
    const dir = layout.generationDir(self.dirs);
    const scripts = try guard.iterateOrEmpty(self.ctx, dir);
    for (scripts) |e| {
        if (e.kind != .file) continue;
        const path = try std.fs.path.join(gpa, &.{ dir, e.name });
        if (!(try self.isGenerated(path))) continue;
        const stop_number = native.parsePriorities((try self.contentOf(path)) orelse continue).stop orelse continue;
        self.symlinkIfMissing(try layout.linkFile(gpa, self.dirs, false, stop_number, e.name), e.name) catch |err| {
            env.ctx.diag.warn("{s}: cannot write the stop link: {t}", .{ e.name, err });
        };
    }
    const links = try guard.iterateOrEmpty(self.ctx, layout.linkDir(self.dirs));
    const owned = guard.indexedPaths(self.ctx, env.owned_paths, backend_name, generator_number);
    for (links) |e| {
        const link = layout.parseLink(e.name) orelse continue;
        if (link.start or e.kind != .sym_link) continue;
        const target = try std.fs.path.join(gpa, &.{ dir, link.name });
        if (self.ctx.fs.exists(target)) continue;
        // Only the stop links of scripts the index lists as generated are ours to remove.
        if (!guard.anyUnder(owned, target) or !self.pointsAtScript(e.name, link.name)) continue;
        self.ctx.fs.deleteFile(try std.fs.path.join(gpa, &.{ layout.linkDir(self.dirs), e.name })) catch |err| {
            env.ctx.diag.warn("{s}: cannot remove the stale stop link: {t}", .{ e.name, err });
        };
    }
}

fn runScript(env: Env, path: []const u8, action: []const u8) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, &.{ path, action }, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

/// The start links of `after` that `before` does not have, and the ones that are gone.
fn diffLinks(gpa: Allocator, before: []const layout.Found, after: []const layout.Found, service: []const u8, changes: *std.ArrayList(interface.Change)) !void {
    for (after) |a| {
        if (!a.start) continue;
        const known = for (before) |b| {
            if (b.start and std.mem.eql(u8, b.path, a.path)) break true;
        } else false;
        if (!known) try changes.append(gpa, .{ .created = .{ .link = a.path, .target = try layout.linkTarget(gpa, service) } });
    }
    for (before) |b| {
        if (!b.start) continue;
        const kept = for (after) |a| {
            if (a.start and std.mem.eql(u8, b.path, a.path)) break true;
        } else false;
        if (!kept) try changes.append(gpa, .{ .removed = b.path });
    }
}

fn predictedLink(self: *Procd, env: Env, service: []const u8, path: []const u8) !?interface.Change {
    const gpa = env.ctx.gpa;
    const prio = native.parsePriorities((try self.contentOf(path)) orelse "");
    const number = prio.start orelse return null;
    return .{ .created = .{ .link = try layout.linkFile(gpa, self.dirs, true, number, service), .target = try layout.linkTarget(gpa, service) } };
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    var changes: std.ArrayList(interface.Change) = .empty;
    const state = try self.startLink(service);
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse {
        if (state != null) return changes.items;
        // A dry run has not written the script yet.
        if (env.ctx.dry_run) {
            try changes.append(gpa, .{ .created = .{ .link = try layout.linkFile(gpa, self.dirs, true, default_start, service), .target = try layout.linkTarget(gpa, service) } });
            return changes.items;
        }
        env.ctx.diag.err("{s}: no init script found", .{service});
        return error.Unsupported;
    };
    if (state != null) {
        try self.syncStopLinks(env);
        return changes.items;
    }
    if (env.ctx.dry_run) {
        if (try self.predictedLink(env, service, path)) |c| try changes.append(gpa, c);
        return changes.items;
    }
    const before = try layout.linksOf(self.ctx, self.dirs, service);
    if (self.useScript(env, path)) try runScript(env, path, "enable") else try self.linkDirect(service, path);
    try self.syncStopLinks(env);
    try diffLinks(gpa, before, try layout.linksOf(self.ctx, self.dirs, service), service, &changes);
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    var changes: std.ArrayList(interface.Change) = .empty;
    if ((try self.startLink(service)) == null) return changes.items;
    const before = try layout.linksOf(self.ctx, self.dirs, service);
    if (env.ctx.dry_run) {
        for (before) |l| if (l.start) try changes.append(gpa, .{ .removed = l.path });
        return changes.items;
    }
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse "";
    if (path.len > 0 and self.useScript(env, path)) {
        try runScript(env, path, "disable");
    } else for (before) |l| {
        // The stop link of a generated script stays, as the script may still run.
        if (l.start or !(try self.isGenerated(path))) try self.ctx.fs.deleteFile(l.path);
    }
    try self.syncStopLinks(env);
    try diffLinks(gpa, before, try layout.linksOf(self.ctx, self.dirs, service), service, &changes);
    return changes.items;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    return if ((try me(ptr).startLink(service)) != null) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

/// Path of the script of `service`; a dry run has not written it yet.
fn scriptPath(self: *Procd, env: Env, service: []const u8) ![]const u8 {
    if (try layout.locate(self.ctx, self.dirs, service)) |path| return path;
    if (env.ctx.dry_run) return std.fs.path.join(env.ctx.gpa, &.{ layout.generationDir(self.dirs), service });
    env.ctx.diag.err("{s}: no init script found", .{service});
    return error.Unsupported;
}

/// Last lines of the output of a script that failed.
fn reportFailure(env: Env, service: []const u8, action: []const u8, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    const from = if (std.mem.findScalarLast(u8, trimmed[0..trimmed.len -| 1], '\n')) |at| at + 1 else 0;
    env.ctx.diag.err("{s} {s}: {s}", .{ service, action, trimmed[from..] });
}

fn control(self: *Procd, env: Env, service: []const u8, action: []const u8) anyerror!void {
    const path = try self.scriptPath(env, service);
    const res = try env.runner.run(env.ctx.gpa, &.{ path, action }, .capture);
    if (res.code != 0) {
        reportFailure(env, service, action, res.stdout);
        return error.CommandFailed;
    }
}

/// A started service has to be stopped at shutdown, so its stop link is written first.
fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.syncStopLinks(env);
    return self.control(env, service, "start");
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "stop");
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.syncStopLinks(env);
    return self.control(env, service, "restart");
}

/// `reload` of `rc.common` runs `reload_service`, and starts the service again without one,
/// which procd takes for a change only when the instance or a file it watches changed.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "reload");
}

/// Unit recorded in the marker of the script, null for native scripts.
fn generatedUnit(self: *Procd, service: []const u8) !?[]const u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    const content = (try self.contentOf(path)) orelse return null;
    return guard.unitOfMarked(content);
}

fn listingArgv(gpa: Allocator, service: []const u8) ![]const []const u8 {
    const request = try std.fmt.allocPrint(gpa, "{{\"name\": \"{s}\"}}", .{service});
    return gpa.dupe([]const u8, &.{ "ubus", "call", "service", "list", request });
}

/// State of a procd service: its instances as `ubus` lists them.
fn listed(env: Env, service: []const u8) !struct { state: native.State, text: []const u8 } {
    const res = try env.runner.run(env.ctx.gpa, try listingArgv(env.ctx.gpa, service), .capture);
    if (res.code != 0) return .{ .state = .{ .state = .inactive }, .text = "" };
    return .{ .state = try native.stateOfListing(env.ctx.gpa, res.stdout, service), .text = res.stdout };
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const path = try self.scriptPath(env, service);
    const pid: ?u32 = if (native.usesProcd((try self.contentOf(path)) orelse ""))
        guard.accepted(self.ctx, (try listed(env, service)).state.pid, null)
    else
        try self.execPid(service);
    const target = pid orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{target});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// Main process of a generated service that runs without procd, from the file its executor writes.
fn execPid(self: *Procd, service: []const u8) !?u32 {
    const unit = (try self.generatedUnit(service)) orelse return null;
    const path = executor.execPidPath(self.ctx, unit) catch return null;
    return guard.recordedPid(self.ctx, path);
}

/// A service with an instance is what procd lists. A script without instances answers `status`
/// with the exit codes of LSB, and a native one that does not know the verb prints its help.
fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const self = me(ptr);
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return .{ .state = .inactive };
    const content = (try self.contentOf(path)) orelse "";
    if (native.usesProcd(content)) {
        const l = try listed(env, service);
        return .{ .state = l.state.state, .pid = l.state.pid, .text = l.text };
    }
    const res = try env.runner.run(env.ctx.gpa, &.{ path, "status" }, .capture);
    const state = sysv_native.stateOfStatus(res.code, native.looksLikeHelp(res.stdout));
    return .{ .state = state, .pid = if (state == .active) try self.execPid(service) else null, .text = res.stdout };
}

// ---- manager ----------------------------------------------------------------------------

/// Scripts are read when they run, so there is nothing to reload; the stop links follow the
/// scripts that exist.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    return me(ptr).syncStopLinks(env);
}

/// procd turns the signal that `reboot`, `poweroff` and `halt` send into the shutdown, and runs
/// the stop links of `/etc/rc.d` before it.
fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const argv: []const []const u8 = switch (action) {
        .reboot => &.{"reboot"},
        .poweroff => &.{"poweroff"},
        .halt => &.{"halt"},
    };
    const res = try env.runner.run(env.ctx.gpa, argv, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
