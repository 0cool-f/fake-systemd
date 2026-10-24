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
    plan.src_stat = index_pkg.hash.statFingerprint(s.ctx.fs.*, paths, resolved.dropin_dirs);
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

/// Writes the generated files and records the unit; returns the backend service name.
/// Valid for `.generate` and `.native` outcomes.
pub fn commit(s: *Session, plan: *const Plan, verb: reconcile.plan.Verb) ![]const u8 {
    switch (plan.outcome) {
        .generate => |g| {
            const idx = try s.index(.write);
            reportIssues(s, plan.unit.?);
            var env = s.applyEnv(verb);
            _ = try reconcile.apply.syncUnit(&env, idx, s.ctx.gpa, .{
                .name = plan.name.full,
                .scope = s.ctx.scope,
                .tier = plan.tier,
                .src_hash = plan.src_hash,
                .src_stat = plan.src_stat,
                .generator_version = backend_pkg.interface.version,
                .files = g.generated.files,
            });
            s.markDirty();
            return g.generated.service_name;
        },
        .native => |n| {
            try adoptNative(s, plan, n);
            return n.name;
        },
        else => unreachable,
    }
}

/// Records that `plan` is served by a native service, removing generated files of the unit.
pub fn adoptNative(s: *Session, plan: *const Plan, n: interface.NativeService) !void {
    const idx = try s.index(.write);
    const existing = idx.findUnit(plan.name.full);
    if (existing != null and existing.?.state == .native) return;
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
        .files = &.{},
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
/// hashed only when their fingerprint differs.
pub fn fastCheck(s: *Session, entry: index_pkg.Index.Unit, resolved: resolve.Resolved) !Fast {
    if (entry.state != .managed or resolved.state != .found or entry.files.len == 0) return .full;
    _ = try s.nativeServices();
    if (s.generator_changed or s.natives_changed) return .full;
    if (!std.mem.eql(u8, entry.generator_version, backend_pkg.interface.version)) return .full;
    const fs = s.ctx.fs.*;
    for (entry.files) |f| {
        const fp = index_pkg.hash.fileFingerprint(fs, f.path);
        if (fp == 0 or fp != f.stat) return .full;
    }
    const paths = try filePaths(s.ctx.gpa, resolved);
    const fingerprint = index_pkg.hash.statFingerprint(fs, paths, resolved.dropin_dirs);
    if (fingerprint == entry.src_stat) return .unchanged;
    if (try index_pkg.hash.unitSetHash(fs, s.ctx.gpa, paths) == entry.src_hash) return .{ .refresh = fingerprint };
    return .full;
}
