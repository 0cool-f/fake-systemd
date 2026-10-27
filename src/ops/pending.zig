// SPDX-License-Identifier: GPL-3.0-or-later
//! Units that `enable` accepted but could not translate yet because their `ExecStart=` binary
//! is absent. A pending entry has state `missing`, no files and a zero source hash; a later
//! `daemon-reload` that finds the binary writes the files for it like for a new unit.
const std = @import("std");
const index_pkg = @import("../index/root.zig");
const backend_pkg = @import("../backend/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");

const Index = index_pkg.Index;

/// True for an entry made by `record`.
pub fn isPending(entry: Index.Unit) bool {
    return entry.state == .missing and entry.files.len == 0 and entry.src_hash == 0;
}

/// Records `plan` as pending unless the index has an entry for it already.
pub fn record(s: *Session, plan: *const pipeline.Plan) !void {
    if (s.ctx.dry_run or !s.deps.backend.caps().translates) return;
    const idx = try s.index(.write);
    if (idx.findUnit(plan.name.full) != null) return;
    try idx.putUnit(s.ctx.gpa, .{
        .name = plan.name.full,
        .scope = s.ctx.scope,
        .tier = plan.tier,
        .state = .missing,
        .src_hash = 0,
        .src_stat = 0,
        .files = &.{},
        .origin = .explicit,
        .generator_version = backend_pkg.interface.version,
    });
    s.markDirty();
}

/// Drops the pending entry of `name`, if there is one.
pub fn forget(s: *Session, name: @import("../unit/root.zig").name.Name) !void {
    if (s.ctx.dry_run or !s.deps.backend.caps().translates) return;
    const idx = try s.index(.write);
    const entry = idx.findUnit(name.full) orelse return;
    if (!isPending(entry.*)) return;
    _ = idx.removeUnit(name.full);
    s.markDirty();
}
