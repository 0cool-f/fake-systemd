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

const Exit = cli.output.Exit;
const Index = index_pkg.Index;

fn drop(s: *Session, idx: *Index, name: []const u8) !void {
    var env = s.applyEnv(.daemon_reload);
    _ = try reconcile.apply.dropUnit(&env, idx, s.ctx.gpa, name);
    s.markDirty();
}

fn syncEntry(s: *Session, idx: *Index, entry: Index.Unit) !void {
    const gpa = s.ctx.gpa;
    const name = unit.name.parse(gpa, entry.name) catch {
        s.ctx.diag.warn("index entry '{s}' is not a valid unit name, skipped", .{entry.name});
        return;
    };
    const resolved = unit.resolve.resolve(gpa, s.ctx.fs.*, s.resolveOptions(), name) catch |e| {
        s.ctx.diag.warn("{s}: cannot resolve unit: {t}", .{ entry.name, e });
        return;
    };
    switch (try pipeline.fastCheck(s, entry, resolved)) {
        .unchanged => return,
        .refresh => |fingerprint| {
            if (s.ctx.dry_run) return;
            var updated = entry;
            updated.src_stat = fingerprint;
            try idx.putUnit(gpa, updated);
            s.markDirty();
            return;
        },
        .full => {},
    }
    const plan = pipeline.prepareResolved(s, name, resolved) catch |e| {
        s.ctx.diag.warn("{s}: cannot load unit: {t}", .{ entry.name, e });
        return;
    };
    switch (plan.outcome) {
        .not_found, .unsupported => try drop(s, idx, entry.name),
        .masked, .timer, .template, .no_backend => {},
        .conflict => |n| s.ctx.diag.warn("{s}: the name is taken by native service '{s}'", .{ entry.name, n.name }),
        .native => |n| if (entry.state != .native) try pipeline.adoptNative(s, &plan, n),
        .generate => |g| {
            if (entry.state == .native) {
                if (!s.ctx.dry_run) {
                    _ = idx.removeUnit(entry.name);
                    s.markDirty();
                }
                return;
            }
            var env = s.applyEnv(.daemon_reload);
            _ = try reconcile.apply.syncUnit(&env, idx, gpa, .{
                .name = entry.name,
                .scope = s.ctx.scope,
                .tier = plan.tier,
                .src_hash = plan.src_hash,
                .src_stat = plan.src_stat,
                .generator_version = backend_pkg.interface.version,
                .files = g.generated.files,
            });
            pipeline.reportIssues(s, plan.unit.?);
            s.markDirty();
        },
    }
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

pub fn run(s: *Session) !u8 {
    if (s.deps.backend.caps().translates) {
        const idx = try s.index(.write);
        const entries = try s.ctx.gpa.dupe(Index.Unit, idx.units.items);
        for (entries) |e| try syncEntry(s, idx, e);
        if (s.ctx.config.translate == .eager) try translateAll(s, idx);
    }
    if (s.ctx.offline) return Exit.success;
    s.deps.backend.reloadManager(s.env()) catch |e| return s.backendFailed("reload", "the init manager", e);
    return Exit.success;
}
