// SPDX-License-Identifier: GPL-3.0-or-later
//! `daemon-reload` (§6.8): sync managed entries, adopt native takeovers, garbage-collect,
//! translate eagerly when configured, then reload the backend.
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const index_pkg = @import("../index/root.zig");
const reconcile = @import("../reconcile/root.zig");
const backend_pkg = @import("../backend/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const timers = @import("timers.zig");

const Exit = cli.output.Exit;
const Index = index_pkg.Index;

fn drop(s: *Session, idx: *Index, name: []const u8) !void {
    var env = s.applyEnv(.daemon_reload);
    _ = try reconcile.apply.dropUnit(&env, idx, s.ctx.gpa, name);
    s.markDirty();
}

/// True when the entry of `before` differs from the one in the index now, or is gone.
fn entryChanged(idx: *Index, before: Index.Unit) bool {
    const now = idx.findUnit(before.name) orelse return true;
    if (now.state != before.state or now.origin != before.origin or now.files.len != before.files.len) return true;
    for (now.files, before.files) |a, b| if (a.out_hash != b.out_hash or !std.mem.eql(u8, a.path, b.path)) return true;
    return false;
}

/// Processes one entry and records it in `Session.changed` when its outcome differs from the index.
fn syncEntry(s: *Session, idx: *Index, entry: Index.Unit) !void {
    const full = try syncEntryInner(s, idx, entry);
    if (full and (s.ctx.dry_run or entryChanged(idx, entry))) try s.changed.put(s.ctx.gpa, entry.name, {});
}

/// Returns true when the entry went through the full pipeline.
fn syncEntryInner(s: *Session, idx: *Index, entry: Index.Unit) !bool {
    const gpa = s.ctx.gpa;
    const name = unit.name.parse(gpa, entry.name) catch {
        s.ctx.diag.warn("index entry '{s}' is not a valid unit name, skipped", .{entry.name});
        return false;
    };
    const resolved = unit.resolve.resolve(gpa, s.ctx.fs.*, s.resolveOptions(), name) catch |e| {
        s.ctx.diag.warn("{s}: cannot resolve unit: {t}", .{ entry.name, e });
        return false;
    };
    switch (try pipeline.fastCheck(s, entry, resolved)) {
        .unchanged => return false,
        .refresh => |fingerprint| {
            if (s.ctx.dry_run) return false;
            var updated = entry;
            updated.src_stat = fingerprint;
            try idx.putUnit(gpa, updated);
            s.markDirty();
            return false;
        },
        .full => {},
    }
    const plan = pipeline.prepareResolved(s, name, resolved) catch |e| {
        s.ctx.diag.warn("{s}: cannot load unit: {t}", .{ entry.name, e });
        return false;
    };
    switch (plan.outcome) {
        .not_found, .unsupported => try drop(s, idx, entry.name),
        .masked, .timer, .template, .no_backend => {},
        .conflict => |n| s.ctx.diag.warn("{s}: the name is taken by native service '{s}'", .{ entry.name, n.name }),
        .native => |n| if (entry.state != .native) try pipeline.adoptNative(s, &plan, n, entry.origin),
        .generate => {
            if (entry.state == .native) {
                if (!s.ctx.dry_run) {
                    _ = idx.removeUnit(entry.name);
                    s.markDirty();
                }
                return false;
            }
            _ = try pipeline.syncPlan(s, &plan, .daemon_reload, entry.origin, .missing);
        },
    }
    return true;
}

fn translateAll(s: *Session, idx: *Index) !void {
    const gpa = s.ctx.gpa;
    const listed = try unit.resolve.list(gpa, s.ctx.fs.*, s.resolveOptions());
    for (listed) |l| {
        if (l.masked or l.alias_of != null) continue;
        const name = try unit.name.parse(gpa, l.name);
        if (name.isTemplate() or name.kind != .service) continue;
        if (idx.findUnit(name.full) != null) continue;
        const plan = pipeline.prepare(s, name) catch continue;
        if (plan.outcome != .generate or plan.class.?.kind != .candidate) continue;
        _ = try pipeline.commit(s, &plan, .explicit);
    }
}

/// Entries with the units they depend on first, following the `deps` lists; a cycle is cut where it closes.
fn dependencyOrder(gpa: std.mem.Allocator, entries: []const Index.Unit) ![]const Index.Unit {
    var out: std.ArrayList(Index.Unit) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |e| try visit(gpa, entries, e, &seen, &out);
    return out.items;
}

fn visit(gpa: std.mem.Allocator, entries: []const Index.Unit, e: Index.Unit, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(Index.Unit)) !void {
    if (seen.contains(e.name)) return;
    try seen.put(gpa, e.name, {});
    for (e.deps) |d| {
        for (entries) |other| if (std.mem.eql(u8, other.name, d)) try visit(gpa, entries, other, seen, out);
    }
    try out.append(gpa, e);
}

pub fn run(s: *Session) !u8 {
    if (s.deps.backend.caps().translates) {
        const idx = try s.index(.write);
        const entries = try s.ctx.gpa.dupe(Index.Unit, idx.units.items);
        for (try dependencyOrder(s.ctx.gpa, entries)) |e| try syncEntry(s, idx, e);
        try pipeline.collectDependencies(s, idx, .daemon_reload);
        if (s.ctx.config.translate == .eager) try translateAll(s, idx);
        try timers.reconcileAll(s);
        try s.storeConfigHash();
    }
    if (s.ctx.offline) return Exit.success;
    s.deps.backend.reloadManager(s.env()) catch |e| return s.backendFailed("reload", "the init manager", e);
    return Exit.success;
}

test "entries are ordered with their dependencies first and cycles terminate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const base: Index.Unit = .{ .name = "", .scope = .system, .tier = .vendor, .state = .managed, .src_hash = 0, .src_stat = 0, .files = &.{}, .generator_version = "" };
    var a = base;
    a.name = "a.service";
    a.deps = &.{ "b.service", "missing.service" };
    var b = base;
    b.name = "b.service";
    b.deps = &.{"c.service"};
    var c = base;
    c.name = "c.service";
    c.deps = &.{"a.service"};
    const ordered = try dependencyOrder(arena.allocator(), &.{ a, b, c });
    try std.testing.expectEqual(@as(usize, 3), ordered.len);
    try std.testing.expectEqualStrings("c.service", ordered[0].name);
    try std.testing.expectEqualStrings("b.service", ordered[1].name);
    try std.testing.expectEqualStrings("a.service", ordered[2].name);
    const chain = try dependencyOrder(arena.allocator(), &.{ a, b, .{ .name = "c.service", .scope = .system, .tier = .vendor, .state = .managed, .src_hash = 0, .src_stat = 0, .files = &.{}, .generator_version = "" } });
    try std.testing.expectEqualStrings("c.service", chain[0].name);
}
