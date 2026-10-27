// SPDX-License-Identifier: GPL-3.0-or-later
//! Backend-independent unit model (§6.4): the merged, specifier-expanded settings of a resolved
//! unit plus the directives that were recognized but not translated.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");
const types = @import("../core/types.zig");
const ini = @import("ini.zig");
const name_mod = @import("name.zig");
const execline = @import("execline.zig");
const specifier = @import("specifier.zig");
const timespan = @import("timespan.zig");
const resolve = @import("resolve.zig");

pub const Name = name_mod.Name;
pub const Command = execline.Command;
pub const Scope = types.Scope;

pub const ServiceType = enum { simple, exec, forking, oneshot, dbus, notify, @"notify-reload", idle };
pub const Restart = enum { no, @"on-success", @"on-failure", @"on-abnormal", @"on-watchdog", @"on-abort", always };
pub const KillMode = enum { @"control-group", process, mixed, none };
pub const DirectoryPreserve = enum { no, yes, restart };

pub const EnvVar = struct { name: []const u8, value: []const u8 };
pub const EnvFile = struct { path: []const u8, optional: bool };
pub const Limit = struct { key: []const u8, value: []const u8 };
pub const Directive = struct { key: []const u8, value: []const u8 };

pub const IssueKind = enum {
    unknown_key,
    unknown_section,
    /// Known directive without a translation that does not change behavior.
    ignored_key,
    sandbox_key,
    resource_key,
    /// Ignored directive that changes what the service does.
    behavior_key,
    invalid_value,
    invalid_specifier,
    syntax,
};

pub const Issue = struct {
    kind: IssueKind,
    section: []const u8,
    key: []const u8,
    file: u32,
    line: u32,
    detail: []const u8 = "",
};

pub const Timer = struct {
    on_calendar: []const []const u8 = &.{},
    on_boot_sec: []const u64 = &.{},
    on_startup_sec: []const u64 = &.{},
    on_active_sec: []const u64 = &.{},
    on_unit_active_sec: []const u64 = &.{},
    on_unit_inactive_sec: []const u64 = &.{},
    persistent: bool = false,
    randomized_delay_sec: ?u64 = null,
    fixed_random_delay: bool = false,
    accuracy_sec: ?u64 = null,
    unit: ?[]const u8 = null,
};

pub const Unit = struct {
    name: Name,
    scope: Scope,
    /// Fragment and drop-ins; `Issue.file` indexes this list.
    files: []const resolve.FileRef = &.{},

    // [Unit]
    description: ?[]const u8 = null,
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
    requires: []const []const u8 = &.{},
    wants: []const []const u8 = &.{},
    binds_to: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    part_of: []const []const u8 = &.{},
    default_dependencies: bool = true,
    /// `Condition*=` and `Assert*=` assignments in order.
    conditions: []const Directive = &.{},

    // [Service]
    service_type: ServiceType = .simple,
    exec_start_pre: []const Command = &.{},
    exec_start: []const Command = &.{},
    exec_start_post: []const Command = &.{},
    exec_reload: []const Command = &.{},
    exec_stop: []const Command = &.{},
    exec_stop_post: []const Command = &.{},
    environment: []const EnvVar = &.{},
    environment_file: []const EnvFile = &.{},
    pass_environment: []const []const u8 = &.{},
    unset_environment: []const []const u8 = &.{},
    user: ?[]const u8 = null,
    group: ?[]const u8 = null,
    supplementary_groups: []const []const u8 = &.{},
    working_directory: ?[]const u8 = null,
    umask: ?u16 = null,
    nice: ?i8 = null,
    limits: []const Limit = &.{},
    no_new_privileges: ?bool = null,
    runtime_directory: []const []const u8 = &.{},
    state_directory: []const []const u8 = &.{},
    cache_directory: []const []const u8 = &.{},
    logs_directory: []const []const u8 = &.{},
    configuration_directory: []const []const u8 = &.{},
    runtime_directory_mode: ?u16 = null,
    state_directory_mode: ?u16 = null,
    cache_directory_mode: ?u16 = null,
    logs_directory_mode: ?u16 = null,
    configuration_directory_mode: ?u16 = null,
    runtime_directory_preserve: ?DirectoryPreserve = null,
    restart: Restart = .no,
    /// Microseconds; `timespan.infinity` for `infinity` and for `0` in the timeout settings.
    restart_sec: ?u64 = null,
    timeout_start_sec: ?u64 = null,
    timeout_stop_sec: ?u64 = null,
    kill_signal: ?[]const u8 = null,
    kill_mode: KillMode = .@"control-group",
    success_exit_status: []const []const u8 = &.{},
    pid_file: ?[]const u8 = null,
    bus_name: ?[]const u8 = null,
    remain_after_exit: bool = false,

    // [Install]
    has_install: bool = false,
    wanted_by: []const []const u8 = &.{},
    required_by: []const []const u8 = &.{},
    also: []const []const u8 = &.{},
    alias: []const []const u8 = &.{},
    default_instance: ?[]const u8 = null,

    // [Timer]
    timer: Timer = .{},

    issues: []const Issue = &.{},

    pub fn countIssues(u: Unit, kind: IssueKind) usize {
        var n: usize = 0;
        for (u.issues) |i| {
            if (i.kind == kind) n += 1;
        }
        return n;
    }
};

pub const UserLookup = struct {
    context: ?*anyopaque = null,
    lookup: *const fn (context: ?*anyopaque, name: []const u8) ?specifier.UserInfo,
};

pub const Options = struct {
    env: specifier.Env,
    /// Resolves `User=` to an account for `%U`, `%g`, `%G`, `%h`.
    user_lookup: ?UserLookup = null,
};

/// Reads the files of `resolved` through `fs` and builds the model.
pub fn load(gpa: Allocator, fs: Fs, resolved: resolve.Resolved, opts: Options) !Unit {
    switch (resolved.state) {
        .not_found => return error.UnitNotFound,
        .masked => return error.UnitMasked,
        .found => {},
    }
    var doc: ini.Document = .empty;
    for (resolved.files, 0..) |ref, i| {
        const content = fs.readFileAlloc(gpa, ref.read_path, resolve.max_unit_file_size) catch |e| switch (e) {
            error.StreamTooLong => return error.UnitFileTooLarge,
            else => return e,
        };
        try ini.parse(gpa, &doc, content, @intCast(i));
    }
    return fromDocument(gpa, resolved.name, resolved.files, doc, opts);
}

const ListId = enum {
    after,
    before,
    requires,
    wants,
    binds_to,
    conflicts,
    part_of,
    wanted_by,
    required_by,
    also,
    alias,
    pass_environment,
    unset_environment,
    supplementary_groups,
    success_exit_status,
    runtime_directory,
    state_directory,
    cache_directory,
    logs_directory,
    configuration_directory,
    on_calendar,
};

const ListKey = struct { section: []const u8, key: []const u8, id: ListId };

const list_keys = [_]ListKey{
    .{ .section = "Unit", .key = "After", .id = .after },
    .{ .section = "Unit", .key = "Before", .id = .before },
    .{ .section = "Unit", .key = "Requires", .id = .requires },
    .{ .section = "Unit", .key = "Wants", .id = .wants },
    .{ .section = "Unit", .key = "BindsTo", .id = .binds_to },
    .{ .section = "Unit", .key = "Conflicts", .id = .conflicts },
    .{ .section = "Unit", .key = "PartOf", .id = .part_of },
    .{ .section = "Install", .key = "WantedBy", .id = .wanted_by },
    .{ .section = "Install", .key = "RequiredBy", .id = .required_by },
    .{ .section = "Install", .key = "Also", .id = .also },
    .{ .section = "Install", .key = "Alias", .id = .alias },
    .{ .section = "Service", .key = "PassEnvironment", .id = .pass_environment },
    .{ .section = "Service", .key = "UnsetEnvironment", .id = .unset_environment },
    .{ .section = "Service", .key = "SupplementaryGroups", .id = .supplementary_groups },
    .{ .section = "Service", .key = "SuccessExitStatus", .id = .success_exit_status },
    .{ .section = "Service", .key = "RuntimeDirectory", .id = .runtime_directory },
    .{ .section = "Service", .key = "StateDirectory", .id = .state_directory },
    .{ .section = "Service", .key = "CacheDirectory", .id = .cache_directory },
    .{ .section = "Service", .key = "LogsDirectory", .id = .logs_directory },
    .{ .section = "Service", .key = "ConfigurationDirectory", .id = .configuration_directory },
    .{ .section = "Timer", .key = "OnCalendar", .id = .on_calendar },
};

const ExecId = enum { exec_start_pre, exec_start, exec_start_post, exec_reload, exec_stop, exec_stop_post };

const exec_keys = [_]struct { key: []const u8, id: ExecId }{
    .{ .key = "ExecStartPre", .id = .exec_start_pre },
    .{ .key = "ExecStart", .id = .exec_start },
    .{ .key = "ExecStartPost", .id = .exec_start_post },
    .{ .key = "ExecReload", .id = .exec_reload },
    .{ .key = "ExecStop", .id = .exec_stop },
    .{ .key = "ExecStopPost", .id = .exec_stop_post },
};

const SpanId = enum { on_boot_sec, on_startup_sec, on_active_sec, on_unit_active_sec, on_unit_inactive_sec };

const span_keys = [_]struct { key: []const u8, id: SpanId }{
    .{ .key = "OnBootSec", .id = .on_boot_sec },
    .{ .key = "OnStartupSec", .id = .on_startup_sec },
    .{ .key = "OnActiveSec", .id = .on_active_sec },
    .{ .key = "OnUnitActiveSec", .id = .on_unit_active_sec },
    .{ .key = "OnUnitInactiveSec", .id = .on_unit_inactive_sec },
};

const DirId = enum { runtime, state, cache, logs, configuration };

const dir_mode_keys = [_]struct { key: []const u8, id: DirId }{
    .{ .key = "RuntimeDirectoryMode", .id = .runtime },
    .{ .key = "StateDirectoryMode", .id = .state },
    .{ .key = "CacheDirectoryMode", .id = .cache },
    .{ .key = "LogsDirectoryMode", .id = .logs },
    .{ .key = "ConfigurationDirectoryMode", .id = .configuration },
};

const Builder = struct {
    gpa: Allocator,
    ctx: specifier.Context,
    unit: Unit,
    lists: [std.meta.tags(ListId).len]std.ArrayList([]const u8) = @splat(.empty),
    execs: [std.meta.tags(ExecId).len]std.ArrayList(Command) = @splat(.empty),
    spans: [std.meta.tags(SpanId).len]std.ArrayList(u64) = @splat(.empty),
    conditions: std.ArrayList(Directive) = .empty,
    env: std.ArrayList(EnvVar) = .empty,
    env_files: std.ArrayList(EnvFile) = .empty,
    limits: std.ArrayList(Limit) = .empty,
    issues: std.ArrayList(Issue) = .empty,
    unknown_sections: std.ArrayList([]const u8) = .empty,
    /// Suppresses issue recording during the `User=` pre-scan.
    quiet: bool = false,

    fn issue(b: *Builder, kind: IssueKind, e: ini.Entry, detail: []const u8) Allocator.Error!void {
        if (b.quiet) return;
        try b.issues.append(b.gpa, .{
            .kind = kind,
            .section = e.section,
            .key = e.key,
            .file = e.file,
            .line = e.line,
            .detail = detail,
        });
    }

    /// Expands specifiers in `text`; records an issue and returns null on failure.
    fn expand(b: *Builder, e: ini.Entry, text: []const u8) Allocator.Error!?[]const u8 {
        var failure: specifier.Failure = .{};
        return specifier.expand(b.gpa, b.ctx, text, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TrailingPercent => {
                try b.issue(.invalid_specifier, e, "trailing '%'");
                return null;
            },
            error.UnknownSpecifier => {
                const d = try std.fmt.allocPrint(b.gpa, "unknown specifier %{c}", .{failure.specifier});
                try b.issue(.invalid_specifier, e, d);
                return null;
            },
            error.Unresolved => {
                const d = try std.fmt.allocPrint(b.gpa, "specifier %{c} cannot be resolved", .{failure.specifier});
                try b.issue(.invalid_specifier, e, d);
                return null;
            },
        };
    }

    fn invalid(b: *Builder, e: ini.Entry, what: []const u8) Allocator.Error!void {
        const d = try std.fmt.allocPrint(b.gpa, "invalid {s} '{s}'", .{ what, e.value });
        try b.issue(.invalid_value, e, d);
    }

    fn words(b: *Builder, e: ini.Entry) Allocator.Error!?[]const []const u8 {
        const split = execline.splitWords(b.gpa, e.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try b.issue(.invalid_value, e, @errorName(err));
                return null;
            },
        };
        const out = try b.gpa.alloc([]const u8, split.len);
        for (split, out) |w, *o| o.* = (try b.expand(e, w)) orelse return null;
        return out;
    }

    fn boolean(b: *Builder, e: ini.Entry) Allocator.Error!?bool {
        const v = parseBool(e.value) orelse {
            try b.invalid(e, "boolean");
            return null;
        };
        return v;
    }

    fn span(b: *Builder, e: ini.Entry) Allocator.Error!?u64 {
        const v = (try b.expand(e, e.value)) orelse return null;
        return timespan.parse(v) catch {
            try b.invalid(e, "time span");
            return null;
        };
    }

    fn octal(b: *Builder, e: ini.Entry) Allocator.Error!?u16 {
        const v = std.fmt.parseInt(u16, e.value, 8) catch {
            try b.invalid(e, "octal mode");
            return null;
        };
        if (v > 0o7777) {
            try b.invalid(e, "octal mode");
            return null;
        }
        return v;
    }

    /// An account or group name. A name that starts with `-` is reported and kept, so that every
    /// consumer refuses it instead of running the service as root.
    fn account(b: *Builder, e: ini.Entry) Allocator.Error!?[]const u8 {
        const v = (try b.scalar(e)) orelse return null;
        if (v.len > 0 and v[0] == '-') try b.invalid(e, "account name");
        return v;
    }

    fn scalar(b: *Builder, e: ini.Entry) Allocator.Error!?[]const u8 {
        if (e.value.len == 0) return null;
        return try b.expand(e, e.value);
    }

    fn setEnv(b: *Builder, name: []const u8, value: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < b.env.items.len) {
            if (std.mem.eql(u8, b.env.items[i].name, name)) _ = b.env.orderedRemove(i) else i += 1;
        }
        try b.env.append(b.gpa, .{ .name = name, .value = value });
    }

    fn apply(b: *Builder, e: ini.Entry) Allocator.Error!void {
        for (list_keys) |lk| {
            if (std.mem.eql(u8, lk.section, e.section) and std.mem.eql(u8, lk.key, e.key)) {
                return b.applyList(lk.id, e);
            }
        }
        if (std.mem.eql(u8, e.section, "Unit")) return b.applyUnit(e);
        if (std.mem.eql(u8, e.section, "Service")) return b.applyService(e);
        if (std.mem.eql(u8, e.section, "Install")) return b.applyInstall(e);
        if (std.mem.eql(u8, e.section, "Timer")) return b.applyTimer(e);
    }

    fn applyList(b: *Builder, id: ListId, e: ini.Entry) Allocator.Error!void {
        const list = &b.lists[@backingInt(id)];
        if (e.value.len == 0) {
            list.clearRetainingCapacity();
            return;
        }
        if (id == .on_calendar) {
            if (try b.expand(e, e.value)) |v| try list.append(b.gpa, v);
            return;
        }
        const ws = (try b.words(e)) orelse return;
        if (id == .supplementary_groups) for (ws) |w| if (w.len > 0 and w[0] == '-') try b.invalid(e, "group name");
        try list.appendSlice(b.gpa, ws);
    }

    fn applyUnit(b: *Builder, e: ini.Entry) Allocator.Error!void {
        const u = &b.unit;
        if (eq(e.key, "Description")) {
            u.description = try b.scalar(e);
        } else if (eq(e.key, "DefaultDependencies")) {
            u.default_dependencies = if (e.value.len == 0) true else (try b.boolean(e)) orelse u.default_dependencies;
        } else if (std.mem.startsWith(u8, e.key, "Condition") or std.mem.startsWith(u8, e.key, "Assert")) {
            if (e.value.len == 0) {
                b.conditions.clearRetainingCapacity();
            } else if (try b.expand(e, e.value)) |v| {
                try b.conditions.append(b.gpa, .{ .key = e.key, .value = v });
            }
        } else {
            try b.unknownKey(e);
        }
    }

    fn applyInstall(b: *Builder, e: ini.Entry) Allocator.Error!void {
        if (eq(e.key, "DefaultInstance")) {
            b.unit.default_instance = try b.scalar(e);
        } else {
            try b.unknownKey(e);
        }
    }

    fn applyTimer(b: *Builder, e: ini.Entry) Allocator.Error!void {
        const t = &b.unit.timer;
        for (span_keys) |sk| {
            if (eq(e.key, sk.key)) {
                const list = &b.spans[@backingInt(sk.id)];
                if (e.value.len == 0) {
                    list.clearRetainingCapacity();
                } else if (try b.span(e)) |v| {
                    try list.append(b.gpa, v);
                }
                return;
            }
        }
        if (eq(e.key, "Persistent")) {
            t.persistent = if (e.value.len == 0) false else (try b.boolean(e)) orelse t.persistent;
        } else if (eq(e.key, "FixedRandomDelay")) {
            t.fixed_random_delay = if (e.value.len == 0) false else (try b.boolean(e)) orelse t.fixed_random_delay;
        } else if (eq(e.key, "RandomizedDelaySec")) {
            t.randomized_delay_sec = if (e.value.len == 0) null else try b.span(e);
        } else if (eq(e.key, "AccuracySec")) {
            t.accuracy_sec = if (e.value.len == 0) null else try b.span(e);
            try b.issue(.ignored_key, e, "");
        } else if (eq(e.key, "Unit")) {
            t.unit = try b.scalar(e);
        } else if (eq(e.key, "WakeSystem") or eq(e.key, "OnClockChange") or eq(e.key, "OnTimezoneChange")) {
            try b.issue(.behavior_key, e, "");
        } else if (eq(e.key, "RemainAfterElapse")) {
            try b.issue(.ignored_key, e, "");
        } else {
            try b.unknownKey(e);
        }
    }

    fn applyService(b: *Builder, e: ini.Entry) Allocator.Error!void {
        const u = &b.unit;
        for (exec_keys) |xk| {
            if (eq(e.key, xk.key)) return b.applyExec(xk.id, e);
        }
        for (dir_mode_keys) |dk| {
            if (eq(e.key, dk.key)) {
                const mode: ?u16 = if (e.value.len == 0) null else try b.octal(e);
                switch (dk.id) {
                    .runtime => u.runtime_directory_mode = mode,
                    .state => u.state_directory_mode = mode,
                    .cache => u.cache_directory_mode = mode,
                    .logs => u.logs_directory_mode = mode,
                    .configuration => u.configuration_directory_mode = mode,
                }
                return;
            }
        }
        if (eq(e.key, "Type")) {
            if (e.value.len == 0) {
                u.service_type = .simple;
            } else if (std.meta.stringToEnum(ServiceType, e.value)) |t| {
                u.service_type = t;
            } else try b.invalid(e, "service type");
        } else if (eq(e.key, "Restart")) {
            if (e.value.len == 0) {
                u.restart = .no;
            } else if (std.meta.stringToEnum(Restart, e.value)) |r| {
                u.restart = r;
            } else try b.invalid(e, "restart setting");
        } else if (eq(e.key, "KillMode")) {
            if (e.value.len == 0) {
                u.kill_mode = .@"control-group";
            } else if (std.meta.stringToEnum(KillMode, e.value)) |k| {
                u.kill_mode = k;
            } else try b.invalid(e, "kill mode");
        } else if (eq(e.key, "RuntimeDirectoryPreserve")) {
            if (e.value.len == 0) {
                u.runtime_directory_preserve = null;
            } else if (std.meta.stringToEnum(DirectoryPreserve, e.value)) |p| {
                u.runtime_directory_preserve = p;
            } else if (parseBool(e.value)) |v| {
                u.runtime_directory_preserve = if (v) .yes else .no;
            } else try b.invalid(e, "preserve mode");
        } else if (eq(e.key, "RemainAfterExit")) {
            u.remain_after_exit = if (e.value.len == 0) false else (try b.boolean(e)) orelse u.remain_after_exit;
        } else if (eq(e.key, "NoNewPrivileges")) {
            u.no_new_privileges = if (e.value.len == 0) null else try b.boolean(e);
        } else if (eq(e.key, "RestartSec")) {
            u.restart_sec = if (e.value.len == 0) null else try b.span(e);
        } else if (eq(e.key, "TimeoutStartSec")) {
            u.timeout_start_sec = if (e.value.len == 0) null else zeroIsInfinity(try b.span(e));
        } else if (eq(e.key, "TimeoutStopSec")) {
            u.timeout_stop_sec = if (e.value.len == 0) null else zeroIsInfinity(try b.span(e));
        } else if (eq(e.key, "TimeoutSec")) {
            const v: ?u64 = if (e.value.len == 0) null else zeroIsInfinity(try b.span(e));
            u.timeout_start_sec = v;
            u.timeout_stop_sec = v;
        } else if (eq(e.key, "KillSignal")) {
            u.kill_signal = try b.scalar(e);
        } else if (eq(e.key, "User")) {
            u.user = try b.account(e);
        } else if (eq(e.key, "Group")) {
            u.group = try b.account(e);
        } else if (eq(e.key, "WorkingDirectory")) {
            u.working_directory = try b.scalar(e);
        } else if (eq(e.key, "PIDFile")) {
            u.pid_file = try b.scalar(e);
        } else if (eq(e.key, "BusName")) {
            u.bus_name = try b.scalar(e);
        } else if (eq(e.key, "UMask")) {
            u.umask = if (e.value.len == 0) null else try b.octal(e);
        } else if (eq(e.key, "Nice")) {
            if (e.value.len == 0) {
                u.nice = null;
            } else if (std.fmt.parseInt(i8, e.value, 10)) |n| {
                if (n >= -20 and n <= 19) u.nice = n else try b.invalid(e, "nice level");
            } else |_| try b.invalid(e, "nice level");
        } else if (eq(e.key, "Environment")) {
            try b.applyEnvironment(e);
        } else if (eq(e.key, "EnvironmentFile")) {
            if (e.value.len == 0) {
                b.env_files.clearRetainingCapacity();
            } else {
                const optional = e.value[0] == '-';
                const raw = if (optional) std.mem.trimStart(u8, e.value[1..], " \t") else e.value;
                if (try b.expand(e, raw)) |p| try b.env_files.append(b.gpa, .{ .path = p, .optional = optional });
            }
        } else if (std.mem.startsWith(u8, e.key, "Limit") and e.key.len > "Limit".len) {
            try b.applyLimit(e);
        } else {
            try b.unknownKey(e);
        }
    }

    fn applyExec(b: *Builder, id: ExecId, e: ini.Entry) Allocator.Error!void {
        const list = &b.execs[@backingInt(id)];
        if (e.value.len == 0) {
            list.clearRetainingCapacity();
            return;
        }
        const cmds = execline.parseAll(b.gpa, e.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const d = try std.fmt.allocPrint(b.gpa, "{s}", .{@errorName(err)});
                try b.issue(.invalid_value, e, d);
                return;
            },
        };
        next: for (cmds) |cmd| {
            const expanded = try b.gpa.alloc([]const u8, cmd.words.len);
            for (cmd.words, expanded) |w, *o| o.* = (try b.expand(e, w)) orelse continue :next;
            try list.append(b.gpa, .{ .flags = cmd.flags, .words = expanded });
        }
    }

    fn applyEnvironment(b: *Builder, e: ini.Entry) Allocator.Error!void {
        if (e.value.len == 0) {
            b.env.clearRetainingCapacity();
            return;
        }
        const ws = (try b.words(e)) orelse return;
        for (ws) |w| {
            const eqp = std.mem.findScalar(u8, w, '=') orelse {
                try b.issue(.invalid_value, e, try std.fmt.allocPrint(b.gpa, "assignment '{s}' lacks '='", .{w}));
                continue;
            };
            if (!isEnvName(w[0..eqp])) {
                try b.issue(.invalid_value, e, try std.fmt.allocPrint(b.gpa, "invalid variable name '{s}'", .{w[0..eqp]}));
                continue;
            }
            try b.setEnv(w[0..eqp], w[eqp + 1 ..]);
        }
    }

    fn applyLimit(b: *Builder, e: ini.Entry) Allocator.Error!void {
        var i: usize = 0;
        while (i < b.limits.items.len) {
            if (std.mem.eql(u8, b.limits.items[i].key, e.key)) _ = b.limits.orderedRemove(i) else i += 1;
        }
        if (e.value.len == 0) return;
        if (try b.expand(e, e.value)) |v| try b.limits.append(b.gpa, .{ .key = e.key, .value = v });
    }

    fn unknownKey(b: *Builder, e: ini.Entry) Allocator.Error!void {
        if (isExtension(e.key)) return;
        try b.issue(classifyKey(e.section, e.key), e, "");
    }

    fn finish(b: *Builder) Allocator.Error!Unit {
        var u = b.unit;
        inline for (comptime std.meta.tags(ListId)) |id| {
            const items = try b.lists[@backingInt(id)].toOwnedSlice(b.gpa);
            if (id == .on_calendar) u.timer.on_calendar = items else @field(u, @tagName(id)) = items;
        }
        inline for (comptime std.meta.tags(ExecId)) |id| {
            @field(u, @tagName(id)) = try b.execs[@backingInt(id)].toOwnedSlice(b.gpa);
        }
        inline for (comptime std.meta.tags(SpanId)) |id| {
            @field(u.timer, @tagName(id)) = try b.spans[@backingInt(id)].toOwnedSlice(b.gpa);
        }
        u.conditions = try b.conditions.toOwnedSlice(b.gpa);
        u.environment = try b.env.toOwnedSlice(b.gpa);
        u.environment_file = try b.env_files.toOwnedSlice(b.gpa);
        u.limits = try b.limits.toOwnedSlice(b.gpa);
        u.issues = try b.issues.toOwnedSlice(b.gpa);
        return u;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn zeroIsInfinity(v: ?u64) ?u64 {
    const x = v orelse return null;
    return if (x == 0) timespan.infinity else x;
}

pub fn parseBool(s: []const u8) ?bool {
    const yes = [_][]const u8{ "1", "yes", "y", "true", "t", "on" };
    const no = [_][]const u8{ "0", "no", "n", "false", "f", "off" };
    for (yes) |v| if (std.ascii.eqlIgnoreCase(s, v)) return true;
    for (no) |v| if (std.ascii.eqlIgnoreCase(s, v)) return false;
    return null;
}

fn isEnvName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isExtension(s: []const u8) bool {
    return s.len >= 2 and std.ascii.eqlIgnoreCase(s[0..2], "X-");
}

const sandbox_keys = [_][]const u8{
    "ProtectSystem",       "ProtectHome",             "ProtectKernelTunables",   "ProtectKernelModules",
    "ProtectKernelLogs",   "ProtectControlGroups",    "ProtectClock",            "ProtectHostname",
    "ProtectProc",         "ProcSubset",              "PrivateTmp",              "PrivateDevices",
    "PrivateNetwork",      "PrivateUsers",            "PrivateMounts",           "PrivateIPC",
    "PrivatePIDs",         "ReadWritePaths",          "ReadOnlyPaths",           "InaccessiblePaths",
    "ExecPaths",           "NoExecPaths",             "TemporaryFileSystem",     "BindPaths",
    "BindReadOnlyPaths",   "MountAPIVFS",             "MountFlags",              "CapabilityBoundingSet",
    "AmbientCapabilities", "SystemCallFilter",        "SystemCallArchitectures", "SystemCallErrorNumber",
    "SystemCallLog",       "RestrictAddressFamilies", "RestrictNamespaces",      "RestrictRealtime",
    "RestrictSUIDSGID",    "RestrictFileSystems",     "LockPersonality",         "MemoryDenyWriteExecute",
    "SELinuxContext",      "AppArmorProfile",         "SmackProcessLabel",       "DevicePolicy",
    "DeviceAllow",         "IPAddressAllow",          "IPAddressDeny",           "NetworkNamespacePath",
    "IPCNamespacePath",    "RemoveIPC",
};

const resource_exact = [_][]const u8{ "Slice", "Delegate", "DisableControllers", "TasksMax", "TasksAccounting" };
const resource_prefixes = [_][]const u8{ "CPU", "Memory", "IO", "BlockIO", "ManagedOOM", "Startup", "DefaultMemory" };
const resource_exceptions = [_][]const u8{ "CPUSchedulingPolicy", "CPUSchedulingPriority", "CPUSchedulingResetOnFork", "CPUAffinity", "MemoryDenyWriteExecute", "IOSchedulingClass", "IOSchedulingPriority" };

const ignored_keys = [_][]const u8{
    // [Unit]
    "Documentation",        "OnFailure",               "OnSuccess",                 "StartLimitIntervalSec",
    "StartLimitBurst",      "StartLimitAction",        "JobTimeoutSec",             "JobTimeoutAction",
    "JobRunningTimeoutSec", "RefuseManualStart",       "RefuseManualStop",          "AllowIsolate",
    "IgnoreOnIsolate",      "StopWhenUnneeded",        "Requisite",                 "Upholds",
    "PropagatesReloadTo",   "ReloadPropagatedFrom",    "PropagatesStopTo",          "StopPropagatedFrom",
    "JoinsNamespaceOf",     "FailureAction",           "SuccessAction",             "RebootArgument",
    "SourcePath",           "OnSuccessJobMode",        "OnFailureJobMode",          "RequiresMountsFor",
    "WantsMountsFor",       "SuccessActionExitStatus", "FailureActionExitStatus",
    // [Service]
      "ExecCondition",
    "StandardInput",        "StandardOutput",          "StandardError",             "StandardInputText",
    "StandardInputData",    "SyslogIdentifier",        "SyslogFacility",            "SyslogLevel",
    "SyslogLevelPrefix",    "TTYPath",                 "TTYReset",                  "TTYVHangup",
    "TTYVTDisallocate",     "WatchdogSec",             "NotifyAccess",              "FileDescriptorStoreMax",
    "OOMScoreAdjust",       "OOMPolicy",               "RestartPreventExitStatus",  "RestartForceExitStatus",
    "RestartMaxDelaySec",   "RestartSteps",            "RootDirectory",             "RootImage",
    "PermissionsStartOnly", "GuessMainPID",            "Sockets",                   "LogLevelMax",
    "LogExtraFields",       "LogRateLimitIntervalSec", "LogRateLimitBurst",         "LogNamespace",
    "SetCredential",        "LoadCredential",          "ImportCredential",          "UtmpIdentifier",
    "UtmpMode",             "TimerSlackNSec",          "Personality",               "SecureBits",
    "KeyringMode",          "PAMName",                 "ExitType",                  "TimeoutAbortSec",
    "TimeoutCleanSec",      "RuntimeMaxSec",           "RuntimeRandomizedExtraSec", "SendSIGHUP",
    "SendSIGKILL",          "FinalKillSignal",         "WatchdogSignal",            "ReloadSignal",
    "CPUSchedulingPolicy",  "CPUSchedulingPriority",   "CPUSchedulingResetOnFork",  "CPUAffinity",
    "IOSchedulingClass",    "IOSchedulingPriority",    "ExecReloadPost",            "USBFunctionDescriptors",
    "USBFunctionStrings",   "NUMAPolicy",              "NUMAMask",                  "CoredumpFilter",
    // [Install]
    "UpheldBy",
};

fn inList(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (eq(k, key)) return true;
    return false;
}

fn classifyKey(section: []const u8, key: []const u8) IssueKind {
    if (eq(section, "Service")) {
        if (eq(key, "DynamicUser")) return .behavior_key;
        if (inList(&sandbox_keys, key)) return .sandbox_key;
        if (!inList(&resource_exceptions, key)) {
            if (inList(&resource_exact, key)) return .resource_key;
            for (resource_prefixes) |p| if (std.mem.startsWith(u8, key, p)) return .resource_key;
        }
    }
    if (inList(&ignored_keys, key)) return .ignored_key;
    return .unknown_key;
}

/// Builds the model from already parsed files; `files` is indexed by `Entry.file`.
pub fn fromDocument(
    gpa: Allocator,
    name: Name,
    files: []const resolve.FileRef,
    doc: ini.Document,
    opts: Options,
) Allocator.Error!Unit {
    var b: Builder = .{
        .gpa = gpa,
        .ctx = .{ .env = opts.env, .name = name },
        .unit = .{ .name = name, .scope = opts.env.scope, .files = files },
    };
    b.unit.has_install = doc.hasSection("Install");

    b.ctx.service_user = try preScanUser(&b, doc, opts);

    for (doc.problems.items) |p| {
        try b.issues.append(gpa, .{
            .kind = .syntax,
            .section = "",
            .key = "",
            .file = p.file,
            .line = p.line,
            .detail = @tagName(p.kind),
        });
    }
    for (doc.sections.items) |s| {
        if (isKnownSection(s.name) or isExtension(s.name)) continue;
        var seen = false;
        for (b.unknown_sections.items) |n| {
            if (eq(n, s.name)) seen = true;
        }
        if (seen) continue;
        try b.unknown_sections.append(gpa, s.name);
        try b.issues.append(gpa, .{ .kind = .unknown_section, .section = s.name, .key = "", .file = s.file, .line = s.line });
    }
    for (doc.entries.items) |e| try b.apply(e);
    return b.finish();
}

fn isKnownSection(s: []const u8) bool {
    return eq(s, "Unit") or eq(s, "Service") or eq(s, "Install") or eq(s, "Timer");
}

/// Resolves the account of `User=` (last assignment wins) before any other directive is expanded,
/// since `%u`, `%U`, `%g`, `%G` and `%h` depend on it.
fn preScanUser(b: *Builder, doc: ini.Document, opts: Options) Allocator.Error!?specifier.UserInfo {
    var user: ?[]const u8 = null;
    b.quiet = true;
    defer b.quiet = false;
    for (doc.entries.items) |e| {
        if (!eq(e.section, "Service") or !eq(e.key, "User")) continue;
        user = if (e.value.len == 0) null else try b.expand(e, e.value);
    }
    const n = user orelse return null;
    if (eq(n, opts.env.user.name)) return opts.env.user;
    if (opts.user_lookup) |l| {
        if (l.lookup(l.context, n)) |info| return info;
    }
    return .{ .name = n };
}

const testing = std.testing;

fn testEnv() specifier.Env {
    var env = specifier.Env.system(.{ .name = "root", .uid = 0, .group = "root", .gid = 0, .home = "/root" });
    env.hostname = "host";
    return env;
}

fn build(arena: Allocator, unit_name: []const u8, files: []const []const u8) !Unit {
    var doc: ini.Document = .empty;
    for (files, 0..) |content, i| try ini.parse(arena, &doc, content, @intCast(i));
    return fromDocument(arena, try name_mod.parse(arena, unit_name), &.{}, doc, .{ .env = testEnv() });
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "basic service" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        \\[Unit]
        \\Description=Foo daemon
        \\After=network.target syslog.target
        \\Wants=bar.service
        \\
        \\[Service]
        \\Type=forking
        \\ExecStart=/usr/bin/foo --daemon
        \\PIDFile=/run/foo.pid
        \\Restart=on-failure
        \\RestartSec=5s
        \\User=foo
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    });
    try testing.expectEqualStrings("Foo daemon", u.description.?);
    try expectStrings(&.{ "network.target", "syslog.target" }, u.after);
    try expectStrings(&.{"bar.service"}, u.wants);
    try testing.expectEqual(ServiceType.forking, u.service_type);
    try testing.expectEqual(@as(usize, 1), u.exec_start.len);
    try expectStrings(&.{ "/usr/bin/foo", "--daemon" }, u.exec_start[0].words);
    try testing.expectEqualStrings("/run/foo.pid", u.pid_file.?);
    try testing.expectEqual(Restart.@"on-failure", u.restart);
    try testing.expectEqual(@as(?u64, 5_000_000), u.restart_sec);
    try testing.expectEqualStrings("foo", u.user.?);
    try testing.expect(u.has_install);
    try expectStrings(&.{"multi-user.target"}, u.wanted_by);
    try testing.expectEqual(@as(usize, 0), u.issues.len);
    try testing.expect(u.default_dependencies);
}

test "empty assignment resets lists across files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Unit]\nAfter=a b\n[Service]\nExecStart=/bin/one\nExecStartPre=/bin/p1\nEnvironment=A=1\nLimitNOFILE=10\n",
        "[Unit]\nAfter=\nAfter=c\n[Service]\nExecStart=\nExecStart=/bin/two x\nExecStartPre=/bin/p2\nEnvironment=\nEnvironment=B=2\nLimitNOFILE=\n",
    });
    try expectStrings(&.{"c"}, u.after);
    try testing.expectEqual(@as(usize, 1), u.exec_start.len);
    try testing.expectEqualStrings("/bin/two", u.exec_start[0].words[0]);
    try testing.expectEqual(@as(usize, 2), u.exec_start_pre.len);
    try testing.expectEqual(@as(usize, 1), u.environment.len);
    try testing.expectEqualStrings("B", u.environment[0].name);
    try testing.expectEqual(@as(usize, 0), u.limits.len);
}

test "list settings accumulate and scalars take the last value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Unit]\nAfter=a\nAfter=b\nDescription=one\n[Service]\nUser=x\nRestart=always\n",
        "[Unit]\nAfter=c\nDescription=two\n[Service]\nUser=y\nRestart=on-abort\n",
    });
    try expectStrings(&.{ "a", "b", "c" }, u.after);
    try testing.expectEqualStrings("two", u.description.?);
    try testing.expectEqualStrings("y", u.user.?);
    try testing.expectEqual(Restart.@"on-abort", u.restart);
}

test "repeated sections are merged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Service]\nExecStart=/bin/a\n[Unit]\nWants=w1\n[Service]\nExecStartPost=/bin/b\n[Unit]\nWants=w2\n",
    });
    try expectStrings(&.{ "w1", "w2" }, u.wants);
    try testing.expectEqual(@as(usize, 1), u.exec_start_post.len);
}

test "exec prefixes, quoting and multiple commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        \\[Service]
        \\ExecStartPre=-/bin/mkdir -p "/run/my dir"
        \\ExecStart=/bin/sh -c 'echo $HOME; exit 0'
        \\ExecStop=+/bin/a ; /bin/b
        \\ExecReload=/bin/kill -HUP $MAINPID
        \\
    });
    try testing.expect(u.exec_start_pre[0].flags.ignore_failure);
    try expectStrings(&.{ "/bin/mkdir", "-p", "/run/my dir" }, u.exec_start_pre[0].words);
    try expectStrings(&.{ "/bin/sh", "-c", "echo $HOME; exit 0" }, u.exec_start[0].words);
    try testing.expectEqual(@as(usize, 2), u.exec_stop.len);
    try testing.expect(u.exec_stop[0].flags.plus);
    try expectStrings(&.{ "/bin/kill", "-HUP", "$MAINPID" }, u.exec_reload[0].words);
}

test "environment parsing with quotes, overrides and invalid words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        \\[Service]
        \\Environment="A=one two" B=2 C=
        \\Environment=A=three
        \\Environment=bad 1X=y
        \\PassEnvironment=LANG TZ
        \\UnsetEnvironment=B
        \\EnvironmentFile=-/etc/default/foo
        \\EnvironmentFile=/etc/foo.env
        \\
    });
    try testing.expectEqual(@as(usize, 3), u.environment.len);
    try testing.expectEqualStrings("B", u.environment[0].name);
    try testing.expectEqualStrings("C", u.environment[1].name);
    try testing.expectEqualStrings("", u.environment[1].value);
    try testing.expectEqualStrings("A", u.environment[2].name);
    try testing.expectEqualStrings("three", u.environment[2].value);
    try testing.expectEqual(@as(usize, 2), u.countIssues(.invalid_value));
    try expectStrings(&.{ "LANG", "TZ" }, u.pass_environment);
    try expectStrings(&.{"B"}, u.unset_environment);
    try testing.expectEqual(@as(usize, 2), u.environment_file.len);
    try testing.expect(u.environment_file[0].optional);
    try testing.expectEqualStrings("/etc/default/foo", u.environment_file[0].path);
    try testing.expect(!u.environment_file[1].optional);
}

test "specifiers are applied, including percent escape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "app@one.service", &.{
        \\[Unit]
        \\Description=App %i on %H (100%%)
        \\After=other@%i.service
        \\[Service]
        \\ExecStart=/usr/bin/app --name %i --dir %t/%p "%n"
        \\Environment=INSTANCE=%i
        \\WorkingDirectory=%S/app
        \\RuntimeDirectory=%p
        \\User=%i
        \\
    });
    try testing.expectEqualStrings("App one on host (100%)", u.description.?);
    try expectStrings(&.{"other@one.service"}, u.after);
    try expectStrings(&.{ "/usr/bin/app", "--name", "one", "--dir", "/run/app", "app@one.service" }, u.exec_start[0].words);
    try testing.expectEqualStrings("one", u.environment[0].value);
    try testing.expectEqualStrings("/var/lib/app", u.working_directory.?);
    try expectStrings(&.{"app"}, u.runtime_directory);
    try testing.expectEqualStrings("one", u.user.?);
}

fn lookupStub(_: ?*anyopaque, n: []const u8) ?specifier.UserInfo {
    if (std.mem.eql(u8, n, "www")) return .{ .name = "www", .uid = 33, .group = "www-data", .gid = 33, .home = "/var/www" };
    return null;
}

test "User= drives %u %U %h even when other settings come first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc: ini.Document = .empty;
    try ini.parse(a, &doc, "[Service]\nWorkingDirectory=%h\nEnvironment=ID=%U\nUser=www\n", 0);
    const u = try fromDocument(a, try name_mod.parse(a, "foo"), &.{}, doc, .{
        .env = testEnv(),
        .user_lookup = .{ .lookup = lookupStub },
    });
    try testing.expectEqualStrings("/var/www", u.working_directory.?);
    try testing.expectEqualStrings("33", u.environment[0].value);
    try testing.expectEqual(@as(usize, 0), u.issues.len);
}

test "unresolvable and unknown specifiers become issues and skip the directive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Service]\nUser=nobody\nWorkingDirectory=%h\nExecStart=/bin/x %z\nExecStartPost=/bin/ok\nDescription=\n[Unit]\nDescription=a%\n",
    });
    try testing.expectEqual(@as(?[]const u8, null), u.working_directory);
    try testing.expectEqual(@as(usize, 0), u.exec_start.len);
    try testing.expectEqual(@as(usize, 1), u.exec_start_post.len);
    try testing.expectEqual(@as(usize, 3), u.countIssues(.invalid_specifier));
    var found_z = false;
    for (u.issues) |i| {
        if (std.mem.indexOf(u8, i.detail, "%z") != null) found_z = true;
    }
    try testing.expect(found_z);
}

test "durations, booleans, modes and numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        \\[Service]
        \\TimeoutStartSec=1min 30s
        \\TimeoutStopSec=0
        \\RestartSec=infinity
        \\RemainAfterExit=yes
        \\NoNewPrivileges=off
        \\UMask=0027
        \\Nice=-5
        \\RuntimeDirectoryMode=0750
        \\RuntimeDirectoryPreserve=restart
        \\KillMode=process
        \\KillSignal=SIGINT
        \\SuccessExitStatus=1 2 SIGUSR1
        \\SupplementaryGroups=audio video
        \\LimitNOFILE=65536
        \\LimitCORE=infinity
        \\
    });
    try testing.expectEqual(@as(?u64, 90_000_000), u.timeout_start_sec);
    try testing.expectEqual(@as(?u64, timespan.infinity), u.timeout_stop_sec);
    try testing.expectEqual(@as(?u64, timespan.infinity), u.restart_sec);
    try testing.expect(u.remain_after_exit);
    try testing.expectEqual(@as(?bool, false), u.no_new_privileges);
    try testing.expectEqual(@as(?u16, 0o27), u.umask);
    try testing.expectEqual(@as(?i8, -5), u.nice);
    try testing.expectEqual(@as(?u16, 0o750), u.runtime_directory_mode);
    try testing.expectEqual(@as(?DirectoryPreserve, .restart), u.runtime_directory_preserve);
    try testing.expectEqual(KillMode.process, u.kill_mode);
    try testing.expectEqualStrings("SIGINT", u.kill_signal.?);
    try expectStrings(&.{ "1", "2", "SIGUSR1" }, u.success_exit_status);
    try expectStrings(&.{ "audio", "video" }, u.supplementary_groups);
    try testing.expectEqual(@as(usize, 2), u.limits.len);
    try testing.expectEqualStrings("LimitNOFILE", u.limits[0].key);
    try testing.expectEqualStrings("65536", u.limits[0].value);
    try testing.expectEqual(@as(usize, 0), u.issues.len);
}

test "TimeoutSec sets both timeouts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{"[Service]\nTimeoutSec=10\n"});
    try testing.expectEqual(@as(?u64, 10_000_000), u.timeout_start_sec);
    try testing.expectEqual(@as(?u64, 10_000_000), u.timeout_stop_sec);
}

test "invalid values are reported and leave defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Service]\nType=weird\nRestart=sometimes\nRestartSec=soon\nRemainAfterExit=maybe\nUMask=999\nNice=40\nKillMode=x\nExecStart=\"unterminated\n",
    });
    try testing.expectEqual(ServiceType.simple, u.service_type);
    try testing.expectEqual(Restart.no, u.restart);
    try testing.expectEqual(@as(?u64, null), u.restart_sec);
    try testing.expectEqual(@as(?u16, null), u.umask);
    try testing.expectEqual(@as(?i8, null), u.nice);
    try testing.expectEqual(@as(usize, 8), u.countIssues(.invalid_value));
}

test "all service types parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "simple", "exec", "forking", "oneshot", "dbus", "notify", "notify-reload", "idle" };
    for (names, std.meta.tags(ServiceType)) |n, t| {
        const text = try std.fmt.allocPrint(arena.allocator(), "[Service]\nType={s}\n", .{n});
        const u = try build(arena.allocator(), "foo", &.{text});
        try testing.expectEqual(t, u.service_type);
    }
}

test "conditions and DefaultDependencies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Unit]\nDefaultDependencies=no\nConditionPathExists=/etc/foo\nAssertPathExists=!/run/x\nConditionVirtualization=!container\n",
    });
    try testing.expect(!u.default_dependencies);
    try testing.expectEqual(@as(usize, 3), u.conditions.len);
    try testing.expectEqualStrings("ConditionPathExists", u.conditions[0].key);
    try testing.expectEqualStrings("!/run/x", u.conditions[1].value);
}

test "directory settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        "[Service]\nRuntimeDirectory=foo bar\nStateDirectory=foo\nCacheDirectory=foo\nLogsDirectory=foo\nConfigurationDirectory=foo\nStateDirectoryMode=0700\n",
    });
    try expectStrings(&.{ "foo", "bar" }, u.runtime_directory);
    try expectStrings(&.{"foo"}, u.state_directory);
    try expectStrings(&.{"foo"}, u.configuration_directory);
    try testing.expectEqual(@as(?u16, 0o700), u.state_directory_mode);
}

test "install section details" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo@.service", &.{
        "[Install]\nWantedBy=multi-user.target default.target\nRequiredBy=x.service\nAlso=foo.socket\nAlias=food.service\nDefaultInstance=main\n",
    });
    try expectStrings(&.{ "multi-user.target", "default.target" }, u.wanted_by);
    try expectStrings(&.{"x.service"}, u.required_by);
    try expectStrings(&.{"foo.socket"}, u.also);
    try expectStrings(&.{"food.service"}, u.alias);
    try testing.expectEqualStrings("main", u.default_instance.?);
}

test "empty [Install] section still counts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const with = try build(arena.allocator(), "foo", &.{"[Service]\nExecStart=/bin/x\n[Install]\n"});
    try testing.expect(with.has_install);
    const without = try build(arena.allocator(), "foo", &.{"[Service]\nExecStart=/bin/x\n"});
    try testing.expect(!without.has_install);
}

test "timer directives" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo.timer", &.{
        \\[Timer]
        \\OnCalendar=daily
        \\OnCalendar=Mon *-*-* 03:00:00
        \\OnBootSec=5min
        \\OnStartupSec=1h
        \\OnActiveSec=30s
        \\OnUnitActiveSec=1d
        \\OnUnitActiveSec=2d
        \\OnUnitInactiveSec=10min
        \\Persistent=true
        \\RandomizedDelaySec=1h
        \\FixedRandomDelay=yes
        \\AccuracySec=1min
        \\Unit=other.service
        \\WakeSystem=true
        \\OnClockChange=yes
        \\
    });
    try expectStrings(&.{ "daily", "Mon *-*-* 03:00:00" }, u.timer.on_calendar);
    try testing.expectEqualSlices(u64, &.{300_000_000}, u.timer.on_boot_sec);
    try testing.expectEqualSlices(u64, &.{3600_000_000}, u.timer.on_startup_sec);
    try testing.expectEqualSlices(u64, &.{30_000_000}, u.timer.on_active_sec);
    try testing.expectEqualSlices(u64, &.{ 86400_000_000, 172800_000_000 }, u.timer.on_unit_active_sec);
    try testing.expectEqualSlices(u64, &.{600_000_000}, u.timer.on_unit_inactive_sec);
    try testing.expect(u.timer.persistent and u.timer.fixed_random_delay);
    try testing.expectEqual(@as(?u64, 3600_000_000), u.timer.randomized_delay_sec);
    try testing.expectEqual(@as(?u64, 60_000_000), u.timer.accuracy_sec);
    try testing.expectEqualStrings("other.service", u.timer.unit.?);
    try testing.expectEqual(@as(usize, 2), u.countIssues(.behavior_key));
    try testing.expectEqual(@as(usize, 1), u.countIssues(.ignored_key));
}

test "timer lists reset on empty assignment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo.timer", &.{
        "[Timer]\nOnCalendar=daily\nOnBootSec=1min\n",
        "[Timer]\nOnCalendar=\nOnCalendar=weekly\nOnBootSec=\n",
    });
    try expectStrings(&.{"weekly"}, u.timer.on_calendar);
    try testing.expectEqual(@as(usize, 0), u.timer.on_boot_sec.len);
}

test "unsupported and unknown directives are recorded by kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{
        \\[Unit]
        \\Documentation=man:foo(8)
        \\X-Custom=1
        \\Bogus=1
        \\[Service]
        \\ExecStart=/bin/x
        \\ProtectSystem=strict
        \\PrivateTmp=yes
        \\ReadWritePaths=/var/lib/foo
        \\CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        \\MemoryMax=1G
        \\CPUQuota=50%
        \\Slice=foo.slice
        \\DynamicUser=yes
        \\StandardOutput=journal
        \\CPUSchedulingPolicy=idle
        \\X-Other=2
        \\[Socket]
        \\ListenStream=80
        \\[Socket]
        \\Accept=no
        \\[X-Foo]
        \\A=b
        \\
    });
    try testing.expectEqual(@as(usize, 4), u.countIssues(.sandbox_key));
    try testing.expectEqual(@as(usize, 3), u.countIssues(.resource_key));
    try testing.expectEqual(@as(usize, 1), u.countIssues(.behavior_key));
    try testing.expectEqual(@as(usize, 3), u.countIssues(.ignored_key));
    try testing.expectEqual(@as(usize, 1), u.countIssues(.unknown_key));
    try testing.expectEqual(@as(usize, 1), u.countIssues(.unknown_section));
    for (u.issues) |i| {
        if (i.kind == .unknown_key) {
            try testing.expectEqualStrings("Bogus", i.key);
            try testing.expectEqualStrings("Unit", i.section);
            try testing.expectEqual(@as(u32, 4), i.line);
        }
    }
}

test "syntax problems become issues" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{"Orphan=1\n[Service]\nnonsense\nExecStart=/bin/x\n"});
    try testing.expectEqual(@as(usize, 2), u.countIssues(.syntax));
    try testing.expectEqual(@as(usize, 1), u.exec_start.len);
}

test "continuation lines in exec values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{"[Service]\nExecStart=/usr/bin/foo \\\n   --opt=1 \\\n   --other\n"});
    try expectStrings(&.{ "/usr/bin/foo", "--opt=1", "--other" }, u.exec_start[0].words);
}

test "load reads fragment and drop-ins through Fs" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.makePath("/usr/lib/systemd/system/foo.service.d");
    try fs.makePath("/etc/systemd/system/foo.service.d");
    try fs.writeFileAtomic("/usr/lib/systemd/system/foo.service", "[Service]\nExecStart=/bin/foo\nEnvironment=A=1\n[Install]\nWantedBy=multi-user.target\n", 0o644);
    try fs.writeFileAtomic("/etc/systemd/system/foo.service.d/10-env.conf", "[Service]\nEnvironment=B=2\nExecStart=\nExecStart=/bin/foo2\n", 0o644);
    const r = try resolve.resolve(a, fs, .{ .scope = .system }, try name_mod.parse(a, "foo"));
    const u = try load(a, fs, r, .{ .env = testEnv() });
    try testing.expectEqual(@as(usize, 2), u.files.len);
    try testing.expectEqual(@as(usize, 2), u.environment.len);
    try testing.expectEqualStrings("/bin/foo2", u.exec_start[0].words[0]);
    try testing.expect(u.has_install);

    const missing = try resolve.resolve(a, fs, .{ .scope = .system }, try name_mod.parse(a, "nope"));
    try testing.expectError(error.UnitNotFound, load(a, fs, missing, .{ .env = testEnv() }));
    try fs.symLink("/dev/null", "/etc/systemd/system/masked.service");
    const masked = try resolve.resolve(a, fs, .{ .scope = .system }, try name_mod.parse(a, "masked"));
    try testing.expectError(error.UnitMasked, load(a, fs, masked, .{ .env = testEnv() }));
}

test "account names that start with a dash are reported and kept for the consumers to refuse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try build(arena.allocator(), "foo", &.{"[Service]\nUser=-r\nGroup=--\nSupplementaryGroups=audio -x\nExecStart=/bin/true\n"});
    try testing.expectEqual(@as(usize, 3), u.countIssues(.invalid_value));
    try testing.expectEqualStrings("-r", u.user.?);
    try testing.expectEqualStrings("--", u.group.?);
    try testing.expectEqual(@as(usize, 2), u.supplementary_groups.len);
}
