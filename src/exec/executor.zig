// SPDX-License-Identifier: GPL-3.0-or-later
//! `fake-systemd --exec`: runs the commands of a service unit with systemd.exec(5) semantics.
//!
//! `start` runs `ExecStartPre=`, then replaces the process with `ExecStart=` (simple, exec,
//! notify, dbus, idle; as a supervised child when `ExecStartPost=` is set), or follows the
//! `PIDFile=` process (forking), or
//! runs every `ExecStart=` in sequence (oneshot). `stop`, `reload` and `stop-post` run
//! `ExecStop=`, `ExecReload=` and `ExecStopPost=`; `stop-post` then removes the runtime
//! directories, and `stop-main` is the part of `stop` before `ExecStopPost=`. Setup failures
//! use systemd's exit statuses (200 and above).
//!
//! With `stop_on_signal`, the main process of a unit that has `ExecStop=` runs as a child of a
//! resident supervisor that turns SIGTERM into the stop: `ExecStop=` with `$MAINPID`, then the
//! termination of the main process, then the exit with its status. Other signals are forwarded.
//!
//! Unit files, environment files, accounts and directories are resolved through `Fs` and so
//! live below the filesystem root of the context; executables, `WorkingDirectory=` and
//! processes are real.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const resolve = @import("../unit/resolve.zig");
const name_mod = @import("../unit/name.zig");
const specifier = @import("../unit/specifier.zig");
const timespan = @import("../unit/timespan.zig");
const accounts = @import("accounts.zig");
const dirs = @import("dirs.zig");
const environment = @import("environment.zig");
const expand = @import("expand.zig");
const identity = @import("identity.zig");
const limits = @import("limits.zig");
const procs = @import("procs.zig");
const sys = @import("sys.zig");
const logger = @import("logger.zig");

pub const Phase = enum { start, stop, reload, @"stop-post", @"stop-main" };

pub const Request = struct {
    unit: []const u8,
    phase: Phase = .start,
    /// `start` only: SIGTERM runs `ExecStop=` and terminates the main process.
    stop_on_signal: bool = false,
    /// `start` only: stdout and stderr of the unit go to one `fake-systemd --log` child.
    log: bool = false,
    /// `start` only: the executor stays resident and writes how the main process ended to `execExitPath`.
    record_exit: bool = false,
    /// The service manager has set the identity of the process: `User=`, `Group=` and
    /// `SupplementaryGroups=` are neither switched to nor refused when they do not resolve.
    identity_set: bool = false,
    /// A numeric identity to switch to instead of resolving `User=`, `Group=` and `SupplementaryGroups=`.
    identity: ?identity.Switch = null,
};

pub const search_path = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };
const default_start_timeout_us: u64 = 90 * std.time.us_per_s;
const pidfile_poll_ms = 100;
const reap_tick_ms = 100;

/// Exit statuses used by systemd for failures before the command runs.
const exit_chdir = 200;
const exit_nice = 201;
const exit_exec = 203;
const exit_limits = 205;
const exit_no_new_privileges = 227;

/// Child running a control command, and the supervised main process; both get forwarded signals.
var forward_pid: std.atomic.Value(i32) = .init(0);
var forward_main: std.atomic.Value(i32) = .init(0);
var received_signal: std.atomic.Value(u32) = .init(0);
/// In stop mode SIGTERM is the request to stop: it ends a control command that is running and is
/// not forwarded to the main process.
var stop_mode: std.atomic.Value(bool) = .init(false);
var stop_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(sig: linux.SIG) callconv(.c) void {
    if (stop_mode.load(.seq_cst)) {
        if (sig == .TERM) {
            stop_requested.store(true, .seq_cst);
            const pid = forward_pid.load(.seq_cst);
            if (pid > 0) _ = linux.kill(pid, sig);
        } else forward(sig);
        return;
    }
    received_signal.store(@backingInt(sig), .seq_cst);
    forward(sig);
}

fn forward(sig: linux.SIG) void {
    const pid = forward_pid.load(.seq_cst);
    if (pid > 0) _ = linux.kill(pid, sig);
    const main_pid = forward_main.load(.seq_cst);
    if (main_pid > 0) _ = linux.kill(main_pid, sig);
}

/// Signals that a supervisor in stop mode forwards besides HUP and INT.
const stop_mode_signals = [_]linux.SIG{ .QUIT, .USR1, .USR2, .ALRM, .WINCH };

fn installHandlers(stop: bool) void {
    stop_mode.store(stop, .seq_cst);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &action, null);
    if (stop) {
        for (stop_mode_signals) |sig| _ = linux.sigaction(sig, &action, null);
    }
}

fn signalFromNumber(n: u32) linux.SIG {
    return @fromBackingInt(@intCast(n));
}

/// Exit statuses and signals that count as success for a main process.
pub const SuccessSet = struct {
    codes: [256]bool = blk: {
        var c: [256]bool = @splat(false);
        c[0] = true;
        break :blk c;
    },
    signals: [65]bool = blk: {
        var s: [65]bool = @splat(false);
        for ([_]linux.SIG{ .HUP, .INT, .TERM, .PIPE }) |sig| s[@backingInt(sig)] = true;
        break :blk s;
    },

    /// Unknown entries are returned through `unknown` for the caller to report.
    pub fn parse(entries: []const []const u8, unknown: *std.ArrayList([]const u8), gpa: Allocator) Allocator.Error!SuccessSet {
        var set: SuccessSet = .{};
        for (entries) |entry| {
            if (std.fmt.parseInt(u8, entry, 10)) |code| {
                set.codes[code] = true;
                continue;
            } else |_| {}
            const bare = if (std.mem.startsWith(u8, entry, "SIG")) entry[3..] else entry;
            if (std.meta.stringToEnum(linux.SIG, bare)) |sig| {
                set.signals[@backingInt(sig)] = true;
            } else try unknown.append(gpa, entry);
        }
        return set;
    }

    pub fn accepts(s: SuccessSet, exit: sys.Exit) bool {
        return switch (exit) {
            .exited => |c| s.codes[c],
            .signaled => |n| n < s.signals.len and s.signals[n],
        };
    }
};

const Cwd = struct {
    path: [:0]const u8,
    optional: bool,
};

const Prepared = struct {
    ctx: *core.Context,
    unit: model.Unit,
    vars: expand.Vars,
    envp: [*:null]const ?[*:0]const u8,
    ident: identity.Identity,
    cwd: ?Cwd,
    limit_list: []const limits.Limit,
    umask: u32,
    success: SuccessSet,
    /// Uid of the service: the account switched to, else the uid of the executor.
    service_uid: u32 = 0,
    /// Main process of the unit for `stop` and `reload`.
    main_pid: ?i32 = null,
    /// Why `main_pid` was accepted, for the checks before it is signalled.
    main_source: procs.Source = .{ .service_uid = 0 },
    stop_on_signal: bool = false,
    record_exit: bool = false,
};

fn readTrimmed(ctx: *const core.Context, path: []const u8) ?[]const u8 {
    const content = ctx.fs.readFileAlloc(ctx.gpa, path, 4096) catch return null;
    const t = std.mem.trim(u8, content, " \t\r\n");
    return if (t.len == 0) null else t;
}

/// Accounts of the root in use for the specifiers: the user that runs the manager is its
/// `/etc/passwd` entry, never what `$USER` or `$HOME` say.
fn readAccounts(ctx: *const core.Context) Allocator.Error!*const specifier.Accounts {
    const acc = try ctx.gpa.create(specifier.Accounts);
    // An unreadable database reads as empty here; `runInner` loads it again and refuses a unit that
    // names an account.
    acc.* = specifier.Accounts.read(ctx.gpa, ctx.fs.*) catch .{};
    return acc;
}

fn specifierEnvFor(ctx: *const core.Context, acc: *const specifier.Accounts) Allocator.Error!specifier.Env {
    const user = try acc.manager(ctx.gpa, ctx.uid);
    var env: specifier.Env = switch (ctx.scope) {
        .system => .system(user),
        .user => try .userScope(ctx.gpa, user, .{
            .runtime = ctx.xdg_runtime_dir,
            .state = ctx.xdg_state_home,
            .cache = ctx.xdg_cache_home,
            .config = ctx.xdg_config_home,
        }),
    };
    env.hostname = readTrimmed(ctx, "/etc/hostname");
    env.machine_id = readTrimmed(ctx, "/etc/machine-id");
    return env;
}

pub fn specifierEnv(ctx: *const core.Context) Allocator.Error!specifier.Env {
    return specifierEnvFor(ctx, try readAccounts(ctx));
}

/// Resolves `unit_name` in the scope of `ctx` and builds its model.
pub fn loadUnit(ctx: *core.Context, unit_name: []const u8) !model.Unit {
    const name = try name_mod.parse(ctx.gpa, unit_name);
    const resolved = try resolve.resolve(ctx.gpa, ctx.fs.*, .{ .scope = ctx.scope, .xdg_config_home = ctx.xdg_config_home }, name);
    const acc = try readAccounts(ctx);
    return model.load(ctx.gpa, ctx.fs.*, resolved, .{
        .env = try specifierEnvFor(ctx, acc),
        .user_lookup = .{ .context = @constCast(acc), .lookup = specifier.Accounts.lookup },
    });
}

fn fail(ctx: *core.Context, comptime fmt: []const u8, args: anytype) u8 {
    ctx.diag.err(fmt, args);
    return 1;
}

/// A pid that passed the checks of its source, with the source it passed for.
const Accepted = struct { pid: i32, src: procs.Source };

const PidFile = struct { text: []const u8, owner: u32 };

/// Reads a small file that is a regular file, not a symlink, through one descriptor.
fn readPidFile(ctx: *const core.Context, path: []const u8, buf: []u8) ?PidFile {
    const file = ctx.fs.openNoFollow(path, .{}) catch return null;
    defer file.close(ctx.io);
    const info = core.Fs.fileInfo(file) catch return null;
    if (info.kind != .file) return null;
    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(file.handle, buf[len..].ptr, buf.len - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (rc == 0) break;
        len += rc;
    }
    return .{ .text = buf[0..len], .owner = info.uid };
}

/// The process that the executor recorded in its state file: null unless the file is a regular
/// file holding `<pid> <start time>` of a live process that `procs.acceptable` allows and whose
/// start time is still the recorded one. A refused pid is reported when `report` is set.
fn readRecorded(ctx: *const core.Context, path: []const u8, service_uid: u32, report: bool) ?Accepted {
    var buf: [64]u8 = undefined;
    const file = readPidFile(ctx, path, &buf) orelse return null;
    const record = procs.parseRecord(file.text) orelse return null;
    const src: procs.Source = .{ .service_uid = service_uid, .file_owner = file.owner };
    if (procs.recordLives(record) and procs.acceptable(record.pid, src)) return .{ .pid = record.pid, .src = src };
    if (report and record.pid > 1) ctx.diag.warn("ignoring pid {d} from {s}: not the recorded process of the service", .{ record.pid, path });
    return null;
}

/// The pid that the daemon of a forking unit wrote to `PIDFile=`. The file is only a claim by
/// the service, so the pid is taken when it is a descendant of this executor, whose subreaper
/// role makes every process the daemon left behind one.
fn readClaimedPid(ctx: *const core.Context, path: []const u8, service_uid: u32) ?Accepted {
    var buf: [64]u8 = undefined;
    const file = readPidFile(ctx, path, &buf) orelse return null;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, file.text, " \t\r\n"), 10) catch return null;
    if (!procs.acceptableDescendant(pid)) return null;
    return .{ .pid = pid, .src = .{ .service_uid = service_uid } };
}

fn pidFilePath(ctx: *const core.Context, unit: model.Unit) Allocator.Error!?[]const u8 {
    const raw = unit.pid_file orelse return null;
    if (std.fs.path.isAbsolute(raw)) return raw;
    return try std.fs.path.join(ctx.gpa, &.{ "/run", raw });
}

fn resolveCwd(ctx: *core.Context, unit: model.Unit, ident: identity.Identity, vars: *const expand.Vars) !?Cwd {
    const raw = unit.working_directory orelse if (ctx.scope == .user) "~" else "/";
    const optional = raw.len > 0 and raw[0] == '-';
    const spec = if (optional) raw[1..] else raw;
    const path: []const u8 = if (std.mem.eql(u8, spec, "~"))
        (if (ident.account) |a| a.home else null) orelse vars.get("HOME") orelse ctx.home
    else
        spec;
    if (!std.fs.path.isAbsolute(path)) {
        if (optional) return null;
        return error.InvalidWorkingDirectory;
    }
    return .{ .path = try ctx.gpa.dupeSentinel(u8, path, 0), .optional = optional };
}

fn buildEnvp(gpa: Allocator, vars: *const expand.Vars) Allocator.Error![*:null]const ?[*:0]const u8 {
    const list = try gpa.allocSentinel(?[*:0]const u8, vars.count(), null);
    for (vars.keys(), vars.values(), 0..) |k, v, i| {
        list[i] = (try std.fmt.allocPrintSentinel(gpa, "{s}={s}", .{ k, v }, 0)).ptr;
    }
    return list.ptr;
}

/// Everything `start`, `stop`, `reload` and `stop-post` share. Returns an exit status to stop
/// with, after reporting the reason, or null.
fn prepare(ctx: *core.Context, unit: model.Unit, db: accounts.Db, phase: Phase, req: Request, out: *Prepared) !?u8 {
    var warnings: std.ArrayList(identity.Warning) = .empty;
    const euid = linux.geteuid();
    const ident = try identity.resolve(ctx.gpa, db, unit, .{
        .euid = euid,
        .egid = linux.getegid(),
        .identity_set = req.identity_set,
        .explicit = req.identity,
    }, &warnings);
    for (warnings.items) |w| switch (w) {
        .unprivileged => |n| ctx.diag.warn("{s}: cannot switch to '{s}' without root; keeping the current identity", .{ unit.name.full, n }),
    };
    if (ident.refused) |r| {
        if (r.incomplete) {
            ctx.diag.err("{s}: the numeric identity needs both --uid and --gid; refusing to run the service as root", .{unit.name.full});
            return r.code;
        }
        ctx.diag.err("{s}: '{s}' is not in /etc/passwd or /etc/group; refusing to run the service as root (pass --identity-set when the service manager has set the identity)", .{ unit.name.full, r.name });
        return r.code;
    }
    const service_uid = if (ident.switch_to) |sw| sw.uid orelse euid else euid;

    var extra: std.ArrayList(model.EnvVar) = .empty;
    const main: ?Accepted = if (phase == .start) null else try mainPid(ctx, unit, service_uid);
    const main_pid: ?i32 = if (main) |m| m.pid else null;
    if (phase == .start) {
        if (try dirs.prepare(ctx, unit, ident.switch_to, &extra)) |code| return code;
    } else if (main_pid) |pid| {
        try extra.append(ctx.gpa, .{ .name = "MAINPID", .value = try std.fmt.allocPrint(ctx.gpa, "{d}", .{pid}) });
    }
    const vars = environment.build(ctx, unit, ident.account, extra.items) catch |e| switch (e) {
        error.EnvironmentFile => return 1,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var limit_list: std.ArrayList(limits.Limit) = .empty;
    for (unit.limits) |l| {
        const parsed = limits.parse(l.key, l.value) catch {
            ctx.diag.err("{s}: invalid {s}={s}", .{ unit.name.full, l.key, l.value });
            return exit_limits;
        };
        try limit_list.append(ctx.gpa, parsed);
    }

    var unknown_status: std.ArrayList([]const u8) = .empty;
    const success = try SuccessSet.parse(unit.success_exit_status, &unknown_status, ctx.gpa);
    for (unknown_status.items) |s| ctx.diag.warn("{s}: unknown SuccessExitStatus= entry '{s}'", .{ unit.name.full, s });

    const cwd = resolveCwd(ctx, unit, ident, &vars) catch {
        ctx.diag.err("{s}: invalid WorkingDirectory={s}", .{ unit.name.full, unit.working_directory orelse "" });
        return exit_chdir;
    };
    out.* = .{
        .ctx = ctx,
        .unit = unit,
        .vars = vars,
        .envp = try buildEnvp(ctx.gpa, &vars),
        .ident = ident,
        .cwd = cwd,
        .limit_list = try limit_list.toOwnedSlice(ctx.gpa),
        .umask = unit.umask orelse 0o022,
        .success = success,
        .service_uid = service_uid,
        .main_pid = main_pid,
        .main_source = if (main) |m| m.src else .{ .service_uid = service_uid },
    };
    return null;
}

/// State file the executor writes in every start, holding `<pid> <start time>` of the main process
/// of the unit. It is the only source of the process that stop and reload signal.
pub fn execPidPath(ctx: *const core.Context, unit_name: []const u8) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(ctx.gpa, "fake-systemd/{s}.pid", .{unit_name});
    return std.fs.path.join(ctx.gpa, &.{ if (ctx.scope == .user) ctx.xdg_runtime_dir else "/run", file });
}

/// Mode of the directory and the files that the executor keeps in the runtime directory. They
/// are written by root before or beside the service, never by the service account.
const state_dir_mode = 0o755;
const state_file_mode = 0o644;

/// Writes one of the executor's state files below `<runtime>/fake-systemd`.
pub fn writeStateFile(ctx: *core.Context, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try dirs.ensureRootDir(ctx, dir, state_dir_mode);
    try ctx.fs.writeFileInPlace(path, content, state_file_mode);
}

fn writeMainPid(ctx: *core.Context, unit: model.Unit, pid: i32) void {
    const path = execPidPath(ctx, unit.name.full) catch return;
    const started = procs.startTime(pid) orelse {
        ctx.diag.warn("{s}: process {d} is gone before it could be recorded", .{ unit.name.full, pid });
        return;
    };
    const text = std.fmt.allocPrint(ctx.gpa, "{d} {d}\n", .{ pid, started }) catch return;
    writeStateFile(ctx, path, text) catch |e| ctx.diag.warn("{s}: cannot write {s}: {t}", .{ unit.name.full, path, e });
}

/// `$MAINPID` for control commands and the process to stop: inherited from the caller, else the
/// process recorded by the executor. Every candidate has to pass `procs.acceptable`.
fn mainPid(ctx: *const core.Context, unit: model.Unit, service_uid: u32) !?Accepted {
    if (ctx.environ.get("MAINPID")) |text| {
        if (std.fmt.parseInt(i32, text, 10)) |pid| {
            const src: procs.Source = .{ .service_uid = service_uid };
            if (procs.acceptable(pid, src)) return .{ .pid = pid, .src = src };
            ctx.diag.warn("{s}: ignoring MAINPID={d}: not a live process of the service", .{ unit.name.full, pid });
        } else |_| {}
    }
    return readRecorded(ctx, try execPidPath(ctx, unit.name.full), service_uid, true);
}

const Argv = struct {
    path: []const u8,
    argv: []const []const u8,
};

/// The executable is taken literally; `argv[0]` and the arguments are expanded unless the
/// command has the `:` prefix.
fn commandArgv(prep: *const Prepared, cmd: model.Command) Allocator.Error!Argv {
    const gpa = prep.ctx.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    if (cmd.flags.argv0) {
        const first = try expand.expandWords(gpa, cmd.words[1..2], &prep.vars, cmd.flags.no_expand);
        try argv.append(gpa, if (first.len > 0) first[0] else "");
    } else try argv.append(gpa, cmd.words[0]);
    try argv.appendSlice(gpa, try expand.expandWords(gpa, cmd.args(), &prep.vars, cmd.flags.no_expand));
    return .{ .path = cmd.words[0], .argv = try argv.toOwnedSlice(gpa) };
}

/// Absolute paths are used as given; a bare name is searched in `search_path`.
pub fn findExecutable(gpa: Allocator, path: []const u8) Allocator.Error!?[:0]const u8 {
    if (std.fs.path.isAbsolute(path)) return try gpa.dupeSentinel(u8, path, 0);
    if (std.mem.findScalar(u8, path, '/') != null) return null;
    for (search_path) |dir| {
        const candidate = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, path }, 0);
        if (sys.isExecutable(candidate)) return candidate;
    }
    return null;
}

fn bail(cmd: model.Command, code: u8) noreturn {
    sys.exitNow(if (cmd.flags.ignore_failure) 0 else code);
}

/// Applies limits, nice level, umask, identity, working directory and `NoNewPrivileges=` in
/// the calling process, then `execve`s the command. Never returns. With the `-` prefix a
/// failure exits 0.
fn execCommand(prep: *Prepared, cmd: model.Command) noreturn {
    const ctx = prep.ctx;
    const unit = prep.unit;
    const privileged = cmd.flags.plus or cmd.flags.bang or cmd.flags.bang_bang;
    const words = commandArgv(prep, cmd) catch {
        ctx.diag.err("{s}: out of memory", .{unit.name.full});
        bail(cmd, 1);
    };

    for (prep.limit_list) |l| {
        const e = sys.setRlimit(l.resource, l.soft, l.hard);
        if (e != .SUCCESS) {
            ctx.diag.err("{s}: cannot set {t} limit: {t}", .{ unit.name.full, l.resource, e });
            bail(cmd, exit_limits);
        }
    }
    if (unit.nice) |n| {
        const e = sys.setNice(n);
        if (e != .SUCCESS) {
            ctx.diag.err("{s}: cannot set the nice level: {t}", .{ unit.name.full, e });
            bail(cmd, exit_nice);
        }
    }
    sys.setUmask(prep.umask);
    if (!privileged) {
        if (prep.ident.switch_to) |sw| {
            if (identity.apply(sw)) |f| {
                ctx.diag.err("{s}: cannot switch user or group: {t}", .{ unit.name.full, f.errno });
                bail(cmd, f.code);
            }
        }
    }
    if (prep.cwd) |cwd| {
        const e = sys.chdir(cwd.path);
        if (e != .SUCCESS and !cwd.optional) {
            ctx.diag.err("{s}: cannot change to {s}: {t}", .{ unit.name.full, cwd.path, e });
            bail(cmd, exit_chdir);
        }
    }
    if (unit.no_new_privileges == true and !cmd.flags.plus) {
        const e = sys.noNewPrivileges();
        if (e != .SUCCESS) {
            ctx.diag.err("{s}: cannot set NoNewPrivileges: {t}", .{ unit.name.full, e });
            bail(cmd, exit_no_new_privileges);
        }
    }

    const exe = (findExecutable(ctx.gpa, words.path) catch null) orelse {
        ctx.diag.err("{s}: executable '{s}' not found", .{ unit.name.full, words.path });
        bail(cmd, exit_exec);
    };
    const argv = ctx.gpa.allocSentinel(?[*:0]const u8, words.argv.len, null) catch bail(cmd, 1);
    for (words.argv, 0..) |a, i| argv[i] = (ctx.gpa.dupeSentinel(u8, a, 0) catch bail(cmd, 1)).ptr;
    const e = sys.execve(exe.ptr, argv.ptr, prep.envp);
    ctx.diag.err("{s}: cannot execute {s}: {t}", .{ unit.name.full, exe, e });
    bail(cmd, exit_exec);
}

const Role = enum { control, main };

fn forkRun(prep: *Prepared, cmd: model.Command) ?sys.Exit {
    switch (sys.fork()) {
        .child => execCommand(prep, cmd),
        .failed => |e| {
            prep.ctx.diag.err("{s}: cannot fork: {t}", .{ prep.unit.name.full, e });
            return null;
        },
        .parent => |pid| {
            forward_pid.store(pid, .seq_cst);
            const early = received_signal.load(.seq_cst);
            if (early != 0) sys.kill(pid, signalFromNumber(early));
            const result = sys.waitPid(pid);
            forward_pid.store(0, .seq_cst);
            return result;
        },
    }
}

fn succeeded(prep: *const Prepared, cmd: model.Command, exit: sys.Exit, role: Role) bool {
    if (cmd.flags.ignore_failure) return true;
    return switch (role) {
        .control => switch (exit) {
            .exited => |c| c == 0,
            .signaled => false,
        },
        .main => prep.success.accepts(exit),
    };
}

/// Runs the commands one after the other and stops at the first failure. Returns its exit
/// status, or null when all succeeded.
fn runSequence(prep: *Prepared, cmds: []const model.Command, role: Role) ?u8 {
    for (cmds) |cmd| {
        const sig = received_signal.load(.seq_cst);
        if (sig != 0) return @intCast(128 + sig);
        if (stop_requested.load(.seq_cst)) return 128 + @as(u8, @intCast(@backingInt(linux.SIG.TERM)));
        sys.reapOthers(forward_main.load(.seq_cst));
        const exit = forkRun(prep, cmd) orelse {
            if (cmd.flags.ignore_failure) continue;
            return 1;
        };
        if (!succeeded(prep, cmd, exit, role)) return exit.code();
    }
    return null;
}

fn startTimeoutMs(unit: model.Unit) ?u64 {
    const us = unit.timeout_start_sec orelse default_start_timeout_us;
    if (us == timespan.infinity) return null;
    return us / std.time.us_per_ms;
}

fn sleepMs(ctx: *const core.Context, ms: u64) void {
    ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

/// Waits for `PIDFile=` to name a live process; null on timeout or when interrupted.
fn waitForPidFile(prep: *Prepared, path: []const u8) ?Accepted {
    const ctx = prep.ctx;
    const began = Io.Timestamp.now(ctx.io, .awake);
    const limit_ms = startTimeoutMs(prep.unit);
    while (true) {
        if (readClaimedPid(ctx, path, prep.service_uid)) |accepted| return accepted;
        if (received_signal.load(.seq_cst) != 0) return null;
        if (limit_ms) |limit| {
            const elapsed_ms: u64 = @intCast(@max(0, began.untilNow(ctx.io, .awake).toMilliseconds()));
            if (elapsed_ms >= limit) return null;
        }
        sleepMs(ctx, pidfile_poll_ms);
    }
}

/// The stop of a followed process on request: `ExecStop=` with `$MAINPID`, whose failure does
/// not prevent the stop, then the termination with `KillSignal=` and the exit with the status
/// of the process. `KillMode=none` leaves the process alone.
fn stopFollowed(prep: *Prepared, pid: i32) u8 {
    const ctx = prep.ctx;
    const unit = prep.unit;
    stop_requested.store(false, .seq_cst);
    withMainPid(prep, pid) catch |e| ctx.diag.warn("{s}: cannot set MAINPID: {t}", .{ unit.name.full, e });
    if (runSequence(prep, unit.exec_stop, .control)) |code| ctx.diag.warn("{s}: ExecStop= failed with status {d}", .{ unit.name.full, code });
    if (unit.kill_mode == .none) return 0;
    terminateMain(prep, pid);
    const exit = sys.reapChild(pid) orelse return 0;
    sys.reapOthers(0);
    return if (prep.success.accepts(exit)) 0 else exit.code();
}

/// Control commands of a started unit see `$MAINPID` as in the stop phase.
fn withMainPid(prep: *Prepared, pid: i32) !void {
    const gpa = prep.ctx.gpa;
    const extra = [_]model.EnvVar{.{ .name = "MAINPID", .value = try std.fmt.allocPrint(gpa, "{d}", .{pid}) }};
    prep.vars = environment.build(prep.ctx, prep.unit, prep.ident.account, &extra) catch |e| switch (e) {
        error.EnvironmentFile => return error.EnvironmentFile,
        error.OutOfMemory => return error.OutOfMemory,
    };
    prep.envp = try buildEnvp(gpa, &prep.vars);
}

fn follow(prep: *Prepared, pid: i32) u8 {
    const ctx = prep.ctx;
    const fd = switch (sys.pidfdOpen(pid)) {
        .fd => |f| f,
        .failed => |e| return fail(ctx, "{s}: cannot follow process {d}: {t}", .{ prep.unit.name.full, pid, e }),
    };
    defer sys.closeFd(fd);
    forward_main.store(pid, .seq_cst);
    defer forward_main.store(0, .seq_cst);
    if (received_signal.load(.seq_cst) != 0) sys.kill(pid, signalFromNumber(received_signal.load(.seq_cst)));
    while (true) {
        const ready = sys.waitReadable(fd, reap_tick_ms) catch {
            ctx.diag.warn("{s}: cannot wait for process {d}", .{ prep.unit.name.full, pid });
            return 1;
        };
        sys.reapOthers(pid);
        if (stopsOnSignal(prep) and stop_requested.load(.seq_cst)) return stopFollowed(prep, pid);
        if (ready) break;
    }
    const exit = sys.reapChild(pid) orelse return 0;
    sys.reapOthers(0);
    return if (prep.success.accepts(exit)) 0 else exit.code();
}

fn startForking(prep: *Prepared) u8 {
    const ctx = prep.ctx;
    const unit = prep.unit;
    if (unit.exec_start.len == 0) return fail(ctx, "{s}: no ExecStart=", .{unit.name.full});
    if (unit.exec_start.len > 1) ctx.diag.warn("{s}: only the first ExecStart= is run for Type=forking", .{unit.name.full});
    const reaper = sys.childSubreaper();
    if (reaper != .SUCCESS) ctx.diag.warn("{s}: cannot become a subreaper: {t}", .{ unit.name.full, reaper });
    if (runSequence(prep, unit.exec_start[0..1], .main)) |code| return code;

    const pid_path = (pidFilePath(ctx, unit) catch null) orelse {
        ctx.diag.warn("{s}: Type=forking without PIDFile=: the service is started but not supervised", .{unit.name.full});
        return runSequence(prep, unit.exec_start_post, .control) orelse 0;
    };
    const accepted = waitForPidFile(prep, pid_path) orelse
        return fail(ctx, "{s}: no live process in {s} (timeout or interrupted)", .{ unit.name.full, pid_path });
    const pid = accepted.pid;
    prep.main_source = accepted.src;
    writeMainPid(ctx, unit, pid);
    forward_main.store(pid, .seq_cst);
    if (runSequence(prep, unit.exec_start_post, .control)) |code| {
        signalChecked(prep, pid, .TERM);
        return code;
    }
    return follow(prep, pid);
}

/// Forks the main command. With `wait_exec` it returns once the child has executed the
/// command (or died trying), observed through a close-on-exec pipe.
fn spawnMain(prep: *Prepared, cmd: model.Command, wait_exec: bool) ?i32 {
    var fds: [2]i32 = .{ -1, -1 };
    if (wait_exec and linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    switch (sys.fork()) {
        .child => execCommand(prep, cmd),
        .failed => |e| {
            prep.ctx.diag.err("{s}: cannot fork: {t}", .{ prep.unit.name.full, e });
            return null;
        },
        .parent => |pid| {
            forward_main.store(pid, .seq_cst);
            if (wait_exec) {
                sys.closeFd(fds[1]);
                var byte: [1]u8 = undefined;
                while (true) {
                    const rc = linux.read(fds[0], &byte, 1);
                    if (linux.errno(rc) != .INTR) break;
                }
                sys.closeFd(fds[0]);
            }
            return pid;
        },
    }
}

/// Runs the main command as a child so that `ExecStartPost=` can run, then stays resident as
/// its supervisor: signals are forwarded, orphans reaped and the exit status propagated.
fn supervise(prep: *Prepared, cmd: model.Command, wait_exec: bool) u8 {
    const ctx = prep.ctx;
    const unit = prep.unit;
    const reaper = sys.childSubreaper();
    if (reaper != .SUCCESS) ctx.diag.warn("{s}: cannot become a subreaper: {t}", .{ unit.name.full, reaper });
    const pid = spawnMain(prep, cmd, wait_exec) orelse
        return if (cmd.flags.ignore_failure) 0 else fail(ctx, "{s}: cannot start the main process", .{unit.name.full});
    writeMainPid(ctx, unit, pid);
    if (runSequence(prep, unit.exec_start_post, .control)) |code| {
        sys.kill(pid, .TERM);
        forward_main.store(0, .seq_cst);
        _ = sys.waitPid(pid);
        return code;
    }
    const code = follow(prep, pid);
    return if (cmd.flags.ignore_failure) 0 else code;
}

fn stopsOnSignal(prep: *const Prepared) bool {
    // A recording executor is the parent of the main process, so SIGTERM stops it as `ExecStop=` would.
    return (prep.stop_on_signal and prep.unit.exec_stop.len > 0) or prep.record_exit;
}

fn startSimple(prep: *Prepared) u8 {
    const ctx = prep.ctx;
    const unit = prep.unit;
    if (unit.exec_start.len == 0) return fail(ctx, "{s}: no ExecStart=", .{unit.name.full});
    if (unit.exec_start.len > 1) ctx.diag.warn("{s}: only the first ExecStart= is run for Type={t}", .{ unit.name.full, unit.service_type });
    if (unit.exec_start_post.len > 0 or stopsOnSignal(prep) or prep.record_exit) return supervise(prep, unit.exec_start[0], unit.service_type == .exec);
    execCommand(prep, unit.exec_start[0]);
}

fn startPhase(prep: *Prepared) u8 {
    installHandlers(stopsOnSignal(prep));
    writeMainPid(prep.ctx, prep.unit, linux.getpid());
    if (runSequence(prep, prep.unit.exec_start_pre, .control)) |code| return code;
    return switch (prep.unit.service_type) {
        .oneshot => runSequence(prep, prep.unit.exec_start, .main) orelse
            (runSequence(prep, prep.unit.exec_start_post, .control) orelse 0),
        .forking => startForking(prep),
        else => startSimple(prep),
    };
}

/// File the executor writes with `record_exit`: `ok <status>` when the main process ended in a
/// way `SuccessExitStatus=` accepts, `failed <status>` otherwise.
pub fn execExitPath(ctx: *const core.Context, unit_name: []const u8) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(ctx.gpa, "fake-systemd/{s}.exit", .{unit_name});
    return std.fs.path.join(ctx.gpa, &.{ if (ctx.scope == .user) ctx.xdg_runtime_dir else "/run", file });
}

fn removeExit(ctx: *core.Context, unit: model.Unit) void {
    const path = execExitPath(ctx, unit.name.full) catch return;
    ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => ctx.diag.warn("{s}: cannot remove {s}: {t}", .{ unit.name.full, path, e }),
    };
}

/// Written by the resident executor, which keeps its own identity while the service runs as its
/// account.
fn writeExit(ctx: *core.Context, unit: model.Unit, code: u8) void {
    const path = execExitPath(ctx, unit.name.full) catch return;
    const text = std.fmt.allocPrint(ctx.gpa, "{s} {d}\n", .{ if (code == 0) "ok" else "failed", code }) catch return;
    writeStateFile(ctx, path, text) catch |e| ctx.diag.warn("{s}: cannot write {s}: {t}", .{ unit.name.full, path, e });
}

/// Forks a `fake-systemd --log` child and points stdout and stderr at it. The child outlives
/// nothing: it ends when the last writer of the pipe is gone.
fn startLogger(prep: *Prepared) void {
    const ctx = prep.ctx;
    var fds: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        return ctx.diag.warn("{s}: cannot create the pipe to the logger", .{prep.unit.name.full});
    }
    switch (sys.fork()) {
        .child => {
            sys.closeFd(fds[1]);
            // Own session, so an init that kills the service's process group keeps the logger until EOF.
            if (linux.errno(linux.setsid()) != .SUCCESS) {
                ctx.diag.warn("{s}: logger stays in the service's process group", .{prep.unit.name.full});
            }
            sys.exitNow(logger.run(ctx, ctx.gpa, prep.unit.name.full, .{}, fds[0]));
        },
        .failed => |e| {
            ctx.diag.warn("{s}: cannot start the logger: {t}", .{ prep.unit.name.full, e });
            sys.closeFd(fds[0]);
            sys.closeFd(fds[1]);
        },
        .parent => {
            sys.closeFd(fds[0]);
            _ = linux.dup2(fds[1], 1);
            _ = linux.dup2(fds[1], 2);
            sys.closeFd(fds[1]);
        },
    }
}

/// Runs the start phase. When it returns, the main process has ended (or was never supervised),
/// so the pid file that named it goes.
fn start(prep: *Prepared) u8 {
    if (prep.record_exit) removeExit(prep.ctx, prep.unit);
    const code = startPhase(prep);
    removeExecPidFile(prep.ctx, prep.unit);
    if (prep.record_exit) writeExit(prep.ctx, prep.unit, code);
    return code;
}

fn control(prep: *Prepared, cmds: []const model.Command) u8 {
    installHandlers(false);
    return runSequence(prep, cmds, .control) orelse 0;
}

pub fn parseSignal(text: []const u8) ?linux.SIG {
    const t = std.mem.trim(u8, text, " \t");
    if (std.fmt.parseInt(u8, t, 10)) |n| {
        if (n == 0 or n >= 65) return null;
        return @fromBackingInt(@intCast(n));
    } else |_| {}
    return std.meta.stringToEnum(linux.SIG, if (std.mem.startsWith(u8, t, "SIG")) t[3..] else t);
}

fn stopTimeoutMs(unit: model.Unit) ?i32 {
    const us = unit.timeout_stop_sec orelse default_start_timeout_us;
    if (us == timespan.infinity) return null;
    return @intCast(@min(us / std.time.us_per_ms, std.math.maxInt(i32)));
}

/// A pidfd for `pid` when it is a process of the service. The pidfd pins that process: it is
/// checked to be running after the checks, so a pid that was recycled in the meantime is
/// never signalled.
fn openChecked(prep: *const Prepared, pid: i32) ?i32 {
    const fd = switch (sys.pidfdOpen(pid)) {
        .fd => |f| f,
        .failed => return null,
    };
    const running = procs.acceptable(pid, prep.main_source) and !(sys.waitReadable(fd, 0) catch true);
    if (running) return fd;
    sys.closeFd(fd);
    return null;
}

/// Signals the process of `pidfd`, or its whole process group when the process leads one that
/// is not ours: a group led by a process of the service holds only its descendants.
fn signalMain(unit: model.Unit, pidfd: i32, pid: i32, sig: linux.SIG) void {
    const own_group = linux.getpgid(0);
    const group = linux.getpgid(pid);
    const leads = unit.kill_mode != .process and group == @as(usize, @intCast(pid)) and group != own_group;
    if (leads) sys.kill(-pid, sig) else _ = sys.pidfdKill(pidfd, sig);
}

/// One signal to a process of the service, after the checks of `openChecked`.
fn signalChecked(prep: *const Prepared, pid: i32, sig: linux.SIG) void {
    const fd = openChecked(prep, pid) orelse return;
    defer sys.closeFd(fd);
    signalMain(prep.unit, fd, pid, sig);
}

const final_kill_wait_ms = 5000;

/// Sends `KillSignal=` and waits for the process to exit, escalating to SIGKILL after
/// `TimeoutStopSec=`. The process is not a child, so its exit is observed through a pidfd.
fn terminateMain(prep: *Prepared, pid: i32) void {
    const ctx = prep.ctx;
    const unit = prep.unit;
    if (unit.kill_mode == .none or procs.parentOf(pid) == null) return;
    const fd = openChecked(prep, pid) orelse {
        ctx.diag.warn("{s}: not signalling process {d}: it is not a live process of the service", .{ unit.name.full, pid });
        return;
    };
    defer sys.closeFd(fd);
    const sig = parseSignal(unit.kill_signal orelse "SIGTERM") orelse .TERM;
    signalMain(unit, fd, pid, sig);
    if (sys.waitReadable(fd, stopTimeoutMs(unit) orelse -1) catch true) return;
    ctx.diag.warn("{s}: process {d} did not stop in time, sending SIGKILL", .{ unit.name.full, pid });
    signalMain(unit, fd, pid, .KILL);
    if (!(sys.waitReadable(fd, final_kill_wait_ms) catch true)) ctx.diag.err("{s}: process {d} survived SIGKILL", .{ unit.name.full, pid });
}

fn removeExecPidFile(ctx: *core.Context, unit: model.Unit) void {
    const path = execPidPath(ctx, unit.name.full) catch return;
    ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => ctx.diag.warn("{s}: cannot remove {s}: {t}", .{ unit.name.full, path, e }),
    };
}

/// `ExecStop=` (a failure does not prevent the stop), then the main process is terminated.
/// Returns the exit status of the first `ExecStop=` command that failed.
fn stopMain(prep: *Prepared) ?u8 {
    installHandlers(false);
    const result = runSequence(prep, prep.unit.exec_stop, .control);
    if (prep.main_pid) |pid| terminateMain(prep, pid);
    return result;
}

/// `stopMain`, then `ExecStopPost=` runs and the runtime directories go. The exit status is
/// that of the first command that failed.
fn stopPhase(prep: *Prepared) u8 {
    const unit = prep.unit;
    var result: ?u8 = stopMain(prep);
    const post = runSequence(prep, unit.exec_stop_post, .control);
    result = result orelse post;
    removeExecPidFile(prep.ctx, unit);
    dirs.removeRuntime(prep.ctx, unit) catch |e| prep.ctx.diag.warn("{s}: {t}", .{ unit.name.full, e });
    return result orelse 0;
}

fn reloadPhase(prep: *Prepared) u8 {
    if (prep.unit.exec_reload.len == 0) return fail(prep.ctx, "{s}: no ExecReload= is defined", .{prep.unit.name.full});
    return control(prep, prep.unit.exec_reload);
}

fn runInner(ctx: *core.Context, req: Request) !u8 {
    var db_error: ?anyerror = null;
    const db = accounts.Db.load(ctx.gpa, ctx.fs.*) catch |e| blk: {
        db_error = e;
        break :blk accounts.Db{};
    };
    const unit = loadUnit(ctx, req.unit) catch |e| return fail(ctx, "{s}: cannot load the unit: {t}", .{ req.unit, e });
    // As root the accounts decide who the service runs as, so a database that cannot be read must
    // not read as "no such account".
    const names_account = unit.user != null or unit.group != null or unit.supplementary_groups.len > 0;
    if (db_error) |e| if (names_account and linux.geteuid() == 0 and !req.identity_set and req.identity == null) {
        ctx.diag.err("{s}: cannot read /etc/passwd or /etc/group: {t}", .{ unit.name.full, e });
        return if (unit.user != null) 217 else 216;
    };
    var prep: Prepared = undefined;
    if (try prepare(ctx, unit, db, req.phase, req, &prep)) |code| return code;
    prep.stop_on_signal = req.stop_on_signal;
    prep.record_exit = req.record_exit;
    if (req.log and req.phase == .start) startLogger(&prep);
    return switch (req.phase) {
        .start => start(&prep),
        .stop => stopPhase(&prep),
        .@"stop-main" => stopMain(&prep) orelse 0,
        .reload => reloadPhase(&prep),
        .@"stop-post" => blk: {
            const code = control(&prep, unit.exec_stop_post);
            removeExecPidFile(ctx, unit);
            try dirs.removeRuntime(ctx, unit);
            break :blk code;
        },
    };
}

/// Runs one phase of the unit and returns the exit status. A successful `start` of a simple
/// service does not return: the process becomes the service.
pub fn run(ctx: *core.Context, req: Request) u8 {
    return runInner(ctx, req) catch |e| fail(ctx, "{s}: {t}", .{ req.unit, e });
}

const testing = std.testing;

test "success set defaults and parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var unknown: std.ArrayList([]const u8) = .empty;
    const def = try SuccessSet.parse(&.{}, &unknown, arena.allocator());
    try testing.expect(def.accepts(.{ .exited = 0 }));
    try testing.expect(!def.accepts(.{ .exited = 1 }));
    try testing.expect(def.accepts(.{ .signaled = 15 }));
    try testing.expect(def.accepts(.{ .signaled = 13 }));
    try testing.expect(!def.accepts(.{ .signaled = 9 }));
    const set = try SuccessSet.parse(&.{ "2", "143", "SIGUSR1", "KILL", "NOSUCH", "999" }, &unknown, arena.allocator());
    try testing.expect(set.accepts(.{ .exited = 2 }));
    try testing.expect(set.accepts(.{ .exited = 143 }));
    try testing.expect(set.accepts(.{ .signaled = 10 }));
    try testing.expect(set.accepts(.{ .signaled = 9 }));
    try testing.expectEqual(@as(usize, 2), unknown.items.len);
    try testing.expectEqualStrings("NOSUCH", unknown.items[0]);
}

test "executable lookup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const abs = (try findExecutable(arena.allocator(), "/nonexistent/x")).?;
    try testing.expectEqualStrings("/nonexistent/x", abs);
    const sh = (try findExecutable(arena.allocator(), "sh")).?;
    try testing.expect(std.mem.endsWith(u8, sh, "/sh"));
    try testing.expect((try findExecutable(arena.allocator(), "definitely-not-a-program")) == null);
    try testing.expect((try findExecutable(arena.allocator(), "bin/sh")) == null);
}

fn testPrepared(vars: *const expand.Vars, ctx: *core.Context) Prepared {
    return .{
        .ctx = ctx,
        .unit = .{ .name = undefined, .scope = .system },
        .vars = vars.*,
        .envp = undefined,
        .ident = .{},
        .cwd = null,
        .limit_list = &.{},
        .umask = 0o022,
        .success = .{},
    };
}

const ArgvEnv = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: core.Fs,
    env: std.process.Environ.Map,
    err: Io.Writer.Allocating,
    diag: core.Diag,
    ctx: core.Context,
    vars: expand.Vars,

    fn init(t: *ArgvEnv) !void {
        t.arena = .init(testing.allocator);
        t.tmp = testing.tmpDir(.{});
        t.fs = .initDir(testing.io, t.tmp.dir);
        t.env = .init(testing.allocator);
        t.err = .init(testing.allocator);
        t.diag = .init(&t.err.writer, .notice);
        t.ctx = try .init(t.arena.allocator(), testing.io, &t.fs, &t.diag, &t.env, .system, 0);
        t.vars = .empty;
        try t.vars.put(t.arena.allocator(), "OPTS", "-a -b");
        try t.vars.put(t.arena.allocator(), "ONE", "one two");
    }

    fn deinit(t: *ArgvEnv) void {
        t.err.deinit();
        t.env.deinit();
        t.tmp.cleanup();
        t.arena.deinit();
    }
};

fn expectArgv(t: *ArgvEnv, flags: model.Command, path: []const u8, argv: []const []const u8) !void {
    const prep = testPrepared(&t.vars, &t.ctx);
    const got = try commandArgv(&prep, flags);
    try testing.expectEqualStrings(path, got.path);
    try testing.expectEqual(argv.len, got.argv.len);
    for (argv, got.argv) |want, have| try testing.expectEqualStrings(want, have);
}

test "command line expansion and prefixes" {
    var t: ArgvEnv = undefined;
    try t.init();
    defer t.deinit();
    try expectArgv(&t, .{ .flags = .{}, .words = &.{ "/bin/x", "$OPTS", "${ONE}", "$$HOME" } }, "/bin/x", &.{ "/bin/x", "-a", "-b", "one two", "$HOME" });
    try expectArgv(&t, .{ .flags = .{ .no_expand = true }, .words = &.{ "/bin/x", "$OPTS", "$$" } }, "/bin/x", &.{ "/bin/x", "$OPTS", "$$" });
    try expectArgv(&t, .{ .flags = .{ .argv0 = true }, .words = &.{ "/bin/x", "custom", "$OPTS" } }, "/bin/x", &.{ "custom", "-a", "-b" });
    try expectArgv(&t, .{ .flags = .{ .argv0 = true }, .words = &.{ "/bin/x", "${ONE}" } }, "/bin/x", &.{"one two"});
    try expectArgv(&t, .{ .flags = .{}, .words = &.{"$ONE"} }, "$ONE", &.{"$ONE"});
}

test "working directory resolution" {
    var t: ArgvEnv = undefined;
    try t.init();
    defer t.deinit();
    try t.vars.put(t.arena.allocator(), "HOME", "/home/svc");
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    try testing.expectEqualStrings("/", (try resolveCwd(&t.ctx, unit, .{}, &t.vars)).?.path);
    unit.working_directory = "/srv/app";
    try testing.expectEqualStrings("/srv/app", (try resolveCwd(&t.ctx, unit, .{}, &t.vars)).?.path);
    unit.working_directory = "~";
    try testing.expectEqualStrings("/home/svc", (try resolveCwd(&t.ctx, unit, .{}, &t.vars)).?.path);
    const ident: identity.Identity = .{ .account = .{ .name = "svc", .uid = 1, .gid = 1, .home = "/var/lib/svc" } };
    try testing.expectEqualStrings("/var/lib/svc", (try resolveCwd(&t.ctx, unit, ident, &t.vars)).?.path);
    unit.working_directory = "-/maybe";
    const optional = (try resolveCwd(&t.ctx, unit, .{}, &t.vars)).?;
    try testing.expect(optional.optional);
    try testing.expectEqualStrings("/maybe", optional.path);
    unit.working_directory = "relative";
    try testing.expectError(error.InvalidWorkingDirectory, resolveCwd(&t.ctx, unit, .{}, &t.vars));
    unit.working_directory = "-relative";
    try testing.expect((try resolveCwd(&t.ctx, unit, .{}, &t.vars)) == null);
}

test "main process success depends on SuccessExitStatus, control commands do not" {
    var t: ArgvEnv = undefined;
    try t.init();
    defer t.deinit();
    var prep = testPrepared(&t.vars, &t.ctx);
    var unknown: std.ArrayList([]const u8) = .empty;
    prep.success = try SuccessSet.parse(&.{"3"}, &unknown, t.arena.allocator());
    const plain: model.Command = .{ .flags = .{}, .words = &.{"/bin/x"} };
    const optional: model.Command = .{ .flags = .{ .ignore_failure = true }, .words = &.{"/bin/x"} };
    try testing.expect(succeeded(&prep, plain, .{ .exited = 3 }, .main));
    try testing.expect(!succeeded(&prep, plain, .{ .exited = 3 }, .control));
    try testing.expect(!succeeded(&prep, plain, .{ .exited = 1 }, .main));
    try testing.expect(succeeded(&prep, optional, .{ .exited = 1 }, .control));
    try testing.expect(succeeded(&prep, optional, .{ .signaled = 9 }, .main));
}

test "kill signal names" {
    try testing.expectEqual(linux.SIG.TERM, parseSignal("SIGTERM").?);
    try testing.expectEqual(linux.SIG.INT, parseSignal("INT").?);
    try testing.expectEqual(linux.SIG.HUP, parseSignal("1").?);
    try testing.expect(parseSignal("SIGNOPE") == null);
    try testing.expect(parseSignal("0") == null);
    try testing.expect(parseSignal("200") == null);
}

test "pid file locations" {
    var t: ArgvEnv = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectEqualStrings("/run/fake-systemd/a.service.pid", try execPidPath(&t.ctx, "a.service"));
    t.ctx.scope = .user;
    t.ctx.xdg_runtime_dir = "/run/user/5";
    try testing.expectEqualStrings("/run/user/5/fake-systemd/a.service.pid", try execPidPath(&t.ctx, "a.service"));
}
