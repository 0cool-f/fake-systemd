// SPDX-License-Identifier: GPL-3.0-or-later
//! Per-invocation state shared by all verbs: dependencies, index access under the lock, caches
//! and output helpers. Allocations come from `ctx.gpa`, which is an arena.
const std = @import("std");
const Io = std.Io;
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const index_pkg = @import("../index/root.zig");
const reconcile = @import("../reconcile/root.zig");
const cli = @import("../cli/root.zig");
const backend_pkg = @import("../backend/root.zig");

const Context = core.Context;
const Index = index_pkg.Index;
const Backend = backend_pkg.Backend;
const output = cli.output;

pub const Deps = struct {
    backend: Backend,
    runner: backend_pkg.Runner,
    /// Standard output.
    out: *Io.Writer,
    /// Standard error, for systemd-style lines that carry no `fake-systemd:` prefix.
    err: *Io.Writer,
    /// Name of the detected init, used in messages.
    detected: []const u8 = "unknown",
};

pub const Intent = enum { read, write };

/// Result of the detection of a native timer scheduler, cached for the invocation.
pub const TimerAdapter = struct { kind: ?@import("../timers/adapters.zig").Kind };

/// Names of units that a `.timer`, `.socket` or `.path` unit starts.
pub const Activators = struct {
    timer_targets: std.StringHashMapUnmanaged(void) = .empty,
    other_targets: std.StringHashMapUnmanaged(void) = .empty,
};

const Session = @This();

ctx: *Context,
deps: Deps,
req: cli.systemctl.Request,
layout: index_pkg.Layout,
dry_runner: backend_pkg.runner.Dry,
runtime_verb: bool = true,
idx: ?Index = null,
persist: bool = true,
lock: ?index_pkg.lock.Lock = null,
lock_mode: index_pkg.lock.Mode = .shared,
dirty: bool = false,
natives: ?[]const backend_pkg.interface.NativeService = null,
/// Cache entries of the last native scan, waiting to be stored in the index.
native_entries: ?[]const Index.Native = null,
native_dir_entries: []const Index.NativeDir = &.{},
/// A scanned native directory has another mtime than the cached one.
native_dirs_changed: bool = false,
/// The last native scan differed from the cached one.
natives_changed: bool = false,
/// The index was written by another generator version.
generator_changed: bool = false,
/// The configuration differs from the one the index entries were computed with.
config_changed: bool = false,
activators: ?Activators = null,
/// Units whose entry changed during this `daemon-reload`; units that depend on them are not skipped.
changed: std.StringHashMapUnmanaged(void) = .empty,
spec_env: ?unit.specifier.Env = null,
timer_adapter: ?TimerAdapter = null,

pub fn init(ctx: *Context, deps: Deps, req: cli.systemctl.Request) !Session {
    return .{
        .ctx = ctx,
        .deps = deps,
        .req = req,
        .layout = try .init(ctx.gpa, ctx.scope, ctx.xdg_state_home, deps.backend.name()),
        .dry_runner = .{ .out = deps.out },
    };
}

pub fn out(s: *Session) *Io.Writer {
    return s.deps.out;
}

pub fn err(s: *Session) *Io.Writer {
    return s.deps.err;
}

pub fn quiet(s: Session) bool {
    return s.req.options.quiet;
}

/// Runner for the current verb: dry runs only print the command.
pub fn runner(s: *Session) backend_pkg.Runner {
    if (s.ctx.dry_run and s.runtime_verb) return s.dry_runner.runner();
    return s.deps.runner;
}

pub fn env(s: *Session) backend_pkg.interface.Env {
    return .{ .ctx = s.ctx, .runner = s.runner(), .online = !s.ctx.offline };
}

pub fn resolveOptions(s: Session) unit.resolve.Options {
    return .{ .scope = s.ctx.scope, .xdg_config_home = s.ctx.xdg_config_home };
}

pub fn style(s: Session) output.Style {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        const v = s.ctx.getEnv(name) orelse continue;
        if (v.len == 0) continue;
        return .{ .utf8 = std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null };
    }
    return .{ .utf8 = false };
}

pub fn applyEnv(s: *Session, verb: reconcile.plan.Verb) reconcile.apply.Env {
    return .{
        .gpa = s.ctx.gpa,
        .fs = s.ctx.fs,
        .diag = s.ctx.diag,
        .layout = s.layout,
        .verb = verb,
        .dry_run = s.ctx.dry_run,
        .out = s.deps.out,
    };
}

/// The index, loaded under the lock on first use. A write intent takes the exclusive lock;
/// dry runs and reads only share it, so they leave no file behind.
pub fn index(s: *Session, intent: Intent) !*Index {
    const want: index_pkg.lock.Mode = if (intent == .write and !s.ctx.dry_run) .exclusive else .shared;
    if (s.idx != null and (s.lock_mode == .exclusive or want == .shared)) return &s.idx.?;
    if (s.lock) |*l| l.release();
    s.lock = null;
    s.idx = null;
    s.lock_mode = want;

    if (!s.deps.backend.caps().translates) {
        s.persist = false;
        s.idx = .init(s.deps.backend.name(), s.deps.backend.generator());
        return &s.idx.?;
    }
    const gpa = s.ctx.gpa;
    s.lock = try index_pkg.lock.acquire(s.ctx.fs.*, s.ctx.diag, try s.layout.lockPath(gpa), want, .{});
    const loaded = try Index.load(gpa, s.ctx.fs.*, s.ctx.diag, try s.layout.indexPath(gpa), s.deps.backend.name(), s.deps.backend.generator());
    s.idx = loaded.index;
    s.generator_changed = loaded.status == .generator_changed;
    s.config_changed = loaded.index.config_hash != try index_pkg.hash.configHash(gpa, s.ctx.config);
    if (loaded.status == .rebuild_needed) try s.rebuildIndex();
    s.storeNatives();
    return &s.idx.?;
}

fn rebuildIndex(s: *Session) !void {
    const dirs = try s.deps.backend.scanDirs(s.ctx.gpa, s.ctx.scope);
    try index_pkg.rebuild.rebuild(s.ctx.gpa, s.ctx.fs.*, s.ctx.diag, &s.idx.?, .{ .scope = s.ctx.scope, .dirs = dirs });
    if (s.lock_mode == .exclusive and s.idx.?.units.items.len > 0) s.dirty = true;
}

/// Records the current configuration hash once every entry was synced against it.
pub fn storeConfigHash(s: *Session) !void {
    if (!s.config_changed or !s.persist or s.ctx.dry_run or s.lock_mode != .exclusive) return;
    const idx = if (s.idx) |*i| i else return;
    idx.config_hash = try index_pkg.hash.configHash(s.ctx.gpa, s.ctx.config);
    s.config_changed = false;
    s.markDirty();
}

pub fn markDirty(s: *Session) void {
    s.dirty = true;
}

/// Saves a changed index and releases the lock. Returns false when saving failed.
pub fn finish(s: *Session) bool {
    var ok = true;
    if (s.dirty and s.persist and !s.ctx.dry_run) {
        if (s.idx) |idx| {
            const path = s.layout.indexPath(s.ctx.gpa) catch |e| return s.finishFailed(e);
            idx.save(s.ctx.gpa, s.ctx.fs.*, path) catch |e| {
                s.ctx.diag.err("cannot write index {s}: {t}", .{ path, e });
                ok = false;
            };
        }
    }
    if (s.lock) |*l| l.release();
    s.lock = null;
    s.dirty = false;
    return ok;
}

fn finishFailed(s: *Session, e: anyerror) bool {
    s.ctx.diag.err("cannot save the index: {t}", .{e});
    if (s.lock) |*l| l.release();
    s.lock = null;
    return false;
}

pub fn nativeServices(s: *Session) ![]const backend_pkg.interface.NativeService {
    if (s.natives) |n| return n;
    const idx = try s.index(.read);
    const scan = try s.deps.backend.nativeScan(.{ .ctx = s.ctx, .runner = s.deps.runner, .online = !s.ctx.offline });
    const result = try backend_pkg.native_scan.scanCached(s.ctx.gpa, s.ctx.fs.*, scan, idx.natives.items, idx.native_dirs.items);
    s.natives = result.services;
    s.native_entries = result.entries;
    s.natives_changed = result.changed;
    s.native_dir_entries = result.dirs;
    s.native_dirs_changed = result.dirs_changed;
    s.storeNatives();
    return result.services;
}

/// Writes the scan result into the index when it holds the exclusive lock.
fn storeNatives(s: *Session) void {
    const entries = s.native_entries orelse return;
    if (!(s.natives_changed or s.native_dirs_changed) or !s.persist or s.ctx.dry_run or s.lock_mode != .exclusive) return;
    const idx = if (s.idx) |*i| i else return;
    idx.natives.clearRetainingCapacity();
    idx.natives.appendSlice(s.ctx.gpa, entries) catch |e| return s.ctx.diag.warn("cannot cache native services: {t}", .{e});
    idx.native_dirs.clearRetainingCapacity();
    idx.native_dirs.appendSlice(s.ctx.gpa, s.native_dir_entries) catch |e| return s.ctx.diag.warn("cannot cache native directories: {t}", .{e});
    s.native_entries = null;
    s.markDirty();
}

pub fn printChanges(s: *Session, changes: []const backend_pkg.interface.Change) !void {
    for (changes) |c| {
        if (s.ctx.dry_run) {
            switch (c) {
                .created => |l| try s.out().print("would create symlink '{s}' -> '{s}'\n", .{ l.link, l.target }),
                .removed => |p| try s.out().print("would remove '{s}'\n", .{p}),
                .created_file => |p| try s.out().print("would create '{s}'\n", .{p}),
                .mode_set => |m| try s.out().print("would make '{s}' {s}executable\n", .{ m.path, if (m.executable) "" else "not " }),
            }
            continue;
        }
        if (s.quiet()) continue;
        switch (c) {
            .created => |l| try output.writeCreatedSymlink(s.err(), s.style(), l.link, l.target),
            .removed => |p| try output.writeRemoved(s.err(), p),
            .created_file => |p| try output.writeCreatedFile(s.err(), p),
            .mode_set => |m| try output.writeModeSet(s.err(), m.path, m.executable),
        }
    }
}

/// Reports that no backend can serve the request.
pub fn reportNoBackend(s: *Session) void {
    s.ctx.diag.err(backend_pkg.NullBackend.no_backend_fmt, .{s.deps.detected});
}

pub fn offlineNotice(s: *Session, verb: []const u8, unit_name: []const u8) void {
    s.ctx.diag.notice("init is not running, not contacting it: skipping '{s} {s}'", .{ verb, unit_name });
}

/// Reports a failed backend call; returns the exit code.
pub fn backendFailed(s: *Session, verb: []const u8, unit_name: []const u8, e: anyerror) u8 {
    if (e != error.Unsupported) s.ctx.diag.err("Failed to {s} {s}: {t}", .{ verb, unit_name, e });
    return output.Exit.failure;
}

/// Reports a unit the classifier excluded; returns the exit code.
pub fn refuseUnsupported(s: *Session, name: []const u8, reason: []const u8) u8 {
    s.ctx.diag.err("{s}: not translated: {s}", .{ name, reason });
    return output.Exit.failure;
}
