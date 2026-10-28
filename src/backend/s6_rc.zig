// SPDX-License-Identifier: GPL-3.0-or-later
//! s6-rc backend (§11.2). A unit becomes an s6-rc source directory: a longrun `foo-srv` whose
//! output feeds the logger longrun `foo-log` of a pipeline named `foo`, or a oneshot `foo` with
//! `up` and `down` in execline. Dependencies go to `dependencies`; s6-rc has one kind of them,
//! so `Wants=` is expressed like `Requires=`.
//!
//! The sources reach the boot database in one of two ways. With the s6 frontend (`enable_tool`,
//! Artix) they are synced into the repository, enabling adds the service to the working set
//! with its dependencies, and `set commit` and `live install` compile and install the set.
//! Otherwise enabling lists the service in `contents.d` of the boot bundle, and installing
//! compiles every source directory into a new database, switches the `compiled` link to it
//! and, with the init running, lets `s6-rc-update` move the live database over.
//!
//! A new database can be built where the files can be reached by the tools: on the running
//! system, or offline in the real root. Inside a `--root` tree the sources are written and
//! the database is left for the target.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const model = @import("../unit/model.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const network = @import("network.zig");
const runner = @import("runner.zig");
const render = @import("s6/render.zig");
const layout = @import("s6/layout.zig");
const native = @import("s6/native.zig");
const common = @import("s6/common.zig");
const files = @import("s6/files.zig");

const apply = @import("../reconcile/apply.zig");
const Backend = interface.Backend;
const Env = interface.Env;
const S6Rc = @This();

pub const backend_name = "s6-rc";
pub const generator_number = 2;

/// Capabilities of §11.2. `soft_deps` is off: s6-rc starts what a service depends on and
/// stops what depends on it, whatever the unit said.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .supervision = true,
    .per_service_logger = true,
    .oneshot = true,
    .restart_policy = true,
};

const power_tool = "s6-linux-init-hpr";
const default_live_dir = "/run/s6-rc";
const default_repository = "/etc/s6/repo";
const default_boot_bundle = "default";
/// Milliseconds `s6-svc -wu` waits for a service to come up.
const up_wait_ms = 10_000;
/// Milliseconds `s6-svwait -D` waits for the `finish` of a stopped service to end.
const finish_wait_ms = 60_000;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Replaces the check of which services are enabled when the network targets are mapped; for
/// tests.
enabled_override: ?[]const []const u8 = null,
/// Replaces the check that the root is the real one when a database is built offline; for tests.
offline_install: ?bool = null,
/// Kind of every service `generate` rendered, which `setMember` falls back on while the sources
/// are not written yet (a dry run).
shapes: std.StringHashMapUnmanaged(layout.Type) = .empty,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) S6Rc {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *S6Rc) Backend {
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
    .service_of_file = layout.serviceOfRcFile,
};

fn me(ptr: *anyopaque) *S6Rc {
    return @ptrCast(@alignCast(ptr));
}

fn base(self: *S6Rc) common.Base {
    return .{ .ctx = self.ctx, .dirs = self.dirs, .flavor = .rc, .enabled_override = self.enabled_override };
}

/// True when the s6 frontend drives the repository of service sets.
fn repositoryFlow(self: *S6Rc) bool {
    return self.dirs.enable_tool != null;
}

fn bootBundle(self: *S6Rc) []const u8 {
    return self.dirs.boot_target orelse default_boot_bundle;
}

fn liveDir(self: *S6Rc) []const u8 {
    return self.dirs.live_dir orelse default_live_dir;
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, .rc),
        .extractor = native.extractCommand,
        .entry_file = "run",
        .strip_suffix = layout.producer_suffix,
    };
}

/// The generation directory is read twice: for the scripts that carry their own marker, and for
/// the service directories that list their data files in a meta file.
fn scanDirs(ptr: *anyopaque, gpa: Allocator, _: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const dirs = try gpa.alloc(rebuild.ScanDir, 2);
    const path = layout.generationDir(self.dirs, .rc);
    dirs[0] = .{ .path = path, .tier = .admin, .nested = true };
    dirs[1] = .{ .path = path, .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn enabledLookup(self: *S6Rc) network.Enabled {
    return .{ .ptr = self, .is_enabled = serviceEnabled, .injected = self.enabled_override };
}

fn dependencyFile(gpa: Allocator, deps: common.Dependencies) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ deps.hard, deps.soft }) |list| for (list) |d| {
        if (common.contains(seen.items, d)) continue;
        try seen.append(gpa, d);
        try out.appendSlice(gpa, d);
        try out.append(gpa, '\n');
    };
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(gpa);
}

/// Names s6-rc keeps for itself, the boot bundle, and hidden names that the sources never hold.
fn reservedName(self: *S6Rc, name: []const u8) bool {
    return std.mem.eql(u8, name, self.bootBundle()) or std.mem.startsWith(u8, name, "s6rc-") or name[0] == '.';
}

/// True when the directory holds a service with a command of its own, which the decision about
/// native services deals with.
fn hasNativeCommand(self: *S6Rc, dir: []const u8) !bool {
    const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, "run" });
    const text = (try guard.readOrAbsent(self.ctx, path, 1 << 20)) orelse return false;
    const words = try native.extractCommand(self.ctx.gpa, text);
    return words != null;
}

/// Refuses the unit when a source directory it takes, its own, its pipeline producer or its
/// logger, is a reserved name or holds something other than files generated for the same
/// unit: another unit, a bundle, a oneshot or a longrun that fake-systemd did not write.
fn claimSources(self: *S6Rc, gpa: Allocator, u: *const model.Unit, svc: []const u8) !void {
    const names = [_][]const u8{ svc, try layout.producerName(gpa, svc), try layout.loggerName(gpa, svc) };
    for (names) |name| {
        if (self.reservedName(name)) {
            self.ctx.diag.err("{s}: '{s}' is a name s6-rc keeps for itself", .{ u.name.full, name });
            return error.Unsupported;
        }
        for (try layout.lookupDirs(self.ctx, self.dirs, .rc)) |root| {
            const dir = try std.fs.path.join(gpa, &.{ root, name });
            switch (guard.claimDir(self.ctx, dir, u.name.full, &.{ "run", "up" })) {
                .free, .ours => {},
                .other_unit => try guard.requireNotOther(self.ctx, .other_unit, u.name.full, dir),
                .foreign => if (!try self.hasNativeCommand(dir)) {
                    self.ctx.diag.err("{s}: {s} exists and was not generated by fake-systemd", .{ u.name.full, dir });
                    return error.Unsupported;
                },
            }
        }
    }
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const b = self.base();
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: the s6-rc backend has no user services", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    try self.claimSources(gpa, u, svc);

    const have_setpriv = (try b.findProgram("setpriv")) != null;
    const reason = policy.executorReason(u.*, capabilities, common.nativeSupport());
    const use_executor = (reason != null and reason.? != .no_command) or common.Base.nativeBlocked(u, have_setpriv) or b.executorResolves(u) or render.stopsOnSignal(u);

    const deps = try b.dependencies(svc, u, input.deps, self.enabledLookup());
    const command: render.Command = if (use_executor)
        .executor
    else
        .{ .native = if (u.exec_start.len == 0) &.{"/bin/true"} else try b.commandWords(u.exec_start[0]) };
    const in: render.Input = .{
        .unit = u,
        .command = command,
        .identity = try b.identityFor(u, have_setpriv, use_executor),
        .numeric = try b.numericFor(u, use_executor),
        .executor_path = policy.executor_path,
        .sleep_path = try b.resolveProgram("sleep", "/usr/bin/sleep"),
        .setpriv_path = try b.resolveProgram("setpriv", "/usr/bin/setpriv"),
        .nice_path = try b.resolveProgram("nice", "/usr/bin/nice"),
    };
    try self.shapes.put(gpa, svc, if (u.service_type == .oneshot) .oneshot else .longrun);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const root = layout.generationDir(self.dirs, .rc);
    const dep_text = try dependencyFile(gpa, deps);

    var out: std.ArrayList(apply.GeneratedFile) = .empty;
    if (u.service_type == .oneshot) {
        var set: files.Set = .init(gpa, input, generator, try std.fs.path.join(gpa, &.{ root, svc }));
        try set.data("type", "oneshot\n");
        try set.script("up", try render.up(gpa, in), 0o644);
        const stop_kind = render.stopKind(u, policy.plainStopCommand(u.*));
        if (stop_kind != .none) {
            const words: []const []const u8 = if (stop_kind == .native) try b.commandWords(u.exec_stop[0]) else &.{};
            try set.script("down", try render.down(gpa, in, stop_kind, words), 0o644);
        }
        if (render.startTimeoutMs(u)) |ms| try set.data("timeout-up", try render.numberFile(gpa, ms));
        if (render.stopTimeoutMs(u)) |ms| try set.data("timeout-down", try render.numberFile(gpa, ms));
        if (dep_text) |t| try set.data("dependencies", t);
        try out.appendSlice(gpa, try set.done());
    } else {
        const producer = try layout.producerName(gpa, svc);
        const logger = try layout.loggerName(gpa, svc);
        var srv: files.Set = .init(gpa, input, generator, try std.fs.path.join(gpa, &.{ root, producer }));
        try srv.data("type", "longrun\n");
        try srv.script("run", try render.run(gpa, in), 0o755);
        if (render.needsFinish(u)) try srv.script("finish", try render.finish(gpa, in), 0o755);
        try srv.data("producer-for", try render.lineFile(gpa, logger));
        try srv.data("timeout-kill", try render.numberFile(gpa, render.killTimeoutMs(u)));
        if (render.downSignal(u)) |sig| try srv.data("down-signal", try render.lineFile(gpa, try render.signalFileName(gpa, sig)));
        if (render.finishTimeoutMs(u)) |ms| try srv.data("timeout-finish", try render.numberFile(gpa, ms));
        if (dep_text) |t| try srv.data("dependencies", t);
        try out.appendSlice(gpa, try srv.done());

        var log: files.Set = .init(gpa, input, generator, try std.fs.path.join(gpa, &.{ root, logger }));
        try log.data("type", "longrun\n");
        try log.script("run", try render.log(gpa, u.name.full, u.scope, policy.executor_path), 0o755);
        try log.data("consumer-for", try render.lineFile(gpa, producer));
        try log.data("pipeline-name", try render.lineFile(gpa, svc));
        try out.appendSlice(gpa, try log.done());
    }
    return .{ .service_name = svc, .files = out.items };
}

// ---- reading what was generated ---------------------------------------------------------

fn located(self: *S6Rc, service: []const u8) ?layout.Located {
    return layout.locateRc(self.ctx, self.dirs, service) catch null;
}

/// The `run` or `up` of the service, the file that carries the marker and the flags.
fn entryText(self: *S6Rc, loc: layout.Located) !?[]const u8 {
    const gpa = self.ctx.gpa;
    for ([_][]const u8{ "run", "up" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ loc.dir, name });
        if (try guard.readOrAbsent(self.ctx, path, 1 << 20)) |text| return text;
    }
    return null;
}

fn generatedUnit(self: *S6Rc, loc: layout.Located) !?[]const u8 {
    return common.unitOf((try self.entryText(loc)) orelse return null);
}

fn flagsOf(self: *S6Rc, loc: layout.Located) !native.Flags {
    const parsed = marker.parse((try self.entryText(loc)) orelse return .{}) orelse return .{};
    return native.parseFlags(parsed.rest);
}

/// Name s6-rc is given: the pipeline bundle of a generated service, which holds its logger,
/// otherwise the service itself.
fn changeName(self: *S6Rc, service: []const u8, loc: ?layout.Located) ![]const u8 {
    const l = loc orelse return service;
    if (l.pipeline and (try self.generatedUnit(l)) != null) return service;
    return l.name;
}

// ---- enablement -------------------------------------------------------------------------

fn bundleContents(self: *S6Rc, service: []const u8) ![]const u8 {
    const gpa = self.ctx.gpa;
    return std.fs.path.join(gpa, &.{ layout.generationDir(self.dirs, .rc), self.bootBundle(), "contents.d", service });
}

/// Name the set records for `service`: its producer when it is a pipeline.
fn setMember(self: *S6Rc, service: []const u8) []const u8 {
    if (self.located(service)) |l| return l.name;
    const shape = self.shapes.get(service) orelse return service;
    if (shape == .oneshot) return service;
    return layout.producerName(self.ctx.gpa, service) catch service;
}

fn setPath(self: *S6Rc, state: []const u8, member: []const u8) ![]const u8 {
    const repo = self.dirs.repository orelse default_repository;
    return std.fs.path.join(self.ctx.gpa, &.{ repo, "sources", "current", state, member });
}

fn present(self: *S6Rc, path: []const u8) bool {
    _ = self.ctx.fs.lstat(path) catch return false;
    return true;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    return if (me(ptr).enabledNow(service)) .enabled else .disabled;
}

fn serviceEnabled(ptr: *anyopaque, service: []const u8) anyerror!bool {
    return me(ptr).enabledNow(service);
}

/// True when the service is listed to start at boot.
fn enabledNow(self: *S6Rc, service: []const u8) bool {
    if (self.repositoryFlow()) {
        const member = self.setMember(service);
        for ([_][]const u8{ "active", "always" }) |state| {
            const path = self.setPath(state, member) catch return false;
            if (self.present(path)) return true;
        }
        return false;
    }
    for (layout.lookupDirs(self.ctx, self.dirs, .rc) catch return false) |dir| {
        const path = std.fs.path.join(self.ctx.gpa, &.{ dir, self.bootBundle(), "contents.d", service }) catch return false;
        if (self.present(path)) return true;
    }
    return false;
}

fn runTool(env: Env, argv: []const []const u8, stdio: runner.Stdio) !runner.Result {
    return env.runner.run(env.ctx.gpa, argv, stdio);
}

fn failed(env: Env, what: []const u8, res: runner.Result) error{CommandFailed} {
    const text = std.mem.trim(u8, res.stdout, " \t\r\n");
    env.ctx.diag.err("{s} exited {d}{s}{s}", .{ what, res.code, if (text.len > 0) ": " else "", text });
    return error.CommandFailed;
}

/// True when the tools can reach the files of the database: the init runs here, or the root
/// is the real one.
fn canInstall(self: *S6Rc, env: Env) bool {
    return env.online or (self.offline_install orelse self.ctx.fs.host_root);
}

fn deferred(self: *S6Rc, env: Env, what: []const u8) void {
    _ = self;
    env.ctx.diag.notice("{s}: the service database is not rebuilt inside a --root tree; run 'systemctl daemon-reload' on the target", .{what});
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (self.located(service) == null and !env.ctx.dry_run) {
        env.ctx.diag.err("{s}: no service directory found", .{service});
        return error.Unsupported;
    }
    if (self.enabledNow(service)) return &.{};
    const gpa = env.ctx.gpa;
    const changes = try gpa.alloc(interface.Change, 1);
    if (self.repositoryFlow()) {
        if (!self.canInstall(env)) {
            self.deferred(env, service);
            return &.{};
        }
        const member = self.setMember(service);
        const link = try self.setPath("active", member);
        changes[0] = .{ .created = .{ .link = link, .target = try std.fmt.allocPrint(gpa, "../../.atomics/{s}", .{member}) } };
        try self.syncRepository(env);
        try self.runRepository(env, &.{ "set", "enable", "-p", service });
        try self.commitAndInstall(env);
        return changes;
    }
    const contents = try self.bundleContents(service);
    changes[0] = .{ .created_file = contents };
    if (!env.ctx.dry_run) {
        try self.ensureBootBundle();
        try self.ctx.fs.writeFileAtomic(contents, "", 0o644);
    }
    if (self.canInstall(env)) try self.install(env) else self.deferred(env, service);
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (!self.enabledNow(service)) return &.{};
    const gpa = env.ctx.gpa;
    const changes = try gpa.alloc(interface.Change, 1);
    if (self.repositoryFlow()) {
        if (!self.canInstall(env)) {
            self.deferred(env, service);
            return &.{};
        }
        changes[0] = .{ .removed = try self.setPath("active", self.setMember(service)) };
        try self.runRepository(env, &.{ "set", "disable", "-i", service });
        try self.commitAndInstall(env);
        return changes;
    }
    var path: []const u8 = try self.bundleContents(service);
    for (try layout.lookupDirs(self.ctx, self.dirs, .rc)) |dir| {
        const candidate = try std.fs.path.join(gpa, &.{ dir, self.bootBundle(), "contents.d", service });
        if (self.present(candidate)) path = candidate;
    }
    changes[0] = .{ .removed = path };
    if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(path);
    if (self.canInstall(env)) try self.install(env) else self.deferred(env, service);
    return changes;
}

fn ensureBootBundle(self: *S6Rc) !void {
    const gpa = self.ctx.gpa;
    const dir = try std.fs.path.join(gpa, &.{ layout.generationDir(self.dirs, .rc), self.bootBundle() });
    try self.ctx.fs.makePath(try std.fs.path.join(gpa, &.{ dir, "contents.d" }));
    const type_path = try std.fs.path.join(gpa, &.{ dir, "type" });
    if (!self.ctx.fs.exists(type_path)) try self.ctx.fs.writeFileAtomic(type_path, "bundle\n", 0o644);
}

// ---- building and installing the database ---------------------------------------------------

/// Runs the s6 frontend; a failure stops the sequence.
fn runRepository(self: *S6Rc, env: Env, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, self.dirs.enable_tool.?);
    try argv.appendSlice(env.ctx.gpa, args);
    const res = try runTool(env, argv.items, .quiet);
    if (res.code != 0) {
        const what = try std.mem.join(env.ctx.gpa, " ", argv.items);
        return failed(env, what, res);
    }
}

/// Makes the repository see the sources again.
fn syncRepository(self: *S6Rc, env: Env) !void {
    const owned = try self.ownedSources(env);
    try self.pruneEmptyDirs(env, owned);
    try self.retireMissing(env, owned);
    if (!env.ctx.dry_run) try self.recordSources();
    try self.runRepository(env, &.{ "repository", "sync" });
}

/// Takes the services of the working set out of it when their sources are gone, as when the
/// dependency of a removed unit is collected: the repository would keep naming them until the
/// sync. Only services the index lists as generated are touched; their dependents go with
/// them, since those could no longer be built.
fn retireMissing(self: *S6Rc, env: Env, owned: []const []const u8) !void {
    const gpa = env.ctx.gpa;
    const active = self.setPath("active", "") catch return;
    const listing = try guard.iterateOrEmpty(self.ctx, active);
    var gone: std.ArrayList([]const u8) = .empty;
    for (listing) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        if (!common.contains(owned, e.name)) continue;
        if (!self.sourceExists(e.name)) gone.append(gpa, e.name) catch return;
    }
    if (gone.items.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(gpa, self.dirs.enable_tool.?) catch return;
    argv.appendSlice(gpa, &.{ "set", "disable", "-p" }) catch return;
    argv.appendSlice(gpa, gone.items) catch return;
    const res = runTool(env, argv.items, .quiet) catch |e| return env.ctx.diag.warn("cannot take removed services out of the set: {t}", .{e});
    if (res.code != 0) env.ctx.diag.warn("s6 set disable exited {d} for the removed services", .{res.code});
}

fn sourceExists(self: *S6Rc, name: []const u8) bool {
    const dirs = layout.lookupDirs(self.ctx, self.dirs, .rc) catch return true;
    for (dirs) |dir| {
        const path = std.fs.path.join(self.ctx.gpa, &.{ dir, name }) catch return true;
        if (layout.typeOf(self.ctx, path) != null) return true;
    }
    return false;
}

/// Removes the empty directories of the generation directory that are fake-systemd's (`owned`),
/// which removing a unit leaves behind: a source directory without `type` makes
/// `s6-rc-compile` and the repository sync fail.
fn pruneEmptyDirs(self: *S6Rc, env: Env, owned: []const []const u8) !void {
    if (env.ctx.dry_run) return;
    const gpa = env.ctx.gpa;
    const root = layout.generationDir(self.dirs, .rc);
    const entries = try guard.iterateOrEmpty(self.ctx, root);
    for (entries) |e| {
        if (e.kind != .directory or !common.contains(owned, e.name)) continue;
        const path = std.fs.path.join(gpa, &.{ root, e.name }) catch return;
        const inner = try guard.iterateOrEmpty(self.ctx, path);
        if (inner.len == 0) self.removeTree(path);
    }
}

/// File of the state directory that lists the source directories that held generated files the
/// last time they were looked at: once the files are removed nothing in the directory says it was ours.
const owned_record = "owned-sources";

/// Names of the source directories that are fake-systemd's: those recorded earlier, those that
/// hold generated files now, and those the index lists files below.
fn ownedSources(self: *S6Rc, env: Env) ![]const []const u8 {
    const gpa = self.ctx.gpa;
    const root = layout.generationDir(self.dirs, .rc);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(gpa, try guard.readNames(self.ctx, backend_name, owned_record));
    try names.appendSlice(gpa, try guard.markedDirs(self.ctx, root));
    const indexed = guard.indexedPaths(self.ctx, env.owned_paths, backend_name, generator_number);
    for (try guard.iterateOrEmpty(self.ctx, root)) |e| {
        const path = try std.fs.path.join(gpa, &.{ root, e.name });
        if (guard.anyUnder(indexed, path)) try names.append(gpa, e.name);
    }
    return names.items;
}

/// Records the source directories that hold generated files now.
fn recordSources(self: *S6Rc) !void {
    const root = layout.generationDir(self.dirs, .rc);
    try guard.writeNames(self.ctx, backend_name, owned_record, try guard.markedDirs(self.ctx, root));
}

/// `set commit` compiles the working set into a database and `live install` makes it the
/// one the init boots on and, with the init running, the live one; `--init` does the first part
/// only, which is all there is to do while the init is not running.
fn commitAndInstall(self: *S6Rc, env: Env) !void {
    try self.runRepository(env, &.{ "set", "commit" });
    if (env.online) {
        try self.runRepository(env, &.{ "live", "install" });
    } else {
        try self.runRepository(env, &.{ "live", "install", "--init" });
    }
}

fn installRepository(self: *S6Rc, env: Env) !void {
    try self.syncRepository(env);
    try self.commitAndInstall(env);
}

/// Number after `<base>-` in `name`, when that is all that follows.
fn databaseNumber(base_name: []const u8, name: []const u8) ?u32 {
    const rest = std.mem.cutPrefix(u8, name, base_name) orelse return null;
    const digits = std.mem.cutPrefix(u8, rest, "-") orelse return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// Path for the next database: `<compiled>-<n>` with `n` above every number in use.
fn nextDatabase(self: *S6Rc, compiled: []const u8) ![]const u8 {
    const gpa = self.ctx.gpa;
    const parent = std.fs.path.dirname(compiled) orelse "/";
    const base_name = std.fs.path.basename(compiled);
    var highest: u32 = 0;
    const entries = self.ctx.fs.iterateDir(gpa, parent) catch |e| switch (e) {
        error.FileNotFound => &.{},
        else => return e,
    };
    for (entries) |e| {
        if (databaseNumber(base_name, e.name)) |n| highest = @max(highest, n);
    }
    return std.fmt.allocPrint(gpa, "{s}-{d}", .{ compiled, highest + 1 });
}

fn install(self: *S6Rc, env: Env) !void {
    if (self.repositoryFlow()) return self.installRepository(env);
    const gpa = env.ctx.gpa;
    const compiled = self.dirs.compiled orelse {
        env.ctx.diag.err("the profile has no compiled database for s6-rc", .{});
        return error.Unsupported;
    };
    try self.pruneEmptyDirs(env, try self.ownedSources(env));
    if (!env.ctx.dry_run) try self.recordSources();
    const next = try self.nextDatabase(compiled);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "s6-rc-compile", next });
    try argv.appendSlice(gpa, try layout.lookupDirs(self.ctx, self.dirs, .rc));
    const built = try runTool(env, argv.items, .quiet);
    if (built.code != 0) {
        if (!env.ctx.dry_run) self.removeTree(next);
        return failed(env, "s6-rc-compile", built);
    }
    if (!env.ctx.dry_run) try self.markDatabase(next);
    if (env.online) {
        const updated = try runTool(env, &.{ "s6-rc-update", "-l", self.liveDir(), next }, .quiet);
        if (updated.code != 0) return failed(env, "s6-rc-update", updated);
    }
    if (env.ctx.dry_run) return;
    try self.switchLink(compiled, next);
}

/// File that records a database as built by fake-systemd, the only kind it removes again.
const database_marker = "fake-systemd.db";

fn markDatabase(self: *S6Rc, db: []const u8) !void {
    try self.ctx.fs.writeFileAtomic(try std.fs.path.join(self.ctx.gpa, &.{ db, database_marker }), "", 0o644);
}

fn ownDatabase(self: *S6Rc, db: []const u8) bool {
    const path = std.fs.path.join(self.ctx.gpa, &.{ db, database_marker }) catch return false;
    return self.ctx.fs.exists(path);
}

fn removeTree(self: *S6Rc, path: []const u8) void {
    self.ctx.fs.deleteTree(path) catch |e| self.ctx.diag.warn("cannot remove {s}: {t}", .{ path, e });
}

fn removeFile(self: *S6Rc, path: []const u8) void {
    self.ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => self.ctx.diag.warn("cannot remove {s}: {t}", .{ path, e }),
    };
}

/// Points `compiled` at `next` and removes the database it pointed at, when fake-systemd built
/// it. A `compiled` that is a real directory is kept under a numbered name that is not taken.
fn switchLink(self: *S6Rc, compiled: []const u8, next: []const u8) !void {
    const gpa = self.ctx.gpa;
    const base_name = std.fs.path.basename(compiled);
    var old_target: ?[]const u8 = null;
    if (self.ctx.fs.lstat(compiled)) |st| switch (st.kind) {
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            old_target = try gpa.dupe(u8, try self.ctx.fs.readLink(compiled, &buf));
        },
        .directory => {
            var kept: []const u8 = try std.fmt.allocPrint(gpa, "{s}-0", .{compiled});
            if (self.present(kept)) kept = try self.nextDatabase(compiled);
            try self.ctx.fs.rename(compiled, kept);
        },
        else => {},
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    const parent = std.fs.path.dirname(compiled) orelse "/";
    try self.ctx.fs.makePath(parent);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.new", .{compiled});
    self.removeFile(tmp);
    try self.ctx.fs.symLink(std.fs.path.basename(next), tmp);
    try self.ctx.fs.rename(tmp, compiled);
    const old = old_target orelse return;
    if (databaseNumber(base_name, std.fs.path.basename(old)) == null) return;
    const old_path = if (std.fs.path.isAbsolute(old)) old else try std.fs.path.join(gpa, &.{ parent, old });
    if (!self.ownDatabase(old_path)) return;
    self.ctx.diag.info("removing the previous service database {s}", .{old_path});
    self.removeTree(old_path);
}

// ---- runtime control --------------------------------------------------------------------

fn statusOf(self: *S6Rc, env: Env, service: []const u8) !interface.Status {
    const loc = self.located(service);
    const name = if (loc) |l| l.name else service;
    if (loc != null and loc.?.kind != .longrun) return self.stateFromList(env, service, loc.?);
    const dir = try self.serviceDirOf(name);
    if (loc == null and !self.ctx.fs.exists(dir)) {
        return .{ .state = if (try self.listed(env, name)) .active else .inactive };
    }
    const res = try runTool(env, &.{ "s6-svstat", dir }, .capture);
    return native.parseStatus(res.stdout, self.verdictOf(dir));
}

/// A oneshot is active while s6-rc lists it as up and it stays after its command; a bundle is
/// active when everything it holds is.
fn stateFromList(self: *S6Rc, env: Env, service: []const u8, loc: layout.Located) !interface.Status {
    _ = service;
    if (loc.kind == .oneshot) {
        const remains = (try self.flagsOf(loc)).remain or (try self.generatedUnit(loc)) == null;
        return .{ .state = if (remains and try self.listed(env, loc.name)) .active else .inactive };
    }
    const res = try runTool(env, &.{ "s6-rc-db", "-l", self.liveDir(), "contents", loc.name }, .capture);
    const members = try native.nameLines(env.ctx.gpa, res.stdout);
    if (members.len == 0) return .{ .state = .inactive };
    for (members) |m| if (!try self.listed(env, m)) return .{ .state = .inactive };
    return .{ .state = .active };
}

fn serviceDirOf(self: *S6Rc, name: []const u8) ![]const u8 {
    return std.fs.path.join(self.ctx.gpa, &.{ self.liveDir(), "servicedirs", name });
}

/// True when s6-rc lists `name` among the services that are up.
fn listed(self: *S6Rc, env: Env, name: []const u8) !bool {
    const res = try runTool(env, &.{ "s6-rc", "-l", self.liveDir(), "-a", "list" }, .capture);
    return native.contains(try native.nameLines(env.ctx.gpa, res.stdout), name);
}

fn verdictOf(self: *S6Rc, servicedir: []const u8) ?native.Verdict {
    const path = std.fs.path.join(self.ctx.gpa, &.{ servicedir, "supervise", render.exit_status_file }) catch return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 256) catch return null;
    return native.parseVerdict(text);
}

fn forgetExit(self: *S6Rc, env: Env, servicedir: []const u8) void {
    if (env.ctx.dry_run) return;
    const path = std.fs.path.join(self.ctx.gpa, &.{ servicedir, "supervise", render.exit_status_file }) catch return;
    self.ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => env.ctx.diag.warn("cannot remove {s}: {t}", .{ path, e }),
    };
}

/// Records a stop that fake-systemd asked for as a clean end, so a service that had to be
/// killed does not read as failed.
fn markStopped(self: *S6Rc, env: Env, servicedir: []const u8) void {
    if (env.ctx.dry_run) return;
    const path = std.fs.path.join(self.ctx.gpa, &.{ servicedir, "supervise", render.exit_status_file }) catch return;
    if (!self.ctx.fs.exists(std.fs.path.dirname(path).?)) return;
    self.ctx.fs.writeFileAtomic(path, "ok 0 0\n", 0o644) catch |e| env.ctx.diag.warn("cannot write {s}: {t}", .{ path, e });
}

/// Whether the live database knows `name`; a service generated since the database was built does not.
fn known(env: Env, live: []const u8, name: []const u8) bool {
    const res = runTool(env, &.{ "s6-rc-db", "-l", live, "type", name }, .capture) catch return false;
    return res.code == 0;
}

fn ensureLoaded(self: *S6Rc, env: Env, service: []const u8, loc: ?layout.Located) !void {
    if (env.ctx.dry_run) return;
    if (known(env, self.liveDir(), try self.changeName(service, loc))) return;
    try self.install(env);
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const loc = self.located(service);
    try self.ensureLoaded(env, service, loc);
    const target = try self.changeName(service, loc);
    const kind: layout.Type = if (loc) |l| l.kind else .longrun;
    if (kind == .oneshot and !(try self.flagsOf(loc.?)).remain and (try self.generatedUnit(loc.?)) != null) {
        _ = try runTool(env, &.{ "s6-rc", "-l", self.liveDir(), "-d", "change", target }, .quiet);
    } else if (kind == .longrun) {
        if (try self.restartOutsideRc(env, service, loc)) return;
    }
    const res = try runTool(env, &.{ "s6-rc", "-l", self.liveDir(), "-u", "change", target }, .quiet);
    if (res.code != 0) return failed(env, "s6-rc", res);
}

/// A service s6-rc lists as up whose process was stopped behind its back (a `finish` that
/// ended it for good) is not started by `s6-rc -u`; its supervisor is told to start it.
/// Returns true when the service is running afterwards or needs no start.
fn restartOutsideRc(self: *S6Rc, env: Env, service: []const u8, loc: ?layout.Located) !bool {
    const name = if (loc) |l| l.name else service;
    const st = try self.statusOf(env, service);
    if (st.state == .active or st.state == .activating) return true;
    if (!try self.listed(env, name)) return false;
    const dir = try self.serviceDirOf(name);
    self.forgetExit(env, dir);
    const wait = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{up_wait_ms});
    const res = try runTool(env, &.{ "s6-svc", "-wu", "-T", wait, "-u", dir }, .quiet);
    if (res.code != 0) return failed(env, "s6-svc", res);
    return true;
}

/// Waits until the `finish` of a stopped longrun has ended, since it records how the process
/// ended and must not do so after `markStopped`; it is a no-op for a service nobody supervises.
fn awaitFinish(self: *S6Rc, env: Env, servicedir: []const u8) !void {
    _ = self;
    if (env.ctx.dry_run) return;
    const wait = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{finish_wait_ms});
    _ = try runTool(env, &.{ "s6-svwait", "-D", "-t", wait, servicedir }, .quiet);
}

fn stopService(self: *S6Rc, env: Env, service: []const u8) !void {
    const loc = self.located(service);
    const target = try self.changeName(service, loc);
    const res = try runTool(env, &.{ "s6-rc", "-l", self.liveDir(), "-d", "change", target }, .quiet);
    if (res.code != 0) {
        const st = try self.statusOf(env, service);
        if (st.state != .inactive and st.state != .failed) return failed(env, "s6-rc", res);
    }
    const l = loc orelse return;
    if (l.kind != .longrun) return;
    const dir = try self.serviceDirOf(l.name);
    try self.awaitFinish(env, dir);
    self.markStopped(env, dir);
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).stopService(env, service);
}

/// A stop followed by a start: `Restart=no` services stay down after the stop, which makes
/// a restart start them again, and a oneshot is brought down so that it runs once more.
fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.stopService(env, service);
    try start(ptr, env, service);
}

fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const loc = self.located(service);
    if (loc) |l| if (try self.generatedUnit(l)) |unit_name| {
        var argv: std.ArrayList([]const u8) = .empty;
        if ((try self.statusOf(env, service)).pid) |pid| {
            try argv.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "MAINPID={d}", .{pid}) });
        }
        try argv.appendSlice(gpa, guard.executorPrefix(env.ctx, unit_name));
        try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name, "--phase", "reload" });
        const res = try runTool(env, argv.items, .inherit);
        if (res.code != 0) return error.CommandFailed;
        return;
    };
    const name = if (loc) |l| l.name else service;
    const res = try runTool(env, &.{ "s6-svc", "-h", try self.serviceDirOf(name) }, .quiet);
    if (res.code != 0) return failed(env, "s6-svc", res);
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const loc = self.located(service);
    if (loc) |l| if (l.kind != .longrun) {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const name = if (loc) |l| l.name else service;
    const sig = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const res = try runTool(env, &.{ "s6-svc", "-s", sig, try self.serviceDirOf(name) }, .quiet);
    if (res.code != 0) return failed(env, "s6-svc", res);
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    return me(ptr).statusOf(env, service);
}

/// Builds the database again from the sources and moves the running init over to it.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    try me(ptr).install(env);
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const flag = switch (action) {
        .reboot => "-r",
        .poweroff => "-p",
        .halt => "-h",
    };
    const res = try runTool(env, &.{ power_tool, flag }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
    _ = common;
    _ = files;
}
