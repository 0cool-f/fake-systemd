//! Translation pipeline for one unit (§6): resolve, model, classify, native lookup, generate.
//! `prepare` is read-only; `commit` writes the generated files and the index entry.
const std = @import("std");
const core = @import("../core/root.zig");
const unit = @import("../unit/root.zig");
const index_pkg = @import("../index/root.zig");
const reconcile = @import("../reconcile/root.zig");
const backend_pkg = @import("../backend/root.zig");
const native = @import("native.zig");
const Session = @import("session.zig");

const model = unit.model;
const classify = unit.classify;
const resolve = unit.resolve;
const Name = unit.name.Name;
const interface = backend_pkg.interface;

pub const Gen = struct {
    generated: interface.Generated,
};

pub const Outcome = union(enum) {
    not_found,
    masked,
    /// Excluded by the classifier; `Plan.class` holds the rule.
    unsupported,
    /// A template name without `DefaultInstance=`.
    template,
    /// `.timer` units belong to the timer subsystem.
    timer,
    /// The backend cannot translate units.
    no_backend,
    native: interface.NativeService,
    generate: Gen,
    /// The name is taken by a native service running another program.
    conflict: interface.NativeService,
};

pub const Plan = struct {
    name: Name,
    resolved: resolve.Resolved,
    unit: ?model.Unit = null,
    class: ?classify.Classification = null,
    tier: core.Tier = .admin,
    src_hash: u64 = 0,
    src_stat: u64 = 0,
    executables: []const index_pkg.Index.Exec = &.{},
    outcome: Outcome,

    pub fn fragmentPath(p: Plan) ?[]const u8 {
        return if (p.resolved.fragment) |f| f.path else null;
    }

    /// Name of the service in the backend, when the unit maps to one.
    pub fn service(p: Plan) ?[]const u8 {
        return switch (p.outcome) {
            .native => |n| n.name,
            .generate => |g| g.generated.service_name,
            else => null,
        };
    }
};

fn exeExists(ptr: ?*const anyopaque, path: []const u8) bool {
    const s: *Session = @ptrCast(@alignCast(@constCast(ptr.?)));
    const st = s.ctx.fs.stat(path) catch return false;
    return st.kind == .file and st.mode & 0o111 != 0;
}

fn timerTriggered(ptr: ?*const anyopaque, name: []const u8) bool {
    const s: *Session = @ptrCast(@alignCast(@constCast(ptr.?)));
    const act = activators(s) catch return false;
    return act.timer_targets.contains(name);
}

fn otherActivator(ptr: ?*const anyopaque, name: []const u8) bool {
    const s: *Session = @ptrCast(@alignCast(@constCast(ptr.?)));
    const act = activators(s) catch return false;
    return act.other_targets.contains(name);
}

pub fn facts(s: *Session) classify.Facts {
    return .{
        .context = s,
        .executable_exists = exeExists,
        .is_timer_triggered = timerTriggered,
        .has_socket_or_path_activator = otherActivator,
        .backend_has_shutdown_hooks = s.deps.backend.caps().shutdown_hooks,
        .allow = s.ctx.config.allow,
        .deny = s.ctx.config.deny,
    };
}

const Activator = struct { suffix: []const u8, section: []const u8, key: []const u8, timer: bool };

const activator_kinds = [_]Activator{
    .{ .suffix = ".timer", .section = "Timer", .key = "Unit", .timer = true },
    .{ .suffix = ".socket", .section = "Socket", .key = "Service", .timer = false },
    .{ .suffix = ".path", .section = "Path", .key = "Unit", .timer = false },
};

fn activators(s: *Session) !*Session.Activators {
    if (s.activators != null) return &s.activators.?;
    s.activators = .{};
    const gpa = s.ctx.gpa;
    const dirs = try resolve.searchDirs(gpa, s.resolveOptions());
    for (dirs) |dir| {
        const entries = s.ctx.fs.iterateDir(gpa, dir.path) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        for (entries) |entry| {
            for (activator_kinds) |kind| {
                if (!std.mem.endsWith(u8, entry.name, kind.suffix)) continue;
                try recordActivator(s, kind, try std.fs.path.join(gpa, &.{ dir.path, entry.name }), entry.name);
            }
        }
    }
    return &s.activators.?;
}

fn recordActivator(s: *Session, kind: Activator, path: []const u8, file_name: []const u8) !void {
    const gpa = s.ctx.gpa;
    const act = &s.activators.?;
    const target_map = if (kind.timer) &act.timer_targets else &act.other_targets;
    const stem = file_name[0 .. file_name.len - kind.suffix.len];
    try target_map.put(gpa, try std.fmt.allocPrint(gpa, "{s}.service", .{stem}), {});
    const content = s.ctx.fs.readFileAlloc(gpa, path, resolve.max_unit_file_size) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return,
    };
    var doc: unit.ini.Document = .empty;
    try unit.ini.parse(gpa, &doc, content, 0);
    for (doc.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.section, kind.section) or !std.mem.eql(u8, entry.key, kind.key)) continue;
        if (entry.value.len > 0) try target_map.put(gpa, entry.value, {});
    }
}

fn readTrimmed(s: *Session, path: []const u8) ?[]const u8 {
    const content = s.ctx.fs.readFileAlloc(s.ctx.gpa, path, 4096) catch return null;
    const t = std.mem.trim(u8, content, " \t\r\n");
    return if (t.len == 0) null else t;
}

fn specifierEnv(s: *Session) !unit.specifier.Env {
    if (s.spec_env) |e| return e;
    const ctx = s.ctx;
    const user: unit.specifier.UserInfo = .{
        .name = ctx.getEnv("USER") orelse if (ctx.uid == 0) "root" else "user",
        .uid = ctx.uid,
        .home = ctx.home,
    };
    var e: unit.specifier.Env = switch (ctx.scope) {
        .system => .system(user),
        .user => try .userScope(ctx.gpa, user, .{
            .runtime = ctx.xdg_runtime_dir,
            .state = ctx.xdg_state_home,
            .cache = ctx.xdg_cache_home,
            .config = ctx.xdg_config_home,
        }),
    };
    e.hostname = readTrimmed(s, "/etc/hostname");
    e.machine_id = readTrimmed(s, "/etc/machine-id");
    s.spec_env = e;
    return e;
}

/// First `ExecStart=` executable, made absolute and normalized.
fn unitExecutable(s: *Session, u: model.Unit) !?[]const u8 {
    if (u.exec_start.len == 0) return null;
    const words = u.exec_start[0].words;
    if (words.len == 0) return null;
    var buf = try s.ctx.gpa.dupe([]const u8, words);
    if (words[0].len > 0 and words[0][0] != '/' and std.mem.findScalar(u8, words[0], '/') == null) {
        for ([_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" }) |dir| {
            const path = try std.fs.path.join(s.ctx.gpa, &.{ dir, words[0] });
            if (s.ctx.fs.exists(path)) {
                buf[0] = path;
                break;
            }
        }
    }
    return backend_pkg.exec_norm.normalizedExecutable(s.ctx.fs.*, s.ctx.gpa, buf);
}

/// Paths that decide whether `name` resolves to an executable, as the classifier probes them:
/// the path itself, or one per search directory for a bare name; empty for anything else.
fn execCandidates(gpa: std.mem.Allocator, name: []const u8) ![]const []const u8 {
    if (name.len == 0 or name[0] == '$') return &.{};
    if (name[0] == '/') return gpa.dupe([]const u8, &.{name});
    if (std.mem.findScalar(u8, name, '/') != null) return &.{};
    const paths = try gpa.alloc([]const u8, classify.exec_search_dirs.len);
    for (classify.exec_search_dirs, paths) |dir, *p| p.* = try std.fs.path.join(gpa, &.{ dir, name });
    return paths;
}

fn execEntry(gpa: std.mem.Allocator, fs: core.Fs, name: []const u8) !index_pkg.Index.Exec {
    return .{ .name = name, .stat = index_pkg.hash.executableStat(fs, try execCandidates(gpa, name)) };
}

/// Every distinct executable named by an `Exec*=` line, with the stat hash of its candidate paths.
fn unitExecutables(gpa: std.mem.Allocator, fs: core.Fs, u: model.Unit) ![]const index_pkg.Index.Exec {
    var list: std.ArrayList(index_pkg.Index.Exec) = .empty;
    const groups = [_][]const model.Command{ u.exec_start_pre, u.exec_start, u.exec_start_post, u.exec_reload, u.exec_stop, u.exec_stop_post };
    for (groups) |commands| for (commands) |cmd| {
        if (cmd.words.len == 0) continue;
        const name = cmd.executable();
        if ((try execCandidates(gpa, name)).len == 0) continue;
        const seen = for (list.items) |e| {
            if (std.mem.eql(u8, e.name, name)) break true;
        } else false;
        if (!seen) try list.append(gpa, try execEntry(gpa, fs, name));
    };
    return list.items;
}

fn executableStats(gpa: std.mem.Allocator, executables: []const index_pkg.Index.Exec) ![]const u64 {
    const stats = try gpa.alloc(u64, executables.len);
    for (executables, stats) |e, *st| st.* = e.stat;
    return stats;
}

fn filePaths(gpa: std.mem.Allocator, resolved: resolve.Resolved) ![]const []const u8 {
    const paths = try gpa.alloc([]const u8, resolved.files.len);
    for (resolved.files, paths) |f, *p| p.* = f.path;
    return paths;
}

pub fn prepare(s: *Session, name: Name) !Plan {
    const resolved = try resolve.resolve(s.ctx.gpa, s.ctx.fs.*, s.resolveOptions(), name);
    return prepareResolved(s, name, resolved);
}

pub fn prepareResolved(s: *Session, name: Name, resolved: resolve.Resolved) !Plan {
    const gpa = s.ctx.gpa;
    var plan: Plan = .{ .name = name, .resolved = resolved, .outcome = .not_found };
    switch (resolved.state) {
        .not_found => return plan,
        .masked => {
            plan.outcome = .masked;
            return plan;
        },
        .found => {},
    }
    plan.tier = resolved.tier() orelse .admin;
    const u = try model.load(gpa, s.ctx.fs.*, resolved, .{ .env = try specifierEnv(s) });
    plan.unit = u;
    const class = classify.classify(u, facts(s));
    plan.class = class;

    if (class.kind == .unsupported or class.kind == .activation_only) {
        plan.outcome = .unsupported;
        return plan;
    }
    if (name.kind == .timer) {
        plan.outcome = .timer;
        return plan;
    }
    if (name.isTemplate()) {
        if (u.default_instance) |inst| {
            const inst_name = try std.fmt.allocPrint(gpa, "{s}@{s}.{s}", .{ name.prefix, inst, name.kind.suffix() });
            return prepare(s, try unit.name.parse(gpa, inst_name));
        }
        plan.outcome = .template;
        return plan;
    }
    if (!s.deps.backend.caps().translates) {
        plan.outcome = .no_backend;
        return plan;
    }

    const paths = try filePaths(gpa, resolved);
    plan.src_hash = try index_pkg.hash.unitSetHash(s.ctx.fs.*, gpa, paths);
    plan.executables = try unitExecutables(gpa, s.ctx.fs.*, u);
    plan.src_stat = index_pkg.hash.statFingerprint(s.ctx.fs.*, paths, resolved.dropin_dirs, try executableStats(gpa, plan.executables));
    const unit_ptr = try gpa.create(model.Unit);
    unit_ptr.* = u;
    const generated = try s.deps.backend.generate(gpa, .{
        .unit = unit_ptr,
        .tier = plan.tier,
        .source = resolved.fragment.?.path,
        .src_hash = plan.src_hash,
    });
    const natives = try s.nativeServices();
    const decision = try native.decide(gpa, s.ctx.config, natives, u, try unitExecutable(s, u), generated.service_name);
    plan.outcome = switch (decision) {
        .native => |n| .{ .native = n },
        .conflict => |n| .{ .conflict = n },
        .generate => .{ .generate = .{ .generated = generated } },
    };
    return plan;
}

/// True when the unit declares something `enable` can act on.
pub fn hasInstallConfig(u: model.Unit) bool {
    return u.has_install and (u.wanted_by.len + u.required_by.len + u.also.len + u.alias.len > 0 or u.default_instance != null);
}

pub fn reportIssues(s: *Session, u: model.Unit) void {
    const diag = s.ctx.diag;
    for (u.issues) |issue| {
        if (issue.kind == .behavior_key) diag.warn("{s}: {s}= is not supported and changes the behavior of the service", .{ u.name.full, issue.key });
    }
    const sandbox = u.countIssues(.sandbox_key);
    if (sandbox > 0) diag.info("{s}: {d} sandboxing directives ignored", .{ u.name.full, sandbox });
    const resources = u.countIssues(.resource_key);
    if (resources > 0) diag.info("{s}: {d} resource control directives ignored", .{ u.name.full, resources });
    const ignored = u.countIssues(.ignored_key) + u.countIssues(.unknown_key) + u.countIssues(.unknown_section);
    if (ignored > 0) diag.info("{s}: {d} unsupported or unknown directives ignored", .{ u.name.full, ignored });
}

pub const Dropped = struct {
    owner: []const u8,
    dep: []const u8,
    reason: []const u8,
};

/// Units a unit pulls in with `Requires=`, `BindsTo=` and `Wants=` that can be services of the
/// backend: other unit types (targets, sockets) are the backend's business.
fn pulledNames(gpa: std.mem.Allocator, u: model.Unit) ![]const Name {
    var out: std.ArrayList(Name) = .empty;
    const lists = [_][]const []const u8{ u.requires, u.binds_to, u.wants };
    for (lists) |list| for (list) |raw| {
        const n = unit.name.parse(gpa, raw) catch continue;
        if (n.kind != .service or std.mem.eql(u8, n.full, u.name.full)) continue;
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o.full, n.full)) break true;
        } else false;
        if (!dup) try out.append(gpa, n);
    };
    return out.items;
}

/// A unit and the dependency units that have to exist for the backend to load it.
pub const Closure = struct {
    /// Dependency plans that are generated or native, transitively, in discovery order.
    members: []const Plan,
    /// How every dependency met on the way resolves in the backend, for `generate`.
    resolved: []const interface.Dep,
    /// Dependencies left out because they cannot be services.
    dropped: []const Dropped,
    /// `owner -> dependency` edges that close a cycle; the backend must not emit them.
    back_edges: []const [2][]const u8,

    fn isBackEdge(c: Closure, owner: []const u8, dep: []const u8) bool {
        for (c.back_edges) |e| if (std.mem.eql(u8, e[0], owner) and std.mem.eql(u8, e[1], dep)) return true;
        return false;
    }

    /// Resolutions as seen from `owner`: cycle edges resolve to nothing.
    pub fn depsFor(c: Closure, gpa: std.mem.Allocator, owner: []const u8) ![]const interface.Dep {
        const out = try gpa.dupe(interface.Dep, c.resolved);
        for (out) |*d| if (c.isBackEdge(owner, d.unit)) {
            d.service = null;
        };
        return out;
    }
};

fn serviceOf(plan: Plan) ?[]const u8 {
    return plan.service();
}

fn unitPlan(plans: []const Plan, root: *const Plan, name: []const u8) ?*const Plan {
    if (std.mem.eql(u8, root.name.full, name)) return root;
    for (plans) |*p| if (std.mem.eql(u8, p.name.full, name)) return p;
    return null;
}

const DfsState = struct {
    gpa: std.mem.Allocator,
    root: *const Plan,
    members: []const Plan,
    on_stack: std.StringHashMapUnmanaged(void) = .empty,
    done: std.StringHashMapUnmanaged(void) = .empty,
    edges: std.ArrayList([2][]const u8) = .empty,

    fn visit(d: *DfsState, plan: *const Plan) !void {
        const name = plan.name.full;
        try d.on_stack.put(d.gpa, name, {});
        if (plan.unit) |u| {
            for (try pulledNames(d.gpa, u)) |n| {
                const dep = unitPlan(d.members, d.root, n.full) orelse continue;
                if (serviceOf(dep.*) == null) continue;
                if (d.on_stack.contains(dep.name.full)) {
                    try d.edges.append(d.gpa, .{ name, n.full });
                } else if (!d.done.contains(dep.name.full)) {
                    try d.visit(dep);
                }
            }
        }
        _ = d.on_stack.remove(name);
        try d.done.put(d.gpa, name, {});
    }
};

/// Prepares every unit `root` pulls in, recursively. Each dependency goes through the whole
/// pipeline (classification, native lookup, generation); one that is excluded or cannot be
/// loaded is recorded in `dropped`.
pub fn collectClosure(s: *Session, root: *const Plan) !Closure {
    const gpa = s.ctx.gpa;
    var members: std.ArrayList(Plan) = .empty;
    var resolved: std.ArrayList(interface.Dep) = .empty;
    var dropped: std.ArrayList(Dropped) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(gpa, root.name.full, {});
    try resolved.append(gpa, .{ .unit = root.name.full, .service = root.service() });

    const Item = struct { owner: []const u8, name: Name };
    var queue: std.ArrayList(Item) = .empty;
    for (try pulledNames(gpa, root.unit.?)) |n| try queue.append(gpa, .{ .owner = root.name.full, .name = n });
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const item = queue.items[i];
        if (seen.contains(item.name.full)) continue;
        try seen.put(gpa, item.name.full, {});
        const dep = prepare(s, item.name) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try resolved.append(gpa, .{ .unit = item.name.full, .service = null });
                try dropped.append(gpa, .{ .owner = item.owner, .dep = item.name.full, .reason = try std.fmt.allocPrint(gpa, "cannot load unit: {t}", .{e}) });
                continue;
            },
        };
        if (dep.service()) |svc| {
            try resolved.append(gpa, .{ .unit = item.name.full, .service = svc });
            try members.append(gpa, dep);
            if (dep.outcome == .generate) {
                for (try pulledNames(gpa, dep.unit.?)) |n| try queue.append(gpa, .{ .owner = dep.name.full, .name = n });
            }
        } else {
            try resolved.append(gpa, .{ .unit = item.name.full, .service = null });
            try dropped.append(gpa, .{ .owner = item.owner, .dep = item.name.full, .reason = dropReason(dep) });
        }
    }

    var dfs: DfsState = .{ .gpa = gpa, .root = root, .members = members.items };
    try dfs.visit(root);
    return .{ .members = members.items, .resolved = resolved.items, .dropped = dropped.items, .back_edges = dfs.edges.items };
}

fn dropReason(plan: Plan) []const u8 {
    return switch (plan.outcome) {
        .not_found => "unit not found",
        .masked => "unit is masked",
        .unsupported => if (plan.class) |c| c.reason else "unit is not translated",
        .template => "template unit without DefaultInstance=",
        .timer => "timer units are not services",
        .no_backend => "the backend cannot translate units",
        .conflict => "the name is taken by a native service running another program",
        .native, .generate => unreachable,
    };
}

fn regenerate(s: *Session, plan: *const Plan, deps: []const interface.Dep) !interface.Generated {
    const gpa = s.ctx.gpa;
    const unit_ptr = try gpa.create(model.Unit);
    unit_ptr.* = plan.unit.?;
    return s.deps.backend.generate(gpa, .{
        .unit = unit_ptr,
        .tier = plan.tier,
        .source = plan.resolved.fragment.?.path,
        .src_hash = plan.src_hash,
        .deps = deps,
    });
}

/// Direct dependencies of `plan` that are recorded in the index as units of their own.
fn directDeps(s: *Session, plan: *const Plan, closure: Closure) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try pulledNames(s.ctx.gpa, plan.unit.?)) |n| {
        const dep = unitPlan(closure.members, plan, n.full) orelse continue;
        if (dep.service() != null) try out.append(s.ctx.gpa, dep.name.full);
    }
    return out.items;
}

fn effectiveOrigin(idx: *index_pkg.Index, name: []const u8, wanted: index_pkg.Index.Origin) index_pkg.Index.Origin {
    if (wanted == .explicit) return .explicit;
    if (idx.findUnit(name)) |e| return e.origin;
    return .dependency;
}

pub const Members = enum {
    /// Reconcile every dependency unit again.
    all,
    /// Translate only those not in the index yet.
    missing,
};

/// Writes the generated files of `plan` and of the dependency units it needs, and records them
/// with their origin. Returns the backend service name of `plan`.
pub fn syncPlan(s: *Session, plan: *const Plan, verb: reconcile.plan.Verb, origin: index_pkg.Index.Origin, members: Members) ![]const u8 {
    const idx = try s.index(.write);
    const gpa = s.ctx.gpa;
    const caps = s.deps.backend.caps();
    var closure: Closure = .{ .members = &.{}, .resolved = &.{}, .dropped = &.{}, .back_edges = &.{} };
    if (plan.outcome == .generate and (caps.hard_deps or caps.soft_deps)) {
        closure = try collectClosure(s, plan);
        for (closure.dropped) |d| s.ctx.diag.info("{s}: dependency {s} dropped: {s}", .{ d.owner, d.dep, d.reason });
        for (closure.back_edges) |e| s.ctx.diag.info("{s}: dependency {s} dropped: dependency cycle", .{ e[0], e[1] });
    }
    for (closure.members) |*m| {
        if (members == .missing and idx.findUnit(m.name.full) != null) continue;
        try syncMember(s, idx, m, if (members == .missing) .explicit else verb, closure);
    }
    switch (plan.outcome) {
        .generate => |g| {
            const generated = if (caps.hard_deps or caps.soft_deps)
                try regenerate(s, plan, try closure.depsFor(gpa, plan.name.full))
            else
                g.generated;
            try syncGenerated(s, idx, plan, generated, verb, effectiveOrigin(idx, plan.name.full, origin), try directDeps(s, plan, closure));
            return generated.service_name;
        },
        .native => |n| {
            try adoptNative(s, plan, n, origin);
            return n.name;
        },
        else => unreachable,
    }
}

fn syncMember(s: *Session, idx: *index_pkg.Index, m: *const Plan, verb: reconcile.plan.Verb, closure: Closure) !void {
    switch (m.outcome) {
        .generate => {
            const generated = try regenerate(s, m, try closure.depsFor(s.ctx.gpa, m.name.full));
            try syncGenerated(s, idx, m, generated, verb, effectiveOrigin(idx, m.name.full, .dependency), try directDeps(s, m, closure));
        },
        .native => |n| try adoptNative(s, m, n, .dependency),
        else => unreachable,
    }
}

fn syncGenerated(
    s: *Session,
    idx: *index_pkg.Index,
    plan: *const Plan,
    generated: interface.Generated,
    verb: reconcile.plan.Verb,
    origin: index_pkg.Index.Origin,
    deps: []const []const u8,
) !void {
    reportIssues(s, plan.unit.?);
    var env = s.applyEnv(verb);
    _ = try reconcile.apply.syncUnit(&env, idx, s.ctx.gpa, .{
        .name = plan.name.full,
        .scope = s.ctx.scope,
        .tier = plan.tier,
        .src_hash = plan.src_hash,
        .src_stat = plan.src_stat,
        .executables = plan.executables,
        .generator_version = backend_pkg.interface.version,
        .files = generated.files,
        .origin = origin,
        .deps = deps,
    });
    s.markDirty();
}

/// Writes the generated files and records the unit as named by the user, together with the
/// dependency units it needs; returns the backend service name. Valid for `.generate` and
/// `.native` outcomes.
pub fn commit(s: *Session, plan: *const Plan, verb: reconcile.plan.Verb) ![]const u8 {
    return syncPlan(s, plan, verb, .explicit, .all);
}

/// Removes the dependency units that no explicit unit reaches through `deps` any more.
pub fn collectDependencies(s: *Session, idx: *index_pkg.Index, verb: reconcile.plan.Verb) !void {
    const gpa = s.ctx.gpa;
    var marked: std.StringHashMapUnmanaged(void) = .empty;
    var work: std.ArrayList([]const u8) = .empty;
    for (idx.units.items) |u| if (u.origin == .explicit) {
        try marked.put(gpa, u.name, {});
        try work.append(gpa, u.name);
    };
    while (work.pop()) |name| {
        const u = idx.findUnit(name) orelse continue;
        for (u.deps) |d| {
            if (marked.contains(d)) continue;
            try marked.put(gpa, d, {});
            try work.append(gpa, d);
        }
    }
    const snapshot = try gpa.dupe(index_pkg.Index.Unit, idx.units.items);
    for (snapshot) |u| {
        if (u.origin != .dependency or marked.contains(u.name)) continue;
        var env = s.applyEnv(verb);
        _ = try reconcile.apply.dropUnit(&env, idx, gpa, u.name);
        s.markDirty();
    }
}

/// Records that `plan` is served by a native service, removing generated files of the unit.
pub fn adoptNative(s: *Session, plan: *const Plan, n: interface.NativeService, origin: index_pkg.Index.Origin) !void {
    const idx = try s.index(.write);
    const existing = idx.findUnit(plan.name.full);
    if (existing != null and existing.?.state == .native) {
        if (origin == .explicit and existing.?.origin == .dependency and !s.ctx.dry_run) {
            existing.?.origin = .explicit;
            s.markDirty();
        }
        return;
    }
    s.ctx.diag.notice("{s}: using native service '{s}' ({s}) instead of generating one", .{ plan.name.full, n.name, n.path });
    if (s.ctx.dry_run) return;
    var env = s.applyEnv(.explicit);
    if (existing != null) _ = try reconcile.apply.dropUnit(&env, idx, s.ctx.gpa, plan.name.full);
    try idx.putUnit(s.ctx.gpa, .{
        .name = plan.name.full,
        .scope = s.ctx.scope,
        .tier = plan.tier,
        .state = .native,
        .src_hash = plan.src_hash,
        .src_stat = plan.src_stat,
        .executables = plan.executables,
        .files = &.{},
        .origin = if (existing) |e| (if (origin == .explicit) .explicit else e.origin) else origin,
        .generator_version = backend_pkg.interface.version,
    });
    s.markDirty();
}

pub const Fast = union(enum) {
    /// Sources, generated files and native services are as recorded: nothing to do.
    unchanged,
    /// Only the source fingerprint moved; store this one.
    refresh: u64,
    /// The unit has to go through the full pipeline.
    full,
};

/// Stat fast path of §7.3 for a managed entry whose unit resolved to `resolved`. The sources are
/// hashed only when their fingerprint differs. An entry whose dependency changed in this run, or
/// left the index, goes through the full pipeline.
pub fn fastCheck(s: *Session, entry: index_pkg.Index.Unit, resolved: resolve.Resolved) !Fast {
    if (entry.state != .managed or resolved.state != .found or entry.files.len == 0) return .full;
    _ = try s.nativeServices();
    if (s.generator_changed or s.natives_changed or s.config_changed) return .full;
    if (!std.mem.eql(u8, entry.generator_version, backend_pkg.interface.version)) return .full;
    const idx = try s.index(.read);
    for (entry.deps) |d| if (s.changed.contains(d) or idx.findUnit(d) == null) return .full;
    const fs = s.ctx.fs.*;
    for (entry.files) |f| {
        const fp = index_pkg.hash.fileFingerprint(fs, f.path);
        if (fp == 0 or fp != f.stat) return .full;
    }
    const stats = try s.ctx.gpa.alloc(u64, entry.executables.len);
    for (entry.executables, stats) |e, *st| {
        st.* = (try execEntry(s.ctx.gpa, fs, e.name)).stat;
        if (st.* != e.stat) return .full;
    }
    const paths = try filePaths(s.ctx.gpa, resolved);
    const fingerprint = index_pkg.hash.statFingerprint(fs, paths, resolved.dropin_dirs, stats);
    if (fingerprint == entry.src_stat) return .unchanged;
    if (try index_pkg.hash.unitSetHash(fs, s.ctx.gpa, paths) == entry.src_hash) return .{ .refresh = fingerprint };
    return .full;
}
