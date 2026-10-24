//! enable, disable, reenable, mask, unmask and revert (§3.1, §9).
const std = @import("std");
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const reconcile = @import("../reconcile/root.zig");
const backend_pkg = @import("../backend/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const units = @import("units.zig");

const Name = unit.name.Name;
const Exit = cli.output.Exit;
const max_also_depth = 8;

pub const Visited = std.StringHashMapUnmanaged(void);

fn enableOptions(s: *Session) backend_pkg.interface.EnableOptions {
    const o = s.req.options;
    if (o.runtime and !s.deps.backend.caps().runtime_dir) {
        s.ctx.diag.warn("--runtime is not supported by the {s} backend, enabling persistently", .{s.deps.backend.name()});
    }
    return .{ .runtime = o.runtime and s.deps.backend.caps().runtime_dir, .global = o.global };
}

/// Shared early outcomes of enable and disable; null means the unit maps to a service.
pub fn earlyOutcome(s: *Session, verb: []const u8, plan: *const pipeline.Plan) !?u8 {
    switch (plan.outcome) {
        .not_found => {
            try cli.output.writeUnitDoesNotExist(s.err(), verb, plan.name.full);
            return Exit.failure;
        },
        .masked => {
            try cli.output.writeUnitMasked(s.err(), verb, plan.fragmentPath() orelse plan.name.full);
            return Exit.failure;
        },
        .unsupported => return s.refuseUnsupported(plan.name.full, plan.class.?.reason),
        .template => {
            s.ctx.diag.err("{s}: template unit without DefaultInstance=, name an instance", .{plan.name.full});
            return Exit.failure;
        },
        .timer => {
            s.ctx.diag.warn("{s}: timer units are not supported yet, nothing done", .{plan.name.full});
            return Exit.success;
        },
        .no_backend => {
            s.reportNoBackend();
            return Exit.failure;
        },
        .conflict => |n| {
            s.ctx.diag.err(
                "{s}: the name is taken by native service '{s}' running another program; map the unit with [Aliases] in the configuration",
                .{ plan.name.full, n.name },
            );
            return Exit.failure;
        },
        .native, .generate => return null,
    }
}

fn stopAfterNow(s: *Session, verb: []const u8, name: []const u8, service: []const u8) u8 {
    if (s.ctx.offline) {
        s.offlineNotice(verb, name);
        return Exit.success;
    }
    const start = std.mem.eql(u8, verb, "start");
    const result = if (start) s.deps.backend.start(s.env(), service) else s.deps.backend.stop(s.env(), service);
    result catch |e| return s.backendFailed(verb, name, e);
    return Exit.success;
}

pub fn enableUnit(s: *Session, name: Name, visited: *Visited, depth: usize) !u8 {
    const gpa = s.ctx.gpa;
    if (visited.contains(name.full)) return Exit.success;
    try visited.put(gpa, name.full, {});
    const plan = try pipeline.prepare(s, name);
    if (try earlyOutcome(s, "enable", &plan)) |code| return code;
    if (!pipeline.hasInstallConfig(plan.unit.?)) {
        try cli.output.writeNoInstallConfig(s.err());
        return Exit.success;
    }
    const service = try pipeline.commit(s, &plan, .explicit);
    const changes = s.deps.backend.enable(s.env(), service, enableOptions(s)) catch |e| return s.backendFailed("enable", name.full, e);
    try s.printChanges(changes);
    var code: u8 = Exit.success;
    if (s.req.options.now) {
        const c = stopAfterNow(s, "start", name.full, service);
        if (c != 0) code = c;
    }
    if (depth < max_also_depth) {
        for (plan.unit.?.also) |also| {
            const also_name = unit.name.parse(gpa, also) catch continue;
            const c = try enableUnit(s, also_name, visited, depth + 1);
            if (c != 0 and code == 0) code = c;
        }
    }
    return code;
}

pub fn disableUnit(s: *Session, name: Name) !u8 {
    const plan = try pipeline.prepare(s, name);
    switch (plan.outcome) {
        .masked, .unsupported, .timer => {
            s.ctx.diag.info("{s}: nothing to disable", .{name.full});
            return Exit.success;
        },
        else => {},
    }
    if (try earlyOutcome(s, "disable", &plan)) |code| return code;
    const service = plan.service().?;
    if (plan.outcome == .generate and !pipeline.hasInstallConfig(plan.unit.?)) {
        try cli.output.writeNoInstallConfig(s.err());
        return Exit.success;
    }
    const changes = s.deps.backend.disable(s.env(), service, enableOptions(s)) catch |e| return s.backendFailed("disable", name.full, e);
    try s.printChanges(changes);
    if (s.req.options.now) return stopAfterNow(s, "stop", name.full, service);
    return Exit.success;
}

pub fn enable(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var visited: Visited = .empty;
    var agg: units.Aggregate = .{};
    for (names) |n| agg.note(try enableUnit(s, n, &visited, 0));
    return agg.code;
}

pub fn disable(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names) |n| agg.note(try disableUnit(s, n));
    return agg.code;
}

pub fn reenable(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var visited: Visited = .empty;
    var agg: units.Aggregate = .{};
    for (names) |n| {
        agg.note(try disableUnit(s, n));
        agg.note(try enableUnit(s, n, &visited, 0));
    }
    return agg.code;
}

const dev_null = "/dev/null";
const system_admin_dir = "/etc/systemd/system";
const system_runtime_dir = "/run/systemd/system";

pub fn adminDir(s: *Session, runtime: bool) ![]const u8 {
    return switch (s.ctx.scope) {
        .system => if (runtime) system_runtime_dir else system_admin_dir,
        .user => try std.fs.path.join(s.ctx.gpa, &.{ if (runtime) s.ctx.xdg_runtime_dir else s.ctx.xdg_config_home, "systemd/user" }),
    };
}

fn isMaskLink(s: *Session, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const st = s.ctx.fs.lstat(path) catch return false;
    switch (st.kind) {
        .sym_link => {
            const target = s.ctx.fs.readLink(path, &buf) catch return false;
            return std.mem.eql(u8, target, dev_null);
        },
        .file => return st.size == 0,
        else => return false,
    }
}

fn removePath(s: *Session, path: []const u8) !void {
    if (s.ctx.dry_run) return s.out().print("would remove '{s}'\n", .{path});
    try s.ctx.fs.deleteTree(path);
    if (!s.quiet()) try cli.output.writeRemoved(s.err(), path);
}

fn stopAndDisableForMask(s: *Session, name: Name) !void {
    const plan = try pipeline.prepare(s, name);
    const service = plan.service() orelse return;
    const env = s.env();
    if (!s.ctx.offline) {
        const st = s.deps.backend.status(env, service) catch return;
        if (st.state == .active or st.state == .activating) {
            s.deps.backend.stop(env, service) catch |e| s.ctx.diag.warn("{s}: stop failed: {t}", .{ name.full, e });
        }
    }
    const enabled = s.deps.backend.isEnabled(env, service) catch return;
    if (enabled == .enabled or enabled == .enabled_runtime) {
        const changes = s.deps.backend.disable(env, service, .{}) catch |e| {
            s.ctx.diag.warn("{s}: disable failed: {t}", .{ name.full, e });
            return;
        };
        try s.printChanges(changes);
    }
}

fn maskUnit(s: *Session, name: Name) !u8 {
    const dir = try adminDir(s, s.req.options.runtime);
    const path = try std.fs.path.join(s.ctx.gpa, &.{ dir, name.full });
    if (s.ctx.fs.lstat(path)) |_| {
        if (isMaskLink(s, path)) return Exit.success;
        s.ctx.diag.err("Failed to mask unit: File {s} already exists", .{path});
        return Exit.failure;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    if (s.deps.backend.caps().translates) try stopAndDisableForMask(s, name);
    const change: backend_pkg.interface.Change = .{ .created = .{ .link = path, .target = dev_null } };
    if (!s.ctx.dry_run) {
        try s.ctx.fs.makePath(dir);
        try s.ctx.fs.symLink(dev_null, path);
    }
    try s.printChanges(&.{change});
    return Exit.success;
}

fn unmaskUnit(s: *Session, name: Name) !u8 {
    const gpa = s.ctx.gpa;
    for ([_]bool{ false, true }) |runtime| {
        const path = try std.fs.path.join(gpa, &.{ try adminDir(s, runtime), name.full });
        if (isMaskLink(s, path)) try removePath(s, path);
    }
    return Exit.success;
}

fn runMaskVerb(s: *Session, one: anytype) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names) |n| agg.note(try one(s, n));
    return agg.code;
}

pub fn mask(s: *Session) !u8 {
    return runMaskVerb(s, maskUnit);
}

pub fn unmask(s: *Session) !u8 {
    return runMaskVerb(s, unmaskUnit);
}

fn revertGenerated(s: *Session, name: Name) !void {
    const idx = try s.index(.write);
    const entry = idx.findUnit(name.full) orelse return;
    const files = entry.files;
    if (entry.state != .native and s.deps.backend.caps().translates and files.len > 0) {
        const service = std.fs.path.basename(files[0].path);
        const changes = s.deps.backend.disable(s.env(), service, .{}) catch |e| blk: {
            s.ctx.diag.warn("{s}: disable failed: {t}", .{ name.full, e });
            break :blk &.{};
        };
        try s.printChanges(changes);
    }
    var env = s.applyEnv(.explicit);
    const out = try reconcile.apply.dropUnit(&env, idx, s.ctx.gpa, name.full);
    s.markDirty();
    if (s.ctx.dry_run or s.quiet()) return;
    if (out.actions.len != files.len) return;
    for (files, out.actions) |f, action| {
        if (action == .remove) try cli.output.writeRemoved(s.err(), f.path);
    }
}

fn revertOverrides(s: *Session, name: Name) !void {
    const gpa = s.ctx.gpa;
    for ([_]bool{ false, true }) |runtime| {
        const dir = try adminDir(s, runtime);
        const dropin = try std.fmt.allocPrint(gpa, "{s}/{s}.d", .{ dir, name.full });
        if (s.ctx.fs.exists(dropin)) {
            const entries = try s.ctx.fs.iterateDir(gpa, dropin);
            for (entries) |e| try removePath(s, try std.fs.path.join(gpa, &.{ dropin, e.name }));
            try removePath(s, dropin);
        }
        const fragment = try std.fs.path.join(gpa, &.{ dir, name.full });
        if (isMaskLink(s, fragment)) {
            try removePath(s, fragment);
        } else if (!runtime and overridesVendorFragment(s, fragment, name)) {
            try removePath(s, fragment);
        }
    }
}

fn overridesVendorFragment(s: *Session, fragment: []const u8, name: Name) bool {
    const st = s.ctx.fs.lstat(fragment) catch return false;
    if (st.kind != .file) return false;
    const dirs = unit.resolve.searchDirs(s.ctx.gpa, s.resolveOptions()) catch return false;
    for (dirs) |d| {
        if (d.tier == .admin or d.tier == .personal) continue;
        const other = std.fs.path.join(s.ctx.gpa, &.{ d.path, name.full }) catch return false;
        if (s.ctx.fs.exists(other)) return true;
    }
    return false;
}

fn revertUnit(s: *Session, name: Name) !u8 {
    try revertGenerated(s, name);
    try revertOverrides(s, name);
    return Exit.success;
}

pub fn revert(s: *Session) !u8 {
    return runMaskVerb(s, revertUnit);
}
