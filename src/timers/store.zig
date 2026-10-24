// SPDX-License-Identifier: GPL-3.0-or-later
//! Access to the index and to per-service job locks for the timer runtime, outside of a
//! `Session`: the timer entries are read and written under the index lock of §7.5.
const std = @import("std");
const core = @import("../core/root.zig");
const index_pkg = @import("../index/root.zig");
const backend_pkg = @import("../backend/root.zig");

const Index = index_pkg.Index;

const Store = @This();

ctx: *core.Context,
layout: index_pkg.Layout,
backend_name: []const u8,
generator: u32,
/// The backend keeps no index (null backend): reads are empty and writes fail.
persistent: bool,

pub fn init(ctx: *core.Context, backend: backend_pkg.Backend) !Store {
    return .{
        .ctx = ctx,
        .layout = try .init(ctx.gpa, ctx.scope, ctx.xdg_state_home, backend.name()),
        .backend_name = backend.name(),
        .generator = backend.generator(),
        .persistent = backend.caps().translates,
    };
}

/// An index loaded under a lock; `commit` saves it, `abort` drops the changes.
pub const Txn = struct {
    store: Store,
    lock: index_pkg.lock.Lock,
    idx: Index,
    exclusive: bool,

    /// Saves the index when the lock is exclusive, then releases the lock.
    pub fn commit(t: *Txn) !void {
        defer t.release();
        if (!t.exclusive) return;
        const gpa = t.store.ctx.gpa;
        try t.idx.save(gpa, t.store.ctx.fs.*, try t.store.layout.indexPath(gpa));
    }

    pub fn release(t: *Txn) void {
        t.lock.release();
    }
};

/// Loads the index under the lock; allocations come from `ctx.gpa`, which is expected to be an
/// arena that lives as long as the index is used.
pub fn begin(st: Store, exclusive: bool) !Txn {
    const gpa = st.ctx.gpa;
    if (!st.persistent) return error.NoIndex;
    var lock = try index_pkg.lock.acquire(
        st.ctx.fs.*,
        st.ctx.diag,
        try st.layout.lockPath(gpa),
        if (exclusive) .exclusive else .shared,
        .{},
    );
    errdefer lock.release();
    const loaded = try Index.load(gpa, st.ctx.fs.*, st.ctx.diag, try st.layout.indexPath(gpa), st.backend_name, st.generator);
    return .{ .store = st, .lock = lock, .idx = loaded.index, .exclusive = exclusive };
}

/// The per-service job lock of `--run-job`; null when another run holds it.
pub fn tryJobLock(st: Store, service: []const u8) !?index_pkg.lock.Lock {
    const path = try std.fs.path.join(st.ctx.gpa, &.{ st.layout.state_dir, st.backend_name, "jobs", try std.fmt.allocPrint(st.ctx.gpa, "{s}.lock", .{service}) });
    return index_pkg.lock.tryAcquire(st.ctx.fs.*, path);
}
